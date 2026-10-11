# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.10.13-1
FROM ${BASE_IMAGE} AS node-base

ARG NODE_VERSION=24.21.0

ENV IM_TZ=UTC \
    IM_UID=1000 \
    IM_GID=1000

COPY --chmod=0755 docker/lib/install-node.sh /tmp/install-node.sh
RUN /tmp/install-node.sh "$NODE_VERSION" && rm -f /tmp/install-node.sh


FROM node-base AS openclaw

ARG OPENCLAW_VERSION=2026.10.2

COPY --chmod=0755 docker/openclaw/patch-worker-artifact.py /tmp/patch-worker-artifact.py
COPY --chmod=0755 docker/openclaw/install-subscription-cli.py /tmp/install-subscription-cli.py

# The Docker sandbox backend invokes the Docker CLI against DOCKER_HOST.
# Ubuntu's docker.io package supplies that CLI but no daemon is started in
# this image; compose.yaml supplies a private socket-proxy endpoint and never
# mounts /var/run/docker.sock here.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends docker.io git openssh-client python3 \
    && npm pack --ignore-scripts --pack-destination /tmp "openclaw@${OPENCLAW_VERSION}" \
    && python3 /tmp/install-subscription-cli.py --verify-openclaw /tmp/openclaw-2026.10.2.tgz \
    && npm install --global --omit=dev /tmp/openclaw-2026.10.2.tgz \
    && python3 /tmp/patch-worker-artifact.py /usr/local/lib/node_modules/openclaw \
    && python3 /tmp/install-subscription-cli.py \
    && ln -s /opt/openclaw/subscription-cli/claude/2.1.296/claude /usr/local/bin/claude \
    && rm -f /tmp/patch-worker-artifact.py /tmp/install-subscription-cli.py /tmp/openclaw-2026.10.2.tgz \
    && npm cache clean --force \
    && test "$(node --print 'require("/usr/local/lib/node_modules/openclaw/package.json").version')" = "${OPENCLAW_VERSION}" \
    && openclaw --version \
    && install -d --owner=root --group=root --mode=0755 /opt/openclaw \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=ai:ai --chmod=0644 docker/openclaw/init.mjs /opt/openclaw/init.mjs
COPY --chown=ai:ai --chmod=0644 docker/openclaw/subscription-models.mjs docker/openclaw/subscription-models.json /opt/openclaw/
COPY --chmod=0755 docker/openclaw/migrate-subscription-selections.mjs /opt/openclaw/migrate-subscription-selections.mjs
COPY --chmod=0755 docker/openclaw/root-prestart.sh /usr/local/bin/openclaw-root-prestart.sh
COPY --chmod=0755 docker/openclaw/entrypoint.sh /usr/local/bin/openclaw-gateway-entrypoint.sh
COPY --chmod=0755 docker/openclaw/verify-subscription-cli.sh /usr/local/bin/openclaw-verify-subscription-cli.sh

# Git over SSH with the dedicated key that docker/ssh-key-delivery delivers from Authentik and compose.yaml mounts
# read-only at /run/ai-stand/ssh. ssh skips an identity file that does not exist; accept-new records a host key on first
# contact in the persistent home instead of failing a non-interactive agent on the prompt.
RUN printf '%s\n' \
        '# Managed by ai-stand (docker/openclaw/Dockerfile).' \
        'Host *' \
        '  IdentityFile /run/ai-stand/ssh/id_ed25519' \
        '  StrictHostKeyChecking accept-new' \
        > /etc/ssh/ssh_config.d/50-ai-stand.conf

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    OPENCLAW_HOME=/home/ai \
    OPENCLAW_STATE_DIR=/home/ai/.openclaw \
    OPENCLAW_CONFIG_PATH=/home/ai/.openclaw/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=/home/ai/.openclaw/workspace \
    OPENCLAW_CODEX_APP_SERVER_BIN=/opt/openclaw/subscription-cli/codex/0.162.1/vendor/x86_64-unknown-linux-musl/bin/codex \
    DISABLE_AUTOUPDATER=1 \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:/home/ai/.local/bin \
    AI_ROOT_PRESTART=/usr/local/bin/openclaw-root-prestart.sh

EXPOSE 18789

CMD ["/usr/local/bin/openclaw-gateway-entrypoint.sh"]
