#!/usr/bin/env python3
"""Validation and atomic I/O for the MetaMCP tenant control-plane manifest."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from tenant_runtime import SECRET, SLUG, SUBJECT, TenantDescriptorError


class TenantManifestError(ValueError):
    """The manifest is invalid and must not be applied partially."""


def fail(message: str) -> None:
    raise TenantManifestError(f"MetaMCP tenant manifest error: {message}")


def validate_inventory(payload: Any) -> list[dict[str, str]]:
    """Read the strictly non-secret identity inventory supplied by reconciler."""
    if not isinstance(payload, dict) or payload.get("version") != 1:
        fail("top-level version must be 1")
    users = payload.get("users")
    if not isinstance(users, list):
        fail("users must be an array")

    normalized: list[dict[str, str]] = []
    subjects: set[tuple[str, str]] = set()
    slugs: set[str] = set()
    emails: set[str] = set()
    for index, user in enumerate(users):
        if not isinstance(user, dict):
            fail(f"users[{index}] must be an object")
        issuer = user.get("issuer")
        subject = user.get("subject")
        slug = user.get("slug")
        email = user.get("legacyEmail")
        personal = user.get("metamcp")
        if not isinstance(issuer, str) or not issuer.startswith("https://") or any(char.isspace() for char in issuer):
            fail(f"users[{index}].issuer must be an HTTPS URL")
        issuer = issuer.rstrip("/")
        if not isinstance(subject, str) or not SUBJECT.fullmatch(subject):
            fail(f"users[{index}].subject must be an Authentik UUID")
        subject = subject.lower()
        if not isinstance(slug, str) or not SLUG.fullmatch(slug):
            fail(f"users[{index}].slug is unsafe")
        if not isinstance(email, str) or not email or any(char.isspace() for char in email):
            fail(f"users[{index}].legacyEmail is required only for an explicit migration")
        if not isinstance(personal, dict):
            fail(f"users[{index}].metamcp must be an object")
        backend_key_secret = personal.get("backendKeySecret")
        if not isinstance(backend_key_secret, str) or not SECRET.fullmatch(backend_key_secret):
            fail(f"users[{index}].metamcp.backendKeySecret is unsafe")

        identity_key = (issuer, subject)
        email_key = email.casefold()
        if identity_key in subjects or slug in slugs or email_key in emails:
            fail("issuer/subject, slug and legacyEmail must each be unique")
        subjects.add(identity_key)
        slugs.add(slug)
        emails.add(email_key)
        normalized.append({
            "issuer": issuer,
            "subject": subject,
            "slug": slug,
            "legacyEmail": email,
            "backendKeySecret": backend_key_secret,
        })
    return normalized


def load_inventory(path: Path) -> list[dict[str, str]]:
    try:
        return validate_inventory(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read inventory {path}: {exc}")


def atomic_write_json(path: Path, payload: dict) -> None:
    """Replace a manifest as a single file; never leave a partial desired state."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
