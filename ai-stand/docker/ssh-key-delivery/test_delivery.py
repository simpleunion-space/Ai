"""Tests for delivery.py (standard library only; an optional check uses the local ssh-keygen).

    python -m unittest docker/ssh-key-delivery/test_delivery.py
"""
import base64
import http.client
import importlib.util
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ssh_key_delivery", HERE / "delivery.py")
delivery = importlib.util.module_from_spec(spec)
sys.modules["ssh_key_delivery"] = delivery
spec.loader.exec_module(delivery)
sync = delivery.sync

POSIX = os.name == "posix"


def string(data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + data


def make_private_key(seed: int, *, encrypted: bool = False, key_type: bytes = b"ssh-ed25519", mismatch: bool = False,
                     bad_check: bool = False, crlf: bool = False) -> str:
    public = bytes([seed % 256]) * 32
    public_blob = string(key_type) + string(public)
    if encrypted:
        cipher, kdf, options, section = b"aes256-ctr", b"bcrypt", string(b"s" * 16) + struct.pack(">I", 16), bytes(range(96))
    else:
        cipher, kdf, options = b"none", b"none", b""
        inner_public = bytes([(seed + 1) % 256]) * 32 if mismatch else public
        check = struct.pack(">I", 0x01020304) + struct.pack(">I", 0x01020305 if bad_check else 0x01020304)
        section = check + string(key_type) + string(inner_public) + string(bytes([seed % 256]) * 32 + public) + string(b"test")
        section += bytes(range(1, 1 + (-len(section)) % 8))
    blob = delivery.MAGIC + string(cipher) + string(kdf) + string(options) + struct.pack(">I", 1) + string(public_blob) + string(section)
    body = base64.b64encode(blob).decode()
    lines = [body[i:i + 70] for i in range(0, len(body), 70)]
    text = "\n".join([delivery.BEGIN, *lines, delivery.END]) + "\n"
    return text.replace("\n", "\r\n") if crlf else text


def public_of(seed: int) -> str:
    name = b"ssh-ed25519"
    return "ssh-ed25519 " + base64.b64encode(string(name) + string(bytes([seed % 256]) * 32)).decode()


class ParsePrivateKeyTests(unittest.TestCase):
    def test_plain_key(self):
        parsed = delivery.parse_private_key(make_private_key(7))
        self.assertEqual(parsed["public"], public_of(7))
        self.assertFalse(parsed["encrypted"])
        self.assertTrue(parsed["pem"].startswith(delivery.BEGIN + "\n") and parsed["pem"].endswith(delivery.END + "\n"))

    def test_encrypted_key_is_checked_structurally(self):
        parsed = delivery.parse_private_key(make_private_key(9, encrypted=True))
        self.assertTrue(parsed["encrypted"])
        self.assertEqual(parsed["public"], public_of(9))

    def test_crlf_and_surrounding_whitespace_are_normalised(self):
        plain = delivery.parse_private_key(make_private_key(3))
        messy = delivery.parse_private_key("\n  " + make_private_key(3, crlf=True) + "\n\n")
        self.assertEqual(plain["pem"], messy["pem"])
        self.assertNotIn("\r", messy["pem"])

    def test_rejections(self):
        good = make_private_key(5)
        cases = {
            "empty": "",
            "not a string": None,
            "public key": public_of(5),
            "rsa header": good.replace("OPENSSH", "RSA"),
            "no end": good.replace(delivery.END, ""),
            "bad base64": good.replace("\n", "!\n", 1),
            "wrong key type": make_private_key(5, key_type=b"ssh-rsa"),
            "corrupt check ints": make_private_key(5, bad_check=True),
            "public halves differ": make_private_key(5, mismatch=True),
            "too long": good + "A" * delivery.MAX_PRIVATE_KEY,
        }
        for name, value in cases.items():
            with self.subTest(name), self.assertRaises(sync.SyncError):
                delivery.parse_private_key(value)

    def test_truncated(self):
        lines = make_private_key(5).splitlines()
        shortened = "\n".join([lines[0], lines[1][:40], lines[-1]])
        with self.assertRaises(sync.SyncError):
            delivery.parse_private_key(shortened)

    def test_passphrase(self):
        self.assertIsNone(delivery.parse_passphrase(None))
        self.assertIsNone(delivery.parse_passphrase(""))
        self.assertEqual(delivery.parse_passphrase(" pass phrase "), " pass phrase ")
        for bad in ("a\nb", "a\x00b", "x" * (delivery.MAX_PASSPHRASE + 1), 12):
            with self.subTest(bad), self.assertRaises(sync.SyncError):
                delivery.parse_passphrase(bad)

    @unittest.skipUnless(shutil.which("ssh-keygen"), "ssh-keygen is not installed")
    def test_real_openssh_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            for passphrase in ("", "correct horse"):
                path = Path(tmp) / f"key-{bool(passphrase)}"
                subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", passphrase, "-C", "t", "-f", str(path)], check=True)
                parsed = delivery.parse_private_key(path.read_text())
                expected = Path(str(path) + ".pub")
                self.assertEqual(sync.identity(parsed["public"]), sync.identity(expected.read_text().strip()))
                self.assertEqual(parsed["encrypted"], bool(passphrase))


class StubAuthentik:
    """Answers the list calls desired_state makes: two groups, users filtered by group primary key."""

    GROUPS = {"ai-users": "g1", "ai-admins": "g2"}

    def __init__(self, users):
        self.users = users
        self.paths = []

    def request(self, method, path, body=None):
        self.paths.append(path)
        if path.startswith("/core/groups/"):
            name = path.split("name=", 1)[1].split("&", 1)[0]
            rows = [{"name": name, "pk": self.GROUPS[name]}] if name in self.GROUPS else []
            return {"results": rows, "pagination": {"count": len(rows)}}
        if path.startswith("/core/users/"):
            if "username=" in path:
                wanted = urllib.parse.unquote(path.split("username=", 1)[1].split("&", 1)[0])
                rows = [row for row in self.users if row["username"] == wanted]
            else:
                pk = path.split("groups_by_pk=", 1)[1].split("&", 1)[0]
                rows = [row for row in self.users if pk in row["groups"]]
            return {"results": rows, "pagination": {"count": len(rows)}}
        raise AssertionError(path)


def user(username, *, private=None, passphrase=None, public=None, active=True, in_group=True, groups=None):
    attributes = {}
    if private is not None:
        attributes[delivery.PRIVATE_KEY_ATTRIBUTE] = private
    if passphrase is not None:
        attributes[delivery.PASSPHRASE_ATTRIBUTE] = passphrase
    if public is not None:
        attributes[sync.PUBLIC_KEY_ATTRIBUTE] = public
    member_of = groups if groups is not None else (["g1"] if in_group else [])
    return {"username": username, "is_active": active, "groups": member_of, "attributes": attributes}


class DesiredStateTests(unittest.TestCase):
    def test_statuses(self):
        users = [
            user("alice", private=make_private_key(1), passphrase="pw", public=public_of(1)),
            user("bob", private=make_private_key(2, encrypted=True)),
            user("carol"),
            user("dave", private="oops, not a key"),
            user("erin", private=make_private_key(4), public=public_of(99)),
            user("frank", private=make_private_key(5), active=False),
            user("grace", private=make_private_key(6), in_group=False),
            user("bad.name", private=make_private_key(7)),
        ]
        payload, report = delivery.desired_state(StubAuthentik(users))
        self.assertEqual(payload["members"], ["alice", "bob", "carol", "dave", "erin"])
        self.assertEqual(sorted(payload["keys"]), ["alice", "bob", "erin"])
        self.assertEqual(payload["keys"]["alice"]["passphrase"], "pw")
        self.assertNotIn("passphrase", payload["keys"]["bob"])
        self.assertEqual(payload["keep"], ["dave"])
        self.assertEqual(report, {"alice": "plain", "bob": "encrypted", "carol": "no-key", "dave": "invalid-kept",
                                  "erin": "plain+public-key-differs", "bad.name": "unsupported-username"})

    def test_admins_who_are_not_users_are_members_too_and_nobody_twice(self):
        users = [user("alice", private=make_private_key(1), groups=["g1", "g2"]),
                 user("root-admin", private=make_private_key(2), groups=["g2"])]
        payload, _ = delivery.desired_state(StubAuthentik(users))
        self.assertEqual(payload["members"], ["alice", "root-admin"])
        only_users, _ = delivery.desired_state(StubAuthentik(users), ("ai-users",))
        self.assertEqual(only_users["members"], ["alice"])

    def test_missing_group_is_an_error(self):
        class NoGroup(StubAuthentik):
            def request(self, method, path, body=None):
                return {"results": [], "pagination": {"count": 0}}
        with self.assertRaises(sync.SyncError):
            delivery.desired_state(NoGroup([]))

    def test_groups_setting(self):
        self.assertEqual(delivery.Settings({}).groups, ("ai-users", "ai-admins"))
        self.assertEqual(delivery.Settings({"SYNC_GROUPS": " a , b "}).groups, ("a", "b"))
        for bad in ("", " , ", "x y"):
            with self.subTest(bad), self.assertRaises(sync.SyncError):
                delivery.Settings({"SYNC_GROUPS": bad})

    def test_digest_is_stable_and_sensitive(self):
        first, _ = delivery.desired_state(StubAuthentik([user("alice", private=make_private_key(1))]))
        again, _ = delivery.desired_state(StubAuthentik([user("alice", private=make_private_key(1))]))
        other, _ = delivery.desired_state(StubAuthentik([user("alice", private=make_private_key(2))]))
        self.assertEqual(delivery.digest_of(first), delivery.digest_of(again))
        self.assertNotEqual(delivery.digest_of(first), delivery.digest_of(other))


def payload_for(members, keys=None, keep=None):
    return {"version": 1, "members": members, "keep": keep or [], "keys": keys or {}}


def mode_of(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


@unittest.skipUnless(POSIX, "file modes are checked on POSIX only")
class ApplyPayloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "keys"
        self.addCleanup(self.tmp.cleanup)

    def entry(self, seed, passphrase=None):
        value = {"private": make_private_key(seed)}
        if passphrase is not None:
            value["passphrase"] = passphrase
        return value

    def test_creates_files_with_private_modes(self):
        result = delivery.apply_payload(self.root, payload_for(["alice", "bob"], {"alice": self.entry(1, "pw")}))
        self.assertEqual(result["delivered"], 1)
        directory = self.root / "alice"
        self.assertEqual(mode_of(self.root), 0o700)
        self.assertEqual(mode_of(directory), 0o700)
        for name in delivery.KEY_FILES:
            self.assertEqual(mode_of(directory / name), 0o400, name)
        self.assertEqual((directory / "passphrase").read_text(), "pw")
        self.assertEqual((directory / "id_ed25519.pub").read_text(), public_of(1) + "\n")
        # A member without a key still gets a directory, so the workspace bind mount always has a source.
        self.assertEqual(sorted(os.listdir(self.root / "bob")), [])

    def test_second_apply_changes_nothing_and_keeps_inodes(self):
        payload = payload_for(["alice"], {"alice": self.entry(1)})
        delivery.apply_payload(self.root, payload)
        before = {name: (self.root / "alice" / name).stat().st_ino for name in ("id_ed25519", "id_ed25519.pub")}
        directory_inode = (self.root / "alice").stat().st_ino
        result = delivery.apply_payload(self.root, payload)
        self.assertEqual(result["changed"], 0)
        self.assertEqual(before, {name: (self.root / "alice" / name).stat().st_ino for name in before})
        self.assertEqual(directory_inode, (self.root / "alice").stat().st_ino)

    def test_rotation_keeps_the_directory_inode(self):
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(1)}))
        directory_inode = (self.root / "alice").stat().st_ino
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(2, "new")}))
        self.assertEqual(directory_inode, (self.root / "alice").stat().st_ino)
        self.assertEqual((self.root / "alice" / "id_ed25519.pub").read_text(), public_of(2) + "\n")
        self.assertEqual((self.root / "alice" / "passphrase").read_text(), "new")
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(2)}))
        self.assertFalse((self.root / "alice" / "passphrase").exists())

    def test_keep_leaves_files_alone(self):
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(1)}))
        delivery.apply_payload(self.root, payload_for(["alice"], keep=["alice"]))
        self.assertEqual((self.root / "alice" / "id_ed25519.pub").read_text(), public_of(1) + "\n")

    def test_blank_key_withdraws_files_but_keeps_directory(self):
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(1, "pw")}))
        result = delivery.apply_payload(self.root, payload_for(["alice"]))
        self.assertEqual(result["removed"], 3)
        self.assertTrue((self.root / "alice").is_dir())
        self.assertEqual(os.listdir(self.root / "alice"), [])

    def test_departed_member_is_removed_and_foreign_entries_are_not(self):
        delivery.apply_payload(self.root, payload_for(["alice", "bob"], {"bob": self.entry(2)}))
        (self.root / ".hidden").write_text("x")
        (self.root / "not a login").write_text("x")
        delivery.apply_payload(self.root, payload_for(["alice"]))
        self.assertFalse((self.root / "bob").exists())
        self.assertTrue((self.root / "alice").is_dir())
        self.assertTrue((self.root / ".hidden").exists())
        self.assertTrue((self.root / "not a login").exists())

    def test_stale_temporary_files_are_cleaned(self):
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(1)}))
        stale = self.root / "alice" / ".id_ed25519.tmp"
        stale.write_text("half written")
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(1)}))
        self.assertFalse(stale.exists())

    def test_symlinked_member_directory_is_replaced_not_followed(self):
        target = Path(self.tmp.name) / "elsewhere"
        target.mkdir()
        self.root.mkdir(mode=0o700)
        os.symlink(target, self.root / "alice")
        delivery.apply_payload(self.root, payload_for(["alice"], {"alice": self.entry(1)}))
        self.assertFalse((self.root / "alice").is_symlink())
        self.assertEqual(os.listdir(target), [])

    def test_invalid_payloads_are_rejected_before_anything_is_written(self):
        good = self.entry(1)
        cases = {
            "version": {"version": 2, "members": [], "keys": {}},
            "not a dict": [],
            "bad login": payload_for(["../etc"]),
            "duplicate member": payload_for(["alice", "alice"]),
            "key for non member": payload_for(["alice"], {"bob": good}),
            "keep and key": payload_for(["alice"], {"alice": good}, keep=["alice"]),
            "bad key": payload_for(["alice"], {"alice": {"private": "nope"}}),
            "bad passphrase": payload_for(["alice"], {"alice": {**good, "passphrase": "a\nb"}}),
        }
        for name, payload in cases.items():
            with self.subTest(name), self.assertRaises(sync.SyncError):
                delivery.apply_payload(self.root, payload)
        self.assertFalse(self.root.exists())


