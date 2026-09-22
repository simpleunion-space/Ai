FROM node:22-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# The task shipped with this benchmark targets a Debian-family system and
# needs a real Ansible runtime for an agent to validate its result. The image
# deliberately contains no Docker client or socket.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ansible \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        sudo

RUN curl --fail --silent --show-error --location https://opencode.ai/v2/install --output /tmp/install-opencode \
    && OPENCODE_INSTALL_DIR=/usr/local/bin bash /tmp/install-opencode --no-modify-path \
    && install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && rm -rf /root/.opencode \
    && rm -f /tmp/install-opencode \
    && opencode --version

RUN npm install --global \
        @charmland/crush@latest \
        @kilocode/cli@latest

RUN crush --version \
    && kilo --version \
    && ansible-playbook --version \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY scripts/ /app/scripts/

ENTRYPOINT ["node", "/app/scripts/run-benchmark.mjs"]
