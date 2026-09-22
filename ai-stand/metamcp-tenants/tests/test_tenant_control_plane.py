#!/usr/bin/env python3
"""Offline contract tests for the MetaMCP tenant control-plane source."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE))

from provision import build_runtime_manifest, copy_escape, transaction_script  # noqa: E402
from tenant_manifest import TenantManifestError, atomic_write_json, validate_inventory  # noqa: E402
from tenant_runtime import TenantDescriptorError, TenantIdentity, descriptor_for  # noqa: E402


class TenantControlPlaneTests(unittest.TestCase):
    subject = "01234567-89ab-cdef-0123-456789abcdef"
    issuer = "https://authentik.example.invalid/application/o/ai-stand"
    slug = "u-0123456789abcdef0123456789abcdef"
    secret = "ai-stand-mcp-personal-u-0123456789abcdef0123456789abcdef-backend-key"

    def inventory(self) -> dict:
        return {
            "version": 1,
            "users": [{
                "issuer": self.issuer,
                "subject": self.subject,
                "slug": self.slug,
                "legacyEmail": "person@example.invalid",
                "metamcp": {"backendKeySecret": self.secret},
            }],
        }

    def test_descriptor_has_only_narrow_router_egress(self) -> None:
        descriptor = descriptor_for(TenantIdentity(
            issuer=self.issuer,
            subject=self.subject,
            slug=self.slug,
            metamcp_user_id="user-1",
            backend_key_secret=self.secret,
        ))
        self.assertEqual(descriptor["networks"]["agentgatewayIngress"], "ai-mcp-backend")
        self.assertIn(self.subject, descriptor["networks"]["tenant"])
        self.assertEqual(descriptor["state"]["root"], f"/mnt/storage/metamcp-data/tenant-{self.subject}")
        self.assertTrue(descriptor["isolation"]["rootlessDind"])
        self.assertFalse(descriptor["isolation"]["hostDockerSocket"])
        self.assertFalse(descriptor["isolation"]["vaultMount"])
        self.assertFalse(descriptor["isolation"]["sharedCoreNetwork"])

    def test_descriptor_rejects_unsafe_identity(self) -> None:
        with self.assertRaises(TenantDescriptorError):
            descriptor_for(TenantIdentity(
                issuer="http://not-tls.invalid",
                subject=self.subject,
                slug=self.slug,
                metamcp_user_id="user-1",
                backend_key_secret=self.secret,
            ))

    def test_inventory_rejects_ambiguous_email_migration(self) -> None:
        payload = self.inventory()
        copied = json.loads(json.dumps(payload))
        copied["users"].append({
            "issuer": self.issuer,
            "subject": "fedcba98-7654-3210-fedc-ba9876543210",
            "slug": "u-fedcba9876543210fedcba9876543210",
            "legacyEmail": "PERSON@example.invalid",
            "metamcp": {"backendKeySecret": "ai-stand-mcp-personal-u-fedcba9876543210fedcba9876543210-backend-key"},
        })
        with self.assertRaises(TenantManifestError):
            validate_inventory(copied)

    def test_transaction_uses_copy_parameters_not_interpolated_values(self) -> None:
        user = validate_inventory(self.inventory())[0]
        sql = transaction_script([user], migrate=True)
        self.assertIn("COPY _ai_stand_tenant_request", sql)
        self.assertIn("LOCK TABLE ai_stand_metamcp_tenant_identities", sql)
        self.assertIn("ISOLATION LEVEL SERIALIZABLE", sql)
        self.assertNotIn("VALUES ('https://authentik.example.invalid", sql)
        self.assertIn("legacy email ownership is absent or ambiguous", sql)

    def test_copy_text_encoding_keeps_columns_separate(self) -> None:
        row = copy_escape(["alpha", "tab\tvalue", "slash\\value"])
        self.assertEqual(row, "alpha\ttab\\tvalue\tslash\\\\value\n")

    def test_manifest_atomic_write_never_contains_email_or_raw_key(self) -> None:
        runtime = build_runtime_manifest([{
            "issuer": self.issuer,
            "subject": self.subject,
            "slug": self.slug,
            "metamcpUserId": "user-1",
            "backendKeySecret": self.secret,
        }])
        self.assertNotIn("person@example.invalid", json.dumps(runtime))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tenant-manifest.json"
            atomic_write_json(target, runtime)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            saved = json.loads(target.read_text(encoding="utf-8"))
            self.assertEqual(saved["tenants"][0]["identity"]["subject"], self.subject)


if __name__ == "__main__":
    unittest.main()
