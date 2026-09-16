#!/bin/sh

set -eu

LMSTUDIO_SEED_HOME="${LMSTUDIO_SEED_HOME:-/opt/lmstudio-seed}"
LMSTUDIO_RUNTIME_MANIFEST="${LMSTUDIO_RUNTIME_MANIFEST:?LMSTUDIO_RUNTIME_MANIFEST is required}"
LMSTUDIO_RUNTIME_ID="${LMSTUDIO_RUNTIME_ID:?LMSTUDIO_RUNTIME_ID is required}"
LMSTUDIO_GPU="${LMSTUDIO_GPU:?LMSTUDIO_GPU is required}"
LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
LMSTUDIO_MODEL="${LMSTUDIO_MODEL:?LMSTUDIO_MODEL is required}"
LMSTUDIO_MODEL_KEY="${LMSTUDIO_MODEL%%@*}"
LMSTUDIO_MODEL_LOAD_SPEC="${LMSTUDIO_MODEL_LOAD_SPEC:-$LMSTUDIO_MODEL_KEY}"
LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER="${LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER:-}"
LMSTUDIO_MODEL_HIDE_VARIANT_FILES="${LMSTUDIO_MODEL_HIDE_VARIANT_FILES:-}"
LMSTUDIO_MODEL_IDENTIFIER="${LMSTUDIO_MODEL_IDENTIFIER:?LMSTUDIO_MODEL_IDENTIFIER is required}"
LMSTUDIO_CONTEXT_LENGTH="${LMSTUDIO_CONTEXT_LENGTH:?LMSTUDIO_CONTEXT_LENGTH is required}"
LMSTUDIO_PARALLEL="${LMSTUDIO_PARALLEL:-1}"
LMSTUDIO_EMBEDDING_MODEL="${LMSTUDIO_EMBEDDING_MODEL:-}"
LMSTUDIO_EMBEDDING_MODEL_KEY="${LMSTUDIO_EMBEDDING_MODEL_KEY:-${LMSTUDIO_EMBEDDING_MODEL%%@*}}"
LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER="${LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER:-}"
LMSTUDIO_EMBEDDING_CONTEXT_LENGTH="${LMSTUDIO_EMBEDDING_CONTEXT_LENGTH:-8192}"
LMSTUDIO_EMBEDDING_GPU="${LMSTUDIO_EMBEDDING_GPU:-off}"
LMSTUDIO_DOWNLOAD_POLL_SECONDS="${LMSTUDIO_DOWNLOAD_POLL_SECONDS:-30}"
LMSTUDIO_DOWNLOAD_STALE_POLLS="${LMSTUDIO_DOWNLOAD_STALE_POLLS:-4}"
LMSTUDIO_DOWNLOAD_FAILED_POLLS="${LMSTUDIO_DOWNLOAD_FAILED_POLLS:-10}"
LMSTUDIO_DIRECT_DOWNLOAD_TIMEOUT_SECONDS="${LMSTUDIO_DIRECT_DOWNLOAD_TIMEOUT_SECONDS:-3600}"
LMSTUDIO_LOAD_WAIT_SECONDS="${LMSTUDIO_LOAD_WAIT_SECONDS:-3600}"
LMSTUDIO_LOAD_POLL_SECONDS="${LMSTUDIO_LOAD_POLL_SECONDS:-10}"
LMSTUDIO_BACKGROUND_DOWNLOAD_MIN_FREE_GB="${LMSTUDIO_BACKGROUND_DOWNLOAD_MIN_FREE_GB:-20}"
# Safety net for LM Studio's own on-demand ("JIT") model loading, triggered
# when an API caller (e.g. OpenClaw continuing a session pinned to a model
# name from before the last model-apply switch) requests a model this
# script isn't currently managing. Without this, such a model loads
# alongside whatever this script already loaded and never unloads/expires
# (2026-09-06 incident: a stale OpenClaw session JIT-reloaded the previous
# chat model after a model-apply switch, stacking two ~30-40GB models in
# the same unified memory pool and triggering a kernel OOM). Scoped to
# JIT-loaded models only - the chat/embedding models this script manages
# are always loaded explicitly via `lms load --identifier`, never via JIT.
# NOTE: confirmed live that unloadPreviousJITModelOnLoad only replaces a
# repeat JIT load of the SAME model - it does not evict a DIFFERENT
# already-JIT-loaded model, so this TTL is the real backstop for the
# two-large-models-at-once case; see modelLoadingGuardrails below for the
# guard against the OOM itself.
LMSTUDIO_JIT_TTL_SECONDS="${LMSTUDIO_JIT_TTL_SECONDS:-1800}"

LMS_BIN="$HOME/.lmstudio/bin/lms"
MODEL_MARKER="$HOME/.lmstudio-container-model"
EMBEDDING_MODEL_MARKER="$HOME/.lmstudio-container-embedding-model"
DOWNLOAD_JOBS_FILE="$HOME/.lmstudio/.internal/download-jobs-info.json"
MODEL_INDEX_CACHE_FILE="$HOME/.lmstudio/.internal/model-index-cache.json"
DOWNLOAD_LOG="$HOME/.lmstudio/.internal/bootstrap-download.log"
API_BASE_URL="http://127.0.0.1:$LMSTUDIO_PORT"
DOWNLOAD_RETRY_SECONDS="${LMSTUDIO_DOWNLOAD_RETRY_SECONDS:-120}"
DAEMON_UP_LOG="$HOME/.lmstudio/.internal/daemon-up.log"
DAEMON_UP_PID=''
LMSTUDIO_BACKGROUND_DOWNLOADS="${LMSTUDIO_BACKGROUND_DOWNLOADS:-}"
BACKGROUND_DOWNLOAD_LOG="$HOME/.lmstudio/.internal/ai-stand-background-download.log"
BACKGROUND_DOWNLOAD_PID_FILE="$HOME/.lmstudio/.internal/ai-stand-background-download.pid"
HIDDEN_VARIANTS_DIR="$HOME/.lmstudio/.internal/ai-stand-hidden-variants"

