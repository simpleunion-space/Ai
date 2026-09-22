# Read-only MCP installation overlay

`reconciler.example.json` documents the root-owned, host-local control-plane
configuration. Copy it to
`/mnt/storage/readonly-mcp-data/reconciler/reconciler.json`
with mode `0600`; it contains static upstream locations and the path to the
Authentik API-token file, never its value.

`reconcile.py` runs only from the root-owned ai01 systemd timer. It reads
`ai-users` and, for each member, reassembles each service's credential from a
fixed set of flat attributes on that user's own Authentik profile (see
`CREDENTIAL_ATTRIBUTES` in `reconcile.py`) - there is no separate secret
store: the user edits their own `ai_stand_mcp_*` attributes through a
self-service prompt stage (`configure.mjs`), and an absent or blank attribute
simply reads as "needs_credentials". No credential value is ever written back
by the reconciler. After a user supplies a complete credential, the
reconciler probes the fixed upstream by a read-only operation and creates
versioned Docker Secrets - the version number now comes from a fingerprint of
the credential's own value (see `credential_fingerprint()`), not an external
KV store's version counter, but the effect is identical: a changed value
always gets a new Secret name, never an in-place overwrite. It writes a
non-secret version-2 manifest atomically. Credentials never appear in the
manifest, Compose overlay, Agentgateway configuration or logs.
`manifest.example.json` is documentation only, not an input for a live
deployment.

An installation may also opt into letting each user override this
installation's own upstream endpoints (Jira/Confluence base URL, IMAP host)
from their own attributes, via `reconciler.json`'s `userOverrides.
upstreamsEnabled` - off by default in this generic core. A user can only ever
redirect their own already-isolated MCP container this way, never another
user's.

`render-profile.py` validates the manifest and renders the Swarm Compose
overlay plus Agentgateway routes. It rejects unsafe subjects, slugs, Docker
Secret names and endpoints. Users without a valid record simply receive no
target for that one MCP; they cannot fall back to another user's target.
It also retains a non-secret `retiredSecrets` list until a Swarm rolling
update has stopped every old task, so a credential rotation never removes a
Secret still mounted by an old container.
