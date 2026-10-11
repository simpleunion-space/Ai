#!/usr/bin/env python3
"""certbot --manual-auth-hook / --manual-cleanup-hook for DNS-01 on Selectel DNS Hosting (API v2).

    selectel-dns-hook.py auth      add the validation TXT value for $CERTBOT_DOMAIN and wait until Selectel's
                                   authoritative name servers serve it
    selectel-dns-hook.py cleanup   remove exactly that value again (other TXT values at the same name stay)

Runs inside the certbot container (python3 only, no third-party modules). The apex and the wildcard of one
domain both validate at the same name, _acme-challenge.<domain>, so the record set carries up to two values at
once; the hook therefore edits a record set value by value and never replaces or deletes foreign values.

Environment (credentials come from a root-only env file passed with docker --env-file, never from argv):
    SELECTEL_ACCOUNT_ID     account number (the identity "domain" of the service user)
    SELECTEL_USER           service user name
    SELECTEL_PASSWORD       service user password
    SELECTEL_PROJECT_ID     id of the project that owns the DNS zone (preferred)
    SELECTEL_PROJECT        alternative to the id: the project name
    SELECTEL_DNS_API        optional, default https://api.selectel.ru/domains/v2
    SELECTEL_IDENTITY_URL   optional, default https://cloud.api.selcloud.ru/identity/v3/auth/tokens
    SELECTEL_NAMESERVERS    optional, comma separated; by default the zone's own NS record set is read from the API
                            (falling back to Selectel's four servers a-d.ns.selectel.ru)
    SELECTEL_PROPAGATION_TIMEOUT  optional seconds to wait for the name servers (default 600: observed live, a
                            first change shows up in about a minute, a second change right after it can take minutes)
    SELECTEL_NS_PORT        optional, tests only (default 53)
    SELECTEL_POLL_INTERVAL  optional, tests only: seconds between name server polls (default 5)
    SELECTEL_RETRY_DELAY    optional, tests only: base seconds between retries of a failed connection (default 3)

Written against Selectel's published API reference (token: POST .../auth/tokens with the token in the
X-Subject-Token response header, sent back as X-Auth-Token; zones: GET /zones; record sets: /zones/{id}/rrset
with name, ttl 60..604800, records[].content). It could not be run against the real service when it was written:
the first real run must be `renew.sh --dry-run` (Let's Encrypt staging). Response envelopes are read leniently
for that reason (a bare list, or an object that wraps the list).
"""
import json
import os
import random
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

DEFAULT_DNS_API = "https://api.selectel.ru/domains/v2"
DEFAULT_IDENTITY_URL = "https://cloud.api.selcloud.ru/identity/v3/auth/tokens"
DEFAULT_NAMESERVERS = "a.ns.selectel.ru,b.ns.selectel.ru,c.ns.selectel.ru,d.ns.selectel.ru"
TTL = 60  # the API minimum: a stale value never outlives a renewal by long


class HookError(Exception):
    pass


# The certbot image is musl-based, and musl fails a whole lookup (EAI_AGAIN) when the resolver answers one of the
# two queries with an error. This LAN's resolver REFUSES the AAAA query for cloud.api.selcloud.ru while the A record
# is fine, so every request of this hook failed. Selectel is reached over IPv4 anyway: resolve IPv4 only.
_real_getaddrinfo = socket.getaddrinfo


def _ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
    return _real_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)


def env(name, default=None, required=False):
    value = os.environ.get(name, default)
    if required and not value:
        raise HookError(f"missing environment variable {name}")
    return value


def fqdn(name):
    return name.rstrip(".") + "."


def quote_txt(value):
    return '"' + value + '"'


def unquote_txt(content):
    content = content.strip()
    if len(content) >= 2 and content[0] == '"' and content[-1] == '"':
        return content[1:-1]
    return content


def unwrap(payload, *keys):
    """The list inside an API answer: a bare list, or the first of keys that holds one."""
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in keys + ("result", "items"):
            if isinstance(payload.get(key), list):
                return payload[key]
    raise HookError("unexpected API answer shape")


