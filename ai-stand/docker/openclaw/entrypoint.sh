#!/bin/sh

set -eu

gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
lmstudio_base_url="${OPENCLAW_LMSTUDIO_BASE_URL:?OPENCLAW_LMSTUDIO_BASE_URL is required}"
lmstudio_wait_seconds="${OPENCLAW_LMSTUDIO_WAIT_SECONDS:-600}"
lmstudio_models_url="${lmstudio_base_url%/}/models"

is_enabled() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_codex_plugin() {
    plugin_version="${OPENCLAW_CODEX_PLUGIN_VERSION:?OPENCLAW_CODEX_PLUGIN_VERSION is required}"
    plugin_projects_dir="${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required}/npm/projects"
    plugin_manifest="$(find "$plugin_projects_dir" -type f -path '*/node_modules/@openclaw/codex/package.json' -print -quit 2>/dev/null || true)"
    installed_version=""
    if [ -r "$plugin_manifest" ]; then
        installed_version="$(node -e 'const fs = require("node:fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version || "")' "$plugin_manifest" 2>/dev/null || true)"
    fi

    if [ "$installed_version" != "$plugin_version" ]; then
        printf '%s\n' "[openclaw] Installing Codex plugin ${plugin_version} into persistent state"
        # Do this before init.mjs writes plugins.entries.codex. Otherwise
        # OpenClaw starts through its Doctor auto-repair path, which is
        # implicit, noisy, and makes a configured app-server policy appear
        # invalid during each first start.
        openclaw plugins install "@openclaw/codex@${plugin_version}"
        plugin_manifest="$(find "$plugin_projects_dir" -type f -path '*/node_modules/@openclaw/codex/package.json' -print -quit 2>/dev/null || true)"
    fi

    [ -r "$plugin_manifest" ] || {
        printf '%s\n' "[openclaw] Codex plugin was not installed below $plugin_projects_dir" >&2
        return 1
    }
}

ensure_lancedb_plugin() {
    if ! is_enabled "${OPENCLAW_LANCEDB_ENABLED:-0}"; then
        return 0
    fi

    plugin_version="${OPENCLAW_LANCEDB_PLUGIN_VERSION:?OPENCLAW_LANCEDB_PLUGIN_VERSION is required when LanceDB is enabled}"
    # `openclaw plugins install` places managed packages below a generated
    # project directory, rather than directly in ~/.openclaw/npm/node_modules.
    # Locate that immutable package manifest so a restart does not mistake an
    # already-installed plugin for a missing one and fail on a duplicate install.
    plugin_projects_dir="${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required}/npm/projects"
    plugin_manifest="$(find "$plugin_projects_dir" -type f -path '*/node_modules/@openclaw/memory-lancedb/package.json' -print -quit 2>/dev/null || true)"
    installed_version=""
    if [ -r "$plugin_manifest" ]; then
        installed_version="$(node -e 'const fs = require("node:fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version || "")' "$plugin_manifest" 2>/dev/null || true)"
    fi

    if [ "$installed_version" != "$plugin_version" ]; then
        printf '%s\n' "[openclaw] Installing memory-lancedb ${plugin_version} into persistent state"
        # The plugin manager installs optional platform packages next to the
        # persistent OpenClaw state. It must finish before init.mjs assigns
        # the exclusive memory slot; otherwise OpenClaw validates a missing
        # plugin and enters a restart loop.
        openclaw plugins install "@openclaw/memory-lancedb@${plugin_version}"
        plugin_manifest="$(find "$plugin_projects_dir" -type f -path '*/node_modules/@openclaw/memory-lancedb/package.json' -print -quit 2>/dev/null || true)"
    fi

    [ -r "$plugin_manifest" ] || {
        printf '%s\n' "[openclaw] memory-lancedb package was not installed below $plugin_projects_dir" >&2
        return 1
    }
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

wait_for_lmstudio() {
    deadline=$(( $(date +%s) + lmstudio_wait_seconds ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        # agentgateway, not lmstudio - readiness now means "the gateway is up
        # and will accept our key", not "LM Studio itself is up" (lmstudio
        # may still be loading behind it; agentgateway just proxies that
        # along as a normal upstream error, which this loop keeps retrying).
        if getent hosts agentgateway >/dev/null 2>&1 \
            && curl --fail --silent --show-error --max-time 5 \
                --header "Authorization: Bearer ${AGENTGATEWAY_TOKEN}" \
                "$lmstudio_models_url" >/dev/null 2>&1; then
            return 0
        fi

        sleep 5
    done

    printf '%s\n' "[openclaw] LM Studio was not reachable at ${lmstudio_models_url} within ${lmstudio_wait_seconds}s" >&2
    return 1
}

if [ -n "${OPENCLAW_GATEWAY_TOKEN_FILE:-}" ]; then
    OPENCLAW_GATEWAY_TOKEN="$(cat "$OPENCLAW_GATEWAY_TOKEN_FILE")"
    export OPENCLAW_GATEWAY_TOKEN
fi

if [ -n "${AGENTGATEWAY_TOKEN_FILE:-}" ]; then
    AGENTGATEWAY_TOKEN="$(cat "$AGENTGATEWAY_TOKEN_FILE")"
    export AGENTGATEWAY_TOKEN
fi

ensure_codex_plugin
ensure_lancedb_plugin

printf '%s\n' '[openclaw] Merging managed local-provider configuration'
node /opt/openclaw/init.mjs
apply_autonomous_exec_approvals

printf '%s\n' "[openclaw] Waiting for LM Studio at ${lmstudio_models_url}"
wait_for_lmstudio

printf '%s\n' "[openclaw] Starting gateway on 0.0.0.0:${gateway_port}"
# --bind lan kept in sync by hand with init.mjs's own gateway.bind config
# write - not derived from one another.
exec openclaw gateway run --bind lan --port "$gateway_port"
