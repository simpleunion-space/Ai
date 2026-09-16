#!/bin/sh

set -eu

profile="${1:?Runtime profile is required}"
runtime_id="${2:?Runtime identifier is required}"
runtime_version="${3:?Runtime version is required}"
lms_bin="$HOME/.lmstudio/bin/lms"
manifest_dir=/opt/lmstudio-runtime-manifests
runtime_output=/tmp/lmstudio-runtime-output.txt
daemon_output=/tmp/lmstudio-daemon-up-output.txt
daemon_up_pid=''

stop_daemon_up_process() {
    if [ -n "$daemon_up_pid" ] && kill -0 "$daemon_up_pid" 2>/dev/null; then
        kill "$daemon_up_pid" 2>/dev/null || true
        wait "$daemon_up_pid" 2>/dev/null || true
    fi
    daemon_up_pid=''
}

cleanup() {
    stop_daemon_up_process
    "$lms_bin" daemon down >/dev/null 2>&1 || true
    rm -f "$runtime_output" "$daemon_output"
}

trap cleanup EXIT INT TERM

if [ ! -x "$lms_bin" ]; then
    printf '%s\n' "lms was not installed at $lms_bin" >&2
    exit 1
fi

start_daemon() {
    daemon_attempt=1
    while [ "$daemon_attempt" -le 3 ]; do
        rm -f "$HOME/.lmstudio/.internal/llmster-pid.lock"
        : > "$daemon_output"

        printf '%s\n' "Waking up LM Studio service (attempt $daemon_attempt/3)..."
        NO_COLOR=1 "$lms_bin" daemon up --json > "$daemon_output" 2>&1 &
        daemon_up_pid="$!"

        elapsed=0
        while [ "$elapsed" -lt 120 ]; do
            daemon_status_json="$(
                NO_COLOR=1 "$lms_bin" daemon status --json 2>/dev/null || true
            )"
            if printf '%s' "$daemon_status_json" | jq -e '.status == "running"' >/dev/null 2>&1; then
                printf '%s\n' 'LM Studio daemon is ready'
                stop_daemon_up_process
                return 0
            fi

            if [ -n "$daemon_up_pid" ] && ! kill -0 "$daemon_up_pid" 2>/dev/null; then
                wait "$daemon_up_pid" 2>/dev/null || true
                daemon_up_pid=''
            fi

            sleep 1
            elapsed=$((elapsed + 1))
        done

        printf '%s\n' "LM Studio daemon did not become ready on attempt $daemon_attempt" >&2
        cat "$daemon_output" >&2 || true
        stop_daemon_up_process
        "$lms_bin" daemon down >/dev/null 2>&1 || true

        daemon_attempt=$((daemon_attempt + 1))
        if [ "$daemon_attempt" -le 3 ]; then
            sleep 5
        fi
    done

    printf '%s\n' 'LM Studio daemon did not become ready during image build' >&2
    exit 1
}

start_daemon

runtime_ref="$runtime_id@$runtime_version"

set -- "$runtime_ref" -y
if [ "$profile" != cpu ]; then
    # Image builds intentionally run without accelerator devices. Fetch the
    # requested GPU backend anyway and validate it on the target host at run time.
    set -- "$@" --allow-incompatible
fi

attempt=1
while :; do
    if CI=1 NO_COLOR=1 "$lms_bin" runtime get "$@" > "$runtime_output" 2>&1; then
        cat "$runtime_output"
        break
    fi

    cat "$runtime_output" >&2
    if [ "$attempt" -ge 5 ]; then
        printf '%s\n' "Runtime download failed after $attempt attempts" >&2
        exit 1
    fi

    retry_delay=$((attempt * 10))
    printf '%s\n' "Runtime download attempt $attempt failed; retrying in ${retry_delay}s" >&2
    sleep "$retry_delay"
    attempt=$((attempt + 1))
done

CI=1 NO_COLOR=1 "$lms_bin" runtime ls >> "$runtime_output" 2>&1 || true

# Pinned exactly - no "pick the latest available" fallback. A future
# intentional bump requires passing a new runtime_version explicitly, the
# same discipline as the install.sh checksum pin above it in the Dockerfile.
if ! grep -Fq "$runtime_ref" "$runtime_output"; then
    printf '%s\n' "Could not confirm installed pinned runtime $runtime_ref" >&2
    cat "$runtime_output" >&2
    exit 1
fi

printf '%s\n' "$runtime_ref" > "$manifest_dir/$profile"
printf '%s=%s\n' "$profile" "$runtime_ref" >> "$HOME/.lmstudio-container-runtimes"

backend_root="$HOME/.lmstudio/extensions/backends"
if [ -d "$backend_root" ]; then
    for backend_dir in "$backend_root"/*; do
        [ -d "$backend_dir" ] || continue

        backend_name="${backend_dir##*/}"
        if [ "$backend_name" = vendor ]; then
            continue
        fi

        keep_backend=0
        for manifest in "$manifest_dir"/*; do
            [ -f "$manifest" ] || continue
            manifest_ref="$(tr -d '\r\n' < "$manifest")"
            manifest_backend="${manifest_ref%@*}-${manifest_ref#*@}"
            if [ "$backend_name" = "$manifest_backend" ]; then
                keep_backend=1
                break
            fi
        done

        if [ "$keep_backend" -eq 0 ]; then
            printf '%s\n' "Removing unrequested bundled runtime $backend_name"
            rm -rf -- "$backend_dir"
        fi
    done
fi

printf '%s\n' "Embedded LM Studio runtime $runtime_ref for profile $profile"
