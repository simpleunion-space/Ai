"""Reconcile the ai-stand Local Qwen model ACL through Open WebUI 0.12.3 ORM.

Input is a root-validated, secret-free identity snapshot on stdin. Planning is
the default; only --apply commits. This module can be imported without Open
WebUI installed so the policy can be tested independently of the application.
"""
from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass
import json
import logging
import os
import stat
import sys
import time
from typing import Any
from urllib.parse import urlsplit
import uuid


SUPPORTED_VERSION = "0.12.3"
MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_IDENTITIES = 10000
NATIVE_BACKEND_PATH = "/app/backend"
NATIVE_SECRET_FILE = "/run/secrets/ai-stand-openwebui-secret-key"
MAX_NATIVE_SECRET_BYTES = 8192
PUBLIC_ERRORS = frozenset({
    "broad_read_grant_conflict", "concurrent_acl_change", "concurrent_model_change",
    "configured_issuer_mismatch", "duplicate_identity",
    "duplicate_native_identity", "duplicate_native_model", "duplicate_native_read_grant",
    "identity_issuer_mismatch", "invalid_arguments",
    "invalid_identities", "invalid_identity", "invalid_issuer", "invalid_managed_permission",
    "invalid_model_id", "invalid_model_name", "invalid_model_owner", "invalid_native_user_id",
    "invalid_snapshot_json", "invalid_snapshot", "invalid_subject", "managed_model_ownership_conflict",
    "native_issuer_mismatch", "native_model_owner_unavailable",
    "native_reconcile_failed", "snapshot_too_large", "unsupported_openwebui_version",
    "unsupported_snapshot_version", "invalid_revocation_target",
    "native_secret_file_unavailable", "unexpected_native_secret_file", "invalid_native_secret_file",
})


class ReconcileError(Exception):
    """A stable public error code; never include source values or exceptions."""


def need(condition: bool, code: str) -> None:
    if not condition:
        raise ReconcileError(code)


def subject(value: Any) -> str:
    need(isinstance(value, str), "invalid_subject")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        raise ReconcileError("invalid_subject") from None
    need(str(parsed) == value, "invalid_subject")
    return value


def opaque_id(value: Any) -> bool:
    return (isinstance(value, str) and 0 < len(value) <= 512 and value != "*"
            and not any(c.isspace() or ord(c) < 32 for c in value))


def bootstrap_native_import_path() -> None:
    """Use the pinned source image layout when launched as a /tmp script.

    Direct Python script execution sets sys.path[0] to /tmp; it does not add
    the working directory. Open WebUI's source-installed package lives in the
    protected /app/backend tree. The path is fixed, never an input selector.
    """
    if not sys.path or sys.path[0] != NATIVE_BACKEND_PATH:
        sys.path.insert(0, NATIVE_BACKEND_PATH)


def bootstrap_native_environment() -> None:
    """Mirror start.sh's mounted key expansion before importing native env.

    docker exec inherits the container definition, not start.sh's exported
    process environment. Read only the existing named Docker Secret; never
    generate a replacement or expose its value to argv, output, or errors.
    """
    if os.environ.get("WEBUI_SECRET_KEY"):
        return
    need(os.environ.get("WEBUI_SECRET_KEY_FILE") == NATIVE_SECRET_FILE,
         "unexpected_native_secret_file")
    need(hasattr(os, "O_NOFOLLOW"), "native_secret_file_unavailable")
    descriptor = None
    try:
        parent = os.lstat("/run/secrets")
        need(stat.S_ISDIR(parent.st_mode) and parent.st_uid == 0 and not parent.st_mode & 0o022,
             "invalid_native_secret_file")
        descriptor = os.open(NATIVE_SECRET_FILE, os.O_RDONLY | os.O_NOFOLLOW)
        info = os.fstat(descriptor)
        need(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022
             and 0 < info.st_size <= MAX_NATIVE_SECRET_BYTES, "invalid_native_secret_file")
        raw = bytearray()
        while len(raw) <= MAX_NATIVE_SECRET_BYTES:
            chunk = os.read(descriptor, MAX_NATIVE_SECRET_BYTES + 1 - len(raw))
            if not chunk:
                break
            raw.extend(chunk)
        need(0 < len(raw) <= MAX_NATIVE_SECRET_BYTES, "invalid_native_secret_file")
        # Shell command substitution removes trailing LF bytes, not spaces.
        key = bytes(raw).decode("utf-8").rstrip("\n")
        need(bool(key.strip()) and "\x00" not in key, "invalid_native_secret_file")
        os.environ["WEBUI_SECRET_KEY"] = key
    except (OSError, UnicodeError):
        raise ReconcileError("native_secret_file_unavailable") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


