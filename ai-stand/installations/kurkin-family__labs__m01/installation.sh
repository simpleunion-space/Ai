#!/usr/bin/env bash

# Installation-specific values for kurkin-family labs m01.
# This file is sourced by ai-stand/apply.sh; it is intentionally not a Compose
# env_file and is not used for Compose interpolation.

INSTALLATION_NAME="kurkin-family__labs__m01"
INSTALLATION_TITLE="Kurkin Family Labs m01"

IM_TZ="Europe/Moscow"
IM_UID="10000"
IM_GID="20000"

AI01_NODE_NAME="ai01"
AI02_NODE_NAME="ai02"

AI01_IP="10.20.0.200"
AI02_IP="10.20.0.204"

TRUSTED_CIDRS=(
  "10.20.0.0/24"
  "10.4.0.0/24"
)

# Authentik owns the browser-facing identity boundary. Open WebUI,
# MetaMCP, Portainer and Agentgateway have native OIDC; OpenClaw uses the
# embedded Authentik outpost in nginx plus OpenClaw's trusted-proxy mode.
# LM Studio and LM Studio Proxy deliberately have neither public route nor
# published port: model requests enter only through Agentgateway.

# Confirmed live on this installation (opencode + qwen3.6-35b-a3b): LM
# Studio's /v1/chat/completions rejects role:"tool" messages whose content
# is an image-bearing content-parts array with a 400 ("Invalid 'messages'
# in payload") - triggered by opencode's `read` tool attaching non-text
# file reads as content parts. See docker/lmstudio-proxy/server.mjs. Off
# generically; this installation has confirmed the need, so it's on here.
LMSTUDIO_PROXY_FLATTEN_TOOL_RESULT_CONTENT_ENABLED="1"

# Enables the personal GigaCode plane. Device IDs are stored only in the
# corresponding user's own Authentik attributes and reconciled into
# per-subscription Docker Secrets; no credential is stored in this public
# profile.
GIGACODE_SUBSCRIPTION_ENABLED="1"

# Read-only Jira/Confluence/IMAP MCP, plus the per-user GigaCode device ID
# reconciled alongside them, are provisioned by the root-owned ai01 timer
# (ai-stand-readonly-mcp-reconciler) from each user's own Authentik
# attributes. This requires a root-only
# /mnt/storage/readonly-mcp-data/reconciler/reconciler.json to already exist
# on ai01 (root:root 0600, real upstream URLs - see
# readonly-mcp/reconciler.example.json); apply.sh's own deploy/verify checks
# die() loudly if it's missing. Once enabled, each of the four personal
# records activates independently; there is no static inventory and no
# all-or-nothing set.
READONLY_MCP_ENABLED="1"
# Coder's control plane and its isolated rootless workspace daemon run on
# ai02. It has no host Docker socket and no default AI/MCP credentials.
CODER_ENABLED="1"

DEFAULT_ACCELERATOR="auto"
PRIMARY_SWARM_NODE="$AI01_NODE_NAME"
MODEL_PROFILE_NODE="$AI01_NODE_NAME"

# ai01: AMD Ryzen AI Max+ PRO 395 (Strix Halo), Radeon 8060S. ai02: AMD
# Ryzen 7 255, Radeon 780M. Confirmed via https://rocm.docs.amd.com's
# per-model GPU picker (fam=ryzen) - see ensure_amd_driver() in apply.sh for
# why this isn't auto-detected instead.
AI01_ROCM_GFX_VERSION="gfx1151"
AI02_ROCM_GFX_VERSION="gfx1103"
case "${NODE_NAME:-}" in
  "$AI01_NODE_NAME") AMD_ROCM_GFX_VERSION="$AI01_ROCM_GFX_VERSION" ;;
  "$AI02_NODE_NAME") AMD_ROCM_GFX_VERSION="$AI02_ROCM_GFX_VERSION" ;;
esac

CERT_DOMAIN="m01.labs.kurkin-family.ru"
CERT_DIR="/mnt/storage/certbot-data/live/m01.labs.kurkin-family.ru"

AI01_HOST="ai01.m01.labs.kurkin-family.ru"
AI02_HOST="ai02.m01.labs.kurkin-family.ru"
OPENWEBUI_HOST="openwebui.m01.labs.kurkin-family.ru"
OPENCLAW_HOST="openclaw.m01.labs.kurkin-family.ru"
PORTAINER_HOST="portainer.m01.labs.kurkin-family.ru"
AUTHENTIK_HOST="authentik.m01.labs.kurkin-family.ru"
METAMCP_HOST="metamcp.m01.labs.kurkin-family.ru"
AGENTGATEWAY_HOST="agentgateway.m01.labs.kurkin-family.ru"
CODER_HOST="coder.m01.labs.kurkin-family.ru"

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

NGINX_SITE_AI01_SOURCE="${INSTALLATION_DIR}/nginx/ai01.conf"
NGINX_SITE_AI02_SOURCE="${INSTALLATION_DIR}/nginx/ai02.conf"

MODEL_PROFILE_SCRIPT="${INSTALLATION_DIR}/apply-model-profile.sh"
