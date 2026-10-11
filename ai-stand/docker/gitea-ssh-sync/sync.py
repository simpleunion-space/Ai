#!/usr/bin/env python3
"""Keep each ai-users member's personal SSH public key registered in Gitea.

The source of truth is the Authentik user attribute ``ai_stand_git_ssh_public_key``.
Every minute the service compares it with the keys of the member's Gitea account
and converges them. Only keys whose title is ``ai-stand personal SSH <login>``
(optionally followed by `` [<fingerprint>]``) are ever created or deleted, so keys
a user added to Gitea by hand are never touched.

The Gitea account of a member is found through the OIDC link, never by name alone:
Gitea stores the Authentik subject (the user's UUID) as the account's ``login_name``,
and the account is used only when its login also equals the Authentik username.
Local Gitea accounts (no link) are invisible to this service.

An unusable attribute value (a typo, a private key pasted by mistake) is reported
and leaves the key already registered in Gitea alone; a blank attribute, a disabled
account or a member removed from ai-users withdraws the managed key.

Besides people the service can keep the key of a **service account** (a bot such as the OpenClaw Gateway's) registered:
the Authentik service account (type ``service_account``) and a LOCAL Gitea account carry the same name, the key is the
account's ``ai_stand_git_ssh_public_key`` attribute, and the same rules apply (titles, rotation, withdrawal). Which names
is decided by SERVICE_ACCOUNTS; the Gitea account itself is created by apply.sh, never by this service.

Credentials arrive as files (Docker secrets). Nothing secret is logged: API error
bodies are dropped and only status codes are reported.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import signal
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

PUBLIC_KEY_ATTRIBUTE = "ai_stand_git_ssh_public_key"
GROUP_NAME = "ai-users"
TITLE_PREFIX = "ai-stand personal SSH "
HEARTBEAT = Path("/tmp/gitea-ssh-sync.heartbeat")

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
LOGIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SECRET = re.compile(r"^[A-Za-z0-9_.=-]{16,512}$")
MAX_BODY = 4 * 1024 * 1024
MAX_PUBLIC_KEY = 2048
MAX_USERS = 500


class SyncError(RuntimeError):
    """A failure whose message is safe to log; ``status`` is the HTTP status, when there was one."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def need(condition: Any, message: str) -> None:
    if not condition:
        raise SyncError(message)


# --- configuration -----------------------------------------------------------------------------------------------------

class Settings:
    def __init__(self, environ: dict[str, str] | None = None):
        env = os.environ if environ is None else environ
        self.authentik_url = env.get("AUTHENTIK_URL", "http://authentik:9000").rstrip("/")
        self.gitea_url = env.get("GITEA_URL", "http://gitea:3000").rstrip("/")
        self.authentik_token_file = Path(env.get("AUTHENTIK_TOKEN_FILE", "/run/secrets/ai-stand-gitea-ssh-sync-authentik-token"))
        self.gitea_token_file = Path(env.get("GITEA_TOKEN_FILE", "/run/secrets/ai-stand-gitea-ssh-sync-gitea-token"))
        source = env.get("GITEA_AUTH_SOURCE_ID", "").strip()
        need(source == "" or (source.isdigit() and int(source) > 0), "GITEA_AUTH_SOURCE_ID must be a positive integer")
        self.auth_source_id = int(source) if source else None
        interval = env.get("SYNC_INTERVAL_SECONDS", "60").strip()
        need(interval.isdigit() and 10 <= int(interval) <= 3600, "SYNC_INTERVAL_SECONDS must be 10..3600")
        self.interval = int(interval)
        # Writing to Gitea is opt-in: an unset or unknown value only plans.
        self.apply = env.get("SYNC_APPLY", "0").strip() == "1"
        # Service accounts: the same name in Authentik (a service account) and in Gitea (a local account).
        self.service_accounts = tuple(sorted({name for name in (part.strip() for part in env.get("SERVICE_ACCOUNTS", "").split(",")) if name}))
        need(all(LOGIN.fullmatch(name) for name in self.service_accounts), "SERVICE_ACCOUNTS must be a comma-separated list of account names")
        for url in (self.authentik_url, self.gitea_url):
            need(re.fullmatch(r"https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?", url) is not None, "service URLs must be http(s)://host[:port]")


def read_secret(path: Path) -> str:
    try:
        value = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        raise SyncError(f"credential file {path.name} is unavailable") from None
    need(SECRET.fullmatch(value) is not None, f"credential file {path.name} is empty or malformed")
    return value


# --- HTTP --------------------------------------------------------------------------------------------------------------

