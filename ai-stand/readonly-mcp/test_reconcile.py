#!/usr/bin/env python3
"""Offline unit tests for the host-only Authentik-attribute/Swarm reconciler."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace


MODULE_PATH = Path(__file__).with_name("reconcile.py")
# The reconciler runs only on Linux hosts and uses fcntl solely for its
# process lock. Keep offline contract tests runnable from a Windows checkout.
if sys.platform == "win32":
    fcntl_stub = ModuleType("fcntl")
    fcntl_stub.LOCK_EX = 0
    fcntl_stub.LOCK_NB = 0
    fcntl_stub.flock = lambda *_args, **_kwargs: None
    sys.modules.setdefault("fcntl", fcntl_stub)
SPEC = importlib.util.spec_from_file_location("readonly_mcp_reconcile", MODULE_PATH)
assert SPEC and SPEC.loader
reconcile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = reconcile
SPEC.loader.exec_module(reconcile)


class ReconcilerContractTests(unittest.TestCase):
    SUBJECT = "01234567-89ab-cdef-0123-456789abcdef"

    def test_subject_slug_is_stable_opaque_and_fits_the_longest_service_name(self) -> None:
        slug = reconcile.slug_for(self.SUBJECT)
        self.assertEqual(slug, "u-a23d006bb020a81dfd1afa1")
        self.assertLessEqual(len("ai-stand_gigacode-subscription-bridge-" + slug), 63)

    def test_accepts_only_fixed_credential_shapes(self) -> None:
        self.assertEqual(reconcile.credential_record("jira", {"pat": "token"}), b'{"pat":"token"}')
        self.assertEqual(
            reconcile.credential_record("imap", {"username": "user@example.invalid", "password": "secret"}),
            b'{"username":"user@example.invalid","password":"secret"}',
        )
        self.assertEqual(
            reconcile.credential_record("gigacode", {"device_id": "a" * 64}),
            b"a" * 64,
        )
        with self.assertRaises(reconcile.ReconcileError):
            reconcile.credential_record("confluence", {"pat": "token", "url": "https://attacker.invalid"})
        with self.assertRaises(reconcile.ReconcileError):
            reconcile.credential_record("imap", {"username": "user@example.invalid"})
        with self.assertRaises(reconcile.ReconcileError):
            reconcile.credential_record("gigacode", {"device_id": "not-a-device-id"})

    def test_credentials_for_user_reassembles_flat_attributes_or_signals_missing(self) -> None:
        complete = {"attributes": {"ai_stand_mcp_jira_pat": "token"}}
        self.assertEqual(reconcile.credentials_for_user(complete, "jira"), {"pat": "token"})

        blank = {"attributes": {"ai_stand_mcp_jira_pat": "   "}}
        self.assertIsNone(reconcile.credentials_for_user(blank, "jira"))

        absent = {"attributes": {}}
        self.assertIsNone(reconcile.credentials_for_user(absent, "jira"))

        no_attributes = {}
        self.assertIsNone(reconcile.credentials_for_user(no_attributes, "jira"))

        partial_imap = {"attributes": {"ai_stand_mcp_imap_username": "user"}}
        self.assertIsNone(reconcile.credentials_for_user(partial_imap, "imap"))

        complete_imap = {
            "attributes": {
                "ai_stand_mcp_imap_username": "user",
                "ai_stand_mcp_imap_password": "secret",
            }
        }
        self.assertEqual(
            reconcile.credentials_for_user(complete_imap, "imap"),
            {"username": "user", "password": "secret"},
        )

    def _settings(self, **overrides: object) -> "reconcile.Settings":
        base = dict(
            authentik_address="https://authentik.example.invalid",
            authentik_api_token_file=Path("/nonexistent"),
            authentik_group="ai-users",
            jira_base_url="https://jira.installation.invalid",
            confluence_base_url="https://confluence.installation.invalid",
            imap_host="imap.installation.invalid",
            imap_port=993,
            imap_tls_mode="implicit",
            upstream_ca_file=None,
            metamcp_enabled=False,
            allow_user_upstream_overrides=False,
        )
        base.update(overrides)
        return reconcile.Settings(**base)

    def test_effective_settings_for_user_applies_only_valid_overrides_when_enabled(self) -> None:
        disabled = self._settings(allow_user_upstream_overrides=False)
        user = {"attributes": {"ai_stand_mcp_jira_base_url": "https://jira.personal.invalid"}}
        # Disabled installation-wide: attributes are never consulted.
        self.assertIs(reconcile.effective_settings_for_user(user, disabled), disabled)

        enabled = self._settings(allow_user_upstream_overrides=True)

        # A valid override replaces just that one field.
        result = reconcile.effective_settings_for_user(user, enabled)
        self.assertEqual(result.jira_base_url, "https://jira.personal.invalid")
        self.assertEqual(result.confluence_base_url, enabled.confluence_base_url)

        # An invalid override (not HTTPS) is silently ignored, not an error.
        invalid_user = {"attributes": {"ai_stand_mcp_jira_base_url": "http://insecure.invalid"}}
        self.assertEqual(
            reconcile.effective_settings_for_user(invalid_user, enabled).jira_base_url,
            enabled.jira_base_url,
        )

        # No attributes at all: falls back to the installation defaults.
        self.assertIs(reconcile.effective_settings_for_user({}, enabled), enabled)

    def test_collects_active_and_personal_secret_references(self) -> None:
        manifest = {
            "version": 2,
            "users": [{
                "slug": "u-00000000000000000000000000000000",
                "services": {
                    "jira": {
                        "credentialSecret": "ai-stand-mcp-jira-u-00000000000000000000000000000000-credentials-v1",
                        "internalTokenSecret": "ai-stand-mcp-jira-u-00000000000000000000000000000000-internal-v1",
                    },
                    "gigacode": {
                        "deviceIdSecret": "ai-stand-gigacode-u-00000000000000000000000000000000-device-v1",
                        "internalTokenSecret": "ai-stand-gigacode-u-00000000000000000000000000000000-internal-v1",
                    },
                },
                "metamcp": {"backendKeySecret": "ai-stand-mcp-personal-u-00000000000000000000000000000000-backend-key"},
            }],
        }
        self.assertEqual(
            reconcile.referenced_secrets(manifest),
            {
                "ai-stand-mcp-jira-u-00000000000000000000000000000000-credentials-v1",
                "ai-stand-mcp-jira-u-00000000000000000000000000000000-internal-v1",
                "ai-stand-gigacode-u-00000000000000000000000000000000-device-v1",
                "ai-stand-gigacode-u-00000000000000000000000000000000-internal-v1",
                "ai-stand-mcp-personal-u-00000000000000000000000000000000-backend-key",
            },
        )

    def test_old_manifest_is_upgraded_with_empty_retired_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps({"version": 2, "users": []}), encoding="utf-8")
            self.assertEqual(reconcile.read_manifest(path)["retiredSecrets"], [])

    def test_manifest_rejects_unsafe_retired_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps({"version": 2, "users": [], "retiredSecrets": ["wrong"]}), encoding="utf-8")
            with self.assertRaises(reconcile.ReconcileError):
                reconcile.read_manifest(path)

    def test_ai_users_ignores_inactive_group_members(self) -> None:
        client = object.__new__(reconcile.Authentik)
        client.settings = SimpleNamespace(authentik_group="ai-users")

        active = {"pk": 1, "uuid": self.SUBJECT, "groups": [7], "is_active": True}
        inactive = {"pk": 2, "uuid": "fedcba98-7654-3210-fedc-ba9876543210", "groups": [7], "is_active": False}
        missing_flag = {"pk": 3, "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "groups": [7]}

        def list_records(path: str) -> list[dict]:
            if path.startswith("/core/groups/"):
                return [{"pk": 7, "name": "ai-users"}]
            self.assertIn("groups_by_pk=7", path)
            return [active, inactive, missing_flag]

        client._list = list_records
        self.assertEqual(client.ai_users(), [active])


if __name__ == "__main__":
    unittest.main()
