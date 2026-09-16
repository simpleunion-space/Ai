#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  */*) INSTALLATION_DIR="$(cd -- "${SCRIPT_PATH%/*}" && pwd)" ;;
  *) INSTALLATION_DIR="$(pwd)" ;;
esac

# shellcheck disable=SC1091
. "${INSTALLATION_DIR}/installation.sh"

STACK_NAME="ai-stand"
PROFILE_NAME="$INSTALLATION_NAME"
PROFILE_STATE_DIR="/mnt/storage/lmstudio-data/lmstudio/.ai-stand/${PROFILE_NAME}"
PROFILE_CONTEXT_STATE="${PROFILE_STATE_DIR}/context.env"
PROFILE_WORKER_PREFIX="$PROFILE_NAME"
AI_UID="${AI_UID:-$IM_UID}"
AI_GID="${AI_GID:-$IM_GID}"

CHAT_MODEL_SOURCE="qwen/qwen3.8-27b@q8_0"
# Must match service-entrypoint.sh's own LMSTUDIO_MODEL_KEY derivation
# ("${LMSTUDIO_MODEL%%@*}"): `lms load` is called with this as both the
# catalog key AND the --identifier. When they differ, LM Studio lists the
# catalog entry and the custom-identified loaded instance as two separate
# rows in /v1/models for the same weights; keeping identifier == key
# collapses them back into one.
CHAT_MODEL_IDENTIFIER="${CHAT_MODEL_SOURCE%%@*}"
CHAT_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER="lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf"
# No Q4 variant is kept anywhere in this installation's catalog (Q4
# quantization quality deemed too low, 2026-09-06) - nothing to hide.
CHAT_MODEL_HIDE_VARIANT_FILES=""
CHAT_CONTEXT_CANDIDATES=(262144 131072 65536 32768 24576 16384 8192 4096)
CHAT_CONTEXT_LENGTH="${CHAT_CONTEXT_CANDIDATES[0]}"
CHAT_PARALLEL="1"
# Placeholder only - always recomputed by openclaw_tokens_for_context()
# before use.
OPENCLAW_MAX_TOKENS="32768"
# This installation deliberately opts into autonomous execution only for the
# Codex harness. Generic compose defaults to Guardian; see init.mjs for the
# exact app-server policy and the container/DIND isolation boundary.
OPENCLAW_CODEX_EXECUTION_PROFILE="autonomous"

EMBEDDING_MODEL_SOURCE="https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF/resolve/main/Qwen3-Embedding-4B-Q8_0.gguf"
EMBEDDING_MODEL_KEY="text-embedding-qwen3-embedding-4b"
EMBEDDING_MODEL_IDENTIFIER="qwen3-embedding-4b-q8"
EMBEDDING_CONTEXT_CANDIDATES=(32768 16384 8192)
EMBEDDING_CONTEXT_LENGTH="${EMBEDDING_CONTEXT_CANDIDATES[0]}"
EMBEDDING_DIMENSIONS="2560"
# The m01 profile deliberately shares ai01's GPU-backed LM Studio between
# the chat and embedding workers. Do not let a stale generic service env
# silently retain the old CPU setting when model-apply runs independently.
# lms load accepts a numeric GPU offload ratio; 1 keeps all embedding layers
# on ai01's GPU (rather than falling back to a CPU inference service).
EMBEDDING_GPU="1"
CONTEXT_RESOLVE_TIMEOUT_SECONDS="${CONTEXT_RESOLVE_TIMEOUT_SECONDS:-7200}"

# OPENCLAW_MAX_TOKENS is OpenClaw's per-completion OUTPUT cap (see
# docker/openclaw/init.mjs's models.providers.lmstudio[0].maxTokens), not a
# share of the total conversation budget - contextWindow already covers
# that, and init.mjs enforces maxTokens < contextWindow. It must scale with
# the resolved chat context: a flat cap here (unchanged 2026-07-27 through
# 2026-09-06, even after CHAT_CONTEXT_CANDIDATES's ceiling was quadrupled to
# 262144 on 2026-09-05) needlessly limits a single completion on a
# large-context model to a tiny fraction of what it can use, and combined
# with a stale OpenClaw session JIT-reloading an old model, produced a
# literal n_ctx=8192 backend error on a 262144-context install (2026-09-06
# incident). These three tunables keep a completion from ever exceeding 1/4
# of the active context, floored at 2048 (still usable at the smallest chat
# context candidate) and capped at 32768 (an uncapped ratio would let one
# runaway generation consume most of a huge context window and crowd out
# conversation history).
OPENCLAW_MAX_TOKENS_DIVISOR="${OPENCLAW_MAX_TOKENS_DIVISOR:-4}"
OPENCLAW_MAX_TOKENS_FLOOR="${OPENCLAW_MAX_TOKENS_FLOOR:-2048}"
OPENCLAW_MAX_TOKENS_CAP="${OPENCLAW_MAX_TOKENS_CAP:-32768}"