class ServerCase(unittest.TestCase):
    """A receiver on a loopback port with a temporary key root and heartbeat file."""

    TOKEN = "delivery-token-0123456789abcdef"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        original_heartbeat = delivery.HEARTBEAT
        delivery.HEARTBEAT = Path(self.tmp.name) / "heartbeat"
        self.addCleanup(setattr, delivery, "HEARTBEAT", original_heartbeat)
        token_file = Path(self.tmp.name) / "token"
        token_file.write_text(self.TOKEN)
        self.root = Path(self.tmp.name) / "keys"
        self.settings = delivery.Settings({
            "KEYS_ROOT": str(self.root), "DELIVERY_TOKEN_FILE": str(token_file), "LISTEN_PORT": "8444",
            "AUTHENTIK_TOKEN_FILE": str(token_file),
        })
        self.server = delivery.make_server(self.settings, "127.0.0.1", 0)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def call(self, method, path, body=None, headers=None, length=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        merged = dict(headers or {})
        if length is not None:
            merged["Content-Length"] = str(length)
        connection.request(method, path, body=data if length is None else None, headers=merged)
        response = connection.getresponse()
        text = response.read()
        connection.close()
        return response.status, text

    def auth(self, token=None):
        return {"Authorization": f"Bearer {token or self.TOKEN}"}


class ReceiverTests(ServerCase):
    def test_healthz_and_unknown_paths(self):
        self.assertEqual(self.call("GET", "/healthz")[0], 200)
        self.assertEqual(self.call("GET", "/v1/keys")[0], 404)
        self.assertEqual(self.call("PUT", "/other", {}, self.auth())[0], 404)

    def test_token_is_required(self):
        payload = payload_for(["alice"])
        self.assertEqual(self.call("PUT", "/v1/keys", payload)[0], 403)
        self.assertEqual(self.call("PUT", "/v1/keys", payload, self.auth("wrong-token-0123456789"))[0], 403)
        self.assertFalse(self.root.exists())

    def test_size_json_and_validation_errors(self):
        self.assertEqual(self.call("PUT", "/v1/keys", None, self.auth(), length=delivery.MAX_BODY + 1)[0], 413)
        self.assertEqual(self.call("PUT", "/v1/keys", b"{not json", self.auth())[0], 400)
        self.assertEqual(self.call("PUT", "/v1/keys", payload_for(["../x"]), self.auth())[0], 422)

    @unittest.skipUnless(POSIX, "file modes are checked on POSIX only")
    def test_accepts_a_payload(self):
        payload = payload_for(["alice"], {"alice": {"private": make_private_key(1)}})
        status, body = self.call("PUT", "/v1/keys", payload, self.auth())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["delivered"], 1)
        self.assertNotIn("BEGIN", body.decode())
        self.assertEqual((self.root / "alice" / "id_ed25519.pub").read_text(), public_of(1) + "\n")

    def test_healthcheck_modes(self):
        self.assertFalse(delivery.healthy("push", self.settings))
        delivery.HEARTBEAT.write_text("1")
        self.assertTrue(delivery.healthy("push", self.settings))
        self.assertFalse(delivery.healthy("push", self.settings, now=delivery.HEARTBEAT.stat().st_mtime + 3600))
        self.settings.port = self.port
        self.assertTrue(delivery.healthy("serve", self.settings))