@dataclass(frozen=True)
class Snapshot:
    issuer: str
    qwen_id: str
    qwen_name: str
    admitted: frozenset[str]
    owner: str

    @classmethod
    def parse(cls, data: Any, provider_url: str) -> "Snapshot":
        keys = {"schemaVersion", "issuer", "qwenModelId", "qwenModelName",
                "admittedIdentities", "modelOwnerIdentity"}
        need(isinstance(data, dict) and set(data) == keys, "invalid_snapshot")
        need(type(data["schemaVersion"]) is int and data["schemaVersion"] == 1,
             "unsupported_snapshot_version")
        issuer = data["issuer"]
        need(isinstance(issuer, str), "invalid_issuer")
        try:
            url = urlsplit(issuer)
            valid_url = (url.scheme == "https" and bool(url.hostname) and not url.username
                         and not url.password and not url.query and not url.fragment)
        except ValueError:
            valid_url = False
        need(valid_url and not any(c.isspace() for c in issuer), "invalid_issuer")
        discovery = issuer + ("" if issuer.endswith("/") else "/") + ".well-known/openid-configuration"
        need(provider_url == discovery, "configured_issuer_mismatch")
        qwen_id = data["qwenModelId"]
        need(opaque_id(qwen_id), "invalid_model_id")
        name = data["qwenModelName"]
        need(isinstance(name, str) and 0 < len(name) <= 512
             and name.strip() == name and not any(ord(c) < 32 for c in name), "invalid_model_name")

        def identities(key: str) -> frozenset[str]:
            values = data[key]
            need(isinstance(values, list) and len(values) <= MAX_IDENTITIES, "invalid_identities")
            result = set()
            for item in values:
                need(isinstance(item, dict) and set(item) == {"issuer", "subject"}, "invalid_identity")
                need(item["issuer"] == issuer, "identity_issuer_mismatch")
                current = subject(item["subject"])
                need(current not in result, "duplicate_identity")
                result.add(current)
            return frozenset(result)

        admitted = identities("admittedIdentities")
        owner = data["modelOwnerIdentity"]
        need(isinstance(owner, dict) and set(owner) == {"issuer", "subject"}, "invalid_model_owner")
        need(owner["issuer"] == issuer, "identity_issuer_mismatch")
        return cls(issuer, qwen_id, name, admitted, subject(owner["subject"]))


@dataclass(frozen=True)
class UserState:
    id: str
    role: str
    oauth: Any


@dataclass(frozen=True)
class ModelState:
    id: str
    user_id: str | None
    base_model_id: str | None
    is_active: bool


@dataclass(frozen=True)
class GrantState:
    id: str
    resource_type: str
    resource_id: str
    principal_type: str
    principal_id: str
    permission: str


@dataclass(frozen=True)
class ModelChange:
    id: str
    create: bool
    name: str
    active: bool
    owner_id: str


@dataclass(frozen=True)
class Plan:
    models: tuple[ModelChange, ...]
    add: tuple[tuple[str, str], ...]
    remove: tuple[str, ...]
    registered: int
    awaiting_login: int
    qwen_readers: int

    def summary(self, applied: bool = False) -> dict:
        return {"schemaVersion": 1, "mode": "apply" if applied else "plan",
                "changed": bool(self.models or self.add or self.remove),
                "modelsCreated": sum(m.create for m in self.models),
                "modelsUpdated": sum(not m.create for m in self.models),
                "readGrantsAdded": len(self.add), "readGrantsRemoved": len(self.remove),
                "registeredIdentities": self.registered,
                "awaitingLoginIdentities": self.awaiting_login,
                "qwenReaders": self.qwen_readers}


