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
LINUX01_NODE_NAME="linux01"

AI01_IP="10.20.0.200"
LINUX01_IP="10.20.0.204"

TRUSTED_CIDRS=(
  "10.20.0.0/24"
  "10.4.0.0/24"
)

# There used to be an --auth-mode bootstrap|enforced switch here, with
# "enforced" wrapping every service in Authentik forward-auth (auth_request)
# at the nginx layer. Removed (2026-09-13): neither lmstudio nor openclaw
# can actually work behind that layer, for different reasons - lmstudio's
# headless CLI has no "Require Authentication"/external-auth support
# upstream at all (lmstudio-ai/lmstudio-bug-tracker#1674); openclaw is
# ai-stand's own gateway and simply was never built with Authentik-
# compatible external auth (not an upstream limitation to cite). "enforced"
# was therefore never actually usable end-to-end - an audit confirmed it
# would fail closed on lmstudio specifically - so the permanent, only mode
# is what "bootstrap" used to mean: nginx reverse-proxies plainly, and each
# service that has its own native OIDC login (OpenWebUI, Portainer,
# agentgateway) is protected by that instead.

# Confirmed live on this installation (opencode + qwen3.6-35b-a3b): LM
# Studio's /v1/chat/completions rejects role:"tool" messages whose content
# is an image-bearing content-parts array with a 400 ("Invalid 'messages'
# in payload") - triggered by opencode's `read` tool attaching non-text
# file reads as content parts. See docker/lmstudio-proxy/server.mjs. Off
# generically; this installation has confirmed the need, so it's on here.
LMSTUDIO_PROXY_FLATTEN_TOOL_RESULT_CONTENT_ENABLED="1"

DEFAULT_ACCELERATOR="auto"
PRIMARY_SWARM_NODE="$AI01_NODE_NAME"
MODEL_PROFILE_NODE="$AI01_NODE_NAME"

# ai01: AMD Ryzen AI Max+ PRO 395 (Strix Halo), Radeon 8060S. linux01: AMD
# Ryzen 7 255, Radeon 780M. Confirmed via https://rocm.docs.amd.com's
# per-model GPU picker (fam=ryzen) - see ensure_amd_driver() in apply.sh for
# why this isn't auto-detected instead.
AI01_ROCM_GFX_VERSION="gfx1151"
LINUX01_ROCM_GFX_VERSION="gfx1103"
case "${NODE_NAME:-}" in
  "$AI01_NODE_NAME") AMD_ROCM_GFX_VERSION="$AI01_ROCM_GFX_VERSION" ;;
  "$LINUX01_NODE_NAME") AMD_ROCM_GFX_VERSION="$LINUX01_ROCM_GFX_VERSION" ;;
esac

CERT_DOMAIN="m01.labs.kurkin-family.ru"
CERT_DIR="/mnt/storage/certbot-data/live/m01.labs.kurkin-family.ru"

AI01_HOST="ai01.m01.labs.kurkin-family.ru"
LINUX01_HOST="linux01.m01.labs.kurkin-family.ru"
LMSTUDIO_HOST="lmstudio.m01.labs.kurkin-family.ru"
LMSTUDIO_PROXY_HOST="lmstudio-proxy.m01.labs.kurkin-family.ru"
OPENWEBUI_HOST="openwebui.m01.labs.kurkin-family.ru"
OPENCLAW_HOST="openclaw.m01.labs.kurkin-family.ru"
PORTAINER_HOST="portainer.m01.labs.kurkin-family.ru"
AUTHENTIK_HOST="authentik.m01.labs.kurkin-family.ru"
METAMCP_HOST="metamcp.m01.labs.kurkin-family.ru"
AGENTGATEWAY_HOST="agentgateway.m01.labs.kurkin-family.ru"

PORTAINER_MULTI_A_HOST="$PORTAINER_HOST"
AUTHENTIK_PUBLIC_URL="https://${AUTHENTIK_HOST}"
OPENWEBUI_PUBLIC_URL="https://${OPENWEBUI_HOST}"
OPENCLAW_PUBLIC_ORIGIN="https://${OPENCLAW_HOST}"
PORTAINER_PUBLIC_URL="https://${PORTAINER_HOST}"

NGINX_SITE_AI01_SOURCE="${INSTALLATION_DIR}/nginx/ai01.conf"
NGINX_SITE_LINUX01_SOURCE="${INSTALLATION_DIR}/nginx/linux01.conf"

MODEL_PROFILE_SCRIPT="${INSTALLATION_DIR}/apply-model-profile.sh"
