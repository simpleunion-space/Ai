#!/usr/bin/env bash
# Tests renew.sh and receive-cert.sh without Docker, a network or nginx: `docker` and `curl` are stubs, and a
# background loop plays the host's nginx-reload unit (it records the fingerprint of the certificate "nginx" serves
# unless the node is marked broken). Needs root and openssl (receive-cert.sh chowns), e.g.:
#   sudo bash certbot/test-certbot-scripts.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
bg_pids=""
trap 'for p in $bg_pids; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
fails() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }

D=test.example
TOKEN=test-token-0123456789abcdef
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
# stand-in for the peer's cert-receiver: records the call and its Authorization header file, then pipes the
# request body straight into receive-cert.sh on the "other node"
echo "curl $*" >> "$STUB_DIR/calls"
while [ $# -gt 0 ]; do
  case "$1" in -H) shift; case "$1" in @*) cat "${1#@}" >> "$STUB_DIR/curl-headers" ;; esac ;; esac
  shift
done
[ -e "$STUB_DIR/peer-down" ] && exit 22
AI_STAND_CERTBOT_CONF="$STUB_DIR/peer.conf" exec bash "$STUB_DIR/receive-cert.sh"
EOF
cat > "$BIN/docker" <<'EOF'
#!/bin/sh
# stand-in for certbot: record the arguments; "renew"/"--issue" replaces the lineage with a fresh certificate
echo "docker $*" >> "$STUB_DIR/calls"
case " $* " in *" --dry-run "*) exit 0 ;; esac
if [ -e "$STUB_DIR/renew-fails" ]; then exit 1; fi
if [ -d "$STUB_DIR/next" ]; then
  rm -rf "$STUB_DIR/own/archive/$LINEAGE" "$STUB_DIR/own/live/$LINEAGE"
  cp -a "$STUB_DIR/next/archive/$LINEAGE" "$STUB_DIR/own/archive/$LINEAGE"
  cp -a "$STUB_DIR/next/live/$LINEAGE" "$STUB_DIR/own/live/$LINEAGE"
