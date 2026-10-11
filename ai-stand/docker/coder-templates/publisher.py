#!/usr/bin/env python3
"""Private template publishing using the pinned Coder HTTP API.

Docker/curl arguments never contain credentials. HTTP bodies and auth headers
travel on stdin; token responses are kept in memory and a root-only host file.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import sys
import tarfile
import time
import urllib.parse
import uuid


# Supported public scopes in Coder v2.38.0. No workspace operations, role
# assignment, template deletion, API-key management or coder:all capability.
PUBLISHER_SCOPES = (
    "coder:templates.build",
    "template:create",
    "template:update",
    "organization:read",
    "user:read",
    "api_key:read",
)
TOKEN_LIFETIME_SECONDS = 90 * 24 * 60 * 60
REFRESH_MARGIN_SECONDS = 24 * 60 * 60
PINNED_VERSION = "v2.38.0"
HELPER_START_SCRIPT = """
set -eu
pg_password=$(cat /run/secrets/coder-postgres-password)
export CODER_PG_CONNECTION_URL="postgresql://coder:${pg_password}@127.0.0.1:5432/coder?sslmode=disable"
unset pg_password
# A killed installer cannot leave a permanent alternate login server.
exec timeout -s TERM 300 /opt/coder server
"""
HELPER_ADMIN_SCRIPT = """
set -eu
pg_password=$(cat /run/secrets/coder-postgres-password)
export CODER_PG_CONNECTION_URL="postgresql://coder:${pg_password}@127.0.0.1:5432/coder?sslmode=disable"
export CODER_PASSWORD=$(cat /run/secrets/coder-admin-password)
unset pg_password
if /opt/coder server create-admin-user --username "$1" --email "$2" >/tmp/create-admin.log 2>&1; then
  exit 0
fi
if grep -qiE 'already exists|duplicate|unique constraint|already in use' /tmp/create-admin.log; then
  exit 0
fi
exit 1
"""


class PublisherError(Exception):
    """A safe, non-secret diagnostic suitable for operator output."""


class Docker:
    def run(self, arguments: list[str], payload: bytes | None = None,
            timeout: int = 30) -> bytes:
        try:
            result = subprocess.run(
                ["docker", "--host", "unix:///var/run/docker.sock", *arguments], input=payload, capture_output=True,
                timeout=timeout, check=False, env={key: value for key, value in os.environ.items()
                    if key not in {"DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"}},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PublisherError("Docker operation unavailable or timed out") from exc
        if result.returncode:
            # Never print Docker stderr: a nested API/client may include secrets.
            raise PublisherError("Docker operation failed; no credentials were logged")
        return result.stdout

    def inspect(self, target: str, expression: str, image: bool = False) -> str:
        args = ["image", "inspect"] if image else ["inspect"]
        return self.run([*args, "--format", expression, target]).decode().strip()


def curl_quote(value: str) -> str:
    """Quote curl's config language, not shell language."""
    if "\x00" in value:
        raise PublisherError("Invalid HTTP value")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace(
        "\n", "\\n").replace("\r", "\\r") + '"'


class CoderHTTP:
    def __init__(self, docker: Docker, container: str, port: int,
                 token: str | None = None):
        self.docker, self.container, self.port, self.token = docker, container, port, token

    def request(self, method: str, path: str, body: object | None = None,
                upload_path: str | None = None) -> tuple[int, object]:
        if not path.startswith("/api/v2/") or "\n" in path or "\r" in path:
            raise PublisherError("Invalid Coder API path")
        config = [
            "silent", "show-error", "max-time = 30", 'noproxy = "*"',
            'write-out = "\\n%{http_code}"',
            "url = " + curl_quote(f"http://127.0.0.1:{self.port}{path}"),
            "request = " + curl_quote(method),
        ]
        if self.token:
            config.append("header = " + curl_quote("Coder-Session-Token: " + self.token))
        if upload_path:
            config.extend([
                'header = "Content-Type: application/x-tar"',
                "data-binary = " + curl_quote("@" + upload_path),
            ])
        elif body is not None:
            config.extend([
                'header = "Content-Type: application/json"',
                "data = " + curl_quote(json.dumps(body, separators=(",", ":"))),
            ])
        raw = self.docker.run(
            ["exec", "-i", self.container, "curl", "--config", "-"],
            ("\n".join(config) + "\n").encode(), timeout=40,
        )
        if len(raw) > 2 * 1024 * 1024:
            raise PublisherError("Coder API response exceeded the safe limit")
        try:
            data, status_code = raw.rsplit(b"\n", 1)
            parsed = json.loads(data) if data.strip() else {}
            return int(status_code), parsed
        except (ValueError, json.JSONDecodeError) as exc:
            raise PublisherError("Coder API returned an invalid response") from exc

    def expect(self, method: str, path: str, body: object | None = None,
               upload_path: str | None = None) -> object:
        status_code, result = self.request(method, path, body, upload_path)
        if not 200 <= status_code < 300:
            raise PublisherError(f"Coder {method} request failed (HTTP {status_code})")
        return result