def plan(snapshot: Snapshot, users: list[UserState], models: list[ModelState],
         grants: list[GrantState]) -> Plan:
    """Pure policy. All conflicts are checked before any mutation can run."""
    bound: dict[str, str] = {}
    roles: dict[str, str] = {}
    for user in users:
        need(opaque_id(user.id), "invalid_native_user_id")
        if not isinstance(user.oauth, dict) or "oidc" not in user.oauth:
            continue
        oidc = user.oauth["oidc"]
        if not isinstance(oidc, dict):
            continue
        try:
            current = subject(oidc.get("sub"))
        except ReconcileError:
            # Legacy/bootstrap records may contain an email in this field.
            # Such a value can never match a validated Authentik subject and
            # receives no grant. Never use it as a fallback identity.
            continue
        need("iss" not in oidc or oidc["iss"] == snapshot.issuer, "native_issuer_mismatch")
        need(current not in bound, "duplicate_native_identity")
        # Reserve even pending identities so a duplicate cannot silently win.
        bound[current] = user.id if user.role in {"user", "admin"} else ""
        roles[current] = user.role

    need(bool(bound.get(snapshot.owner)) and roles.get(snapshot.owner) == "admin",
         "native_model_owner_unavailable")
    owner_id = bound[snapshot.owner]

    qwen_users = {bound[s] for s in snapshot.admitted if bound.get(s)}
    managed = {snapshot.qwen_id}
    model_map: dict[str, ModelState] = {}
    for model in models:
        if model.id not in managed:
            continue
        need(model.id not in model_map, "duplicate_native_model")
        need(model.user_id in {None, owner_id} and model.base_model_id is None,
             "managed_model_ownership_conflict")
        model_map[model.id] = model

    changes = []
    for model_id, name, active in ((snapshot.qwen_id, snapshot.qwen_name, True),):
        current = model_map.get(model_id)
        if current is None:
            if active:
                changes.append(ModelChange(model_id, True, name, active, owner_id))
        elif current.is_active != active or current.user_id != owner_id:
            changes.append(ModelChange(model_id, False, name, active, owner_id))

    desired = {(snapshot.qwen_id, user_id) for user_id in qwen_users}
    current: dict[tuple[str, str], str] = {}
    remove = []
    for grant in grants:
        if grant.resource_type != "model" or grant.resource_id not in managed:
            continue
        need(grant.permission in {"read", "write"}, "invalid_managed_permission")
        # Public/group/wildcard readers cannot be reconciled to individual OIDC
        # subjects safely. An operator must resolve the conflicting policy.
        if grant.permission == "read":
            need(grant.principal_type == "user" and opaque_id(grant.principal_id),
                 "broad_read_grant_conflict")
            key = (grant.resource_id, grant.principal_id)
            need(key not in current, "duplicate_native_read_grant")
            current[key] = grant.id
            if key not in desired:
                remove.append(grant.id)
    add = sorted(desired - current.keys())
    return Plan(tuple(changes), tuple(add), tuple(sorted(remove)), len(qwen_users),
                len(snapshot.admitted) - len(qwen_users), len(qwen_users))


