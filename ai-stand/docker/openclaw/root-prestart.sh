#!/bin/sh

# Runs from docker/base/entrypoint.sh after it has normalised the bind-mounted
# /home/ai ownership but before it drops privileges to UID/GID 10000:20000.
# OpenClaw 2026.10.2 deliberately rejects a managed plugin whose payload is
# mutable by the runtime user.  The Gateway itself stays unprivileged; only
# only their generated payloads are made root-owned here. Stateful OpenClaw
# commands run as the state owner: 10.2 intentionally rejects root opening a
# runtime-owned database/ownership directory.

set -eu

# A full generic deploy must not silently reinstall older managed plugins on
# the new host, including an existing memory slot temporarily disabled in ENV.
managed_host_version=2026.10.2
[ "$(node --print 'require("/usr/local/lib/node_modules/openclaw/package.json").version')" = "$managed_host_version" ] \
    && [ "${OPENCLAW_CODEX_PLUGIN_VERSION:?OPENCLAW_CODEX_PLUGIN_VERSION is required}" = "$managed_host_version" ] \
    && [ "${OPENCLAW_LANCEDB_PLUGIN_VERSION:?OPENCLAW_LANCEDB_PLUGIN_VERSION is required}" = "$managed_host_version" ] || {
    printf '%s\n' '[openclaw] managed host/plugin version contract mismatch' >&2
    exit 1
}

is_enabled() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

restore_gateway_config_ownership() {
    config_root="${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required}"
    # Managed plugin commands run as root and may rewrite this one config
    # file and its exact backup. Restore only these two owners on every
    # exit; plugin generations remain root-owned. Do not touch user backups.
    for config_path in "$config_root/openclaw.json" "$config_root/openclaw.json.bak"; do
        if [ ! -e "$config_path" ] && [ ! -L "$config_path" ]; then
            continue
        fi
        [ -f "$config_path" ] && [ ! -L "$config_path" ] \
            && [ "$(stat -c '%h' "$config_path")" = '1' ] || {
            printf '%s\n' "[openclaw] refusing unexpected config path: ${config_path}" >&2
            return 1
        }
        chown "${IM_UID:?IM_UID is required}:${IM_GID:?IM_GID is required}" "$config_path"
    done
}

load_agentgateway_token() {
    if [ -n "${AGENTGATEWAY_TOKEN_FILE:-}" ]; then
        AGENTGATEWAY_TOKEN="$(cat "$AGENTGATEWAY_TOKEN_FILE")"
        export AGENTGATEWAY_TOKEN
    fi
}

latest_plugin_manifest() {
    package_name="$1"
    find "${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required}/npm/projects" \
        -type f \
        -path "*/node_modules/${package_name}/package.json" \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | head -n 1 \
        | cut -d ' ' -f 2-
}

plugin_version() {
    node -e 'const fs=require("node:fs");process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).version||"")' "$1" 2>/dev/null || true
}

plugin_project_dir() {
    manifest="$1"
    package_name="$2"
    printf '%s\n' "${manifest%/node_modules/${package_name}/package.json}"
}

validate_managed_generation() {
    generation="$1"
    package_name="$2"
    case "$package_name" in
        @openclaw/codex) managed_stem=openclaw-codex-8902d781d4 ;;
        @openclaw/memory-lancedb) managed_stem=openclaw-memory-lancedb-6a4d78c41e ;;
        *) printf '%s\n' '[openclaw] refusing unmanaged package generation' >&2; exit 1 ;;
    esac
    [ -d "$generation" ] && [ ! -L "$generation" ] \
        && [ "${generation%/*}" = "${OPENCLAW_STATE_DIR}/npm/projects" ] \
        && printf '%s\n' "${generation##*/}" | grep -Eq "^${managed_stem}(__openclaw-generation__g-[0-9a-f]{16})?$" || {
        printf '%s\n' '[openclaw] refusing unexpected managed package generation' >&2
        exit 1
    }
}

state_owner_cli() {
    gosu "${IM_UID:?IM_UID is required}:${IM_GID:?IM_GID is required}" openclaw "$@"
}

prepare_runtime_state_root() {
    state_root="${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required}"
    if [ ! -e "$state_root" ] && [ ! -L "$state_root" ]; then
        install -d -m 0700 -o "$IM_UID" -g "$IM_GID" "$state_root"
    fi
    [ -d "$state_root" ] && [ ! -L "$state_root" ] \
        && [ "$(stat -c '%u' "$state_root")" = "$IM_UID" ] || {
        printf '%s\n' '[openclaw] refusing unexpected runtime state root ownership/type' >&2
        exit 1
    }
}