def checked_uuid(value: object) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except ValueError as exc:
        raise PublisherError("Coder API returned an invalid identifier") from exc


def read_secret(path: Path) -> str:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as handle:
            metadata = os.fstat(handle.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid or metadata.st_gid \
                    or stat.S_IMODE(metadata.st_mode) != 0o600:
                raise PublisherError("Credential files must be regular root:root mode 0600")
            raw = handle.read(16385)
    except OSError as exc:
        raise PublisherError("A required root-only credential file is unavailable") from exc
    if not raw or len(raw) > 16384:
        raise PublisherError("Credential file is empty or oversized")
    try:
        value = raw.decode().strip()
    except UnicodeDecodeError as exc:
        raise PublisherError("Invalid credential encoding") from exc
    if not value or any(char in value for char in "\x00\r\n"):
        raise PublisherError("Credential has an invalid format")
    return value


def atomic_secret(path: Path, value: str) -> None:
    """Atomically persist only the credential, never a bootstrap response."""
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    name = ".coder-publisher-" + secrets.token_hex(8)
    try:
        metadata = os.fstat(directory_fd)
        if metadata.st_uid or metadata.st_gid or stat.S_IMODE(metadata.st_mode) & 0o027:
            raise PublisherError("Secret directory must be root-owned and non-public")
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory_fd)
        with os.fdopen(fd, "w") as handle:
            os.fchown(handle.fileno(), 0, 0)
            handle.write(value + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path.name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name, dir_fd=directory_fd)
        os.close(directory_fd)


def helper_arguments(name: str, image_id: str, postgres_container: str,
                     pg_file: Path, password_file: Path) -> list[str]:
    # Sharing the PG network namespace avoids making its Swarm overlay
    # attachable. That namespace has no Coder socket-proxy network or socket.
    return [
        "run", "--detach", "--rm", "--name", name,
        "--network", "container:" + postgres_container,
        "--user", "0:0", "--read-only", "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges:true", "--pids-limit", "128",
        "--memory", "2g", "--cpus", "1",
        "--tmpfs", "/tmp:rw,nosuid,nodev,size=536870912,mode=1777",
        "--mount", f"type=bind,source={pg_file},target=/run/secrets/coder-postgres-password,readonly",
        "--mount", f"type=bind,source={password_file},target=/run/secrets/coder-admin-password,readonly",
        "--env", "HOME=/tmp/coder-helper",
        "--env", "CODER_CACHE_DIRECTORY=/tmp/coder-helper/cache",
        "--env", "GOMEMLIMIT=1GiB",
        "--env", "CODER_HTTP_ADDRESS=127.0.0.1:7081",
        "--env", "CODER_ACCESS_URL=http://127.0.0.1:7081",
        "--env", "CODER_DISABLE_PASSWORD_AUTH=false",
        "--env", "CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE=false",
        "--env", "CODER_PROVISIONER_DAEMONS=0",
        # The temporary helper has one process and shares the PG namespace;
        # it must not expose Coder 2.38's new embedded NATS mesh listener.
        "--env", "CODER_EXPERIMENTS=no_nats_pubsub",
        "--env", "CODER_DERP_SERVER_ENABLE=false",
        "--env", "CODER_AI_GATEWAY_ENABLED=false",
        "--env", "CODER_TELEMETRY_ENABLE=false",
        "--env", "CODER_UPDATE_CHECK=false",
        "--env", "CODER_MAX_ADMIN_TOKEN_LIFETIME=2160h",
        "--env", "CODER_SESSION_DURATION=5m",
        "--env", "CODER_DISABLE_SESSION_EXPIRY_REFRESH=true",
        "--entrypoint", "/bin/sh", image_id, "-ceu", HELPER_START_SCRIPT,
    ]