@unittest.skipUnless(POSIX, "file modes are checked on POSIX only")
class PushTests(ServerCase):
    def test_push_converges_and_only_resends_on_change_or_timeout(self):
        users = [user("alice", private=make_private_key(1)), user("bob")]
        authentik = StubAuthentik(users)
        sent = []

        class Recording(sync.Api):
            def request(inner, method, path, body=None):
                sent.append(body)
                return super().request(method, path, body)

        receiver = Recording("Receiver", f"http://127.0.0.1:{self.port}", "Bearer", Path(self.tmp.name) / "token")
        settings = self.settings
        # push_forever loops; run exactly three passes by stopping the sleep.
        passes = {"count": 0}
        original_sleep = delivery.time.sleep

        def fake_sleep(_):
            passes["count"] += 1
            if passes["count"] == 3:
                raise KeyboardInterrupt
            if passes["count"] == 2:
                users[0] = user("alice", private=make_private_key(2))

        delivery.time.sleep = fake_sleep
        try:
            with self.assertRaises(KeyboardInterrupt):
                delivery.push_forever(settings, authentik=authentik, receiver=receiver)
        finally:
            delivery.time.sleep = original_sleep
        # pass 1 sends, pass 2 sees no change (nothing sent), pass 3 sees the rotated key.
        self.assertEqual(len(sent), 2)
        self.assertEqual((self.root / "alice" / "id_ed25519.pub").read_text(), public_of(2) + "\n")
        self.assertEqual(os.listdir(self.root / "bob"), [])


