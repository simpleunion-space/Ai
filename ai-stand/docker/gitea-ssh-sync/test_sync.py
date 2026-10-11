"""Tests for sync.py against in-process fake Authentik and Gitea servers (standard library only).

    python -m unittest docker/gitea-ssh-sync/test_sync.py
"""
import base64
import importlib.util
import json
import struct
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

spec = importlib.util.spec_from_file_location("gitea_ssh_sync", Path(__file__).resolve().with_name("sync.py"))
sync = importlib.util.module_from_spec(spec)
sys.modules["gitea_ssh_sync"] = sync
spec.loader.exec_module(sync)

AK_TOKEN = "authentik-token-0123456789abcdef"
GITEA_TOKEN = "gitea-token-0123456789abcdef"


def make_key(seed: int, comment: str = "") -> str:
    name = b"ssh-ed25519"
    blob = struct.pack(">I", len(name)) + name + struct.pack(">I", 32) + bytes([seed % 256]) * 32
    return "ssh-ed25519 " + base64.b64encode(blob).decode() + (" " + comment if comment else "")


def uuid_for(n: int) -> str:
    return "00000000-0000-0000-0000-%012d" % n


class World:
    """The state both fake services share, plus a log of every mutating Gitea call."""

    def __init__(self):
        self.group_pk = "g1"
        self.members = []          # Authentik users
        self.accounts = []         # Gitea users
        self.keys = {}             # login -> [key dict]
        self.next_id = 100
        self.writes = []           # (method, login, detail)
        self.queries = []          # raw request paths
        self.fail_keys_for = set() # logins whose key listing answers HTTP 500
        self.service_users = []    # Authentik users that are looked up by name (service accounts and a person of that name)
        self.bad_auth = []

    def member(self, n, username, key=..., active=True, in_group=True, attributes=None):
        attrs = dict(attributes or {})
        if key is not ...:
            attrs[sync.PUBLIC_KEY_ATTRIBUTE] = key
        self.members.append({"pk": n, "uuid": uuid_for(n), "username": username, "is_active": active,
                             "groups": [self.group_pk] if in_group else [], "attributes": attrs})

    def account(self, n, login, source_id=1, login_name=...):
        self.accounts.append({"id": n, "login": login, "source_id": source_id,
                              "login_name": uuid_for(n) if login_name is ... else login_name})
        self.keys.setdefault(login, [])

    def add_key(self, login, key, title, read_only=False):
        self.next_id += 1
        self.keys[login].append({"id": self.next_id, "key": key, "title": title, "read_only": read_only})
        return self.next_id


