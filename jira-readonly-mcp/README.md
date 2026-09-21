# Jira read-only MCP

`jira-readonly-mcp` is a standalone .NET 10 Streamable HTTP MCP server for one Jira Data Center account. It exposes a deliberately small set of read-only tools and uses Jira's native REST API; it does not expose Jira URLs as tool input and cannot create, modify, transition, comment on, or delete Jira objects.

The server is an internal backend: deploy it without a published port and put Agentgateway in front of `POST /mcp`. Every `/mcp` request must carry `Authorization: Bearer <token>` matching its dedicated `MCP_INTERNAL_TOKEN_FILE` Docker Secret. Agentgateway owns that secret, authenticates the human caller, and selects the dedicated per-user container/credential set. `/healthz` deliberately stays unauthenticated for the internal health probe; authenticated `/readyz` performs only `GET /rest/api/2/myself` and returns no upstream detail.

## Tools

- `jira_search_issues` — bounded JQL search.
- `jira_get_issue` — issue metadata and configured standard fields.
- `jira_list_comments` — bounded list of comments for one issue.
- `jira_list_projects` — projects visible to the configured account.
- `jira_get_attachment` — attachment metadata, or bounded base64 content when explicitly requested.

All upstream requests are `GET`; attachment content is downloaded only from the configured Jira origin. There are no write tools and no configurable upstream URL in an MCP request.

## Configuration

| Variable | Required | Description |
| --- | --- | --- |
| `JIRA_BASE_URL` | yes | HTTPS Jira base URL; a context path such as `https://jira.example/jira/` is supported. |
| `JIRA_AUTH_MODE` | yes | `basic`, `pat`, `oauth-client-credentials`, or `oauth-refresh-token`. |
| `JIRA_CREDENTIAL_SECRET_FILE` | yes | Read-only Docker secret file with a JSON credential object. |
| `MCP_INTERNAL_TOKEN_FILE` | yes | Docker Secret containing the backend bearer token supplied only by Agentgateway. |
| `JIRA_OAUTH_TOKEN_URL` | OAuth only | HTTPS token endpoint. |
| `JIRA_OAUTH_SCOPE` | no | OAuth scope requested while refreshing a token. |
| `JIRA_TOKEN_STATE_DIR` | OAuth refresh only | Writable per-instance volume where only an encrypted rotating refresh token is stored. |
| `JIRA_TOKEN_STATE_KEY_FILE` | OAuth refresh only | Docker Secret containing a base64-encoded 32-byte AES-256 key for that state volume. |
| `JIRA_MAX_RESULTS` | no | Per-tool result ceiling, 1–100; default `50`. |
| `JIRA_MAX_ATTACHMENT_BYTES` | no | Attachment content ceiling, 1 byte–50 MiB; default 10 MiB. |
| `JIRA_MAX_JSON_RESPONSE_BYTES` | no | Jira JSON response ceiling; default 8 MiB. |
| `JIRA_REQUEST_TIMEOUT_SECONDS` | no | Upstream request timeout, 1–300 seconds; default `30`. |

Credential JSON is a Docker Secret, never an environment value or a tracked file:

```json
// basic
{ "username": "service-user", "password": "..." }

// pat (the fixed Vault/ai-stand record contract)
{ "pat": "..." }

// oauth-client-credentials
{ "client_id": "...", "client_secret": "..." }

// oauth-refresh-token
{ "client_id": "...", "client_secret": "...", "refresh_token": "..." }
```

For `oauth-refresh-token`, the bootstrap refresh token remains in the credential secret. If the provider returns a rotating `refresh_token`, it replaces the active one and is atomically persisted only as an AES-GCM encrypted state file in `JIRA_TOKEN_STATE_DIR`; that volume is per instance and must never be shared. TLS certificate validation is always enabled. The service rejects HTTP base/token endpoints, redirects, origins outside the configured Jira origin, over-large upstream responses, unrecognized issue/attachment identifiers, and unsupported auth modes. Logs include only operation status; they never log credentials, access tokens, JQL, response bodies, or attachment contents.

## Build and test

```powershell
dotnet test .\JiraReadonlyMcp.sln
dotnet publish .\src\JiraReadonlyMcp\JiraReadonlyMcp.csproj -c Release
docker build --build-context mcp-readonly-common=../mcp-readonly-common -t ai-stand/jira-readonly-mcp:local .
```

The image uses the .NET 10 chiseled runtime and runs as UID/GID `10000:20000`. Deployment must set a read-only root filesystem, drop Linux capabilities, mount only the individual credential secret and any required trust material, and keep the service solely on the internal `ai-network`.
