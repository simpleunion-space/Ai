# Confluence read-only MCP

`confluence-readonly-mcp` is a .NET 10 Streamable HTTP MCP server for one
preconfigured Confluence Data Center account. It exposes a deliberately small,
read-only tool surface over Confluence REST API. It has no public port, no
Docker socket, no facility for an MCP caller to select an upstream URL, and no
write tool.

The intended deployment is one container per end user/account, behind
Agentgateway. Agentgateway is responsible for authenticating a user and routing
only to that user's instance. This server must not be shared between accounts.

## MCP endpoint and tools

The server accepts JSON-RPC 2.0 requests at `POST /mcp` and supports the
Streamable HTTP MCP methods `initialize`, `ping`, `tools/list`, and `tools/call`.
Successful calls return JSON; streaming is not needed because every upstream
operation is a bounded read. `GET /healthz` intentionally checks configuration
only and does not expose upstream metadata. Authenticated `GET /readyz`
performs only `GET /rest/api/user/current` and returns a generic 503 if the
upstream is unavailable.

| Tool | Read-only Confluence operation |
| --- | --- |
| `confluence_search_content` | CQL content search |
| `confluence_get_content` | Read one content item with a fixed safe expand list |
| `confluence_list_comments` | List comments for one content item |
| `confluence_list_attachments` | List attachments for one content item |
| `confluence_get_attachment` | Read one attachment by its Confluence content ID |

No user-provided URL or REST path is accepted. The server sends only HTTP `GET`
requests to the configured Confluence origin. Attachments use the API-provided
relative download link only after the referenced item is confirmed to be a
Confluence attachment on that origin.

## Configuration

All values below are runtime configuration. Values ending in `_FILE` name a
Docker Secret or protected mounted file. Credentials must never be placed in an
environment variable, image layer, source tree, or log.

The installation renderer uses the single `CONFLUENCE_CREDENTIAL_SECRET_FILE`
contract, so an instance needs only that upstream secret plus
`MCP_INTERNAL_TOKEN_FILE` (and, for a rotating refresh-token flow, its state
key). The separate `*_FILE` settings remain only as a compatibility mode for
manual development.

| Variable | Required | Meaning |
| --- | --- | --- |
| `CONFLUENCE_BASE_URL` | yes | Absolute `https` base URL, including an optional context path |
| `MCP_INTERNAL_TOKEN_FILE` | yes | Per-instance Agentgateway backend bearer secret |
| `CONFLUENCE_AUTH_MODE` | yes | `basic`, `pat`, `oauth-client-credentials`, or `oauth-refresh-token` |
| `CONFLUENCE_CREDENTIAL_SECRET_FILE` | renderer mode | One JSON Docker Secret. The initial Vault renderer permits only `{ "pat": "…" }`; manual-development compatibility may also use `username`, `password`, `token`, `client_id`, `client_secret`, `refresh_token`, `token_url`, and optional `scope`. |
| `CONFLUENCE_USERNAME_FILE`, `CONFLUENCE_PASSWORD_FILE` | legacy basic | Legacy separate Secret files |
| `CONFLUENCE_PAT_FILE` | legacy PAT | Legacy personal-access-token Secret file |
| `CONFLUENCE_OAUTH_TOKEN_URL` | legacy OAuth | Legacy absolute `https` token endpoint |
| `CONFLUENCE_OAUTH_CLIENT_ID_FILE`, `CONFLUENCE_OAUTH_CLIENT_SECRET_FILE` | legacy OAuth | Legacy OAuth client credential Secret files |
| `CONFLUENCE_OAUTH_REFRESH_TOKEN_FILE` | legacy refresh | Legacy initial refresh-token Secret file |
| `CONFLUENCE_TOKEN_STATE_DIR`, `CONFLUENCE_TOKEN_STATE_KEY_FILE` | refresh | Absolute writable per-account token volume and 32-byte AES-GCM key for rotated refresh tokens |
| `CONFLUENCE_OAUTH_SCOPE` | no | Space-separated OAuth scopes |
| `CONFLUENCE_MAX_PAGE_SIZE` | no | Per-request list bound, default 25, maximum 100 |
| `CONFLUENCE_MAX_RESULTS` | no | Total advertised result bound, default 100, maximum 500 |
| `CONFLUENCE_MAX_ATTACHMENT_BYTES` | no | Attachment body bound, default 10 MiB, maximum 50 MiB |
| `CONFLUENCE_MAX_RESPONSE_BYTES` | no | JSON REST response bound, default 2 MiB, maximum 8 MiB |
| `CONFLUENCE_REQUEST_TIMEOUT_SECONDS` | no | Upstream GET/token timeout, default 60 seconds, maximum 600 seconds |

TLS certificate validation is always enabled. `http` base URLs and token
endpoints are rejected at startup. Trust a private CA through the container/host
trust store; do not disable certificate validation.

For OAuth refresh-token flows, mount only the account-specific token-state
directory read/write. The rest of the container can use a read-only filesystem.
The server stores a rotated refresh token only as AES-GCM encrypted state; short
lived access tokens remain in memory.

## Container hardening

Run with `read_only: true`, `cap_drop: [ALL]`, `security_opt:
['no-new-privileges:true']`, a read-only secret mount, and a narrow writable
volume only when `oauth-refresh-token` is selected. The image already runs as
UID `10000`, GID `20000`; it exposes port 8080 only to the internal deployment
network.

## Development

```powershell
dotnet test .\ConfluenceReadonlyMcp.sln -c Release
dotnet publish .\src\ConfluenceReadonlyMcp\ConfluenceReadonlyMcp.csproj -c Release
docker build -t confluence-readonly-mcp:dev .
```

The Dockerfile expects the shared module as a named build context:

```powershell
docker build --build-context mcp-readonly-common=../mcp-readonly-common -t confluence-readonly-mcp:dev .
```

Tests use fake HTTP handlers and do not contact a Confluence instance.
