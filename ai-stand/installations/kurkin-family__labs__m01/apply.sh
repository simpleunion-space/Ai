#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  */*) INSTALLATION_DIR="$(cd -- "${SCRIPT_PATH%/*}" && pwd)" ;;
  *) INSTALLATION_DIR="$(pwd)" ;;
esac

AI_STAND_DIR="$(cd -- "${INSTALLATION_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
. "${INSTALLATION_DIR}/installation.sh"

ACCELERATOR="$DEFAULT_ACCELERATOR"
MANAGER_JOIN_TOKEN=""
USE_SUDO="auto"

usage() {
  cat <<USAGE
Usage: $(basename "$0") <command> [options]

Commands:
  preflight-ai01
  preflight-linux01
  host-ai01
  host-linux01
  images-ai01
  images-linux01
  deploy
  configure-authentik
  configure-portainer
  verify-ai01
  verify-linux01
  credentials
  model-apply
  model-status
  model-verify

Options:
  --accelerator auto|cpu|amd|nvidia    Default: ${DEFAULT_ACCELERATOR}
  --manager-join-token <token>         Required when linux01 must join Swarm
  --sudo auto|always|never             Default: auto
  -h, --help

This wrapper is installation-specific for ${INSTALLATION_NAME}.
It calls ${AI_STAND_DIR}/apply.sh with the profile's node/IP/CIDR constants.
USAGE
}

die() {
  printf '%s\n' "[${INSTALLATION_NAME}] ERROR: $*" >&2
  exit 1
}

log() {
  printf '%s\n' "[${INSTALLATION_NAME}] $*"
}

parse_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --accelerator)
        [ "$#" -ge 2 ] || die "--accelerator requires a value"
        ACCELERATOR="$2"
        shift 2
        ;;
      --accelerator=*)
        ACCELERATOR="${1#*=}"
        shift
        ;;
      --manager-join-token)
        [ "$#" -ge 2 ] || die "--manager-join-token requires a value"
        MANAGER_JOIN_TOKEN="$2"
        shift 2
        ;;
      --manager-join-token=*)
        MANAGER_JOIN_TOKEN="${1#*=}"
        shift
        ;;
      --sudo)
        [ "$#" -ge 2 ] || die "--sudo requires a value"
        USE_SUDO="$2"
        shift 2
        ;;
      --sudo=*)
        USE_SUDO="${1#*=}"
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  case "$ACCELERATOR" in
    auto|cpu|amd|nvidia) ;;
    *) die "--accelerator must be auto, cpu, amd or nvidia" ;;
  esac
  case "$USE_SUDO" in
    auto|always|never) ;;
    *) die "--sudo must be auto, always or never" ;;
  esac
}

sudo_prefix() {
  case "$USE_SUDO" in
    always)
      printf '%s\n' sudo
      ;;
    never)
      return 0
      ;;
    auto)
      if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        printf '%s\n' sudo
      fi
      ;;
  esac
}

trusted_args_append() {
  local -n target_args="$1"
  local cidr
  for cidr in "${TRUSTED_CIDRS[@]}"; do
    target_args+=(--trusted-cidr "$cidr")
  done
}

run_generic_apply() {
  local command="$1"
  local node_name="$2"
  local host_ip="$3"
  local peer_ip="$4"
  shift 4

  local args=(
    "${AI_STAND_DIR}/apply.sh"
    "$command"
    --installation "$INSTALLATION_NAME"
    --node-name "$node_name"
    --host-ip "$host_ip"
    --peer-ip "$peer_ip"
  )
  trusted_args_append args

  if [ "$node_name" = "$AI01_NODE_NAME" ]; then
    args+=(--accelerator "$ACCELERATOR")
  fi

  if [ "$node_name" = "$LINUX01_NODE_NAME" ] && [ -n "$MANAGER_JOIN_TOKEN" ]; then
    args+=(--manager-join-token "$MANAGER_JOIN_TOKEN")
  fi

  args+=("$@")

  local prefix
  prefix="$(sudo_prefix || true)"
  log "Running generic apply: $command on $node_name"
  if [ -n "$prefix" ]; then
    "$prefix" bash "${args[@]}"
  else
    bash "${args[@]}"
  fi
}

run_generic_images() {
  local node_name="$1"
  local args=(
    "${AI_STAND_DIR}/apply.sh"
    images
    --installation "$INSTALLATION_NAME"
    --node-name "$node_name"
  )

  if [ "$node_name" = "$AI01_NODE_NAME" ]; then
    args+=(--accelerator "$ACCELERATOR")
  fi

  local prefix
  prefix="$(sudo_prefix || true)"
  log "Building/pulling images for $node_name"
  if [ -n "$prefix" ]; then
    "$prefix" bash "${args[@]}"
  else
    bash "${args[@]}"
  fi
}