def handler_for(world: World):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, value=None):
            raw = b"" if value is None else json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def route(self, method):
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            world.queries.append(self.path)
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length)) if length else None
            auth = self.headers.get("Authorization")
            parts = [urllib.parse.unquote(p) for p in url.path.strip("/").split("/")]
            if parts[:2] == ["api", "v3"]:
                if auth != "Bearer " + AK_TOKEN:
                    world.bad_auth.append(auth); return self.reply(401)
                return self.authentik(method, parts[2:], query)
            if parts[:2] == ["api", "v1"]:
                if auth != "token " + GITEA_TOKEN:
                    world.bad_auth.append(auth); return self.reply(401)
                return self.gitea(method, parts[2:], query, body)
            return self.reply(404)

        def page(self, rows, query, size_key):
            number, size = int(query["page"][0]), int(query[size_key][0])
            return rows[(number - 1) * size: number * size]

        def authentik(self, method, parts, query):
            if parts == ["core", "groups"]:
                rows = [{"pk": world.group_pk, "name": "ai-users"}] if query.get("name") == ["ai-users"] else []
                return self.reply(200, {"pagination": {"count": len(rows)}, "results": self.page(rows, query, "page_size")})
            if parts == ["core", "users"] and "username" in query:
                rows = [r for r in world.service_users if r["username"] == query["username"][0]]
                return self.reply(200, {"pagination": {"count": len(rows)}, "results": self.page(rows, query, "page_size")})
            if parts == ["core", "users"] and query.get("groups_by_pk") == [world.group_pk]:
                rows = world.members
                return self.reply(200, {"pagination": {"count": len(rows)}, "results": self.page(rows, query, "page_size")})
            return self.reply(404)

        def gitea(self, method, parts, query, body):
            if parts == ["admin", "users"] and method == "GET":
                rows = world.accounts
                if "source_id" in query:
                    rows = [r for r in rows if r["source_id"] == int(query["source_id"][0])]
                return self.reply(200, self.page(rows, query, "limit"))
            if len(parts) == 3 and parts[0] == "users" and parts[2] == "keys" and method == "GET":
                if parts[1] in world.fail_keys_for:
                    return self.reply(500)
                return self.reply(200, self.page(world.keys.get(parts[1], []), query, "limit"))
            if len(parts) == 4 and parts[:2] == ["admin", "users"] and parts[3] == "keys" and method == "POST":
                login = parts[2]
                for other, rows in world.keys.items():
                    if any(sync.identity(r["key"]) == sync.identity(body["key"]) for r in rows):
                        return self.reply(422)
                world.writes.append(("POST", login, body["title"]))
                new_id = world.add_key(login, body["key"], body["title"], body["read_only"])
                return self.reply(201, {"id": new_id})
            if len(parts) == 5 and parts[:2] == ["admin", "users"] and parts[3] == "keys" and method == "DELETE":
                login, key_id = parts[2], int(parts[4])
                world.writes.append(("DELETE", login, key_id))
                world.keys[login] = [r for r in world.keys[login] if r["id"] != key_id]
                return self.reply(204)
            return self.reply(404)

        def do_GET(self): self.route("GET")
        def do_POST(self): self.route("POST")
        def do_DELETE(self): self.route("DELETE")

    return Handler


class SyncTestCase(unittest.TestCase):
    def setUp(self):
        self.world = World()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(self.world))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        directory = Path(self.tmp.name)
        (directory / "ak").write_text(AK_TOKEN)
        (directory / "gitea").write_text(GITEA_TOKEN)
        self.directory = directory

    def run_sync(self, apply=True, **extra):
        port = self.server.server_address[1]
        env = {"AUTHENTIK_URL": f"http://127.0.0.1:{port}", "GITEA_URL": f"http://127.0.0.1:{port}",
               "AUTHENTIK_TOKEN_FILE": str(self.directory / "ak"), "GITEA_TOKEN_FILE": str(self.directory / "gitea"),
               "SYNC_APPLY": "1" if apply else "0", **extra}
        settings = sync.Settings(env)
        return sync.run_once(settings,
                             sync.Api("Authentik", settings.authentik_url + "/api/v3", "Bearer", settings.authentik_token_file),
                             sync.Api("Gitea", settings.gitea_url + "/api/v1", "token", settings.gitea_token_file))

    def statuses(self, result):
        return {row["login"]: row["status"] for row in result["accounts"]}

    def titles(self, login):
        return sorted(row["title"] for row in self.world.keys[login])


class KeyParsingTests(unittest.TestCase):
    def test_accepts_plain_and_commented_keys(self):
        key = make_key(1)
        self.assertEqual(sync.parse_public_key(key), key)
        self.assertEqual(sync.parse_public_key("  " + make_key(1, "me@host") + "\n"), key)

    def test_rejects_everything_else(self):
        good = make_key(1)
        blob = good.split()[1]
        for bad in ("", "   ", None, 5, ["x"], "ssh-rsa " + blob, "ssh-ed25519", "ssh-ed25519 !!!notbase64!!!",
                    "ssh-ed25519 " + blob[:-8], good + "\n" + make_key(2), "-----BEGIN OPENSSH PRIVATE KEY-----\nabc",
                    "ssh-ed25519 " + base64.b64encode(b"short").decode(), "x" * 5000):
            with self.assertRaises(sync.SyncError, msg=repr(bad)):
                sync.parse_public_key(bad)

    def test_fingerprint_is_openssh_style(self):
        self.assertRegex(sync.fingerprint(make_key(3)), r"^SHA256:[A-Za-z0-9+/]{43}$")

    def test_title_ownership(self):
        base = "ai-stand personal SSH bob"
        self.assertTrue(sync.owned_title(base, base))
        self.assertTrue(sync.owned_title(base + " [SHA256:abc]", base))
        self.assertFalse(sync.owned_title(base + "x", base))
        self.assertFalse(sync.owned_title("my laptop", base))


