#!/usr/bin/env bash
# Receives the renewed certificate lineage from the node that owns certbot and activates it here.
# It is run by the `cert-receiver` service of the ai-stand controller image (docker/controller) for every
# authenticated PUT /v1/certificate, and is baked into that image: the validation below must not depend on a
# mutable checkout.
#
# stdin: a tar stream of archive/<domain> and live/<domain> (relative symlinks kept) from renew.sh. Nothing is
# trusted: member names and link targets are checked before extraction, and the certificate is checked
# (validity, SAN, key pairing, chain to a trusted CA) before it replaces the one nginx serves.
# Activation is confirmed by the host: nginx must report serving the new certificate (see served.sh), otherwise the
# previous lineage is restored. Any failure leaves the old files in place.
set -euo pipefail

CONF="${AI_STAND_CERTBOT_CONF:-}"
# shellcheck disable=SC1090
if [ -n "$CONF" ]; then . "$CONF"; fi
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/served.sh"
: "${CERT_DOMAIN:?}" "${CERTBOT_DATA:?}"

die() { printf '[certbot-receive] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[certbot-receive] %s\n' "$*"; }
[ "$(id -u)" = 0 ] || die "must run as root"
case "$CERT_DOMAIN" in *[!A-Za-z0-9.-]*|"") die "unsafe domain name" ;; esac

work="$(mktemp -d "$CERTBOT_DATA/.incoming.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
cat > "$work/stream.tar"

# 1. member names: only archive/<domain>[/file] and live/<domain>[/file]; no absolute paths, no "..".
d="$CERT_DOMAIN"
while IFS= read -r member; do
  member="${member%/}"
  case "$member" in
    archive|live) ;;
    "archive/$d"|"live/$d") ;;
    "archive/$d/"*|"live/$d/"*)
      leaf="${member#*/"$d"/}"
      case "$leaf" in */*|.*|"") die "unexpected member: $member" ;; esac
      case "$leaf" in *[!A-Za-z0-9._-]*) die "unexpected member: $member" ;; esac ;;
    *) die "unexpected member: $member" ;;
  esac
done < <(tar -tf "$work/stream.tar")

# 2. link targets: relative, inside the same lineage
while IFS= read -r line; do
  case "$line" in
    -*|d*|l*) ;;
    *) die "unexpected member type: ${line%% *}" ;;
  esac
  case "$line" in
    *" -> "*)
      target="${line##* -> }"
      case "$target" in
        "../../archive/$d/"*) leaf="${target#../../archive/"$d"/}"
          case "$leaf" in */*|.*|"") die "unexpected link target: $target" ;; esac ;;
        *) die "unexpected link target: $target" ;;
      esac ;;
  esac
done < <(tar -tvf "$work/stream.tar")

mkdir "$work/new"
tar -xf "$work/stream.tar" -C "$work/new" --no-same-owner --no-same-permissions

# 3. the certificate itself
fullchain="$work/new/live/$d/fullchain.pem"
privkey="$work/new/live/$d/privkey.pem"
[ -r "$fullchain" ] && [ -r "$privkey" ] || die "stream does not contain live/$d/fullchain.pem and privkey.pem"
# the links resolve inside the unpacked tree only because they are relative; check the resolved files are regular
[ -f "$(readlink -f "$fullchain")" ] && [ -f "$(readlink -f "$privkey")" ] || die "certificate links do not resolve"
case "$(readlink -f "$fullchain")" in "$work/new/archive/$d/"*) ;; *) die "certificate link leaves the lineage" ;; esac
case "$(readlink -f "$privkey")" in "$work/new/archive/$d/"*) ;; *) die "key link leaves the lineage" ;; esac
openssl x509 -in "$fullchain" -noout -checkend 2592000 >/dev/null || die "certificate has less than 30 days of validity"
openssl x509 -in "$fullchain" -noout -ext subjectAltName | grep -q "DNS:\*\.$d" || die "certificate does not cover *.$d"
# A certificate that no public CA signed must never replace the one nginx serves, whichever node sends it:
# the chain has to verify against the system trust store for a host name under the domain.
openssl verify -CAfile "${CERTBOT_TRUST_STORE:-/etc/ssl/certs/ca-certificates.crt}" -untrusted "$work/new/live/$d/chain.pem" \
  -purpose sslserver -verify_hostname "check.$d" "$work/new/live/$d/cert.pem" >/dev/null 2>&1 \
  || die "certificate does not chain to a trusted CA for $d"
[ "$(openssl x509 -in "$fullchain" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$privkey" -pubout | openssl sha256)" ] \
  || die "certificate and private key do not match"

# 4. activate: keep the previous lineage next to the new one until nginx accepts it
owner="$(stat -c %u:%g "$CERTBOT_DATA")"
chown -R "$owner" "$work/new"
chmod -R u=rwX,g=rX,o= "$work/new"
install -d -m 0750 -o "${owner%:*}" -g "${owner#*:}" "$CERTBOT_DATA/archive" "$CERTBOT_DATA/live"
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$" # unique even for two activations within one second
for part in archive live; do
  [ -e "$CERTBOT_DATA/$part/$d" ] && mv "$CERTBOT_DATA/$part/$d" "$CERTBOT_DATA/$part/.$d.before-$stamp"
  mv "$work/new/$part/$d" "$CERTBOT_DATA/$part/$d"
done
new_fingerprint="$(lineage_fingerprint "$CERTBOT_DATA/live/$d")"
if wait_served "$new_fingerprint"; then
  log "activated $(openssl x509 -in "$CERTBOT_DATA/live/$d/fullchain.pem" -noout -enddate); nginx serves it"
  # keep only the newest previous lineage
  for part in archive live; do
    { ls -1dt "$CERTBOT_DATA/$part"/."$d".before-* 2>/dev/null || true; } | tail -n +2 | xargs -r rm -rf --
  done
else
  log "nginx did not start serving the new certificate: restoring the previous one"
  for part in archive live; do
    rm -rf -- "${CERTBOT_DATA:?}/$part/$d"
    [ -e "$CERTBOT_DATA/$part/.$d.before-$stamp" ] && mv "$CERTBOT_DATA/$part/.$d.before-$stamp" "$CERTBOT_DATA/$part/$d"
  done
  # The host path unit sees the restoration and reloads nginx again.
  exit 1
fi