log() {
    printf '%s\n' "[lmstudio] $*"
}

sync_image_payload() {
    if [ ! -d "$LMSTUDIO_SEED_HOME/.lmstudio" ]; then
        log "LM Studio seed is missing from $LMSTUDIO_SEED_HOME"
        exit 1
    fi

    mkdir -p "$HOME/.lmstudio"

    # Add versioned image payload without replacing mutable user state or models.
    rsync --archive --ignore-existing "$LMSTUDIO_SEED_HOME/" "$HOME/"

    # CLI and daemon payload are image-owned and must follow image updates.
    # Otherwise a persisted old lms binary can talk to a newer llmster daemon
    # with a mismatching passkey protocol.
    if [ -d "$LMSTUDIO_SEED_HOME/.lmstudio/bin" ]; then
        mkdir -p "$HOME/.lmstudio/bin"
        rsync --archive --delete \
            "$LMSTUDIO_SEED_HOME/.lmstudio/bin/" \
            "$HOME/.lmstudio/bin/"
    fi

    if [ -d "$LMSTUDIO_SEED_HOME/.lmstudio/llmster" ]; then
        mkdir -p "$HOME/.lmstudio/llmster"
        rsync --archive --delete \
            "$LMSTUDIO_SEED_HOME/.lmstudio/llmster/" \
            "$HOME/.lmstudio/llmster/"
    fi

    if [ -d "$LMSTUDIO_SEED_HOME/.lmstudio/extensions/backends" ]; then
        mkdir -p "$HOME/.lmstudio/extensions/backends"
        rsync --archive \
            "$LMSTUDIO_SEED_HOME/.lmstudio/extensions/backends/" \
            "$HOME/.lmstudio/extensions/backends/"
    fi

    if [ -d "$LMSTUDIO_SEED_HOME/.cache/lm-studio" ]; then
        mkdir -p "$HOME/.cache/lm-studio"
        rsync --archive \
            "$LMSTUDIO_SEED_HOME/.cache/lm-studio/" \
            "$HOME/.cache/lm-studio/"
    fi
}

