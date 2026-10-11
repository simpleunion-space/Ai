#!/usr/bin/env bash

# Installation-specific values for kurkin-family labs m01.
# This file is sourced by ai-stand/apply.sh; it is intentionally not a Compose
# env_file and is not used for Compose interpolation.

INSTALLATION_NAME="kurkin-family__labs__m01"
INSTALLATION_TITLE="Kurkin Family Labs m01"

# Where this installation keeps its data: <storage root>/<component>-data/<part> (and _secrets, _backups). Nothing in the
# repository spells the root out; apply.sh derives every path from this value (define_storage_paths) and passes it on.
STORAGE_ROOT="/mnt/storage"

# ai-stand's own default is UTC; this installation runs on Moscow time (UTC+3, no daylight saving) - services and both hosts.
IM_TZ="Europe/Moscow"

AI01_NODE_NAME="ai01"
AI02_NODE_NAME="ai02"

AI01_IP="10.20.0.200"
AI02_IP="10.20.0.204"

TRUSTED_CIDRS=(
  "10.20.0.0/24"
  "10.4.0.0/24"
)

# Authentik owns the browser-facing identity boundary. Open WebUI,
# Portainer and Agentgateway have native OIDC; OpenClaw uses the
# embedded Authentik outpost in nginx plus OpenClaw's trusted-proxy mode.
# llama.cpp deliberately has neither public route nor
# published port: model requests enter only through Agentgateway.

# Read-only Jira/Confluence/IMAP MCP are provisioned by the `reconcile` job of the
# controller container on ai01 (docker/controller) from each user's own Authentik
# attributes. This requires a root-only
# ${STORAGE_ROOT}/readonly-mcp-data/reconciler/reconciler.json to already exist
# on ai01 (root:root 0600, real upstream URLs - see
# readonly-mcp/reconciler.example.json); apply.sh's own deploy/verify checks
# die() loudly if it's missing. Once enabled, each of the three personal
# records activates independently; there is no static inventory and no
# all-or-nothing set.
READONLY_MCP_ENABLED="1"
# Coder's control plane runs on ai02. Its built-in provisioner reaches the
# node Docker daemon only through a policy-limited socket proxy; no raw
# socket or default AI/MCP credentials enter a workspace.
CODER_ENABLED="1"
# Rootless Gitea is the optional Git control plane on ai01. Projects and
# Actions are intentionally not seeded by this profile.
GITEA_ENABLED="1"
# Registers every ai-users member's SSH public key (an Authentik attribute) in
# their Gitea account; see docker/gitea-ssh-sync. Deployed by the
# configure-gitea-ssh-sync stage once Gitea and Authentik are configured.
GITEA_SSH_SYNC_ENABLED="1"
# Delivers every ai-users member's personal SSH private key (an Authentik attribute) to their own Coder workspaces and to
# nobody else's; see docker/ssh-key-delivery. Deployed by the configure-ssh-key-delivery stage.
SSH_KEY_DELIVERY_ENABLED="1"

DEFAULT_ACCELERATOR="auto"
PRIMARY_SWARM_NODE="$AI01_NODE_NAME"
MODEL_PROFILE_NODE="$AI01_NODE_NAME"

