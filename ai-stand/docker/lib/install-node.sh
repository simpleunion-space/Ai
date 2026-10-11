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
# same 24.21.0 - hardcode ITS hash (fetched directly from nodejs.org
# 2026-10-13) rather
# than re-trusting a checksum file fetched from that same origin on every
# build. Unknown versions fail closed until their archive checksum is reviewed.
pinned_sha256=""
case "$node_version" in
    24.20.0)
        pinned_sha256="2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2"
        ;;
    24.21.0)
        pinned_sha256="fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6"
        ;;
    *) echo "Unreviewed Node.js version: ${node_version}" >&2; exit 1 ;;
esac

printf '%s  /tmp/%s\n' "$pinned_sha256" "$node_archive" | sha256sum --check --strict -

tar --extract \
    --file "/tmp/${node_archive}" \
    --directory /usr/local \
    --strip-components 1

rm -f "/tmp/${node_archive}" /tmp/SHASUMS256.txt

node --version
npm --version
