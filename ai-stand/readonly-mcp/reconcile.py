#!/usr/bin/env python3
"""Reconcile Authentik-attribute-backed, per-user read-only MCP services on ai01.

This program is intentionally a host-only control-plane component.  It never
prints credential values, bearer values, IMAP credentials, HTTP response
bodies or the configuration document.  The manifest it writes contains only
subjects, stable service names and Docker Secret names/versions.

Credentials live only in each user's own Authentik profile attributes
(edited by the user through a self-service prompt stage - see configure.mjs),
never in this repository, the manifest, or any rendered Compose/configuration
file. Credentials are deliberately kept in the authenticated user's profile
attributes: the reconciler already has to trust that identity control plane,
so adding a second secret store would only widen the operational boundary.
"""

from __future__ import annotations

import argparse
import base64
import calendar
import contextlib
import fcntl
import hashlib
import imaplib
import json
import os
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any


SUBJECT = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
SAFE_SLUG = re.compile(r"^[a-z][a-z0-9-]{0,48}$")
SECRET_NAME = re.compile(r"^ai-stand-mcp-[a-z0-9-]{3,100}$")
MCP_KINDS = ("jira", "confluence", "imap")
# Telegram user ids of the people allowed to talk to the OpenClaw bot (OPENCLAW_TELEGRAM_ALLOW_FROM). Numeric ids of
# people only: a @username can be taken over, a group id is negative.
TELEGRAM_ATTRIBUTE = "ai_stand_telegram_user_id"
TELEGRAM_ID = re.compile(r"^[1-9][0-9]{4,14}$")
# The Telegram groups of the OpenClaw bot live in the attributes of one account, the Telegram owner (akadmin unless
# authentik.telegramOwner says otherwise): that account's own ai_stand_telegram_user_id is the bot's owner, and
# ai_stand_telegram_groups lists the groups, an object {"<group id>": {"requireMention": true, "topics": {"<topic id>":
# "<agent id>"}}}. The people allowed to write in them are the ordinary ai_stand_telegram_user_id of the ai-users members.
TELEGRAM_GROUPS_ATTRIBUTE = "ai_stand_telegram_groups"
TELEGRAM_GROUP_ID = re.compile(r"^-[1-9][0-9]{4,19}$")
TELEGRAM_TOPIC_ID = re.compile(r"^(?:[1-9][0-9]{0,9}|\*)$")
TELEGRAM_AGENT_ID = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
TELEGRAM_MAX_GROUPS = 20
TELEGRAM_MAX_TOPICS = 64
# Which flat Authentik user-attribute keys make up one kind's credential, and
# which of credential_record()'s field names each one fills. A record is
# "complete" only once every one of these attributes is a non-empty string;
# there is no CHANGE_ME-style placeholder to write or detect - an absent or
# blank attribute already means "needs_credentials", so the self-service
# prompt stage (configure.mjs) can simply start empty.
CREDENTIAL_ATTRIBUTES: dict[str, dict[str, str]] = {
    "jira": {"ai_stand_mcp_jira_pat": "pat"},
    "confluence": {"ai_stand_mcp_confluence_pat": "pat"},
    "imap": {
        "ai_stand_mcp_imap_username": "username",
        "ai_stand_mcp_imap_password": "password",
    },
}
# Installation-scoped opt-in (Settings.allow_user_upstream_overrides): which
# attribute overrides which of this installation's upstream Settings fields.
# Off by default in the generic core; a single-user installation may accept
# the reduced blast radius of a user picking their own endpoint.
UPSTREAM_OVERRIDE_ATTRIBUTES: dict[str, str] = {
    "ai_stand_mcp_jira_base_url": "jira_base_url",
    "ai_stand_mcp_confluence_base_url": "confluence_base_url",
    "ai_stand_mcp_imap_host": "imap_host",
}


class ReconcileError(RuntimeError):
    """A redacted, expected reconciliation failure."""


def audit(event: str, **fields: object) -> None:
    """Emit only allowlisted metadata to the systemd journal."""
    allowed = {"subject", "kind", "state", "version", "changed", "count"}
    suffix = " ".join(f"{key}={fields[key]}" for key in sorted(fields) if key in allowed)
    print(f"[readonly-mcp] {event}{(' ' + suffix) if suffix else ''}", flush=True)


