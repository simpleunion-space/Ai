# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.10.13-1

FROM ${BASE_IMAGE} AS controller

# The Docker CLI comes from Docker's own apt repository, exactly as on the hosts (apply.sh ensure_docker_repo), so it
# matches the daemon it talks to through the mounted socket. python3 runs the controller and the jobs it supervises;
# jq, openssl, curl, tar and flock (util-linux) are already in the base image.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 iproute2 \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl --fail --silent --show-error --location https://download.docker.com/linux/ubuntu/gpg \
        --output /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && printf '%s\n' "Types: deb" "URIs: https://download.docker.com/linux/ubuntu" "Suites: ${VERSION_CODENAME}" \
        "Components: stable" "Signed-By: /etc/apt/keyrings/docker.asc" \
        "Architectures: $(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.sources \
    && apt-get update \
    && apt-get install --yes --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/* \
    # COPY --chmod would also give an implicitly created directory mode 0644
    && install -d -m 0755 /opt/controller /opt/controller/certbot

COPY --chmod=0644 docker/controller/controller.py /opt/controller/controller.py
# The certificate scripts are baked in: the receiving side's validation must not depend on a mutable checkout.
COPY --chmod=0755 certbot/renew.sh certbot/receive-cert.sh /opt/controller/certbot/
COPY --chmod=0644 certbot/served.sh /opt/controller/certbot/served.sh

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    DOCKER_CONFIG=/tmp/.docker

# Runs as root on purpose: the jobs create Docker secrets and services and write root-owned control files. The Compose
# service gives it the Docker socket and the directories it needs, nothing else (read_only root filesystem, no ports).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/python3", "/opt/controller/controller.py"]
CMD ["run"]
