"""Tests for selectel-dns-hook.py against an in-process mock of the Selectel identity/DNS API and a UDP DNS server.

    python -m unittest installations/kurkin-family__labs__m01/certbot/test_selectel_dns_hook.py

The mock follows the same reading of the API the hook is written against; it cannot prove that Selectel behaves
identically. That is what `renew.sh --dry-run` (Let's Encrypt staging) is for.
"""
import contextlib
import importlib.util
import io
import json
import os
import socket
import struct
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HOOK = Path(__file__).with_name("selectel-dns-hook.py")
spec = importlib.util.spec_from_file_location("selectel_dns_hook", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

TOKEN = "tok-123"
PASSWORD = "very-secret-password"


class MockState:
    def __init__(self, envelope="result"):
        self.envelope = envelope
        self.zones = [{"id": "z-root", "name": "kurkin-family.ru."}, {"id": "z-sub", "name": "labs.kurkin-family.ru."},
                      {"id": "z-other", "name": "example.org."}]
        self.rrsets = {}  # zone id -> {rrset id -> rrset}
        self.calls = []
        self.scopes = []
        self.counter = 0


def make_api(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, status, payload=None, headers=None):
            raw = json.dumps(payload).encode() if payload is not None else b""
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(raw)

        def _wrap(self, items, key):
            return items if state.envelope == "bare" else {state.envelope: items, "count": len(items)}

        def _body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(length)) if length else None

        def _route(self, method):
            url = urlparse(self.path)
            body = self._body()
            state.calls.append((method, url.path, body))
            if url.path == "/identity":
                user = body["auth"]["identity"]["password"]["user"]
                state.scopes.append(body["auth"]["scope"]["project"])
                if user["password"] != PASSWORD:
                    return self._send(401, {"error": "denied"})
                return self._send(201, {"token": {}}, {"X-Subject-Token": TOKEN})
            if self.headers.get("X-Auth-Token") != TOKEN:
                return self._send(401, {"error": "no token"})
            parts = url.path.strip("/").split("/")
            query = parse_qs(url.query)
            if parts == ["zones"] and method == "GET":
                return self._send(200, self._wrap(state.zones, "zones"))
            if len(parts) >= 3 and parts[0] == "zones" and parts[2] == "rrset":
                zone = state.rrsets.setdefault(parts[1], {})
                if len(parts) == 3 and method == "GET":
                    items = [r for r in zone.values()
                             if r["name"] == (query.get("name") or [r["name"]])[0] and r["type"] in (query.get("rrset_types") or [r["type"]])]
                    return self._send(200, self._wrap(items, "rrsets"))
                if len(parts) == 3 and method == "POST":
                    state.counter += 1
                    rrset = dict(body, id=f"r{state.counter}")
                    zone[rrset["id"]] = rrset
                    return self._send(201, rrset)
                if len(parts) == 4 and method == "PATCH":
                    zone[parts[3]].update(ttl=body["ttl"], records=body["records"])
                    return self._send(200, zone[parts[3]])
                if len(parts) == 4 and method == "DELETE":
                    zone.pop(parts[3])
                    return self._send(204)
            return self._send(404, {"error": "not found"})

        def do_GET(self):
            self._route("GET")

        def do_POST(self):
            self._route("POST")

        def do_PATCH(self):
            self._route("PATCH")

        def do_DELETE(self):
            self._route("DELETE")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def name_wire(name):
    return b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\x00"


