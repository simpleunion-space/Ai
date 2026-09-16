# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.08.07-1
# Must be declared before this file's first FROM to resolve in the
# docker-cli stage's own FROM below - confirmed live that an ARG declared
# immediately before a LATER FROM (i.e. after some earlier FROM has already
# occurred in the file) is NOT treated as global for image-reference
# resolution, even though textually it looks identical to this one.
ARG DOCKER_CLI_VERSION=29.8.0
FROM ${BASE_IMAGE} AS node-base

ARG NODE_VERSION=24.20.0

ENV IM_TZ=Europe/Moscow \
    IM_UID=1000 \
    IM_GID=1000

COPY --chmod=0755 docker/lib/install-node.sh /tmp/install-node.sh
RUN /tmp/install-node.sh "$NODE_VERSION" && rm -f /tmp/install-node.sh


# Named stage, not an inline COPY --from=docker:${DOCKER_CLI_VERSION}-cli:
# BuildKit does not expand ARGs inside a COPY --from=<external-image>
# reference (confirmed live - it fails with `failed to parse stage name
# "docker:${DOCKER_CLI_VERSION}-cli": invalid reference format` regardless of
# where the ARG is declared). ARG substitution IS reliable in a FROM line
# (see BASE_IMAGE above), so resolve the version there and reference this
# stage by its fixed name instead.
FROM docker:${DOCKER_CLI_VERSION}-cli AS docker-cli


FROM node-base AS openclaw

ARG OPENCLAW_VERSION=2026.9.4

RUN apt-get update \
    && apt-get install --yes --no-install-recommends git \
    && npm install --global --omit=dev "openclaw@${OPENCLAW_VERSION}" \
    && npm cache clean --force \
    && test "$(node --print 'require("/usr/local/lib/node_modules/openclaw/package.json").version')" = "${OPENCLAW_VERSION}" \
    && openclaw --version \
    && install -d --owner=ai --group=ai --mode=0755 /opt/openclaw \
    && rm -rf /var/lib/apt/lists/*

# Sandbox mode (agents.defaults.sandbox.backend=docker, see init.mjs) shells
# out to a `docker` CLI subprocess against openclaw-sandbox-dind over
# DOCKER_HOST - it needs the client binary on PATH, not just network
# reachability. Pull only the static, dependency-free CLI from Docker's
# official image (docker-cli stage above): no daemon, no extra apt repo/GPG key.
COPY --from=docker-cli --chmod=0755 /usr/local/bin/docker /usr/local/bin/docker

COPY --chown=ai:ai --chmod=0644 docker/openclaw/init.mjs /opt/openclaw/init.mjs
COPY --chmod=0755 docker/openclaw/entrypoint.sh /usr/local/bin/openclaw-gateway-entrypoint.sh

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    OPENCLAW_HOME=/home/ai \
    OPENCLAW_STATE_DIR=/home/ai/.openclaw \
    OPENCLAW_CONFIG_PATH=/home/ai/.openclaw/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=/home/ai/.openclaw/workspace

EXPOSE 18789

CMD ["/usr/local/bin/openclaw-gateway-entrypoint.sh"]