class SettingsTests(unittest.TestCase):
    def test_defaults_plan_only(self):
        settings = sync.Settings({})
        self.assertFalse(settings.apply)
        self.assertEqual(settings.interval, 60)

    def test_validation(self):
        for env in ({"SYNC_INTERVAL_SECONDS": "5"}, {"SYNC_INTERVAL_SECONDS": "x"}, {"GITEA_AUTH_SOURCE_ID": "0"},
                    {"GITEA_AUTH_SOURCE_ID": "a"}, {"GITEA_URL": "ftp://gitea"}, {"AUTHENTIK_URL": "http://a/b"}):
            with self.assertRaises(sync.SyncError, msg=str(env)):
                sync.Settings(env)

    def test_missing_or_malformed_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(sync.SyncError):
                sync.read_secret(Path(directory) / "none")
            path = Path(directory) / "bad"
            path.write_text("short")
            with self.assertRaises(sync.SyncError) as caught:
                sync.read_secret(path)
            self.assertNotIn("short", str(caught.exception))


class ReconcileTests(SyncTestCase):
    def test_adds_a_missing_key_once(self):
        key = make_key(1, "laptop")
        self.world.member(1, "alice", key)
        self.world.account(1, "alice")
        result = self.run_sync()
        self.assertEqual(self.statuses(result), {"alice": "add"})
        self.assertEqual(len(self.world.keys["alice"]), 1)
        title = self.world.keys["alice"][0]["title"]
        self.assertEqual(title, "ai-stand personal SSH alice [" + sync.fingerprint(sync.parse_public_key(key)) + "]")
        # The comment is dropped; the second pass finds nothing to do.
        self.assertEqual(self.world.keys["alice"][0]["key"], sync.parse_public_key(key))
        self.world.writes.clear()
        self.assertEqual(self.statuses(self.run_sync()), {"alice": "verified"})
        self.assertEqual(self.world.writes, [])

    def test_existing_key_titled_as_before_is_recognised(self):
        key = sync.parse_public_key(make_key(1))
        self.world.member(1, "alice", key)
        self.world.account(1, "alice")
        self.world.add_key("alice", key + " comment", "ai-stand personal SSH alice [SHA256:old]")
        self.assertEqual(self.statuses(self.run_sync()), {"alice": "verified"})
        self.assertEqual(self.world.writes, [])

    def test_rotation_adds_before_it_deletes(self):
        self.world.member(1, "alice", make_key(2))
        self.world.account(1, "alice")
        self.world.add_key("alice", make_key(1), "ai-stand personal SSH alice [SHA256:old]")
        self.assertEqual(self.statuses(self.run_sync()), {"alice": "rotate"})
        self.assertEqual([w[0] for w in self.world.writes], ["POST", "DELETE"])
        self.assertEqual(len(self.world.keys["alice"]), 1)
        self.assertEqual(sync.identity(self.world.keys["alice"][0]["key"]), sync.identity(make_key(2)))

    def test_obsolete_duplicates_are_cleaned(self):
        key = make_key(1)
        self.world.member(1, "alice", key)
        self.world.account(1, "alice")
        self.world.add_key("alice", key, "ai-stand personal SSH alice [SHA256:a]")
        self.world.add_key("alice", make_key(9), "ai-stand personal SSH alice [SHA256:b]")
        self.assertEqual(self.statuses(self.run_sync()), {"alice": "clean-obsolete-managed"})
        self.assertEqual(len(self.world.keys["alice"]), 1)
        self.assertEqual(sync.identity(self.world.keys["alice"][0]["key"]), sync.identity(key))

    def test_users_own_keys_are_never_touched(self):
        self.world.member(1, "alice", make_key(2))
        self.world.account(1, "alice")
        own = self.world.add_key("alice", make_key(7), "my laptop")
        self.world.add_key("alice", make_key(1), "ai-stand personal SSH alice [SHA256:old]")
        self.run_sync()
        self.assertIn(own, [row["id"] for row in self.world.keys["alice"]])
        # ...and withdrawal leaves them too.
        self.world.members[0]["attributes"][sync.PUBLIC_KEY_ATTRIBUTE] = ""
        self.run_sync()
        self.assertEqual(self.titles("alice"), ["my laptop"])

    def test_blank_attribute_withdraws_the_managed_key(self):
        for blank in ("", "   \n", None):
            world = self.world
            world.members.clear(); world.keys.clear(); world.accounts.clear(); world.writes.clear()
            world.member(1, "alice", blank)
            world.account(1, "alice")
            world.add_key("alice", make_key(1), "ai-stand personal SSH alice [SHA256:old]")
            self.assertEqual(self.statuses(self.run_sync()), {"alice": "remove-managed"}, repr(blank))
            self.assertEqual(world.keys["alice"], [])

    def test_missing_attribute_withdraws_too(self):
        self.world.member(1, "alice")
        self.world.account(1, "alice")
        self.world.add_key("alice", make_key(1), "ai-stand personal SSH alice")
        self.assertEqual(self.statuses(self.run_sync()), {"alice": "remove-managed"})

    def test_disabled_or_removed_members_are_withdrawn(self):
        self.world.member(1, "alice", make_key(1), active=False)
        self.world.member(2, "bob", make_key(2), in_group=False)
        for n, login in ((1, "alice"), (2, "bob"), (3, "carol")):    # carol is not in Authentik at all
            self.world.account(n, login)
            self.world.add_key(login, make_key(n), f"ai-stand personal SSH {login}")
        self.assertEqual(self.statuses(self.run_sync()),
                         {"alice": "remove-managed", "bob": "remove-managed", "carol": "remove-managed"})
        self.assertTrue(all(self.world.keys[login] == [] for login in ("alice", "bob", "carol")))

    def test_unusable_values_leave_the_registered_key_alone(self):
        registered = make_key(1)
        for bad in ("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----", "ssh-rsa AAAA", 42,
                    make_key(1) + "\n" + make_key(2)):
            world = self.world
            world.members.clear(); world.keys.clear(); world.accounts.clear(); world.writes.clear()
            world.member(1, "alice", bad)
            world.account(1, "alice")
            world.add_key("alice", registered, "ai-stand personal SSH alice [SHA256:old]")
            self.assertEqual(self.statuses(self.run_sync()), {"alice": "keep-invalid-value"}, repr(bad)[:40])
            self.assertEqual(world.writes, [])

    def test_a_key_the_user_registered_by_hand_is_not_adopted(self):
        key = make_key(1)
        self.world.member(1, "alice", key)
        self.world.account(1, "alice")
        self.world.add_key("alice", key, "my laptop")
        self.assertEqual(self.statuses(self.run_sync()), {"alice": "refused-unmanaged-duplicate"})
        self.assertEqual(self.world.writes, [])

    def test_identity_must_match_by_subject_and_name(self):
        self.world.member(1, "alice", make_key(1))
        self.world.account(1, "mallory")               # linked to alice's subject under another name
        self.assertEqual(self.statuses(self.run_sync()), {"mallory": "refused-identity-mismatch"})
        self.assertEqual(self.world.writes, [])

    def test_local_accounts_are_invisible(self):
        self.world.member(1, "simpleunion", make_key(1))
        self.world.account(2, "simpleunion", source_id=0, login_name="")
        self.world.account(3, "other", source_id=0, login_name=uuid_for(1))    # not linked: source 0
        self.world.add_key("simpleunion", make_key(5), "ai-stand personal SSH simpleunion")
        result = self.run_sync()
        self.assertEqual(result["accounts"], [])
        self.assertEqual(self.world.writes, [])

    def test_plan_mode_never_writes(self):
        self.world.member(1, "alice", make_key(1))
        self.world.member(2, "bob", "")
        self.world.account(1, "alice")
        self.world.account(2, "bob")
        self.world.add_key("bob", make_key(4), "ai-stand personal SSH bob")
        result = self.run_sync(apply=False)
        self.assertEqual(result["mode"], "plan")
        self.assertEqual(self.statuses(result), {"alice": "add", "bob": "remove-managed"})
        self.assertEqual(self.world.writes, [])

    def test_source_id_filter(self):
        self.world.member(1, "alice", make_key(1))
        self.world.member(2, "bob", make_key(2))
        self.world.account(1, "alice", source_id=1)
        self.world.account(2, "bob", source_id=2)
        result = self.run_sync(GITEA_AUTH_SOURCE_ID="1")
        self.assertEqual(self.statuses(result), {"alice": "add"})
        self.assertTrue(any("source_id=1" in q for q in self.world.queries))

    def test_pagination_covers_every_member_and_account(self):
        for n in range(1, 131):
            self.world.member(n, f"user{n}", make_key(n))
            self.world.account(n, f"user{n}")
        result = self.run_sync()
        self.assertEqual(len(result["accounts"]), 130)
        self.assertEqual(sum(len(rows) for rows in self.world.keys.values()), 130)

    def test_one_failing_account_does_not_block_the_others(self):
        self.world.member(1, "alice", make_key(1))
        self.world.member(2, "bob", make_key(2))
        self.world.account(1, "alice")
        self.world.account(2, "bob")
        self.world.fail_keys_for.add("alice")
        result = self.run_sync()
        statuses = self.statuses(result)
        self.assertEqual(statuses["alice"], "error")
        self.assertEqual(statuses["bob"], "add")
        alice = next(row for row in result["accounts"] if row["login"] == "alice")
        self.assertIn("HTTP 500", alice["error"])

    def test_rejected_add_keeps_the_old_key(self):
        shared = make_key(5)
        self.world.member(1, "alice", shared)
        self.world.member(2, "bob", make_key(2))
        self.world.account(1, "alice")
        self.world.account(2, "bob")
        self.world.add_key("bob", shared, "ai-stand personal SSH bob [SHA256:x]")   # same key already owned by bob
        old = self.world.add_key("alice", make_key(1), "ai-stand personal SSH alice [SHA256:old]")
        statuses = self.statuses(self.run_sync())
        self.assertEqual(statuses["alice"], "error")
        self.assertIn(old, [row["id"] for row in self.world.keys["alice"]])

    def test_members_without_a_gitea_account_are_counted_not_created(self):
        self.world.member(1, "newbie", make_key(1))
        result = self.run_sync()
        self.assertEqual(result["accounts"], [])
        self.assertEqual(result["waitingForFirstGiteaSignIn"], 1)

    def test_credentials_are_sent_as_the_right_scheme_and_failures_do_not_leak_them(self):
        self.world.member(1, "alice", make_key(1))
        self.world.account(1, "alice")
        self.run_sync()
        self.assertEqual(self.world.bad_auth, [])
        (self.directory / "ak").write_text("wrong-token-0123456789abcdef")
        with self.assertRaises(sync.SyncError) as caught:
            self.run_sync()
        self.assertIn("HTTP 401", str(caught.exception))
        self.assertNotIn("wrong-token", str(caught.exception))

    def test_unreachable_service_is_a_clean_error(self):
        settings = sync.Settings({"GITEA_URL": "http://127.0.0.1:9", "AUTHENTIK_TOKEN_FILE": str(self.directory / "ak"),
                                  "GITEA_TOKEN_FILE": str(self.directory / "gitea")})
        api = sync.Api("Gitea", settings.gitea_url + "/api/v1", "token", settings.gitea_token_file, timeout=2)
        with self.assertRaises(sync.SyncError) as caught:
            api.request("GET", "/user")
        self.assertIn("unreachable", str(caught.exception))