class NativeStore:
    """Pinned native ORM adapter; one transaction preserves unrelated rows."""

    def __init__(self, revoke_only: bool = False):
        bootstrap_native_import_path()
        bootstrap_native_environment()
        # Official env.VERSION supports both wheel and source-installed images.
        from open_webui.env import VERSION
        need(VERSION == SUPPORTED_VERSION, "unsupported_openwebui_version")
        from open_webui.internal.db import AsyncSessionLocal
        from open_webui.models.access_grants import AccessGrant
        from sqlalchemy import select

        self.session_factory = AsyncSessionLocal
        self.Grant, self.select = AccessGrant, select
        if revoke_only:
            return
        from open_webui.models.models import Model, ModelForm, ModelModel
        from open_webui.models.users import User

        self.Model,self.ModelForm, self.User = Model, ModelForm, User
        self.ModelModel = ModelModel

    async def revoke_reads(self, qwen_id: str) -> dict:
        """Delete only read grants for the exact current managed ID.

        This denial path intentionally needs no owner, User, model
        DTO, prior snapshot, or source inventory. It cannot grant access or
        create/update a model, and retains every write/unrelated grant row.
        """
        need(opaque_id(qwen_id), "invalid_revocation_target")
        ids = {qwen_id}
        async with self.session_factory() as db:
            async with db.begin():
                rows = (await db.execute(self.select(self.Grant).where(
                    self.Grant.resource_type == "model", self.Grant.resource_id.in_(ids),
                    self.Grant.permission == "read"))).scalars().all()
                for row in rows:
                    need(row.resource_type == "model" and row.resource_id in ids and row.permission == "read",
                         "invalid_revocation_target")
                    await db.delete(row)
                await db.flush()
        return {"schemaVersion": 1, "mode": "revoke", "changed": bool(rows),
                "modelsCreated": 0, "modelsUpdated": 0, "readGrantsAdded": 0,
                "readGrantsRemoved": len(rows)}

    async def read(self, db, snapshot: Snapshot):
        users = (await db.execute(self.select(self.User.id, self.User.role, self.User.oauth))).all()
        ids = [snapshot.qwen_id]
        models = (await db.execute(self.select(self.Model).where(self.Model.id.in_(ids)))).scalars().all()
        grants = (await db.execute(self.select(self.Grant).where(
            self.Grant.resource_type == "model", self.Grant.resource_id.in_(ids)))).scalars().all()
        return ([UserState(u.id, u.role, u.oauth) for u in users],
                [ModelState(m.id, m.user_id, m.base_model_id, m.is_active) for m in models],
                [GrantState(g.id, g.resource_type, g.resource_id, g.principal_type,
                            g.principal_id, g.permission) for g in grants])

    async def identity_inventory(self, issuer: str, qwen_id: str) -> dict:
        """Read-only host builder contract; never expose profiles or OAuth data."""
        async with self.session_factory() as db:
            async with db.begin():
                rows = (await db.execute(self.select(self.User.id, self.User.role, self.User.oauth))).all()
                native = {}
                seen = set()
                for row in rows:
                    oidc = row.oauth.get("oidc") if isinstance(row.oauth, dict) else None
                    if not isinstance(oidc, dict):
                        continue
                    try:
                        current = subject(oidc.get("sub"))
                    except ReconcileError:
                        continue
                    need("iss" not in oidc or oidc["iss"] == issuer, "native_issuer_mismatch")
                    need(current not in seen, "duplicate_native_identity")
                    seen.add(current)
                    if row.role == "admin":
                        native[row.id] = current
                models = (await db.execute(self.select(self.Model).where(
                    self.Model.id.in_([qwen_id])))).scalars().all()
                owners = set()
                for row in models:
                    if row.user_id is not None:
                        need(row.user_id in native, "managed_model_ownership_conflict")
                        owners.add(native[row.user_id])
                await db.rollback()
                return {"schemaVersion": 1, "issuer": issuer, "adminSubjects": sorted(native.values()),
                        "managedOwnerSubjects": sorted(owners)}

    async def write(self, db, result: Plan) -> None:
        now = int(time.time())
        # Remove denied readers before adding newly admitted readers. A failed
        # operation rolls back the entire transaction.
        for grant_id in result.remove:
            row = await db.get(self.Grant, grant_id)
            need(row is not None and row.permission == "read", "concurrent_acl_change")
            await db.delete(row)
        for change in result.models:
            if change.create:
                form = self.ModelForm(id=change.id, name=change.name, base_model_id=None,
                                      params={}, meta={}, is_active=change.active)
                row = self.Model(id=form.id, user_id=change.owner_id, base_model_id=None,
                    name=form.name, params={}, meta={}, is_active=form.is_active,
                    created_at=now, updated_at=now)
                self.ModelModel.model_validate(row)
                db.add(row)
            else:
                row = await db.get(self.Model, change.id)
                need(row is not None and row.user_id in {None, change.owner_id} and row.base_model_id is None,
                     "concurrent_model_change")
                row.user_id = change.owner_id
                row.is_active = change.active
                row.updated_at = now
                self.ModelModel.model_validate(row)
        for model_id, user_id in result.add:
            db.add(self.Grant(id=str(uuid.uuid4()), resource_type="model", resource_id=model_id,
                principal_type="user", principal_id=user_id, permission="read", created_at=now))
        await db.flush()

    async def reconcile(self, snapshot: Snapshot, apply: bool = False) -> Plan:
        async with self.session_factory() as db:
            async with db.begin():
                state = await self.read(db, snapshot)
                result = plan(snapshot, *state)
                if apply:
                    await self.write(db, result)
                else:
                    # A plan must never commit ORM events or incidental writes.
                    await db.rollback()
            return result


