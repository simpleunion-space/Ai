#!/usr/bin/env bash
set -euo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH
INSTALLATION_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck disable=SC1091
. "${INSTALLATION_DIR}/installation.sh"
# The Python helpers below take the installation's storage root from the environment.
export STORAGE_ROOT
CORE_DIR="$(cd -- "${INSTALLATION_DIR}/../.." && pwd)"
STACK_NAME=ai-stand
PROFILE_NAME="$INSTALLATION_NAME"
PROFILE_STATE_DIR="${STORAGE_ROOT}/llamacpp-data/llamacpp01/state/.ai-stand/${PROFILE_NAME}"
PROFILE_CONTEXT_STATE="${PROFILE_STATE_DIR}/context.env"
MODEL_CATALOG_LOCK="${CORE_DIR}/model-catalog/catalog.lock.json"
# Every model value comes from installation.sh. The embedding dimensions are not a profile value: the pinned catalog
# knows them, and load_pinned_model_selection takes them from there.
CHAT_MODEL_SOURCE="$LLAMACPP_CHAT_MODEL_SOURCE"
CHAT_MODEL_IDENTIFIER="$LLAMACPP_CHAT_MODEL_ID"
CHAT_CONTEXT_CANDIDATES=("${LLAMACPP_CHAT_CONTEXT_CANDIDATES[@]}")
CHAT_CONTEXT_LENGTH="$LLAMACPP_CHAT_CONTEXT_LENGTH"
CHAT_PARALLEL="$LLAMACPP_CHAT_PARALLEL"
EMBEDDING_MODEL_IDENTIFIER="$LLAMACPP_EMBEDDING_MODEL_ID"
EMBEDDING_CONTEXT_CANDIDATES=("${LLAMACPP_EMBEDDING_CONTEXT_CANDIDATES[@]}")
EMBEDDING_CONTEXT_LENGTH="$LLAMACPP_EMBEDDING_CONTEXT_LENGTH"
EMBEDDING_DIMENSIONS=""
OPENWEBUI_LOCAL_MODEL_DISPLAY_NAME="$CHAT_MODEL_IDENTIFIER"
OPENCLAW_MAX_TOKENS_DIVISOR="${OPENCLAW_MAX_TOKENS_DIVISOR:-4}"
OPENCLAW_MAX_TOKENS_FLOOR="${OPENCLAW_MAX_TOKENS_FLOOR:-2048}"
OPENCLAW_MAX_TOKENS_CAP="${OPENCLAW_MAX_TOKENS_CAP:-32768}"
CONTEXT_RESOLVE_TIMEOUT_SECONDS="${CONTEXT_RESOLVE_TIMEOUT_SECONDS:-7200}"
AGENTGATEWAY_OPENWEBUI_TOKEN=""
OPENWEBUI_OPENAI_API_CONFIGS=""
OPENWEBUI_OPENAI_API_KEYS=""
OPENWEBUI_DEFAULT_MODELS="$CHAT_MODEL_IDENTIFIER"