class Api:
    def __init__(self, name: str, base: str, scheme: str, token_file: Path, timeout: int = 15):
        self.name, self.base, self.scheme, self.token_file, self.timeout = name, base, scheme, token_file, timeout

    def request(self, method: str, path: str, body: Any = None) -> Any:
        headers = {"Accept": "application/json", "Authorization": f"{self.scheme} {read_secret(self.token_file)}"}
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":"), allow_nan=False).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        shown = path.split("?", 1)[0]
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read(MAX_BODY + 1)
        except urllib.error.HTTPError as error:
            raise SyncError(f"{self.name} {method} {shown} failed with HTTP {error.code}", error.code) from None
        except (OSError, ValueError):
            raise SyncError(f"{self.name} {method} {shown} is unreachable") from None
        need(len(payload) <= MAX_BODY, f"{self.name} response exceeds the size limit")
        if not payload:
            return None
        try:
            return json.loads(payload)
        except ValueError:
            raise SyncError(f"{self.name} {method} {shown} returned invalid JSON") from None


def authentik_list(api: Api, path: str) -> list[dict]:
    rows: list[dict] = []
    for page in range(1, 101):
        result = api.request("GET", f"{path}{'&' if '?' in path else '?'}page={page}&page_size=100")
        need(isinstance(result, dict) and isinstance(result.get("results"), list), "Authentik list response is invalid")
        rows.extend(row for row in result["results"] if isinstance(row, dict))
        count = (result.get("pagination") or {}).get("count", len(rows))
        if not result["results"] or not isinstance(count, int) or len(rows) >= count:
            return rows
    raise SyncError("Authentik list exceeded the page bound")


def gitea_list(api: Api, path: str) -> list[dict]:
    rows: list[dict] = []
    for page in range(1, 201):
        result = api.request("GET", f"{path}{'&' if '?' in path else '?'}page={page}&limit=50")
        need(isinstance(result, list) and all(isinstance(row, dict) for row in result), "Gitea list response is invalid")
        rows.extend(result)
        if len(result) < 50:
            return rows
    raise SyncError("Gitea list exceeded the page bound")


# --- SSH public keys ---------------------------------------------------------------------------------------------------

def parse_public_key(value: Any) -> str:
    """Return ``ssh-ed25519 <base64>`` for a valid single-line Ed25519 public key, else raise SyncError."""
    need(isinstance(value, str) and 0 < len(value) <= MAX_PUBLIC_KEY, "public key is empty or too long")
    lines = [line for line in value.strip().splitlines() if line.strip()]
    need(len(lines) == 1, "public key must be a single line")
    parts = lines[0].split()
    need(len(parts) >= 2 and parts[0] == "ssh-ed25519", "only ssh-ed25519 public keys are accepted")
    try:
        blob = base64.b64decode(parts[1], validate=True)
    except ValueError:
        raise SyncError("public key is not valid base64") from None
    # RFC 4253 wire format: string "ssh-ed25519", string <32-byte key>.
    name = b"ssh-ed25519"
    expected = struct.pack(">I", len(name)) + name + struct.pack(">I", 32)
    need(len(blob) == len(expected) + 32 and blob.startswith(expected), "public key is not a well-formed Ed25519 key")
    return f"ssh-ed25519 {parts[1]}"


def fingerprint(key: str) -> str:
    blob = base64.b64decode(key.split()[1], validate=True)
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def identity(key: str) -> tuple[str, str]:
    parts = str(key).split()
    return (parts[0], parts[1]) if len(parts) >= 2 else ("", "")


def owned_title(title: str, base: str) -> bool:
    return title == base or title.startswith(base + " [")


# --- Authentik side ----------------------------------------------------------------------------------------------------

def public_key_state(raw: Any) -> tuple[str | None, str]:
    """``(key, state)`` of the attribute value; ``state`` is present, absent or invalid."""
    if raw is None or (isinstance(raw, str) and not raw.strip()):
        return None, "absent"
    if isinstance(raw, str):
        try:
            return parse_public_key(raw), "present"
        except SyncError:
            return None, "invalid"
    return None, "invalid"


def authentik_service_account(api: Api, username: str) -> dict | None:
    """``{active, state, key}`` of the named Authentik service account, or None when there is no such account."""
    rows = [row for row in authentik_list(api, "/core/users/?username=" + urllib.parse.quote(username))
            if row.get("username") == username]
    # A person with the same name is not a service account: never act on it.
    if len(rows) != 1 or rows[0].get("type") != "service_account":
        return None
    attributes = rows[0].get("attributes") if isinstance(rows[0].get("attributes"), dict) else {}
    key, state = public_key_state(attributes.get(PUBLIC_KEY_ATTRIBUTE))
    return {"active": rows[0].get("is_active") is True, "state": state, "key": key}


