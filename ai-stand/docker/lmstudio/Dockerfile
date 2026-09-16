# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.08.07-1
# llmster's `runtime get` always resolves to whatever engine build is
# currently newest for the requested id - there is no way to ask it for
# "latest known-good". 2.28.2 (2026-08-14) hangs indefinitely on every
# completion request on this installation's AMD/ROCm 7.2.4 hardware (GPU
# utilization stays near 0%, dmesg logs repeated amdgpu
# svm_range_restore_work stalls) while otherwise reporting the model as
# loaded - confirmed by direct A/B test against 2.27.1. Skip 2.28.2 if
# bumping further. 2.32.0 (2026-09-02) does not have that specific hang,
# but this hardware also has a separate, version-independent instability
# under sustained load (amdgpu queue eviction, Swarm auto-restarts the
# container) reproduced on both 2.27.1 and 2.32.0 - bumping this pin does
# not fix, and does not worsen, that issue. Bump only after re-validating
# a real completion on this hardware, not just a successful build.
ARG LMSTUDIO_RUNTIME_VERSION=2.32.0
FROM ${BASE_IMAGE} AS lmstudio-build

ARG LMSTUDIO_RUNTIME_VERSION

ENV IM_TZ=Europe/Moscow \
    IM_UID=1000 \
    IM_GID=1000 \
    LMSTUDIO_SEED_HOME=/opt/lmstudio-seed

RUN install -d --owner=ai --group=ai \
        /opt/lmstudio-seed \
        /opt/lmstudio-runtime-manifests

USER ai
WORKDIR /opt/lmstudio-seed

# lmstudio.ai does not publish an official checksum for install.sh (unlike
# the Node.js SHASUMS256.txt verification in docker/lib/install-node.sh,
# used by the authentik/openclaw/lmstudio-proxy images - not this one, which
# never installs Node.js), so this pins the hash of the version reviewed for
# this image. A future intentional upstream change
# requires bumping this hash here, not just a silent re-fetch. The `lms`
# runtime binary itself is fetched by this script's own closed-source
# updater with no independently verifiable checksum available to us - this
# pin only covers the entry point, not everything it can later download.
# Re-pinned 2026-09-10: upstream bumped its embedded APP_VERSION (0.0.22-1
# -> 0.0.24-1). Diffed the new script against archive.org snapshots back to
# 0.0.21-2 (2026-08-25) - that version string is the only line that ever
# changes between releases; installer logic itself is unmodified.
RUN curl \
        --fail \
        --location \
        --proto '=https' \
        --show-error \
        --silent \
        --tlsv1.2 \
        https://lmstudio.ai/install.sh \
        --output /tmp/lmstudio-install.sh \
    && echo "076edb51310664314222a2d706b41882d09675245f4ea3eb884185e23d85e0a6  /tmp/lmstudio-install.sh" | sha256sum --check --strict \
    && HOME=/opt/lmstudio-seed sh /tmp/lmstudio-install.sh --quiet --no-modify-path \
    && rm -f /tmp/lmstudio-install.sh \
    && test -x /opt/lmstudio-seed/.lmstudio/bin/lms

RUN if [ -d /opt/lmstudio-seed/.lmstudio/extensions/backends ]; then \
        find /opt/lmstudio-seed/.lmstudio/extensions/backends \
            -mindepth 1 \
            -maxdepth 1 \
            ! -name vendor \
            -exec rm -rf -- {} +; \
    fi

COPY --chmod=0755 docker/lmstudio/install-runtime.sh /usr/local/bin/lmstudio-install-runtime.sh

RUN HOME=/opt/lmstudio-seed \
    /usr/local/bin/lmstudio-install-runtime.sh \
        cpu \
        llama.cpp-linux-x86_64-avx2 \
        "$LMSTUDIO_RUNTIME_VERSION"

USER root
WORKDIR /home/ai

COPY --chmod=0755 docker/lmstudio/healthcheck.sh /usr/local/bin/lmstudio-healthcheck.sh

EXPOSE 1234

CMD ["/usr/local/bin/lmstudio-entrypoint.sh"]


FROM lmstudio-build AS lmstudio

RUN chown -R root:ai \
        /opt/lmstudio-seed \
        /opt/lmstudio-runtime-manifests \
    && chmod -R u=rwX,g=rwX,o=rX \
        /opt/lmstudio-seed \
        /opt/lmstudio-runtime-manifests

COPY --chmod=0755 docker/lmstudio/service-entrypoint.sh /usr/local/bin/lmstudio-entrypoint.sh


FROM lmstudio-build AS lmstudio-nvidia

ARG LMSTUDIO_RUNTIME_VERSION

USER ai

RUN HOME=/opt/lmstudio-seed \
    /usr/local/bin/lmstudio-install-runtime.sh \
        nvidia \
        llama.cpp-linux-x86_64-nvidia-cuda-avx2 \
        "$LMSTUDIO_RUNTIME_VERSION"

USER root

