# IMAP read-only MCP

`imap-readonly-mcp` is a .NET 10 Streamable HTTP MCP server that exposes one
statically configured IMAP account as a deliberately small, read-only tool
surface. It is intended to run behind Agentgateway; it does not publish a
host port and does not authenticate end users itself.

## MCP endpoint

`POST /mcp` implements MCP Streamable HTTP JSON-RPC. `GET /healthz` returns a
non-sensitive liveness response. Authenticated `GET /readyz` logs in, lists
mailboxes without selecting one, then disconnects; failure is a generic 503.
The server supports `initialize`, `ping`,
`tools/list`, and `tools/call`; it does not implement server-initiated SSE
messages or sessions.

Available tools:

- `imap_list_mailboxes`
- `imap_search_messages`
- `imap_get_message`
- `imap_list_attachments`
- `imap_get_attachment`

There are no mutating tools. The IMAP folder is opened with MailKit
`FolderAccess.ReadOnly`, which issues IMAP `EXAMINE`; message retrieval uses
MailKit's non-seen (`BODY.PEEK`) read path. The implementation never calls
`STORE`, `APPEND`, `COPY`, `MOVE`, `EXPUNGE`, or a write-capable folder open.

## Configuration

All configuration is supplied by the deployment. Do not commit values or pass
secrets as normal environment variables.

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `IMAP_HOST` | yes | — | Static IMAP hostname; it cannot contain a URL/path. |
| `IMAP_PORT` | no | `993` | TLS IMAP port. |
| `IMAP_TLS_MODE` | no | `implicit` | `implicit` or `starttls`; plaintext is rejected. |
| `IMAP_AUTH_MODE` | no | `basic` | `basic`, `oauth-client-credentials`, or `oauth-refresh-token`. |
| `IMAP_CREDENTIAL_SECRET_FILE` | yes | — | One Docker Secret JSON file holding this instance's upstream credentials. |
| `MCP_INTERNAL_TOKEN_FILE` | yes | — | Docker Secret file with the Agentgateway-only backend bearer. |
| `IMAP_TOKEN_STATE_DIR` | refresh grant | — | Writable, per-instance persistent directory for encrypted rotating refresh tokens. |
| `IMAP_TOKEN_STATE_KEY_FILE` | refresh grant | — | Secret file with a base64-encoded 32-byte AES key. |
| `IMAP_ALLOWED_MAILBOXES` | no | — | Comma-separated mailbox allowlist; unset means all folders in this account. |
| `IMAP_MAX_PAGE_SIZE` / `IMAP_MAX_RESULTS` | no | `50` | Maximum search page size, max `100`; the renderer sets `IMAP_MAX_RESULTS`. |
| `IMAP_MAX_BODY_BYTES` | no | `262144` | Maximum returned text body bytes. |
| `IMAP_MAX_MESSAGE_BYTES` | no | `10485760` | Maximum RFC822 message size fetched by detail/attachment tools. |
| `IMAP_MAX_ATTACHMENT_BYTES` | no | `5242880` | Maximum returned attachment size. |
| `IMAP_REQUEST_TIMEOUT_SECONDS` | no | `60` | Per-tool upstream timeout, max `300`. |

The credential secret is a JSON object; no individual username/password/token
environment variables are accepted:

```json
{"username":"reader@example.test","password":"..."}
```

```json
{"username":"reader@example.test","token_url":"https://idp.example.test/token","client_id":"...","client_secret":"...","scope":"imap.read"}
```

```json
{"username":"reader@example.test","token_url":"https://idp.example.test/token","client_id":"...","client_secret":"...","refresh_token":"...","scope":"imap.read"}
```

For `oauth-client-credentials`, `{ "username": "...", "token": "..." }`
is also accepted when the deployment supplies a pre-issued access token. For
`oauth-refresh-token`, a rotated refresh token is encrypted with AES-256-GCM
into the dedicated per-instance state directory and atomically replaces the
state file; it is therefore not lost on restart. `IMAP_TOKEN_PROTECTION_KEY_FILE`
is supported as a legacy alias for `IMAP_TOKEN_STATE_KEY_FILE`.

## Container security

The image runs as `10000:20000`, has no Docker client or host mounts, and is
designed for `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges:true` at
deployment. Secrets must be mounted read-only under `/run/secrets`. `POST
/mcp` requires an exact `Authorization: Bearer` token from
`MCP_INTERNAL_TOKEN_FILE`; comparison is constant-time and neither token is
logged. `GET /healthz` is deliberately unauthenticated for the container
health check. The server logs operation names and opaque request IDs only; it
never logs credentials, OAuth tokens, message text, headers, attachment
contents, or IMAP commands.

## Local validation

```powershell
dotnet test .\ImapReadonlyMcp.sln -c Release
dotnet publish .\src\ImapReadonlyMcp\ImapReadonlyMcp.csproj -c Release
docker build --build-context mcp-readonly-common=../mcp-readonly-common -t imap-readonly-mcp:test .
```

The module intentionally contains no real account, host, or credential.