class ServiceKeyTests(unittest.TestCase):
    def test_parse_service_keys(self):
        self.assertEqual(delivery.parse_service_keys(""), {})
        self.assertEqual(delivery.parse_service_keys(" openclaw = ai-stand-bot , ci=svc.ci@x "),
                         {"openclaw": "ai-stand-bot", "ci": "svc.ci@x"})
        for bad in ("openclaw", "Open=bot", "x=", "=bot", "a=b,a=c", "a=b c", "1a=b"):
            with self.subTest(bad), self.assertRaises(sync.SyncError):
                delivery.parse_service_keys(bad)

    def test_desired_services(self):
        users = [
            user("alice", private=make_private_key(1)),
            user("ai-stand-bot", private=make_private_key(2), groups=[]),
            user("encrypted-bot", private=make_private_key(3, encrypted=True), groups=[]),
            user("broken-bot", private="not a key", groups=[]),
            user("empty-bot", groups=[]),
            user("sleeping-bot", private=make_private_key(5), groups=[], active=False),
        ]
        services = {"openclaw": "ai-stand-bot", "enc": "encrypted-bot", "broken": "broken-bot", "empty": "empty-bot",
                    "sleeping": "sleeping-bot", "ghost": "nobody"}
        payload, report = delivery.desired_state(StubAuthentik(users), services=services)
        self.assertEqual(payload["serviceNames"], sorted(services))
        self.assertEqual(sorted(payload["services"]), ["openclaw"])
        self.assertEqual(payload["serviceKeep"], ["broken", "enc"])
        self.assertNotIn("passphrase", payload["services"]["openclaw"])
        self.assertEqual({k: v for k, v in report.items() if k.startswith("service:")}, {
            "service:openclaw": "plain", "service:enc": "invalid-kept", "service:broken": "invalid-kept",
            "service:empty": "no-key", "service:sleeping": "account-missing-or-inactive",
            "service:ghost": "account-missing-or-inactive"})
        # People are unaffected by services, and without services the payload has no service fields.
        self.assertEqual(payload["members"], ["alice"])
        plain, _ = delivery.desired_state(StubAuthentik(users))
        self.assertNotIn("serviceNames", plain)

    def test_a_service_is_not_picked_up_as_a_person(self):
        users = [user("ai-stand-bot", private=make_private_key(2), groups=[])]
        payload, _ = delivery.desired_state(StubAuthentik(users), services={"openclaw": "ai-stand-bot"})
        self.assertEqual(payload["members"], [])