def ensure_helper_running(docker: Docker, container: str) -> None:
    """Inspect only bounded state metadata; never print Docker logs/errors."""
    try:
        state = json.loads(docker.inspect(container, "{{json .State}}"))
    except PublisherError as exc:
        raise PublisherError("Coder bootstrap helper exited or was removed before readiness") from exc
    if not isinstance(state, dict):
        raise PublisherError("Coder bootstrap helper returned invalid state metadata")
    if state.get("OOMKilled") is True:
        raise PublisherError("Coder bootstrap helper was stopped by its memory limit (OOM)")
    if state.get("Running") is not True:
        exit_code = state.get("ExitCode")
        suffix = f" (exit {exit_code})" if type(exit_code) is int else ""
        raise PublisherError("Coder bootstrap helper exited before readiness" + suffix)


def token_current(api: CoderHTTP, token: str) -> bool:
    # Coder tokens have an ID prefix. Read only public metadata, not hashes.
    token_id = token.split("-", 1)[0]
    if not re.fullmatch(r"[A-Za-z0-9]+", token_id):
        return False
    api.token = token
    status_code, metadata = api.request("GET", f"/api/v2/users/me/keys/{token_id}")
    if status_code in (401, 403, 404):
        return False
    if status_code != 200 or not isinstance(metadata, dict):
        raise PublisherError("Cannot verify the existing publisher credential")
    try:
        expiry = dt.datetime.fromisoformat(metadata["expires_at"].replace("Z", "+00:00"))
        return set(metadata.get("scopes", [])) == set(PUBLISHER_SCOPES) and \
            expiry.timestamp() > time.time() + REFRESH_MARGIN_SECONDS
    except (KeyError, ValueError, TypeError) as exc:
        raise PublisherError("Invalid publisher credential metadata") from exc


def grant_verified_owner(api: CoderHTTP, user_id: str) -> None:
    """One explicit installation decision, not username-based role sync."""
    user_id = checked_uuid(user_id)
    caller = api.expect("GET", "/api/v2/users/me")
    if checked_uuid(caller["id"]) == user_id:
        raise PublisherError("Cannot grant the bootstrap caller its own role")
    target = api.expect("GET", f"/api/v2/users/{user_id}")
    if checked_uuid(target["id"]) != user_id or target.get("login_type") != "oidc" \
            or target.get("status") != "active":
        raise PublisherError("Verified owner target must be an active OIDC user")
    metadata = api.expect("GET", f"/api/v2/users/{user_id}/roles")
    roles = metadata.get("roles")
    if not isinstance(roles, list) or any(not isinstance(role, str) for role in roles):
        raise PublisherError("Invalid Coder owner target roles")
    if "owner" not in roles:
        api.expect("PUT", f"/api/v2/users/{user_id}/roles", {"roles": [*roles, "owner"]})
    print("Explicit verified OIDC owner grant ensured")


def check_coder_version(docker: Docker, container: str) -> None:
    """Require the exact released binary; similarly prefixed versions fail."""
    raw = docker.run(["exec", container, "/opt/coder", "version"])
    version = re.match(rb"\ACoder (v[0-9]+\.[0-9]+\.[0-9]+)(?:\+[A-Za-z0-9.-]+)?(?:\s|\Z)", raw)
    if version is None or version.group(1).decode() != PINNED_VERSION:
        raise PublisherError("Coder helper contract requires the pinned version")


def check_runtime_image(docker: Docker, container: str, image: str) -> str:
    # Docker resolves either a local tag, registry digest or immutable image
    # ID. Compare the resulting actual IDs, never mutable textual references.
    expected_image = docker.inspect(image, "{{.Id}}", image=True)
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", expected_image) or \
            docker.inspect(container, "{{.Image}}") != expected_image:
        raise PublisherError("Running Coder does not match the pinned helper image")
    check_coder_version(docker, container)
    return expected_image