class Selectel:
    def __init__(self):
        self.api = env("SELECTEL_DNS_API", DEFAULT_DNS_API).rstrip("/")
        self.identity = env("SELECTEL_IDENTITY_URL", DEFAULT_IDENTITY_URL)
        self.token = None

    def _request(self, method, url, body=None, headers=None, ok=(200, 201, 204)):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        request.add_header("Accept", "application/json")
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        delay = float(env("SELECTEL_RETRY_DELAY", "3"))
        for attempt in range(1, 5):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    raw = response.read()
                    return response.status, dict(response.headers), (json.loads(raw) if raw else None)
            except urllib.error.HTTPError as error:
                detail = error.read()[:300].decode("utf-8", "replace")
                raise HookError(f"{method} {url.split('?')[0]} -> HTTP {error.code}: {detail}") from None
            except (urllib.error.URLError, OSError) as error:
                # A name server or the network that answers "try again" for a moment (seen on this LAN's resolver):
                # retry a few times before giving up. An HTTP answer is never retried.
                if attempt == 4:
                    raise HookError(f"{method} {url.split('?')[0]} failed after {attempt} attempts: {error}") from None
                time.sleep(delay * attempt)

    @staticmethod
    def project_scope(account):
        project_id = env("SELECTEL_PROJECT_ID")
        if project_id:
            return {"id": project_id}
        return {"name": env("SELECTEL_PROJECT", required=True), "domain": {"name": account}}

    def authenticate(self):
        account = env("SELECTEL_ACCOUNT_ID", required=True)
        body = {"auth": {
            "identity": {"methods": ["password"], "password": {"user": {
                "name": env("SELECTEL_USER", required=True),
                "domain": {"name": account},
                "password": env("SELECTEL_PASSWORD", required=True)}}},
            "scope": {"project": self.project_scope(account)},
        }}
        _, headers, _ = self._request("POST", self.identity, body)
        token = next((v for k, v in headers.items() if k.lower() == "x-subject-token"), None)
        if not token:
            raise HookError("identity service did not return a token")
        self.token = token

    def call(self, method, path, body=None):
        if self.token is None:
            self.authenticate()
        return self._request(method, self.api + path, body, {"X-Auth-Token": self.token})[2]

    def zone_for(self, domain):
        """The zone with the longest name that contains the domain."""
        name = fqdn(domain)
        best = None
        offset = 0
        while True:
            page = self.call("GET", f"/zones?limit=1000&offset={offset}")
            zones = unwrap(page, "zones")
            for zone in zones:
                zname = fqdn(zone["name"])
                if name == zname or name.endswith("." + zname):
                    if best is None or len(zname) > len(fqdn(best["name"])):
                        best = zone
            if len(zones) < 1000:
                break
            offset += 1000
        if best is None:
            raise HookError(f"no DNS zone in this project contains {domain}")
        return best

    def rrset(self, zone_id, name, rtype):
        from urllib.parse import quote
        page = self.call("GET", f"/zones/{zone_id}/rrset?limit=100&name={quote(name)}&rrset_types={rtype}")
        for rrset in unwrap(page, "rrsets"):
            if fqdn(rrset["name"]) == name and rrset.get("type", rtype) == rtype:
                return rrset
        return None

    def txt_rrset(self, zone_id, name):
        return self.rrset(zone_id, name, "TXT")

    def nameservers(self, zone):
        """The zone's own authoritative servers, [] when the API does not say."""
        try:
            rrset = self.rrset(zone["id"], fqdn(zone["name"]), "NS")
        except HookError:
            return []
        if rrset is None:
            return []
        return [r["content"].strip().rstrip(".") for r in rrset.get("records", []) if r.get("content") and not r.get("disabled")]


def record_values(rrset):
    return [unquote_txt(r["content"]) for r in rrset.get("records", [])]


def add_value(client, zone_id, name, value):
    rrset = client.txt_rrset(zone_id, name)
    if rrset is None:
        client.call("POST", f"/zones/{zone_id}/rrset", {
            "name": name, "type": "TXT", "ttl": TTL,
            "records": [{"content": quote_txt(value), "disabled": False}],
            "comment": "certbot dns-01 (ai-stand)"})
        return
    if value in record_values(rrset):
        return
    records = [{"content": r["content"], "disabled": bool(r.get("disabled", False))} for r in rrset.get("records", [])]
    records.append({"content": quote_txt(value), "disabled": False})
    client.call("PATCH", f"/zones/{zone_id}/rrset/{rrset['id']}", {"ttl": max(TTL, int(rrset.get("ttl", TTL))), "records": records})