prepare_managed_install_parents() {
    # Prior root-run installs can leave these two exact projection parents
    # root-owned. Make room for the native state-owner installer without
    # changing state, credentials, workspaces or existing payload ownership.
    for parent in "${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required}/npm" \
                  "${OPENCLAW_STATE_DIR}/npm/projects"; do
        if [ ! -e "$parent" ] && [ ! -L "$parent" ]; then
            install -d -m 0700 -o "$IM_UID" -g "$IM_GID" "$parent"
        fi
        [ -d "$parent" ] && [ ! -L "$parent" ] || {
            printf '%s\n' '[openclaw] refusing unexpected managed install parent' >&2
            exit 1
        }
        owner="$(stat -c '%u' "$parent")"
        [ "$owner" = 0 ] || [ "$owner" = "$IM_UID" ] || {
            printf '%s\n' '[openclaw] managed install parent has an unexpected owner' >&2
            exit 1
        }
        chown "$IM_UID:$IM_GID" "$parent"
        chmod 0700 "$parent"
    done
}

set_package_retention_markers() {
    package_name="$1"
    retention_owner="$2"
    retention_mode="$3"
    retention_file_mode=0600
    [ "$retention_owner" != root:root ] || retention_file_mode=0644
    # 10.2 keeps replaced generations and writes only a JSON retirement marker
    # inside their project root. Permit that exact bookkeeping directory,
    # never the old node_modules payload, to be written by the state owner.
    find "${OPENCLAW_STATE_DIR}/npm/projects" -type f \
        -path "*/node_modules/${package_name}/package.json" -print \
        | while IFS= read -r manifest_path; do
            generation="$(plugin_project_dir "$manifest_path" "$package_name")"
            validate_managed_generation "$generation" "$package_name"
            retention="${generation}/.openclaw-retained-npm-installs"
            [ ! -L "$retention" ] && { [ ! -e "$retention" ] || [ -d "$retention" ]; } || {
                printf '%s\n' '[openclaw] refusing unexpected retention metadata directory' >&2
                exit 1
            }
            if [ ! -e "$retention" ] && [ "$retention_owner" = root:root ]; then
                continue
            fi
            install -d -m "$retention_mode" -o "${retention_owner%:*}" -g "${retention_owner#*:}" "$retention"
            for marker in "$retention"/* "$retention"/.[!.]* "$retention"/..?*; do
                [ -e "$marker" ] || [ -L "$marker" ] || continue
                case "${marker##*/}" in
                    *.json) ;;
                    *) printf '%s\n' '[openclaw] refusing unexpected retention metadata' >&2; exit 1 ;;
                esac
                [ -f "$marker" ] && [ ! -L "$marker" ] \
                    && [ "$(stat -c '%h' "$marker")" = 1 ] || {
                    printf '%s\n' '[openclaw] refusing linked retention metadata' >&2
                    exit 1
                }
                chown "$retention_owner" "$marker"
                chmod "$retention_file_mode" "$marker"
            done
        done
}

restore_managed_retention_ownership() {
    # A failed install also restores the non-executable bookkeeping boundary.
    set_package_retention_markers '@openclaw/codex' root:root 0755
    set_package_retention_markers '@openclaw/memory-lancedb' root:root 0755
}

adopt_existing_lancedb_generation() {
    # OpenClaw checks the configured memory plugin before any `openclaw
    # plugins …` subcommand can run.  Earlier deployments installed this one
    # package as the runtime user, so repair precisely its generated npm
    # project before invoking the CLI.  Do not recurse outside the fixed
    # package-generation naming scheme and do not touch user workspaces,
    # state, sessions or any other plugin.
    for project_dir in "${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required}"/npm/projects/openclaw-memory-lancedb-*; do
        [ -d "$project_dir" ] || continue
        validate_managed_generation "$project_dir" '@openclaw/memory-lancedb'
        chown -R --no-dereference root:root "$project_dir"
        # GNU chmod does not implement --no-dereference; its default
        # recursive traversal is physical (it does not traverse symlinked
        # directories), which preserves the boundary checked above.
        chmod -R u=rwX,go=rX "$project_dir"
    done
}

ensure_root_owned_plugin() {
    package_name="$1"
    expected_version="$2"
    manifest="$(latest_plugin_manifest "$package_name")"
    installed_version=""
    project_dir=""
    owner=""

    if [ -r "$manifest" ]; then
        installed_version="$(plugin_version "$manifest")"
        project_dir="$(plugin_project_dir "$manifest" "$package_name")"
        owner="$(stat -c '%u' "$project_dir" 2>/dev/null || true)"
    fi

    # `--force` is intentional. It repairs an earlier OpenClaw generation
    # which installed the plugin while already running as UID 10000. Never
    # use Doctor's broad auto-repair path here: this is the one bounded
    # payload the installation owns and version-pins.
    if [ "$installed_version" != "$expected_version" ] || [ "$owner" != "0" ]; then
        printf '%s\n' "[openclaw] Installing immutable ${package_name}@${expected_version}"
        set_package_retention_markers "$package_name" "$IM_UID:$IM_GID" 0700
        state_owner_cli plugins install --force --accept-capabilities "${package_name}@${expected_version}"
        manifest="$(latest_plugin_manifest "$package_name")"
        [ -r "$manifest" ] || {
            printf '%s\n' "[openclaw] ${package_name} was not installed" >&2
            exit 1
        }
        installed_version="$(plugin_version "$manifest")"
        [ "$installed_version" = "$expected_version" ] || {
            printf '%s\n' "[openclaw] ${package_name} version mismatch: expected ${expected_version}, got ${installed_version:-<missing>}" >&2
            exit 1
        }
        project_dir="$(plugin_project_dir "$manifest" "$package_name")"
    fi

    # The project root is a generated package generation, not all of
    # ~/.openclaw. Leave state, sessions and model credentials owned by ai.
    validate_managed_generation "$project_dir" "$package_name"
    chown -R root:root "$project_dir"
    chmod -R u=rwX,go=rX "$project_dir"
}