def bootstrap(args: argparse.Namespace, docker: Docker) -> None:
    if os.geteuid() != 0:
        raise PublisherError("Publisher bootstrap must run as root")
    # Validate even when an existing token is current: idempotence must not
    # bypass the version/image contract or admit an old runtime after rollout.
    expected_image = check_runtime_image(docker, args.coder_container, args.image)
    token_file, pg_file, password_file = map(Path, (
        args.token_file, args.postgres_password_file, args.admin_password_file,
    ))
    existing = read_secret(token_file) if token_file.exists() else None
    existing_current = bool(existing and token_current(CoderHTTP(docker, args.coder_container, 7080), existing))
    owner_target = getattr(args, "verified_owner_user_id", None)
    if existing_current:
        if not owner_target:
            print("Coder template publisher credential is already valid")
            return
    pg_password, password = read_secret(pg_file), read_secret(password_file)
    if not re.fullmatch(r"[A-Fa-f0-9]+", pg_password):
        raise PublisherError("Coder PostgreSQL credential must use the managed hex format")
    pg_networks = json.loads(docker.inspect(args.postgres_container, "{{json .NetworkSettings.Networks}}"))
    if len(pg_networks) != 1 or not next(iter(pg_networks)).endswith("ai-coder-control"):
        raise PublisherError("PostgreSQL must have only the isolated ai-coder-control network")
    name = "ai-coder-publisher-" + secrets.token_hex(8)
    api, session, candidate, persisted = CoderHTTP(docker, name, 7081), None, None, False
    try:
        docker.run(helper_arguments(name, expected_image, args.postgres_container, pg_file, password_file))
        deadline = time.monotonic() + 90
        while True:
            ensure_helper_running(docker, name)
            try:
                api.expect("GET", "/api/v2/buildinfo")
                break
            except PublisherError:
                if time.monotonic() >= deadline:
                    raise PublisherError("Isolated Coder bootstrap helper did not become ready")
                time.sleep(1)
        # Native DB bootstrap is safe to repeat and never resets an existing
        # account's password/roles. A conflicting credential fails the login.
        docker.run(["exec", name, "sh", "-ceu", HELPER_ADMIN_SCRIPT, "sh",
                    args.admin_username, args.admin_email])
        login = api.expect("POST", "/api/v2/users/login", {"email": args.admin_email, "password": password})
        session = login.get("session_token") if isinstance(login, dict) else None
        if not isinstance(session, str) or not session:
            raise PublisherError("Coder bootstrap login did not yield a session")
        api.token = session
        if owner_target:
            grant_verified_owner(api, owner_target)
        if existing_current:
            print("Coder template publisher credential remains unchanged")
            return
        result = api.expect("POST", "/api/v2/users/me/keys/tokens", {
            "token_name": "ai-stand-template-publisher-" + secrets.token_hex(6),
            "lifetime": TOKEN_LIFETIME_SECONDS * 1_000_000_000,
            "scopes": list(PUBLISHER_SCOPES),
        })
        token = result.get("key") if isinstance(result, dict) else None
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9]+-[A-Za-z0-9]+", token):
            raise PublisherError("Coder bootstrap returned an invalid publisher credential")
        candidate = token
        # Verify signature/expiry/scopes against the unchanged public runtime.
        if not token_current(CoderHTTP(docker, args.coder_container, 7080), token):
            raise PublisherError("New publisher credential failed public-runtime validation")
        atomic_secret(token_file, token)
        persisted = True
        if existing:
            old_id = existing.split("-", 1)[0]
            if re.fullmatch(r"[A-Za-z0-9]+", old_id):
                # Native API revocation occurs only after a tested replacement
                # is durable. The replacement cannot manage API keys itself.
                # A missing old key is already revoked, so treat 404 as the
                # idempotent success case rather than failing after rotation.
                status_code, _ = api.request("DELETE", f"/api/v2/users/me/keys/{old_id}")
                if not 200 <= status_code < 300 and status_code != 404:
                    raise PublisherError("Cannot revoke the replaced publisher credential")
        print("Coder template publisher credential issued and stored root-only")
    finally:
        if session:
            if candidate and not persisted:
                with contextlib.suppress(PublisherError):
                    api.expect("DELETE", "/api/v2/users/me/keys/" + candidate.split("-", 1)[0])
            with contextlib.suppress(PublisherError):
                api.token = session
                api.expect("POST", "/api/v2/users/logout")
        # Cleanup is not optional; no long-lived password-auth helper remains.
        try:
            docker.run(["rm", "--force", name])
        except PublisherError:
            # A failed create has no container to remove; otherwise fail closed.
            try:
                docker.inspect(name, "{{.Id}}")
            except PublisherError:
                pass
            else:
                raise PublisherError("Coder bootstrap helper cleanup failed")