def remove_value(client, zone_id, name, value):
    """True when the value was there and is now removed."""
    rrset = client.txt_rrset(zone_id, name)
    if rrset is None or value not in record_values(rrset):
        return False
    keep = [{"content": r["content"], "disabled": bool(r.get("disabled", False))}
            for r in rrset.get("records", []) if unquote_txt(r["content"]) != value]
    if keep:
        client.call("PATCH", f"/zones/{zone_id}/rrset/{rrset['id']}", {"ttl": int(rrset.get("ttl", TTL)), "records": keep})
    else:
        client.call("DELETE", f"/zones/{zone_id}/rrset/{rrset['id']}")
    return True


# --- propagation check: ask the authoritative servers directly (plain DNS over UDP, TCP when truncated)

def _name_wire(name):
    return b"".join(bytes([len(part)]) + part.encode("ascii") for part in name.rstrip(".").split(".")) + b"\x00"


def _skip_name(data, pos):
    while True:
        length = data[pos]
        if length == 0:
            return pos + 1
        if length & 0xC0 == 0xC0:
            return pos + 2
        pos += 1 + length


def parse_txt_answers(data):
    qdcount, ancount = struct.unpack("!HH", data[4:8])
    rcode = data[3] & 0x0F
    pos = 12
    for _ in range(qdcount):
        pos = _skip_name(data, pos) + 4
    values = []
    for _ in range(ancount):
        pos = _skip_name(data, pos)
        rtype, _cls, _ttl, rdlen = struct.unpack("!HHIH", data[pos:pos + 10])
        pos += 10
        if rtype == 16:
            end, text = pos + rdlen, b""
            cur = pos
            while cur < end:
                text += data[cur + 1:cur + 1 + data[cur]]
                cur += 1 + data[cur]
            values.append(text.decode("utf-8", "replace"))
        pos += rdlen
    return rcode, values


def query_txt(server, name, port=53, timeout=5.0):
    query_id = random.getrandbits(16)
    packet = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + _name_wire(name) + struct.pack("!HH", 16, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(timeout)
        udp.sendto(packet, (server, port))
        data, _ = udp.recvfrom(4096)
    if struct.unpack("!H", data[:2])[0] != query_id:
        raise HookError("DNS answer id mismatch")
    if data[2] & 0x02:  # truncated: ask again over TCP
        with socket.create_connection((server, port), timeout=timeout) as tcp:
            tcp.sendall(struct.pack("!H", len(packet)) + packet)
            size = struct.unpack("!H", tcp.recv(2))[0]
            data = b""
            while len(data) < size:
                chunk = tcp.recv(size - len(data))
                if not chunk:
                    break
                data += chunk
    return parse_txt_answers(data)


def wait_for_value(name, value, nameservers, timeout, port, interval=5.0):
    deadline = time.time() + timeout
    pending = list(nameservers)
    while pending and time.time() < deadline:
        for server_name in list(pending):
            try:
                address = socket.getaddrinfo(server_name, port, socket.AF_INET, socket.SOCK_DGRAM)[0][4][0]
                _, values = query_txt(address, name, port)
            except (OSError, HookError, IndexError, struct.error):
                continue
            if value in values:
                pending.remove(server_name)
        if pending:
            time.sleep(interval)
    if pending:
        raise HookError("TXT value not visible on: " + ", ".join(pending))


def main(argv):
    if len(argv) != 2 or argv[1] not in ("auth", "cleanup"):
        print("usage: selectel-dns-hook.py auth|cleanup", file=sys.stderr)
        return 2
    socket.getaddrinfo = _ipv4_only
    try:
        domain = env("CERTBOT_DOMAIN", required=True)
        value = env("CERTBOT_VALIDATION", required=True)
        name = fqdn("_acme-challenge." + domain)
        client = Selectel()
        zone = client.zone_for(domain)
        if argv[1] == "auth":
            add_value(client, zone["id"], name, value)
            servers = ([s.strip() for s in env("SELECTEL_NAMESERVERS", "").split(",") if s.strip()]
                       or client.nameservers(zone)
                       or DEFAULT_NAMESERVERS.split(","))
            wait_for_value(name, value, servers, int(env("SELECTEL_PROPAGATION_TIMEOUT", "600")), int(env("SELECTEL_NS_PORT", "53")),
                           float(env("SELECTEL_POLL_INTERVAL", "5")))
            print(f"[selectel-dns-hook] {name} visible on all name servers")
        else:
            removed = remove_value(client, zone["id"], name, value)
            print(f"[selectel-dns-hook] {'value removed from' if removed else 'value was not present in'} {name}")
    except HookError as error:
        print(f"[selectel-dns-hook] {argv[1]} failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