# Goes through agentgateway, not lmstudio directly (see
# agentgateway/config.yaml) - the token is generated once by apply.sh's
# ensure_ai_stand_secrets() (load_host_secret agentgateway-openwebui-token),
# well before this script ever runs; a plain top-level `cat` under
# `set -euo pipefail` is enough to abort cleanly if that assumption is ever
# wrong (no need for a separate die() call here - not defined yet at this
# point in the file).
AGENTGATEWAY_OPENWEBUI_TOKEN="$(cat /mnt/storage/_secrets/agentgateway-openwebui-token)"
OPENWEBUI_OPENAI_API_CONFIGS="{\"0\":{\"enable\":true,\"base_url\":\"http://agentgateway:4000/v1\",\"api_key\":\"${AGENTGATEWAY_OPENWEBUI_TOKEN}\",\"model_ids\":[\"${CHAT_MODEL_IDENTIFIER}\"]}}"
# The api_key embedded in OPENAI_API_CONFIGS above is NOT what Open WebUI
# actually sends as the outbound Authorization bearer - confirmed live
# 2026-09-11 by reading its own routers/openai.py: the real request uses
# OPENAI_API_KEYS[idx] (a separate, flat env var), not api_configs[idx].api_key.
# Before agentgateway existed, leaving this at compose.yaml's placeholder was
# harmless (LM Studio accepts any non-empty bearer) - now that Open WebUI's
# traffic goes through agentgateway's apiKey.mode: strict policy, a stale
# placeholder here means every single chat request gets a 401 from
# agentgateway that Open WebUI's frontend doesn't surface, rendering as a
# silently empty response. Must be pushed every run, same as the configs above.
OPENWEBUI_OPENAI_API_KEYS="$AGENTGATEWAY_OPENWEBUI_TOKEN"
OPENWEBUI_DEFAULT_MODELS="$CHAT_MODEL_IDENTIFIER"

# Q4_K_M variants deliberately not downloaded/kept anywhere in this list -
# quantization quality deemed too low for this installation (2026-09-06).
BACKGROUND_DOWNLOADS="$(
  cat <<DOWNLOADS
$EMBEDDING_MODEL_SOURCE
https://huggingface.co/Qwen/Qwen3-Embedding-8B-GGUF/resolve/main/Qwen3-Embedding-8B-Q8_0.gguf
qwen/qwen3.8-27b@q8_0
qwen/qwen3.6-35b-a3b@q8_0
qwen/qwen3.6-27b@q8_0
qwen/qwen3.5-9b@q8_0
qwen/qwen3-8b@q8_0
qwen/qwen3-4b@q8_0
qwen/qwen3-1.7b@q8_0
DOWNLOADS
)"

log() {
  printf '%s\n' "[${PROFILE_NAME}-model-profile] $*"
}

die() {
  printf '%s\n' "[${PROFILE_NAME}-model-profile] ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage:
  apply-model-profile.sh apply
  apply-model-profile.sh status
  apply-model-profile.sh verify

Run on ${AI01_HOST} after the generic ai-stand stack is deployed.

This script is installation-specific for ${INSTALLATION_NAME}:
  - keeps generic ai-stand source fast: qwen/qwen3-1.7b@q8_0;
  - switches this installation to qwen/qwen3.8-27b@q8_0;
  - keeps qwen3-embedding-0.6b-q8 as the active embedding model;
  - starts background downloads for the extended local model catalog;
  - resolves the highest working chat/embedding context from candidate lists;
  - exposes only qwen3.8-27b-q8 as the LM Studio chat model in Open WebUI.
USAGE
}

require_commands() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

service_name() {
  printf '%s_%s\n' "$STACK_NAME" "$1"
}

ensure_service() {
  local svc
  svc="$(service_name "$1")"
  docker service inspect "$svc" >/dev/null 2>&1 || die "Missing service: $svc"
}

current_env_value() {
  local svc="$1"
  local key="$2"
  docker service inspect "$svc" \
    | jq -r \
      --arg key "$key" \
      '.[0].Spec.TaskTemplate.ContainerSpec.Env // []
       | map(select(startswith($key + "=")))
       | .[0] // empty
       | .[(($key | length) + 1):]'
}

has_env_key() {
  local svc="$1"
  local key="$2"
  docker service inspect "$svc" \
    | jq -e \
      --arg key "$key" \
      '.[0].Spec.TaskTemplate.ContainerSpec.Env // []
       | map(select(startswith($key + "=")))
       | length > 0' >/dev/null
}