fi
exit 0
EOF
chmod +x "$BIN"/*
export STUB_DIR="$T" LINEAGE="$D" PATH="$BIN:$PATH" AI_STAND_NGINX_WAIT=3 AI_STAND_NGINX_POLL=1
cp "$HERE/receive-cert.sh" "$HERE/served.sh" "$T/"

# The host's reload unit: while the node is not marked broken, nginx "serves" whatever live/<domain>/fullchain.pem holds.
start_host() { # <certbot data dir> <flag file that makes this node reject certificates>
  (
    while :; do
      if [ ! -e "$2" ] && [ -r "$1/live/$D/fullchain.pem" ]; then
        openssl x509 -in "$1/live/$D/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 > "$1/.served-fingerprint.tmp" \
          && mv -f "$1/.served-fingerprint.tmp" "$1/.served-fingerprint"
      fi
      sleep 0.2
    done
  ) &
  bg_pids="$bg_pids $!"
}

# a throw-away CA stands in for Let's Encrypt; the receiver is pointed at it through CERTBOT_TRUST_STORE
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=test-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$T/ca.key" -out "$T/ca.pem" >/dev/null 2>&1

# make_lineage <root> <days> <san-list> [wrong-key|selfsigned]
make_lineage() {
  local root="$1" days="$2" san="$3" mode="${4:-}" dir
  dir="$root/archive/$D"; mkdir -p "$dir" "$root/live/$D"
  if [ "$mode" = selfsigned ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days "$days" -subj "/CN=$D" \
      -addext "subjectAltName=$san" -keyout "$dir/privkey1.pem" -out "$dir/cert1.pem" >/dev/null 2>&1
    cp "$dir/cert1.pem" "$dir/chain1.pem"
  else
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$D" \
      -keyout "$dir/privkey1.pem" -out "$dir/leaf.csr" >/dev/null 2>&1
    printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "$dir/leaf.ext"
    openssl x509 -req -in "$dir/leaf.csr" -CA "$T/ca.pem" -CAkey "$T/ca.key" -CAcreateserial -days "$days" \
      -extfile "$dir/leaf.ext" -out "$dir/cert1.pem" >/dev/null 2>&1
    rm -f "$dir/leaf.csr" "$dir/leaf.ext"
    cp "$T/ca.pem" "$dir/chain1.pem"
  fi
  cat "$dir/cert1.pem" "$dir/chain1.pem" > "$dir/fullchain1.pem"
  [ "$mode" = wrong-key ] && openssl ecparam -name prime256v1 -genkey -noout -out "$dir/privkey1.pem" >/dev/null 2>&1
  for f in cert chain fullchain privkey; do ln -s "../../archive/$D/${f}1.pem" "$root/live/$D/$f.pem"; done
}
stream() { tar -C "$1" -cf - "archive/$D" "live/$D"; }

OWN="$T/own"; PEER="$T/peer"; mkdir -p "$OWN" "$PEER"
STD_SAN="DNS:$D,DNS:*.$D"
printf '%s\n' "$TOKEN" > "$T/token"
cat > "$T/peer.conf" <<EOF
CERT_DOMAIN=$D
CERTBOT_DATA=$PEER
CERTBOT_TRUST_STORE=$T/ca.pem
EOF
cat > "$T/own.conf" <<EOF
CERT_DOMAIN=$D
CERTBOT_IMAGE=certbot/certbot:test
CERTBOT_EMAIL=test@example.invalid
CERTBOT_DATA=$OWN
CERTBOT_HOOK_DIR=$T/hooks
CERTBOT_CREDENTIALS=$T/credentials
CERTBOT_AUTH_HOOK="python3 /hooks/h.py auth"
CERTBOT_CLEANUP_HOOK="python3 /hooks/h.py cleanup"
CERTBOT_STATE_DIR=$T/state
CERTBOT_PEER_URL=http://cert-receiver.invalid:8443
CERTBOT_PEER_TOKEN_FILE=$T/token
EOF
start_host "$PEER" "$T/nginx-broken-peer"
start_host "$OWN" "$T/nginx-broken-own"
recv() { AI_STAND_CERTBOT_CONF="$T/peer.conf" bash "$HERE/receive-cert.sh"; }
renew() { AI_STAND_CERTBOT_CONF="$T/own.conf" bash "$HERE/renew.sh" "$@"; }
fp() { openssl x509 -in "$1/live/$D/fullchain.pem" -noout -fingerprint -sha256; }
fpq() { fp "$1" | cut -d= -f2; }

echo "== receive-cert.sh"
make_lineage "$T/good" 90 "$STD_SAN"
check "valid stream is activated" bash -c "$(declare -f stream); D=$D; stream $T/good | AI_STAND_CERTBOT_CONF=$T/peer.conf bash $HERE/receive-cert.sh"
check "peer serves the new certificate" test "$(fp "$T/good")" = "$(fp "$PEER")"
check "nginx on the peer reported serving it" test "$(cat "$PEER/.served-fingerprint")" = "$(fpq "$T/good")"
check "peer files are readable through the links" test -r "$PEER/live/$D/privkey.pem"

make_lineage "$T/next1" 90 "$STD_SAN"
before="$(fp "$PEER")"
bash -c "$(declare -f stream); D=$D; stream $T/next1 | AI_STAND_CERTBOT_CONF=$T/peer.conf bash $HERE/receive-cert.sh" >/dev/null 2>&1
check "second activation replaces the first" test "$(fp "$T/next1")" = "$(fp "$PEER")"
check "only one previous lineage is kept" test "$(ls -1d "$PEER"/archive/.$D.before-* | wc -l)" = 1

reject() { # name, mutation of a lineage root created with the given arguments
  local name="$1"; shift
  local root="$T/rej-$RANDOM"; make_lineage "$root" "$@"
  local keep; keep="$(fp "$PEER")"
  if stream "$root" | recv >/dev/null 2>&1; then bad "$name"; else
    [ "$(fp "$PEER")" = "$keep" ] && ok "$name" || bad "$name (peer changed)"; fi
}
reject "short validity is refused" 10 "$STD_SAN"
reject "missing wildcard SAN is refused" 90 "DNS:$D"
reject "mismatched key is refused" 90 "$STD_SAN" wrong-key
reject "self-signed certificate is refused" 90 "$STD_SAN" selfsigned

evil="$T/evil"; mkdir -p "$evil/archive/$D" "$evil/live/$D"; echo x > "$evil/archive/$D/..x"
fails "dot-leading member is refused" bash -c "tar -C $evil -cf - archive/$D live/$D | AI_STAND_CERTBOT_CONF=$T/peer.conf bash $HERE/receive-cert.sh"
esc="$T/esc"; make_lineage "$esc" 90 "$STD_SAN"; rm "$esc/live/$D/privkey.pem"; ln -s "../../../../../etc/passwd" "$esc/live/$D/privkey.pem"
fails "link leaving the lineage is refused" bash -c "$(declare -f stream); D=$D; stream $esc | AI_STAND_CERTBOT_CONF=$T/peer.conf bash $HERE/receive-cert.sh"
mkdir -p "$T/other/etc"; echo x > "$T/other/etc/file"
fails "foreign path is refused" bash -c "tar -C $T/other -cf - etc | AI_STAND_CERTBOT_CONF=$T/peer.conf bash $HERE/receive-cert.sh"
hl="$T/hl"; make_lineage "$hl" 90 "$STD_SAN"; ln "$hl/archive/$D/cert1.pem" "$hl/archive/$D/hard.pem"
fails "hard link is refused" bash -c "$(declare -f stream); D=$D; stream $hl | AI_STAND_CERTBOT_CONF=$T/peer.conf bash $HERE/receive-cert.sh"

keep="$(fp "$PEER")"; make_lineage "$T/nginxbad" 90 "$STD_SAN"; touch "$T/nginx-broken-peer"
fails "nginx not serving the certificate fails the receive" bash -c "$(declare -f stream); D=$D; stream $T/nginxbad | AI_STAND_CERTBOT_CONF=$T/peer.conf AI_STAND_NGINX_WAIT=3 AI_STAND_NGINX_POLL=1 bash $HERE/receive-cert.sh"
rm -f "$T/nginx-broken-peer"
check "...and the previous certificate is restored" test "$(fp "$PEER")" = "$keep"

echo "== renew.sh"
mkdir -p "$T/hooks" "$T/state"
make_lineage "$OWN" 90 "$STD_SAN"
: > "$T/calls"
rm -f "$T/credentials"
check "no credentials, certificate fine: inactive but ok" renew
rm -rf "$OWN"/archive "$OWN"/live; make_lineage "$OWN" 10 "$STD_SAN"
fails "no credentials and expiry near: loud failure" renew
echo "SELECTEL_USER=x" > "$T/credentials"; chmod 600 "$T/credentials"
check "dry run passes --dry-run and changes nothing" renew --dry-run
check "dry run never distributes" bash -c "! grep -q '^curl' $T/calls"
grep -q -- "--env-file $T/credentials" "$T/calls" && ok "credentials go through --env-file" || bad "credentials go through --env-file"
grep -q -- "--manual-auth-hook" "$T/calls" && ok "configured hooks are passed" || bad "configured hooks are passed"
: > "$T/calls"; : > "$T/curl-headers"
make_lineage "$T/next" 90 "$STD_SAN"
check "renewal with a new certificate succeeds" renew
check "own node got the new certificate" test "$(fp "$T/next")" = "$(fp "$OWN")"
check "own nginx reported serving it" test "$(cat "$OWN/.served-fingerprint")" = "$(fpq "$T/next")"
check "peer got the new certificate" test "$(fp "$T/next")" = "$(fp "$PEER")"
check "distribution marker written" test "$(cat "$T/state/distributed.sha256")" = "$(fpq "$OWN")"
check "the bearer token reached curl through a header file" grep -q "^Authorization: Bearer $TOKEN\$" "$T/curl-headers"
check "...and never through an argv" bash -c "! grep -q '$TOKEN' $T/calls"
check "the hand-over goes to the configured URL" grep -q "http://cert-receiver.invalid:8443/v1/certificate" "$T/calls"
: > "$T/calls"
check "a second run changes nothing" renew
check "...and does not hand over again" bash -c "! grep -q '^curl' $T/calls"
rm -rf "$T/next"; make_lineage "$T/next" 90 "$STD_SAN"; touch "$T/peer-down"; : > "$T/calls"
fails "peer unreachable: the job fails" renew --issue --force
check "...but this node already serves the new certificate" test "$(fp "$T/next")" = "$(fp "$OWN")"
rm -f "$T/peer-down"
check "next run retries the hand-over" renew
check "...and the peer is current again" test "$(fp "$OWN")" = "$(fp "$PEER")"
rm -rf "$T/next"; touch "$T/renew-fails"
fails "certbot failing fails the job" renew
rm -f "$T/renew-fails"
rm -rf "$T/next"; make_lineage "$T/next" 90 "DNS:$D"
fails "new certificate without the wildcard is not rolled out" renew --issue --force
rm -rf "$T/next"
# an own node whose nginx does not serve the new certificate must not push it to the peer
make_lineage "$T/next" 90 "$STD_SAN"; touch "$T/nginx-broken-own"; : > "$T/calls"
keep="$(fp "$PEER")"
fails "own nginx not serving: the job fails" renew --issue --force
check "...and nothing was handed to the peer" bash -c "! grep -q '^curl' $T/calls"
check "...so the peer keeps its certificate" test "$(fp "$PEER")" = "$keep"
rm -f "$T/nginx-broken-own"; rm -rf "$T/next"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
