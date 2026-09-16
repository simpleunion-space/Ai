# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.08.07-1
FROM ${BASE_IMAGE} AS node-base

ARG NODE_VERSION=24.20.0

ENV IM_TZ=Europe/Moscow \
    IM_UID=1000 \
    IM_GID=1000

COPY --chmod=0755 docker/lib/install-node.sh /tmp/install-node.sh
RUN /tmp/install-node.sh "$NODE_VERSION" && rm -f /tmp/install-node.sh


FROM node-base AS lmstudio-proxy

RUN install -d --owner=ai --group=ai --mode=0755 /opt/lmstudio-proxy

COPY --chown=ai:ai --chmod=0644 docker/lmstudio-proxy/server.mjs /opt/lmstudio-proxy/server.mjs

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    LMSTUDIO_PROXY_HOST=0.0.0.0 \
    LMSTUDIO_PROXY_PORT=11234 \
    LMSTUDIO_PROXY_UPSTREAM_BASE_URL=http://lmstudio:1234/v1 \
    LMSTUDIO_PROXY_DEBUG=0

EXPOSE 11234

CMD ["node", "/opt/lmstudio-proxy/server.mjs"]
