# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        gzip \
        jq \
        libatomic1 \
        libgomp1 \
        openssl \
        passwd \
        procps \
        rsync \
        tar \
        tini \
        tzdata \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN existing_group="$(getent group 1000 | cut -d: -f1)" \
    && if [ -n "$existing_group" ] && [ "$existing_group" != ai ]; then \
        groupmod --new-name ai "$existing_group"; \
    elif [ -z "$existing_group" ]; then \
        groupadd --gid 1000 ai; \
    fi \
    && existing_user="$(getent passwd 1000 | cut -d: -f1)" \
    && if [ -n "$existing_user" ] && [ "$existing_user" != ai ]; then \
        usermod --login ai --home /home/ai --move-home --shell /bin/bash "$existing_user"; \
    elif [ -z "$existing_user" ]; then \
        useradd \
            --uid 1000 \
            --gid 1000 \
            --create-home \
            --shell /bin/bash \
            ai; \
    fi

COPY --chmod=0755 docker/base/entrypoint.sh /usr/local/bin/ai-entrypoint.sh

ENV HOME=/home/ai \
    PATH=/home/ai/.local/bin:/home/ai/.lmstudio/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    IM_UID=1000 \
    IM_GID=1000 \
    IM_TZ=Europe/Moscow

WORKDIR /home/ai

ENTRYPOINT ["/usr/local/bin/ai-entrypoint.sh"]
