"""Host-owned Open WebUI ACL snapshot builder and five-minute reconciler.

Uses an independent identity config and the existing limited Authentik token. No credential
or upstream response is printed. The regular invocation plans; --apply writes.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

from model_access import (MAX_INPUT_BYTES, PUBLIC_ERRORS, ReconcileError,
                          Snapshot, need, opaque_id, subject)


# The installation's storage root (apply.sh and the controller export it); nothing below it is spelled out as a literal path.
STORAGE_ROOT = os.environ.get("STORAGE_ROOT", "")
if not STORAGE_ROOT.startswith("/") or STORAGE_ROOT.endswith("/") or ".." in STORAGE_ROOT:
    raise SystemExit("STORAGE_ROOT must be the installation's absolute storage root")
DEFAULT_CONFIG = Path(STORAGE_ROOT) / "ai-stand-data/identity/openwebui-model-access.json"
DEFAULT_LAST = DEFAULT_CONFIG.parent / "openwebui-model-access.snapshot.json"
TOKEN_FILE = f"{STORAGE_ROOT}/_secrets/readonly-mcp-authentik-api-token"
CONTAINER_HELPER = "/tmp/ai-stand-model-access.py"


def identity_configuration(address: str) -> dict:
    try:
        parsed = urllib.parse.urlsplit(address)
        valid = (parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username
                 and not parsed.password and not parsed.query and not parsed.fragment
                 and parsed.path in {"", "/"} and not any(c.isspace() for c in address))
    except (ValueError, TypeError):
        valid = False
    need(valid, "invalid_authentik_address")
    return {"version": 1, "authentik": {"address": address.rstrip("/"),
        "apiTokenFile": TOKEN_FILE, "aiUsersGroup": "ai-users"}}


def private_read(path: Path, maximum: int = MAX_INPUT_BYTES) -> bytes:
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and not path.is_symlink() and info.st_uid == 0
         and not info.st_mode & 0o077 and info.st_size <= maximum, "unprotected_control_file")
    parent = path.parent.lstat()
    need(stat.S_ISDIR(parent.st_mode) and not path.parent.is_symlink()
         and parent.st_uid == 0 and not parent.st_mode & 0o022, "unprotected_control_parent")
    with path.open("rb") as handle:
        raw = handle.read(maximum + 1)
    need(len(raw) <= maximum, "control_file_too_large")
    return raw


def private_json(path: Path) -> dict:
    value = json.loads(private_read(path))
    need(isinstance(value, dict), "invalid_control_file")
    return value


def atomic_snapshot(path: Path, value: dict) -> None:
    parent = path.parent.lstat()
    need(parent.st_uid == 0 and not parent.st_mode & 0o077
         and not path.parent.is_symlink(), "unprotected_snapshot_parent")
    descriptor, pending = tempfile.mkstemp(prefix=".openwebui-acl.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(pending, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(pending):
            os.unlink(pending)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ReconcileError("identity_request_redirected")


class Authentik:
    def __init__(self, address: str, token: str):
        parsed = urllib.parse.urlsplit(address)
        need(parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username
             and not parsed.password and not parsed.query and not parsed.fragment,
             "invalid_authentik_address")
        self.address = address.rstrip("/")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, url: str, authenticated: bool = True) -> dict:
        headers = {"Accept": "application/json"}
        if authenticated:
            need(url.startswith(self.address + "/api/v3/"), "foreign_identity_request")
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(url, headers=headers)
        try:
            with self.opener.open(request, timeout=20) as response:
                need(response.status == 200, "identity_request_failed")
                raw = response.read(MAX_INPUT_BYTES + 1)
            need(len(raw) <= MAX_INPUT_BYTES, "identity_response_too_large")
            value = json.loads(raw)
            need(isinstance(value, dict), "invalid_identity_response")
            return value
        except ReconcileError:
            raise
        except Exception:
            raise ReconcileError("identity_request_failed") from None

    def listed(self, path: str) -> list[dict]:
        records = []
        total = None
        for page in range(1, 102):
            separator = "&" if "?" in path else "?"
            response = self.request(self.address + "/api/v3" + path + separator
                                    + f"page={page}&page_size=100")
            batch = response.get("results")
            pagination = response.get("pagination")
            need(isinstance(batch, list) and all(isinstance(item, dict) for item in batch)
                 and isinstance(pagination, dict), "invalid_identity_pagination")
            count = pagination.get("count")
            need(type(count) is int and 0 <= count <= 10000
                 and (total is None or count == total), "unstable_identity_inventory")
            total = count
            records.extend(batch)
            need(len(records) <= total, "invalid_identity_pagination")
            if len(records) == total:
                return records
            need(bool(batch), "incomplete_identity_inventory")
        raise ReconcileError("identity_inventory_too_large")

    def inventory(self) -> tuple[dict, list[dict]]:
        named = {}
        for group in self.listed("/core/groups/"):
            if group.get("name") in {"ai-users", "ai-admins"}:
                name = group["name"]
                need(name not in named and isinstance(group.get("pk"), (str, int)), "ambiguous_identity_group")
                named[name] = str(group["pk"])
        need(set(named) == {"ai-users", "ai-admins"}, "missing_identity_group")
        return named, self.listed("/core/users/?groups_by_pk=" + urllib.parse.quote(named["ai-users"]))


def docker(*arguments: str, payload: dict | None = None) -> str:
    result = subprocess.run(["docker", *arguments], input=None if payload is None else json.dumps(payload),
        capture_output=True, text=True, check=False, timeout=90)
    if result.returncode != 0:
        # Forward only this helper's fixed public error vocabulary. Vendor
        # responses, stderr, command lines and credentials never become errors.
        if arguments[:1] == ("exec",) and CONTAINER_HELPER in arguments:
            try:
                failure = json.loads(result.stdout)
            except (ValueError, TypeError):
                failure = None
            if (isinstance(failure, dict) and failure.get("schemaVersion") == 1
                    and isinstance(failure.get("error"), str) and failure["error"] in PUBLIC_ERRORS):
                raise ReconcileError(failure["error"])
        raise ReconcileError("docker_operation_failed")
    return result.stdout


def service_context(service: str, command=docker) -> tuple[str, str, str]:
    inspected = json.loads(command("service", "inspect", service))
    need(isinstance(inspected, list) and len(inspected) == 1, "invalid_openwebui_service")
    entries = inspected[0]["Spec"]["TaskTemplate"]["ContainerSpec"].get("Env", [])
    env = {}
    for item in entries:
        key, value = item.split("=", 1)
        need(key not in env, "duplicate_service_environment")
        env[key] = value
    discovery = env.get("OPENID_PROVIDER_URL", "")
    suffix = ".well-known/openid-configuration"
    need(discovery.startswith("https://") and discovery.endswith("/" + suffix), "invalid_oidc_provider")
    issuer = discovery[:-len(suffix)]
    qwen_id = env.get("DEFAULT_MODELS", "")
    need(opaque_id(qwen_id) and ";" not in qwen_id and "," not in qwen_id,
         "ambiguous_default_model")
    containers = command("ps", "--filter", "label=com.docker.swarm.service.name=" + service,
                         "--filter", "status=running", "--format", "{{.ID}}").splitlines()
    need(len(containers) == 1 and bool(containers[0]), "ambiguous_openwebui_container")
    return containers[0], issuer, qwen_id


def build_snapshot(issuer: str, qwen_id: str, native: dict, groups: dict, users: list) -> dict:
    need(native.get("schemaVersion") == 1 and native.get("issuer") == issuer, "native_inventory_binding_conflict")
    admitted, admins = set(), set()
    seen = set()
    for user in users:
        current = subject(user.get("uuid"))
        need(current not in seen, "duplicate_identity_inventory")
        seen.add(current)
        membership = user.get("groups")
        need(isinstance(membership, list), "incomplete_identity_membership")
        membership = {str(item) for item in membership}
        if user.get("is_active") is not True or groups["ai-users"] not in membership:
            continue
        admitted.add(current)
        if groups["ai-admins"] in membership:
            admins.add(current)
    native_admins = native.get("adminSubjects")
    owners = native.get("managedOwnerSubjects")
    need(isinstance(native_admins, list) and isinstance(owners, list), "invalid_native_inventory")
    eligible_owners = admins & {subject(s) for s in native_admins}
    existing_owners = {subject(s) for s in owners}
    need(len(existing_owners) <= 1, "ambiguous_managed_model_owner")
    candidates = existing_owners if existing_owners else eligible_owners
    need(len(candidates) == 1 and candidates <= eligible_owners, "native_model_owner_unavailable")
    selected_owner = next(iter(candidates))
    identity = lambda s: {"issuer": issuer, "subject": s}
    result = {"schemaVersion": 1, "issuer": issuer, "qwenModelId": qwen_id, "qwenModelName": qwen_id,
              "modelOwnerIdentity": identity(selected_owner),
              "admittedIdentities": [identity(s) for s in sorted(admitted)]}
    Snapshot.parse(result, issuer + ".well-known/openid-configuration")
    return result


def invoke(container: str, snapshot: dict, apply: bool, command=docker) -> dict:
    args = ["exec", "-i", container, "python", CONTAINER_HELPER]
    if apply:
        args.append("--apply")
    value = json.loads(command(*args, payload=snapshot))
    need(isinstance(value, dict) and "error" not in value and value.get("schemaVersion") == 1,
         "native_helper_failed")
    return value


def revoke(container: str, issuer: str, qwen_id: str, command=docker) -> dict:
    value = json.loads(command("exec", container, "python", CONTAINER_HELPER, "--revoke-only",
        "--issuer", issuer, "--qwen-model-id", qwen_id))
    need(isinstance(value, dict) and value.get("schemaVersion") == 1 and value.get("mode") == "revoke"
         and value.get("modelsCreated") == 0 and value.get("modelsUpdated") == 0
         and value.get("readGrantsAdded") == 0 and type(value.get("readGrantsRemoved")) is int,
         "native_revocation_failed")
    return value


def reconcile(args, command=docker) -> tuple[dict, int]:
    container, issuer, qwen_id = service_context(args.service, command)
    command("cp", str(args.helper), container + ":" + CONTAINER_HELPER)
    try:
        native = json.loads(command("exec", container, "python", CONTAINER_HELPER, "--identity-inventory",
            "--issuer", issuer, "--qwen-model-id", qwen_id))
        config = private_json(args.config)
        auth = config.get("authentik", {})
        need(config.get("version") == 1 and auth.get("aiUsersGroup", "ai-users") == "ai-users"
             and auth.get("apiTokenFile") == TOKEN_FILE, "unexpected_identity_reader_contract")
        token = private_read(Path(auth["apiTokenFile"]), 32768).decode().strip()
        need(bool(token) and not any(c.isspace() for c in token), "invalid_identity_reader_credential")
        client = Authentik(auth.get("address", ""), token)
        provider = issuer + ".well-known/openid-configuration"
        need(urllib.parse.urlsplit(issuer).netloc == urllib.parse.urlsplit(client.address).netloc,
             "identity_origin_conflict")
        need(client.request(provider, authenticated=False).get("issuer") == issuer, "discovery_issuer_conflict")
        groups, users = client.inventory()
        value = build_snapshot(issuer, qwen_id, native, groups, users)
        output = invoke(container, value, False, command)
        if args.apply:
            # A protected validated recovery file must exist before any access
            # gain is committed, including the first successful application.
            atomic_snapshot(args.last_snapshot, value)
            output = invoke(container, value, True, command)
        return output, 0
    except Exception as error:
        code = str(error) if isinstance(error, ReconcileError) else "identity_inventory_unavailable"
        if args.apply:
            output = revoke(container, issuer, qwen_id, command)
            return {"schemaVersion": 1, "error": code, "readAccessRevoked": True,
                    "readGrantsRemoved": output["readGrantsRemoved"]}, 2
        raise ReconcileError(code) from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--install-config", action="store_true", help="write the independent root identity configuration")
    parser.add_argument("--authentik-address", help="known installation HTTPS origin, config installation only")
    parser.add_argument("--service", default="ai-stand_openwebui")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--last-snapshot", type=Path, default=DEFAULT_LAST)
    parser.add_argument("--helper", type=Path, default=Path(__file__).with_name("model_access.py"))
    parser.add_argument("--lock-file", type=Path, default=Path("/run/lock/ai-stand-openwebui-model-access.lock"))
    args = parser.parse_args(argv)
    try:
        need(os.geteuid() == 0 and args.service.endswith("_openwebui"), "root_control_plane_required")
        if args.install_config:
            need(args.config == DEFAULT_CONFIG, "unexpected_identity_config_path")
            atomic_snapshot(DEFAULT_CONFIG, identity_configuration(args.authentik_address))
            print('{"schemaVersion":1,"identityConfigInstalled":true}')
            return 0
        need(args.authentik_address is None, "invalid_arguments")
        import fcntl
        descriptor = os.open(args.lock_file, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "r+") as lock:
            info = os.fstat(lock.fileno())
            need(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o077,
                 "unprotected_reconcile_lock")
            fcntl.flock(lock, fcntl.LOCK_EX)
            output, code = reconcile(args)
        print(json.dumps(output, separators=(",", ":")))
        return code
    except ReconcileError as error:
        print(json.dumps({"schemaVersion": 1, "error": str(error)}, separators=(",", ":")))
        return 2
    except Exception:
        print('{"schemaVersion":1,"error":"snapshot_reconcile_failed"}')
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
