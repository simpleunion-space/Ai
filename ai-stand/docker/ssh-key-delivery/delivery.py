#!/usr/bin/env python3
"""Deliver each ai-users member's personal SSH private key from Authentik to the Coder host.

Two modes, both stdlib-only and sharing the HTTP helpers of docker/gitea-ssh-sync/sync.py:

``push`` (ai01, where the Authentik reader credential lives) reads the members of ``ai-users``
every minute, validates the Authentik attribute ``ai_stand_git_ssh_private_key`` (and the optional
``ai_stand_git_ssh_passphrase``) and sends the desired set to the receiver.

``serve`` (the Coder node) accepts ``PUT /v1/keys`` with a bearer token and keeps one directory per
member under KEYS_ROOT: ``<login>/id_ed25519``, ``id_ed25519.pub`` and, when a passphrase is set,
``passphrase``. The Coder templates bind-mount exactly the owner's directory read-only into the
workspace, so a workspace never sees another member's key. The receiver has no Authentik
credential and re-validates everything it is sent.

Besides people the same pipeline can deliver the dedicated key of a service (SERVICE_KEYS on the sender, SERVICE_NAMES on
the receiver): an Authentik account that is not a person holds the key in the same attribute, and the receiver keeps it in
its own tree (SERVICE_KEYS_ROOT, ``<name>/id_ed25519``) for a service to mount. Service keys must not be encrypted.

Only OpenSSH ``ssh-ed25519`` keys are accepted, matching the public-key synchronizer. A value that
does not parse leaves the delivered key alone (reported as ``invalid-kept``); a blank attribute, a
disabled account or a member removed from ai-users withdraws it. Nothing secret is logged.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import signal
import struct
import sys
import textwrap
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
# In the image sync.py sits next to this file; in a checkout it is the sibling module.
for candidate in (HERE, HERE.parent / "gitea-ssh-sync"):
    if (candidate / "sync.py").is_file():
        sys.path.insert(0, str(candidate))
        break
import sync  # noqa: E402
from sync import Api, SyncError, authentik_list, need, parse_public_key, read_secret  # noqa: E402

PRIVATE_KEY_ATTRIBUTE = "ai_stand_git_ssh_private_key"
PASSPHRASE_ATTRIBUTE = "ai_stand_git_ssh_passphrase"
HEARTBEAT = Path("/tmp/ssh-key-delivery.heartbeat")
# Coder usernames: what the templates put in the path, so the directory name must be exactly this.
USERNAME = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,30}[A-Za-z0-9])?$")
SERVICE_NAME = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
BEGIN = "-----BEGIN OPENSSH PRIVATE KEY-----"
END = "-----END OPENSSH PRIVATE KEY-----"
MAGIC = b"openssh-key-v1\0"
MAX_PRIVATE_KEY = 8192
MAX_PASSPHRASE = 1024
MAX_USERS = 500
MAX_BODY = 4 * 1024 * 1024
KEY_FILES = ("id_ed25519", "id_ed25519.pub", "passphrase")
PROTOCOL = 1


# --- OpenSSH private keys ----------------------------------------------------------------------------------------------

def take(blob: bytes, offset: int) -> tuple[bytes, int]:
    """One RFC 4251 ``string``: a big-endian length and that many bytes."""
    need(offset + 4 <= len(blob), "private key is truncated")
    (length,) = struct.unpack(">I", blob[offset:offset + 4])
    need(offset + 4 + length <= len(blob), "private key is truncated")
    return blob[offset + 4:offset + 4 + length], offset + 4 + length


def parse_private_key(value: Any) -> dict:
    """Validate an OpenSSH Ed25519 private key and return ``{pem, public, encrypted}``.

    An unencrypted key is checked completely (check integers, matching public half); an encrypted one
    can only be checked structurally because its private section needs the passphrase.
    """
    need(isinstance(value, str) and 0 < len(value) <= MAX_PRIVATE_KEY, "private key is empty or too long")
    lines = [line.strip() for line in value.strip().splitlines()]
    need(len(lines) >= 3 and lines[0] == BEGIN and lines[-1] == END, "private key must be an OpenSSH private key")
    body = "".join(lines[1:-1])
    need(re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", body) is not None, "private key is not valid base64")
    try:
        blob = base64.b64decode(body, validate=True)
    except ValueError:
        raise SyncError("private key is not valid base64") from None
    need(blob.startswith(MAGIC), "private key is not in the OpenSSH format")
    cipher, offset = take(blob, len(MAGIC))
    kdf, offset = take(blob, offset)
    _, offset = take(blob, offset)
    need(offset + 4 <= len(blob) and struct.unpack(">I", blob[offset:offset + 4])[0] == 1, "private key must hold one key")
    public_blob, offset = take(blob, offset + 4)
    section, offset = take(blob, offset)
    key_type, inner = take(public_blob, 0)
    public_key, inner = take(public_blob, inner)
    need(key_type == b"ssh-ed25519" and len(public_key) == 32 and inner == len(public_blob),
         "only ssh-ed25519 private keys are accepted")
    encrypted = cipher != b"none"
    if encrypted:
        need(kdf == b"bcrypt" and len(section) >= 16, "private key uses an unsupported encryption")
    else:
        need(kdf == b"none" and offset == len(blob), "private key is malformed")
        need(len(section) >= 8 and section[:4] == section[4:8], "private key check failed (corrupt or truncated)")
        inner_type, at = take(section, 8)
        inner_public, at = take(section, at)
        secret, at = take(section, at)
        need(inner_type == b"ssh-ed25519" and inner_public == public_key and len(secret) == 64
             and secret[32:] == public_key, "private key does not match its public half")
    wrapped = "\n".join(textwrap.wrap(body, 70))
    return {
        "pem": f"{BEGIN}\n{wrapped}\n{END}\n",
        "public": "ssh-ed25519 " + base64.b64encode(public_blob).decode(),
        "encrypted": encrypted,
    }


def parse_passphrase(value: Any) -> str | None:
    if value is None or (isinstance(value, str) and value == ""):
        return None
    need(isinstance(value, str) and len(value) <= MAX_PASSPHRASE, "passphrase is too long")
    need(re.search(r"[\x00-\x1f\x7f]", value) is None, "passphrase contains control characters")
    return value


# --- configuration -----------------------------------------------------------------------------------------------------

def parse_service_keys(raw: str) -> dict[str, str]:
    """``name=username[,name=username]`` -> {name: Authentik username}."""
    result: dict[str, str] = {}
    for part in (item.strip() for item in raw.split(",")):
        if not part:
            continue
        name, _, username = (piece.strip() for piece in part.partition("="))
        need(SERVICE_NAME.fullmatch(name) is not None and re.fullmatch(r"[A-Za-z0-9._@-]{1,150}", username) is not None,
             "SERVICE_KEYS must be name=username[,name=username]")
        need(name not in result, "SERVICE_KEYS repeats a name")
        result[name] = username
    return result


class Settings:
    def __init__(self, environ: dict[str, str] | None = None):
        env = os.environ if environ is None else environ
        self.authentik_url = env.get("AUTHENTIK_URL", "http://authentik:9000").rstrip("/")
        self.authentik_token_file = Path(env.get("AUTHENTIK_TOKEN_FILE", "/run/secrets/ai-stand-ssh-key-delivery-authentik-token"))
        self.delivery_url = env.get("DELIVERY_URL", "http://ssh-key-receiver:8444").rstrip("/")
        self.delivery_token_file = Path(env.get("DELIVERY_TOKEN_FILE", "/run/secrets/ai-stand-ssh-key-delivery-token"))
        self.keys_root = Path(env.get("KEYS_ROOT", "/srv/user-ssh-keys"))
        port = env.get("LISTEN_PORT", "8444").strip()
        need(port.isdigit() and 1 <= int(port) <= 65535, "LISTEN_PORT must be a port number")
        self.port = int(port)
        interval = env.get("SYNC_INTERVAL_SECONDS", "60").strip()
        need(interval.isdigit() and 10 <= int(interval) <= 3600, "SYNC_INTERVAL_SECONDS must be 10..3600")
        self.interval = int(interval)
        # Everyone who can sign in to Coder has a key directory: the managed templates mount it, and a bind mount fails
        # when its source is missing.
        self.groups = tuple(name for name in (part.strip() for part in env.get("SYNC_GROUPS", "ai-users,ai-admins").split(",")) if name)
        need(self.groups and all(re.fullmatch(r"[A-Za-z0-9._-]{1,64}", name) for name in self.groups), "SYNC_GROUPS is invalid")
        resend = env.get("RESEND_SECONDS", "600").strip()
        need(resend.isdigit() and 60 <= int(resend) <= 86400, "RESEND_SECONDS must be 60..86400")
        self.resend = int(resend)
        # Keys of services rather than people. The sender reads them from the named Authentik accounts; the receiver accepts
        # only the names it is configured for and keeps them in a tree of their own.
        self.service_keys = parse_service_keys(env.get("SERVICE_KEYS", ""))
        self.service_names = tuple(sorted({name for name in (part.strip() for part in env.get("SERVICE_NAMES", "").split(",")) if name}))
        need(all(SERVICE_NAME.fullmatch(name) for name in self.service_names), "SERVICE_NAMES is invalid")
        self.service_root = Path(env.get("SERVICE_KEYS_ROOT", "/srv/service-ssh-keys"))
        for url in (self.authentik_url, self.delivery_url):
            need(re.fullmatch(r"https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?", url) is not None, "service URLs must be http(s)://host[:port]")


# --- Authentik side (push) ---------------------------------------------------------------------------------------------

def group_members(api: Api, name: str) -> list[dict]:
    groups = authentik_list(api, "/core/groups/?name=" + urllib.parse.quote(name))
    matches = [row for row in groups if row.get("name") == name and row.get("pk") is not None]
    need(len(matches) == 1, f"Authentik group {name} is missing or ambiguous")
    group_pk = str(matches[0]["pk"])
    rows = authentik_list(api, "/core/users/?groups_by_pk=" + urllib.parse.quote(group_pk))
    # Membership is checked again: serializers can be configured to omit related objects.
    return [row for row in rows if group_pk in {str(item) for item in row.get("groups", [])}]


def key_entry(attributes: dict, allow_encrypted: bool = True) -> tuple[str, dict | None, dict | None]:
    """``(status, entry, parsed)``: status is none, invalid or ok; ``entry`` is what the receiver is sent."""
    raw = attributes.get(PRIVATE_KEY_ATTRIBUTE)
    if raw is None or (isinstance(raw, str) and not raw.strip()):
        return "none", None, None
    try:
        parsed = parse_private_key(raw)
        need(allow_encrypted or not parsed["encrypted"], "service keys must not be encrypted")
        passphrase = parse_passphrase(attributes.get(PASSPHRASE_ATTRIBUTE)) if allow_encrypted else None
    except SyncError:
        return "invalid", None, None
    entry: dict[str, Any] = {"private": parsed["pem"]}
    if passphrase is not None:
        entry["passphrase"] = passphrase
    return "ok", entry, parsed


def desired_services(api: Api, services: dict[str, str], report: dict[str, str]) -> dict:
    """The service part of the payload: one entry per configured name, from the named Authentik account."""
    keep: list[str] = []
    keys: dict[str, dict] = {}
    for name, username in sorted(services.items()):
        label = "service:" + name
        rows = [row for row in authentik_list(api, "/core/users/?username=" + urllib.parse.quote(username))
                if row.get("username") == username]
        if len(rows) != 1 or rows[0].get("is_active") is not True:
            report[label] = "account-missing-or-inactive"
            continue
        attributes = rows[0].get("attributes") if isinstance(rows[0].get("attributes"), dict) else {}
        status, entry, _ = key_entry(attributes, allow_encrypted=False)
        if status == "invalid":
            keep.append(name)
            report[label] = "invalid-kept"
        elif status == "none":
            report[label] = "no-key"
        else:
            keys[name] = entry
            report[label] = "plain"
    return {"serviceNames": sorted(services), "serviceKeep": keep, "services": keys}


def desired_state(api: Api, groups: tuple[str, ...] = ("ai-users", "ai-admins"),
                  services: dict[str, str] | None = None) -> tuple[dict, dict]:
    """Return ``(payload, report)``: what the receiver should hold, and one status word per member."""
    users: dict[str, dict] = {}
    for name in groups:
        for row in group_members(api, name):
            if isinstance(row.get("username"), str):
                users.setdefault(row["username"], row)
    members: list[str] = []
    keep: list[str] = []
    keys: dict[str, dict] = {}
    report: dict[str, str] = {}
    for username, row in sorted(users.items()):
        if row.get("is_active") is not True:
            continue
        if USERNAME.fullmatch(username) is None:
            report[username] = "unsupported-username"
            continue
        members.append(username)
        attributes = row.get("attributes") if isinstance(row.get("attributes"), dict) else {}
        status, entry, parsed = key_entry(attributes)
        if status == "none":
            report[username] = "no-key"
            continue
        if status == "invalid":
            keep.append(username)
            report[username] = "invalid-kept"
            continue
        keys[username] = entry
        report[username] = "encrypted" if parsed["encrypted"] else "plain"
        registered = attributes.get(sync.PUBLIC_KEY_ATTRIBUTE)
        if isinstance(registered, str) and registered.strip():
            try:
                if sync.identity(parse_public_key(registered)) != sync.identity(parsed["public"]):
                    report[username] += "+public-key-differs"
            except SyncError:
                pass
    need(len(members) <= MAX_USERS, "too many members")
    payload: dict[str, Any] = {"version": PROTOCOL, "members": members, "keep": keep, "keys": keys}
    if services:
        payload.update(desired_services(api, services, report))
    return payload, report


def digest_of(payload: dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


# --- receiver side (serve) ---------------------------------------------------------------------------------------------

def write_file(path: Path, data: bytes, mode: int) -> bool:
    """Atomically replace ``path`` (same directory); return False when it already held exactly this."""
    try:
        if not path.is_symlink() and path.read_bytes() == data and (path.stat().st_mode & 0o777) == mode:
            return False
    except OSError:
        pass
    temporary = path.with_name("." + path.name + ".tmp")
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise
    return True


def member_directory(root: Path, login: str) -> Path:
    path = root / login
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        path.unlink()
    if not path.exists():
        path.mkdir(mode=0o700)
    os.chmod(path, 0o700)
    return path


def validate_services(payload: dict, allowed: tuple[str, ...]) -> dict | None:
    """The optional service part; ``None`` when the sender sends none."""
    names = payload.get("serviceNames")
    if names is None:
        return None
    keep, keys = payload.get("serviceKeep", []), payload.get("services", {})
    need(isinstance(names, list) and isinstance(keep, list) and isinstance(keys, dict), "malformed service payload")
    need(allowed, "this receiver accepts no service keys")
    need(len(set(names)) == len(names) and set(names) <= set(allowed), "service names are not accepted here")
    for name in names + keep + list(keys):
        need(isinstance(name, str) and SERVICE_NAME.fullmatch(name) is not None, "invalid service name in payload")
    need(set(keep) <= set(names) and set(keys) <= set(names) and not (set(keep) & set(keys)), "inconsistent service payload")
    checked: dict[str, dict] = {}
    for name, entry in keys.items():
        need(isinstance(entry, dict) and "passphrase" not in entry, "malformed service key entry")
        parsed = parse_private_key(entry.get("private"))
        need(not parsed["encrypted"], "service keys must not be encrypted")
        checked[name] = {"parsed": parsed, "passphrase": None}
    return {"names": list(names), "keep": list(keep), "keys": checked}


def validate_payload(payload: Any, allowed_services: tuple[str, ...] = ()) -> dict:
    need(isinstance(payload, dict) and payload.get("version") == PROTOCOL, "unsupported payload")
    members, keep, keys = payload.get("members"), payload.get("keep", []), payload.get("keys")
    need(isinstance(members, list) and isinstance(keep, list) and isinstance(keys, dict), "malformed payload")
    need(len(members) <= MAX_USERS and len(set(members)) == len(members), "invalid member list")
    for login in members + keep + list(keys):
        need(isinstance(login, str) and USERNAME.fullmatch(login) is not None, "invalid login in payload")
    need(set(keep) <= set(members) and set(keys) <= set(members) and not (set(keep) & set(keys)), "inconsistent payload")
    checked: dict[str, dict] = {}
    for login, entry in keys.items():
        need(isinstance(entry, dict), "malformed key entry")
        parsed = parse_private_key(entry.get("private"))
        checked[login] = {"parsed": parsed, "passphrase": parse_passphrase(entry.get("passphrase"))}
    return {"members": list(members), "keep": list(keep), "keys": checked,
            "services": validate_services(payload, allowed_services)}


def apply_tree(root: Path, names: list[str], keep: list[str], keys: dict[str, dict], pattern: re.Pattern) -> tuple[int, int]:
    """Make ``root`` hold one directory per name with exactly that name's key files; return (changed, removed)."""
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    changed = removed = 0
    for login in names:
        directory = member_directory(root, login)
        for stale in directory.glob(".*.tmp"):
            stale.unlink()
        if login in keep:
            continue
        entry = keys.get(login)
        if entry is None:
            for name in KEY_FILES:
                if (directory / name).exists() or (directory / name).is_symlink():
                    (directory / name).unlink()
                    removed += 1
            continue
        changed += write_file(directory / "id_ed25519", entry["parsed"]["pem"].encode(), 0o400)
        changed += write_file(directory / "id_ed25519.pub", (entry["parsed"]["public"] + "\n").encode(), 0o400)
        passphrase_file = directory / "passphrase"
        if entry["passphrase"] is None:
            if passphrase_file.exists() or passphrase_file.is_symlink():
                passphrase_file.unlink()
                removed += 1
        else:
            changed += write_file(passphrase_file, entry["passphrase"].encode(), 0o400)
    # Departed names: only entries that look like such directories, never anything else in the root.
    for entry in os.scandir(root):
        if pattern.fullmatch(entry.name) is None or entry.name in names:
            continue
        if entry.is_dir(follow_symlinks=False):
            shutil.rmtree(entry.path)
        else:
            os.unlink(entry.path)
        removed += 1
    return changed, removed


