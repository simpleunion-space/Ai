# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.10.13-1

FROM ${BASE_IMAGE} AS ssh-key-delivery

RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/* \
    # COPY --chmod would also give an implicitly created directory mode 0644,
    # which the unprivileged service identity cannot traverse.
    && install -d -m 0755 /opt/ssh-key-delivery

# sync.py is the Gitea synchronizer's module; delivery.py reuses its HTTP and Authentik helpers.
COPY --chmod=0644 docker/gitea-ssh-sync/sync.py /opt/ssh-key-delivery/sync.py
COPY --chmod=0644 docker/ssh-key-delivery/delivery.py /opt/ssh-key-delivery/delivery.py

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# The service identity, the read-only root filesystem and the dropped
# capabilities come from the Compose service, so the base image's
# privilege-dropping entrypoint is not used. The Compose command picks the
# mode: push (sender) or serve (receiver).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/python3", "/opt/ssh-key-delivery/delivery.py"]
