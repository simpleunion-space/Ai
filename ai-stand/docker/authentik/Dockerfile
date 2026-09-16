# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.08.07-1
ARG AUTHENTIK_VERSION=2026.8.1

FROM ghcr.io/goauthentik/server:${AUTHENTIK_VERSION} AS authentik-upstream

FROM ${BASE_IMAGE} AS authentik

COPY --from=authentik-upstream / /
COPY --chmod=0755 docker/base/entrypoint.sh /usr/local/bin/ai-entrypoint.sh

RUN existing_group="$(getent group 1000 | cut -d: -f1)" \
    && if [ -n "$existing_group" ] && [ "$existing_group" != ai ]; then \
        groupmod --new-name ai "$existing_group"; \
    elif [ -z "$existing_group" ]; then \
        groupadd --gid 1000 ai; \
    fi \
    && existing_user="$(getent passwd 1000 | cut -d: -f1)" \
    && if [ -n "$existing_user" ] && [ "$existing_user" != ai ]; then \
        if [ -d /home/ai ]; then \
            usermod --login ai --home /home/ai --shell /bin/bash "$existing_user"; \
        else \
            usermod --login ai --home /home/ai --move-home --shell /bin/bash "$existing_user"; \
        fi; \
    elif [ -z "$existing_user" ]; then \
        useradd \
            --uid 1000 \
            --gid 1000 \
            --create-home \
            --shell /bin/bash \
            ai; \
    fi

# authentik 2026.5+'s /lifecycle/ak references the literal Linux account "authentik" in three
# places once it detects it's running as root (Docker HEALTHCHECK always execs as the image's
# configured user - root here, since this image never sets USER - even though the main process
# already dropped to "ai" via gosu): `chown authentik:authentik` for /data, /certs and the
# Prometheus multiproc dir; `usermod -a -G "$DOCKER_GID" authentik`; and
# `setpriv --reuid authentik --regid authentik ... env HOME=/authentik`. This image renames that
# account to "ai" (see the useradd/usermod block above), so all three fail with "invalid user" /
# "failed to parse reuid", which is exactly why `ak healthcheck` was failing. Since the
# entrypoint's usermod always keeps "ai" mapped to IM_UID/IM_GID at runtime, rewriting every
# hardcoded reference to "ai" (and the bogus /authentik HOME to the real /home/ai) keeps these
# targeting the correct, remapped identity.
RUN sed -i \
    -e 's#>/dev/stderr#>\&2#g' \
    -e 's#authentik:authentik#ai:ai#g' \
    -e 's#"\${DOCKER_GID}" authentik#"${DOCKER_GID}" ai#g' \
    -e 's#--reuid authentik --regid authentik#--reuid ai --regid ai#g' \
    -e 's#HOME=/authentik #HOME=/home/ai #g' \
    /lifecycle/ak

ENV PATH=/lifecycle:/ak-root/.venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    VENV_PATH=/ak-root/.venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NATIVE_TLS=1 \
    UV_PYTHON_DOWNLOADS=0 \
    GIT_BUILD_HASH= \
    TMPDIR=/dev/shm/ \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    GOFIPS=1 \
    IM_TZ=Europe/Moscow \
    IM_UID=1000 \
    IM_GID=1000

WORKDIR /

EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/ai-entrypoint.sh"]
CMD ["ak", "server"]


FROM ${BASE_IMAGE} AS node-base

ARG NODE_VERSION=24.20.0

COPY --chmod=0755 docker/lib/install-node.sh /tmp/install-node.sh
RUN /tmp/install-node.sh "$NODE_VERSION" && rm -f /tmp/install-node.sh


FROM node-base AS authentik-configurator

RUN install -d --owner=ai --group=ai --mode=0755 /opt/authentik-configurator

COPY --chown=ai:ai --chmod=0755 docker/authentik/configure.mjs /opt/authentik-configurator/configure.mjs

# Defaults below cover only the vars needed to start; the full set
# configure.mjs actually requires (METAMCP/AGENTGATEWAY urls and
# client secrets included) has no image-level default at all - apply.sh's
# cmd_configure_authentik() always passes every one of them explicitly via
# `docker run --env`, so this image is not meant to run standalone without
# that wrapper.
ENV AUTHENTIK_BASE_URL=http://authentik:9000 \
    AUTHENTIK_PUBLIC_URL=https://authentik.local \
    AUTHENTIK_BOOTSTRAP_USERNAME=akadmin \
    AUTHENTIK_OPENWEBUI_URL=https://openwebui.local \
    AUTHENTIK_PORTAINER_URL=https://portainer.local

CMD ["node", "/opt/authentik-configurator/configure.mjs"]
