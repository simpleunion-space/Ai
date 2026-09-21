# IMAP read-only MCP specification

## Goal

Expose exactly one configured IMAP account through MCP Streamable HTTP for a
single Agentgateway target. The server is a backend adapter, not a multi-user
authentication boundary: Agentgateway selects the per-user instance and holds
the backend bearer credential.

## Safety requirements

- Require TLS for every IMAP connection (`SslOnConnect` or mandatory
  `STARTTLS`) and validate the server certificate chain/name.
- Open folders only with `FolderAccess.ReadOnly` (`EXAMINE`) and retrieve data
  without setting `\\Seen` (`BODY.PEEK`).
- Do not expose write tools or call IMAP `STORE`, `APPEND`, `COPY`, `MOVE`,
  `EXPUNGE`, or any write-capable folder operation.
- Configure one static upstream host and port at startup. No caller input may
  select an endpoint, scheme, credential, or authentication mechanism.
- Limit page size, returned bodies, fetched RFC822 messages, attachments, and
  per-request duration. Return a safe tool error rather than partially writing
  state or leaking upstream details.
- Keep credentials in mounted secret files. Redact all secret/message values
  from logs and error responses.

## Tool contract

| Tool | Purpose |
| --- | --- |
| `imap_list_mailboxes` | List accessible mailboxes for the configured account. |
| `imap_search_messages` | Search one mailbox using a restricted set of read filters and a bounded page. |
| `imap_get_message` | Read message metadata and bounded body by mailbox and UID. |
| `imap_list_attachments` | List attachment metadata for a bounded message. |
| `imap_get_attachment` | Return one bounded attachment as base64 by numeric attachment index. |

The client may select a mailbox only from a deployment allowlist when
`IMAP_ALLOWED_MAILBOXES` is configured. All server-generated external API
operations use the configured IMAP host.

## Authentication

The authentication abstraction accepts exactly one `IMAP_CREDENTIAL_SECRET_FILE`
JSON object per instance. `IMAP_AUTH_MODE` is `basic`,
`oauth-client-credentials`, or `oauth-refresh-token`; it selects the required
fields from `username`, `password`, `token`, `token_url`, `client_id`,
`client_secret`, `refresh_token`, and optional `scope`. No separate credential
environment variables are accepted. For the refresh-token grant, the initial
secret is replaced atomically by an AES-256-GCM encrypted state file in the
per-instance `IMAP_TOKEN_STATE_DIR` volume whenever the provider returns a
rotating refresh token. The decryption key is the separate Docker Secret
`IMAP_TOKEN_STATE_KEY_FILE`; the legacy `IMAP_TOKEN_PROTECTION_KEY_FILE` alias
is accepted. Access tokens remain in process memory only.

## Operations and observability

`GET /healthz` reports process/config readiness without attempting a login or
returning configuration values. `POST /mcp` provides the MCP JSON-RPC methods
needed by Agentgateway and clients. Logs use a generated correlation ID and
operation/result category only. No telemetry endpoint is included.

`POST /mcp` is backend-only: it requires `Authorization: Bearer` equal to the
value in `MCP_INTERNAL_TOKEN_FILE`, compared in constant time. The endpoint
never logs an invalid/expected token; `/healthz` remains unauthenticated for
container health checks.