def template_archive(source: Path) -> tuple[bytes, str]:
    # Only public Terraform sources belong in the archive, never arbitrary
    # hidden state, credentials, .terraform cache or a symlink destination.
    files = sorted(source.glob("*.tf"))
    if not files or any(path.is_symlink() or not path.is_file() for path in files):
        raise PublisherError("Template must contain regular Terraform source files")
    buffer, digest = io.BytesIO(), hashlib.sha256()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for path in files:
            content = path.read_bytes()
            digest.update(path.name.encode() + b"\0" + content)
            entry = tarfile.TarInfo(path.name)
            entry.size, entry.mode = len(content), 0o644
            archive.addfile(entry, io.BytesIO(content))
    return buffer.getvalue(), digest.hexdigest()


def template_variables(entries: list[str] | None) -> list[dict[str, str]]:
    """``NAME=VALUE`` arguments -> the user variable values of the template version, in a stable order."""
    values: dict[str, str] = {}
    for entry in entries or []:
        name, separator, value = entry.partition("=")
        if (not separator or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", name) or len(value) > 1024
                or re.search(r"[\x00-\x1f\x7f]", value) or name in values):
            raise PublisherError("Invalid template variable (expected unique NAME=VALUE without control characters)")
        values[name] = value
    return [{"name": name, "value": values[name]} for name in sorted(values)]


def source_digest(source_hash: str, variables: list[dict[str, str]]) -> str:
    """The managed-source marker: the Terraform files and the variable values the version is created with."""
    if not variables:
        return source_hash
    digest = hashlib.sha256(source_hash.encode())
    for item in variables:
        digest.update(b"\x00" + item["name"].encode() + b"=" + item["value"].encode())
    return digest.hexdigest()


