#!/bin/sh

set -eu

# The persistent home can contain a previous native install. Always select the
# reviewed image-owned executables, while leaving its auth/session state intact.
PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:/home/ai/.local/bin"
export PATH
/usr/local/bin/openclaw-verify-subscription-cli.sh

gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
agentgateway_base_url="${OPENCLAW_AGENTGATEWAY_BASE_URL:?OPENCLAW_AGENTGATEWAY_BASE_URL is required}"
agentgateway_wait_seconds="${OPENCLAW_AGENTGATEWAY_WAIT_SECONDS:-600}"
agentgateway_models_url="${agentgateway_base_url%/}/models"

is_enabled() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

apply_autonomous_exec_approvals() {
    # The central tools.exec policy in init.mjs has a separate persisted
    # host-approval document. An autonomous profile must manage both layers:
    # without these defaults, a non-interactive Guardian/reviewer path can
    # fall back to deny after its 30-second review times out. This runs as the
    # container's `ai` user before the gateway starts, so it writes only its
    # own OpenClaw state database. Generic Guardian deployments leave their
    # local approval rules untouched.
    if [ "${OPENCLAW_CODEX_EXECUTION_PROFILE:-guardian}" != "autonomous" ]; then
        return 0
    fi

    printf '%s\n' '[openclaw] Applying managed autonomous exec approvals'
    printf '%s\n' '{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{}}' \
        | openclaw approvals set --stdin
}

wait_for_agentgateway() {
    deadline=$(( $(date +%s) + agentgateway_wait_seconds ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        # Wait for the public model route, not an implementation-specific backend.
        if getent hosts agentgateway >/dev/null 2>&1 \
            && curl --fail --silent --show-error --max-time 5 \
                --header "Authorization: Bearer ${AGENTGATEWAY_TOKEN}" \
                "$agentgateway_models_url" >/dev/null 2>&1; then
            return 0
        fi

        sleep 5
    done

    printf '%s\n' "[openclaw] Agentgateway was not reachable at ${agentgateway_models_url} within ${agentgateway_wait_seconds}s" >&2
    return 1
}

if ! is_enabled "${OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED:-0}" \
    && [ -n "${OPENCLAW_GATEWAY_TOKEN_FILE:-}" ]; then
    OPENCLAW_GATEWAY_TOKEN="$(cat "$OPENCLAW_GATEWAY_TOKEN_FILE")"
    export OPENCLAW_GATEWAY_TOKEN
fi

if [ -n "${AGENTGATEWAY_TOKEN_FILE:-}" ]; then
    AGENTGATEWAY_TOKEN="$(cat "$AGENTGATEWAY_TOKEN_FILE")"
    export AGENTGATEWAY_TOKEN
fi

openclaw plugins registry --refresh

printf '%s\n' '[openclaw] Merging managed local-provider configuration'
node /opt/openclaw/init.mjs
apply_autonomous_exec_approvals

printf '%s\n' "[openclaw] Waiting for Agentgateway at ${agentgateway_models_url}"
wait_for_agentgateway

printf '%s\n' "[openclaw] Starting gateway on 0.0.0.0:${gateway_port}"
# --bind lan kept in sync by hand with init.mjs's own gateway.bind config
# write - not derived from one another.
exec openclaw gateway run --bind lan --port "$gateway_port"