configure_runtime_home() {
    lmstudio_home="$HOME/.lmstudio"
    internal_dir="$lmstudio_home/.internal"
    install_location="$internal_dir/llmster-install-location.json"
    settings_file="$lmstudio_home/settings.json"

    mkdir -p "$internal_dir" "$lmstudio_home/models"

    # The headless installer runs under LMSTUDIO_SEED_HOME while the image is
    # built. Never let its absolute build-time home escape into the writable
    # runtime home copied from the image.
    printf '%s\n' "$lmstudio_home" > "$HOME/.lmstudio-home-pointer"

    llmster_binary="$(
        find "$lmstudio_home/llmster" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name llmster \
            -print 2>/dev/null \
            | sort -V \
            | tail -n 1
    )"

    if [ -z "$llmster_binary" ]; then
        llmster_binary="$(
            find "$LMSTUDIO_SEED_HOME/.lmstudio/llmster" \
                -mindepth 2 \
                -maxdepth 2 \
                -type f \
                -name llmster \
                -print 2>/dev/null \
                | sort -V \
                | tail -n 1
        )"
    fi

    if [ -z "$llmster_binary" ]; then
        log "llmster was not found in $LMSTUDIO_SEED_HOME/.lmstudio/llmster or $lmstudio_home/llmster"
        exit 1
    fi

    install_location_tmp="$(mktemp "$internal_dir/.llmster-install-location.XXXXXX")"
    if [ -f "$install_location" ]; then
        jq \
            --arg path "$llmster_binary" \
            --arg cwd "${llmster_binary%/*}" \
            '.path = $path | .cwd = $cwd' \
            "$install_location" > "$install_location_tmp"
    else
        jq \
            --null-input \
            --arg path "$llmster_binary" \
            --arg cwd "${llmster_binary%/*}" \
            '{path: $path, argv: [], cwd: $cwd}' > "$install_location_tmp"
    fi
    mv "$install_location_tmp" "$install_location"

    if [ -f "$settings_file" ]; then
        settings_tmp="$(mktemp "$lmstudio_home/.settings.XXXXXX")"
        # customThresholdBytes/alwaysAllowLoadAnyway must stay a full bypass
        # (1TB threshold, always-allow): this script's own non-interactive
        # `lms load --yes` (see load_model_with_retry()) does NOT bypass this
        # guardrail on its own - tested live 2026-09-06 with
        # alwaysAllowLoadAnyway=false at a 50GiB threshold, expecting it to
        # only block a stray second/JIT load, and instead it outright
        # rejected the single, already-working, correctly-configured primary
        # model too ("this model requires approximately 76.69 GB of memory"
        # for qwen3.8-27b @ 262144 context alone - LM Studio's own estimate,
        # comfortably above any threshold that would still catch a second
        # large model), crash-looping the lmstudio service. The guardrail
        # appears to be a flat per-model-size check, not aware of what else
        # is already loaded, so no static threshold here can distinguish
        # "one big model" from "a second big model on top" - it can only
        # protect this deployment by also blocking normal operation. Do not
        # re-attempt this without a materially different mechanism; rely on
        # LMSTUDIO_JIT_TTL_SECONDS above as the actual backstop instead.
        jq \
            --arg downloads_folder "$lmstudio_home/models" \
            --argjson context_length "$LMSTUDIO_CONTEXT_LENGTH" \
            --argjson jit_ttl_seconds "$LMSTUDIO_JIT_TTL_SECONDS" \
            '
              .downloadsFolder = $downloads_folder
              | .modelLoadingGuardrails = (.modelLoadingGuardrails // {})
              | .modelLoadingGuardrails.mode = "custom"
              | .modelLoadingGuardrails.customThresholdBytes = 1099511627776
              | .modelLoadingGuardrails.alwaysAllowLoadAnyway = true
              | .defaultContextLength = {"type": "custom", "value": $context_length}
              | .chat = (.chat // {})
              | .chat.unloadPreviousModelOnSelect = false
              | .developer = (.developer // {})
              | .developer.unloadPreviousJITModelOnLoad = true
              | .developer.jitModelTTL = {"enabled": true, "ttlSeconds": $jit_ttl_seconds}
            ' \
            "$settings_file" > "$settings_tmp"
        mv "$settings_tmp" "$settings_file"
    else
        settings_tmp="$(mktemp "$lmstudio_home/.settings.XXXXXX")"
        jq \
            --null-input \
            --arg downloads_folder "$lmstudio_home/models" \
            --argjson context_length "$LMSTUDIO_CONTEXT_LENGTH" \
            --argjson jit_ttl_seconds "$LMSTUDIO_JIT_TTL_SECONDS" \
            '
              {
                downloadsFolder: $downloads_folder,
                defaultContextLength: {
                  type: "custom",
                  value: $context_length
                },
                chat: {
                  unloadPreviousModelOnSelect: false
                },
                developer: {
                  unloadPreviousJITModelOnLoad: true,
                  jitModelTTL: {
                    enabled: true,
                    ttlSeconds: $jit_ttl_seconds
                  }
                },
                modelLoadingGuardrails: {
                  mode: "custom",
                  customThresholdBytes: 1099511627776,
                  alwaysAllowLoadAnyway: true
                }
              }
            ' \
            > "$settings_tmp"
        mv "$settings_tmp" "$settings_file"
    fi

    # A container cannot inherit a live daemon from the previous container;
    # a persisted lock is therefore always stale at this point.
    rm -f \
        "$internal_dir/http-server.json" \
        "$internal_dir/llmster-pid.lock" \
        "$internal_dir/lms-key-2" \
        "$internal_dir/local-identity.json"
}

stop_lmstudio() {
    exit_code="${1:-0}"
    trap - INT TERM
    log 'Stopping LM Studio server and daemon'
    "$LMS_BIN" server stop >/dev/null 2>&1 || true
    if [ -n "$DAEMON_UP_PID" ] && kill -0 "$DAEMON_UP_PID" 2>/dev/null; then
        kill "$DAEMON_UP_PID" 2>/dev/null || true
        wait "$DAEMON_UP_PID" 2>/dev/null || true
    fi
    "$LMS_BIN" daemon down >/dev/null 2>&1 || true
    exit "$exit_code"
}

start_lmstudio_daemon() {
    daemon_attempt=1
    while [ "$daemon_attempt" -le 3 ]; do
        mkdir -p "${DAEMON_UP_LOG%/*}"
        rm -f "$HOME/.lmstudio/.internal/llmster-pid.lock"
        : > "$DAEMON_UP_LOG"

        log "Starting llmster daemon (attempt $daemon_attempt/3)"
        NO_COLOR=1 "$LMS_BIN" daemon up --json > "$DAEMON_UP_LOG" 2>&1 &
        DAEMON_UP_PID="$!"

        elapsed=0
        while [ "$elapsed" -lt 120 ]; do
            daemon_status_json="$(
                NO_COLOR=1 "$LMS_BIN" daemon status --json 2>/dev/null || true
            )"
            if printf '%s' "$daemon_status_json" | jq -e '.status == "running"' >/dev/null 2>&1; then
                log 'llmster daemon is ready'
                return 0
            fi

            if [ -n "$DAEMON_UP_PID" ] && ! kill -0 "$DAEMON_UP_PID" 2>/dev/null; then
                wait "$DAEMON_UP_PID" 2>/dev/null || true
                DAEMON_UP_PID=''
            fi

            sleep 1
            elapsed=$((elapsed + 1))
        done

        log "llmster daemon did not become ready on attempt $daemon_attempt; see $DAEMON_UP_LOG"
        if [ -n "$DAEMON_UP_PID" ] && kill -0 "$DAEMON_UP_PID" 2>/dev/null; then
            kill "$DAEMON_UP_PID" 2>/dev/null || true
            wait "$DAEMON_UP_PID" 2>/dev/null || true
        fi
        DAEMON_UP_PID=''
        "$LMS_BIN" daemon down >/dev/null 2>&1 || true

        daemon_attempt=$((daemon_attempt + 1))
        if [ "$daemon_attempt" -le 3 ]; then
            sleep 5
        fi
    done

    log "llmster daemon failed to start; last output follows"
    sed 's/^/[lmstudio-daemon] /' "$DAEMON_UP_LOG" >&2 || true
    exit 1
}

install_llama_server_wrapper() {
    extra_args="${LMSTUDIO_LLAMA_SERVER_EXTRA_ARGS:-}"
    if [ -z "$extra_args" ]; then
        return 0
    fi

    backends_dir="$HOME/.lmstudio/extensions/backends"
    if [ ! -d "$backends_dir" ]; then
        log "Backend wrapper requested, but backends directory is missing: $backends_dir"
        exit 1
    fi

    runtime_dir=''
    for candidate in "$backends_dir"/"$LMSTUDIO_RUNTIME_ID"-*; do
        if [ -d "$candidate" ] && [ -x "$candidate/llama-server" ]; then
            runtime_dir="$candidate"
            break
        fi
    done

    if [ -z "$runtime_dir" ]; then
        log "Backend wrapper requested, but llama-server was not found for runtime $LMSTUDIO_RUNTIME_ID"
        exit 1
    fi

    server="$runtime_dir/llama-server"
    real_server="$runtime_dir/llama-server.real"

    if [ -x "$server" ] && ! grep -q 'AI_STAND_LLAMA_SERVER_WRAPPER' "$server" 2>/dev/null; then
        cp "$server" "$real_server"
        chmod 0755 "$real_server"
    fi

    if [ ! -x "$real_server" ]; then
        log "Backend wrapper requested, but real llama-server is missing: $real_server"
        exit 1
    fi

    cat > "$server" <<'WRAPPER'
#!/bin/bash
# AI_STAND_LLAMA_SERVER_WRAPPER
set -euo pipefail

real_server="$0.real"
extra_args="${LMSTUDIO_LLAMA_SERVER_EXTRA_ARGS:-}"
strip_args="${LMSTUDIO_LLAMA_SERVER_STRIP_ARGS:---flash-attn --batch-size --ubatch-size}"

if [ ! -x "$real_server" ]; then
    printf '%s\n' "ai-stand llama-server wrapper: missing real backend: $real_server" >&2
    exit 127
fi

if [ -z "$extra_args" ]; then
    exec "$real_server" "$@"
fi

should_strip_arg() {
    local needle="$1"
    local strip_arg

    for strip_arg in $strip_args; do
        if [ "$strip_arg" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

args=()
while [ "$#" -gt 0 ]; do
    if should_strip_arg "$1"; then
        shift
        if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
            shift
        fi
        continue
    fi

    args+=("$1")
    shift
done

# Intentionally split extra_args as shell words. Keep values simple in
# compose.yaml, e.g. "--no-mmap --no-repack --batch-size 512".
# shellcheck disable=SC2206
extra_words=($extra_args)
args+=("${extra_words[@]}")

exec "$real_server" "${args[@]}"
WRAPPER
    chmod 0755 "$server"
    log "Installed llama-server wrapper for $runtime_dir with extra args: $extra_args"
}

find_model_download_job() {
    active_model_key="${1:?model key is required}"
    # Optional: full "publisher/model@quant" spec. jobName in the jobs file
    # is keyed by the base model only, with no quant info of its own, so a
    # model with several quants downloaded (or downloading) in parallel has
    # multiple jobs sharing one jobName; without this, `last` can pick a
    # job for the wrong quant entirely (e.g. a still-downloading Q4_K_M job
    # instead of the already-completed Q8_0 one actually requested).
    active_model_full="${2:-}"

    if [ ! -r "$DOWNLOAD_JOBS_FILE" ]; then
        return 0
    fi

    quant_pattern=""
    case "$active_model_full" in
        *@*) quant_pattern="$(printf '%s' "${active_model_full#*@}" | tr '[:lower:]' '[:upper:]')" ;;
    esac

    jq --raw-output \
        --arg model "$active_model_key" \
        --arg quant "$quant_pattern" \
        '[.jobs[]? | select(
            .jobName == $model
            and (
                ($quant | length) == 0
                or ([.tasks[]?.request.savePath // ""] | any(contains($quant)))
            )
          )] | last | .shortHashJobId // empty' \
        "$DOWNLOAD_JOBS_FILE" 2>/dev/null || true
}

request_model_download() {
    active_model="${1:?model is required}"

    log "Requesting model download/resume for $active_model"
    timeout 120s "$LMS_BIN" get "$active_model" >> "$DOWNLOAD_LOG" 2>&1 || true
}

is_direct_model_url() {
    case "$1" in
        http://*|https://*) return 0 ;;
        *) return 1 ;;
    esac
}

download_direct_model_url() {
    active_model="${1:?model is required}"
    attempt=1
    max_attempts=5

    while [ "$attempt" -le "$max_attempts" ]; do
        log "Downloading direct model URL for $active_model (attempt $attempt/$max_attempts)"
        if timeout "$LMSTUDIO_DIRECT_DOWNLOAD_TIMEOUT_SECONDS"s \
            "$LMS_BIN" get "$active_model" --gguf --yes > "$DOWNLOAD_LOG" 2>&1; then
            log "Direct model URL download completed for $active_model"
            return 0
        fi

        log "Direct model URL download did not complete on attempt $attempt; last output follows"
        tail -n 80 "$DOWNLOAD_LOG" || true
        retry_delay=$((attempt * 30))
        sleep "$retry_delay" &
        wait "$!"
        attempt=$((attempt + 1))
    done

    log "Direct model URL download failed after $max_attempts attempts: $active_model"
    return 1
}

wait_for_model_download() {
    active_model="${1:?model is required}"

    if is_direct_model_url "$active_model"; then
        download_direct_model_url "$active_model"
        return "$?"
    fi

    active_model_key="${active_model%%@*}"
    job_id="$(find_model_download_job "$active_model_key" "$active_model")"

    if [ -z "$job_id" ]; then
        log "Starting model download for $active_model; this can take a long time"

        # lms may return a timeout while llmster continues the resumable job.
        # Keep its verbose progress outside the service log, then follow the
        # official status endpoint below.
        if timeout 120s "$LMS_BIN" get "$active_model" > "$DOWNLOAD_LOG" 2>&1; then
            log "Model download command completed for $active_model"
            return 0
        fi

        job_id="$(find_model_download_job "$active_model_key" "$active_model")"
        if [ -z "$job_id" ]; then
            log "Model download did not create a resumable job; see $DOWNLOAD_LOG"
            return 1
        fi
    else
        log "Resuming model download job $job_id for $active_model"
    fi

    poll_count=0
    status_failures=0
    failed_polls=0
    stale_polls=0
    last_downloaded_bytes=0
    while :; do
        response="$(
            curl \
                --connect-timeout 5 \
                --max-time 15 \
                --silent \
                --show-error \
                "$API_BASE_URL/api/v1/models/download/status/$job_id" \
                2>/dev/null || true
        )"
        status="$(printf '%s' "$response" | jq --raw-output '.status // empty' 2>/dev/null || true)"

        case "$status" in
            completed|already_downloaded)
                log "Model download job $job_id completed"
                return 0
                ;;
            failed)
                error_message="$(printf '%s' "$response" | jq --raw-output '.error.message // .message // "unknown error"' 2>/dev/null || true)"
                downloaded_bytes="$(printf '%s' "$response" | jq --raw-output '.downloaded_bytes // 0' 2>/dev/null || printf '0')"
                if [ "$downloaded_bytes" -gt 0 ] || [ "$last_downloaded_bytes" -gt 0 ] || [ "$error_message" = "unknown error" ]; then
                    failed_polls=$((failed_polls + 1))
                    log "Download $job_id returned failed ($failed_polls/$LMSTUDIO_DOWNLOAD_FAILED_POLLS): $error_message; keeping service alive and retrying"
                    if [ "$failed_polls" -ge "$LMSTUDIO_DOWNLOAD_FAILED_POLLS" ]; then
                        log "Download $job_id failed $failed_polls times in a row; giving up"
                        return 1
                    fi
                    request_model_download "$active_model"
                    job_id="$(find_model_download_job "$active_model_key" "$active_model")"
                    if [ -z "$job_id" ]; then
                        log "Model download retry did not leave a resumable job; see $DOWNLOAD_LOG"
                        return 1
                    fi
                    sleep "$DOWNLOAD_RETRY_SECONDS" &
                    wait "$!"
                    continue
                fi

                failed_polls=$((failed_polls + 1))
                log "Model download job $job_id failed without progress ($failed_polls/$LMSTUDIO_DOWNLOAD_FAILED_POLLS): $error_message"
                if [ "$failed_polls" -ge "$LMSTUDIO_DOWNLOAD_FAILED_POLLS" ]; then
                    log "Download $job_id failed $failed_polls times in a row; giving up"
                    return 1
                fi
                request_model_download "$active_model"
                job_id="$(find_model_download_job "$active_model_key" "$active_model")"
                if [ -z "$job_id" ]; then
                    return 1
                fi
                # Same DOWNLOAD_RETRY_SECONDS backoff as the sibling branch
                # above, not the short LMSTUDIO_DOWNLOAD_POLL_SECONDS this
                # would otherwise fall through to at the bottom of the loop -
                # this is also a failure case (just without progress and with
                # a specific message), not the steady-state polling the short
                # interval is for.
                sleep "$DOWNLOAD_RETRY_SECONDS" &
                wait "$!"
                continue
                ;;
            nonResumableFailure|non_resumable_failure|canceled|cancelled)
                # LM Studio can surface an otherwise retryable artifact failure
                # under a non-resumable task status, for example after rejecting
                # a stale/corrupt partial file at 100%. Keep the service alive
                # and ask lms to create a fresh/resumed job instead of letting
                # the container fall into a restart loop.
                failed_polls=$((failed_polls + 1))
                error_message="$(printf '%s' "$response" | jq --raw-output '.error.message // .message // "unknown error"' 2>/dev/null || true)"
                log "Download job $job_id reported $status ($failed_polls/$LMSTUDIO_DOWNLOAD_FAILED_POLLS): $error_message; retrying through lms get"
                if [ "$failed_polls" -ge "$LMSTUDIO_DOWNLOAD_FAILED_POLLS" ]; then
                    log "Download $job_id failed $failed_polls times in a row; giving up"
                    return 1
                fi
                request_model_download "$active_model"
                job_id="$(find_model_download_job "$active_model_key" "$active_model")"
                if [ -z "$job_id" ]; then
                    log "Model download retry did not leave a resumable job; see $DOWNLOAD_LOG"
                    return 1
                fi
                sleep "$DOWNLOAD_RETRY_SECONDS" &
                wait "$!"
                ;;
            downloading|paused)
                status_failures=0
                failed_polls=0
                downloaded_bytes="$(printf '%s' "$response" | jq --raw-output '.downloaded_bytes // 0')"
                total_size_bytes="$(printf '%s' "$response" | jq --raw-output '.total_size_bytes // 0')"
                bytes_per_second="$(printf '%s' "$response" | jq --raw-output '.bytes_per_second // 0')"

                if [ "$downloaded_bytes" -gt "$last_downloaded_bytes" ]; then
                    stale_polls=0
                else
                    stale_polls=$((stale_polls + 1))
                fi

                if [ "$poll_count" -eq 0 ] || [ $((poll_count % 10)) -eq 0 ]; then
                    log "Download $job_id: status=$status bytes=$downloaded_bytes/$total_size_bytes speed=$bytes_per_second stale_polls=$stale_polls"
                fi

                if [ "$stale_polls" -ge "$LMSTUDIO_DOWNLOAD_STALE_POLLS" ]; then
                    log "Download $job_id made no byte progress for $stale_polls polls; retrying through lms get"
                    request_model_download "$active_model"
                    job_id="$(find_model_download_job "$active_model_key" "$active_model")"
                    if [ -z "$job_id" ]; then
                        log "Model download retry did not leave a resumable job; see $DOWNLOAD_LOG"
                        return 1
                    fi
                    stale_polls=0
                    sleep "$DOWNLOAD_RETRY_SECONDS" &
                    wait "$!"
                    continue
                fi
                last_downloaded_bytes="$downloaded_bytes"
                ;;
            *)
                status_failures=$((status_failures + 1))
                log "Download status request failed ($status_failures/10) for $job_id"
                if [ "$status_failures" -ge 10 ]; then
                    return 1
                fi
                ;;
        esac

        poll_count=$((poll_count + 1))
        sleep "$LMSTUDIO_DOWNLOAD_POLL_SECONDS" &
        wait "$!"
    done
}