class HealthTests(unittest.TestCase):
    def test_heartbeat_age(self):
        with tempfile.TemporaryDirectory() as directory:
            original = sync.HEARTBEAT
            sync.HEARTBEAT = Path(directory) / "beat"
            try:
                self.assertFalse(sync.healthy(60))
                sync.HEARTBEAT.write_text("1")
                now = sync.HEARTBEAT.stat().st_mtime
                self.assertTrue(sync.healthy(60, now=now + 100))
                self.assertFalse(sync.healthy(60, now=now + 400))
                self.assertTrue(sync.healthy(600, now=now + 1500))
            finally:
                sync.HEARTBEAT = original


class ServiceAccountTests(SyncTestCase):
    NAME = "ai-stand-bot"

    def service(self, key=..., active=True, kind="service_account", attributes=None):
        attrs = dict(attributes or {})
        if key is not ...:
            attrs[sync.PUBLIC_KEY_ATTRIBUTE] = key
        self.world.service_users.append({"pk": 900, "uuid": uuid_for(900), "username": self.NAME, "is_active": active,
                                         "type": kind, "groups": [], "attributes": attrs})

    def sync_services(self, **extra):
        return self.run_sync(SERVICE_ACCOUNTS=self.NAME, **extra)

    def test_registers_the_key_of_a_service_account_with_a_local_gitea_account(self):
        key = make_key(5)
        self.service(key)
        self.world.account(50, self.NAME, source_id=0)
        result = self.sync_services()
        self.assertEqual(self.statuses(result), {self.NAME: "add"})
        self.assertEqual(result["accounts"][0]["kind"], "service")
        self.assertEqual(self.titles(self.NAME), ["ai-stand personal SSH " + self.NAME + " [" + sync.fingerprint(key) + "]"])
        self.world.writes.clear()
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "verified"})
        self.assertEqual(self.world.writes, [])

    def test_waits_for_the_gitea_account(self):
        self.service(make_key(5))
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "waiting-for-gitea-account"})
        self.assertEqual(self.world.writes, [])

    def test_an_account_linked_to_a_person_is_not_a_service_account(self):
        self.service(make_key(5))
        self.world.account(50, self.NAME, source_id=1)
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "waiting-for-gitea-account"})
        self.assertEqual(self.world.writes, [])

    def test_a_person_of_that_name_in_authentik_is_ignored(self):
        self.service(make_key(5), kind="internal")
        self.world.account(50, self.NAME, source_id=0)
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "no-key"})
        self.assertEqual(self.world.writes, [])

    def test_rotation_withdrawal_and_invalid_values(self):
        self.world.account(50, self.NAME, source_id=0)
        self.world.add_key(self.NAME, make_key(1), "ai-stand personal SSH " + self.NAME + " [SHA256:old]")
        self.service(make_key(2))
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "rotate"})
        self.assertEqual(sync.identity(self.world.keys[self.NAME][0]["key"]), sync.identity(make_key(2)))
        self.world.service_users.clear()
        self.service("a typo, not a key")
        self.world.writes.clear()
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "keep-invalid-value"})
        self.assertEqual(self.world.writes, [])
        self.world.service_users.clear()
        self.service("")
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "remove-managed"})
        self.assertEqual(self.world.keys[self.NAME], [])

    def test_an_inactive_or_missing_account_withdraws_the_key(self):
        self.world.account(50, self.NAME, source_id=0)
        self.world.add_key(self.NAME, make_key(1), "ai-stand personal SSH " + self.NAME + " [SHA256:old]")
        self.service(make_key(1), active=False)
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "remove-managed"})
        self.world.add_key(self.NAME, make_key(1), "ai-stand personal SSH " + self.NAME + " [SHA256:old]")
        self.world.service_users.clear()
        self.assertEqual(self.statuses(self.sync_services()), {self.NAME: "remove-managed"})

    def test_people_and_services_are_handled_together(self):
        self.world.member(1, "alice", make_key(1))
        self.world.account(1, "alice")
        self.service(make_key(5))
        self.world.account(50, self.NAME, source_id=0)
        self.assertEqual(self.statuses(self.sync_services()), {"alice": "add", self.NAME: "add"})

    def test_services_are_not_touched_unless_configured(self):
        self.service(make_key(5))
        self.world.account(50, self.NAME, source_id=0)
        self.assertEqual(self.statuses(self.run_sync()), {})

    def test_settings(self):
        self.assertEqual(sync.Settings({}).service_accounts, ())
        self.assertEqual(sync.Settings({"SERVICE_ACCOUNTS": " b-bot , a-bot,a-bot"}).service_accounts, ("a-bot", "b-bot"))
        for bad in ("x y", "../x", "-x"):
            with self.assertRaises(sync.SyncError, msg=bad):
                sync.Settings({"SERVICE_ACCOUNTS": bad})


if __name__ == "__main__":
    unittest.main()
