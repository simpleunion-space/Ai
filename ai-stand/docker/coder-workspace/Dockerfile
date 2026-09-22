# This image is NOT built by cmd_images/docker_cmd build like every other
# docker/<name>/Dockerfile in this repo - see ensure_coder_workspace_image()
# in apply.sh, which builds it the same way ensure_openclaw_sandbox_image()
# builds docker/openclaw-sandbox/Dockerfile: by piping this file's raw text
# into `docker build -t ... -` against Coder's own dedicated rootless Docker
# daemon (the daemon workspaces themselves are created on, not the main
# Swarm engine - a workspace container must already exist in that daemon's
# local image store, since it has no route to any registry mirror other
# than the public internet). No build context is available this way (stdin
# carries only this file, not a tar), so this Dockerfile deliberately has no
# COPY/ADD - everything is a RUN step, same constraint and same reasoning as
# docker/openclaw-sandbox/Dockerfile.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --yes --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    less \
    python3 \
    python3-pip \
    python3-venv \
    sudo \
    unzip \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Node.js: same pinned-tarball approach as docker/lib/install-node.sh (not
# reused directly - this image has no build context to COPY it in, see the
# header comment above), same version and checksum for consistency with the
# rest of this repo.
RUN node_version=24.20.0 \
    && node_archive="node-v${node_version}-linux-x64.tar.xz" \
    && curl --fail --location --proto '=https' --show-error --silent --tlsv1.2 \
        "https://nodejs.org/dist/v${node_version}/${node_archive}" --output "/tmp/${node_archive}" \
    && printf '%s  /tmp/%s\n' "2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2" "$node_archive" | sha256sum --check --strict - \
    && tar --extract --file "/tmp/${node_archive}" --directory /usr/local --strip-components 1 \
    && rm -f "/tmp/${node_archive}" \
    && node --version && npm --version

# .NET 10 SDK via Microsoft's own apt repository (GPG-signed packages - the
# same trust model this repo already relies on for the AMD ROCm apt repo in
# docker/lmstudio/Dockerfile, rather than pinning an individual .deb hash).
RUN curl --fail --location --proto '=https' --show-error --silent --tlsv1.2 \
        --output /tmp/packages-microsoft-prod.deb \
        https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm -f /tmp/packages-microsoft-prod.deb \
    && apt-get update && apt-get install --yes --no-install-recommends dotnet-sdk-10.0 \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI only (no daemon, no dockerd) - this workspace talks to the
# already-running dedicated rootless daemon over the socket
# docker_container.workspace bind-mounts in, same sibling-container pattern
# openclaw-gateway already uses against openclaw-sandbox-dind.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl --fail --location --proto '=https' --show-error --silent --tlsv1.2 \
        https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --output /etc/apt/keyrings/docker.gpg \
    && printf '%s\n' \
        "Types: deb" \
        "URIs: https://download.docker.com/linux/ubuntu" \
        "Suites: noble" \
        "Components: stable" \
        "Architectures: amd64" \
        "Signed-By: /etc/apt/keyrings/docker.gpg" \
        > /etc/apt/sources.list.d/docker.sources \
    && apt-get update && apt-get install --yes --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# code-server: the standard Coder browser-IDE pattern for a Docker-based
# template (see coder_app "code-server" in the Terraform template next to
# this file).
RUN curl -fsSL https://code-server.dev/install.sh | sh

# No --uid pin: ubuntu:24.04 already ships a default "ubuntu" user at UID
# 1000 (confirmed live 2026-09-23 - useradd --uid 1000 fails outright with
# "UID 1000 is not unique"), and nothing outside this image cares which
# numeric UID "coder" gets - the Terraform template selects the container
# user by name (user = "coder" in docker_container.workspace), never by
# number.
RUN useradd --create-home --shell /bin/bash coder \
    && echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder \
    && chmod 0440 /etc/sudoers.d/coder

USER coder
WORKDIR /home/coder
ENV PATH="/home/coder/.dotnet/tools:${PATH}"
CMD ["sleep", "infinity"]