def read_snapshot(stream, provider_url: str) -> Snapshot:
    raw = stream.read(MAX_INPUT_BYTES + 1)
    need(len(raw) <= MAX_INPUT_BYTES, "snapshot_too_large")
    try:
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                need(key not in result, "invalid_snapshot_json")
                result[key] = value
            return result
        data = json.loads(raw, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        raise ReconcileError("invalid_snapshot_json") from None
    return Snapshot.parse(data, provider_url)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="commit the validated plan")
    mode.add_argument("--identity-inventory", action="store_true", help="read-only host builder identity contract")
    mode.add_argument("--revoke-only", action="store_true", help="delete only the managed model's read grants")
    parser.add_argument("--issuer", help="expected issuer, inventory/revocation modes only")
    parser.add_argument("--qwen-model-id", help="managed wire ID, inventory/revocation modes only")
    args = parser.parse_args(argv)
    # Native imports may log configuration/startup text. Only the fixed JSON
    # summary belongs on stdout, and native diagnostics must not expose input.
    logging.disable(logging.CRITICAL)
    try:
        provider = os.environ.get("OPENID_PROVIDER_URL", "")
        if args.identity_inventory or args.revoke_only:
            # Reuse the exact issuer and wire-ID validation of the normal path.
            checked = Snapshot.parse({"schemaVersion": 1, "issuer": args.issuer,
                "qwenModelId": args.qwen_model_id, "qwenModelName": "inventory",
                "modelOwnerIdentity": {"issuer": args.issuer, "subject": str(uuid.UUID(int=0))},
                "admittedIdentities": []}, provider)
        else:
            need(args.issuer is None and args.qwen_model_id is None, "invalid_arguments")
            snapshot = read_snapshot(sys.stdin.buffer, provider)
        from contextlib import redirect_stdout, redirect_stderr
        with open(os.devnull, "w", encoding="utf-8") as quiet:
            with redirect_stdout(quiet), redirect_stderr(quiet):
                store = NativeStore(revoke_only=args.revoke_only)
                if args.revoke_only:
                    output = asyncio.run(store.revoke_reads(checked.qwen_id))
                elif args.identity_inventory:
                    output = asyncio.run(store.identity_inventory(checked.issuer, checked.qwen_id))
                else:
                    output = asyncio.run(store.reconcile(snapshot, args.apply)).summary(args.apply)
        print(json.dumps(output, separators=(",", ":")))
        return 0
    except ReconcileError as error:
        code = str(error) if str(error) in PUBLIC_ERRORS else "native_reconcile_failed"
        print(json.dumps({"schemaVersion": 1, "error": code}, separators=(",", ":")))
        return 2
    except (Exception, SystemExit):
        print('{"schemaVersion":1,"error":"native_reconcile_failed"}')
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