def publish(args: argparse.Namespace, docker: Docker) -> None:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", args.slug):
        raise PublisherError("Invalid managed template slug")
    payload, source_hash = template_archive(Path(args.source_dir))
    variables = template_variables(getattr(args, "variable", None))
    source_hash = source_digest(source_hash, variables)
    check_coder_version(docker, args.coder_container)
    token = read_secret(Path(args.token_file))
    api = CoderHTTP(docker, args.coder_container, 7080, token)
    organizations = api.expect("GET", "/api/v2/users/me/organizations")
    if not isinstance(organizations, list) or len(organizations) != 1:
        raise PublisherError("Managed templates require exactly one Coder organization")
    organization_id = checked_uuid(organizations[0]["id"])
    status_code, template = api.request(
        "GET", f"/api/v2/organizations/{organization_id}/templates/{args.slug}")
    if status_code not in (200, 404):
        raise PublisherError(f"Cannot inspect managed template (HTTP {status_code})")
    template_id = checked_uuid(template["id"]) if status_code == 200 else None
    policy = getattr(args, "access_policy", "private")
    if policy not in ("private", "shared-vetted"):
        raise PublisherError("Unsupported explicit template access policy")
    if template_id and policy == "shared-vetted":
        postgres = getattr(args, "postgres_container", None)
        if not postgres or not re.fullmatch(r"[a-f0-9]{12,64}", postgres) or docker.inspect(
                postgres, '{{index .Config.Labels "com.docker.swarm.service.name"}}') != "ai-stand_coder-postgresql":
            raise PublisherError("Shared existing templates require verified read-only native policy metadata")
        sql = ("BEGIN READ ONLY; SELECT coalesce(group_acl -> '" + organization_id + "', '[]'::jsonb) "
               "FROM templates WHERE id = '" + template_id + "' AND NOT deleted; ROLLBACK;")
        raw = docker.run(["exec", "-i", postgres, "psql", "-X", "-q", "-A", "-t",
                          "--set=ON_ERROR_STOP=1", "-U", "coder", "-d", "coder"], sql.encode())
        if set(json.loads(raw)) != {"read", "use"}:
            # PATCH disable_everyone_group_access=false is a native no-op for
            # a previously private template. Never pretend it restores ACLs.
            raise PublisherError("Existing private template cannot be shared by Free metadata PATCH; approve native recreate with zero workspaces or a new managed slug")
    if template_id:
        # Revoke an inherited Everyone grant before importing/activating.
        api.expect("PATCH", f"/api/v2/templates/{template_id}", {
            **({"disable_everyone_group_access": True} if policy == "private" else {}),
            "display_name": args.display_name,
        })
    message = "ai-stand managed source sha256:" + source_hash
    if template_id:
        active = api.expect("GET", "/api/v2/templateversions/" + checked_uuid(template["active_version_id"]))
        if active.get("message") == message:
            print(f"Coder {policy} template unchanged: {args.display_name}")
            return
    remote_file = "/tmp/ai-stand-template-" + secrets.token_hex(8) + ".tar"
    try:
        docker.run(["exec", "-i", args.coder_container, "sh", "-ceu",
                    'umask 077; cat > "$1"', "sh", remote_file], payload)
        uploaded = api.expect("POST", "/api/v2/files", upload_path=remote_file)
        # UploadResponse.ID is serialized as "hash" in the pinned Coder SDK.
        # Despite that legacy field name, its value is a UUID, not SHA-256.
        if not isinstance(uploaded, dict) or "hash" not in uploaded:
            raise PublisherError("Coder file upload response is missing its file identifier")
        version_request = {
            "storage_method": "file", "file_id": checked_uuid(uploaded["hash"]),
            "provisioner": "terraform", "message": message,
        }
        if variables:
            version_request["user_variable_values"] = variables
        if template_id:
            version_request["template_id"] = template_id
        version = api.expect("POST", f"/api/v2/organizations/{organization_id}/templateversions", version_request)
        version_id = checked_uuid(version["id"])
        deadline = time.monotonic() + 900
        while True:
            version = api.expect("GET", f"/api/v2/templateversions/{version_id}")
            status = version.get("job", {}).get("status")
            if status == "succeeded":
                break
            if status in ("failed", "canceled"):
                raise PublisherError("Coder template validation failed; source was not activated")
            if time.monotonic() >= deadline:
                raise PublisherError("Coder template validation timed out; source was not activated")
            time.sleep(2)
        if template_id:
            api.expect("PATCH", f"/api/v2/templates/{template_id}/versions", {"id": version_id})
        else:
            # Atomic creation: no intermediate public template ever exists.
            api.expect("POST", f"/api/v2/organizations/{organization_id}/templates", {
                "name": args.slug, "display_name": args.display_name,
                "template_version_id": version_id, "disable_everyone_group_access": policy == "private",
            })
        print(f"Coder {policy} template published and activated: {args.display_name}")
    finally:
        docker.run(["exec", args.coder_container, "rm", "-f", "--", remote_file])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--coder-container", required=True)
    common.add_argument("--token-file", required=True)
    boot = commands.add_parser("bootstrap", parents=[common])
    boot.add_argument("--postgres-container", required=True)
    boot.add_argument("--image", required=True)
    boot.add_argument("--postgres-password-file", required=True)
    boot.add_argument("--admin-password-file", required=True)
    boot.add_argument("--admin-email", required=True)
    boot.add_argument("--admin-username", required=True)
    boot.add_argument("--verified-owner-user-id", help="Optional UUID separately verified against live Authentik ai-admins and immutable OIDC link")
    pub = commands.add_parser("publish", parents=[common])
    pub.add_argument("--source-dir", required=True)
    pub.add_argument("--slug", required=True)
    pub.add_argument("--display-name", required=True)
    pub.add_argument("--access-policy", choices=("private", "shared-vetted"), default="private")
    pub.add_argument("--postgres-container", help="Exact native PostgreSQL container for read-only existing shared-policy verification")
    pub.add_argument("--variable", action="append", metavar="NAME=VALUE",
                     help="Terraform variable value for the template version (repeatable); part of the managed-source marker")
    args = parser.parse_args()
    try:
        def stop_safely(signum, frame):
            raise PublisherError("Coder publisher interrupted; temporary helper cleanup requested")
        signal.signal(signal.SIGTERM, stop_safely)
        signal.signal(signal.SIGINT, stop_safely)
        # Serialize bootstrap/publication. A routine deploy and a manually
        # invoked templates stage must not create competing tokens/versions.
        import fcntl
        lock_path = Path(args.token_file).parent / ".coder-template-publisher.lock"
        lock_fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(lock_fd, "w") as lock:
            lock_metadata = os.fstat(lock.fileno())
            if lock_metadata.st_uid or lock_metadata.st_gid or stat.S_IMODE(lock_metadata.st_mode) != 0o600:
                raise PublisherError("Publisher lock must be root:root mode 0600")
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            (bootstrap if args.command == "bootstrap" else publish)(args, Docker())
        return 0
    except PublisherError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except (OSError, KeyError, ValueError, TypeError):
        print("Coder publisher failed closed; no credentials were logged", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
