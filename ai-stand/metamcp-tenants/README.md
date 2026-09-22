# MetaMCP tenant identity control plane

This directory defines the fail-closed identity boundary for personal
MetaMCP tenants. It deliberately does not accept an email, endpoint name or
Docker resource supplied by a browser request.

An administrator makes a reviewed, root-owned copy of
`tenant-identities.example.json` at:

```text
/mnt/storage/readonly-mcp-data/reconciler/metamcp-tenant-identities.json
```

The file is `root:root` with mode `0600`. Each row binds an already existing
MetaMCP OIDC user to the immutable Authentik `(issuer, sub)` pair. Run the
one-time migration only after checking every row:

```bash
sudo bash apply.sh migrate-metamcp-tenants --installation <profile> --node-name ai01
```

`provision.py` refuses an absent or ambiguous legacy email match, an unsafe
resource name, a changed MetaMCP image, or a schema mismatch. The database
transaction is serializable and uses a temporary `COPY` table rather than
interpolating identity values into SQL. It emits a descriptor with no API key,
credential, email or browser token.

The descriptor is intentionally not a shared MetaMCP endpoint. A tenant
runtime controller must apply it by creating an isolated state/database,
private `ai-metamcp-tenant-<subject>` network, rootless DIND, and a narrow
router to `ai-mcp-backend`. Until that controller has positively attested the
applied descriptor, `/mcp/personal` has no Agentgateway target and is denied.
