# This image is NOT built by cmd_images/docker_cmd build like every other
# docker/<name>/Dockerfile in this repo - see ensure_openclaw_sandbox_image()
# in apply.sh, which builds it by piping this file's content over
# `docker exec -i ai-stand-openclaw-sandbox-dind docker build -t
# openclaw-sandbox:bookworm-slim -` (stdin only, no COPY/ADD, so no build
# context is needed and none is provided).
#
# Why this file has to exist at all: OpenClaw's Docker sandbox backend
# (agents.defaults.sandbox.backend=docker, see docker/openclaw/init.mjs)
# refuses to start any sandboxed session until an image named exactly
# openclaw-sandbox:bookworm-slim already exists in whatever daemon
# DOCKER_HOST points at (here: the openclaw-sandbox-dind sidecar) - it does
# NOT fall back to a plain debian:bookworm-slim image. Confirmed via
# OpenClaw's own bundled docs, read live from inside the running
# openclaw-gateway container at
# /usr/local/lib/node_modules/openclaw/docs/gateway/sandboxing.md, and via
# the runtime error it fails with otherwise: "Sandbox image not found:
# openclaw-sandbox:bookworm-slim. Build it with scripts/sandbox-setup.sh
# before enabling Docker sandboxing. The default image includes python3 for
# sandbox write/edit helpers; OpenClaw will not substitute plain debian:...".
#
# scripts/sandbox-setup.sh (that docs' own "easy" build helper) is explicitly
# source-checkout-only and is never shipped in the npm package - our
# docker/openclaw/Dockerfile installs OpenClaw via
# `npm install --global --omit=dev "openclaw@${OPENCLAW_VERSION}"`, so we
# never have that script and never will. The content below is instead that
# same docs' official npm-install fallback recipe, copied verbatim - do not
# "improve" it independently. It MUST stay in sync with whatever OpenClaw's
# own sandbox backend actually expects of openclaw-sandbox:bookworm-slim for
# whatever OPENCLAW_VERSION docker/openclaw/Dockerfile currently pins -
# re-check docs/gateway/sandboxing.md inside the openclaw-gateway container
# (or upstream OpenClaw release notes) whenever OPENCLAW_VERSION changes, and
# update this file to match rather than assuming it's still accurate.
# python3 in particular is called out by the docs as load-bearing (OpenClaw's
# own sandbox write/edit helpers depend on it), not an extra we added.
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash ca-certificates curl git jq python3 ripgrep \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
