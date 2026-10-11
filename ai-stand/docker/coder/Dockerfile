ARG CODER_BASE_IMAGE=ghcr.io/coder/coder:v2.38.0
FROM ${CODER_BASE_IMAGE}

USER root
# The upstream image is Alpine/musl. Coder's own Terraform provisioner spawns
# Terraform provider plugins as subprocesses (Go's go-plugin RPC handshake
# over stdin/stdout); any provider binary that's dynamically linked against
# glibc (no /lib64/ld-linux-x86-64.so.2 exists here otherwise) fails that
# handshake with a generic "Failed to read any lines from plugin's stdout" -
# confirmed live 2026-09-23 against both coder/coder and kreuzwerker/docker
# provider builds. gcompat is Alpine's own standard glibc-compatibility
# shim for exactly this case.
RUN apk add --no-cache gcompat
COPY entrypoint.sh /usr/local/bin/ai-stand-coder-entrypoint
RUN chmod 0755 /usr/local/bin/ai-stand-coder-entrypoint

ENTRYPOINT ["/usr/local/bin/ai-stand-coder-entrypoint"]
CMD ["server"]