update_service_env() {
  local short_name="$1"
  shift

  local svc
  svc="$(service_name "$short_name")"
  ensure_service "$short_name"

  local args
  args=(--detach=true)
  local changed="false"

  local kv key desired current
  for kv in "$@"; do
    key="${kv%%=*}"
    desired="${kv#*=}"
    current="$(current_env_value "$svc" "$key")"

    if [ "$current" = "$desired" ]; then
      continue
    fi

    if has_env_key "$svc" "$key"; then
      args+=(--env-rm "$key")
    fi
    args+=(--env-add "$key=$desired")
    changed="true"
  done

  if [ "$changed" = "true" ]; then
    log "Updating environment for $svc"
    docker service update "${args[@]}" "$svc" >/dev/null
  else
    log "$svc environment is already up to date"
  fi
}

local_lmstudio_container() {
  docker ps \
    --filter "label=com.docker.swarm.service.name=$(service_name lmstudio)" \
    --format '{{.ID}}' \
    | head -n 1 || true
}

local_service_container() {
  local short_name="$1"
  docker ps \
    --filter "label=com.docker.swarm.service.name=$(service_name "$short_name")" \
    --format '{{.ID}}' \
    | head -n 1 || true
}

local_lmstudio_container_with_profile() {
  local cid value

  while IFS= read -r cid; do
    [ -n "$cid" ] || continue

    value="$(docker inspect "$cid" \
      | jq -r \
        '.[0].Config.Env // []
         | map(select(startswith("LMSTUDIO_MODEL_IDENTIFIER=")))
         | .[0] // ""
         | sub("^LMSTUDIO_MODEL_IDENTIFIER="; "")')"
    if [ "$value" != "$CHAT_MODEL_IDENTIFIER" ]; then
      continue
    fi

    value="$(docker inspect "$cid" \
      | jq -r \
        '.[0].Config.Env // []
         | map(select(startswith("LMSTUDIO_CONTEXT_LENGTH=")))
         | .[0] // ""
         | sub("^LMSTUDIO_CONTEXT_LENGTH="; "")')"
    if [ "$value" != "$CHAT_CONTEXT_LENGTH" ]; then
      continue
    fi

    printf '%s\n' "$cid"
    return 0
  done <<CONTAINERS
$(docker ps \
  --filter "label=com.docker.swarm.service.name=$(service_name lmstudio)" \
  --format '{{.ID}}')
CONTAINERS

  return 1
}