# ai01: AMD Ryzen AI Max+ PRO 395 (Strix Halo), Radeon 8060S. ai02: AMD
# Ryzen 7 255, Radeon 780M. Confirmed via https://rocm.docs.amd.com's
# per-model GPU picker (fam=ryzen) - see ensure_amd_driver() in apply.sh for
# why this isn't auto-detected instead.
AI01_ROCM_GFX_VERSION="gfx1151"
AI02_ROCM_GFX_VERSION="gfx1103"
# Both workers are ROCm-only. Readiness fails closed if GPU inference is not
# available; an AMD node must never select Vulkan or CPU as a fallback.
# First task boot uses the installation's selected model families, never the
# generic small-model defaults. apply.sh resolves paths and SHA-256 from the
# shared pinned catalog; model-apply resolves and persists the chat context.
LLAMACPP_CHAT_MODEL_SOURCE="qwen/qwen3.8-27b@q4_k_m"
LLAMACPP_CHAT_MODEL_ID="qwen/qwen3.8-27b"
LLAMACPP_CHAT_CONTEXT_LENGTH="262144"
LLAMACPP_EMBEDDING_MODEL_ID="qwen3-embedding-8b"
LLAMACPP_EMBEDDING_CONTEXT_LENGTH="32768"
# Ceiling the model selector may pick the chat context from, and the contexts model-apply tries (largest first; the first
# the hardware serves is kept as the resolved state). The embedding model has the one context it is served with.
LLAMACPP_CHAT_POLICY_MAX_CONTEXT="262144"
LLAMACPP_CHAT_CONTEXT_CANDIDATES=(262144 131072 65536 32768 24576 16384 8192 4096)
LLAMACPP_CHAT_PARALLEL="1"
LLAMACPP_EMBEDDING_CONTEXT_CANDIDATES=(32768)
# A full deploy waits for the model migration controller's receipt (model-migrate-q4); see apply.sh.
MODEL_MIGRATION_REQUIRED="1"
# How freely OpenClaw's Codex runtime may act: guardian (asks) or autonomous.
OPENCLAW_CODEX_EXECUTION_PROFILE="autonomous"
case "${NODE_NAME:-}" in
  "$AI01_NODE_NAME") AMD_ROCM_GFX_VERSION="$AI01_ROCM_GFX_VERSION" ;;
  "$AI02_NODE_NAME") AMD_ROCM_GFX_VERSION="$AI02_ROCM_GFX_VERSION" ;;
esac

CERT_DOMAIN="m01.labs.kurkin-family.ru"
CERT_DIR="${STORAGE_ROOT}/certbot-data/live/m01.labs.kurkin-family.ru"

# The recurring jobs (MCP/Telegram reconciler, Open WebUI model access, certificate
# renewal) run in the controller container on ai01 instead of host systemd timers
# (docker/controller/README.md).
CONTROLLER_ENABLED="1"

# Automatic wildcard certificate: DNS-01 against Selectel DNS Hosting, renewed by the
# controller on ai01 and handed to the cert-receiver on ai02 (certbot/README.md). The
# credentials file is created by the owner and is not part of the repository.
CERTBOT_ENABLED="1"
CERTBOT_EMAIL="pskurkin@yandex.ru"
CERTBOT_CREDENTIALS_NAME="certbot-dns-selectel"
CERTBOT_HOOK_SOURCE="certbot/selectel-dns-hook.py"
# ai02 runs the cert-receiver; every certificate renewed on ai01 is handed to it.
CERTBOT_RECEIVER_ENABLED="1"

AI01_HOST="ai01.m01.labs.kurkin-family.ru"
AI02_HOST="ai02.m01.labs.kurkin-family.ru"
OPENWEBUI_HOST="openwebui.m01.labs.kurkin-family.ru"
OPENCLAW_HOST="openclaw.m01.labs.kurkin-family.ru"
PORTAINER_HOST="portainer.m01.labs.kurkin-family.ru"
AUTHENTIK_HOST="authentik.m01.labs.kurkin-family.ru"
# Stable namespace for Authentik's immutable user UUIDs. This is an internal
# (issuer, sub) key namespace, not an OIDC application/provider slug.
AUTHENTIK_IDENTITY_ISSUER_PATH="/application/o/stand"
AGENTGATEWAY_HOST="agentgateway.m01.labs.kurkin-family.ru"
CODER_HOST="coder.m01.labs.kurkin-family.ru"
GITEA_HOST="gitea.m01.labs.kurkin-family.ru"
GITEA_SSH_PORT="2222"

PORTAINER_MULTI_A_HOST="$PORTAINER_HOST"
AUTHENTIK_PUBLIC_URL="https://${AUTHENTIK_HOST}"
OPENWEBUI_PUBLIC_URL="https://${OPENWEBUI_HOST}"
OPENCLAW_PUBLIC_ORIGIN="https://${OPENCLAW_HOST}"
# Nginx on ai02 performs Authentik forward-auth and is the only process
# allowed to assert an immutable subject to the Gateway.  The host-published
# Swarm port is reached through docker-proxy, which observes Nginx as the
# gateway bridge address rather than literal loopback. Keep this narrow;
# trusting the whole overlay would let arbitrary workloads assert identity.
OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED="1"
OPENCLAW_TRUSTED_PROXIES="127.0.0.1,::1,172.18.0.1"
PORTAINER_PUBLIC_URL="https://${PORTAINER_HOST}"

MODEL_PROFILE_SCRIPT="${INSTALLATION_DIR}/apply-model-profile.sh"