def make_dns(state, zone_id, serve=True, truncate_first=False):
    """UDP (and TCP for truncated) responder serving the TXT values stored at the queried name, with a compression pointer."""
    def answer(packet, truncated=False):
        qid = packet[:2]
        end = 12
        while packet[end] != 0:
            end += 1 + packet[end]
        question = packet[12:end + 5]
        labels, pos = [], 12
        while packet[pos]:
            labels.append(packet[pos + 1:pos + 1 + packet[pos]].decode())
            pos += 1 + packet[pos]
        qname = ".".join(labels) + "."
        values = []
        if serve:
            for rrset in state.rrsets.get(zone_id, {}).values():
                if rrset["name"] == qname:
                    values += [r["content"].strip('"') for r in rrset["records"]]
        flags = 0x8400 | (0x0200 if truncated else 0)
        data = qid + struct.pack("!HHHHH", flags, 1, 0 if truncated else len(values), 0, 0) + question
        if not truncated:
            for value in values:
                raw = value.encode()
                data += b"\xc0\x0c" + struct.pack("!HHIH", 16, 1, 60, len(raw) + 1) + bytes([len(raw)]) + raw
        return data

    # The hook uses one port number for UDP and TCP, so find a port that is free for both.
    for _ in range(50):
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.bind(("127.0.0.1", 0))
        port = tcp.getsockname()[1]
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            udp.bind(("127.0.0.1", port))
            break
        except OSError:
            tcp.close()
            udp.close()
    else:
        raise RuntimeError("no port free for both UDP and TCP")
    tcp.listen(4)
    first = [truncate_first]

    def serve_udp():
        while True:
            try:
                packet, addr = udp.recvfrom(512)
            except OSError:
                return
            truncated = first[0]
            first[0] = False
            udp.sendto(answer(packet, truncated), addr)

    def serve_tcp():
        while True:
            try:
                conn, _ = tcp.accept()
            except OSError:
                return
            with conn:
                size = struct.unpack("!H", conn.recv(2))[0]
                packet = conn.recv(size)
                data = answer(packet)
                conn.sendall(struct.pack("!H", len(data)) + data)

    threading.Thread(target=serve_udp, daemon=True).start()
    threading.Thread(target=serve_tcp, daemon=True).start()
    return port, (udp, tcp)