def authentik_members(api: Api) -> dict[str, dict]:
    """uuid -> {username, active, state, key}; ``state`` is present, absent or invalid."""
    groups = authentik_list(api, "/core/groups/?name=" + urllib.parse.quote(GROUP_NAME))
    matches = [row for row in groups if row.get("name") == GROUP_NAME and row.get("pk") is not None]
    need(len(matches) == 1, f"Authentik group {GROUP_NAME} is missing or ambiguous")
    group_pk = str(matches[0]["pk"])
    members: dict[str, dict] = {}
    for row in authentik_list(api, "/core/users/?groups_by_pk=" + urllib.parse.quote(group_pk)):
        uuid = str(row.get("uuid", "")).lower()
        username = row.get("username")
        # Membership is checked again: serializers can be configured to omit related objects.
        in_group = group_pk in {str(item) for item in row.get("groups", [])}
        if not UUID.fullmatch(uuid) or not isinstance(username, str) or not in_group:
            continue
        attributes = row.get("attributes") if isinstance(row.get("attributes"), dict) else {}
        key, state = public_key_state(attributes.get(PUBLIC_KEY_ATTRIBUTE))
        members[uuid] = {"username": username, "active": row.get("is_active") is True, "state": state, "key": key}
    return members


# --- Gitea side --------------------------------------------------------------------------------------------------------

def gitea_linked_users(api: Api, source_id: int | None) -> list[dict]:
    """Gitea accounts created by the Authentik OIDC source: ``login_name`` is the Authentik subject (a UUID)."""
    path = "/admin/users" + (f"?source_id={source_id}" if source_id else "")
    users = []
    for row in gitea_list(api, path):
        subject = str(row.get("login_name", "")).lower()
        login = row.get("login")
        linked = isinstance(row.get("source_id"), int) and row["source_id"] > 0
        if UUID.fullmatch(subject) and linked and isinstance(login, str) and LOGIN.fullmatch(login) \
                and (source_id is None or row["source_id"] == source_id):
            users.append({"login": login, "subject": subject})
    need(len(users) <= MAX_USERS, "too many linked Gitea accounts")
    return users


def user_keys(api: Api, login: str) -> list[dict]:
    keys = gitea_list(api, f"/users/{urllib.parse.quote(login)}/keys")
    need(all(isinstance(row.get("id"), int) and isinstance(row.get("key"), str) and isinstance(row.get("title"), str)
             for row in keys), "Gitea key list contains an invalid entry")
    return keys


def plan_user(keys: list[dict], base: str, kind: str, desired: str | None) -> dict:
    """Decide what to do for one account; ``kind`` is present, absent or invalid."""
    managed = [row for row in keys if owned_title(row["title"], base)]
    if kind == "invalid":
        return {"action": "keep-invalid-value", "managed": managed}
    if kind == "absent" or desired is None:
        return {"action": "remove-managed" if managed else "no-key", "managed": managed}
    wanted = identity(desired)
    if any(identity(row["key"]) == wanted and not owned_title(row["title"], base) for row in keys):
        return {"action": "refused-unmanaged-duplicate", "managed": managed}
    exact = [row for row in managed if identity(row["key"]) == wanted]
    if exact:
        if len(exact) == 1 and len(managed) == 1:
            return {"action": "verified", "managed": managed}
        return {"action": "clean-obsolete-managed", "managed": managed}
    return {"action": "rotate" if managed else "add", "managed": managed}


def apply_user(api: Api, login: str, base: str, desired: str | None, plan: dict) -> None:
    quoted = urllib.parse.quote(login)
    action = plan["action"]
    if action == "remove-managed":
        for row in plan["managed"]:
            api.request("DELETE", f"/admin/users/{quoted}/keys/{row['id']}")
        return
    if action in ("add", "rotate", "clean-obsolete-managed"):
        wanted = identity(desired)
        if action != "clean-obsolete-managed":
            title = f"{base} [{fingerprint(desired)}]"
            need(len(title) <= 180, "managed key title is too long")
            api.request("POST", f"/admin/users/{quoted}/keys", {"title": title, "key": desired, "read_only": False})
        refreshed = user_keys(api, login)
        current = [row for row in refreshed if owned_title(row["title"], base) and identity(row["key"]) == wanted]
        need(len(current) >= 1, "the registered key did not verify under its exact owner")
        keep = current[0]["id"]
        for row in refreshed:
            if owned_title(row["title"], base) and row["id"] != keep:
                api.request("DELETE", f"/admin/users/{quoted}/keys/{row['id']}")
        final = [row for row in user_keys(api, login) if owned_title(row["title"], base)]
        need(len(final) == 1 and identity(final[0]["key"]) == wanted, "the final managed key verification failed")


