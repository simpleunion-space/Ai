#!/bin/sh
set -eu

# Coder accepts its PostgreSQL URL and OIDC client secret as environment
# values, not *_FILE options. This local wrapper expands only Docker Secret
# files at startup and then execs the upstream binary.
read_required_secret() {
  path="$1"
  test -r "$path" || {
    echo "required Coder secret file is unreadable" >&2
    exit 1
  }
  value="$(cat "$path")"
  test -n "$value" || {
    echo "required Coder secret file is empty" >&2
    exit 1
  }
  printf '%s' "$value"
}

: "${CODER_PG_PASSWORD_FILE:?CODER_PG_PASSWORD_FILE is required}"
: "${CODER_OIDC_CLIENT_SECRET_FILE:?CODER_OIDC_CLIENT_SECRET_FILE is required}"

pg_password="$(read_required_secret "$CODER_PG_PASSWORD_FILE")"
export CODER_PG_CONNECTION_URL="postgresql://coder:${pg_password}@coder-postgresql:5432/coder?sslmode=disable"
unset pg_password
export CODER_OIDC_CLIENT_SECRET="$(read_required_secret "$CODER_OIDC_CLIENT_SECRET_FILE")"

exec /opt/coder "$@"