model_is_loaded() {
    identifier="$1"

    "$LMS_BIN" ps --json 2>/dev/null \
        | jq --exit-status --arg identifier "$identifier" \
            'any(.[]?; .identifier == $identifier)' \
            >/dev/null
}

model_is_ready() {
    identifier="$1"

    if "$LMS_BIN" ps --json 2>/dev/null \
        | jq --exit-status --arg identifier "$identifier" '
            any(.[]?;
              .identifier == $identifier
              and ((.status // "") | ascii_downcase) == "idle"
            )
          ' >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

model_is_ready_with_config() {
    identifier="$1"
    context_length="$2"
    parallel="${3:-}"
    expected_model="${4:-}"

    if [ -n "$parallel" ]; then
        "$LMS_BIN" ps --json 2>/dev/null \
            | jq --exit-status \
                --arg identifier "$identifier" \
                --arg expected_model "$expected_model" \
                --argjson context_length "$context_length" \
                --argjson parallel "$parallel" '
                  any(.[]?;
                    .identifier == $identifier
                    and ((.status // "") | ascii_downcase) == "idle"
                    and ((.contextLength // 0) == $context_length)
                    and ((.parallel // 0) == $parallel)
                    and (
                      $expected_model == ""
                      or ((.selectedVariant // "") == $expected_model)
                      or ((.path // "") == $expected_model)
                      or ((.indexedModelIdentifier // "") == $expected_model)
                    )
                  )
                ' >/dev/null
    else
        "$LMS_BIN" ps --json 2>/dev/null \
            | jq --exit-status \
                --arg identifier "$identifier" \
                --arg expected_model "$expected_model" \
                --argjson context_length "$context_length" '
                  any(.[]?;
                    .identifier == $identifier
                    and ((.status // "") | ascii_downcase) == "idle"
                    and ((.contextLength // 0) == $context_length)
                    and (
                      $expected_model == ""
                      or ((.selectedVariant // "") == $expected_model)
                      or ((.path // "") == $expected_model)
                      or ((.indexedModelIdentifier // "") == $expected_model)
                    )
                  )
                ' >/dev/null
    fi
}

unload_model_if_loaded() {
    identifier="$1"

    if ! model_is_loaded "$identifier"; then
        return 0
    fi

    log "Unloading $identifier before reloading with requested runtime parameters"
    "$LMS_BIN" unload "$identifier" >/dev/null 2>&1 || true
}

wait_for_loaded_model() {
    identifier="$1"
    deadline=$(( $(date +%s) + LMSTUDIO_LOAD_WAIT_SECONDS ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if model_is_ready "$identifier"; then
            log "Model is ready: $identifier"
            return 0
        fi
        sleep "$LMSTUDIO_LOAD_POLL_SECONDS" &
        wait "$!"
    done

    log "Timed out waiting for loaded model: $identifier"
    return 1
}

load_model_with_retry() {
    model_key="$1"
    identifier="$2"
    context_length="$3"
    gpu_mode="$4"
    parallel="$5"
    label="$6"
    attempt=1
    max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        load_log="$(mktemp "$HOME/.lmstudio/.internal/load.XXXXXX")"
        load_pid=''
        deadline=$(( $(date +%s) + LMSTUDIO_LOAD_WAIT_SECONDS ))
        log "Loading $model_key as $identifier ($label, attempt $attempt/$max_attempts)"

        "$LMS_BIN" load "$model_key" \
            --identifier "$identifier" \
            --context-length "$context_length" \
            --gpu "$gpu_mode" \
            --parallel "$parallel" \
            --yes \
            > "$load_log" 2>&1 &
        load_pid="$!"

        while [ "$(date +%s)" -lt "$deadline" ]; do
            if model_is_ready "$identifier"; then
                log "Model is ready: $identifier"
                kill "$load_pid" >/dev/null 2>&1 || true
                wait "$load_pid" >/dev/null 2>&1 || true
                rm -f "$load_log"
                return 0
            fi

            if ! kill -0 "$load_pid" >/dev/null 2>&1; then
                if wait "$load_pid"; then
                    if wait_for_loaded_model "$identifier"; then
                        rm -f "$load_log"
                        return 0
                    fi
                fi

                if grep --extended-regexp --ignore-case \
                    'Loading model|unavailable_error|healthCheck request returned 503|did not become healthy' \
                    "$load_log" >/dev/null 2>&1; then
                    log "LM Studio is still loading $identifier; retrying without restarting"
                    break
                fi

                if model_is_loaded "$identifier"; then
                    log "Model $identifier is visible but not idle yet; waiting"
                    if wait_for_loaded_model "$identifier"; then
                        rm -f "$load_log"
                        return 0
                    fi
                    break
                fi

                log "Model load failed for $identifier"
                tail -n 80 "$load_log" || true
                rm -f "$load_log"
                return 1
            fi

            sleep "$LMSTUDIO_LOAD_POLL_SECONDS" &
            wait "$!"
        done

        if kill -0 "$load_pid" >/dev/null 2>&1; then
            log "Stopping stalled lms load process for $identifier"
            kill "$load_pid" >/dev/null 2>&1 || true
            wait "$load_pid" >/dev/null 2>&1 || true
        else
            wait "$load_pid" >/dev/null 2>&1 || true
        fi

        tail -n 40 "$load_log" || true
        rm -f "$load_log"
        attempt=$((attempt + 1))
    done

    log "Model load did not finish for $identifier after $max_attempts attempts"
    return 1
}

force_model_index_variant() {
    if [ -z "$LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER" ]; then
        return 0
    fi

    if [ ! -r "$MODEL_INDEX_CACHE_FILE" ]; then
        log "Model index cache is not present yet, cannot force concrete model: $MODEL_INDEX_CACHE_FILE"
        return 0
    fi

    tmp_index="$(mktemp "$HOME/.lmstudio/.internal/model-index-cache.XXXXXX")"
    if jq -e \
        --arg base "$LMSTUDIO_MODEL_KEY" \
        --arg concrete "$LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER" '
          (.models[]? | select(.indexedModelIdentifier == $concrete)) as $target
          | .models |= map(
              if .indexedModelIdentifier == $base then
                .entryPoint = $target.entryPoint
                | .visionAdapter = ($target.visionAdapter // .visionAdapter)
                | .quant = ($target.quant // .quant)
                | .originalIndexedModelIdentifier = ($target.originalIndexedModelIdentifier // .originalIndexedModelIdentifier)
                | .sizeBytes = ($target.sizeBytes // .sizeBytes)
                | .baselessAutoIdentifiers = ($target.baselessAutoIdentifiers // .baselessAutoIdentifiers)
                | .virtual.concreteModelIndexedModelIdentifier = $concrete
                | .virtual.baseChain = (
                    if ((.virtual.baseChain // []) | length) > 1 then
                      (.virtual.baseChain | .[1] = $concrete)
                    else
                      .virtual.baseChain
                    end
                  )
              else
                .
              end
            )
        ' "$MODEL_INDEX_CACHE_FILE" > "$tmp_index"; then
        if ! cmp -s "$MODEL_INDEX_CACHE_FILE" "$tmp_index"; then
            mv "$tmp_index" "$MODEL_INDEX_CACHE_FILE"
            log "Forced $LMSTUDIO_MODEL_KEY concrete model to $LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER in model index cache"
        else
            rm -f "$tmp_index"
            log "Model index cache already points $LMSTUDIO_MODEL_KEY to $LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER"
        fi
    else
        rm -f "$tmp_index"
        log "Could not force concrete model in index cache: $LMSTUDIO_MODEL_FORCE_CONCRETE_MODEL_IDENTIFIER"
        return 1
    fi
}

restore_hidden_variant_files() {
    if [ ! -d "$HIDDEN_VARIANTS_DIR" ]; then
        return 0
    fi

    find "$HIDDEN_VARIANTS_DIR" -type f 2>/dev/null | while IFS= read -r hidden_file; do
        rel_path="${hidden_file#"$HIDDEN_VARIANTS_DIR"/}"
        target_file="$HOME/.lmstudio/models/$rel_path"

        if [ -e "$target_file" ]; then
            log "Hidden variant restore skipped because target already exists: $rel_path"
            continue
        fi

        mkdir -p "$(dirname "$target_file")"
        mv "$hidden_file" "$target_file"
        log "Restored hidden model variant: $rel_path"
    done
}

hide_model_variant_files() {
    if [ -z "$LMSTUDIO_MODEL_HIDE_VARIANT_FILES" ]; then
        return 0
    fi

    for variant_file in $LMSTUDIO_MODEL_HIDE_VARIANT_FILES; do
        case "$variant_file" in
            "$HOME"/.lmstudio/models/*)
                source_file="$variant_file"
                rel_path="${variant_file#"$HOME/.lmstudio/models/"}"
                ;;
            /*)
                source_file="$variant_file"
                rel_path="$(basename "$variant_file")"
                ;;
            *)
                rel_path="$variant_file"
                source_file="$HOME/.lmstudio/models/$rel_path"
                ;;
        esac

        if [ ! -f "$source_file" ]; then
            log "Requested hidden model variant is not present, skipping: $variant_file"
            continue
        fi

        hidden_file="$HIDDEN_VARIANTS_DIR/$rel_path"
        mkdir -p "$(dirname "$hidden_file")"
        mv "$source_file" "$hidden_file"
        log "Temporarily hid model variant before load: $rel_path"
    done
}

load_requested_chat_model() {
    hide_model_variant_files

    load_rc=0
    load_model_with_retry \
        "$LMSTUDIO_MODEL_LOAD_SPEC" \
        "$LMSTUDIO_MODEL_IDENTIFIER" \
        "$LMSTUDIO_CONTEXT_LENGTH" \
        "$LMSTUDIO_GPU" \
        "$LMSTUDIO_PARALLEL" \
        "chat" || load_rc="$?"

    if [ "$load_rc" -ne 0 ] && [ "$LMSTUDIO_GPU" != "off" ]; then
        log "GPU model load failed for $LMSTUDIO_MODEL_IDENTIFIER after retries; falling back to --gpu off"
        load_rc=0
        load_model_with_retry \
            "$LMSTUDIO_MODEL_LOAD_SPEC" \
            "$LMSTUDIO_MODEL_IDENTIFIER" \
            "$LMSTUDIO_CONTEXT_LENGTH" \
            "off" \
            "$LMSTUDIO_PARALLEL" \
            "chat-cpu-fallback" || load_rc="$?"
    fi

    restore_hidden_variant_files
    return "$load_rc"
}

requested_models_are_loaded() {
    if [ -n "$LMSTUDIO_EMBEDDING_MODEL" ] \
        && ! model_is_loaded "$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER"; then
        log "Embedding model $LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER is not loaded"
        return 1
    fi

    if ! model_is_loaded "$LMSTUDIO_MODEL_IDENTIFIER"; then
        log "Model $LMSTUDIO_MODEL_IDENTIFIER is not loaded"
        return 1
    fi

    return 0
}

start_background_downloads() {
    if [ -z "$LMSTUDIO_BACKGROUND_DOWNLOADS" ]; then
        return 0
    fi

    if [ -s "$BACKGROUND_DOWNLOAD_PID_FILE" ]; then
        background_pid="$(cat "$BACKGROUND_DOWNLOAD_PID_FILE" 2>/dev/null || true)"
        if [ -n "$background_pid" ] && kill -0 "$background_pid" 2>/dev/null; then
            log "Background model download is already running as pid $background_pid"
            return 0
        fi
    fi

    (
        printf '\n%s\n' '=== ai-stand background model download started ==='
        date -Iseconds

        printf '%s\n' "$LMSTUDIO_BACKGROUND_DOWNLOADS" | while IFS= read -r raw_item; do
            item="$(printf '%s' "$raw_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            case "$item" in
                ''|'#'*) continue ;;
            esac

            available_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
            min_free_kb="$((LMSTUDIO_BACKGROUND_DOWNLOAD_MIN_FREE_GB * 1024 * 1024))"
            if [ "$available_kb" -lt "$min_free_kb" ]; then
                printf '\n=== %s ===\nSKIP: only %s KB free, below %sGB minimum\n' \
                    "$item" "$available_kb" "$LMSTUDIO_BACKGROUND_DOWNLOAD_MIN_FREE_GB"
                continue
            fi

            printf '\n=== %s ===\n' "$item"
            date -Iseconds
            if "$LMS_BIN" get "$item" -y; then
                printf 'OK %s\n' "$item"
            else
                rc="$?"
                printf 'FAIL rc=%s %s\n' "$rc" "$item"
            fi
            date -Iseconds
        done

        printf '\n%s\n' '=== ai-stand background model download finished ==='
        date -Iseconds
    ) >> "$BACKGROUND_DOWNLOAD_LOG" 2>&1 &

    background_pid="$!"
    printf '%s\n' "$background_pid" > "$BACKGROUND_DOWNLOAD_PID_FILE"
    log "Started background model download as pid $background_pid; log: $BACKGROUND_DOWNLOAD_LOG"
}

sync_image_payload
configure_runtime_home

if [ ! -x "$LMS_BIN" ]; then
    log "lms was not found in image payload at $LMS_BIN"
    exit 1
fi

if [ ! -r "$LMSTUDIO_RUNTIME_MANIFEST" ]; then
    log "Runtime manifest is missing: $LMSTUDIO_RUNTIME_MANIFEST"
    exit 1
fi

runtime_ref="$(tr -d '\r\n' < "$LMSTUDIO_RUNTIME_MANIFEST")"
case "$runtime_ref" in
    "$LMSTUDIO_RUNTIME_ID"@*) ;;
    *)
        log "Runtime manifest '$runtime_ref' does not match $LMSTUDIO_RUNTIME_ID"
        exit 1
        ;;
esac

trap 'stop_lmstudio 0' INT TERM

restore_hidden_variant_files
hide_model_variant_files
# Best-effort: the daemon hasn't started yet, so the persisted index cache
# reflects whatever it looked like when the *previous* container instance
# shut down and may not have an entry for the concrete model at all. The
# authoritative call is the one after the daemon starts and the model
# download is confirmed, below.
force_model_index_variant || true
start_lmstudio_daemon

log "Selecting embedded runtime $runtime_ref"
NO_COLOR=1 "$LMS_BIN" runtime select "$runtime_ref"
install_llama_server_wrapper

log "Starting API server on 0.0.0.0:$LMSTUDIO_PORT"
"$LMS_BIN" server start --bind 0.0.0.0 --port "$LMSTUDIO_PORT"

downloaded_model=''
if [ -f "$MODEL_MARKER" ]; then
    downloaded_model="$(cat "$MODEL_MARKER")"
fi

if [ "$downloaded_model" != "$LMSTUDIO_MODEL" ]; then
    wait_for_model_download "$LMSTUDIO_MODEL"
else
    log "Using model data already stored for $LMSTUDIO_MODEL"
fi

# Best-effort even here: observed in practice that the daemon's own index
# scan (started above, asynchronous) can still not have picked up the
# concrete file's entry yet even after the download itself is confirmed
# complete, so a missing match isn't necessarily a real problem. The load
# below addresses the model by $LMSTUDIO_MODEL_IDENTIFIER regardless of
# whether this forcing succeeded; worst case on a miss here is that the
# "virtual" base identifier's own quant resolution is whatever LM Studio
# picks by default rather than the pinned one.
force_model_index_variant || true

if [ -n "$LMSTUDIO_EMBEDDING_MODEL" ]; then
    if [ -z "$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER" ]; then
        log 'LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER is required when LMSTUDIO_EMBEDDING_MODEL is set'
        exit 1
    fi

    downloaded_embedding_model=''
    if [ -f "$EMBEDDING_MODEL_MARKER" ]; then
        downloaded_embedding_model="$(cat "$EMBEDDING_MODEL_MARKER")"
    fi

    if [ "$downloaded_embedding_model" != "$LMSTUDIO_EMBEDDING_MODEL" ]; then
        wait_for_model_download "$LMSTUDIO_EMBEDDING_MODEL"
    else
        log "Using embedding model data already stored for $LMSTUDIO_EMBEDDING_MODEL"
    fi

    if model_is_ready_with_config \
        "$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER" \
        "$LMSTUDIO_EMBEDDING_CONTEXT_LENGTH"; then
        log "Embedding model $LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER is already loaded with requested context"
    else
        unload_model_if_loaded "$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER"
        load_model_with_retry \
            "$LMSTUDIO_EMBEDDING_MODEL_KEY" \
            "$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER" \
            "$LMSTUDIO_EMBEDDING_CONTEXT_LENGTH" \
            "$LMSTUDIO_EMBEDDING_GPU" \
            "1" \
            "embedding"
    fi

    printf '%s\n' "$LMSTUDIO_EMBEDDING_MODEL" > "$EMBEDDING_MODEL_MARKER"
fi

if model_is_ready_with_config \
    "$LMSTUDIO_MODEL_IDENTIFIER" \
    "$LMSTUDIO_CONTEXT_LENGTH" \
    "$LMSTUDIO_PARALLEL" \
    "$LMSTUDIO_MODEL"; then
    log "Model $LMSTUDIO_MODEL_IDENTIFIER is already loaded with requested context/parallel"
else
    unload_model_if_loaded "$LMSTUDIO_MODEL_IDENTIFIER"
    load_requested_chat_model
fi

# The marker means both download and first load succeeded. This prevents a
# completed-but-unindexed job from being mistaken for a ready model.
printf '%s\n' "$LMSTUDIO_MODEL" > "$MODEL_MARKER"

start_background_downloads

failures=0
while :; do
    sleep 10 &
    wait "$!"

    daemon_ok=0
    server_ok=0
    models_ok=0

    daemon_status_json="$(
        NO_COLOR=1 "$LMS_BIN" daemon status --json 2>/dev/null || true
    )"
    if printf '%s' "$daemon_status_json" | jq -e '.status == "running"' >/dev/null 2>&1; then
        daemon_ok=1
    fi

    if curl --fail --silent "$API_BASE_URL/v1/models" >/dev/null; then
        server_ok=1
    fi

    # Runtime reconciliation above is intentionally one-shot during startup.
    # Do not unload/reload models from the health monitor: a long inference can
    # temporarily change status from idle, and unloading it here aborts active
    # API requests with "Model unloaded by user or API request".
    if [ "$daemon_ok" -eq 1 ] && [ "$server_ok" -eq 1 ] && requested_models_are_loaded; then
        models_ok=1
    fi

    if [ "$daemon_ok" -eq 1 ] && [ "$server_ok" -eq 1 ] && [ "$models_ok" -eq 1 ]; then
        failures=0
        continue
    fi

    failures=$((failures + 1))
    log "Health monitor failure $failures/3 (daemon=$daemon_ok, server=$server_ok, models=$models_ok)"
    if [ "$failures" -ge 3 ]; then
        stop_lmstudio 1
    fi
done
