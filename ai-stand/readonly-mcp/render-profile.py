#!/usr/bin/env python3
"""Render the dynamic, installation-owned read-only MCP overlay.

The reconciler is the only writer of the manifest consumed here. It derives
that manifest from Authentik identity and user attribute metadata; it never
writes a credential value to it. A service entry is active only after the
reconciler has created its versioned Docker Secrets.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlparse


SAFE = re.compile(r"^[a-z][a-z0-9-]{0,48}$")
SUBJECT = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
SECRET = re.compile(r"^ai-stand-mcp-[a-z0-9-]{3,100}$")
HOST = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
KINDS = ("jira", "confluence", "imap")
MCP_PATH_PREFIX = re.compile(r"^/mcp/[a-z][a-z0-9-]{0,62}$")
# Docker's 63-character limit applies after the `ai-stand_` stack prefix.
# The slug is "u-" plus 23 hash characters (25), which fits even behind the
# longest service prefix: 9 + len("confluence-readonly-mcp-") + 25 = 58.
# The length is deliberately unchanged so existing service and Docker Secret
# names stay stable.
MAX_SUBJECT_SLUG_LENGTH = 25


def fail(message: str) -> None:
    raise SystemExit(f"readonly-mcp manifest error: {message}")


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def https_url(value: object, field: str) -> str:
    if not isinstance(value, str):
        fail(f"{field} must be a string")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.fragment:
        fail(f"{field} must be an absolute HTTPS URL without credentials or fragment")
    return value.rstrip("/")


def secret_name(value: object, field: str) -> str:
    if not isinstance(value, str) or not SECRET.fullmatch(value):
        fail(f"{field} must be an ai-stand-mcp-* Docker Secret name")
    return value


def hostname(value: object, field: str) -> str:
    if not isinstance(value, str) or not HOST.fullmatch(value) or "/" in value or "@" in value:
        fail(f"{field} must be a DNS hostname without a port or credentials")
    return value.lower()


def port(value: object, field: str) -> int:
    if not isinstance(value, int) or not 1 <= value <= 65535:
        fail(f"{field} must be an integer from 1 to 65535")
    return value


def load_manifest(path: Path) -> list[dict]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read {path}: {exc}")
    if not isinstance(raw, dict) or raw.get("version") != 2 or not isinstance(raw.get("users"), list):
        fail("top-level object must have version 2 and a users array")

    users: list[dict] = []
    seen_subjects: set[str] = set()
    seen_slugs: set[str] = set()
    for index, entry in enumerate(raw["users"]):
        if not isinstance(entry, dict):
            fail(f"users[{index}] must be an object")
        subject = entry.get("subject")
        slug = entry.get("slug")
        if not isinstance(subject, str) or not SUBJECT.fullmatch(subject):
            fail(f"users[{index}].subject must be an Authentik user UUID")
        if not isinstance(slug, str) or not SAFE.fullmatch(slug) or len(slug) > MAX_SUBJECT_SLUG_LENGTH:
            fail(f"users[{index}].slug must be a safe Docker service suffix of at most {MAX_SUBJECT_SLUG_LENGTH} characters")
        if subject in seen_subjects or slug in seen_slugs:
            fail("subject and slug values must be unique")
        seen_subjects.add(subject)
        seen_slugs.add(slug)

        raw_services = entry.get("services", {})
        if not isinstance(raw_services, dict):
            fail(f"users[{index}].services must be an object")
        services: dict[str, dict] = {}
        for kind in KINDS:
            service = raw_services.get(kind)
            if service is None:
                continue
            if not isinstance(service, dict):
                fail(f"users[{index}].services.{kind} must be an object")
            version = service.get("secretVersion")
            if not isinstance(version, int) or version < 1:
                fail(f"users[{index}].services.{kind}.secretVersion must be a positive integer")
            services[kind] = {
                "credentialSecret": secret_name(service.get("credentialSecret"), f"users[{index}].services.{kind}.credentialSecret"),
                "internalTokenSecret": secret_name(service.get("internalTokenSecret"), f"users[{index}].services.{kind}.internalTokenSecret"),
                "secretVersion": version,
            }

        users.append({"subject": subject.lower(), "slug": slug, "services": services})
    return users


def service_name(kind: str, slug: str) -> str:
    return f"{kind}-readonly-mcp-{slug}"


def render_compose(
    users: list[dict],
    images: dict[str, str],
    gateway_url: str,
    upstreams: dict[str, object],
    mcp_path_prefix: str,
) -> str:
    declared_secrets: set[str] = set()
    active_services = [(user, kind, config) for user in users for kind, config in user["services"].items()]
    lines = [
        "# Generated by ai-stand readonly MCP reconciler. DO NOT EDIT.",
        "services:" if active_services else "services: {}",
    ]
    for user, kind, config in active_services:
        name = service_name(kind, user["slug"])
        internal_token_secret = config["internalTokenSecret"]
        credential_secret = config["credentialSecret"]
        declared_secrets.update((credential_secret, internal_token_secret))
        prefix = kind.upper()
        lines.extend([
            f"  {name}:",
            f"    image: {images[kind]}",
            '    user: "10000:20000"',
            "    read_only: true",
            "    cap_drop:",
            "      - ALL",
            "    security_opt:",
            "      - no-new-privileges:true",
            "    environment:",
            "      ASPNETCORE_URLS: http://+:8080",
            # Version two deliberately permits only the initial PAT/basic
            # contract. OAuth fields cannot be smuggled in through a user
            # attribute.
            f"      {prefix}_AUTH_MODE: {quoted('basic' if kind == 'imap' else 'pat')}",
            f"      {prefix}_CREDENTIAL_SECRET_FILE: /run/secrets/{credential_secret}",
            f"      MCP_INTERNAL_TOKEN_FILE: /run/secrets/{internal_token_secret}",
            f"      {prefix}_REQUEST_TIMEOUT_SECONDS: \"60\"",
            f"      {prefix}_MAX_RESULTS: \"100\"",
            f"      {prefix}_MAX_ATTACHMENT_BYTES: \"10485760\"",
        ])
        if kind == "imap":
            lines.extend([
                f"      IMAP_HOST: {quoted(str(upstreams['imapHost']))}",
                f"      IMAP_PORT: \"{upstreams['imapPort']}\"",
                f"      IMAP_TLS_MODE: {quoted(str(upstreams['imapTlsMode']))}",
            ])
        else:
            lines.append(f"      {prefix}_BASE_URL: {quoted(str(upstreams[f'{kind}BaseUrl']))}")
        lines.extend([
            "    secrets:",
            f"      - source: {credential_secret}",
            f"        target: {credential_secret}",
            "        mode: 0444",
            f"      - source: {internal_token_secret}",
            f"        target: {internal_token_secret}",
            "        mode: 0444",
            "    networks:",
            "      ai-mcp-backend:",
            f"        aliases: [{name}]",
            "    deploy:",
            "      mode: replicated",
            "      replicas: 1",
            "      placement:",
            "        constraints:",
            "          - node.labels.ai-stand.agentgateway == true",
            "      restart_policy:",
            "        condition: any",
            "        delay: 10s",
        ])

    # Agentgateway receives backend bearer keys only.  Its Secret references
    # are intentionally *not* rendered as a partial Compose service here:
    # `docker stack deploy` would otherwise replace the complete existing
    # Agentgateway spec.  apply.sh updates just those secret attachments,
    # then atomically reloads the rendered route configuration.  External
    # PAT/IMAP credentials remain mounted solely into their owning MCP
    # container.
    if declared_secrets:
        lines.append("secrets:")
        for secret in sorted(declared_secrets):
            lines.extend([f"  {secret}:", "    external: true"])
    # This is a deliberately narrow stack fragment.  The full core stack
    # creates the network; every five-minute reconciliation later deploys
    # only MCP service definitions and cannot reset model/profile state.
    lines.extend([
        "networks:",
        "  ai-mcp-backend:",
        "    external: true",
        "    name: ai-stand_ai-mcp-backend",
    ])
    return "\n".join(lines) + "\n"


def target(kind: str, user: dict) -> tuple[str, str, str] | None:
    config = user["services"].get(kind)
    if not config:
        return None
    return (
        f"{kind}-{user['slug']}",
        f"http://{service_name(kind, user['slug'])}:8080/mcp",
        config["internalTokenSecret"],
    )


def render_agentgateway(
    base: str,
    users: list[dict],
    gateway_url: str,
    issuer: str,
    client_id: str,
    openwebui_url: str,
    mcp_path_prefix: str,
) -> str:
    marker = "# READONLY_MCP_ROUTES_RENDER"
    if base.count(marker) != 1:
        fail("Agentgateway base config must contain exactly one readonly MCP marker")
    paths = {
        "jira": f"{mcp_path_prefix}/jira-readonly-mcp",
        "confluence": f"{mcp_path_prefix}/confluence-readonly-mcp",
        "imap": f"{mcp_path_prefix}/imap-readonly-mcp",
    }
    routes: list[str] = []
    for kind, path in paths.items():
        resolved = [(user, candidate) for user in users if (candidate := target(kind, user)) is not None]
        # Administrative UI access is intentionally not an entitlement to a
        # person's external Jira/Confluence/IMAP account. Only ai-users may
        # reach the user-scoped data plane; an administrator who needs MCP
        # access must explicitly also be an ai-users member.
        membership_rule = "'ai-users' in jwt.groups"
        lines = [
            f"  - name: readonly-{kind}",
            "    gateways: [default]",
            "    matches:",
            "      - path:",
            f"          pathPrefix: {path}",
            "      - path:",
            f"          pathPrefix: /.well-known/oauth-protected-resource{path}",
            "      - path:",
            f"          pathPrefix: /.well-known/oauth-authorization-server{path}",
            "    policies:",
            "      cors:",
            f"        allowOrigins: [{openwebui_url}]",
            "        allowHeaders: [authorization, content-type, mcp-protocol-version, mcp-session-id]",
            "        exposeHeaders: [Mcp-Session-Id]",
            "      mcpAuthentication:",
            "        mode: strict",
            f"        issuer: {issuer}",
            f"        audiences: [{client_id}]",
            "        provider:",
            "          authentik: {}",
            f"        clientId: {client_id}",
            "        resourceMetadata:",
            f"          resource: {gateway_url}{path}",
            "          scopesSupported: [openid, profile, email, groups]",
            "          bearerMethodsSupported: [header]",
            "      mcpAuthorization:",
            "        rules:",
            # This route-level requirement runs before any MCP invocation.
            # Per-subject allow rules then select only that subject's named
            # target. Do not collapse them into one broad expression: each
            # owner/target association remains an independently auditable,
            # fail-closed rule in the rendered configuration.
            f"          - require: {quoted(membership_rule)}",
        ]
        if resolved:
            for user, (name, _, _) in resolved:
                subject = user["subject"]
                target_rule = f'jwt.sub == "{subject}" && mcp.tool.target == "{name}"'
                lines.append(f"          - allow: {quoted(target_rule)}")
        else:
            # Keep OAuth metadata discoverable before anyone stores
            # credentials, but deny every MCP method until a target exists.
            # This deliberately yields authorization denial rather than
            # routing a subject to a fallback or returning an ambiguous 404.
            lines.append('          - allow: "false"')
        lines.extend(["    backends:", "      - mcp:"])
        if resolved:
            lines.append("          targets:")
        else:
            # Agentgateway's schema requires an array. An explicit empty
            # array keeps the OAuth-protected resource route valid while the
            # preceding false allow rule rejects all MCP dispatches.
            lines.append("          targets: []")
        for name, host, token in (candidate for _, candidate in resolved):
            lines.extend([
                f"          - name: {name}",
                "            mcp:",
                f"              host: {host}",
                "            policies:",
                "              backendAuth:",
                "                key:",
                "                  value:",
                f"                    file: /run/secrets/{token}",
            ])
        routes.extend(lines)

    return base.replace(marker, "routes: []" if not routes else "routes:\n" + "\n".join(routes))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", "--inventory", dest="manifest", type=Path, required=True)
    parser.add_argument("--base-agentgateway-config", type=Path, required=True)
    parser.add_argument("--agentgateway-config-out", type=Path, required=True)
    parser.add_argument("--compose-out", type=Path, required=True)
    parser.add_argument("--agentgateway-url", required=True)
    parser.add_argument("--openwebui-url", required=True)
    parser.add_argument("--mcp-issuer", required=True)
    parser.add_argument("--mcp-client-id", default="agentgateway-mcp")
    parser.add_argument("--mcp-path-prefix", default="/mcp/work")
    parser.add_argument("--jira-base-url", required=True)
    parser.add_argument("--confluence-base-url", required=True)
    parser.add_argument("--imap-host", required=True)
    parser.add_argument("--imap-port", type=int, default=993)
    parser.add_argument("--imap-tls-mode", choices=("implicit", "starttls"), default="implicit")
    parser.add_argument("--jira-image", required=True)
    parser.add_argument("--confluence-image", required=True)
    parser.add_argument("--imap-image", required=True)
    args = parser.parse_args()

    users = load_manifest(args.manifest)
    gateway_url = https_url(args.agentgateway_url, "agentgateway URL")
    openwebui_url = https_url(args.openwebui_url, "Open WebUI URL")
    if not MCP_PATH_PREFIX.fullmatch(args.mcp_path_prefix):
        fail("MCP path prefix must match /mcp/<lowercase-slug>")
    issuer = https_url(args.mcp_issuer, "MCP issuer") + "/"
    if not SAFE.fullmatch(args.mcp_client_id):
        fail("MCP client ID must be a safe identifier")
    upstreams = {
        "jiraBaseUrl": https_url(args.jira_base_url, "Jira base URL"),
        "confluenceBaseUrl": https_url(args.confluence_base_url, "Confluence base URL"),
        "imapHost": hostname(args.imap_host, "IMAP host"),
        "imapPort": port(args.imap_port, "IMAP port"),
        "imapTlsMode": args.imap_tls_mode,
    }
    base = args.base_agentgateway_config.read_text(encoding="utf-8")
    args.agentgateway_config_out.parent.mkdir(parents=True, exist_ok=True)
    args.compose_out.parent.mkdir(parents=True, exist_ok=True)
    args.agentgateway_config_out.write_text(
        render_agentgateway(
            base,
            users,
            gateway_url,
            issuer,
            args.mcp_client_id,
            openwebui_url,
            args.mcp_path_prefix,
        ),
        encoding="utf-8",
    )
    args.compose_out.write_text(
        render_compose(
            users,
            {
                "jira": args.jira_image,
                "confluence": args.confluence_image,
                "imap": args.imap_image,
            },
            gateway_url,
            upstreams,
            args.mcp_path_prefix,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
