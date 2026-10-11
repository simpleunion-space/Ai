#!/usr/bin/env bash
# Renews the ai-stand wildcard certificate (DNS-01 through the installation's DNS hook) and hands it to the
# other node. Runs ONLY on the node that owns certbot (ai01), as the `certbot` job of the ai-stand controller
# container (docker/controller) or by hand:
#
#   renew.sh             renew when due (certbot decides: <30 days left), then distribute if the certificate changed
#   renew.sh --dry-run   full DNS-01 rehearsal against Let's Encrypt STAGING: creates and removes the TXT values,
#                        changes nothing on disk. Run this first, and after any change of the DNS credentials.
#   renew.sh --issue     (re)issue now with the configured hooks. Converts a certificate that was issued with
#                        `certonly --manual` to hook-based renewal. Add --force to reissue before it is due.
#
# Configuration comes from the environment (the controller's compose service sets it); an optional file named by
# AI_STAND_CERTBOT_CONF may supply the same variables. Credentials come from the root-only env file named by
# CERTBOT_CREDENTIALS, passed to the certbot container with --env-file so they never appear in an argv.
#
# The new certificate is rolled out only after nginx on this node serves it (see served.sh), and is then pushed to the
# other node's cert-receiver service over the encrypted overlay network (CERTBOT_PEER_URL, bearer token from
# CERTBOT_PEER_TOKEN_FILE). No SSH keys are involved.
set -euo pipefail

CONF="${AI_STAND_CERTBOT_CONF:-}"
# shellcheck disable=SC1090
if [ -n "$CONF" ]; then . "$CONF"; fi
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/served.sh"

: "${CERT_DOMAIN:?}" "${CERTBOT_IMAGE:?}" "${CERTBOT_EMAIL:?}" "${CERTBOT_DATA:?}" "${CERTBOT_HOOK_DIR:?}"
: "${CERTBOT_CREDENTIALS:?}" "${CERTBOT_AUTH_HOOK:?}" "${CERTBOT_CLEANUP_HOOK:?}"
STATE_DIR="${CERTBOT_STATE_DIR:-/var/lib/ai-stand/certbot}"
LIVE="$CERTBOT_DATA/live/$CERT_DOMAIN"
RENEW_BEFORE_WARN="${CERTBOT_WARN_SECONDS:-1814400}" # 21 days: no credentials and this close is an alarm

log() { printf '[certbot-renew] %s\n' "$*"; }
die() { printf '[certbot-renew] ERROR: %s\n' "$*" >&2; exit 1; }

mode=renew
force=
for arg in "$@"; do
  case "$arg" in
    --dry-run) mode=dry-run ;;
    --issue) mode=issue ;;
    --force) force=--force-renewal ;;
    *) die "unknown option: $arg" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "must run as root"
install -d -m 0700 "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || die "another renewal is running"

fingerprint() { openssl x509 -in "$LIVE/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }

if [ ! -r "$CERTBOT_CREDENTIALS" ]; then
  # Without credentials nothing can renew. Staying silent until expiry is the failure this exists to prevent.
  if [ -r "$LIVE/fullchain.pem" ] && ! openssl x509 -in "$LIVE/fullchain.pem" -noout -checkend "$RENEW_BEFORE_WARN" >/dev/null; then
    die "DNS credentials ($CERTBOT_CREDENTIALS) are missing and the certificate expires within $((RENEW_BEFORE_WARN / 86400)) days"
  fi
  log "DNS credentials are not installed: automatic renewal is inactive"
  exit 0
fi

certbot() {
  docker run --rm --name ai-stand-certbot --env-file "$CERTBOT_CREDENTIALS" \
    -v "$CERTBOT_DATA:/etc/letsencrypt" -v "$CERTBOT_HOOK_DIR:/hooks:ro" "$CERTBOT_IMAGE" "$@"
}

issue_args=(certonly --non-interactive --manual --preferred-challenges dns
  --manual-auth-hook "$CERTBOT_AUTH_HOOK" --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK"
  --cert-name "$CERT_DOMAIN" -d "$CERT_DOMAIN" -d "*.$CERT_DOMAIN"
  --email "$CERTBOT_EMAIL" --agree-tos --key-type ecdsa)

before="$(fingerprint || true)"
case "$mode" in
  dry-run)
    certbot "${issue_args[@]}" --dry-run
    log "dry run finished (Let's Encrypt staging); nothing was changed"
    exit 0 ;;
  issue)
    certbot "${issue_args[@]}" ${force:+"$force"} ;;
  renew)
    certbot renew --non-interactive --no-random-sleep-on-renew ;;
esac

after="$(fingerprint)" || die "no certificate at $LIVE after the run"
distributed="$(cat "$STATE_DIR/distributed.sha256" 2>/dev/null || true)"
if [ "$after" = "$distributed" ] && [ "$after" = "$before" ]; then
  log "certificate unchanged and already distributed"
  exit 0
fi

# Never roll out something nginx would not serve: SAN, validity and key pairing first.
openssl x509 -in "$LIVE/fullchain.pem" -noout -checkend 2592000 >/dev/null || die "new certificate has less than 30 days of validity"
san="$(openssl x509 -in "$LIVE/fullchain.pem" -noout -ext subjectAltName)"
printf '%s' "$san" | grep -q "DNS:\*\.$CERT_DOMAIN" || die "certificate does not cover *.$CERT_DOMAIN"
[ "$(openssl x509 -in "$LIVE/fullchain.pem" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$LIVE/privkey.pem" -pubout | openssl sha256)" ] \
  || die "certificate and private key do not match"

# nginx on this node: the host path unit tests the configuration, reloads and records what it serves.
wait_served "$after" \
  || die "nginx on this node did not start serving the new certificate (host unit: ai-stand-nginx-reload.service); not handing it to the other node"
log "nginx serves the new certificate on this node"

if [ -n "${CERTBOT_PEER_URL:-}" ]; then
  : "${CERTBOT_PEER_TOKEN_FILE:?}"
  [ -r "$CERTBOT_PEER_TOKEN_FILE" ] || die "peer token file $CERTBOT_PEER_TOKEN_FILE is not readable"
  # The token goes to curl through a header file, never an argv.
  tar -C "$CERTBOT_DATA" -cf - "archive/$CERT_DOMAIN" "live/$CERT_DOMAIN" \
    | curl --fail-with-body -sS --max-time 180 -X PUT -H "Content-Type: application/x-tar" \
        -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$CERTBOT_PEER_TOKEN_FILE")") \
        --data-binary @- "${CERTBOT_PEER_URL%/}/v1/certificate" \
    || die "could not hand the certificate to $CERTBOT_PEER_URL (this node already serves the new one)"
  echo
  log "certificate handed to $CERTBOT_PEER_URL"
fi
printf '%s\n' "$after" > "$STATE_DIR/distributed.sha256"
log "done: $(openssl x509 -in "$LIVE/fullchain.pem" -noout -enddate)"
