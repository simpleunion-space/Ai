#!/bin/sh

set -eu

log() {
    printf '%s\n' "[bootstrap] $*" >&2
}

IM_UID="${IM_UID:-1000}"
IM_GID="${IM_GID:-1000}"
IM_TZ="${IM_TZ:-Europe/Moscow}"

case "$IM_UID" in
    ''|*[!0-9]*)
        log 'IM_UID must be a positive integer'
        exit 1
        ;;
esac

case "$IM_GID" in
    ''|*[!0-9]*)
        log 'IM_GID must be a positive integer'
        exit 1
        ;;
esac

if [ "$IM_UID" -eq 0 ] || [ "$IM_GID" -eq 0 ]; then
    log 'IM_UID and IM_GID must be non-zero'
    exit 1
fi

if [ ! -e "/usr/share/zoneinfo/$IM_TZ" ]; then
    log "Unknown timezone: $IM_TZ"
    exit 1
fi

if [ "$(id -g ai)" -ne "$IM_GID" ]; then
    log "Changing ai group id to $IM_GID"
    groupmod --non-unique --gid "$IM_GID" ai
fi

if [ "$(id -u ai)" -ne "$IM_UID" ]; then
    log "Changing ai user id to $IM_UID"
    usermod --non-unique --uid "$IM_UID" ai
fi

usermod --gid "$IM_GID" ai
usermod --groups '' ai

# Swarm does not support Compose group_add. Create deterministic image-local
# group names for the numeric host device groups supplied through environment.
supplemental_gids="${AI_SUPPLEMENTAL_GIDS:-}"
old_ifs="$IFS"
IFS=:
for supplemental_gid in $supplemental_gids; do
    case "$supplemental_gid" in
        ''|*[!0-9]*)
            log 'AI_SUPPLEMENTAL_GIDS must be a colon-separated list of positive integers'
            exit 1
            ;;
    esac

    if [ "$supplemental_gid" -eq 0 ]; then
        log 'AI_SUPPLEMENTAL_GIDS must not contain 0'
        exit 1
    fi

    if [ "$supplemental_gid" -eq "$IM_GID" ]; then
        continue
    fi

    supplemental_group="$(getent group "$supplemental_gid" | cut -d: -f1 || true)"
    if [ -z "$supplemental_group" ]; then
        supplemental_group="ai-device-$supplemental_gid"
        groupadd --non-unique --gid "$supplemental_gid" "$supplemental_group"
    fi
    usermod --append --groups "$supplemental_group" ai
done
IFS="$old_ifs"

ln -snf "/usr/share/zoneinfo/$IM_TZ" /etc/localtime
printf '%s\n' "$IM_TZ" > /etc/timezone

writable_paths="/home/ai"
if [ -n "${AI_WRITABLE_PATHS:-}" ]; then
    writable_paths="$writable_paths:$AI_WRITABLE_PATHS"
fi

old_ifs="$IFS"
IFS=:
for writable_path in $writable_paths; do
    if [ -z "$writable_path" ]; then
        continue
    fi

    mkdir -p "$writable_path"
    owner_marker="$writable_path/.ai-container-owner"
    expected_owner="$IM_UID:$IM_GID"
    current_owner="$(cat "$owner_marker" 2>/dev/null || true)"

    if [ "$current_owner" != "$expected_owner" ]; then
        log "Applying ownership $expected_owner to $writable_path"
        chown -R "$IM_UID:$IM_GID" "$writable_path"
        printf '%s\n' "$expected_owner" > "$owner_marker"
        chown "$IM_UID:$IM_GID" "$owner_marker"
    fi
done
IFS="$old_ifs"

if [ "$#" -eq 0 ]; then
    set -- /bin/bash
fi

exec gosu ai /usr/bin/tini -- "$@"