run_model_profile() {
  local command="$1"
  local prefix
  prefix="$(sudo_prefix || true)"
  log "Running model profile: $command"
  if [ -n "$prefix" ]; then
    # Plain `sudo` resets the environment by default, which silently drops
    # apply-model-profile.sh's own overridable tunables (AI_UID/AI_GID/
    # CONTEXT_RESOLVE_TIMEOUT_SECONDS/OPENCLAW_MAX_TOKENS_*) if the operator
    # set them in this shell - confirmed 2026-09-13, they'd fall back to
    # hardcoded defaults with no warning.
    #
    # `sudo VAR=val cmd` (tried first, 2026-09-13) does NOT reliably forward
    # them: that form requires the `setenv` Defaults flag or a per-rule
    # `SETENV:` tag in sudoers, and this repo grants neither anywhere (the
    # one sudoers rule ai-stand's IaC touches at all,
    # ansible-setup/roles/accounts/tasks/main.yml, has no SETENV: tag) -
    # without it sudo either silently drops the VAR=val prefixes (back to
    # this exact bug) or, on sudo 1.9+, refuses to run the command at all.
    # Routing through `env` instead sidesteps sudoers entirely: from sudo's
    # policy-check perspective the command being run is just `env` with
    # plain arguments, not a VAR=val environment request, and `env` sets
    # them for its own exec'd child once it's already running as the
    # target user post-sudo. Still not a blanket `sudo -E`, which would
    # also carry unrelated things like PATH/LD_PRELOAD into a privileged
    # context.
    "$prefix" env \
      AI_UID="${AI_UID:-}" \
      AI_GID="${AI_GID:-}" \
      CONTEXT_RESOLVE_TIMEOUT_SECONDS="${CONTEXT_RESOLVE_TIMEOUT_SECONDS:-}" \
      OPENCLAW_MAX_TOKENS_DIVISOR="${OPENCLAW_MAX_TOKENS_DIVISOR:-}" \
      OPENCLAW_MAX_TOKENS_FLOOR="${OPENCLAW_MAX_TOKENS_FLOOR:-}" \
      OPENCLAW_MAX_TOKENS_CAP="${OPENCLAW_MAX_TOKENS_CAP:-}" \
      bash "$MODEL_PROFILE_SCRIPT" "$command"
  else
    bash "$MODEL_PROFILE_SCRIPT" "$command"
  fi
}

command_name="${1:-}"
case "$command_name" in
  -h|--help|help|'')
    usage
    exit 0
    ;;
esac
shift
parse_options "$@"

case "$command_name" in
  preflight-ai01)
    run_generic_apply preflight "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    ;;
  preflight-linux01)
    run_generic_apply preflight "$LINUX01_NODE_NAME" "$LINUX01_IP" "$AI01_IP"
    ;;
  host-ai01)
    run_generic_apply host "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    ;;
  host-linux01)
    run_generic_apply host "$LINUX01_NODE_NAME" "$LINUX01_IP" "$AI01_IP"
    ;;
  images-ai01)
    run_generic_images "$AI01_NODE_NAME"
    ;;
  images-linux01)
    run_generic_images "$LINUX01_NODE_NAME"
    ;;
  deploy)
    # `ai-stand/apply.sh deploy` itself resets the model profile back to
    # compose.yaml's generic default (see MODEL_PROFILE_SCRIPT/model-apply
    # below) - it has no notion of "this installation's intended model" at
    # all, being shared across every installation. Re-applying it here,
    # right after, means a plain `deploy` can no longer silently regress
    # LM Studio/Open WebUI back to the small default the way it repeatedly
    # has (confirmed live 2026-09-10, twice in one session). If the
    # resolved-context state file doesn't exist yet, this can take a long
    # time the first time (model-apply retries multiple context sizes) -
    # that cost was already unavoidable on the very next model-apply run
    # either way, just now paid immediately instead of silently deferred.
    run_generic_apply deploy "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    # configure-authentik right after deploy, unconditionally, for the same
    # reason model-apply already runs unconditionally below: on a genuinely
    # fresh install (or a from-scratch Authentik data wipe), agentgateway
    # gets pushed its real OIDC issuer URL immediately by deploy's own
    # apply_installation_service_env() - unlike Coder's old staged approach,
    # nothing waits for the Authentik application to actually exist first -
    # and agentgateway crashes outright (not just its OIDC surface, the
    # whole process) when that issuer 404s, confirmed live 2026-09-13. That
    # cascades into anything routing through agentgateway (openclaw-gateway
    # included) never becoming ready, which would otherwise make the
    # model-apply call right below this hang until it times out. Previously
    # this was only fixed by a human remembering to run configure-authentik
    # as the very next manual step (see README's rollout order) - making it
    # automatic here means a plain `deploy` can't leave the stack in that
    # half-working state even if nobody runs the next command right away.
    run_generic_apply configure-authentik "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    run_model_profile apply
    ;;
  configure-authentik)
    run_generic_apply configure-authentik "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    ;;
  configure-portainer)
    run_generic_apply configure-portainer "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    ;;
  verify-ai01)
    run_generic_apply verify "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    ;;
  verify-linux01)
    run_generic_apply verify "$LINUX01_NODE_NAME" "$LINUX01_IP" "$AI01_IP"
    ;;
  credentials)
    run_generic_apply credentials "$AI01_NODE_NAME" "$AI01_IP" "$LINUX01_IP"
    ;;
  model-apply)
    run_model_profile apply
    ;;
  model-status)
    run_model_profile status
    ;;
  model-verify)
    run_model_profile verify
    ;;
  *)
    usage >&2
    die "Unknown command: $command_name"
    ;;
esac
