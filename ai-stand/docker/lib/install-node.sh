#!/bin/sh
set -eu

node_version="${1:?NODE_VERSION is required}"
node_archive="node-v${node_version}-linux-x64.tar.xz"

curl \
    --fail \
    --location \
    --proto '=https' \
    --show-error \
    --silent \
    --tlsv1.2 \
    "https://nodejs.org/dist/v${node_version}/${node_archive}" \
    --output "/tmp/${node_archive}"

# Every Dockerfile calling this script currently pins NODE_VERSION to the
# same 24.20.0 - hardcode ITS hash (fetched directly from nodejs.org
# 2026-09-13, cross-checked against the published Content-Length) rather
# than re-trusting a checksum file fetched from that same origin on every
# build, same reasoning as the pinned lmstudio install.sh hash
# (docker/lmstudio/Dockerfile) and the fixed-URL VC++ Redistributables in
# software/resolve.ps1. A version bump not yet in this map falls back to
# the old live-fetched-checksum behavior (still real verification, just
# against the same origin as the file) rather than failing the build -
# update pinned_sha256 by hand when bumping NODE_VERSION.
pinned_sha256=""
case "$node_version" in
    24.20.0)
        pinned_sha256="2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2"
        ;;
esac

if [ -n "$pinned_sha256" ]; then
    printf '%s  /tmp/%s\n' "$pinned_sha256" "$node_archive" | sha256sum --check --strict -
else
    echo "WARN: no hardcoded checksum pinned for Node.js ${node_version}; falling back to nodejs.org's own SHASUMS256.txt (update pinned_sha256 in install-node.sh)" >&2
    curl \
        --fail \
        --location \
        --proto '=https' \
        --show-error \
        --silent \
        --tlsv1.2 \
        "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" \
        --output /tmp/SHASUMS256.txt

    grep " ${node_archive}$" /tmp/SHASUMS256.txt \
        | sed "s#  ${node_archive}#  /tmp/${node_archive}#" \
        | sha256sum --check --strict -
fi

tar --extract \
    --file "/tmp/${node_archive}" \
    --directory /usr/local \
    --strip-components 1

rm -f "/tmp/${node_archive}" /tmp/SHASUMS256.txt

node --version
npm --version
