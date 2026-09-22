#!/usr/bin/env python3
"""Fail-closed descriptor model for isolated MetaMCP tenants.

This module deliberately contains no Docker or database calls.  It turns a
validated Authentik identity and an already-established MetaMCP ownership map
into a non-secret desired-state descriptor.  A deployment controller may use
that descriptor to create a tenant runtime, but must never infer a tenant from
an email address or from a caller-provided slug.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass


SUBJECT = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
SLUG = re.compile(r"^[a-z][a-z0-9-]{0,48}$")
SECRET = re.compile(r"^ai-stand-mcp-[a-z0-9-]{3,100}$")


class TenantDescriptorError(ValueError):
    """Raised before a potentially ambiguous tenant descriptor is emitted."""


@dataclass(frozen=True)
class TenantIdentity:
    issuer: str
    subject: str
    slug: str
    metamcp_user_id: str
    backend_key_secret: str

    def validate(self) -> None:
        if not self.issuer.startswith("https://") or any(char.isspace() for char in self.issuer):
            raise TenantDescriptorError("issuer must be an absolute HTTPS URL")
        if not SUBJECT.fullmatch(self.subject):
            raise TenantDescriptorError("subject must be a UUID")
        if not SLUG.fullmatch(self.slug):
            raise TenantDescriptorError("slug is unsafe")
        if not self.metamcp_user_id or any(char.isspace() for char in self.metamcp_user_id):
            raise TenantDescriptorError("MetaMCP user ID is missing or unsafe")
        if not SECRET.fullmatch(self.backend_key_secret):
            raise TenantDescriptorError("backend key secret name is unsafe")


def tenant_id(identity: TenantIdentity) -> str:
    """Stable opaque ID; do not use a mutable username/email in resource names."""
    identity.validate()
    digest = hashlib.sha256(f"{identity.issuer}\x00{identity.subject.lower()}".encode("utf-8")).hexdigest()
    return f"t-{digest[:20]}"


def descriptor_for(identity: TenantIdentity) -> dict:
    """Return the non-secret runtime contract for exactly one isolated tenant."""
    identity.validate()
    stable_id = tenant_id(identity)
    subject = identity.subject.lower()
    private_network = f"ai-metamcp-tenant-{subject}"
    state_root = f"/mnt/storage/metamcp-data/tenant-{subject}"
    router_service = f"metamcp-tenant-router-{stable_id}"

    return {
        "tenantId": stable_id,
        "identity": {
            "issuer": identity.issuer.rstrip("/"),
            "subject": subject,
            "metamcpUserId": identity.metamcp_user_id,
        },
        "state": {
            "root": state_root,
            "metamcp": f"{state_root}/metamcp",
            "postgres": f"{state_root}/postgres",
            "dind": f"{state_root}/dind",
        },
        "networks": {
            "tenant": private_network,
            # Only this narrow router connects the private tenant to the
            # Agentgateway-facing MCP network.  MetaMCP itself and its DIND
            # do not receive ai-core or ai-mcp-backend membership.
            "agentgatewayIngress": "ai-mcp-backend",
        },
        "services": {
            "metamcp": f"metamcp-tenant-{stable_id}",
            "postgres": f"metamcp-tenant-postgres-{stable_id}",
            "rootlessDind": f"metamcp-tenant-dind-{stable_id}",
            "router": router_service,
        },
        "agentgateway": {
            "target": f"personal-{identity.slug}",
            "url": f"http://{router_service}:8080/mcp",
            "backendKeySecret": identity.backend_key_secret,
        },
        "isolation": {
            "rootlessDind": True,
            "hostDockerSocket": False,
            "vaultMount": False,
            "sharedCoreNetwork": False,
            "crossTenantVolumes": False,
            "privateCidrEgressDenied": True,
        },
    }