# --- one reconciliation pass -------------------------------------------------------------------------------------------

def converge(settings: Settings, gitea: Api, login: str, kind: str, desired: str | None, entry: dict) -> None:
    """Plan (and, when applying, do) what one Gitea account's managed key needs; fills ``entry``."""
    base = TITLE_PREFIX + login.lower()
    plan = plan_user(user_keys(gitea, login), base, kind, desired)
    entry["status"] = plan["action"]
    if desired:
        entry["fingerprint"] = fingerprint(desired)
    if settings.apply and plan["action"] not in ("verified", "no-key", "keep-invalid-value", "refused-unmanaged-duplicate"):
        apply_user(gitea, login, base, desired, plan)
        entry["applied"] = True


def run_once(settings: Settings, authentik: Api, gitea: Api) -> dict:
    members = authentik_members(authentik)
    accounts = gitea_linked_users(gitea, settings.auth_source_id)
    results = []
    linked = set()
    for account in accounts:
        login, subject = account["login"], account["subject"]
        linked.add(subject)
        member = members.get(subject)
        entry: dict[str, Any] = {"login": login}
        try:
            if member is not None and member["username"].lower() != login.lower():
                # The same subject under another name: never act on an ambiguous identity.
                entry["status"] = "refused-identity-mismatch"
                results.append(entry)
                continue
            usable = member is not None and member["active"]
            converge(settings, gitea, login, member["state"] if usable else "absent", member["key"] if usable else None, entry)
        except SyncError as error:
            entry["status"] = "error"
            entry["error"] = str(error)
        results.append(entry)
    if settings.service_accounts:
        # Only LOCAL Gitea accounts (no authentication source): an account linked to a person is never a service account.
        local = {row["login"].lower() for row in gitea_list(gitea, "/admin/users")
                 if isinstance(row.get("login"), str) and not row.get("source_id")}
        for name in settings.service_accounts:
            entry = {"login": name, "kind": "service"}
            try:
                if name.lower() not in local:
                    entry["status"] = "waiting-for-gitea-account"
                else:
                    account = authentik_service_account(authentik, name)
                    usable = account is not None and account["active"]
                    converge(settings, gitea, name, account["state"] if usable else "absent", account["key"] if usable else None, entry)
            except SyncError as error:
                entry["status"] = "error"
                entry["error"] = str(error)
            results.append(entry)
    # Members without a linked Gitea account yet are reported, not created: the account appears at first sign-in.
    waiting = sum(1 for subject, row in members.items() if subject not in linked and row["state"] == "present")
    return {"mode": "apply" if settings.apply else "plan", "accounts": results, "waitingForFirstGiteaSignIn": waiting}


def log(event: dict) -> None:
    print(json.dumps(event, sort_keys=True, separators=(",", ":")), flush=True)


def healthy(interval: int, now: float | None = None) -> bool:
    try:
        age = (time.time() if now is None else now) - HEARTBEAT.stat().st_mtime
    except OSError:
        return False
    return age <= max(180, 3 * interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="run a single pass and exit")
    parser.add_argument("--healthcheck", action="store_true", help="exit 0 when a pass succeeded recently")
    args = parser.parse_args(argv)
    try:
        settings = Settings()
    except SyncError as error:
        print(f"configuration refused: {error}", file=sys.stderr)
        return 2
    if args.healthcheck:
        return 0 if healthy(settings.interval) else 1
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    authentik = Api("Authentik", settings.authentik_url + "/api/v3", "Bearer", settings.authentik_token_file)
    gitea = Api("Gitea", settings.gitea_url + "/api/v1", "token", settings.gitea_token_file)
    while True:
        failed = True
        try:
            result = run_once(settings, authentik, gitea)
            HEARTBEAT.write_text(str(int(time.time())), encoding="ascii")
            log({"event": "sync", **result})
            failed = False
        except SyncError as error:
            log({"event": "sync-failed", "error": str(error)})
        except Exception as error:  # a bug must not turn into a crash loop that hides the cause
            log({"event": "sync-failed", "error": type(error).__name__})
        if args.once:
            return 1 if failed else 0
        time.sleep(settings.interval)


if __name__ == "__main__":
    raise SystemExit(main())
