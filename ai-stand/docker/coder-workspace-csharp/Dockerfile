FROM mcr.microsoft.com/dotnet/sdk:10.0.401-noble AS dotnet-sdk-source

FROM ubuntu:26.04

ARG CODE_SERVER_VERSION=4.141.0
# Official GitHub release asset: code-server_4.141.0_amd64.deb.
ARG CODE_SERVER_SHA256=f384beb4f3ba207e0bca27d0dbd36dd825d5aa909d78c6d4baa8703eaf6b77ba

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

RUN printf '%s\n' \
        '#!/bin/sh' \
        'set -eu' \
        'attempt=1' \
        'while :; do' \
        '  # Host-network BuildKit cannot provide the host DNS stub to the _apt user.' \
        '  # This helper is used only while building this trusted template image.' \
        '  if apt-get -o APT::Sandbox::User=root update && apt-get -o APT::Sandbox::User=root install --yes --no-install-recommends "$@"; then exit 0; fi' \
        '  [ "$attempt" -ge 4 ] && exit 1' \
        '  rm -rf /var/lib/apt/lists/*' \
        '  sleep $((attempt * 5))' \
        '  attempt=$((attempt + 1))' \
        'done' \
        > /usr/local/sbin/apt-install-retry \
    && chmod 0755 /usr/local/sbin/apt-install-retry

RUN apt-install-retry \
        ca-certificates \
        curl \
        git \
        iproute2 \
        less \
        procps \
        openssh-client \
        python3 \
        tini \
        unzip \
        vim \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 26.04 packages supply the distro-compatible native runtime deps.
# Its SDK package uses another feature band; copy the exact official SDK
# tree rather than accepting a mutable apt-selected SDK version.
RUN apt-install-retry dotnet-runtime-10.0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=dotnet-sdk-source /usr/share/dotnet/ /usr/share/dotnet/
RUN ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
    && test "$(dotnet --version)" = "10.0.401" \
    && dotnet --list-runtimes | grep -Eq '^Microsoft.NETCore.App 10\.0\.12 \[/usr/share/dotnet/shared/Microsoft.NETCore.App\]$'

# Install the exact verified release, never the installer's mutable latest.
RUN curl --fail --location --proto '=https' --show-error --silent --tlsv1.2 \
        --output /tmp/code-server.deb \
        "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_amd64.deb" \
    && printf '%s  /tmp/code-server.deb\n' "$CODE_SERVER_SHA256" | sha256sum --check --strict \
    && apt-install-retry /tmp/code-server.deb \
    && test "$(dpkg-query -W -f='${Version}' code-server)" = "$CODE_SERVER_VERSION" \
    && rm -f /tmp/code-server.deb \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 20000 coder \
    && useradd --uid 10000 --gid 20000 --create-home --shell /bin/bash coder

ENV HOME=/home/coder

WORKDIR /home/coder
USER 10000:20000
CMD ["sleep", "infinity"]
