# Confluence read-only MCP specification

## Purpose

Provide a custom C#/.NET 10 MCP server that accepts the MCP Streamable HTTP
protocol and reads data from exactly one Confluence Data Center account through
its native REST API. It is an internal backend service, normally one instance
per user/account and reached only through Agentgateway.

## Security requirements

- The public MCP surface has read-only tools only. No create, update, delete,
  comment, label, attachment upload, space administration, or arbitrary REST
  proxy operation may be exposed.
- The upstream base URL is fixed at startup, must use HTTPS, and is never
  supplied by a caller. TLS certificate verification remains enabled.
- The installation renderer supplies one `CONFLUENCE_CREDENTIAL_SECRET_FILE`
  JSON Docker Secret. It contains the selected mode's `username`/`password`,
  `token`, or `client_id`/`client_secret`/`refresh_token`/`token_url` fields and
  optional `scope`. Legacy separate Secret-file settings are retained only for
  manual compatibility. Supported authentication abstractions are Basic, PAT
  bearer, OAuth 2 client credentials, and OAuth 2 refresh-token grants.
- `MCP_INTERNAL_TOKEN_FILE` is a required per-instance Agentgateway-to-backend
  bearer secret. `/mcp` rejects any missing or non-matching bearer token with
  `401`; comparisons are constant-time and the token is never logged.
- Refresh-token state, if required, is stored at
  `CONFLUENCE_TOKEN_STATE_DIR/refresh-token.state`, encrypted with the
  `CONFLUENCE_TOKEN_STATE_KEY_FILE` AES-GCM key in an account-specific
  persistent volume. Access tokens stay in memory.
- Logs must not contain credentials, authorization headers, request arguments,
  CQL, content bodies, attachment names, or upstream response bodies.
- The container runs non-root with a read-only root filesystem, dropped Linux
  capabilities, no Docker socket, no published port, and no access to another
  account's secrets or token state.

## Tools and limits

The server exposes content search/read, comments read, attachments list/read.
All Confluence requests are HTTP GET. Result pagination, REST JSON body size,
attachment bytes, and upstream time are bounded by static configuration. The
attachment reader accepts only an attachment content ID, verifies type
`attachment`, and follows only its same-origin relative download link.

## Integration boundaries

Agentgateway performs user authentication and selects this account-specific
backend. This server does not parse end-user identity or implement tenancy.
Authentik, Agentgateway routes, Docker Secrets, the inventory, deployment, and
Open WebUI/OpenClaw integration are owned by `ai-stand`, not this module.
