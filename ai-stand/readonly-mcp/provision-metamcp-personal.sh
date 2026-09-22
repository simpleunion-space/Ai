#!/usr/bin/env bash
# Compatibility entry point for the retired central personal-endpoint helper.
#
# It intentionally does *not* create a namespace, endpoint or API key in the
# shared MetaMCP database.  The replacement maps an existing OIDC owner to an
# immutable (issuer, subject) relation and produces a descriptor for a future
# isolated per-user tenant runtime.  All paths must be installed together by
# the deployment integration; otherwise the helper refuses to operate.
set -euo pipefail

: "${READONLY_MCP_INVENTORY:?must point to protected readonly MCP inventory}"
: "${METAMCP_IMAGE:?must be set}"
: "${STACK_NAME:?must be set}"
: "${AUTHENTIK_ISSUER:?must be the canonical Authentik issuer for ai-stand}"
: "${METAMCP_TENANT_MANIFEST:?must be the root-only generated tenant descriptor path}"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
tenant_source="${METAMCP_TENANT_SOURCE_DIR:-${script_dir}/../metamcp-tenants}"
adapter="${tenant_source}/legacy_inventory_adapter.py"
helper="${tenant_source}/provision.py"
[ -r "$adapter" ] && [ -r "$helper" ] || {
  printf '%s\n' "[readonly-mcp] MetaMCP tenant control-plane source is not installed; refusing legacy shared-endpoint provisioning" >&2
  exit 1
}

umask 077
inventory="$(mktemp)"
trap 'rm -f "$inventory"' EXIT
python3 "$adapter" \
  --legacy-inventory "$READONLY_MCP_INVENTORY" \
  --issuer "$AUTHENTIK_ISSUER" \
  --output "$inventory"

# The email-to-identity transition is deliberately not automatic.  An operator
# runs the explicit `--migrate-email-owners` command once, reviews its outcome,
# and then normal reconciliation can emit the runtime descriptor.
python3 "$helper" \
  --inventory "$inventory" \
  --stack-name "$STACK_NAME" \
  --metamcp-image "$METAMCP_IMAGE" \
  --output "$METAMCP_TENANT_MANIFEST"

# Do not let the existing reconciler publish the old shared MetaMCP endpoint
# merely because a desired-state descriptor was rendered.  A controller that
# creates the tenant services and Agentgateway router must explicitly attest
# that it has applied the descriptor first.
[ "${METAMCP_TENANT_RUNTIME_CONTROLLER:-0}" = "1" ] || {
  printf '%s\n' "[readonly-mcp] tenant descriptor rendered; isolated tenant runtime controller has not applied it" >&2
  exit 1
}