@unittest.skipUnless(POSIX, "file modes are checked on POSIX only")
class ServiceApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.users = Path(self.tmp.name) / "users"
        self.services = Path(self.tmp.name) / "services"

    def payload(self, services=None, names=("openclaw",), keep=(), members=("alice",)):
        value = {"version": 1, "members": list(members), "keep": [], "keys": {}}
        if names is not None:
            value.update({"serviceNames": list(names), "serviceKeep": list(keep), "services": services or {}})
        return value

    def test_service_keys_land_in_their_own_tree_with_private_modes(self):
        result = delivery.apply_payload(self.users, self.payload({"openclaw": {"private": make_private_key(1)}}),
                                        self.services, ("openclaw",))
        self.assertEqual(result["services"], 1)
        directory = self.services / "openclaw"
        self.assertEqual(mode_of(self.services), 0o700)
        self.assertEqual(mode_of(directory), 0o700)
        self.assertEqual(mode_of(directory / "id_ed25519"), 0o400)
        self.assertEqual((directory / "id_ed25519.pub").read_text(), public_of(1) + "\n")
        self.assertFalse((directory / "passphrase").exists())
        self.assertEqual(os.listdir(self.users), ["alice"])

    def test_withdrawal_keep_and_departure(self):
        delivery.apply_payload(self.users, self.payload({"openclaw": {"private": make_private_key(1)}}, ("openclaw", "ci")),
                               self.services, ("openclaw", "ci"))
        delivery.apply_payload(self.users, self.payload({}, ("openclaw", "ci"), keep=("openclaw",)), self.services, ("openclaw", "ci"))
        self.assertTrue((self.services / "openclaw" / "id_ed25519").exists())
        delivery.apply_payload(self.users, self.payload({}, ("openclaw", "ci")), self.services, ("openclaw", "ci"))
        self.assertEqual(os.listdir(self.services / "openclaw"), [])
        (self.services / "README").write_text("foreign")
        delivery.apply_payload(self.users, self.payload({}, ("openclaw",)), self.services, ("openclaw", "ci"))
        self.assertFalse((self.services / "ci").exists())
        self.assertTrue((self.services / "README").exists())

    def test_rejections(self):
        key = {"private": make_private_key(1)}
        cases = {
            "not configured here": (self.payload({"openclaw": key}), ()),
            "name not allowed": (self.payload({"openclaw": key}), ("other",)),
            "bad name": (self.payload({}, ("Open",)), ("Open",)),
            "encrypted": (self.payload({"openclaw": {"private": make_private_key(1, encrypted=True)}}), ("openclaw",)),
            "passphrase": (self.payload({"openclaw": {**key, "passphrase": "x"}}), ("openclaw",)),
            "key for unlisted name": (self.payload({"ci": key}), ("openclaw", "ci")),
            "garbage key": (self.payload({"openclaw": {"private": "nope"}}), ("openclaw",)),
        }
        for name, (payload, allowed) in cases.items():
            with self.subTest(name), self.assertRaises(sync.SyncError):
                delivery.apply_payload(self.users, payload, self.services, allowed)
        self.assertFalse(self.services.exists())

    def test_no_service_fields_leave_the_service_tree_alone(self):
        delivery.apply_payload(self.users, self.payload({"openclaw": {"private": make_private_key(1)}}), self.services, ("openclaw",))
        delivery.apply_payload(self.users, self.payload(names=None), self.services, ("openclaw",))
        self.assertTrue((self.services / "openclaw" / "id_ed25519").exists())

    def test_settings(self):
        defaults = delivery.Settings({})
        self.assertEqual((defaults.service_keys, defaults.service_names), ({}, ()))
        configured = delivery.Settings({"SERVICE_KEYS": "openclaw=bot", "SERVICE_NAMES": "openclaw, ci", "SERVICE_KEYS_ROOT": "/x"})
        self.assertEqual((configured.service_keys, configured.service_names, configured.service_root),
                         ({"openclaw": "bot"}, ("ci", "openclaw"), Path("/x")))
        with self.assertRaises(sync.SyncError):
            delivery.Settings({"SERVICE_NAMES": "Bad Name"})


if __name__ == "__main__":
    unittest.main()
