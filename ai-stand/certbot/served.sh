# Sourced by renew.sh and receive-cert.sh.
#
# nginx runs on the host, the scripts run in a container. When the TLS lineage changes, a host path unit
# (nginx/ai-stand-nginx-reload.path) tests the configuration, reloads nginx and records the SHA-256 fingerprint of
# the certificate nginx then serves in $CERTBOT_DATA/.served-fingerprint. The scripts wait for that record to match
# the certificate they just installed: it proves nginx accepted and serves it, without any access to the host.

served_fingerprint() {
  cat "${CERTBOT_DATA}/.served-fingerprint" 2>/dev/null || true
}

# wait_served <fingerprint>: succeed once nginx reports serving it, fail after AI_STAND_NGINX_WAIT seconds.
wait_served() {
  local want="$1" waited=0
  local limit="${AI_STAND_NGINX_WAIT:-90}" step="${AI_STAND_NGINX_POLL:-2}"
  while [ "$(served_fingerprint)" != "$want" ]; do
    [ "$waited" -lt "$limit" ] || return 1
    sleep "$step"
    waited=$((waited + step))
  done
}

# lineage_fingerprint <live-dir>: SHA-256 fingerprint of the leaf certificate, in the form served_fingerprint reports.
lineage_fingerprint() {
  openssl x509 -in "$1/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}