container_models_include() {
  local cid="$1"
  local chat_id="$2"
  local embedding_id="$3"

  docker exec -u ai "$cid" sh -lc \
    '$HOME/.lmstudio/bin/lms ps --json' \
    | jq -e \
      --arg chat_id "$chat_id" \
      --arg embedding_id "$embedding_id" \
      'any(.[]?;
          .identifier == $chat_id
          and ((.status // "") | ascii_downcase) == "idle"
        )
       and any(.[]?;
          .identifier == $embedding_id
          and ((.status // "") | ascii_downcase) == "idle"
        )' >/dev/null
}

dump_lmstudio_profile_debug() {
  docker service ps "$(service_name lmstudio)" --no-trunc || true

  local cid
  cid="$(local_lmstudio_container || true)"
  if [ -n "$cid" ]; then
    log "LM Studio current models:"
    docker exec -u ai "$cid" sh -lc \
      'curl -fsS http://127.0.0.1:${LMSTUDIO_PORT:-1234}/v1/models 2>/dev/null | jq -r ".data[]?.id" | sort || true' || true
    log "LM Studio current env:"
    docker inspect "$cid" \
      | jq -r '.[0].Config.Env // [] | map(select(startswith("LMSTUDIO_"))) | .[]' \
      | sort || true
  fi
}

try_wait_lmstudio_profile_ready() {
  local timeout_seconds="${1:-7200}"
  local elapsed="0"
  local cid=""

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if [ "$(docker service ls --filter "name=$(service_name lmstudio)" --format '{{.Replicas}}' | head -n 1)" = "1/1" ]; then
      cid="$(local_lmstudio_container_with_profile || true)"
      if [ -n "$cid" ] && container_models_include "$cid" "$CHAT_MODEL_IDENTIFIER" "$EMBEDDING_MODEL_IDENTIFIER"; then
        log "LM Studio m01 profile is ready in container $cid"
        return 0
      fi
    fi

    sleep 15
    elapsed="$((elapsed + 15))"
  done

  dump_lmstudio_profile_debug
  return 1
}

wait_lmstudio_profile_ready() {
  local timeout_seconds="${1:-7200}"
  try_wait_lmstudio_profile_ready "$timeout_seconds" \
    || die "LM Studio m01 profile did not become ready within ${timeout_seconds}s"
}

openclaw_tokens_for_context() {
  local context="$1"
  local tokens="$((context / OPENCLAW_MAX_TOKENS_DIVISOR))"

  if [ "$tokens" -lt "$OPENCLAW_MAX_TOKENS_FLOOR" ]; then
    tokens="$OPENCLAW_MAX_TOKENS_FLOOR"
  fi
  if [ "$tokens" -gt "$OPENCLAW_MAX_TOKENS_CAP" ]; then
    tokens="$OPENCLAW_MAX_TOKENS_CAP"
  fi

  printf '%s\n' "$tokens"
}

is_array_member() {
  local value="$1"
  shift

  local item
  for item in "$@"; do
    if [ "$item" = "$value" ]; then
      return 0
    fi
  done

  return 1
}

state_value() {
  local key="$1"
  [ -r "$PROFILE_CONTEXT_STATE" ] || return 1
  sed -n "s/^${key}=//p" "$PROFILE_CONTEXT_STATE" | tail -n 1
}

load_resolved_context_from_state() {
  local chat_context
  local embedding_context

  chat_context="$(state_value CHAT_CONTEXT_LENGTH || true)"
  embedding_context="$(state_value EMBEDDING_CONTEXT_LENGTH || true)"

  if ! is_array_member "$chat_context" "${CHAT_CONTEXT_CANDIDATES[@]}"; then
    return 1
  fi
  if ! is_array_member "$embedding_context" "${EMBEDDING_CONTEXT_CANDIDATES[@]}"; then
    return 1
  fi

  CHAT_CONTEXT_LENGTH="$chat_context"
  EMBEDDING_CONTEXT_LENGTH="$embedding_context"
  # Always re-derive from the just-validated chat context instead of trusting
  # a persisted OPENCLAW_MAX_TOKENS value: openclaw_tokens_for_context() is a
  # pure function of chat context, so persisting/validating its output here
  # separately only creates another place that can go stale (exactly how
  # this flatlined at 8192 in 2026-09). Recomputing also self-heals any
  # installation that already persisted a stale value under the old bug the
  # next time model-apply runs, without deleting the state file / forcing a
  # full re-probe.
  OPENCLAW_MAX_TOKENS="$(openclaw_tokens_for_context "$CHAT_CONTEXT_LENGTH")"
  log "Loaded resolved context from state: chat=${CHAT_CONTEXT_LENGTH}, embedding=${EMBEDDING_CONTEXT_LENGTH}, openclaw_max=${OPENCLAW_MAX_TOKENS}"
  return 0
}

persist_resolved_context_state() {
  mkdir -p "$PROFILE_STATE_DIR"

  local tmp
  tmp="$(mktemp "${PROFILE_STATE_DIR}/context.env.XXXXXX")"
  {
    printf 'CHAT_MODEL_IDENTIFIER=%s\n' "$CHAT_MODEL_IDENTIFIER"
    printf 'CHAT_CONTEXT_LENGTH=%s\n' "$CHAT_CONTEXT_LENGTH"
    printf 'EMBEDDING_MODEL_IDENTIFIER=%s\n' "$EMBEDDING_MODEL_IDENTIFIER"
    printf 'EMBEDDING_CONTEXT_LENGTH=%s\n' "$EMBEDDING_CONTEXT_LENGTH"
    printf 'OPENCLAW_MAX_TOKENS=%s\n' "$OPENCLAW_MAX_TOKENS"
  } > "$tmp"
  chmod 0640 "$tmp"
  mv "$tmp" "$PROFILE_CONTEXT_STATE"
  chown -R "${AI_UID}:${AI_GID}" "$PROFILE_STATE_DIR" 2>/dev/null || true
  log "Persisted resolved context state: ${PROFILE_CONTEXT_STATE}"
}

update_lmstudio_profile_env() {
  update_service_env lmstudio \
    "LMSTUDIO_MODEL=$CHAT_MODEL_SOURCE" \
    "LMSTUDIO_MODEL_IDENTIFIER=$CHAT_MODEL_IDENTIFIER" \
    "LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER=$CHAT_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER" \
    "LMSTUDIO_MODEL_HIDE_VARIANT_FILES=$CHAT_MODEL_HIDE_VARIANT_FILES" \
    "LMSTUDIO_CONTEXT_LENGTH=$CHAT_CONTEXT_LENGTH" \
    "LMSTUDIO_PARALLEL=$CHAT_PARALLEL" \
    "LMSTUDIO_EMBEDDING_MODEL=$EMBEDDING_MODEL_SOURCE" \
    "LMSTUDIO_EMBEDDING_MODEL_KEY=$EMBEDDING_MODEL_KEY" \
    "LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER=$EMBEDDING_MODEL_IDENTIFIER" \
    "LMSTUDIO_EMBEDDING_CONTEXT_LENGTH=$EMBEDDING_CONTEXT_LENGTH" \
    "LMSTUDIO_EMBEDDING_DIMENSIONS=$EMBEDDING_DIMENSIONS" \
    "LMSTUDIO_EMBEDDING_GPU=$EMBEDDING_GPU"
}

resolve_context_policy() {
  if load_resolved_context_from_state; then
    update_lmstudio_profile_env
    wait_lmstudio_profile_ready "$CONTEXT_RESOLVE_TIMEOUT_SECONDS"
    return 0
  fi

  local chat_context
  local embedding_context

  for chat_context in "${CHAT_CONTEXT_CANDIDATES[@]}"; do
    for embedding_context in "${EMBEDDING_CONTEXT_CANDIDATES[@]}"; do
      CHAT_CONTEXT_LENGTH="$chat_context"
      EMBEDDING_CONTEXT_LENGTH="$embedding_context"
      OPENCLAW_MAX_TOKENS="$(openclaw_tokens_for_context "$CHAT_CONTEXT_LENGTH")"

      log "Trying context profile: chat=${CHAT_CONTEXT_LENGTH}, embedding=${EMBEDDING_CONTEXT_LENGTH}, openclaw_max=${OPENCLAW_MAX_TOKENS}"
      update_lmstudio_profile_env

      if try_wait_lmstudio_profile_ready "$CONTEXT_RESOLVE_TIMEOUT_SECONDS"; then
        persist_resolved_context_state
        return 0
      fi

      log "Context profile did not become ready; trying next candidate"
    done
  done

  die "Unable to resolve a working LM Studio context profile"
}

start_download_worker() {
  local lmstudio_container
  lmstudio_container="$(local_lmstudio_container)"
  if [ -z "$lmstudio_container" ]; then
    die "LM Studio task is not running on this node; run this script on ai01"
  fi

  local download_list="/home/ai/.lmstudio/.internal/${PROFILE_WORKER_PREFIX}-downloads.txt"
  local worker_script="/home/ai/.lmstudio/.internal/${PROFILE_WORKER_PREFIX}-background-download.sh"
  local worker_nohup="/home/ai/.lmstudio/.internal/${PROFILE_WORKER_PREFIX}-background-download.nohup"

  docker exec -i -u ai "$lmstudio_container" sh -lc \
    "mkdir -p /home/ai/.lmstudio/.internal && cat > ${download_list}" \
    <<DOWNLOADS
$BACKGROUND_DOWNLOADS
DOWNLOADS

  docker exec -i -u ai "$lmstudio_container" sh -lc \
    "cat > ${worker_script} && chmod +x ${worker_script}" \
    <<WORKER
#!/bin/sh
set -eu

profile_worker_prefix="${PROFILE_WORKER_PREFIX}"
home="\${HOME:-/home/ai}"
lms_bin="\${LMSTUDIO_SEED_HOME:-/opt/lmstudio-seed}/.lmstudio/bin/lms"
if [ ! -x "\$lms_bin" ]; then
  lms_bin="\$home/.lmstudio/bin/lms"
fi

list_file="\$home/.lmstudio/.internal/\${profile_worker_prefix}-downloads.txt"
log_file="\$home/.lmstudio/.internal/\${profile_worker_prefix}-background-download.log"
pid_file="\$home/.lmstudio/.internal/\${profile_worker_prefix}-background-download.pid"

if [ -s "\$pid_file" ]; then
  old_pid="\$(cat "\$pid_file" 2>/dev/null || true)"
  if [ -n "\$old_pid" ] && kill -0 "\$old_pid" 2>/dev/null; then
    printf '%s\n' "\$profile_worker_prefix background download already running as pid \$old_pid"
    exit 0
  fi
fi

(
  printf '\n=== %s background model download started ===\n' "\$profile_worker_prefix"
  date -Iseconds

  while IFS= read -r raw_item; do
    item="\$(printf '%s' "\$raw_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "\$item" in
      ''|'#'*) continue ;;
    esac

    available_kb="\$(df -Pk "\$home" | awk 'NR==2 {print \$4}')"
    if [ "\$available_kb" -lt "\$((20 * 1024 * 1024))" ]; then
      printf '\n=== %s ===\nSKIP: only %s KB free, below 20GB minimum\n' "\$item" "\$available_kb"
      continue
    fi

    printf '\n=== %s ===\n' "\$item"
    date -Iseconds
    if "\$lms_bin" get "\$item" -y; then
      printf 'OK %s\n' "\$item"
    else
      rc="\$?"
      printf 'FAIL rc=%s %s\n' "\$rc" "\$item"
    fi
    date -Iseconds
  done < "\$list_file"

  printf '\n=== %s background model download finished ===\n' "\$profile_worker_prefix"
  date -Iseconds
) >> "\$log_file" 2>&1 &

printf '%s\n' "\$!" > "\$pid_file"
printf '%s\n' "\$profile_worker_prefix background download started as pid \$(cat "\$pid_file"); log: \$log_file"
WORKER

  log "Starting ${PROFILE_NAME} background download worker in LM Studio container"
  docker exec -d -u ai "$lmstudio_container" sh -lc \
    "nohup ${worker_script} >${worker_nohup} 2>&1 &"
}

wait_replicas() {
  local short_name="$1"
  local expected="$2"
  local timeout_seconds="${3:-900}"
  local svc
  svc="$(service_name "$short_name")"

  local elapsed="0"
  local replicas
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    replicas="$(docker service ls --filter "name=$svc" --format '{{.Replicas}}' | head -n 1)"
    if [ "$replicas" = "$expected" ]; then
      log "$svc replicas ok: $replicas"
      return 0
    fi

    sleep 10
    elapsed="$((elapsed + 10))"
  done

  docker service ps "$svc" --no-trunc || true
  die "$svc did not reach replicas $expected within ${timeout_seconds}s"
}

sync_openwebui_persistent_config() {
  local openwebui_container
  openwebui_container="$(local_service_container openwebui)"
  if [ -z "$openwebui_container" ]; then
    die "Open WebUI task is not running on this node; run this script on ai01"
  fi

  local output
  output="$(
    local -x OPENAI_API_CONFIGS="$OPENWEBUI_OPENAI_API_CONFIGS"
    docker exec -e OPENAI_API_CONFIGS -i "$openwebui_container" python - \
      "$EMBEDDING_MODEL_IDENTIFIER" \
      "$OPENWEBUI_DEFAULT_MODELS" <<'PY'
import json
import os
import sqlite3
import sys
import time

# Passed via -e/environment rather than argv: may contain api_key.
openai_api_configs = os.environ["OPENAI_API_CONFIGS"]
rag_embedding_model = sys.argv[1]
default_models = sys.argv[2]

db_path = "/app/backend/data/webui.db"
now = int(time.time())

def stable_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

def parse_json_object(raw, name):
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise SystemExit(f"{name} must be a JSON object")
    return value

openai_configs = parse_json_object(openai_api_configs, "OPENAI_API_CONFIGS")
openai_base_urls = [
    cfg.get("base_url", "")
    for _, cfg in sorted(openai_configs.items(), key=lambda item: str(item[0]))
    if cfg.get("enable", True) and cfg.get("base_url")
]
openai_api_keys = [
    cfg.get("api_key", "")
    for _, cfg in sorted(openai_configs.items(), key=lambda item: str(item[0]))
    # Same filter as openai_base_urls above (enable AND base_url) - these
    # two lists are parallel, matched by index in Open WebUI, so a
    # mismatched filter here would silently misalign key[i] with the wrong
    # base_url[i] the moment a second config entry is ever added.
    if cfg.get("enable", True) and cfg.get("base_url")
]

desired = {
    "openai.enable": "true",
    "openai.api_configs": stable_json(openai_configs),
    "openai.api_base_urls": stable_json(openai_base_urls),
    "openai.api_keys": stable_json(openai_api_keys),
    "ollama.enable": "false",
    "ollama.base_urls": stable_json([]),
    "ollama.api_configs": stable_json({}),
    "rag.embedding_model": rag_embedding_model,
    "ui.default_models": default_models,
    "task.follow_up.enable": "false",
    "task.query.retrieval.enable": "false",
    "task.query.search.enable": "false",
    "task.tags.enable": "false",
    "task.title.enable": "false",
}

changed = False
with sqlite3.connect(db_path, timeout=30) as con:
    cur = con.cursor()
    cur.execute(
        "create table if not exists config (key varchar(255) primary key, value text not null, updated_at integer not null)"
    )
    for key, value in desired.items():
        row = cur.execute("select value from config where key = ?", (key,)).fetchone()
        if row is None:
            cur.execute(
                "insert into config (key, value, updated_at) values (?, ?, ?)",
                (key, value, now),
            )
            changed = True
        elif row[0] != value:
            cur.execute(
                "update config set value = ?, updated_at = ? where key = ?",
                (value, now, key),
            )
            changed = True
    con.commit()

print("changed=true" if changed else "changed=false")
PY
  )"

  log "Open WebUI persistent config sync: $output"
  if printf '%s\n' "$output" | grep -q 'changed=true'; then
    log "Restarting Open WebUI to pick up persistent config changes"
    docker service update --force --detach=true "$(service_name openwebui)" >/dev/null
    wait_replicas openwebui 1/1 900
  fi
}

apply_profile() {
  require_commands

  resolve_context_policy
  start_download_worker

  update_service_env openwebui \
    "OPENAI_API_CONFIGS=$OPENWEBUI_OPENAI_API_CONFIGS" \
    "OPENAI_API_KEYS=$OPENWEBUI_OPENAI_API_KEYS" \
    "DEFAULT_MODELS=$OPENWEBUI_DEFAULT_MODELS" \
    "RAG_EMBEDDING_MODEL=$EMBEDDING_MODEL_IDENTIFIER"

  wait_replicas openwebui 1/1 900
  sync_openwebui_persistent_config

  update_service_env openclaw-gateway \
    "LMSTUDIO_MODEL=$CHAT_MODEL_SOURCE" \
    "LMSTUDIO_MODEL_IDENTIFIER=$CHAT_MODEL_IDENTIFIER" \
    "LMSTUDIO_CONTEXT_LENGTH=$CHAT_CONTEXT_LENGTH" \
    "OPENCLAW_MAX_TOKENS=$OPENCLAW_MAX_TOKENS" \
    "OPENCLAW_CODEX_EXECUTION_PROFILE=$OPENCLAW_CODEX_EXECUTION_PROFILE" \
    "OPENCLAW_LANCEDB_ENABLED=1" \
    "OPENCLAW_LANCEDB_EMBEDDING_MODEL=$EMBEDDING_MODEL_IDENTIFIER" \
    "OPENCLAW_LANCEDB_EMBEDDING_DIMENSIONS=$EMBEDDING_DIMENSIONS"

  wait_replicas openclaw-gateway 1/1 900

  log "kurkin-family__labs__m01 model profile applied"
}

status_profile() {
  require_commands

  docker stack services "$STACK_NAME" --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'

  local lmstudio_container
  lmstudio_container="$(local_lmstudio_container)"
  if [ -z "$lmstudio_container" ]; then
    log "LM Studio task is not running on this node; run status on ai01"
    return 0
  fi

  log "LM Studio /v1/models:"
  docker exec -u ai "$lmstudio_container" sh -lc \
    'curl -fsS http://127.0.0.1:${LMSTUDIO_PORT:-1234}/v1/models 2>/dev/null | jq -r ".data[]?.id" | sort || true'

  log "LM Studio background download processes:"
  docker exec -u ai "$lmstudio_container" sh -lc \
    'ps -ef | grep -E "kurkin-family__labs__m01-background-download|m01-background-download|ai-stand-background-download|lms get" | grep -v grep || true'

  log "LM Studio background download log tail:"
  docker exec -u ai "$lmstudio_container" sh -lc \
    'tail -n 80 /home/ai/.lmstudio/.internal/kurkin-family__labs__m01-background-download.log 2>/dev/null || tail -n 80 /home/ai/.lmstudio/.internal/m01-background-download.log 2>/dev/null || tail -n 80 /home/ai/.lmstudio/.internal/ai-stand-background-download.log 2>/dev/null || true'
}

verify_profile() {
  require_commands
  load_resolved_context_from_state \
    || die "Resolved context state is missing or invalid: ${PROFILE_CONTEXT_STATE}"

  local svc
  svc="$(service_name lmstudio)"
  [ "$(current_env_value "$svc" LMSTUDIO_MODEL)" = "$CHAT_MODEL_SOURCE" ] \
    || die "LM Studio model env is not $CHAT_MODEL_SOURCE"
  [ "$(current_env_value "$svc" LMSTUDIO_MODEL_IDENTIFIER)" = "$CHAT_MODEL_IDENTIFIER" ] \
    || die "LM Studio identifier env is not $CHAT_MODEL_IDENTIFIER"
  [ "$(current_env_value "$svc" LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER)" = "$CHAT_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER" ] \
    || die "LM Studio forced concrete model env is not $CHAT_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER"
  [ "$(current_env_value "$svc" LMSTUDIO_MODEL_HIDE_VARIANT_FILES)" = "$CHAT_MODEL_HIDE_VARIANT_FILES" ] \
    || die "LM Studio hidden variant env is not $CHAT_MODEL_HIDE_VARIANT_FILES"
  [ "$(current_env_value "$svc" LMSTUDIO_CONTEXT_LENGTH)" = "$CHAT_CONTEXT_LENGTH" ] \
    || die "LM Studio context env is not $CHAT_CONTEXT_LENGTH"
  [ "$(current_env_value "$svc" LMSTUDIO_PARALLEL)" = "$CHAT_PARALLEL" ] \
    || die "LM Studio parallel env is not $CHAT_PARALLEL"
  [ "$(current_env_value "$svc" LMSTUDIO_EMBEDDING_MODEL)" = "$EMBEDDING_MODEL_SOURCE" ] \
    || die "LM Studio embedding model env is not $EMBEDDING_MODEL_SOURCE"
  [ "$(current_env_value "$svc" LMSTUDIO_EMBEDDING_MODEL_KEY)" = "$EMBEDDING_MODEL_KEY" ] \
    || die "LM Studio embedding key env is not $EMBEDDING_MODEL_KEY"
  [ "$(current_env_value "$svc" LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER)" = "$EMBEDDING_MODEL_IDENTIFIER" ] \
    || die "LM Studio embedding identifier env is not $EMBEDDING_MODEL_IDENTIFIER"
  [ "$(current_env_value "$svc" LMSTUDIO_EMBEDDING_CONTEXT_LENGTH)" = "$EMBEDDING_CONTEXT_LENGTH" ] \
    || die "LM Studio embedding context env is not $EMBEDDING_CONTEXT_LENGTH"
  [ "$(current_env_value "$svc" LMSTUDIO_EMBEDDING_DIMENSIONS)" = "$EMBEDDING_DIMENSIONS" ] \
    || die "LM Studio embedding dimensions env is not $EMBEDDING_DIMENSIONS"
  [ "$(current_env_value "$svc" LMSTUDIO_EMBEDDING_GPU)" = "$EMBEDDING_GPU" ] \
    || die "LM Studio embedding GPU env is not $EMBEDDING_GPU"

  svc="$(service_name openwebui)"
  [ "$(current_env_value "$svc" OPENAI_API_CONFIGS)" = "$OPENWEBUI_OPENAI_API_CONFIGS" ] \
    || die "Open WebUI model list does not match m01 profile"
  # Open WebUI's own outbound Authorization bearer comes from this separate
  # flat var, not from OPENAI_API_CONFIGS's embedded api_key (confirmed live
  # 2026-09-11 against its routers/openai.py) - a stale value here 401s every
  # chat request against agentgateway silently, so this must be verified on
  # its own, not assumed to follow from OPENAI_API_CONFIGS matching above.
  [ "$(current_env_value "$svc" OPENAI_API_KEYS)" = "$OPENWEBUI_OPENAI_API_KEYS" ] \
    || die "Open WebUI API key env does not match m01 profile"
  [ "$(current_env_value "$svc" DEFAULT_MODELS)" = "$OPENWEBUI_DEFAULT_MODELS" ] \
    || die "Open WebUI default models env is not $OPENWEBUI_DEFAULT_MODELS"
  [ "$(current_env_value "$svc" RAG_EMBEDDING_MODEL)" = "$EMBEDDING_MODEL_IDENTIFIER" ] \
    || die "Open WebUI RAG embedding model env is not $EMBEDDING_MODEL_IDENTIFIER"

  svc="$(service_name openclaw-gateway)"
  [ "$(current_env_value "$svc" LMSTUDIO_MODEL)" = "$CHAT_MODEL_SOURCE" ] \
    || die "OpenClaw LM Studio model env is not $CHAT_MODEL_SOURCE"
  [ "$(current_env_value "$svc" LMSTUDIO_MODEL_IDENTIFIER)" = "$CHAT_MODEL_IDENTIFIER" ] \
    || die "OpenClaw LM Studio identifier env is not $CHAT_MODEL_IDENTIFIER"
  [ "$(current_env_value "$svc" LMSTUDIO_CONTEXT_LENGTH)" = "$CHAT_CONTEXT_LENGTH" ] \
    || die "OpenClaw LM Studio context env is not $CHAT_CONTEXT_LENGTH"
  [ "$(current_env_value "$svc" OPENCLAW_MAX_TOKENS)" = "$OPENCLAW_MAX_TOKENS" ] \
    || die "OpenClaw max tokens env is not $OPENCLAW_MAX_TOKENS"
  [ "$(current_env_value "$svc" OPENCLAW_CODEX_EXECUTION_PROFILE)" = "$OPENCLAW_CODEX_EXECUTION_PROFILE" ] \
    || die "OpenClaw Codex execution profile is not $OPENCLAW_CODEX_EXECUTION_PROFILE"
  [ "$(current_env_value "$svc" OPENCLAW_LANCEDB_ENABLED)" = "1" ] \
    || die "OpenClaw LanceDB is not enabled"
  [ "$(current_env_value "$svc" OPENCLAW_LANCEDB_EMBEDDING_MODEL)" = "$EMBEDDING_MODEL_IDENTIFIER" ] \
    || die "OpenClaw LanceDB embedding model env is not $EMBEDDING_MODEL_IDENTIFIER"
  [ "$(current_env_value "$svc" OPENCLAW_LANCEDB_EMBEDDING_DIMENSIONS)" = "$EMBEDDING_DIMENSIONS" ] \
    || die "OpenClaw LanceDB dimensions env is not $EMBEDDING_DIMENSIONS"

  wait_replicas lmstudio 1/1 30
  wait_replicas openwebui 1/1 30
  wait_replicas openclaw-gateway 1/1 30

  log "kurkin-family__labs__m01 model profile verify ok"
}

main() {
  local command_name="${1:-}"
  case "$command_name" in
    apply) apply_profile ;;
    status) status_profile ;;
    verify) verify_profile ;;
    -h|--help|help|'') usage ;;
    *) usage >&2; die "Unknown command: $command_name" ;;
  esac
}

main "$@"