def apply_payload(root: Path, payload: Any, service_root: Path | None = None,
                  allowed_services: tuple[str, ...] = ()) -> dict:
    """Make the trees hold exactly the delivered keys; return counts. Untrusted input: validated first."""
    checked = validate_payload(payload, allowed_services)
    changed, removed = apply_tree(root, checked["members"], checked["keep"], checked["keys"], USERNAME)
    result = {"members": len(checked["members"]), "delivered": len(checked["keys"])}
    services = checked["services"]
    if services is not None:
        need(service_root is not None, "this receiver has no service key tree")
        more_changed, more_removed = apply_tree(service_root, services["names"], services["keep"], services["keys"], SERVICE_NAME)
        changed, removed = changed + more_changed, removed + more_removed
        result["services"] = len(services["keys"])
    result.update({"changed": changed, "removed": removed})
    return result


def log(event: dict) -> None:
    print(json.dumps(event, sort_keys=True, separators=(",", ":")), flush=True)


def make_server(settings: Settings, host: str = "0.0.0.0", port: int | None = None) -> ThreadingHTTPServer:
    token = read_secret(settings.delivery_token_file)
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        server_version = "ssh-key-receiver"
        sys_version = ""

        def log_message(self, *_: Any) -> None:  # request lines can carry nothing secret, but stay quiet
            return

        def reply(self, status: int, body: dict) -> None:
            data = json.dumps(body, sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            if self.path == "/healthz":
                self.reply(200, {"status": "ok"})
            else:
                self.reply(404, {"error": "not found"})

        def do_PUT(self) -> None:
            if self.path != "/v1/keys":
                return self.reply(404, {"error": "not found"})
            given = self.headers.get("Authorization", "")
            if not hmac.compare_digest(given.encode(), f"Bearer {token}".encode()):
                return self.reply(403, {"error": "forbidden"})
            length = self.headers.get("Content-Length", "")
            if not length.isdigit():
                return self.reply(411, {"error": "length required"})
            if int(length) > MAX_BODY:
                return self.reply(413, {"error": "payload too large"})
            raw = self.rfile.read(int(length))
            try:
                payload = json.loads(raw)
            except ValueError:
                return self.reply(400, {"error": "invalid JSON"})
            try:
                with lock:
                    result = apply_payload(settings.keys_root, payload, settings.service_root, settings.service_names)
            except SyncError as error:
                log({"event": "rejected", "reason": str(error)})
                return self.reply(422, {"error": str(error)})
            except OSError as error:
                log({"event": "write-failed", "error": type(error).__name__})
                return self.reply(500, {"error": "write failed"})
            log({"event": "keys", **result})
            self.reply(200, {"status": "ok", **result})

    return ThreadingHTTPServer((host, settings.port if port is None else port), Handler)


# --- entry points ------------------------------------------------------------------------------------------------------

def healthy(mode: str, settings: Settings, now: float | None = None) -> bool:
    if mode == "serve":
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{settings.port}/healthz", timeout=5) as response:
                return response.status == 200
        except (OSError, ValueError):
            return False
    try:
        age = (time.time() if now is None else now) - HEARTBEAT.stat().st_mtime
    except OSError:
        return False
    return age <= max(180, 3 * settings.interval)


def push_forever(settings: Settings, once: bool = False, authentik: Api | None = None, receiver: Api | None = None) -> int:
    authentik = authentik or Api("Authentik", settings.authentik_url + "/api/v3", "Bearer", settings.authentik_token_file)
    receiver = receiver or Api("Receiver", settings.delivery_url, "Bearer", settings.delivery_token_file)
    last_digest, last_sent = "", 0.0
    while True:
        failed = True
        try:
            payload, report = desired_state(authentik, settings.groups, settings.service_keys)
            digest = digest_of(payload)
            sent = False
            if digest != last_digest or time.time() - last_sent >= settings.resend:
                receiver.request("PUT", "/v1/keys", payload)
                last_digest, last_sent, sent = digest, time.time(), True
            HEARTBEAT.write_text(str(int(time.time())), encoding="ascii")
            log({"event": "push", "sent": sent, "members": report})
            failed = False
        except SyncError as error:
            log({"event": "push-failed", "error": str(error)})
        except Exception as error:  # a bug must not turn into a crash loop that hides the cause
            log({"event": "push-failed", "error": type(error).__name__})
        if once:
            return 1 if failed else 0
        time.sleep(settings.interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("push", "serve", "healthcheck"))
    parser.add_argument("--for", dest="target", choices=("push", "serve"), default="push", help="healthcheck: which mode")
    parser.add_argument("--once", action="store_true", help="push: run a single pass and exit")
    args = parser.parse_args(argv)
    try:
        settings = Settings()
    except SyncError as error:
        print(f"configuration refused: {error}", file=sys.stderr)
        return 2
    if args.mode == "healthcheck":
        return 0 if healthy(args.target, settings) else 1
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if args.mode == "push":
        return push_forever(settings, args.once)
    try:
        server = make_server(settings)
    except SyncError as error:
        print(f"configuration refused: {error}", file=sys.stderr)
        return 2
    log({"event": "receiving", "port": settings.port})
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