def fail(message: str) -> ReconcileError:
    return ReconcileError(message)


def read_limited(path: Path, label: str, maximum: int = 32 * 1024) -> str:
    """Read a root-only credential without accepting a weak host file."""
    try:
        metadata = path.stat()
    except OSError as error:
        raise fail(f"cannot read {label}") from error
    if not path.is_file() or metadata.st_uid != 0 or metadata.st_mode & 0o077:
        raise fail(f"{label} must be a root-owned file with mode 0600")
    try:
        value = path.read_text(encoding="utf-8")
    except OSError as error:
        raise fail(f"cannot read {label}") from error
    if len(value) > maximum or not value.strip():
        raise fail(f"{label} is empty or too large")
    return value.strip()


def require_object(value: object, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise fail(f"{field} must be an object")
    return value


def require_string(value: object, field: str, maximum: int = 4096) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise fail(f"{field} must be a non-empty string")
    return value


def https_url(value: object, field: str) -> str:
    raw = require_string(value, field)
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.fragment:
        raise fail(f"{field} must be an HTTPS URL without credentials")
    return raw.rstrip("/")


def positive_port(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 65535:
        raise fail(f"{field} must be a TCP port")
    return value


@dataclass(frozen=True)
class Settings:
    authentik_address: str
    authentik_api_token_file: Path
    authentik_group: str
    telegram_owner_username: str
    jira_base_url: str
    confluence_base_url: str
    imap_host: str
    imap_port: int
    imap_tls_mode: str
    upstream_ca_file: Path | None
    # Installation-scoped opt-in, off by default: lets a member of
    # authentik_group override this installation's own upstream endpoints
    # for their personal services via UPSTREAM_OVERRIDE_ATTRIBUTES. The
    # generic core ships this off; a single-user installation may judge the
    # reduced blast radius (a user can only ever redirect their own
    # already-isolated MCP container) an acceptable trade for
    # letting them self-serve the endpoint too, not just the credential.
    allow_user_upstream_overrides: bool

    @classmethod
    def from_path(cls, path: Path) -> "Settings":
        # The configuration does not contain credential values, but it names
        # the Authentik API token file and internal topology. Keep it
        # protected from unprivileged local users just like that file.
        try:
            metadata = path.stat()
        except OSError as error:
            raise fail("cannot read reconciler configuration") from error
        if not path.is_file() or metadata.st_uid != 0 or metadata.st_mode & 0o077:
            raise fail("reconciler configuration must be root-owned with mode 0600")
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise fail("cannot read reconciler configuration") from error
        root = require_object(raw, "configuration")
        if root.get("version") != 1:
            raise fail("configuration version must be 1")
        authentik = require_object(root.get("authentik"), "authentik")
        upstreams = require_object(root.get("upstreams"), "upstreams")
        imap_host = require_string(upstreams.get("imapHost"), "upstreams.imapHost", 253)
        if "/" in imap_host or "@" in imap_host:
            raise fail("upstreams.imapHost must be a hostname")
        tls_mode = upstreams.get("imapTlsMode", "implicit")
        if tls_mode not in ("implicit", "starttls"):
            raise fail("upstreams.imapTlsMode must be implicit or starttls")
        return cls(
            authentik_address=https_url(authentik.get("address"), "authentik.address"),
            authentik_api_token_file=Path(require_string(authentik.get("apiTokenFile"), "authentik.apiTokenFile")),
            authentik_group=require_string(authentik.get("aiUsersGroup", "ai-users"), "authentik.aiUsersGroup", 128),
            telegram_owner_username=require_string(authentik.get("telegramOwner", "akadmin"), "authentik.telegramOwner", 150),
            jira_base_url=https_url(upstreams.get("jiraBaseUrl"), "upstreams.jiraBaseUrl"),
            confluence_base_url=https_url(upstreams.get("confluenceBaseUrl"), "upstreams.confluenceBaseUrl"),
            imap_host=imap_host,
            imap_port=positive_port(upstreams.get("imapPort", 993), "upstreams.imapPort"),
            imap_tls_mode=tls_mode,
            upstream_ca_file=Path(upstreams["caFile"]) if upstreams.get("caFile") else None,
            allow_user_upstream_overrides=bool(
                require_object(root.get("userOverrides", {}), "userOverrides").get("upstreamsEnabled", False)
            ),
        )


def ssl_context(ca_file: Path | None) -> ssl.SSLContext:
    try:
        return ssl.create_default_context(cafile=str(ca_file) if ca_file else None)
    except OSError as error:
        raise fail("cannot load configured CA trust store") from error


def request_json(
    url: str,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
    context: ssl.SSLContext | None = None,
    accepted: tuple[int, ...] = (200,),
) -> dict[str, Any]:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8") if payload is not None else None
    all_headers = {"Accept": "application/json"}
    if payload is not None:
        all_headers["Content-Type"] = "application/json"
    if headers:
        all_headers.update(headers)
    request = urllib.request.Request(url, data=body, headers=all_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30, context=context) as response:
            if response.status not in accepted:
                raise fail("unexpected upstream status")
            raw = response.read(1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        # Do not read error.body: it can reflect a credential or upstream data.
        raise fail(f"remote request failed with HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, ssl.SSLError) as error:
        raise fail("remote request failed") from error
    if len(raw) > 1024 * 1024:
        raise fail("remote metadata response is too large")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise fail("remote response was not JSON") from error
    return require_object(value, "remote response")


class Authentik:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.token = read_limited(settings.authentik_api_token_file, "Authentik API token")
        self.context = ssl_context(None)

    def _api(self, path: str, method: str = "GET", payload: dict[str, Any] | None = None) -> dict[str, Any]:
        return request_json(
            f"{self.settings.authentik_address}/api/v3{path}",
            method=method,
            headers={"Authorization": f"Bearer {self.token}"},
            payload=payload,
            context=self.context,
            accepted=(200, 201),
        )

    def _list(self, path: str) -> list[dict[str, Any]]:
        page = 1
        records: list[dict[str, Any]] = []
        while page <= 1000:
            sep = "&" if "?" in path else "?"
            response = self._api(f"{path}{sep}page={page}&page_size=100")
            current = response.get("results")
            if not isinstance(current, list):
                raise fail("Authentik list response is invalid")
            records.extend(require_object(item, "Authentik list item") for item in current)
            total = require_object(response.get("pagination", {}), "Authentik pagination").get("count", len(records))
            if not isinstance(total, int) or len(records) >= total or not current:
                return records
            page += 1
        raise fail("Authentik pagination exceeded limit")

    def ai_users(self) -> list[dict[str, Any]]:
        groups = self._list(f"/core/groups/?name={urllib.parse.quote(self.settings.authentik_group)}")
        group = next((item for item in groups if item.get("name") == self.settings.authentik_group), None)
        if group is None or group.get("pk") is None:
            raise fail("Authentik ai-users group is missing")
        group_pk = str(group["pk"])
        users = []
        # Do not enumerate the whole directory.  Authentik exposes a group
        # filter for the users endpoint; membership is checked again below
        # because serializers can be configured to omit related objects.
        for user in self._list(f"/core/users/?groups_by_pk={urllib.parse.quote(group_pk)}"):
            memberships = {str(item) for item in user.get("groups", []) if isinstance(item, (str, int))}
            subject = user.get("uuid")
            # Authentik can keep an inactive account in its groups. Inactive
            # users are never eligible for attribute reads, Secret creation
            # or Agentgateway routes; the next reconcile retires their targets.
            if (
                user.get("is_active") is not True
                or group_pk not in memberships
                or not isinstance(subject, str)
                or not SUBJECT.fullmatch(subject)
            ):
                continue
            users.append(user)
        return users

    def telegram_owner(self) -> dict[str, Any] | None:
        """The active superuser account that owns the Telegram bot, or None. Looked up by exact username, not through
        ai-users: the owner needs no MCP credentials and may be outside the group. A non-superuser never qualifies, so
        renaming an ordinary account to the owner's name cannot hand it the bot."""
        name = self.settings.telegram_owner_username
        for user in self._list(f"/core/users/?username={urllib.parse.quote(name)}"):
            if user.get("username") == name and user.get("is_active") is True and user.get("is_superuser") is True:
                return user
        return None

    def write_status(self, user: dict[str, Any], status: dict[str, Any]) -> None:
        pk = user.get("pk")
        if pk is None:
            raise fail("Authentik user has no primary key")
        path = f"/core/users/{urllib.parse.quote(str(pk))}/"
        # `user` is a snapshot from the start of the run, and a run can take minutes (every probe of an unreachable
        # upstream waits up to 30 s). Authentik's PATCH replaces the whole attributes object, so writing that snapshot
        # back would silently undo whatever the person or an operator saved in the meantime. Read the user again right
        # before writing and change nothing but our own status key.
        current = require_object(self._api(path), "Authentik user")
        attributes = current.get("attributes")
        if attributes is None:
            attributes = {}
        attributes = dict(require_object(attributes, "Authentik user attributes"))
        if status_unchanged(attributes.get("ai_stand_mcp"), status):
            return
        attributes["ai_stand_mcp"] = status
        self._api(path, method="PATCH", payload={"attributes": attributes})


def status_unchanged(current: Any, new: dict[str, Any], max_age: int = 3600) -> bool:
    """True when rewriting the status would change nothing but its timestamp, and the timestamp is still recent.

    Skipping those writes keeps the reconciler from touching every profile every five minutes, which is what
    made lost updates possible in the first place."""
    if not isinstance(current, dict):
        return False
    strip = lambda value: {key: item for key, item in value.items() if key != "checkedAt"}
    if strip(current) != strip(new):
        return False
    try:
        age = time.time() - calendar.timegm(time.strptime(str(current["checkedAt"]), "%Y-%m-%dT%H:%M:%SZ"))
    except (KeyError, ValueError, OverflowError):
        return False
    return 0 <= age < max_age


def telegram_groups(user: dict[str, Any] | None) -> tuple[dict[str, Any] | None, str]:
    """The Telegram groups from the owner's attribute: (groups, state) with state active, missing or invalid. The value is
    an object, or the same object as a JSON string (Authentik's attribute editor keeps either). Anything outside the
    schema makes the whole attribute invalid: a half-read list could silently drop a group, so nothing is pushed then and
    the gateway keeps what it has. An empty object is valid and means "no groups"."""
    attributes = user.get("attributes") if isinstance(user, dict) else None
    value = attributes.get(TELEGRAM_GROUPS_ATTRIBUTE) if isinstance(attributes, dict) else None
    if value is None or (isinstance(value, str) and not value.strip()):
        return None, "missing"
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return None, "invalid"
    if not isinstance(value, dict) or len(value) > TELEGRAM_MAX_GROUPS:
        return None, "invalid"
    groups: dict[str, Any] = {}
    for group_id, group in value.items():
        if not isinstance(group_id, str) or not TELEGRAM_GROUP_ID.fullmatch(group_id) or not isinstance(group, dict):
            return None, "invalid"
        if set(group) - {"requireMention", "topics"}:
            return None, "invalid"
        require_mention = group.get("requireMention", True)
        topics = group.get("topics", {})
        if not isinstance(require_mention, bool) or not isinstance(topics, dict) or len(topics) > TELEGRAM_MAX_TOPICS:
            return None, "invalid"
        for topic_id, agent in topics.items():
            if (
                not isinstance(topic_id, str) or not TELEGRAM_TOPIC_ID.fullmatch(topic_id)
                or not isinstance(agent, str) or not TELEGRAM_AGENT_ID.fullmatch(agent)
            ):
                return None, "invalid"
        entry: dict[str, Any] = {"requireMention": require_mention}
        if topics:
            entry["topics"] = dict(sorted(topics.items()))
        groups[group_id] = entry
    return dict(sorted(groups.items())), "active"


def telegram_user_id(user: dict[str, Any]) -> tuple[str | None, str]:
    """The person's Telegram user id from the self-service attribute: (id, state) with state active, missing or
    invalid. Surrounding spaces are tolerated; anything that is not a plain number is reported, never guessed."""
    attributes = user.get("attributes")
    value = attributes.get(TELEGRAM_ATTRIBUTE) if isinstance(attributes, dict) else None
    if value is None or (isinstance(value, str) and not value.strip()):
        return None, "missing"
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return None, "invalid"
    text = str(value).strip()
    return (text, "active") if TELEGRAM_ID.fullmatch(text) else (None, "invalid")


def credentials_for_user(user: dict[str, Any], kind: str) -> dict[str, Any] | None:
    """Reassemble one kind's credential dict from flat Authentik attributes.

    Returns None when any of that kind's required attributes (see
    CREDENTIAL_ATTRIBUTES) is absent, not a string, or blank - the caller
    treats that as ``needs_credentials``, not an error. There is no separate
    placeholder check: an untouched attribute is already empty.
    """
    attributes = user.get("attributes")
    if not isinstance(attributes, dict):
        return None
    record: dict[str, Any] = {}
    for attribute_key, field in CREDENTIAL_ATTRIBUTES[kind].items():
        value = attributes.get(attribute_key)
        if not isinstance(value, str) or not value.strip():
            return None
        record[field] = value
    return record


def effective_settings_for_user(user: dict[str, Any], settings: Settings) -> Settings:
    """Apply this user's own upstream overrides, when the installation opts in.

    An invalid or partially-set override silently falls back to the
    installation's own default for that one field - the user only ever
    affects their own already-isolated container, never anyone else's, so a
    typo here is a self-service mistake to fix, not a control-plane fault.
    """
    if not settings.allow_user_upstream_overrides:
        return settings
    attributes = user.get("attributes")
    if not isinstance(attributes, dict):
        return settings
    overrides: dict[str, str] = {}
    for attribute_key, field in UPSTREAM_OVERRIDE_ATTRIBUTES.items():
        value = attributes.get(attribute_key)
        if not isinstance(value, str) or not value.strip():
            continue
        candidate = value.strip()
        try:
            if field == "imap_host":
                if "/" in candidate or "@" in candidate:
                    raise fail("invalid imap host override")
                overrides[field] = candidate
            else:
                overrides[field] = https_url(candidate, attribute_key)
        except ReconcileError:
            continue
    return replace(settings, **overrides) if overrides else settings


def credential_record(kind: str, record: dict[str, Any]) -> bytes:
    if kind in ("jira", "confluence"):
        pat = record.get("pat")
        if set(record) != {"pat"} or not isinstance(pat, str) or not pat.strip() or len(pat) > 8192:
            raise fail(f"{kind} pat attribute must be a non-empty string")
        return json.dumps({"pat": pat.strip()}, separators=(",", ":")).encode("utf-8")
    username = record.get("username")
    password = record.get("password")
    if set(record) != {"username", "password"} or not isinstance(username, str) or not isinstance(password, str):
        raise fail("imap username/password attributes must both be strings")
    if not username.strip() or not password or len(username) > 1024 or len(password) > 8192:
        raise fail("imap username/password attributes are empty or oversized")
    return json.dumps({"username": username.strip(), "password": password}, separators=(",", ":")).encode("utf-8")


def credential_fingerprint(secret: bytes) -> str:
    """Return a stable, non-reversible credential change marker.

    Authentik attributes have no per-field version counter, so rotation keys
    off whether the credential value changed since the previous reconcile
    (via the manifest's ``valueFingerprint``).
    """
    return hashlib.sha256(secret).hexdigest()[:16]


def probe_http(base: str, path: str, pat: str, context: ssl.SSLContext) -> None:
    url = urllib.parse.urljoin(base.rstrip("/") + "/", path)
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {pat}", "Accept": "application/json"}, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=30, context=context) as response:
            if response.status != 200:
                raise fail("upstream probe was rejected")
            response.read(4096)
    except urllib.error.HTTPError as error:
        raise fail(f"upstream probe failed with HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, ssl.SSLError) as error:
        raise fail("upstream probe failed") from error


def probe_imap(settings: Settings, username: str, password: str, context: ssl.SSLContext) -> None:
    client: imaplib.IMAP4 | None = None
    try:
        if settings.imap_tls_mode == "implicit":
            client = imaplib.IMAP4_SSL(settings.imap_host, settings.imap_port, ssl_context=context, timeout=30)
        else:
            client = imaplib.IMAP4(settings.imap_host, settings.imap_port, timeout=30)
            client.starttls(ssl_context=context)
        code, _ = client.login(username, password)
        if code != "OK":
            raise fail("IMAP authentication was rejected")
        code, _ = client.list()
        if code != "OK":
            raise fail("IMAP read-only mailbox probe failed")
    except (imaplib.IMAP4.error, OSError, ssl.SSLError) as error:
        raise fail("IMAP probe failed") from error
    finally:
        if client is not None:
            with contextlib.suppress(Exception):
                client.logout()


def probe(kind: str, secret: bytes, settings: Settings) -> None:
    payload = json.loads(secret)
    context = ssl_context(settings.upstream_ca_file)
    if kind == "jira":
        probe_http(settings.jira_base_url, "rest/api/2/myself", payload["pat"], context)
    elif kind == "confluence":
        probe_http(settings.confluence_base_url, "rest/api/user/current", payload["pat"], context)
    else:
        probe_imap(settings, payload["username"], payload["password"], context)


def docker_secret_exists(name: str) -> bool:
    return subprocess.run(["docker", "secret", "inspect", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def require_swarm_manager() -> None:
    process = subprocess.run(
        ["docker", "info", "--format", "{{.Swarm.ControlAvailable}}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if process.returncode or process.stdout.strip().lower() != "true":
        raise fail("local Docker node is not an active Swarm manager")


def create_docker_secret(name: str, value: bytes) -> None:
    if docker_secret_exists(name):
        return
    process = subprocess.run(["docker", "secret", "create", name, "-"], input=value, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if process.returncode:
        raise fail("Docker Secret creation failed")


def remove_docker_secret(name: str) -> bool:
    """Remove a retired secret only when no Swarm task still references it."""
    if docker_secret_exists(name):
        process = subprocess.run(["docker", "secret", "rm", name], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if process.returncode:
            # A rolling service update may still have an old task.  Keeping a
            # root-only Swarm Secret temporarily is safe; deleting it early
            # could break that task. A later five-minute run retries.
            return False
    return True


def remove_service(name: str) -> None:
    subprocess.run(["docker", "service", "rm", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def readonly_mcp_service_name(kind: str, slug: str) -> str:
    return f"{kind}-readonly-mcp-{slug}"


def slug_for(subject: str) -> str:
    # Docker Swarm limits service names to 63 characters. The longest
    # generated prefix is ``confluence-readonly-mcp-``; embedding a full
    # 32-hex-character UUID would exceed that limit. A deterministic 96-bit
    # SHA-256 prefix is collision-resistant for this installation and keeps
    # the internal identifier opaque rather than exposing the Authentik UUID
    # in service/DNS names.
    # `docker stack deploy` prefixes every service with ``ai-stand_``. Keep
    # the whole resulting Swarm name within 63 characters: 9 (stack prefix)
    # + 24 (longest service prefix) + 25 (``u-`` plus 23 hash chars) = 58.
    # The slug length is deliberately unchanged so existing service and
    # Docker Secret names stay stable.
    slug = "u-" + hashlib.sha256(subject.encode("ascii")).hexdigest()[:23]
    if not SAFE_SLUG.fullmatch(slug):
        raise fail("cannot derive safe service slug")
    return slug


def secret_names(kind: str, slug: str, version: int) -> tuple[str, str]:
    return (
        f"ai-stand-mcp-{kind}-{slug}-credentials-v{version}",
        f"ai-stand-mcp-{kind}-{slug}-internal-v{version}",
    )


def read_manifest(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 2, "users": [], "retiredSecrets": []}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise fail("existing MCP manifest is unreadable") from error
    if not isinstance(value, dict) or value.get("version") != 2 or not isinstance(value.get("users"), list):
        raise fail("existing MCP manifest has an unsupported shape")
    retired = value.get("retiredSecrets", [])
    if not isinstance(retired, list) or any(not isinstance(item, str) or not SECRET_NAME.fullmatch(item) for item in retired):
        raise fail("existing MCP manifest has invalid retired Secrets")
    value.setdefault("retiredSecrets", [])
    return value


def write_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    descriptor, temporary = tempfile.mkstemp(prefix=".manifest.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def old_services(manifest: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for user in manifest.get("users", []):
        if not isinstance(user, dict) or not isinstance(user.get("slug"), str):
            continue
        for kind, service in (user.get("services") or {}).items():
            if kind in MCP_KINDS and isinstance(service, dict):
                result[(kind, user["slug"])] = service
    return result


def referenced_secrets(manifest: dict[str, Any]) -> set[str]:
    """Return Secret references held by active services."""
    names: set[str] = set()
    for service in old_services(manifest).values():
        for field in ("credentialSecret", "internalTokenSecret"):
            value = service.get(field)
            if isinstance(value, str) and SECRET_NAME.fullmatch(value):
                names.add(value)
    return names


def settings_fingerprint(settings: Settings) -> str:
    """Track non-secret inputs which affect the rendered services/routes."""
    import hashlib
    value = {
        "jiraBaseUrl": settings.jira_base_url,
        "confluenceBaseUrl": settings.confluence_base_url,
        "imapHost": settings.imap_host,
        "imapPort": settings.imap_port,
        "imapTlsMode": settings.imap_tls_mode,
        "allowUserUpstreamOverrides": settings.allow_user_upstream_overrides,
    }
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def telegram_manifest(user_ids: list[str], owner_id: str | None, groups: dict[str, Any] | None) -> dict[str, Any]:
    """What apply.sh pushes to the gateway. `groups` is left out unless the attribute was read cleanly, which tells the
    gateway not to touch its groups; an empty object, by contrast, removes them all."""
    manifest: dict[str, Any] = {"userIds": user_ids, "ownerIds": [owner_id] if owner_id else []}
    if groups is not None:
        manifest["groups"] = groups
    return manifest


def apply_manifest(script: Path, installation: str, node: str) -> None:
    process = subprocess.run(
        [str(script), "reconcile-mcp", "--installation", installation, "--node-name", node],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    # The apply script can include service details, so do not replay its
    # output into the timer journal. Preserve only the exit status.
    if process.returncode:
        raise fail("read-only MCP stack apply failed")


def reconcile(
    settings: Settings,
    manifest_path: Path,
    apply_script: Path,
    installation: str,
    node: str,
    dry_run: bool,
) -> None:
    previous = read_manifest(manifest_path)
    previous_services = old_services(previous)
    authentik = Authentik(settings)
    if not dry_run:
        require_swarm_manager()
    desired_users: list[dict[str, Any]] = []
    statuses: list[tuple[dict[str, Any], dict[str, Any]]] = []
    telegram_ids: set[str] = set()

    for user in authentik.ai_users():
        subject = str(user.get("uuid", "")).lower()
        slug = slug_for(subject)
        user_settings = effective_settings_for_user(user, settings)
        services: dict[str, Any] = {}
        service_status: dict[str, Any] = {}
        for kind in MCP_KINDS:
            try:
                record = credentials_for_user(user, kind)
                if record is None:
                    service_status[kind] = {"state": "needs_credentials"}
                    audit("service-checked", subject=subject, kind=kind, state="needs_credentials")
                    continue
                credential = credential_record(kind, record)
                probe(kind, credential, user_settings)
                fingerprint = credential_fingerprint(credential)
                previous_service = previous_services.get((kind, slug))
                previous_version = previous_service.get("secretVersion") if isinstance(previous_service, dict) else None
                previous_fingerprint = previous_service.get("valueFingerprint") if isinstance(previous_service, dict) else None
                has_previous_version = isinstance(previous_version, int) and previous_version >= 1
                if has_previous_version and previous_fingerprint == fingerprint:
                    version = previous_version
                else:
                    # A changed (or first-seen) credential value always gets
                    # its own secret name - never overwrite a Docker Secret
                    # in place, since a task from the previous rolling update
                    # may still reference it.
                    version = previous_version + 1 if has_previous_version else 1
                credential_secret, internal_secret = secret_names(kind, slug, version)
                if not dry_run:
                    create_docker_secret(credential_secret, credential)
                    create_docker_secret(internal_secret, secrets.token_urlsafe(32).encode("ascii"))
                services[kind] = {
                    "credentialSecret": credential_secret,
                    "internalTokenSecret": internal_secret,
                    "secretVersion": version,
                    "valueFingerprint": fingerprint,
                }
                service_status[kind] = {"state": "active", "version": version}
                audit("service-checked", subject=subject, kind=kind, state="active", version=version)
            except ReconcileError:
                service_status[kind] = {"state": "unavailable"}
                audit("service-checked", subject=subject, kind=kind, state="unavailable")

        telegram_id, telegram_state = telegram_user_id(user)
        if telegram_id:
            telegram_ids.add(telegram_id)
        audit("telegram-checked", subject=subject, state=telegram_state)

        entry: dict[str, Any] = {"subject": subject, "slug": slug, "services": services}
        desired_users.append(entry)
        statuses.append((user, {
            "credentialSource": "authentik-user-attributes",
            "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "services": service_status,
            "telegram": {"state": telegram_state},
        }))

    owner = authentik.telegram_owner()
    owner_id, owner_state = telegram_user_id(owner) if owner else (None, "missing")
    groups, groups_state = telegram_groups(owner)
    audit("telegram-owner-checked", state=owner_state)
    audit("telegram-groups-checked", state=groups_state, count=len(groups or {}))

    # Keep stale Secret names in the manifest until Swarm no longer has an
    # old task that references them.  This makes credentials rotation safe
    # with asynchronous rolling updates and gives the next timer run a
    # deterministic cleanup list.
    active_secrets = referenced_secrets({"version": 2, "users": desired_users})
    retired_secrets = {
        value for value in previous.get("retiredSecrets", [])
        if isinstance(value, str) and SECRET_NAME.fullmatch(value) and value not in active_secrets
    }
    retired_secrets.update(referenced_secrets(previous) - active_secrets)
    desired = {
        "version": 2,
        "configurationFingerprint": settings_fingerprint(settings),
        "users": desired_users,
        # apply.sh pushes this list to the OpenClaw gateway; the people stay out of it, only the numbers travel.
        "telegram": telegram_manifest(sorted(telegram_ids), owner_id, groups),
        "retiredSecrets": sorted(retired_secrets),
    }
    changed = json.dumps(previous, sort_keys=True, separators=(",", ":")) != json.dumps(desired, sort_keys=True, separators=(",", ":"))
    audit("manifest-evaluated", changed=str(changed).lower(), count=len(desired_users))
    if changed and not dry_run:
        old = old_services(previous)
        try:
            write_atomic(manifest_path, desired)
            apply_manifest(apply_script, installation, node)
        except ReconcileError:
            write_atomic(manifest_path, previous)
            raise
        current = old_services(desired)
        for key, service in old.items():
            if key not in current:
                kind, slug = key
                remove_service(f"ai-stand_{readonly_mcp_service_name(kind, slug)}")

    # Do this even when the manifest itself did not change: a previous
    # rotation may have left a Secret temporarily in use by an old task.
    remaining_retired: list[str] = []
    for name in desired["retiredSecrets"]:
        if not dry_run and not remove_docker_secret(name):
            remaining_retired.append(name)
            audit("secret-cleanup-deferred", state="in-use")
    if remaining_retired != desired["retiredSecrets"] and not dry_run:
        desired["retiredSecrets"] = remaining_retired
        write_atomic(manifest_path, desired)

    if not dry_run:
        for user, status in statuses:
            try:
                authentik.write_status(user, status)
            except ReconcileError:
                audit("status-write-failed", subject=str(user.get("uuid", "")), state="unavailable")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--apply-script", type=Path, required=True)
    parser.add_argument("--installation", required=True)
    parser.add_argument("--node", default="ai01")
    parser.add_argument("--lock-file", type=Path, default=Path("/run/lock/ai-stand-readonly-mcp.lock"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.installation) or not args.apply_script.is_file():
        raise SystemExit("invalid installation or apply script")
    settings = Settings.from_path(args.config)
    args.lock_file.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with open(args.lock_file, "w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            audit("skipped", state="locked")
            return
        try:
            reconcile(
                settings, args.manifest, args.apply_script, args.installation, args.node, args.dry_run,
            )
        except ReconcileError as error:
            # Error strings are constructed locally from fixed categories;
            # never attach exception reprs because they may contain secrets.
            audit("failed", state="error")
            print(f"[readonly-mcp] ERROR: {error}", file=sys.stderr)
            raise SystemExit(1)


if __name__ == "__main__":
    main()