log() { printf '%s\n' "[${PROFILE_NAME}-model-profile] $*"; }
die() { printf '%s\n' "[${PROFILE_NAME}-model-profile] ERROR: $*" >&2; exit 1; }
service_name() { printf '%s_%s\n' "$STACK_NAME" "$1"; }
usage() { printf '%s\n' 'Usage: apply-model-profile.sh apply|backend-apply|consumers-apply|consumers-ready|status|verify'; }
is_array_member() { local wanted="$1" value; shift; for value in "$@"; do [ "$value" = "$wanted" ] && return 0; done; return 1; }
openclaw_tokens_for_context() {
  local tokens="$(( $1 / OPENCLAW_MAX_TOKENS_DIVISOR ))"
  [ "$tokens" -ge "$OPENCLAW_MAX_TOKENS_FLOOR" ] || tokens="$OPENCLAW_MAX_TOKENS_FLOOR"
  [ "$tokens" -le "$OPENCLAW_MAX_TOKENS_CAP" ] || tokens="$OPENCLAW_MAX_TOKENS_CAP"
  printf '%s\n' "$tokens"
}
load_pinned_model_selection() {
  local image_version selected
  image_version="$(sed -n 's/^LLAMACPP_IMAGE_VERSION="\([0-9.-]*\)"$/\1/p' "${CORE_DIR}/apply.sh")"
  selected="$(python3 "${CORE_DIR}/model-catalog/selection.py" --catalog "$MODEL_CATALOG_LOCK" \
    --chat-model "$CHAT_MODEL_IDENTIFIER" --embedding-model "$EMBEDDING_MODEL_IDENTIFIER" \
    --chat-gfx "$AI01_ROCM_GFX_VERSION" --embedding-gfx "$AI02_ROCM_GFX_VERSION" \
    --chat-policy-max-context "$LLAMACPP_CHAT_POLICY_MAX_CONTEXT" --image-version "$image_version" --format shell)" || die "Pinned native model selection failed"
  # Output is shell-quoted exclusively by our checked-in read-only selector.
  eval "$selected"
  PROFILE_MODEL_FINGERPRINT="$LLAMACPP_MODEL_CATALOG_FINGERPRINT"
  CHAT_MODEL_PATH="$LLAMACPP_CHAT_MODEL_PATH"
  CHAT_MODEL_SHA256="$LLAMACPP_CHAT_MODEL_SHA256"
  CHAT_PROJECTOR_PATH="$LLAMACPP_CHAT_PROJECTOR_PATH"
  CHAT_PROJECTOR_SHA256="$LLAMACPP_CHAT_PROJECTOR_SHA256"
  EMBEDDING_MODEL_PATH="$LLAMACPP_EMBEDDING_MODEL_PATH"
  EMBEDDING_MODEL_SHA256="$LLAMACPP_EMBEDDING_MODEL_SHA256"
  EMBEDDING_DIMENSIONS="$LLAMACPP_EMBEDDING_DIMENSIONS"
}
require_commands() {
  local command
  for command in docker jq python3 sha256sum; do command -v "$command" >/dev/null || die "$command is required"; done
  load_pinned_model_selection
}
require_model_api_token() {
  AGENTGATEWAY_OPENWEBUI_TOKEN="$(cat "${STORAGE_ROOT}/_secrets/agentgateway-openwebui-token")"
  OPENWEBUI_OPENAI_API_KEYS="$AGENTGATEWAY_OPENWEBUI_TOKEN"
  OPENWEBUI_OPENAI_API_CONFIGS="$(jq -cn --arg id "$CHAT_MODEL_IDENTIFIER" --arg key "$AGENTGATEWAY_OPENWEBUI_TOKEN" \
    '{"0":{enable:true,base_url:"http://agentgateway:4000/v1",api_key:$key,model_ids:[$id]}}')"
}
ensure_service() { docker service inspect "$(service_name "$1")" >/dev/null 2>&1 || die "Missing service: $(service_name "$1")"; }
current_env_value() {
  docker service inspect "$1" | jq -r --arg key "$2" \
    '.[0].Spec.TaskTemplate.ContainerSpec.Env // [] | map(select(startswith($key + "="))) | .[0] // empty | .[(($key | length) + 1):]'
}
has_env_key() { [ -n "$(current_env_value "$1" "$2")" ]; }
update_service_env() {
  local name="$1" kv key desired current changed=false; shift
  ensure_service "$name"
  local svc="$(service_name "$name")"
  local -a args=(--detach=true)
  if [ "$name" = openclaw-gateway ]; then
    local image_version desired_image current_image replicas
    image_version="$(sed -n 's/^OPENCLAW_IMAGE_VERSION="\([0-9.-]*\)"$/\1/p' "${CORE_DIR}/apply.sh")"
    [[ "$image_version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]+$ ]] || die "Pinned consumer image is unavailable"
    desired_image="ghcr.io/kukurusik/ai-stand-openclaw:${image_version}"
    current_image="$(docker service inspect "$svc" | jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Image')"
    if [ "${current_image%%@*}" != "$desired_image" ]; then
      replicas="$(docker service inspect "$svc" | jq -r '.[0].Spec.Mode.Replicated.Replicas')"
      [ "$replicas" = 0 ] || die "A changed consumer image requires stopped consumers and a protected state backup; runtime-only updates do not require index migration"
      args+=(--image "$desired_image" --no-resolve-image)
      changed=true
    fi
  fi
  for kv in "$@"; do
    key="${kv%%=*}"; desired="${kv#*=}"; current="$(current_env_value "$svc" "$key")"
    [ "$current" != "$desired" ] || continue
    args+=(--env-rm "$key" --env-add "$kv"); changed=true
  done
  if [ "$changed" = true ]; then docker service update "${args[@]}" "$svc" >/dev/null; fi
}
local_service_container() {
  docker ps --filter "label=com.docker.swarm.service.name=$(service_name "$1")" --format '{{.ID}}' | head -n 1
}
wait_replicas() {
  local name="$1" expected="$2" timeout="${3:-900}" deadline=$(( $(date +%s) + ${3:-900} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(docker service ls --filter "name=$(service_name "$name")" --format '{{.Replicas}}' | head -n1)" = "$expected" ] && return 0
    sleep 10
  done
  die "$name did not reach expected replicas within ${timeout}s"
}
state_value() { [ -r "$PROFILE_CONTEXT_STATE" ] || return 1; sed -n "s/^$1=//p" "$PROFILE_CONTEXT_STATE" | tail -n1; }
load_resolved_context_from_state() {
  [ "$(stat -c '%u:%a' "$PROFILE_CONTEXT_STATE" 2>/dev/null || true)" = 0:600 ] || return 1
  [ "$(state_value MODEL_FINGERPRINT || true)" = "$PROFILE_MODEL_FINGERPRINT" ] || return 1
  local chat="$(state_value CHAT_CONTEXT_LENGTH || true)" embedding="$(state_value EMBEDDING_CONTEXT_LENGTH || true)"
  is_array_member "$chat" "${CHAT_CONTEXT_CANDIDATES[@]}" || return 1
  is_array_member "$embedding" "${EMBEDDING_CONTEXT_CANDIDATES[@]}" || return 1
  CHAT_IMAGE_ID="$(state_value CHAT_IMAGE_ID || true)"
  EMBEDDING_IMAGE_ID="$(state_value EMBEDDING_IMAGE_ID || true)"
  [[ "$CHAT_IMAGE_ID" =~ ^sha256:[a-f0-9]{64}$ && "$EMBEDDING_IMAGE_ID" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  CHAT_CONTEXT_LENGTH="$chat"; EMBEDDING_CONTEXT_LENGTH="$embedding"
  OPENCLAW_MAX_TOKENS="$(openclaw_tokens_for_context "$CHAT_CONTEXT_LENGTH")"
}
persist_resolved_context_state() {
  [ ! -L "$PROFILE_STATE_DIR" ] && [ ! -L "$PROFILE_CONTEXT_STATE" ] || die "Symlink in protected model state"
  if [ -e "$PROFILE_STATE_DIR" ]; then
    [ "$(stat -c '%u:%a' "$PROFILE_STATE_DIR")" = 0:700 ] || die "Model state must be root-owned 0700"
  else
    mkdir -p "$PROFILE_STATE_DIR"; chmod 0700 "$PROFILE_STATE_DIR"
  fi
  local temporary="$(mktemp "${PROFILE_STATE_DIR}/context.env.XXXXXX")"
  {
    printf 'CHAT_CONTEXT_LENGTH=%s\nEMBEDDING_CONTEXT_LENGTH=%s\n' "$CHAT_CONTEXT_LENGTH" "$EMBEDDING_CONTEXT_LENGTH"
    printf 'MODEL_FINGERPRINT=%s\nCHAT_IMAGE_ID=%s\nEMBEDDING_IMAGE_ID=%s\n' "$PROFILE_MODEL_FINGERPRINT" "$CHAT_IMAGE_ID" "$EMBEDDING_IMAGE_ID"
    printf 'OPENCLAW_MAX_TOKENS=%s\n' "$OPENCLAW_MAX_TOKENS"
  } > "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$PROFILE_CONTEXT_STATE"
}
deploy_native_backends() {
  export LLAMACPP_CHAT_MODEL_ID="$CHAT_MODEL_IDENTIFIER" LLAMACPP_CHAT_MODEL_PATH="$CHAT_MODEL_PATH"
  export LLAMACPP_CHAT_MODEL_SHA256="$CHAT_MODEL_SHA256" LLAMACPP_CHAT_CONTEXT_LENGTH="$CHAT_CONTEXT_LENGTH"
  export LLAMACPP_CHAT_PROJECTOR_PATH="$CHAT_PROJECTOR_PATH" LLAMACPP_CHAT_PROJECTOR_SHA256="$CHAT_PROJECTOR_SHA256"
  export LLAMACPP_EMBEDDING_MODEL_ID="$EMBEDDING_MODEL_IDENTIFIER" LLAMACPP_EMBEDDING_MODEL_PATH="$EMBEDDING_MODEL_PATH"
  export LLAMACPP_EMBEDDING_MODEL_SHA256="$EMBEDDING_MODEL_SHA256" LLAMACPP_EMBEDDING_CONTEXT_LENGTH="$EMBEDDING_CONTEXT_LENGTH"
  export LLAMACPP_EMBEDDING_DIMENSIONS="$EMBEDDING_DIMENSIONS" LLAMACPP_MODEL_CATALOG_FINGERPRINT="$PROFILE_MODEL_FINGERPRINT"
  export LLAMACPP01_APPROVED_IMAGE="$CHAT_IMAGE_ID" LLAMACPP02_APPROVED_IMAGE="$EMBEDDING_IMAGE_ID"
  bash "${CORE_DIR}/apply.sh" deploy-models --installation "$INSTALLATION_NAME" --node-name "$AI01_NODE_NAME" --accelerator amd
  update_service_env agentgateway "AGENTGATEWAY_CHAT_MODEL_ID=$CHAT_MODEL_IDENTIFIER" "AGENTGATEWAY_EMBEDDING_MODEL_ID=$EMBEDDING_MODEL_IDENTIFIER"
  wait_replicas llamacpp01 1/1 "$CONTEXT_RESOLVE_TIMEOUT_SECONDS"
  wait_replicas llamacpp02 1/1 "$CONTEXT_RESOLVE_TIMEOUT_SECONDS"
  wait_native_chat_readiness "$CONTEXT_RESOLVE_TIMEOUT_SECONDS"
  bash "${CORE_DIR}/apply.sh" configure-model-routing --installation "$INSTALLATION_NAME" --node-name "$AI01_NODE_NAME" --accelerator amd
}
wait_native_chat_readiness() {
  # Docker liveness deliberately accepts the loading state. Running replicas
  # are therefore not inference readiness; wait for the exact startup proof
  # under the same app UID that owns its private marker and native process.
  local deadline=$(( $(date +%s) + ${1:-900} )) cid
  while [ "$(date +%s)" -lt "$deadline" ]; do
    cid="$(local_service_container llamacpp01)"
    if [ -n "$cid" ] && docker exec --user 10000:20000 "$cid" /usr/local/bin/llamacpp-healthcheck.sh --ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "Exact native chat startup inference did not become ready"
}
wait_embedding_endpoint() {
  local deadline=$(( $(date +%s) + ${1:-900} )) response payload
  payload="$(jq -cn --arg model "$EMBEDDING_MODEL_IDENTIFIER" '{model:$model,input:"ai-stand embedding health check"}')"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if response="$(curl --fail --silent --max-time 300 --header "Authorization: Bearer ${AGENTGATEWAY_OPENWEBUI_TOKEN}" \
      --header 'Content-Type: application/json' --data "$payload" http://127.0.0.1:4000/v1/embeddings 2>/dev/null)" \
      && printf '%s' "$response" | jq -e --argjson n "$EMBEDDING_DIMENSIONS" '.data[0].embedding | type=="array" and length==$n' >/dev/null; then return 0; fi
    sleep 10
  done
  die "Exact embedding endpoint did not pass real inference"
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
      "$OPENWEBUI_DEFAULT_MODELS" \
      "$CHAT_MODEL_IDENTIFIER" \
      "$OPENWEBUI_LOCAL_MODEL_DISPLAY_NAME" <<'PY'
import json
import os
import sqlite3
import sys
import time

# Passed via -e/environment rather than argv: may contain api_key.
openai_api_configs = os.environ["OPENAI_API_CONFIGS"]
rag_embedding_model = sys.argv[1]
default_models = sys.argv[2]
local_model_id = sys.argv[3]
local_model_display_name = sys.argv[4]

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
if not all((local_model_id, local_model_display_name)):
    raise SystemExit("Open WebUI model ids and display names must not be empty")
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

    # Native model rows and read ACLs belong to model_access.py. In
    # particular, never reset their verified administrator owner to NULL.
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
  # The recurring run belongs to the controller container; this writes the configuration it reads and applies once now.
  python3 "${CORE_DIR}/docker/openwebui/model_access_snapshot.py" --install-config --authentik-address "https://${AUTHENTIK_HOST}"
  python3 "${CORE_DIR}/docker/openwebui/model_access_snapshot.py" --apply
}

check_openwebui_model_display_names() {
  # Native ownership and ACL validation also preserves operator aliases.
  # A read-only plan must be idempotent after the profile was applied.
  python3 "${CORE_DIR}/docker/openwebui/model_access_snapshot.py" \
    | jq -e '.schemaVersion == 1 and .mode == "plan" and .changed == false' >/dev/null \
    || die "Open WebUI native model access requires reconciliation"
}


prepare_backend_state() {
  require_commands
  if [ -n "${MODEL_MIGRATION_APPROVED_CHAT_CONTEXT:-}" ]; then
    is_array_member "$MODEL_MIGRATION_APPROVED_CHAT_CONTEXT" "${CHAT_CONTEXT_CANDIDATES[@]}" || die "Untested chat context"
    CHAT_CONTEXT_LENGTH="$MODEL_MIGRATION_APPROVED_CHAT_CONTEXT"
    CHAT_IMAGE_ID="${MODEL_MIGRATION_CHAT_IMAGE_ID:-}"
    EMBEDDING_IMAGE_ID="${MODEL_MIGRATION_EMBEDDING_IMAGE_ID:-}"
    [[ "$CHAT_IMAGE_ID" =~ ^sha256:[a-f0-9]{64}$ && "$EMBEDDING_IMAGE_ID" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Passed immutable candidate images are required"
    OPENCLAW_MAX_TOKENS="$(openclaw_tokens_for_context "$CHAT_CONTEXT_LENGTH")"
    persist_resolved_context_state
  else
    load_resolved_context_from_state || die "Passed model context/images are required before activation"
  fi
}
apply_backend_profile() {
  prepare_backend_state
  require_model_api_token
  deploy_native_backends
  wait_embedding_endpoint "$CONTEXT_RESOLVE_TIMEOUT_SECONDS"
}
apply_consumers_profile() {
  require_commands
  require_model_api_token
  load_resolved_context_from_state || die "Model context/fingerprint state is not ready"
  [[ "${MODEL_MIGRATION_GENERATION:-}" =~ ^[a-f0-9]{64}$ ]] || die "consumers-apply requires an index migration generation"
  [ "$MODEL_MIGRATION_GENERATION" = "$PROFILE_MODEL_FINGERPRINT" ] || die "Migration generation does not match selected candidate"
  local lancedb_path="/home/ai/.openclaw/memory/lancedb-${MODEL_MIGRATION_GENERATION:0:16}"
  update_service_env openwebui \
    "OPENAI_API_CONFIGS=$OPENWEBUI_OPENAI_API_CONFIGS" "OPENAI_API_KEYS=$OPENWEBUI_OPENAI_API_KEYS" \
    "DEFAULT_MODELS=$OPENWEBUI_DEFAULT_MODELS" "RAG_EMBEDDING_MODEL=$EMBEDDING_MODEL_IDENTIFIER" \
    "RAG_OPENAI_API_BASE_URL=http://agentgateway:4000/v1" "RAG_OPENAI_API_KEY=$AGENTGATEWAY_OPENWEBUI_TOKEN"
  update_service_env openclaw-gateway \
    "OPENCLAW_CHAT_MODEL_SOURCE=$CHAT_MODEL_SOURCE" "OPENCLAW_CHAT_MODEL_ID=$CHAT_MODEL_IDENTIFIER" \
    "OPENCLAW_CHAT_CONTEXT_LENGTH=$CHAT_CONTEXT_LENGTH" "OPENCLAW_AGENTGATEWAY_BASE_URL=http://agentgateway:4000/v1" \
    "OPENCLAW_MAX_TOKENS=$OPENCLAW_MAX_TOKENS" "OPENCLAW_CODEX_EXECUTION_PROFILE=$OPENCLAW_CODEX_EXECUTION_PROFILE" \
    "OPENCLAW_LANCEDB_ENABLED=1" "OPENCLAW_LANCEDB_DB_PATH=$lancedb_path" \
    "OPENCLAW_LANCEDB_EMBEDDING_MODEL=$EMBEDDING_MODEL_IDENTIFIER" "OPENCLAW_LANCEDB_EMBEDDING_DIMENSIONS=$EMBEDDING_DIMENSIONS"
}
consumers_ready() {
  require_commands
  require_model_api_token
  local webui="${MODEL_MIGRATION_OPENWEBUI_REPLICAS:-1}" gateway="${MODEL_MIGRATION_OPENCLAW_REPLICAS:-1}"
  case "$webui:$gateway" in 0:0|0:1|1:0|1:1) ;; *) die "Invalid consumer replicas" ;; esac
  wait_replicas openwebui "$webui/$webui" 900
  [ "$webui" = 0 ] || sync_openwebui_persistent_config
  wait_replicas openclaw-gateway "$gateway/$gateway" 900
}
apply_profile() {
  require_commands
  python3 "${CORE_DIR}/model-migration/migrate.py" --installation "$INSTALLATION_NAME" \
    --apply-script "${INSTALLATION_DIR}/apply-model-profile.sh" --backend-url http://127.0.0.1:4000/v1 \
    --token-file "${STORAGE_ROOT}/_secrets/agentgateway-openwebui-token" --model "$EMBEDDING_MODEL_IDENTIFIER" \
    --dimensions "$EMBEDDING_DIMENSIONS" --generation "$PROFILE_MODEL_FINGERPRINT"
}
status_profile() {
  require_commands
  docker stack services "$STACK_NAME" --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'
}
verify_profile() {
  require_commands
  require_model_api_token
  load_resolved_context_from_state || die "Protected model generation is missing"
  local role svc image expected
  for role in chat embedding; do
    if [ "$role" = chat ]; then svc="$(service_name llamacpp01)"; image="$CHAT_IMAGE_ID"; expected="$CHAT_MODEL_SHA256"; else svc="$(service_name llamacpp02)"; image="$EMBEDDING_IMAGE_ID"; expected="$EMBEDDING_MODEL_SHA256"; fi
    [ "$(docker service inspect "$svc" | jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Image')" = "$image" ] || die "Backend image differs from passed canary"
    [ "$(current_env_value "$svc" LLAMACPP_MODEL_SHA256)" = "$expected" ] || die "Backend weight checksum differs"
    [ "$(current_env_value "$svc" LLAMACPP_REQUIRE_GPU)" = 1 ] || die "ROCm-only contract is absent"
    [ "$(current_env_value "$svc" LLAMACPP_MODEL_CATALOG_FINGERPRINT)" = "$PROFILE_MODEL_FINGERPRINT" ] || die "Backend generation differs"
  done
  [ "$(current_env_value "$(service_name openclaw-gateway)" OPENCLAW_LANCEDB_DB_PATH)" = "/home/ai/.openclaw/memory/lancedb-${PROFILE_MODEL_FINGERPRINT:0:16}" ] || die "LanceDB generation differs"
  wait_embedding_endpoint 300
  check_openwebui_model_display_names
}
main() {
  case "${1:-}" in
    apply) apply_profile ;; prepare-backend-state) prepare_backend_state ;; backend-apply) apply_backend_profile ;;
    consumers-apply) apply_consumers_profile ;; consumers-ready) consumers_ready ;;
    status) status_profile ;; verify) verify_profile ;;
    -h|--help|help|'') usage ;; *) die "Unknown command: $1" ;;
  esac
}
main "$@"
