# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/simpleunion/base:2026.10.13-1
ARG CUDA_BUILD_IMAGE=nvidia/cuda:12.8.1-devel-ubuntu24.04@sha256:520292dbb4f755fd360766059e62956e9379485d9e073bbd2f6e3c20c270ed66

FROM ${BASE_IMAGE} AS native-source
ARG LLAMA_CPP_COMMIT=d81235049384534c167caea52b85a694f6103d14
ARG LLAMA_CPP_ARCHIVE_SHA256=6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14
ARG LLAMA_CPP_TAG=v0.6.0
RUN test "$LLAMA_CPP_COMMIT" = d81235049384534c167caea52b85a694f6103d14 \
    && test "$LLAMA_CPP_ARCHIVE_SHA256" = 6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14 \
    && test "$LLAMA_CPP_TAG" = v0.6.0 \
    && curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
       "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$LLAMA_CPP_COMMIT" -o /tmp/llama-source.tar.gz \
    && echo "$LLAMA_CPP_ARCHIVE_SHA256  /tmp/llama-source.tar.gz" | sha256sum --check --strict \
    && mkdir /src \
    && tar -xzf /tmp/llama-source.tar.gz --strip-components=1 -C /src \
    && rm /tmp/llama-source.tar.gz

FROM ${BASE_IMAGE} AS runtime-common
RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 libstdc++6 libgcc-s1 \
    && rm -rf /var/lib/apt/lists/* \
    && groupmod --gid 20000 ai \
    && usermod --uid 10000 --gid 20000 ai \
    && install -d -m 0750 -o ai -g ai /models /state /home/ai \
    && chown ai:ai /home/ai
ENV HOME=/state \
    IM_UID=10000 IM_GID=20000 \
    LLAMACPP_MODELS_DIR=/models LLAMACPP_STATE_DIR=/state \
    LLAMACPP_PORT=1234 LLAMACPP_REQUIRED_QUANT=Q4_K_M \
    LLAMACPP_PARALLEL=1 LLAMACPP_BATCH_SIZE=512 LLAMACPP_UBATCH_SIZE=512 \
    LLAMACPP_CACHE_TYPE_K=f16 LLAMACPP_CACHE_TYPE_V=f16 \
    LLAMACPP_REQUEST_TIMEOUT=86400 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /state
EXPOSE 1234
# The common framework's legacy bootstrap rewrites /etc and home ownership.
# This scoped wrapper preserves its UID/GID and supplemental-device contract
# without writing to a read-only rootfs or touching read-only model weights.
ENTRYPOINT ["/usr/local/bin/llamacpp-entrypoint.sh"]
CMD ["serve"]

FROM runtime-common AS cpu-build
COPY --from=native-source /src /src
RUN apt-get update && apt-get install --yes --no-install-recommends cmake g++ make \
    && cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF \
       -DGGML_CUDA=OFF -DGGML_HIP=OFF -DGGML_VULKAN=OFF -DLLAMA_CURL=OFF \
       -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON \
    && cmake --build /build --target llama-server -j 8

FROM runtime-common AS llamacpp-cpu
COPY --chmod=0755 docker/llamacpp/service-entrypoint.sh /usr/local/bin/llamacpp-entrypoint.sh
COPY --chmod=0755 docker/llamacpp/healthcheck.sh /usr/local/bin/llamacpp-healthcheck.sh
COPY --chmod=0644 docker/llamacpp/runtime.py /usr/local/lib/llamacpp/runtime.py
ENV LD_LIBRARY_PATH=/opt/llamacpp/bin
ARG LLAMA_CPP_COMMIT=d81235049384534c167caea52b85a694f6103d14
ARG LLAMA_CPP_ARCHIVE_SHA256=6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14
COPY --from=cpu-build /build/bin /opt/llamacpp/bin
# Final-layer provenance does not invalidate native compiler/cache layers.
# Same canonical four-source digest as model-catalog/selection.py, calculated
# from image-owned bytes. No caller-supplied build argument can forge it.
COPY --chmod=0644 docker/llamacpp/Dockerfile docker/llamacpp/service-entrypoint.sh docker/llamacpp/healthcheck.sh docker/llamacpp/runtime.py /opt/llamacpp-recipe/
# COPY --chmod also applies to newly created directories. Restore traversal
# for the non-root runtime without changing cached compiler/toolchain layers.
RUN chmod 0755 /usr/local/lib/llamacpp /opt/llamacpp /opt/llamacpp/bin /opt/llamacpp-recipe
RUN python3 -c 'from pathlib import Path; import hashlib,json; root=Path("/opt/llamacpp-recipe"); files=("Dockerfile","service-entrypoint.sh","healthcheck.sh","runtime.py"); value={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in files}; fingerprint=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":")).encode()).hexdigest(); Path("/opt/llamacpp-recipe-fingerprint").write_text(fingerprint+"\n")'
RUN jq -n --arg commit "$LLAMA_CPP_COMMIT" --arg archive "$LLAMA_CPP_ARCHIVE_SHA256" \
       --arg recipe "$(cat /opt/llamacpp-recipe-fingerprint)" \
       '{commit:$commit,archiveSha256:$archive,recipeFingerprint:$recipe,nativeTag:"v0.6.0",accelerator:"cpu",gfx:"",rocmVersion:""}' \
       > /opt/llamacpp-build.json \
    && /opt/llamacpp/bin/llama-server --version
ENV LLAMACPP_ACCELERATOR=cpu LLAMACPP_REQUIRE_GPU=0 LLAMACPP_GPU_LAYERS=0
LABEL org.opencontainers.image.revision=${LLAMA_CPP_COMMIT}

FROM ${CUDA_BUILD_IMAGE} AS cuda-build
COPY --from=native-source /src /src
RUN apt-get update && apt-get install --yes --no-install-recommends cmake g++ make \
    && cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF \
       -DGGML_CUDA=ON -DGGML_HIP=OFF -DGGML_VULKAN=OFF -DLLAMA_CURL=OFF \
       -DCMAKE_CUDA_ARCHITECTURES="75;80;86;89;90" \
       -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON \
    && cmake --build /build --target llama-server -j 8

FROM runtime-common AS llamacpp-nvidia
COPY --chmod=0755 docker/llamacpp/service-entrypoint.sh /usr/local/bin/llamacpp-entrypoint.sh
COPY --chmod=0755 docker/llamacpp/healthcheck.sh /usr/local/bin/llamacpp-healthcheck.sh
COPY --chmod=0644 docker/llamacpp/runtime.py /usr/local/lib/llamacpp/runtime.py
ARG LLAMA_CPP_COMMIT=d81235049384534c167caea52b85a694f6103d14
ARG LLAMA_CPP_ARCHIVE_SHA256=6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14
COPY --from=cuda-build /build/bin /opt/llamacpp/bin
COPY --from=cuda-build /usr/local/cuda/targets/x86_64-linux/lib/libcudart.so* /opt/cuda/lib/
COPY --from=cuda-build /usr/local/cuda/targets/x86_64-linux/lib/libcublas.so* /opt/cuda/lib/
COPY --from=cuda-build /usr/local/cuda/targets/x86_64-linux/lib/libcublasLt.so* /opt/cuda/lib/
COPY --chmod=0644 docker/llamacpp/Dockerfile docker/llamacpp/service-entrypoint.sh docker/llamacpp/healthcheck.sh docker/llamacpp/runtime.py /opt/llamacpp-recipe/
RUN chmod 0755 /usr/local/lib/llamacpp /opt/llamacpp /opt/llamacpp/bin /opt/llamacpp-recipe
RUN python3 -c 'from pathlib import Path; import hashlib,json; root=Path("/opt/llamacpp-recipe"); files=("Dockerfile","service-entrypoint.sh","healthcheck.sh","runtime.py"); value={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in files}; fingerprint=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":")).encode()).hexdigest(); Path("/opt/llamacpp-recipe-fingerprint").write_text(fingerprint+"\n")'
RUN jq -n --arg commit "$LLAMA_CPP_COMMIT" --arg archive "$LLAMA_CPP_ARCHIVE_SHA256" \
       --arg recipe "$(cat /opt/llamacpp-recipe-fingerprint)" \
       '{commit:$commit,archiveSha256:$archive,recipeFingerprint:$recipe,nativeTag:"v0.6.0",accelerator:"nvidia",gfx:"",rocmVersion:"",cudaVersion:"12.8"}' \
       > /opt/llamacpp-build.json
ENV LD_LIBRARY_PATH=/opt/cuda/lib:/opt/llamacpp/bin \
    NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    LLAMACPP_ACCELERATOR=nvidia LLAMACPP_REQUIRE_GPU=1 LLAMACPP_GPU_LAYERS=all
LABEL org.opencontainers.image.revision=${LLAMA_CPP_COMMIT}

FROM runtime-common AS rocm-common
ARG AMD_ROCM_RELEASE=10.1
ARG AMD_ROCM_GFX_VERSION=gfx1151
RUN test "$AMD_ROCM_RELEASE" = 10.1 \
    && case "$AMD_ROCM_GFX_VERSION" in gfx[0-9][0-9][0-9][0-9]) ;; *) exit 1 ;; esac \
    && install -d --mode=0755 /etc/apt/keyrings \
    && apt-get update && apt-get install --yes --no-install-recommends gnupg \
    && curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
       https://stable.repo.amd.com/rocm/gpg/packages.gpg \
       | gpg --dearmor --output /etc/apt/keyrings/amdrocm.gpg \
    && printf '%s\n' "X-Repo-Id: amdrocm-stable" "Types: deb" \
       "URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/" \
       "Suites: stable" "Components: main" "Architectures: amd64" \
       "Signed-By: /etc/apt/keyrings/amdrocm.gpg" "Enabled: yes" \
       > /etc/apt/sources.list.d/amdrocm-stable.sources \
    && apt-get update \
    && apt-get install --yes --no-install-recommends "amdrocm${AMD_ROCM_RELEASE}-${AMD_ROCM_GFX_VERSION}" \
    && rm -rf /var/lib/apt/lists/*
ENV LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:/opt/llamacpp/bin \
    LLAMACPP_ACCELERATOR=amd LLAMACPP_REQUIRE_GPU=1 LLAMACPP_GPU_LAYERS=all \
    LLAMACPP_GFX=${AMD_ROCM_GFX_VERSION}

FROM rocm-common AS hip-build
ARG AMD_ROCM_RELEASE=10.1
ARG AMD_ROCM_GFX_VERSION=gfx1151
COPY --from=native-source /src /src
# The runtime metapackage intentionally lacks HIP headers/CMake config. Keep
# the minimum SDK in this build stage only; the production image inherits the
# runtime-only stage. An explicit SDK root also avoids CMake resolving the
# TheRock compiler symlink to core/lib/llvm and mistaking it for an SDK root.
RUN apt-get update && apt-get install --yes --no-install-recommends cmake g++ make \
       "amdrocm-runtime-dev${AMD_ROCM_RELEASE}" "amdrocm-blas-dev${AMD_ROCM_RELEASE}" \
    && cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF \
       -DCMAKE_C_COMPILER=/opt/rocm/llvm/bin/clang \
       -DCMAKE_CXX_COMPILER=/opt/rocm/llvm/bin/clang++ \
       -DCMAKE_HIP_COMPILER=/opt/rocm/llvm/bin/clang++ \
       -DCMAKE_HIP_COMPILER_ROCM_ROOT=/opt/rocm \
       -DCMAKE_PREFIX_PATH=/opt/rocm -DGGML_HIP=ON -DGGML_HIP_NO_VMM=ON \
       -DAMDGPU_TARGETS="$AMD_ROCM_GFX_VERSION" \
       -DCMAKE_HIP_ARCHITECTURES="$AMD_ROCM_GFX_VERSION" \
       -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DLLAMA_CURL=OFF \
       -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON \
    && cmake --build /build --target llama-server -j 4
# llvm-objdump --offloading in this ROCm distribution extracts bundle objects
# beside the library. llvm-readobj inspects ELF offload descriptors without
# writing anything, and its complete output must be drained (no grep -m/head).
RUN /opt/rocm/llvm/bin/llvm-readobj --offloading /build/bin/libggml-hip.so \
    | grep --extended-regexp "(^|[^[:alnum:]])${AMD_ROCM_GFX_VERSION}([^[:alnum:]]|$)"

FROM rocm-common AS llamacpp-amd
COPY --chmod=0755 docker/llamacpp/service-entrypoint.sh /usr/local/bin/llamacpp-entrypoint.sh
COPY --chmod=0755 docker/llamacpp/healthcheck.sh /usr/local/bin/llamacpp-healthcheck.sh
COPY --chmod=0644 docker/llamacpp/runtime.py /usr/local/lib/llamacpp/runtime.py
ARG LLAMA_CPP_COMMIT=d81235049384534c167caea52b85a694f6103d14
ARG LLAMA_CPP_ARCHIVE_SHA256=6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14
ARG AMD_ROCM_RELEASE=10.1
ARG AMD_ROCM_GFX_VERSION=gfx1151
COPY --from=hip-build /build/bin /opt/llamacpp/bin
COPY --chmod=0644 docker/llamacpp/Dockerfile docker/llamacpp/service-entrypoint.sh docker/llamacpp/healthcheck.sh docker/llamacpp/runtime.py /opt/llamacpp-recipe/
RUN chmod 0755 /usr/local/lib/llamacpp /opt/llamacpp /opt/llamacpp/bin /opt/llamacpp-recipe
RUN python3 -c 'from pathlib import Path; import hashlib,json; root=Path("/opt/llamacpp-recipe"); files=("Dockerfile","service-entrypoint.sh","healthcheck.sh","runtime.py"); value={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in files}; fingerprint=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":")).encode()).hexdigest(); Path("/opt/llamacpp-recipe-fingerprint").write_text(fingerprint+"\n")'
RUN jq -n --arg commit "$LLAMA_CPP_COMMIT" --arg archive "$LLAMA_CPP_ARCHIVE_SHA256" \
       --arg gfx "$AMD_ROCM_GFX_VERSION" --arg rocm "$AMD_ROCM_RELEASE" \
       --arg recipe "$(cat /opt/llamacpp-recipe-fingerprint)" \
       '{commit:$commit,archiveSha256:$archive,recipeFingerprint:$recipe,nativeTag:"v0.6.0",accelerator:"amd",gfx:$gfx,rocmVersion:$rocm}' \
       > /opt/llamacpp-build.json \
    && /opt/rocm/llvm/bin/llvm-readobj --offloading /opt/llamacpp/bin/libggml-hip.so \
       | grep --extended-regexp "(^|[^[:alnum:]])${AMD_ROCM_GFX_VERSION}([^[:alnum:]]|$)"
LABEL org.opencontainers.image.revision=${LLAMA_CPP_COMMIT} \
      org.ai-stand.rocm.gfx=${AMD_ROCM_GFX_VERSION}
