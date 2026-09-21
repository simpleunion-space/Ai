# Jira read-only MCP specification

## Purpose

Provide MCP clients with narrowly scoped, read-only access to one Jira Data Center account through the native Jira REST API. A deployment creates one server instance per external account. Agentgateway, not this process, authenticates people with Authentik and routes each Authentik `sub` only to that person's instance.

## Interface

- Transport: Streamable HTTP JSON-RPC 2.0 at `POST /mcp`; `GET /healthz` is an internal health probe.
- Every `/mcp` request must have an exact `Authorization: Bearer` token whose secret is read from required `MCP_INTERNAL_TOKEN_FILE`. The server hashes the candidate and secret before constant-time comparison; it never logs either token. `/healthz` requires no bearer token.
- MCP methods: `initialize`, `notifications/initialized`, `ping`, `tools/list`, and `tools/call`.
- Tools: `jira_search_issues`, `jira_get_issue`, `jira_list_comments`, `jira_list_projects`, `jira_get_attachment`.
- The service does not implement an authentication scheme for public callers, user provisioning, Agentgateway routing, Open WebUI/OpenClaw configuration, or MetaMCP integration.

## Safety constraints

- The upstream base URI, token endpoint, credentials, response limits and timeout are static deployment configuration; tools cannot provide a URL, host, REST path, HTTP method, auth header, or arbitrary fields/expand option.
- Jira requests are `GET` only. Attachment data is fetched only after metadata has returned an HTTPS URL with the same scheme, host and port as the configured Jira origin.
- No Jira mutations: issue/project creation or updates, comments, transitions, assignments, worklogs, links, watches, votes, delete requests and bulk operations are absent from the public tool list and code path.
- Basic, PAT, OAuth client-credentials and authorization-code refresh-token credentials are supported. OAuth access tokens live only in process memory and are refreshed at most once concurrently. Rotating refresh tokens are AES-GCM encrypted and atomically persisted in required per-instance `JIRA_TOKEN_STATE_DIR`, using a 256-bit key from `JIRA_TOKEN_STATE_KEY_FILE`; no plaintext refresh token enters the volume.
- TLS verification and redirect refusal are mandatory. The container runs non-root; deployment must use read-only rootfs, dropped capabilities, no Docker socket, no published port and no host mounts other than explicit secrets/trust material.

## Limits and errors

- Result pages: configurable ceiling 1–100, default 50.
- Attachment bytes: configurable ceiling up to 50 MiB, default 10 MiB.
- JSON body: configurable ceiling up to 50 MiB, default 8 MiB.
- Upstream timeout: configurable 1–300 seconds, default 30 seconds.
- Invalid tool input becomes JSON-RPC `-32602`; Jira/backend failures are returned as MCP `isError` tool results without exposing credentials or upstream details.

## Non-goals

This module does not contain secrets, inventory records, personal routing, Nginx, Agentgateway, Authentik, Open WebUI, OpenClaw, MetaMCP, or any `ai-stand` deployment configuration.