RUN chown -R root:ai \
        /opt/lmstudio-seed \
        /opt/lmstudio-runtime-manifests \
    && chmod -R u=rwX,g=rwX,o=rX \
        /opt/lmstudio-seed \
        /opt/lmstudio-runtime-manifests

COPY --chmod=0755 docker/lmstudio/service-entrypoint.sh /usr/local/bin/lmstudio-entrypoint.sh


FROM lmstudio-build AS lmstudio-amd

ARG LMSTUDIO_RUNTIME_VERSION
ARG LMSTUDIO_VULKAN_RUNTIME_VERSION=2.32.0
# ROCm's package distribution moved from repo.radeon.com's flat per-version apt
# path (which topped out at 7.2.4 and had no further releases published under
# that scheme) to stable.repo.amd.com with a new "amdrocm<release>-gfx<gfx>"
# package naming convention - see https://rocm.docs.amd.com/en/latest/install/rocm.html.
# AMD_ROCM_RELEASE and AMD_ROCM_GFX_VERSION are independent: the former is the
# ROCm release line, the latter is this GPU's LLVM gfx target (e.g. gfx1151 for
# Strix Halo/Ryzen AI Max, gfx1103 for Phoenix/Radeon 780M) - `rocminfo` or
# https://rocm.docs.amd.com's per-model GPU picker reports the right value.
ARG AMD_ROCM_RELEASE=10.0
ARG AMD_ROCM_GFX_VERSION=gfx1151

USER root

# Confirmed by live A/B test (2026-09-05): a llama.cpp binary built against the
# old repo.radeon.com/rocm 7.2.4 libraries loads and runs unmodified against
# these amdrocm10.0 libraries - every SONAME it links against (libamdhip64.so.7,
# libhipblas.so.3, librocblas.so.5, libhsa-runtime64.so.1, libhipblaslt.so.1)
# is unchanged between the two package generations.
RUN install -d --mode=0755 /etc/apt/keyrings \
    && apt-get update \
    && apt-get install --yes --no-install-recommends gnupg \
    && curl \
        --fail \
        --location \
        --proto '=https' \
        --show-error \
        --silent \
        --tlsv1.2 \
        https://stable.repo.amd.com/rocm/gpg/packages.gpg \
        | gpg --dearmor --output /etc/apt/keyrings/amdrocm.gpg \
    && printf '%s\n' \
        "X-Repo-Id: amdrocm-stable" \
        "Types: deb" \
        "URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2404/" \
        "Suites: stable" \
        "Components: main" \
        "Architectures: amd64" \
        "Signed-By: /etc/apt/keyrings/amdrocm.gpg" \
        "Enabled: yes" \
        > /etc/apt/sources.list.d/amdrocm-stable.sources \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
        "amdrocm${AMD_ROCM_RELEASE}-${AMD_ROCM_GFX_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

ENV LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64

# Vulkan (Mesa RADV) userspace driver, installed alongside ROCm as a diagnostic/alternative
# backend - /dev/dri is already passed through for ROCm, but no Vulkan ICD exists in the image
# without this. ROCm stays the image's default selected runtime; switching to Vulkan is a
# runtime-only `lms runtime select`, no rebuild needed either way.
#
# Known gap: these two are the only packages in this file installed without a
# version pin (everything else here - LM Studio's own install.sh, the ROCm
# release line, its GPG key - is pinned with a justifying comment). Given
# this file's own GPU-hang history, an unannounced Mesa driver bump on a
# future rebuild could silently reintroduce a regression on hardware that
# was actually validated against a specific driver version. Not pinned here
# because the exact resolvable version string depends on the target Ubuntu
# release's apt repo state at build time, which isn't something to guess at
# from outside that environment - if this ever needs hardening, pin via
# `apt-get install libvulkan1=<version> mesa-vulkan-drivers=<version>` after
# checking `apt-cache policy` on the actual build host.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        libvulkan1 \
        mesa-vulkan-drivers \
    && rm -rf /var/lib/apt/lists/*

USER ai

RUN HOME=/opt/lmstudio-seed \
    /usr/local/bin/lmstudio-install-runtime.sh \
        amd \
        llama.cpp-linux-x86_64-amd-rocm-avx2 \
        "$LMSTUDIO_RUNTIME_VERSION"

# Separate profile name ("amd-vulkan") so install-runtime.sh's own cleanup pass (which removes
# any backend directory lacking a matching manifest) keeps both engines instead of deleting one.
RUN HOME=/opt/lmstudio-seed \
    /usr/local/bin/lmstudio-install-runtime.sh \
        amd-vulkan \
        llama.cpp-linux-x86_64-vulkan-avx2 \
        "$LMSTUDIO_VULKAN_RUNTIME_VERSION"

USER root

RUN chown -R root:ai \
        /opt/lmstudio-seed \
        /opt/lmstudio-runtime-manifests \
    && chmod -R u=rwX,g=rwX,o=rX \
        /opt/lmstudio-seed \
        /opt/lmstudio-runtime-manifests

COPY --chmod=0755 docker/lmstudio/service-entrypoint.sh /usr/local/bin/lmstudio-entrypoint.sh