class HookTests(unittest.TestCase):
    def setUp(self):
        self.state = MockState()
        self.api = make_api(self.state)
        self.addCleanup(self.api.shutdown)
        self.sockets = []

    def run_hook(self, mode, domain, value, envelope=None, dns_serves=True, truncate=False, timeout="2", password=PASSWORD, extra=None):
        if envelope:
            self.state.envelope = envelope
        base = f"http://127.0.0.1:{self.api.server_address[1]}"
        zone_id = "z-sub" if domain.endswith("labs.kurkin-family.ru") else "z-root"
        port, socks = make_dns(self.state, zone_id, serve=dns_serves, truncate_first=truncate)
        self.addCleanup(lambda: [s.close() for s in socks])
        env = {"SELECTEL_ACCOUNT_ID": "123456", "SELECTEL_USER": "svc", "SELECTEL_PASSWORD": password,
               "SELECTEL_PROJECT_ID": "0123abcd", "SELECTEL_DNS_API": base, "SELECTEL_IDENTITY_URL": base + "/identity",
               "SELECTEL_NAMESERVERS": "127.0.0.1", "SELECTEL_NS_PORT": str(port), "SELECTEL_PROPAGATION_TIMEOUT": timeout,
               "SELECTEL_POLL_INTERVAL": "0.1", "CERTBOT_DOMAIN": domain, "CERTBOT_VALIDATION": value}
        env.update(extra or {})
        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.dict(os.environ, env, clear=False), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = hook.main(["hook", mode])
        return rc, out.getvalue(), err.getvalue()

    def rrset(self, zone_id="z-sub"):
        return list(self.state.rrsets.get(zone_id, {}).values())

    def test_auth_creates_quoted_txt_in_the_longest_matching_zone(self):
        rc, out, err = self.run_hook("auth", "labs.kurkin-family.ru", "val-one")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.state.rrsets.get("z-root"), None)
        (rrset,) = self.rrset("z-sub")
        self.assertEqual(rrset["name"], "_acme-challenge.labs.kurkin-family.ru.")
        self.assertEqual(rrset["type"], "TXT")
        self.assertEqual(rrset["ttl"], 60)
        self.assertEqual(rrset["records"][0]["content"], '"val-one"')
        self.assertIn("visible on all name servers", out)

    def test_apex_and_wildcard_share_one_rrset_and_foreign_values_survive(self):
        name = "_acme-challenge.labs.kurkin-family.ru."
        self.state.rrsets["z-sub"] = {"x1": {"id": "x1", "name": name, "type": "TXT", "ttl": 300,
                                             "records": [{"content": '"test1"', "disabled": False}]}}
        self.assertEqual(self.run_hook("auth", "labs.kurkin-family.ru", "val-one")[0], 0)
        self.assertEqual(self.run_hook("auth", "labs.kurkin-family.ru", "val-two")[0], 0)
        (rrset,) = self.rrset()
        self.assertEqual([r["content"] for r in rrset["records"]], ['"test1"', '"val-one"', '"val-two"'])
        self.assertEqual(rrset["ttl"], 300)  # an existing longer ttl is not lowered
        # idempotent: the same value again changes nothing
        self.assertEqual(self.run_hook("auth", "labs.kurkin-family.ru", "val-two")[0], 0)
        self.assertEqual(len(self.rrset()[0]["records"]), 3)

        self.assertEqual(self.run_hook("cleanup", "labs.kurkin-family.ru", "val-one")[0], 0)
        self.assertEqual(self.run_hook("cleanup", "labs.kurkin-family.ru", "val-two")[0], 0)
        (rrset,) = self.rrset()
        self.assertEqual([r["content"] for r in rrset["records"]], ['"test1"'])
        self.assertNotIn("DELETE", [c[0] for c in self.state.calls])

    def test_cleanup_deletes_the_rrset_when_it_was_ours_alone(self):
        self.assertEqual(self.run_hook("auth", "labs.kurkin-family.ru", "val-one")[0], 0)
        self.assertEqual(self.run_hook("cleanup", "labs.kurkin-family.ru", "val-one")[0], 0)
        self.assertEqual(self.rrset(), [])
        self.assertEqual(self.run_hook("cleanup", "labs.kurkin-family.ru", "val-one")[0], 0)  # already gone: fine

    def test_bare_list_envelope_is_accepted(self):
        rc, _, err = self.run_hook("auth", "kurkin-family.ru", "val-one", envelope="bare")
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(self.rrset("z-root")), 1)

    def test_zone_not_in_project(self):
        rc, _, err = self.run_hook("auth", "nowhere.invalid", "v")
        self.assertEqual(rc, 1)
        self.assertIn("no DNS zone", err)

    def test_wrong_password_is_reported_without_leaking_it(self):
        rc, out, err = self.run_hook("auth", "kurkin-family.ru", "v", password="wrong-password")
        self.assertEqual(rc, 1)
        self.assertIn("HTTP 401", err)
        self.assertNotIn("wrong-password", out + err)
        self.assertNotIn(PASSWORD, out + err)

    def test_propagation_timeout_fails_the_hook(self):
        rc, _, err = self.run_hook("auth", "kurkin-family.ru", "v", dns_serves=False, timeout="1")
        self.assertEqual(rc, 1)
        self.assertIn("not visible on", err)

    def test_truncated_udp_answer_is_retried_over_tcp(self):
        rc, _, err = self.run_hook("auth", "kurkin-family.ru", "v", truncate=True)
        self.assertEqual(rc, 0, err)

    def test_project_is_scoped_by_id_or_by_name(self):
        self.assertEqual(self.run_hook("auth", "kurkin-family.ru", "v")[0], 0)
        self.assertEqual(self.state.scopes[-1], {"id": "0123abcd"})
        rc, _, err = self.run_hook("cleanup", "kurkin-family.ru", "v",
                                   extra={"SELECTEL_PROJECT_ID": "", "SELECTEL_PROJECT": "proj"})
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.state.scopes[-1], {"name": "proj", "domain": {"name": "123456"}})
        rc, _, err = self.run_hook("auth", "kurkin-family.ru", "v", extra={"SELECTEL_PROJECT_ID": ""})
        self.assertEqual(rc, 1)
        self.assertIn("SELECTEL_PROJECT", err)

    def test_transient_network_errors_are_retried_but_http_errors_are_not(self):
        real = urllib.request.urlopen
        failures = {"left": 2}

        def flaky(request, *args, **kwargs):
            if failures["left"] > 0:
                failures["left"] -= 1
                raise urllib.error.URLError("[Errno -3] Try again")
            return real(request, *args, **kwargs)

        with unittest.mock.patch("urllib.request.urlopen", flaky):
            rc, _, err = self.run_hook("auth", "kurkin-family.ru", "v", extra={"SELECTEL_RETRY_DELAY": "0.01"})
        self.assertEqual(rc, 0, err)
        self.assertEqual(failures["left"], 0)

        failures["left"] = 99
        with unittest.mock.patch("urllib.request.urlopen", flaky):
            rc, _, err = self.run_hook("cleanup", "kurkin-family.ru", "v", extra={"SELECTEL_RETRY_DELAY": "0.01"})
        self.assertEqual(rc, 1)
        self.assertIn("failed after 4 attempts", err)
        self.assertEqual(failures["left"], 99 - 4)

        # a wrong password is an HTTP answer: reported at once, not retried
        failures["left"] = 0
        calls = []
        with unittest.mock.patch("urllib.request.urlopen", lambda r, *a, **k: (calls.append(1), real(r, *a, **k))[1]):
            rc, _, err = self.run_hook("auth", "kurkin-family.ru", "v", password="wrong")
        self.assertEqual((rc, len(calls)), (1, 1))

    def test_names_are_resolved_over_ipv4_only(self):
        # musl fails a lookup outright when the resolver REFUSES the AAAA query, so the hook never asks for it
        with unittest.mock.patch.object(hook, "_real_getaddrinfo", return_value=[]) as real:
            hook._ipv4_only("cloud.api.selcloud.ru", 443, 0, socket.SOCK_STREAM)
        real.assert_called_once_with("cloud.api.selcloud.ru", 443, socket.AF_INET, socket.SOCK_STREAM, 0, 0)

    def test_name_servers_come_from_the_zone_unless_overridden(self):
        # the zone publishes its own NS set; localhost stands in for the authoritative server in this test
        self.state.rrsets["z-root"] = {"ns1": {"id": "ns1", "name": "kurkin-family.ru.", "type": "NS", "ttl": 3600,
                                               "records": [{"content": "localhost.", "disabled": False}]}}
        rc, out, err = self.run_hook("auth", "kurkin-family.ru", "v", extra={"SELECTEL_NAMESERVERS": ""})
        self.assertEqual(rc, 0, err)
        self.assertIn("visible on all name servers", out)
        # no NS set and no override: the built-in list is used (names that cannot resolve, so the wait times out on them)
        self.state.rrsets["z-root"] = {}
        with unittest.mock.patch.object(hook, "DEFAULT_NAMESERVERS", "a.ns.example.invalid,b.ns.example.invalid"):
            rc, _, err = self.run_hook("auth", "kurkin-family.ru", "v2", timeout="1", extra={"SELECTEL_NAMESERVERS": ""})
        self.assertEqual(rc, 1)
        self.assertIn("a.ns.example.invalid", err)

    def test_missing_credentials(self):
        rc, _, err = self.run_hook("auth", "kurkin-family.ru", "v", extra={"SELECTEL_USER": ""})
        self.assertEqual(rc, 1)
        self.assertIn("SELECTEL_USER", err)

    def test_usage(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(hook.main(["hook"]), 2)
            self.assertEqual(hook.main(["hook", "bogus"]), 2)


if __name__ == "__main__":
    import unittest.mock  # noqa: F401
    unittest.main()
else:
    import unittest.mock  # noqa: F401