ensure_openclaw_peer_link() {
    package_name="$1"
    manifest="$(latest_plugin_manifest "$package_name")"
    [ -r "$manifest" ] || {
        printf '%s\n' "[openclaw] managed plugin manifest is missing: ${package_name}" >&2
        exit 1
    }
    project_dir="$(plugin_project_dir "$manifest" "$package_name")"
    peer_link="${project_dir}/node_modules/openclaw"
    expected_peer="/usr/local/lib/node_modules/openclaw"
    [ -d "$expected_peer" ] || {
        printf '%s\n' "[openclaw] selected OpenClaw host is missing: ${expected_peer}" >&2
        exit 1
    }

    if [ -e "$peer_link" ] && [ ! -L "$peer_link" ]; then
        printf '%s\n' "[openclaw] refusing non-link peer dependency at ${peer_link}" >&2
        exit 1
    fi
    if [ -L "$peer_link" ] && [ "$(readlink "$peer_link")" = "$expected_peer" ] && [ -e "$peer_link" ]; then
        return 0
    fi

    # This link belongs to the root-owned package generation.  A stale or
    # dangling peer link makes OpenClaw block the plugin before config
    # validation, so replace only this exact path with the selected host.
    rm -f "$peer_link"
    ln -s "$expected_peer" "$peer_link"
    chown -h root:root "$peer_link" 2>/dev/null || true
    [ -e "$peer_link" ] || {
        printf '%s\n' "[openclaw] failed to establish peer link for ${package_name}" >&2
        exit 1
    }
}

ensure_openclaw_peer_link_if_present() {
    package_name="$1"
    manifest="$(latest_plugin_manifest "$package_name")"
    [ -z "$manifest" ] || ensure_openclaw_peer_link "$package_name"
}

load_agentgateway_token
# Managed installs must not inherit old root-owned ~/.npm entries. This one
# bounded tmpfs cache belongs to the runtime UID; only the generated package
# payload is promoted to root after the state-owner command commits.
managed_npm_cache=/tmp/openclaw-managed-npm-cache
if [ -L "$managed_npm_cache" ]; then
    printf '%s\n' '[openclaw] refusing symlinked managed npm cache' >&2
    exit 1
fi
if [ -e "$managed_npm_cache" ]; then
    [ -d "$managed_npm_cache" ] \
        && [ "$(stat -c '%u:%g:%a' "$managed_npm_cache")" = "$IM_UID:$IM_GID:700" ] || {
        printf '%s\n' '[openclaw] refusing unexpected managed npm cache ownership/type' >&2
        exit 1
    }
fi
install -d -m 0700 -o "$IM_UID" -g "$IM_GID" "$managed_npm_cache"
export npm_config_cache="$managed_npm_cache"
# Run even when a managed CLI command fails: otherwise a partial plugin
# repair could leave the next unprivileged Gateway start unable to read its
# persistent configuration.
prepare_runtime_state_root
prepare_managed_install_parents
trap 'restore_managed_retention_ownership; restore_gateway_config_ownership' EXIT
# Generic deploys deliberately start with OPENCLAW_LANCEDB_ENABLED=0 until
# the installation model profile supplies its embedding configuration.  The
# persistent config can nevertheless still reference the previous memory
# slot during that short window, so the package must be trusted before the
# first OpenClaw CLI invocation even when this flag is temporarily disabled.
adopt_existing_lancedb_generation
# Establish an already-installed peer before the first plugin CLI command.
ensure_openclaw_peer_link_if_present "@openclaw/memory-lancedb"
ensure_root_owned_plugin "@openclaw/codex" "${OPENCLAW_CODEX_PLUGIN_VERSION:?OPENCLAW_CODEX_PLUGIN_VERSION is required}"
ensure_openclaw_peer_link "@openclaw/codex"
if is_enabled "${OPENCLAW_LANCEDB_ENABLED:-0}" || [ -n "$(latest_plugin_manifest '@openclaw/memory-lancedb')" ]; then
    ensure_root_owned_plugin "@openclaw/memory-lancedb" "${OPENCLAW_LANCEDB_PLUGIN_VERSION:?OPENCLAW_LANCEDB_PLUGIN_VERSION is required}"
    ensure_openclaw_peer_link "@openclaw/memory-lancedb"
else
    # A generic deployment can temporarily disable the environment flag
    # while persistent config still selects the prior memory slot.
    ensure_openclaw_peer_link_if_present "@openclaw/memory-lancedb"
fi

# Registry refresh runs after privilege drop in entrypoint.sh. State-owner
# projections must belong to the Gateway user, not this root prestart process.
