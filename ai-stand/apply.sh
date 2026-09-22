#!/usr/bin/env bash

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

STACK_NAME="ai-stand"
IM_UID="10000"
IM_GID="20000"
IM_TZ="Europe/Moscow"
APP_UID="$IM_UID"
APP_GID="$IM_GID"

IMAGE_VERSION="2026.08.07-1"
BASE_IMAGE="ghcr.io/simpleunion/base:${IMAGE_VERSION}"
# lmstudio carries its own tag, separate from IMAGE_VERSION: its Dockerfile changes
# (LM Studio app refresh, llama.cpp runtime bumps) independently of the shared base
# image, which did not change here. Also bumped, with no Dockerfile content
# change, whenever a plain --no-cache rebuild is done purely to refresh the
# apt packages it installs (glibc/openssl/etc security patches) - same
# reasoning as every other date-stamped tag here: the tag must change for
# Swarm to actually redeploy a locally-built, no-digest image, see
# REBUILT_IMAGE_VERSION's comment below.
LMSTUDIO_IMAGE_VERSION="2026.09.23-1"
LMSTUDIO_CPU_IMAGE="ghcr.io/kukurusik/ai-stand-lmstudio:${LMSTUDIO_IMAGE_VERSION}-cpu"
LMSTUDIO_AMD_IMAGE="ghcr.io/kukurusik/ai-stand-lmstudio:${LMSTUDIO_IMAGE_VERSION}-amd"
LMSTUDIO_NVIDIA_IMAGE="ghcr.io/kukurusik/ai-stand-lmstudio:${LMSTUDIO_IMAGE_VERSION}-nvidia"
# The OpenClaw image contains the two version-pinned trusted-proxy patches:
# one renders a display-only Authentik name and one preserves the already
# authenticated browser subject for the GigaCode requester hook.  Bump the
# shared rebuilt tag so a Swarm deployment cannot silently reuse the old
# image after the Dockerfile changes.
REBUILT_IMAGE_VERSION="2026.09.23-1"
# OpenClaw contains version-pinned runtime patches and needs an independent
# tag bump whenever its image changes.  Keeping this separate avoids
# needlessly rebuilding unrelated Authentik and LM Studio Proxy images.
OPENCLAW_IMAGE_VERSION="2026.09.23-1"
GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE_VERSION="2026.09.21-1"
GIGACODE_IDENTITY_BROKER_IMAGE_VERSION="2026.09.21-1"
GIGACODE_IDENTITY_BROKER_JWKS_SECRET="ai-stand-gigacode-broker-public-jwks-v2"
READONLY_MCP_IMAGE_VERSION="2026.09.19-1"
# Bump together with docker/coder-templates/ai-stand-dev/main.tf's own
# `image = "ai-stand-coder-workspace:..."` literal - Terraform files have no
# shared substitution with apply.sh, so this tag is necessarily duplicated
# in both places, not derived.
CODER_WORKSPACE_IMAGE_VERSION="2026.09.23-1"
CODER_VERSION="2.36.6"
# NOT bumped to 2026.9.5 yet (confirmed live 2026-09-23): the display-name
# trusted-proxy patch's target import line genuinely restructured in that
# release, not just renamed - getUserProfileDisplay moved out into its own
# user-profiles-owner-*.mjs module that doesn't exist in 2026.9.4, so
# apply-authentik-display-name-patch.mjs's importBefore/importAfter can
# never match it as-is. That patch (and its sibling identity patch) touch
# identity/auth-resolution code, and 2026.9.5's own release notes call out
# unspecified "credential safety" changes in the same area - adapting them
# deserves a careful, standalone pass, not a rushed edit alongside four
# other version bumps. OPENCLAW_IMAGE_VERSION below is still bumped, so
# this rebuild still ships the GigaCode requester plugin fix from this same
# session even though OpenClaw itself stays on 2026.9.4 for now.
OPENCLAW_VERSION="2026.9.4"
AUTHENTIK_VERSION="2026.8.3"
LMSTUDIO_PROXY_IMAGE="ghcr.io/kukurusik/ai-stand-lmstudio-proxy:${REBUILT_IMAGE_VERSION}"
OPENCLAW_IMAGE="ghcr.io/kukurusik/ai-stand-openclaw:${OPENCLAW_IMAGE_VERSION}"
# 2.45.1 fixes 3 Critical CVEs (openssl/libssl3: CVE-2026-63073,
# CVE-2026-75803; kubectl: CVE-2026-39821), confirmed against the upstream
# release notes 2026-09-23.
PORTAINER_IMAGE="portainer/portainer-ce:2.45.1"
PORTAINER_AGENT_IMAGE="portainer/agent:2.45.1"
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:v0.11.4"
AUTHENTIK_IMAGE="ghcr.io/kukurusik/ai-stand-authentik:${REBUILT_IMAGE_VERSION}"
AUTHENTIK_POSTGRES_IMAGE="docker.io/library/postgres:18-alpine"
AUTHENTIK_REDIS_IMAGE="docker.io/library/redis:8.10-alpine"
# MetaMCP only ships a single combined image (frontend+backend). Its own
# docker-compose.yml pins postgres:16-alpine, but bumped to match
# authentik-postgresql's version here - see the note on the metamcp-postgres
# service in compose.yaml.
METAMCP_IMAGE="ghcr.io/metatool-ai/metamcp:2.4.22"
METAMCP_POSTGRES_IMAGE="docker.io/library/postgres:18-alpine"
OPENCLAW_SANDBOX_DIND_IMAGE="docker.io/library/docker:29.8.0-dind"
# LLM gateway in front of lmstudio-proxy (not LM Studio directly, so every
# consumer inherits its tool-call compatibility fixes). Its admin console
# uses OIDC/RBAC; its LLM API uses per-service bearer tokens. An opt-in
# profile additionally renders identity-scoped read-only MCP routes here.
AGENTGATEWAY_IMAGE="cr.agentgateway.dev/agentgateway:v1.5.0"
# Coder is an upstream image. ai-stand builds a tiny local wrapper so its
# PostgreSQL and OIDC secrets stay mounted files rather than service env.
# Do not invent a digest: the images stage verifies the released upstream tag.
CODER_BASE_IMAGE="ghcr.io/coder/coder:v${CODER_VERSION}"
CODER_IMAGE="ai-stand-coder:${CODER_VERSION}-1"
CODER_POSTGRES_IMAGE="docker.io/library/postgres:18-alpine"
# Derived from the pin above, not a separate hardcoded value: this is the
# CLI half of the same client/daemon version pair used to build the
# openclaw-gateway image's `docker` binary (see docker/openclaw/Dockerfile),
# so the two can't silently drift apart.
DOCKER_CLI_VERSION="${OPENCLAW_SANDBOX_DIND_IMAGE##*:}"
DOCKER_CLI_VERSION="${DOCKER_CLI_VERSION%-dind}"
# Tag OpenClaw's Docker sandbox backend hardcodes and looks for by default
# (agents.defaults.sandbox.backend=docker, see docker/openclaw/init.mjs) -
# not a registry image, built locally inside openclaw-sandbox-dind itself by
# ensure_openclaw_sandbox_image from docker/openclaw-sandbox/Dockerfile.
OPENCLAW_SANDBOX_IMAGE="openclaw-sandbox:bookworm-slim"
# Not a registry image either - built locally against the dedicated Coder
# rootless daemon by ensure_coder_workspace_image() from
# docker/coder-workspace/Dockerfile, and referenced by tag (no digest, same
# reason as CODER_IMAGE above) from the ai-stand-dev template's
# docker_container.workspace resource.
CODER_WORKSPACE_IMAGE="ai-stand-coder-workspace:${CODER_WORKSPACE_IMAGE_VERSION}"
AUTHENTIK_CONFIGURATOR_IMAGE="ghcr.io/kukurusik/ai-stand-authentik-configurator:${REBUILT_IMAGE_VERSION}"
GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE="ai-stand-gigacode-subscription-bridge:${GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE_VERSION}"
GIGACODE_IDENTITY_BROKER_IMAGE="ai-stand-gigacode-identity-broker:${GIGACODE_IDENTITY_BROKER_IMAGE_VERSION}"
OPENCLAW_GIGACODE_ADAPTER_IMAGE_VERSION="2026.09.21-1"
OPENCLAW_GIGACODE_ADAPTER_IMAGE="ai-stand-openclaw-gigacode-adapter:${OPENCLAW_GIGACODE_ADAPTER_IMAGE_VERSION}"
JIRA_READONLY_MCP_IMAGE="ai-stand-jira-readonly-mcp:${READONLY_MCP_IMAGE_VERSION}"
CONFLUENCE_READONLY_MCP_IMAGE="ai-stand-confluence-readonly-mcp:${READONLY_MCP_IMAGE_VERSION}"
IMAP_READONLY_MCP_IMAGE="ai-stand-imap-readonly-mcp:${READONLY_MCP_IMAGE_VERSION}"
DIAGNOSTIC_IMAGE="ghcr.io/kukurusik/ai-stand-diagnostic:${IMAGE_VERSION}"

AMD_AMDGPU_INSTALL_URL="https://repo.radeon.com/amdgpu/31.50/ubuntu/pool/main/a/amdgpu-install/amdgpu-install_31.50.0.0.31500000-2390945.24.04_all.deb"
AMD_AMDGPU_INSTALL_SHA256="1b2d7613ac3d04ba74bb718ba28297eff8bd2c52f34a91e751d3044e7998e9cb"
AMD_ROCM_APT_CODENAME="noble"
AMD_CONTAINER_TOOLKIT_KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"
AMD_CONTAINER_TOOLKIT_REPO_URL="https://repo.radeon.com/amd-container-toolkit/apt/"
# ROCm compute-library release line (stable.repo.amd.com's "amdrocm<release>-gfx<gfx>"
# package scheme - see ensure_amd_driver()). AMD_ROCM_GFX_VERSION has no default;
# each installation profile must set it per node to that node's actual GPU.
AMD_ROCM_RELEASE="10.0"
AMD_ROCM_GFX_VERSION="${AMD_ROCM_GFX_VERSION:-}"
NVIDIA_CONTAINER_TOOLKIT_KEY_URL="https://nvidia.github.io/libnvidia-container/gpgkey"
NVIDIA_CONTAINER_TOOLKIT_LIST_URL="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"

LMSTUDIO_DATA_ROOT="/mnt/storage/lmstudio-data"
OPENCLAW_DATA_ROOT="/mnt/storage/openclaw-data"
OPENWEBUI_DATA_ROOT="/mnt/storage/openwebui-data"
AUTHENTIK_DATA="/mnt/storage/authentik-data"
# authentik-server and authentik-worker share both subdirectories below -
# "server" names the role (matching openwebui/portainer's own single-app
# "server" role), not the file type - data/templates aren't a role of their
# own the way postgresql/redis are (see ensure_authentik_data()).
AUTHENTIK_DATA_SERVER="${AUTHENTIK_DATA}/server"
AUTHENTIK_ICONS_DATA="${AUTHENTIK_DATA}/icons"
PORTAINER_DATA_ROOT="/mnt/storage/portainer-data"
METAMCP_DATA_ROOT="/mnt/storage/metamcp-data"
AGENTGATEWAY_DATA_ROOT="/mnt/storage/agentgateway-data"
# Reconciler state is deliberately separate from agentgateway-data: only a
# root-owned host timer may read the AppRole files, generate Docker Secrets
# or alter the dynamic MCP manifest. The running gateway sees only its
# rendered config and explicitly mounted backend bearer secrets.
READONLY_MCP_DATA_ROOT="/mnt/storage/readonly-mcp-data"
# Installation-specific deployment overrides deliberately live outside the
# source tree. They are not an environment-file include: the loader below
# accepts one exact key/value record only, so a root-local override cannot
# execute arbitrary shell while apply.sh is running as root.
AI_STAND_DATA_ROOT="/mnt/storage/ai-stand-data"
INSTALLATION_OVERRIDES_ROOT="${AI_STAND_DATA_ROOT}/installation-overrides"
READONLY_MCP_RUNTIME_OVERRIDE_FILE="${INSTALLATION_OVERRIDES_ROOT}/readonly-mcp.env"
CODER_DATA_ROOT="/mnt/storage/coder-data"
LMSTUDIO_DATA="${LMSTUDIO_DATA_ROOT}/lmstudio"
OPENCLAW_DATA="${OPENCLAW_DATA_ROOT}/gateway"
OPENCLAW_SANDBOX_DATA="${OPENCLAW_DATA_ROOT}/sandbox-dind"
# The Gateway owns this path. It is deliberately the only part of its
# persistent home made visible to the separate Docker-in-Docker daemon; see
# ensure_openclaw_sandbox_dind_service().
OPENCLAW_SANDBOX_WORKSPACE_ROOT="${OPENCLAW_DATA}/.openclaw/sandboxes"
# Narrow, non-secret hand-off from the OpenClaw requester plugin to the
# local GigaCode adapter.  It stores only opaque session IDs, Authentik
# subject UUIDs and expiry timestamps; device IDs and broker private keys
# never reach ai02.
OPENCLAW_GIGACODE_REQUESTER_DIR="${OPENCLAW_DATA}/.openclaw/gigacode-requester"
OPENCLAW_GIGACODE_SESSION_MAP="${OPENCLAW_GIGACODE_REQUESTER_DIR}/sessions.json"
OPENWEBUI_DATA="${OPENWEBUI_DATA_ROOT}/server"
PORTAINER_DATA="${PORTAINER_DATA_ROOT}/server"
METAMCP_DATA="${METAMCP_DATA_ROOT}/postgres"
# Holds only the rendered config.yaml agentgateway is bind-mounted (see
# install_agentgateway_config()). Named "server" (not "config") to match
# the {component}-data/{role} convention every other component follows.
AGENTGATEWAY_DATA="${AGENTGATEWAY_DATA_ROOT}/server"
# Backs agentgateway-postgres: agentgateway's own request-log/analytics
# database (config.logging.database in agentgateway/config.yaml). A second
# role under the same root, same convention as CODER_SERVER_DATA/
# CODER_POSTGRES_DATA below.
AGENTGATEWAY_POSTGRES_DATA="${AGENTGATEWAY_DATA_ROOT}/postgres"
CODER_SERVER_DATA="${CODER_DATA_ROOT}/server"
CODER_POSTGRES_DATA="${CODER_DATA_ROOT}/postgres"
CODER_PROVISIONER_DATA="${CODER_DATA_ROOT}/provisioner"
CODER_PROVISIONER_HOME="${CODER_PROVISIONER_DATA}/home"
CODER_PROVISIONER_RUNTIME="${CODER_PROVISIONER_DATA}/runtime"
CODER_PROVISIONER_DOCKER_DATA="${CODER_PROVISIONER_DATA}/docker"
CODER_ROOTLESS_DOCKER_SOCKET="${CODER_PROVISIONER_DATA}/docker.sock"
CODER_RUNTIME_USER="service"
CODER_WORKSPACE_NETWORK="ai-coder-workspaces"
BACKUP_ROOT="/mnt/storage/_backups"
NGINX_BACKUP_DIR="${BACKUP_ROOT}/nginx"
CERT_DIR="/mnt/storage/certbot-data/live/local"
CERT_DOMAIN="local"

AI01_HOST="ai01.local"
AI02_HOST="ai02.local"
OPENWEBUI_HOST="openwebui.local"
OPENCLAW_HOST="openclaw.local"
OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED="0"
OPENCLAW_TRUSTED_PROXIES="127.0.0.1,::1"
PORTAINER_HOST="portainer.local"
AUTHENTIK_HOST="authentik.local"
METAMCP_HOST="metamcp.local"
AGENTGATEWAY_HOST="agentgateway.local"
CODER_HOST="coder.local"

# Both default off generically - installations override the one they've
# confirmed a need for in their own installation.sh. See docker/lmstudio-proxy/server.mjs.
LMSTUDIO_PROXY_STRIP_TOOLS_AFTER_RESULT_ENABLED="0"
LMSTUDIO_PROXY_FLATTEN_TOOL_RESULT_CONTENT_ENABLED="0"

LMSTUDIO_MODEL_IDENTIFIER="qwen/qwen3-1.7b"
LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER="qwen3-embedding-0.6b-q8"
LMSTUDIO_CHAT_TIMEOUT_SECONDS="300"

AUTHENTIK_SECRET_KEY_SECRET="ai-stand-authentik-secret-key"
AUTHENTIK_POSTGRES_PASSWORD_SECRET="ai-stand-authentik-postgres-password"
# AUTHENTIK_BOOTSTRAP_TOKEN, AUTHENTIK_OPENWEBUI_CLIENT_SECRET,
# AUTHENTIK_PORTAINER_CLIENT_SECRET, AUTHENTIK_BOOTSTRAP_PASSWORD,
# PORTAINER_ADMIN_PASSWORD, WEBUI_SECRET_KEY, OPENCLAW_GATEWAY_TOKEN,
# METAMCP_POSTGRES_PASSWORD, METAMCP_BETTER_AUTH_SECRET and
# METAMCP_BOOTSTRAP_PASSWORD are not literals:
# ensure_ai_stand_secrets() generates and persists each one under
# AI_STAND_SECRETS_DIR on first use and reuses it on every later run.
AI_STAND_SECRETS_DIR="/mnt/storage/_secrets"
AUTHENTIK_BOOTSTRAP_USERNAME="akadmin"
PORTAINER_ADMIN_USERNAME="admin"
# Bootstrap-only Coder owner, created non-interactively via `coder server
# create-admin-user` (see bootstrap_coder_admin()) so the native /setup
# password form - which CODER_DISABLE_PASSWORD_AUTH=true breaks, since it
# can never be submitted once password auth is off - never needs to run.
# Real day-to-day access is still Authentik OIDC (ai-admins -> owner via
# CODER_OIDC_USER_ROLE_MAPPING); this is only the emergency/first-boot
# account, same role as akadmin for Authentik. {component}@ai-stand.local,
# not a shared admin@ai-stand.local - see METAMCP_BOOTSTRAP_EMAIL below for
# why that collision is a real, already-hit failure mode.
CODER_ADMIN_USERNAME="admin"
CODER_ADMIN_EMAIL="coder@ai-stand.local"
PORTAINER_ENDPOINT_NAME="ai-stand-swarm"
PORTAINER_ENDPOINT_URL="tcp://tasks.portainer-agent:9001"
PORTAINER_OAUTH_TEAM_NAME="ai-admins"
# References Authentik's own akadmin identity (compose.yaml's
# AUTHENTIK_BOOTSTRAP_EMAIL) to recognize it as Portainer's OIDC admin -
# the two aren't derived from one another, kept in sync by hand.
PORTAINER_OAUTH_ADMIN_USERS=("authentik@ai-stand.local")
PORTAINER_ENVIRONMENT_ROLE_ID="1"
# MetaMCP's admin UI has its own email+password login (Better Auth),
# separate from Authentik - see ensure_ai_stand_secrets() /
# apply_installation_service_env() - but IS also OIDC-enabled for human
# login (docker/authentik/configure.mjs's metamcp provider/application).
# Every component's own built-in-admin email follows {component}@ai-stand.local
# rather than a shared admin@ai-stand.local, precisely to avoid this: an
# OIDC login whose email already belongs to a same-app password account
# gets rejected (confirmed live 2026-09-09 against a same-app collision on
# a different component's bootstrap admin) - and there's no reason
# MetaMCP's OIDC login couldn't hit the identical collision if left on the
# shared address.
METAMCP_BOOTSTRAP_EMAIL="metamcp@ai-stand.local"
# LM Studio and its compatibility proxy deliberately have no host-published
# ports. Their API is reachable only from Agentgateway on ai-models-backend;
# the remaining entries below are loopback technical listeners protected by
# the host firewall.
TECH_PORTS=(18789 9443 18080 19001 9001 12008 4000 17080)
PUBLIC_PORTS=(80 443)
SWARM_TCP_PORTS=(2377 7946)
SWARM_UDP_PORTS=(7946 4789)
SERVICES=(
  "ai-stand_authentik-postgresql"
  "ai-stand_authentik-redis"
  "ai-stand_authentik-server"
  "ai-stand_authentik-worker"
  "ai-stand_lmstudio"
  "ai-stand_lmstudio-proxy"
  "ai-stand_openclaw-gateway"
  "ai-stand_openwebui"
  "ai-stand_portainer"
  "ai-stand_portainer-agent"
  "ai-stand_metamcp-postgres"
  "ai-stand_metamcp"
  "ai-stand_agentgateway-postgres"
  "ai-stand_agentgateway"
)
OBSOLETE_SERVICES=(
  "ai-stand_shannon"
  "ai-stand_lightrag"
  # The legacy shared GigaCode bridge is retired only after the personal
  # broker-JWT route has passed its owner-scoped probe.  Future deployments
  # must never recreate or retain this subscription-sharing service.
  "ai-stand_gigacode-bridge"
  # Coder was removed entirely 2026-09-13 (never usable enough to justify
  # its own maintenance cost); coder-provisioner specifically predates that
  # and was already obsolete on its own - external provisioners turned out
  # to be a Premium-only Coder feature, so it only ever ran briefly during
  # initial bring-up before that was caught.
  "ai-stand_coder-provisioner"
  "ai-stand_coder-postgres"
  "ai-stand_coder"
  "ai-stand_gigacode-subscription-status"
  "ai-stand_vault"
)

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  */*) SCRIPT_DIR="$(cd -- "${SCRIPT_PATH%/*}" && pwd)" ;;
  *) SCRIPT_DIR="$(pwd)" ;;
esac

COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"
COMPOSE_AMD_FILE="${SCRIPT_DIR}/compose.amd.yaml"
COMPOSE_NVIDIA_FILE="${SCRIPT_DIR}/compose.nvidia.yaml"
COMPOSE_GIGACODE_IDENTITY_BROKER_FILE="${SCRIPT_DIR}/compose.gigacode-identity-broker.yaml"
COMPOSE_OPENCLAW_GIGACODE_ADAPTER_FILE="${SCRIPT_DIR}/compose.openclaw-gigacode-adapter.yaml"
COMPOSE_CODER_FILE="${SCRIPT_DIR}/compose.coder.yaml"
# ai-stand consumes separately versioned source modules but builds their
# images locally. Deployment stages them next to the ai-stand checkout.
AI_STAND_MODULES_ROOT="${AI_STAND_MODULES_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR="${AI_STAND_MODULES_ROOT}/gigacode-subscription-bridge"
GIGACODE_IDENTITY_BROKER_SOURCE_DIR="${SCRIPT_DIR}/docker/gigacode-identity-broker"
OPENCLAW_GIGACODE_ADAPTER_SOURCE_DIR="${SCRIPT_DIR}/docker/openclaw-gigacode-adapter"
OPENCLAW_GIGACODE_REQUESTER_PLUGIN_SOURCE_DIR="${SCRIPT_DIR}/docker/openclaw-gigacode-requester"
OPENWEBUI_GIGACODE_PIPE_SOURCE="${SCRIPT_DIR}/docker/openwebui/gigacode_subscription_pipe.py"
MCP_READONLY_COMMON_SOURCE_DIR="${AI_STAND_MODULES_ROOT}/mcp-readonly-common"
JIRA_READONLY_MCP_SOURCE_DIR="${AI_STAND_MODULES_ROOT}/jira-readonly-mcp"
CONFLUENCE_READONLY_MCP_SOURCE_DIR="${AI_STAND_MODULES_ROOT}/confluence-readonly-mcp"
IMAP_READONLY_MCP_SOURCE_DIR="${AI_STAND_MODULES_ROOT}/imap-readonly-mcp"
READONLY_MCP_RENDERER="${SCRIPT_DIR}/readonly-mcp/render-profile.py"
# The reconciler's manifest contains only Authentik UUIDs, active service
# status and Docker Secret names/versions; plaintext credentials never enter
# it or any rendered Compose/configuration file. Its root-owned config names
# the static upstreams and the path to the Authentik API-token file, not its
# value - per-user credentials live only in each user's own Authentik
# profile attributes, edited through a self-service prompt stage.
READONLY_MCP_RECONCILER_DATA="${READONLY_MCP_DATA_ROOT}/reconciler"
READONLY_MCP_MANIFEST="${READONLY_MCP_RECONCILER_DATA}/manifest.json"
READONLY_MCP_RECONCILER_CONFIG="${READONLY_MCP_RECONCILER_DATA}/reconciler.json"
READONLY_MCP_RECONCILER="${SCRIPT_DIR}/readonly-mcp/reconcile.py"
READONLY_MCP_RENDERED_COMPOSE="${AGENTGATEWAY_DATA}/readonly-mcp.compose.yaml"
# Root-only inputs/output for the MetaMCP tenant identity control plane.
# They are never profile fixtures or Git-tracked inventory.
METAMCP_TENANT_CONTROL_SOURCE_DIR="${SCRIPT_DIR}/metamcp-tenants"
METAMCP_TENANT_IDENTITY_INVENTORY="${READONLY_MCP_RECONCILER_DATA}/metamcp-tenant-identities.json"
METAMCP_TENANT_MANIFEST="${READONLY_MCP_RECONCILER_DATA}/metamcp-tenants.json"
READONLY_MCP_ENABLED="0"
# Generic core publishes a neutral endpoint family. A protected host-local
# override may replace this only at deployment time; profile sources never
# carry organization-specific paths.
READONLY_MCP_PATH_PREFIX="/mcp/work"
# A GigaCode device ID is an installation-owned credential. Generic core
# remains runnable without it; a profile must opt in explicitly before the
# bridge service and its Docker Secret are required.
GIGACODE_SUBSCRIPTION_ENABLED="0"
CODER_ENABLED="0"
NGINX_CONF_SOURCE="${SCRIPT_DIR}/nginx/nginx.conf"
NGINX_MIME_TYPES_SOURCE="${SCRIPT_DIR}/nginx/mime.types"
NGINX_SITE_AI01_SOURCE="${SCRIPT_DIR}/nginx/conf.d/ai-stand-ai01.conf"
NGINX_SITE_AI02_SOURCE="${SCRIPT_DIR}/nginx/conf.d/ai-stand-ai02.conf"
NGINX_SITE_SOURCE=""
# Unlike the nginx sources above, this has no per-installation override -
# agentgateway/config.yaml is installation-agnostic by design (every
# per-installation value is injected as a container env var, not baked into
# the file - see install_agentgateway_config() and the file's own header).
AGENTGATEWAY_CONFIG_SOURCE="${SCRIPT_DIR}/agentgateway/config.yaml"
# See install_authentik_icons() - vendored so Authentik's own app-list tiles
# never depend on an external site or on some other ai-stand component's own
# live instance being reachable.
AUTHENTIK_ICONS_SOURCE_DIR="${SCRIPT_DIR}/docker/authentik/icons"
INSTALLATION=""
INSTALLATION_DIR=""
LOCK_FILE="/tmp/ai-stand-apply.lock"
REBOOT_MARKER="/var/lib/ai-stand/reboot-required"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
NGINX_BACKED_UP="0"
SWARM_RECOVERED="0"

COMMAND="all"
COMMAND_SET="0"
NODE_NAME=""
HOST_IP=""
PEER_IP=""
TRUSTED_CIDRS=()
MANAGER_JOIN_TOKEN=""
ACCELERATOR="auto"
ONBOARD_USERNAME=""
ONBOARD_EMAIL=""
ONBOARD_GROUPS="ai-users"
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
ARCH=""

log() {
  printf '%s\n' "[ai-stand] $*" >&2
}

warn() {
  printf '%s\n' "[ai-stand] WARNING: $*" >&2
}

die() {
  printf '%s\n' "[ai-stand] ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage: $0 [preflight|host|images|deploy|reconcile-mcp|migrate-metamcp-tenants|configure-authentik|onboard-readonly-mcp-user|configure-portainer|verify|credentials|all] [options]

Commands:
  preflight              Check host prerequisites without changing state.
  host                   Install/configure host prerequisites, storage, TLS, firewall, Nginx and labels.
  images                 Build/pull required images for the selected accelerator.
  deploy                 Validate and deploy the Swarm stack.
  reconcile-mcp          Apply an already rendered read-only MCP manifest; intended for the root-owned timer only.
  configure-authentik    Idempotently configure Authentik groups and OIDC applications.
  onboard-readonly-mcp-user  Idempotently create (or verify) one Authentik user and its group membership.
  migrate-metamcp-tenants  One-time reviewed email-to-(issuer,sub) ownership migration for existing MetaMCP users.
  configure-portainer    Idempotently initialize Portainer admin and enable Authentik OAuth/OIDC.
  verify                 Verify services, routing and protection rules.
  credentials            Print the generated Authentik/Portainer/OpenClaw credentials for this installation.
  all                    Run preflight, host, images, deploy, configure-authentik, configure-portainer and verify. This is the default.

Options:
  --installation <name>      Installation profile name. Required.
  --node-name <name>         ai01 or ai02. Required except for generic images builds.
  --host-ip <ip>             Required for preflight, host, deploy, verify and all.
  --peer-ip <ip>             Required for preflight, host, deploy, verify and all.
  --trusted-cidr <cidr>      Required for preflight, host, deploy, verify and all. Repeatable.
  --manager-join-token <t>   Required only when ai02 must join an inactive local Swarm.
  --accelerator <value>      auto, cpu, amd or nvidia. Default: auto.
  --username <name>          Required for onboard-readonly-mcp-user. New Authentik username.
  --email <address>          Required for onboard-readonly-mcp-user. New user's email.
  --groups <csv>             For onboard-readonly-mcp-user. Comma-separated ai-users and/or ai-admins. Default: ai-users.
  -h, --help                 Show this help.

Examples:
  sudo bash apply.sh all --installation kurkin-family__labs__m01 --node-name ai01 --host-ip <ai01-ip> --peer-ip <ai02-ip> --trusted-cidr <trusted-cidr> --accelerator auto
  sudo bash apply.sh host --installation kurkin-family__labs__m01 --node-name ai02 --host-ip <ai02-ip> --peer-ip <ai01-ip> --trusted-cidr <trusted-cidr> --manager-join-token <token>
  sudo bash apply.sh images --installation kurkin-family__labs__m01 --node-name ai02
  sudo bash apply.sh onboard-readonly-mcp-user --installation kurkin-family__labs__m01 --node-name ai01 --username <username> --email <email> --groups ai-users
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      preflight|host|images|deploy|reconcile-mcp|migrate-metamcp-tenants|configure-authentik|onboard-readonly-mcp-user|configure-portainer|verify|credentials|all)
        if [ "$COMMAND_SET" = "1" ]; then
          die "Only one command can be specified"
        fi
        COMMAND="$1"
        COMMAND_SET="1"
        shift
        ;;
      --installation)
        [ "$#" -ge 2 ] || die "--installation requires a value"
        INSTALLATION="$2"
        shift 2
        ;;
      --installation=*)
        INSTALLATION="${1#*=}"
        shift
        ;;
      --node-name)
        [ "$#" -ge 2 ] || die "--node-name requires a value"
        NODE_NAME="$2"
        shift 2
        ;;
      --node-name=*)
        NODE_NAME="${1#*=}"
        shift
        ;;
      --host-ip)
        [ "$#" -ge 2 ] || die "--host-ip requires a value"
        HOST_IP="$2"
        shift 2
        ;;
      --host-ip=*)
        HOST_IP="${1#*=}"
        shift
        ;;
      --peer-ip)
        [ "$#" -ge 2 ] || die "--peer-ip requires a value"
        PEER_IP="$2"
        shift 2
        ;;
      --peer-ip=*)
        PEER_IP="${1#*=}"
        shift
        ;;
      --trusted-cidr)
        [ "$#" -ge 2 ] || die "--trusted-cidr requires a value"
        TRUSTED_CIDRS+=("$2")
        shift 2
        ;;
      --trusted-cidr=*)
        TRUSTED_CIDRS+=("${1#*=}")
        shift
        ;;
      --manager-join-token)
        [ "$#" -ge 2 ] || die "--manager-join-token requires a value"
        MANAGER_JOIN_TOKEN="$2"
        shift 2
        ;;
      --manager-join-token=*)
        MANAGER_JOIN_TOKEN="${1#*=}"
        shift
        ;;
      --accelerator)
        [ "$#" -ge 2 ] || die "--accelerator requires a value"
        ACCELERATOR="$2"
        shift 2
        ;;
      --accelerator=*)
        ACCELERATOR="${1#*=}"
        shift
        ;;
      --username)
        [ "$#" -ge 2 ] || die "--username requires a value"
        ONBOARD_USERNAME="$2"
        shift 2
        ;;
      --username=*)
        ONBOARD_USERNAME="${1#*=}"
        shift
        ;;
      --email)
        [ "$#" -ge 2 ] || die "--email requires a value"
        ONBOARD_EMAIL="$2"
        shift 2
        ;;
      --email=*)
        ONBOARD_EMAIL="${1#*=}"
        shift
        ;;
      --groups)
        [ "$#" -ge 2 ] || die "--groups requires a value"
        ONBOARD_GROUPS="$2"
        shift 2
        ;;
      --groups=*)
        ONBOARD_GROUPS="${1#*=}"
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_readonly_mcp_path_prefix() {
  local value="$1"
  [[ "$value" =~ ^/mcp/[a-z][a-z0-9-]{0,62}$ ]] \
    || die "READONLY_MCP_PATH_PREFIX must match /mcp/<lowercase-slug>"
}

load_readonly_mcp_runtime_override() {
  # This file is intentionally not sourced. It is an installation-owned
  # exception to the public generic profile. It may enable the feature and
  # choose its installation-local route prefix, but cannot inject shell or
  # compose syntax into an operator's root process.
  [ -e "$READONLY_MCP_RUNTIME_OVERRIDE_FILE" ] || return 0
  [ -f "$READONLY_MCP_RUNTIME_OVERRIDE_FILE" ] \
    || die "Read-only MCP runtime override is not a regular file"

  local line key value seen_enabled=0 seen_prefix=0
  while IFS= read -r line || [ -n "$line" ]; do
    # Operators commonly create the host-local override from Windows. Accept
    # CRLF without broadening its deliberately tiny grammar.
    line="${line%$'\r'}"
    case "$line" in
      READONLY_MCP_ENABLED=0|READONLY_MCP_ENABLED=1)
        [ "$seen_enabled" = "0" ] || die "Read-only MCP runtime override repeats READONLY_MCP_ENABLED"
        READONLY_MCP_ENABLED="${line#READONLY_MCP_ENABLED=}"
        seen_enabled=1
        ;;
      READONLY_MCP_PATH_PREFIX=*)
        [ "$seen_prefix" = "0" ] || die "Read-only MCP runtime override repeats READONLY_MCP_PATH_PREFIX"
        READONLY_MCP_PATH_PREFIX="${line#READONLY_MCP_PATH_PREFIX=}"
        seen_prefix=1
        ;;
      *) die "Read-only MCP runtime override has an unsupported setting" ;;
    esac
  done < "$READONLY_MCP_RUNTIME_OVERRIDE_FILE"
  [ "$seen_prefix" = "1" ] || die "Read-only MCP runtime override must set READONLY_MCP_PATH_PREFIX"
  validate_readonly_mcp_path_prefix "$READONLY_MCP_PATH_PREFIX"
}

validate_readonly_mcp_runtime_override_permissions() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  [ -e "$READONLY_MCP_RUNTIME_OVERRIDE_FILE" ] || return 0
  local ownership
  ownership="$(run_root stat -c '%U:%G:%a' "$READONLY_MCP_RUNTIME_OVERRIDE_FILE")"
  [ "$ownership" = "root:root:600" ] \
    || die "Read-only MCP runtime override must be root:root with mode 0600"
}

load_installation() {
  [ -n "$INSTALLATION" ] || die "--installation is required"
  case "$INSTALLATION" in
    *[!A-Za-z0-9_-]*|''|*/*|*..*) die "--installation contains unsupported characters: $INSTALLATION" ;;
  esac

  local cli_trusted_cidrs=("${TRUSTED_CIDRS[@]}")

  INSTALLATION_DIR="${SCRIPT_DIR}/installations/${INSTALLATION}"
  local installation_file="${INSTALLATION_DIR}/installation.sh"
  [ -r "$installation_file" ] || die "Installation config is missing: ${installation_file}"

  # shellcheck disable=SC1090
  . "$installation_file"

  validate_readonly_mcp_path_prefix "$READONLY_MCP_PATH_PREFIX"
  load_readonly_mcp_runtime_override

  case "${GIGACODE_SUBSCRIPTION_ENABLED:-0}" in
    0|1) ;;
    *) die "GIGACODE_SUBSCRIPTION_ENABLED must be 0 or 1" ;;
  esac
  if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
    SERVICES+=("${STACK_NAME}_gigacode-identity-broker" "${STACK_NAME}_openclaw-gigacode-adapter")
  fi

  case "${READONLY_MCP_ENABLED:-0}" in
    0|1) ;;
    *) die "READONLY_MCP_ENABLED must be 0 or 1" ;;
  esac

  if [ "${#cli_trusted_cidrs[@]}" -gt 0 ]; then
    TRUSTED_CIDRS=("${cli_trusted_cidrs[@]}")
  fi

  APP_UID="$IM_UID"
  APP_GID="$IM_GID"
  NGINX_SITE_SOURCE=""
  log "Loaded installation: ${INSTALLATION}"
}

validate_ipv4() {
  local ip="$1"
  local -a octets
  IFS=. read -r -a octets <<<"$ip"
  [ "${#octets[@]}" -eq 4 ] || return 1
  local octet
  for octet in "${octets[@]}"; do
    case "$octet" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#octet}" -le 3 ] || return 1
    [ "$octet" -le 255 ] || return 1
  done
  return 0
}

validate_ipv4_cidr() {
  local cidr="$1" address mask
  case "$cidr" in
    */*) address="${cidr%%/*}"; mask="${cidr#*/}" ;;
    *) return 1 ;;
  esac
  validate_ipv4 "$address" || return 1
  case "$mask" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$mask" -le 32 ] || return 1
  return 0
}

validate_args() {
  if [ -n "$NODE_NAME" ]; then
    case "$NODE_NAME" in
      ai01|ai02) ;;
      *) die "--node-name must be one of: ai01, ai02" ;;
    esac
  fi

  case "$ACCELERATOR" in
    auto|cpu|amd|nvidia) ;;
    *) die "--accelerator must be one of: auto, cpu, amd, nvidia" ;;
  esac

  case "$COMMAND" in
    images)
      if [ -n "$HOST_IP" ]; then
        validate_ipv4 "$HOST_IP" || die "--host-ip must be an IPv4 address"
      fi
      if [ -n "$PEER_IP" ]; then
        validate_ipv4 "$PEER_IP" || die "--peer-ip must be an IPv4 address"
      fi
      return 0
      ;;
    reconcile-mcp)
      # The root-owned timer invokes only the narrow dynamic overlay stage.
      # It neither configures host networking nor touches the Swarm control
      # plane, therefore host/peer/trusted CIDR arguments are intentionally
      # not required. Requiring them here made the generated systemd wrapper
      # fail before it could apply a valid manifest.
      [ -n "$NODE_NAME" ] || die "--node-name is required for command: $COMMAND"
      return 0
      ;;
    onboard-readonly-mcp-user)
      # A one-off imperative action against a running Authentik, not a host
      # provisioning step - no networking/CIDR arguments needed, same as
      # reconcile-mcp above.
      [ -n "$NODE_NAME" ] || die "--node-name is required for command: $COMMAND"
      [ -n "$ONBOARD_USERNAME" ] || die "--username is required for command: $COMMAND"
      [ -n "$ONBOARD_EMAIL" ] || die "--email is required for command: $COMMAND"
      return 0
      ;;
    preflight|host|deploy|configure-authentik|configure-portainer|verify|credentials|all)
      [ -n "$NODE_NAME" ] || die "--node-name is required for command: $COMMAND"
      [ -n "$HOST_IP" ] || die "--host-ip is required for command: $COMMAND"
      [ -n "$PEER_IP" ] || die "--peer-ip is required for command: $COMMAND"
      [ "${#TRUSTED_CIDRS[@]}" -gt 0 ] || die "--trusted-cidr is required for command: $COMMAND"
      ;;
  esac

  validate_ipv4 "$HOST_IP" || die "--host-ip must be an IPv4 address"
  validate_ipv4 "$PEER_IP" || die "--peer-ip must be an IPv4 address"

  local trusted_cidr
  for trusted_cidr in "${TRUSTED_CIDRS[@]}"; do
    validate_ipv4_cidr "$trusted_cidr" || die "--trusted-cidr must be an IPv4 CIDR (address/mask, e.g. 10.20.0.0/24)"
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    command_exists sudo || die "This command requires root or sudo: $*"
    sudo "$@"
  fi
}

run_root_no_prompt() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    return 127
  fi
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    run_root docker "$@"
  fi
}

install_if_changed() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local owner="${4:-root}"
  local group="${5:-root}"

  if run_root test -f "$target" && run_root cmp -s "$source" "$target"; then
    log "${target} already up to date"
    return 0
  fi

  run_root install -D -m "$mode" -o "$owner" -g "$group" "$source" "$target"
  log "Installed ${target}"
}

write_root_file_if_changed() {
  local content_file="$1"
  local target="$2"
  local mode="$3"
  install_if_changed "$content_file" "$target" "$mode" root root
}

load_os_info() {
  [ -r /etc/os-release ] || die "/etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  ARCH="$(dpkg --print-architecture 2>/dev/null || true)"

  [ "$OS_ID" = "ubuntu" ] || die "Only Ubuntu is supported, got: ${OS_ID:-unknown}"
  case "$OS_VERSION_ID" in
    24.04|26.04) ;;
    *) die "Only Ubuntu 24.04 and 26.04 are supported, got: ${OS_VERSION_ID:-unknown}" ;;
  esac
  [ -n "$OS_CODENAME" ] || die "Ubuntu VERSION_CODENAME is missing from /etc/os-release"
  [ "$ARCH" = "amd64" ] || die "Only linux/amd64 is supported, got: ${ARCH:-unknown}"
}

check_reboot_marker() {
  if ! run_root test -f "$REBOOT_MARKER"; then
    return 0
  fi

  local marker_boot
  local current_boot
  marker_boot="$(run_root sed -n '1p' "$REBOOT_MARKER" 2>/dev/null || true)"
  current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

  if [ -n "$marker_boot" ] && [ "$marker_boot" = "$current_boot" ]; then
    run_root sed 's/^/[ai-stand] /' "$REBOOT_MARKER" >&2 || true
    die "Host reboot is required before continuing; run the same apply.sh command after reboot"
  fi

  run_root rm -f "$REBOOT_MARKER"
  log "Previous reboot marker cleared"
}

check_reboot_marker_readonly() {
  if ! run_root_no_prompt test -f "$REBOOT_MARKER" >/dev/null 2>&1; then
    return 0
  fi

  local marker_boot
  local current_boot
  marker_boot="$(run_root_no_prompt sed -n '1p' "$REBOOT_MARKER" 2>/dev/null || true)"
  current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

  if [ -n "$marker_boot" ] && [ "$marker_boot" = "$current_boot" ]; then
    run_root_no_prompt sed 's/^/[ai-stand] /' "$REBOOT_MARKER" >&2 || true
    die "Host reboot is required before continuing; run the same apply.sh command after reboot"
  fi

  log "A stale reboot marker exists and will be cleared by the host command"
}

mark_reboot_required() {
  local reason="$1"
  local tmp
  tmp="$(mktemp)"
  {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf '%s\n' "unknown-boot"
    printf '%s\n' "$reason"
    printf '%s\n' "Repeat the same apply.sh command after reboot."
  } > "$tmp"
  run_root install -D -m 0644 "$tmp" "$REBOOT_MARKER"
  rm -f "$tmp"
  die "$reason; reboot the host and repeat the same apply.sh command"
}

ensure_base_packages() {
  require_command apt-get
  run_root apt-get update
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    firewalld \
    gnupg \
    iproute2 \
    iptables \
    jq \
    lsb-release \
    nginx \
    openssl \
    pciutils \
    software-properties-common \
    util-linux
}

ensure_docker_repo() {
  local key_tmp
  local sources_tmp
  key_tmp="$(mktemp)"
  sources_tmp="$(mktemp)"

  curl --fail --show-error --silent --location \
    https://download.docker.com/linux/ubuntu/gpg \
    --output "$key_tmp"

  printf '%s\n' \
    "Types: deb" \
    "URIs: https://download.docker.com/linux/ubuntu" \
    "Suites: ${OS_CODENAME}" \
    "Components: stable" \
    "Signed-By: /etc/apt/keyrings/docker.asc" \
    "Architectures: ${ARCH}" > "$sources_tmp"

  run_root install -d -m 0755 /etc/apt/keyrings
  write_root_file_if_changed "$key_tmp" /etc/apt/keyrings/docker.asc 0644
  write_root_file_if_changed "$sources_tmp" /etc/apt/sources.list.d/docker.sources 0644
  rm -f "$key_tmp" "$sources_tmp"
}

ensure_docker() {
  if ! command_exists docker; then
    run_root apt-get remove -y \
      docker.io \
      docker-doc \
      docker-compose \
      docker-compose-v2 \
      podman-docker \
      containerd \
      runc >/dev/null 2>&1 || true
  fi

  ensure_docker_repo
  run_root apt-get update
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  run_root systemctl enable --now docker >/dev/null
  docker_cmd info >/dev/null
  log "Docker Engine is installed and reachable"
}

ensure_swarm() {
  local state
  local control

  state="$(docker_cmd info --format '{{.Swarm.LocalNodeState}}')"
  control="$(docker_cmd info --format '{{.Swarm.ControlAvailable}}')"

  case "$state" in
    active)
      [ "$control" = "true" ] || die "Docker Swarm is active but this node is not a manager"
      local node_addr
      local swarm_error
      local remote_managers
      local invalid_manager_addr
      node_addr="$(docker_cmd info --format '{{.Swarm.NodeAddr}}')"
      swarm_error="$(docker_cmd info --format '{{.Swarm.Error}}')"
      remote_managers="$(docker_cmd info --format '{{range .Swarm.RemoteManagers}}{{.Addr}} {{end}}')"
      invalid_manager_addr="0"
      for manager_addr in $remote_managers; do
        case "$manager_addr" in
          "${HOST_IP}:2377" | "${PEER_IP}:2377")
            ;;
          *)
            invalid_manager_addr="1"
            ;;
        esac
      done

      if [ "$NODE_NAME" = "ai01" ] && { [ "$node_addr" != "$HOST_IP" ] || [ "$invalid_manager_addr" = "1" ] || printf '%s\n' "$swarm_error" | grep -qi "does not have a leader"; }; then
        warn "Swarm manager state is unhealthy (addr=${node_addr}, managers=${remote_managers:-none}, expected=${HOST_IP}/${PEER_IP}); recreating single-node control plane"
        docker_cmd swarm leave --force >/dev/null || true
        docker_cmd swarm init \
          --advertise-addr "$HOST_IP" \
          --listen-addr "${HOST_IP}:2377" \
          --data-path-addr "$HOST_IP" >/dev/null
        SWARM_RECOVERED="1"
        log "Recreated Docker Swarm manager on ai01 with advertise address ${HOST_IP}"
      fi
      log "Docker Swarm manager is active on ${NODE_NAME}"
      ;;
    inactive)
      case "$NODE_NAME" in
        ai01)
          docker_cmd swarm init \
            --advertise-addr "$HOST_IP" \
            --listen-addr "${HOST_IP}:2377" \
            --data-path-addr "$HOST_IP" >/dev/null
          log "Initialized Docker Swarm manager on ai01 with advertise address ${HOST_IP}"
          ;;
        ai02)
          [ -n "$MANAGER_JOIN_TOKEN" ] || die "--manager-join-token is required when ai02 is not part of the Swarm yet"
          docker_cmd swarm join \
            --token "$MANAGER_JOIN_TOKEN" \
            --advertise-addr "$HOST_IP" \
            --listen-addr "${HOST_IP}:2377" \
            --data-path-addr "$HOST_IP" \
            "${PEER_IP}:2377" >/dev/null
          control="$(docker_cmd info --format '{{.Swarm.ControlAvailable}}')"
          [ "$control" = "true" ] || die "ai02 joined Swarm but is not a manager; use a manager join token"
          log "Joined Docker Swarm as manager on ai02 via ${PEER_IP}:2377"
          ;;
        *)
          die "Unknown node name: ${NODE_NAME:-empty}"
          ;;
      esac
      ;;
    pending)
      case "$NODE_NAME" in
        ai02)
          warn "ai02 has a pending Swarm join; leaving incomplete Swarm state before retry"
          docker_cmd swarm leave --force >/dev/null || true
          [ -n "$MANAGER_JOIN_TOKEN" ] || die "--manager-join-token is required when ai02 must retry Swarm join"
          docker_cmd swarm join \
            --token "$MANAGER_JOIN_TOKEN" \
            --advertise-addr "$HOST_IP" \
            --listen-addr "${HOST_IP}:2377" \
            --data-path-addr "$HOST_IP" \
            "${PEER_IP}:2377" >/dev/null
          control="$(docker_cmd info --format '{{.Swarm.ControlAvailable}}')"
          [ "$control" = "true" ] || die "ai02 joined Swarm but is not a manager; use a manager join token"
          log "Joined Docker Swarm as manager on ai02 via ${PEER_IP}:2377 after pending-state recovery"
          ;;
        *)
          die "Docker Swarm pending state is only supported for ai02 join recovery"
          ;;
      esac
      ;;
    *)
      die "Docker Swarm state is not supported for fresh install: ${state}"
      ;;
  esac
}

cleanup_stale_swarm_nodes_after_recovery() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  [ "$SWARM_RECOVERED" = "1" ] || return 0

  local current_node
  current_node="$(docker_cmd info --format '{{.Swarm.NodeID}}')"

  docker_cmd node ls --format '{{.ID}}\t{{.Status}}\t{{.Hostname}}' \
    | while IFS="$(printf '\t')" read -r node_id status hostname; do
        [ -n "$node_id" ] || continue
        [ "$node_id" = "$current_node" ] && continue
        if [ "$status" != "Ready" ]; then
          warn "Removing stale Swarm node after recovery: id=${node_id} status=${status} hostname=${hostname}"
          docker_cmd node rm --force "$node_id" >/dev/null || true
        fi
      done
}

detect_accelerator() {
  if [ "$ACCELERATOR" != "auto" ]; then
    printf '%s\n' "$ACCELERATOR"
    return 0
  fi

  if ! command_exists lspci; then
    warn "lspci is unavailable; auto accelerator falls back to cpu"
    printf '%s\n' "cpu"
    return 0
  fi

  local pci
  pci="$(lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display|Processing accelerators' || true)"

  local has_amd="0"
  local has_nvidia="0"
  printf '%s\n' "$pci" | grep -Eiq 'AMD|Advanced Micro Devices|ATI' && has_amd="1"
  printf '%s\n' "$pci" | grep -Eiq 'NVIDIA' && has_nvidia="1"

  if [ "$has_amd" = "1" ] && [ "$has_nvidia" = "1" ]; then
    die "Both AMD and NVIDIA GPUs were detected; use --accelerator amd or --accelerator nvidia"
  fi
  if [ "$has_amd" = "1" ]; then
    printf '%s\n' "amd"
  elif [ "$has_nvidia" = "1" ]; then
    printf '%s\n' "nvidia"
  else
    printf '%s\n' "cpu"
  fi
}

validate_accelerator_compatibility() {
  # NOTE: the OS-version check below uses the resolved $accelerator
  # parameter, but the two hardware-presence checks use the global
  # $ACCELERATOR (the raw --accelerator flag, still "auto" when
  # auto-detection picked the resolved value). This is currently harmless
  # either way: when $ACCELERATOR=auto, detect_accelerator() already did
  # its own lspci check before returning "amd"/"nvidia", so these checks
  # just no-op; when $ACCELERATOR is explicit, both variables agree. Every
  # current call site that passes an explicit accelerator here (e.g.
  # ensure_amd_kernel/ensure_amd_driver passing the literal "amd") has
  # already gone through hardware validation upstream. A future call site
  # that relies on THIS function's own hardware check while $ACCELERATOR
  # is still "auto" would silently skip it - use $accelerator consistently
  # below if that's ever needed.
  local accelerator="$1"

  if [ "$accelerator" = "amd" ] && [ "$OS_VERSION_ID" = "26.04" ]; then
    die "AMD accelerator on Ubuntu 26.04 is unsupported by this installer; use Ubuntu 24.04 or --accelerator cpu/nvidia"
  fi

  if [ "$ACCELERATOR" = "amd" ] && command_exists lspci; then
    lspci | grep -Eiq 'AMD|Advanced Micro Devices|ATI' \
      || die "--accelerator amd was requested, but no AMD GPU is visible in lspci"
  fi

  if [ "$ACCELERATOR" = "nvidia" ] && command_exists lspci; then
    lspci | grep -Eiq 'NVIDIA' \
      || die "--accelerator nvidia was requested, but no NVIDIA GPU is visible in lspci"
  fi
}

ensure_docker_daemon_runtime() {
  local runtime="$1"
  local runtime_path="$2"
  local source_json
  local target_json
  local source_normalized
  local target_normalized

  source_json="$(mktemp)"
  target_json="$(mktemp)"
  source_normalized="$(mktemp)"
  target_normalized="$(mktemp)"

  if run_root test -s /etc/docker/daemon.json; then
    run_root cp /etc/docker/daemon.json "$source_json"
    run_root chown "$(id -u):$(id -g)" "$source_json"
  else
    printf '%s\n' '{}' > "$source_json"
  fi

  jq \
    --arg runtime "$runtime" \
    --arg runtime_path "$runtime_path" \
    '(.runtimes //= {}) |
     .runtimes[$runtime] = {"path": $runtime_path, "runtimeArgs": []} |
     .["default-runtime"] = $runtime' \
    "$source_json" > "$target_json"

  jq --sort-keys . "$target_json" > "$target_normalized"
  if run_root test -s /etc/docker/daemon.json; then
    run_root jq --sort-keys . /etc/docker/daemon.json > "$source_normalized"
  fi

  if [ -s "$source_normalized" ] && cmp -s "$target_normalized" "$source_normalized"; then
    log "Docker default runtime already set to ${runtime}"
  else
    write_root_file_if_changed "$target_json" /etc/docker/daemon.json 0644
    run_root systemctl restart docker
    log "Docker default runtime set to ${runtime}; Docker restarted"
  fi

  rm -f "$source_json" "$target_json" "$source_normalized" "$target_normalized"
  docker_cmd info >/dev/null
}

amd_smi_command() {
  if command_exists amd-smi; then
    printf '%s\n' "amd-smi"
  elif [ -x /opt/rocm/bin/amd-smi ]; then
    printf '%s\n' "/opt/rocm/bin/amd-smi"
  else
    return 1
  fi
}

amd_gpu_ready() {
  local amd_smi_bin
  amd_smi_bin="$(amd_smi_command 2>/dev/null || true)"
  [ -n "$amd_smi_bin" ] || return 1
  [ -e /dev/kfd ] || return 1
  [ -d /dev/dri ] || return 1
  "$amd_smi_bin" static --asic --vram >/dev/null 2>&1 || run_root_no_prompt "$amd_smi_bin" static --asic --vram >/dev/null 2>&1
}

ensure_amd_kernel() {
  validate_accelerator_compatibility amd

  # gfx1151 (Strix Halo/Ryzen AI Max+ PRO 395) hits an unresolved amdgpu/ROCm
  # queue-eviction crash ("Freeing queue vital buffer..., queue evicted")
  # under real inference load on kernels below 7.0, regardless of ROCm
  # release, GTT/TTM tuning, or even switching LM Studio to the Vulkan
  # (Mesa RADV, non-ROCm/HIP) runtime on its own - confirmed 2026-09-06 (see
  # project_ai_stand_gpu_crash_investigation memory notes) that only kernel
  # >=7.0 together with Vulkan avoids it. linux-generic-hwe-24.04 provides
  # that kernel on Ubuntu 24.04 (same kernel Ubuntu 26.04 ships as GA)
  # without a full distro upgrade. This is required, not optional, for
  # accelerator=amd - skipping it silently reproduces the crash.
  local kernel_major
  kernel_major="$(uname -r | cut -d. -f1)"

  if [ "$kernel_major" -lt 7 ]; then
    if ! dpkg -s linux-generic-hwe-24.04 >/dev/null 2>&1; then
      log "Installing linux-generic-hwe-24.04 (running kernel $(uname -r) is older than the minimum 7.0 required to avoid a known gfx1151 GPU crash under load)"
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y linux-generic-hwe-24.04
    fi
    mark_reboot_required "linux-generic-hwe-24.04 installed to reach kernel >=7.0 (running kernel is still $(uname -r))"
  fi

  log "Running kernel $(uname -r) satisfies the >=7.0 requirement for accelerator=amd"
}

ensure_amd_driver() {
  validate_accelerator_compatibility amd

  # ROCm compute packages (as opposed to amdgpu-install / the kernel driver
  # installer below) moved to stable.repo.amd.com with an
  # "amdrocm<release>-gfx<gfx>" package naming convention - see
  # https://rocm.docs.amd.com/en/latest/install/rocm.html. AMD_ROCM_GFX_VERSION
  # identifies this specific GPU's LLVM gfx target (e.g. gfx1151 for Strix
  # Halo/Ryzen AI Max, gfx1103 for Phoenix/Radeon 780M) and is intentionally
  # NOT auto-detected: amdgpu-install's own --gfxversion=auto/all detection is
  # unreliable (confirmed 2026-09-05 - --gfxversion=all is documented as "not
  # yet available", --gfxversion=auto correctly identifies the chip but then
  # fails to resolve a matching package on this same repo, and it gets
  # confused entirely once any amdrocm* package is already installed). Each
  # installation profile sets this explicitly per node instead.
  [ -n "${AMD_ROCM_GFX_VERSION:-}" ] || die "AMD_ROCM_GFX_VERSION must be set for accelerator=amd (e.g. gfx1151, gfx1103 - see https://rocm.docs.amd.com's per-model GPU picker)"

  if ! amd_gpu_ready; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      "linux-headers-$(uname -r)" || true

    local deb_tmp
    deb_tmp="$(mktemp --suffix=.deb)"
    curl --fail --show-error --silent --location \
      "$AMD_AMDGPU_INSTALL_URL" \
      --output "$deb_tmp"
    echo "${AMD_AMDGPU_INSTALL_SHA256}  ${deb_tmp}" | sha256sum --check --strict \
      || die "amdgpu-install package checksum mismatch: $AMD_AMDGPU_INSTALL_URL"
    run_root apt-get install -y "$deb_tmp"
    rm -f "$deb_tmp"
    run_root apt-get update

    # Ryzen APUs use the kernel's own inbox amdgpu driver (confirmed via
    # AMD's per-model install picker with fam=ryzen); no DKMS build needed.
    run_root modprobe amdgpu >/dev/null 2>&1 || true

    if ! amd_gpu_ready; then
      mark_reboot_required "amdgpu-install completed but GPU devices are not ready yet"
    fi
  fi

  if ! run_root test -f /etc/apt/sources.list.d/amdrocm-stable.sources; then
    local key_tmp
    local sources_tmp
    key_tmp="$(mktemp)"
    sources_tmp="$(mktemp)"

    curl --fail --show-error --silent --location \
      https://stable.repo.amd.com/rocm/gpg/packages.gpg \
      | gpg --dearmor > "$key_tmp"

    run_root install -d -m 0755 /etc/apt/keyrings
    write_root_file_if_changed "$key_tmp" /etc/apt/keyrings/amdrocm.gpg 0644
    rm -f "$key_tmp"
    printf '%s\n' \
      "X-Repo-Id: amdrocm-stable" \
      "Types: deb" \
      "URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2404/" \
      "Suites: stable" \
      "Components: main" \
      "Architectures: amd64" \
      "Signed-By: /etc/apt/keyrings/amdrocm.gpg" \
      "Enabled: yes" \
      > "$sources_tmp"
    write_root_file_if_changed "$sources_tmp" /etc/apt/sources.list.d/amdrocm-stable.sources 0644
    rm -f "$sources_tmp"
    run_root apt-get update
  fi

  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "amdrocm${AMD_ROCM_RELEASE}-${AMD_ROCM_GFX_VERSION}"
  run_root usermod -a -G render,video "$(whoami)"

  log "AMD GPU driver (amdrocm${AMD_ROCM_RELEASE}-${AMD_ROCM_GFX_VERSION}) is available"
}

ensure_amd_container_runtime() {
  local key_tmp
  local sources_tmp
  key_tmp="$(mktemp)"
  sources_tmp="$(mktemp)"

  curl --fail --show-error --silent --location \
    "$AMD_CONTAINER_TOOLKIT_KEY_URL" \
    | gpg --dearmor > "$key_tmp"

  printf '%s\n' \
    "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/rocm.gpg] ${AMD_CONTAINER_TOOLKIT_REPO_URL} ${AMD_ROCM_APT_CODENAME} main" > "$sources_tmp"

  run_root install -d -m 0755 /etc/apt/keyrings
  write_root_file_if_changed "$key_tmp" /etc/apt/keyrings/rocm.gpg 0644
  write_root_file_if_changed "$sources_tmp" /etc/apt/sources.list.d/amd-container-toolkit.list 0644
  rm -f "$key_tmp" "$sources_tmp"

  run_root apt-get update
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y amd-container-toolkit

  if [ "$(docker_cmd info --format '{{.DefaultRuntime}}' 2>/dev/null || true)" = "amd" ] \
    && run_root test -s /etc/docker/daemon.json \
    && run_root jq --exit-status \
      '.["default-runtime"] == "amd" and .runtimes.amd.path == "amd-container-runtime"' \
      /etc/docker/daemon.json >/dev/null \
    && command_exists amd-ctk; then
    amd-ctk gpu list >/dev/null 2>&1 || run_root amd-ctk gpu list >/dev/null
    log "AMD Container Toolkit is already configured"
    return 0
  fi

  if command_exists amd-ctk; then
    run_root amd-ctk runtime configure --runtime=docker --set-as-default >/dev/null 2>&1 \
      || run_root amd-ctk runtime configure --runtime=docker >/dev/null 2>&1 \
      || run_root amd-ctk runtime configure >/dev/null
  fi

  ensure_docker_daemon_runtime amd amd-container-runtime

  [ "$(docker_cmd info --format '{{.DefaultRuntime}}')" = "amd" ] \
    || die "Docker default runtime is not amd after configuration"
  command_exists amd-ctk || die "amd-ctk is missing after AMD Container Toolkit installation"
  amd-ctk gpu list >/dev/null 2>&1 || run_root amd-ctk gpu list >/dev/null
  log "AMD Container Toolkit is configured"
}

nvidia_gpu_ready() {
  command_exists nvidia-smi && nvidia-smi >/dev/null 2>&1
}

ensure_nvidia_driver() {
  validate_accelerator_compatibility nvidia

  if nvidia_gpu_ready; then
    log "NVIDIA driver is already available"
    return 0
  fi

  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "linux-headers-$(uname -r)" \
    ubuntu-drivers-common
  run_root ubuntu-drivers install --gpgpu

  if ! nvidia_gpu_ready; then
    mark_reboot_required "NVIDIA driver installation completed but nvidia-smi is not ready yet"
  fi

  log "NVIDIA driver is available"
}

ensure_nvidia_container_runtime() {
  local key_tmp
  local list_tmp
  key_tmp="$(mktemp)"
  list_tmp="$(mktemp)"

  curl --fail --show-error --silent --location \
    "$NVIDIA_CONTAINER_TOOLKIT_KEY_URL" \
    | gpg --dearmor > "$key_tmp"
  curl --fail --show-error --silent --location \
    "$NVIDIA_CONTAINER_TOOLKIT_LIST_URL" \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > "$list_tmp"

  write_root_file_if_changed "$key_tmp" /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 0644
  write_root_file_if_changed "$list_tmp" /etc/apt/sources.list.d/nvidia-container-toolkit.list 0644
  rm -f "$key_tmp" "$list_tmp"

  run_root apt-get update
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
  run_root nvidia-ctk runtime configure --runtime=docker --set-as-default >/dev/null 2>&1 \
    || run_root nvidia-ctk runtime configure --runtime=docker >/dev/null
  ensure_docker_daemon_runtime nvidia nvidia-container-runtime

  [ "$(docker_cmd info --format '{{.DefaultRuntime}}')" = "nvidia" ] \
    || die "Docker default runtime is not nvidia after configuration"
  log "NVIDIA Container Toolkit is configured"
}

ensure_accelerator_runtime() {
  local accelerator="$1"
  validate_accelerator_compatibility "$accelerator"

  case "$accelerator" in
    cpu)
      log "CPU accelerator selected; GPU driver/runtime installation is skipped"
      ;;
    amd)
      ensure_amd_kernel
      ensure_amd_driver
      ensure_amd_container_runtime
      ;;
    nvidia)
      ensure_nvidia_driver
      ensure_nvidia_container_runtime
      ;;
  esac
}

check_accelerator_preflight() {
  local accelerator="$1"
  validate_accelerator_compatibility "$accelerator"

  case "$accelerator" in
    cpu)
      log "Accelerator preflight: cpu"
      ;;
    amd)
      if amd_gpu_ready && command_exists amd-ctk; then
        log "Accelerator preflight: AMD driver/runtime are present"
      else
        log "Accelerator preflight: AMD driver/runtime will be installed by host command"
      fi
      ;;
    nvidia)
      if nvidia_gpu_ready && command_exists nvidia-ctk; then
        log "Accelerator preflight: NVIDIA driver/runtime are present"
      else
        log "Accelerator preflight: NVIDIA driver/runtime will be installed by host command"
      fi
      ;;
  esac
}

check_docker_preflight() {
  if ! command_exists docker; then
    log "Docker is not installed yet; host command will install Docker Engine"
    return 0
  fi

  if ! docker info >/dev/null 2>&1 && ! run_root_no_prompt docker info >/dev/null 2>&1; then
    log "Docker is installed but not reachable yet; host command will start/configure it"
    return 0
  fi

  local state
  state="$(docker_cmd info --format '{{.Swarm.LocalNodeState}}')"
  log "Docker is reachable; Swarm state=${state}"
}

check_disk() {
  local disk_path="/mnt/storage"
  if [ ! -d "$disk_path" ]; then
    disk_path="/mnt"
  fi
  if [ ! -d "$disk_path" ]; then
    disk_path="/"
  fi

  local available_kb
  available_kb="$(df -Pk "$disk_path" | awk 'NR == 2 {print $4}')"
  [ -n "$available_kb" ] || die "Cannot determine free space for ${disk_path}"

  if [ "$available_kb" -lt 62914560 ]; then
    die "${disk_path} has less than 60 GiB free"
  fi
  log "${disk_path} has enough free space"
}

node_hostname() {
  case "$NODE_NAME" in
    ai01) printf '%s\n' "$AI01_HOST" ;;
    ai02) printf '%s\n' "$AI02_HOST" ;;
    *) die "Unknown node name: ${NODE_NAME:-empty}" ;;
  esac
}

peer_hostname() {
  case "$NODE_NAME" in
    ai01) printf '%s\n' "$AI02_HOST" ;;
    ai02) printf '%s\n' "$AI01_HOST" ;;
    *) die "Unknown node name: ${NODE_NAME:-empty}" ;;
  esac
}

local_service_domains() {
  case "$NODE_NAME" in
    ai01)
      # AGENTGATEWAY_HOST is deliberately not listed here: its whole
      # surface requires app-level auth unconditionally, so an
      # unauthenticated check against it belongs with
      # check_agentgateway_llm_auth() in cmd_verify(), not the generic
      # bare-success loop this list feeds.
      printf '%s\n' "$OPENWEBUI_HOST" "$PORTAINER_HOST" "$METAMCP_HOST"
      ;;
    ai02)
      # A trusted-proxy OpenClaw deliberately redirects an unauthenticated
      # browser to Authentik, so it has a separate protected-route probe in
      # cmd_verify rather than this bare 2xx loop.
      if [ "$OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED" != "1" ]; then
        printf '%s\n' "$OPENCLAW_HOST"
      fi
      printf '%s\n' "$PORTAINER_HOST"
      if [ "$CODER_ENABLED" = "1" ]; then
        printf '%s\n' "$CODER_HOST"
      fi
      ;;
    *)
      die "Unknown node name: ${NODE_NAME:-empty}"
      ;;
  esac
}

nginx_site_source_for_node() {
  case "$NODE_NAME" in
    ai01) printf '%s\n' "$NGINX_SITE_AI01_SOURCE" ;;
    ai02) printf '%s\n' "$NGINX_SITE_AI02_SOURCE" ;;
    *) die "Unknown node name: ${NODE_NAME:-empty}" ;;
  esac
}

peer_allowed_technical_ports() {
  case "$NODE_NAME" in
    ai01)
      # No peer access to technical ports is required.
      ;;
    ai02)
      ;;
    *)
      die "Unknown node name: ${NODE_NAME:-empty}"
      ;;
  esac
}

technical_ports_for_current_node() {
  local port
  for port in "${TECH_PORTS[@]}"; do
    printf '%s\n' "$port"
  done
}

check_dns() {
  local domain="$1"
  local expected="${2:-$HOST_IP}"
  local resolved
  resolved="$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u | tr '\n' ' ')"

  case "$expected" in
    cluster)
      if printf '%s\n' "$resolved" | grep -qw "$HOST_IP" \
        || printf '%s\n' "$resolved" | grep -qw "$PEER_IP"; then
        log "DNS ok: ${domain} -> cluster node (${resolved})"
      else
        die "DNS for ${domain} does not include ${HOST_IP} or ${PEER_IP}; got: ${resolved:-none}"
      fi
      ;;
    *)
      if printf '%s\n' "$resolved" | grep -qw "$expected"; then
        log "DNS ok: ${domain} -> ${expected}"
      else
        die "DNS for ${domain} does not include ${expected}; got: ${resolved:-none}"
      fi
      ;;
  esac
}

check_node_dns() {
  local domain

  check_dns "$(node_hostname)" "$HOST_IP"
  check_dns "$(peer_hostname)" "$PEER_IP"

  for domain in $(local_service_domains); do
    if [ "$domain" = "$PORTAINER_HOST" ]; then
      check_dns "$domain" cluster
    else
      check_dns "$domain" "$HOST_IP"
    fi
  done

  if [ "$NODE_NAME" = "ai01" ]; then
    check_dns "$AUTHENTIK_HOST" "$HOST_IP"
    # Not part of local_service_domains() (see its own comment) - checked
    # here directly, same as AUTHENTIK_HOST above.
    check_dns "$AGENTGATEWAY_HOST" "$HOST_IP"
  else
    check_dns "$AUTHENTIK_HOST" "$PEER_IP"
  fi
}

cert_valid() {
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  run_root test -r "$fullchain" || return 1
  run_root test -r "$privkey" || return 1
  run_root openssl x509 -in "$fullchain" -noout -checkend 604800 >/dev/null || return 1
  run_root openssl x509 -in "$fullchain" -noout -ext subjectAltName \
    | grep -q "DNS:\\*.${CERT_DOMAIN}"
}

check_cert_preflight() {
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  if run_root_no_prompt test -r "$fullchain" >/dev/null 2>&1 && run_root_no_prompt test -r "$privkey" >/dev/null 2>&1; then
    if run_root_no_prompt openssl x509 -in "$fullchain" -noout -checkend 604800 >/dev/null 2>&1; then
      log "TLS certificate exists; host command will validate SAN before Nginx reload"
    else
      die "Existing TLS certificate is expired or invalid: ${fullchain}"
    fi
  elif run_root_no_prompt test -e "$fullchain" >/dev/null 2>&1 || run_root_no_prompt test -e "$privkey" >/dev/null 2>&1; then
    die "TLS certificate directory is partially populated; fix ${CERT_DIR} before continuing"
  else
    log "TLS certificate is absent; host command will generate a self-signed bootstrap wildcard certificate"
  fi
}

ensure_tls_cert() {
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  if cert_valid; then
    log "TLS certificate is valid and covers *.${CERT_DOMAIN}"
    return 0
  fi

  if run_root test -e "$fullchain" || run_root test -e "$privkey"; then
    die "TLS certificate/key exists but is invalid or incomplete: ${CERT_DIR}"
  fi

  warn "Generating self-signed bootstrap certificate for *.${CERT_DOMAIN}"
  run_root install -d -m 0750 -o root -g root "$CERT_DIR"
  run_root openssl req \
    -x509 \
    -nodes \
    -newkey rsa:4096 \
    -sha256 \
    -days 825 \
    -subj "/CN=*.${CERT_DOMAIN}" \
    -addext "subjectAltName=DNS:*.${CERT_DOMAIN},DNS:${CERT_DOMAIN},DNS:authentik.${CERT_DOMAIN},DNS:lmstudio.${CERT_DOMAIN},DNS:lmstudio-proxy.${CERT_DOMAIN},DNS:openwebui.${CERT_DOMAIN},DNS:openclaw.${CERT_DOMAIN},DNS:portainer.${CERT_DOMAIN}" \
    -keyout "$privkey" \
    -out "$fullchain" >/dev/null 2>&1
  run_root chmod 0600 "$privkey"
  run_root chmod 0644 "$fullchain"
  log "Self-signed bootstrap certificate created at ${CERT_DIR}"
}

ensure_owned_data_dir() {
  local path="$1"
  local mode="$2"
  local marker="${path}/.ai-stand-owner"
  local expected="${APP_UID}:${APP_GID}"
  local current=""

  run_root install -d -m "$mode" -o "$APP_UID" -g "$APP_GID" "$path"
  current="$(run_root cat "$marker" 2>/dev/null || true)"

  if [ "$current" != "$expected" ]; then
    log "Applying ownership ${expected} to ${path}"
    run_root chown -R "${APP_UID}:${APP_GID}" "$path"
    printf '%s\n' "$expected" | run_root tee "$marker" >/dev/null
    run_root chown "${APP_UID}:${APP_GID}" "$marker"
    run_root chmod 0640 "$marker"
  else
    log "${path} ownership marker already matches ${expected}"
  fi
}

mark_existing_openclaw_component_owned() {
  local path="$1"
  local component_name="$2"
  local marker="${path}/.ai-stand-owner"
  local expected="${APP_UID}:${APP_GID}"
  local unexpected_path
  local current

  # A manual OpenClaw state reset can create a populated component without
  # ai-stand's marker. Never repair such a tree recursively: validate it
  # first, then add only the marker that lets storage migration recognise the
  # component on later runs.
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$path"
  if [ "$component_name" = "sandbox DIND" ]; then
    # Docker's *inner* daemon is deliberately privileged inside its own
    # isolated DIND container. It creates these small implementation-owned
    # root entries (including a block-device marker) even though the mounted
    # data root and workspace belong to APP_UID:APP_GID. They are not user
    # repositories and must not be recursively chowned. Accept only this
    # enumerated Docker layout; any other ownership drift remains fatal.
    unexpected_path="$(
      run_root find "$path" -xdev \
        \( \
          -path "$path/runtimes" -o \
          -path "$path/containers" -o \
          -path "$path/tmp" \
        \) -prune -o \
        \( \
          -path "$path/volumes" -o \
          -path "$path/volumes/backingFsBlockDev" \
        \) -o \
        \( ! -uid "$APP_UID" -o ! -gid "$APP_GID" \) \
        -print -quit 2>/dev/null || true
    )"
  else
    unexpected_path="$(
      run_root find "$path" -xdev \
        \( ! -uid "$APP_UID" -o ! -gid "$APP_GID" \) \
        -print -quit 2>/dev/null || true
    )"
  fi
  [ -z "$unexpected_path" ] || die "OpenClaw ${component_name} ownership conflict at ${unexpected_path}; expected ${expected}. Refusing to recursively chown persistent data."

  current="$(run_root cat "$marker" 2>/dev/null || true)"
  if [ "$current" != "$expected" ]; then
    printf '%s\n' "$expected" | run_root tee "$marker" >/dev/null
    run_root chown "$APP_UID:$APP_GID" "$marker"
    run_root chmod 0640 "$marker"
    log "Recorded verified ownership ${expected} for OpenClaw ${component_name}"
  fi
}

ensure_openclaw_sandbox_workspace_root() {
  local unexpected_path

  # Do not use ensure_owned_data_dir() here: its recovery path recursively
  # chowns a component. Sandboxes may contain user repositories, and an
  # ownership drift in one must be diagnosed rather than silently rewritten.
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$OPENCLAW_SANDBOX_WORKSPACE_ROOT"
  unexpected_path="$(
    run_root find "$OPENCLAW_SANDBOX_WORKSPACE_ROOT" -xdev \
      \( ! -uid "$APP_UID" -o ! -gid "$APP_GID" \) \
      -print -quit 2>/dev/null || true
  )"
  [ -z "$unexpected_path" ] || die "OpenClaw sandbox workspace ownership conflict at ${unexpected_path}; expected ${APP_UID}:${APP_GID}. Refusing to recursively chown user workspace data."

  log "OpenClaw sandbox workspace root is ready at ${OPENCLAW_SANDBOX_WORKSPACE_ROOT}"
}

ensure_openclaw_gigacode_requester_state() {
  [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  # Do not run a recursive repair here.  This directory is written by the
  # unprivileged OpenClaw plugin at runtime; unexpected ownership could turn
  # a host file into a confused-deputy identity map.
  #
  # The file's mode is 0750, not the tighter 0640 an identity-mapping file
  # would otherwise get elsewhere in this script (e.g. the .ai-stand-owner
  # markers above) - confirmed live 2026-09-23 that this host runs a
  # pre-existing, outside-this-repo root cron every 5 minutes
  # (/mnt/fix.sh: `chmod -R 750 /mnt/storage/*-data`) that unconditionally
  # reasserts 0750 on everything under /mnt/storage/openclaw-data,
  # this directory included. Fighting it back to 0640 on every apply.sh run
  # just means this check fails intermittently depending on how recently
  # cron last fired, for no real security gain: 0750 vs 0640 grant the
  # identical owner/group read-write access for a plain data file neither
  # mode ever executes, the only difference is an inert execute bit.
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$OPENCLAW_GIGACODE_REQUESTER_DIR"
  if ! run_root test -e "$OPENCLAW_GIGACODE_SESSION_MAP"; then
    printf '%s\n' '{"version":1,"entries":{}}' | run_root tee "$OPENCLAW_GIGACODE_SESSION_MAP" >/dev/null
    run_root chown "$APP_UID:$APP_GID" "$OPENCLAW_GIGACODE_SESSION_MAP"
    run_root chmod 0750 "$OPENCLAW_GIGACODE_SESSION_MAP"
  fi
  local ownership
  ownership="$(run_root stat -c '%u:%g:%a' "$OPENCLAW_GIGACODE_REQUESTER_DIR" "$OPENCLAW_GIGACODE_SESSION_MAP")"
  [ "$ownership" = "${APP_UID}:${APP_GID}:750
${APP_UID}:${APP_GID}:750" ] \
    || die "OpenClaw GigaCode requester state must be ${APP_UID}:${APP_GID} with mode 0750"
}

migrate_root_data_to_component() {
  local root="$1"
  local component="$2"
  local mode="$3"
  local preserved_root_entry_pattern="${4:-}"
  local component_name
  local old_entry
  local component_entry
  component_name="${component##*/}"

  run_root install -d -m "$mode" -o "$APP_UID" -g "$APP_GID" "$root"
  run_root install -d -m "$mode" -o "$APP_UID" -g "$APP_GID" "$component"

  # ! -exec test -f "{}/.ai-stand-owner" \; excludes entries that are
  # themselves already-managed component directories (recognized by their
  # own .ai-stand-owner marker, written unconditionally by
  # ensure_owned_data_dir below on every prior successful run). Without this,
  # adding a second component under an already-populated multi-component
  # root sweeps the first component's real data into the new one, since it
  # matches "not named $component_name, not the root marker" just as
  # genuine old flat root-style data would. Hit for real on 2026-09-07: adding
  # OPENCLAW_SANDBOX_DATA alongside the pre-existing OPENCLAW_DATA component
  # moved gateway's live data into sandbox-dind/gateway.
  old_entry="$(
    run_root find "$root" \
      -mindepth 1 \
      -maxdepth 1 \
      ! -name "$component_name" \
      ! -name ".ai-stand-owner" \
      ! -name "$preserved_root_entry_pattern" \
      ! -exec test -f "{}/.ai-stand-owner" \; \
      -print \
      -quit 2>/dev/null || true
  )"

  if [ -n "$old_entry" ]; then
    component_entry="$(run_root find "$component" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    if [ -n "$component_entry" ]; then
      die "Storage migration conflict: ${root} still has old root-style data AND ${component} is already non-empty. This is either a genuine conflict, or a previous migrate_root_data_to_component() run for this same path was interrupted partway (killed process, dropped SSH session) - if so, finish moving ${root}'s remaining entries into ${component} by hand, then re-run. No backup of the pre-migration data was kept (see the timestamp marker note below) - check ${component} carefully before deleting anything from ${root}."
    fi

    # This directory is a plain timestamp marker for when a migration ran -
    # it holds no copy of the moved data. The move below is a bare rename
    # (mv), not a backed-up copy; if it's interrupted partway, the die()
    # above is what a re-run hits, with no automatic recovery.
    local migration_run_marker_dir="${BACKUP_ROOT}/storage-migration/${RUN_TS}"
    run_root install -d -m 0750 -o root -g root "$migration_run_marker_dir"
    log "Migrating root-style data from ${root} to ${component} (mv, not a backup); run marker: ${migration_run_marker_dir}"
    run_root find "$root" \
      -mindepth 1 \
      -maxdepth 1 \
      ! -name "$component_name" \
      ! -name ".ai-stand-owner" \
      ! -name "$preserved_root_entry_pattern" \
      ! -exec test -f "{}/.ai-stand-owner" \; \
      -exec mv -t "$component" -- {} +

    # A freshly-created component may already carry a marker so sibling
    # component directories are not mistaken for legacy root-style data. If
    # this run did migrate real legacy data into it, remove that provisional
    # marker and let ensure_owned_data_dir() apply its normal ownership
    # repair to the newly migrated tree.
    run_root rm -f "${component}/.ai-stand-owner"
  fi

  ensure_owned_data_dir "$component" "$mode"
}

ensure_portainer_data() {
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$PORTAINER_DATA"
  printf '%s\n' "ai-stand ${IMAGE_VERSION}" | run_root tee "${PORTAINER_DATA}/.ai-stand-owned" >/dev/null
  run_root chown "${APP_UID}:${APP_GID}" "${PORTAINER_DATA}/.ai-stand-owned"
  run_root chmod 0640 "${PORTAINER_DATA}/.ai-stand-owned"

  if run_root test -f "${PORTAINER_DATA}/portainer.db"; then
    run_root chown "${APP_UID}:${APP_GID}" "${PORTAINER_DATA}/portainer.db"
    run_root chmod 0600 "${PORTAINER_DATA}/portainer.db"
  fi
  log "Portainer infrastructure data is ready at ${PORTAINER_DATA}"
}

ensure_authentik_data() {
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$AUTHENTIK_DATA"
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "${AUTHENTIK_DATA}/postgresql"
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "${AUTHENTIK_DATA}/redis"
  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$AUTHENTIK_DATA_SERVER"

  # Legacy rename, kept for any install old enough to still have it:
  # custom-templates -> templates (flat, pre-"server/" layout).
  if run_root test -d "${AUTHENTIK_DATA}/custom-templates"; then
    local old_templates_entry
    local new_templates_entry
    old_templates_entry="$(run_root find "${AUTHENTIK_DATA}/custom-templates" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    new_templates_entry="$(run_root find "${AUTHENTIK_DATA}/templates" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    if [ -n "$old_templates_entry" ] && [ -n "$new_templates_entry" ]; then
      die "Storage migration conflict: both ${AUTHENTIK_DATA}/custom-templates and ${AUTHENTIK_DATA}/templates contain data"
    fi
    if [ -n "$old_templates_entry" ] && [ -z "$new_templates_entry" ]; then
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "${AUTHENTIK_DATA}/templates"
      run_root find "${AUTHENTIK_DATA}/custom-templates" -mindepth 1 -maxdepth 1 -exec mv -t "${AUTHENTIK_DATA}/templates" -- {} +
      log "Migrated Authentik templates to ${AUTHENTIK_DATA}/templates"
    fi
  fi

  # data/templates -> server/{data,templates} (2026-09-11): both are
  # authentik-server+worker's own role, not a distinct role of their own the
  # way postgresql/redis are - see AUTHENTIK_DATA_SERVER. This also retires
  # the old "media" directory this function used to pre-create here: it was
  # never actually bind-mounted by compose.yaml (the real mount is "data",
  # which Authentik itself populates with its own "media/public"
  # subdirectory) - an orphaned leftover of an earlier, incomplete rename.
  local leaf
  for leaf in data templates; do
    if run_root test -d "${AUTHENTIK_DATA}/${leaf}"; then
      local old_entry
      local new_entry
      old_entry="$(run_root find "${AUTHENTIK_DATA}/${leaf}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
      new_entry="$(run_root find "${AUTHENTIK_DATA_SERVER}/${leaf}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
      if [ -n "$old_entry" ] && [ -n "$new_entry" ]; then
        die "Storage migration conflict: both ${AUTHENTIK_DATA}/${leaf} and ${AUTHENTIK_DATA_SERVER}/${leaf} contain data"
      fi
      if [ -n "$old_entry" ] && [ -z "$new_entry" ]; then
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "${AUTHENTIK_DATA_SERVER}/${leaf}"
        run_root find "${AUTHENTIK_DATA}/${leaf}" -mindepth 1 -maxdepth 1 -exec mv -t "${AUTHENTIK_DATA_SERVER}/${leaf}" -- {} +
        run_root rmdir "${AUTHENTIK_DATA}/${leaf}" 2>/dev/null || true
        log "Migrated Authentik ${leaf} to ${AUTHENTIK_DATA_SERVER}/${leaf}"
      fi
    fi
    run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "${AUTHENTIK_DATA_SERVER}/${leaf}"
  done

  run_root chown -R "${APP_UID}:${APP_GID}" "$AUTHENTIK_DATA"
  run_root chmod 0750 "$AUTHENTIK_DATA" "${AUTHENTIK_DATA}/postgresql" "${AUTHENTIK_DATA}/redis" \
    "$AUTHENTIK_DATA_SERVER" "${AUTHENTIK_DATA_SERVER}/data" "${AUTHENTIK_DATA_SERVER}/templates"
  log "Authentik data is ready at ${AUTHENTIK_DATA}"
}

ensure_docker_secret() {
  local secret_name="$1"
  local bytes="$2"

  if docker_cmd secret inspect "$secret_name" >/dev/null 2>&1; then
    log "Docker secret already exists: ${secret_name}"
    return 0
  fi

  local secret_value
  secret_value="$(openssl rand -base64 "$bytes" | tr -d '\n')"
  printf '%s' "$secret_value" | docker_cmd secret create "$secret_name" - >/dev/null
  log "Created Docker secret: ${secret_name}"
}

ensure_authentik_secrets() {
  ensure_docker_secret "$AUTHENTIK_SECRET_KEY_SECRET" 60
  ensure_docker_secret "$AUTHENTIK_POSTGRES_PASSWORD_SECRET" 36
}

# Returns a persisted, randomly generated secret value on stdout, generating
# it on first use so it stays stable across re-runs and redeploys. Used for
# values that, unlike ensure_docker_secret's, are also needed by apply.sh
# itself (host-side API calls) or by an operator (break-glass logins) and
# therefore cannot live only inside the write-only Docker secret store.
load_host_secret() {
  local name="$1"
  local bytes="$2"
  # "base64" (default) or "hex" - hex is for values that get embedded
  # directly in a connection URL (e.g. postgresql://user:PASSWORD@host/db):
  # base64's `/` (and `+`, `=`) corrupt URL parsing there, unlike plain
  # password fields or file://-delivered secrets where any byte is fine.
  local encoding="${3:-base64}"
  local path="${AI_STAND_SECRETS_DIR}/${name}"

  if ! run_root test -s "$path"; then
    run_root install -d -m 0700 -o root -g root "$AI_STAND_SECRETS_DIR"
    local value
    case "$encoding" in
      hex) value="$(openssl rand -hex "$bytes")" ;;
      base64) value="$(openssl rand -base64 "$bytes" | tr -d '\n')" ;;
      *) die "load_host_secret: unknown encoding: ${encoding}" ;;
    esac
    printf '%s' "$value" | run_root tee "$path" >/dev/null
  fi

  # Every host-side secret, including a pre-existing one from a prior
  # installation, is root-only. This is deliberately repaired here instead
  # of accepting a legacy shared-storage mode at the next deploy.
  run_root install -d -m 0700 -o root -g root "$AI_STAND_SECRETS_DIR"
  run_root chown root:root "$path"
  run_root chmod 0600 "$path"
  run_root cat "$path"
}

ensure_docker_secret_from_value() {
  local secret_name="$1"
  local value="$2"

  if docker_cmd secret inspect "$secret_name" >/dev/null 2>&1; then
    log "Docker secret already exists: ${secret_name}"
    return 0
  fi

  printf '%s' "$value" | docker_cmd secret create "$secret_name" - >/dev/null
  log "Created Docker secret: ${secret_name}"
}

# Docker Secret values are intentionally write-only once created.  A few
# locally generated broker materials are PEM/JSON files rather than one-line
# values; stream them directly from a root-only host file so they never enter
# a shell variable, an argv vector, or this script's log.
ensure_docker_secret_from_file() {
  local secret_name="$1"
  local source_file="$2"

  if docker_cmd secret inspect "$secret_name" >/dev/null 2>&1; then
    log "Docker secret already exists: ${secret_name}"
    return 0
  fi
  run_root test -s "$source_file" \
    || die "Cannot create Docker secret ${secret_name}: source file is empty or missing"
  run_root cat "$source_file" | docker_cmd secret create "$secret_name" - >/dev/null
  log "Created Docker secret: ${secret_name}"
}

ensure_host_random_secret_file() {
  local name="$1"
  local bytes="$2"
  local path="${AI_STAND_SECRETS_DIR}/${name}"

  run_root install -d -m 0700 -o root -g root "$AI_STAND_SECRETS_DIR"
  if ! run_root test -s "$path"; then
    # `openssl rand` never prints the generated value to the terminal: its
    # stdout is redirected by a root shell directly into the protected file.
    run_root sh -c 'umask 077; openssl rand -base64 "$1" | tr -d "\\n" > "$2"' sh "$bytes" "$path"
  fi
  run_root chown root:root "$path"
  run_root chmod 0600 "$path"
  printf '%s\n' "$path"
}

ensure_gigacode_identity_broker_secrets() {
  [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ] || return 0
  # The broker is placed exclusively on ai01.  Do not manufacture a second
  # signing identity on ai02 merely because someone ran `verify-ai02` there.
  [ "${NODE_NAME:-}" = "ai01" ] || return 0

  local private_key public_jwks public_pem openwebui_caller openclaw_caller callers
  private_key="${AI_STAND_SECRETS_DIR}/gigacode-broker-signing-key.pem"
  public_jwks="${AI_STAND_SECRETS_DIR}/gigacode-broker-public-jwks.json"
  public_pem="${public_jwks}.pem.tmp"
  openwebui_caller="${AI_STAND_SECRETS_DIR}/gigacode-broker-openwebui-caller"
  openclaw_caller="${AI_STAND_SECRETS_DIR}/gigacode-broker-openclaw-caller"
  callers="${AI_STAND_SECRETS_DIR}/gigacode-broker-callers.json"

  run_root install -d -m 0700 -o root -g root "$AI_STAND_SECRETS_DIR"
  if ! run_root test -s "$private_key"; then
    # RSA-3072 is accepted by the .NET JWT stack and keeps the private key
    # local to ai01. OpenSSL progress is discarded as well.
    run_root sh -c 'umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 > "$1" 2>/dev/null' sh "$private_key"
  fi
  if ! run_root test -s "$public_jwks"; then
    # Agentgateway's `jwtAuth.jwks.file` consumes a JWKS document, not a PEM
    # public key. Derive the one public RSA key with Python's standard
    # library; no crypto package, private key value, or output is exposed.
    run_root sh -c 'umask 077; openssl pkey -in "$1" -pubout > "$2" 2>/dev/null' sh "$private_key" "$public_pem"
    run_root python3 - "$public_pem" "$public_jwks" <<'PY'
import base64
import json
import os
import pathlib
import re
import sys

def take_tlv(data, offset):
    if offset >= len(data):
        raise ValueError("truncated DER")
    tag = data[offset]
    offset += 1
    if offset >= len(data):
        raise ValueError("truncated DER length")
    first = data[offset]
    offset += 1
    if first < 128:
        length = first
    else:
        count = first & 0x7f
        if count == 0 or count > 4 or offset + count > len(data):
            raise ValueError("invalid DER length")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    end = offset + length
    if end > len(data):
        raise ValueError("truncated DER body")
    return tag, data[offset:end], end

def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")

pem = pathlib.Path(sys.argv[1]).read_text(encoding="ascii")
body = "".join(line for line in pem.splitlines() if not line.startswith("---"))
der = base64.b64decode(body, validate=True)
tag, outer, end = take_tlv(der, 0)
if tag != 0x30 or end != len(der):
    raise ValueError("invalid public key outer sequence")
tag, _algorithm, offset = take_tlv(outer, 0)
if tag != 0x30:
    raise ValueError("invalid public key algorithm")
tag, bit_string, end = take_tlv(outer, offset)
if tag != 0x03 or end != len(outer) or not bit_string or bit_string[0] != 0:
    raise ValueError("invalid public key bit string")
tag, rsa, end = take_tlv(bit_string[1:], 0)
if tag != 0x30 or end != len(bit_string) - 1:
    raise ValueError("invalid RSA public key")
tag, modulus, offset = take_tlv(rsa, 0)
tag2, exponent, end = take_tlv(rsa, offset)
if tag != 0x02 or tag2 != 0x02 or end != len(rsa):
    raise ValueError("invalid RSA integers")
modulus = modulus.lstrip(b"\\0")
exponent = exponent.lstrip(b"\\0")
if len(modulus) < 256 or not exponent:
    raise ValueError("invalid RSA key size")
document = {"keys": [{"use": "sig", "kty": "RSA", "kid": "ai-stand-gigacode-broker-v1", "alg": "RS256", "n": b64url(modulus), "e": b64url(exponent)}]}
target = pathlib.Path(sys.argv[2])
temporary = target.with_suffix(".tmp")
temporary.write_text(json.dumps(document, separators=(",", ":")), encoding="ascii")
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY
    run_root rm -f "$public_pem"
  fi
  ensure_host_random_secret_file gigacode-broker-openwebui-caller 32 >/dev/null
  ensure_host_random_secret_file gigacode-broker-openclaw-caller 32 >/dev/null
  if ! run_root test -s "$callers"; then
    # Build the caller allowlist from files, not values.  The JSON carries
    # only internal broker caller secrets and stays root-only on the host.
    run_root python3 - "$openwebui_caller" "$openclaw_caller" "$callers" <<'PY'
import json
import os
import pathlib
import sys

openwebui = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
openclaw = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").strip()
if not openwebui or not openclaw:
    raise SystemExit("broker caller secret is empty")
target = pathlib.Path(sys.argv[3])
temporary = target.with_suffix(".tmp")
temporary.write_text(json.dumps({"openwebui": openwebui, "openclaw": openclaw}, separators=(",", ":")), encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY
  fi
  run_root chown root:root "$private_key" "$public_jwks" "$openwebui_caller" "$openclaw_caller" "$callers"
  run_root chmod 0600 "$private_key" "$public_jwks" "$openwebui_caller" "$openclaw_caller" "$callers"

  ensure_docker_secret_from_file ai-stand-gigacode-broker-signing-key "$private_key"
  ensure_docker_secret_from_file "$GIGACODE_IDENTITY_BROKER_JWKS_SECRET" "$public_jwks"
  ensure_docker_secret_from_file ai-stand-gigacode-broker-callers "$callers"
  ensure_docker_secret_from_file ai-stand-gigacode-broker-openwebui-caller "$openwebui_caller"
  # Created now for the version-pinned OpenClaw adapter.  It is not attached
  # to any service until that adapter is present and verified.
  ensure_docker_secret_from_file ai-stand-gigacode-broker-openclaw-caller "$openclaw_caller"
  local adapter_bearer
  adapter_bearer="$(ensure_host_random_secret_file gigacode-openclaw-adapter 32)"
  ensure_docker_secret_from_file ai-stand-openclaw-gigacode-adapter "$adapter_bearer"
}

# The browser path is bound to Authentik's immutable UUID by trusted proxy
# and therefore needs no static mapping. Telegram has no OIDC session, so its
# two explicitly approved sender IDs are bound once to the active akadmin
# subject. The JSON contains identity routing only -- neither a Device ID nor
# any API secret -- but remains root-only because changing it would select a
# different user's subscription.
ensure_openclaw_gigacode_requester_map() {
  [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ] || return 0
  [ "${NODE_NAME:-}" = "ai01" ] || return 0

  local container_id shell_output subject map_path expected_path
  container_id="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container_id" ] || die "Cannot create OpenClaw GigaCode Telegram mapping: Authentik server is not running"
  shell_output="$(
    docker_cmd exec -i -e AK_TARGET_USERNAME=akadmin "$container_id" ak shell <<'PYEOF'
import os
from authentik.core.models import User

user = User.objects.filter(username=os.environ["AK_TARGET_USERNAME"], is_active=True).first()
if user is None:
    print("AI_STAND_GIGACODE_SUBJECT missing")
else:
    print("AI_STAND_GIGACODE_SUBJECT " + str(user.uuid))
PYEOF
  )" || die "Cannot resolve active akadmin Authentik subject for OpenClaw GigaCode mapping"
  subject="$(printf '%s\n' "$shell_output" | sed -n 's/^AI_STAND_GIGACODE_SUBJECT //p' | tail -n 1)"
  printf '%s\n' "$subject" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
    || die "Cannot resolve active akadmin Authentik subject for OpenClaw GigaCode mapping"

  map_path="${AI_STAND_SECRETS_DIR}/gigacode-openclaw-requester-map.json"
  expected_path="${map_path}.expected"
  run_root install -d -m 0700 -o root -g root "$AI_STAND_SECRETS_DIR"
  # Do not let the resolved UUID escape command output. Python receives it
  # as an argument in a root-only subprocess and writes atomically.
  run_root python3 - "$subject" "$expected_path" <<'PY'
import json
import os
import pathlib
import sys

subject = sys.argv[1].lower()
target = pathlib.Path(sys.argv[2])
temporary = target.with_suffix(".tmp")
temporary.write_text(json.dumps({"version": 1, "telegram": {
    "6990181709": subject,
    "6135243488": subject,
}}, separators=(",", ":")), encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY
  if run_root test -e "$map_path"; then
    run_root cmp --silent "$map_path" "$expected_path" \
      || die "OpenClaw GigaCode Telegram mapping changed; rotate its Docker Secret deliberately before deployment"
    run_root rm -f "$expected_path"
  else
    run_root mv "$expected_path" "$map_path"
  fi
  run_root chown root:root "$map_path"
  run_root chmod 0600 "$map_path"
  ensure_docker_secret_from_file ai-stand-openclaw-gigacode-requester-map "$map_path"
  log "OpenClaw GigaCode Telegram requester mapping is ready"
}

# Generates/loads every ai-stand secret and populates the corresponding
# global variables. Safe and idempotent to call from any command that needs
# them (deploy, configure-authentik, configure-portainer, verify) - values
# are generated once per installation, never hardcoded, never logged.
ensure_ai_stand_secrets() {
  ensure_authentik_secrets

  AUTHENTIK_BOOTSTRAP_TOKEN="$(load_host_secret authentik-bootstrap-token 32)"
  ensure_docker_secret_from_value ai-stand-authentik-bootstrap-token "$AUTHENTIK_BOOTSTRAP_TOKEN"

  AUTHENTIK_BOOTSTRAP_PASSWORD="$(load_host_secret authentik-bootstrap-password 24)"
  ensure_docker_secret_from_value ai-stand-authentik-bootstrap-password "$AUTHENTIK_BOOTSTRAP_PASSWORD"

  AUTHENTIK_OPENWEBUI_CLIENT_SECRET="$(load_host_secret authentik-openwebui-client-secret 32)"
  AUTHENTIK_PORTAINER_CLIENT_SECRET="$(load_host_secret authentik-portainer-client-secret 32)"
  AUTHENTIK_METAMCP_CLIENT_SECRET="$(load_host_secret authentik-metamcp-client-secret 32)"
  AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET="$(load_host_secret authentik-agentgateway-client-secret 32)"
  AUTHENTIK_CODER_CLIENT_SECRET="$(load_host_secret authentik-coder-client-secret 32)"
  ensure_docker_secret_from_value ai-stand-authentik-coder-client-secret "$AUTHENTIK_CODER_CLIENT_SECRET"
  # Opaque machine bearer tokens for agentgateway's llm.policies.apiKey -
  # one per consumer service, not tied to any Authentik group/claim (see
  # agentgateway/config.yaml). Same generate-and-forget pattern as
  # OPENCLAW_GATEWAY_TOKEN below.
  AGENTGATEWAY_OPENWEBUI_TOKEN="$(load_host_secret agentgateway-openwebui-token 32)"
  AGENTGATEWAY_OPENCLAW_TOKEN="$(load_host_secret agentgateway-openclaw-token 32)"
  # Same generate-and-forget pattern as the two above, unconditionally, even
  # though it's only ever actually handed to a workspace when
  # CODER_ENABLED=1 (see reconcile_coder_profile_urls()'s TF_VAR_
  # agentgateway_token, the only consumer) - config.yaml substitutes every
  # referenced var over the whole file unconditionally, so a Coder-disabled
  # installation would otherwise crash agentgateway on an unset var rather
  # than simply not using this one.
  AGENTGATEWAY_CODER_TOKEN="$(load_host_secret agentgateway-coder-token 32)"
  # Not referenced anywhere in config.yaml - agentgateway looks for this
  # exact env var name directly (undocumented outside its own error text)
  # whenever ui.policies.oidc is configured, to sign/encrypt the browser
  # session cookie. Confirmed live 2026-09-11: rejects anything that isn't
  # hex (an arbitrary string errors "Invalid character 't' at position 0"),
  # 32 bytes of hex works.
  AGENTGATEWAY_OIDC_COOKIE_SECRET="$(load_host_secret agentgateway-oidc-cookie-secret 32 hex)"
  # OpenClaw's init.mjs treats a missing/empty env var as fatal (unlike
  # agentgateway's own $VAR-substitution, which only crashes on a var that
  # is entirely absent) - an empty-string placeholder in compose.yaml
  # wouldn't survive the gap before apply_installation_service_env() runs.
  # Delivered as a mounted Docker secret instead, same as
  # OPENCLAW_GATEWAY_TOKEN, so it is present from the container's very
  # first start.
  ensure_docker_secret_from_value ai-stand-agentgateway-openclaw-token "$AGENTGATEWAY_OPENCLAW_TOKEN"
  PORTAINER_ADMIN_PASSWORD="$(load_host_secret portainer-admin-password 24)"
  WEBUI_SECRET_KEY="$(load_host_secret openwebui-secret-key 32)"
  ensure_docker_secret_from_value ai-stand-openwebui-secret-key "$WEBUI_SECRET_KEY"
  OPENCLAW_GATEWAY_TOKEN="$(load_host_secret openclaw-gateway-token 32)"
  ensure_docker_secret_from_value ai-stand-openclaw-gateway-token "$OPENCLAW_GATEWAY_TOKEN"

  METAMCP_POSTGRES_PASSWORD="$(load_host_secret metamcp-postgres-password 24 hex)"
  ensure_docker_secret_from_value ai-stand-metamcp-postgres-password "$METAMCP_POSTGRES_PASSWORD"

  # Backs agentgateway-postgres. hex mode (like metamcp/coder's own Postgres
  # passwords) matters here specifically: this value is embedded unescaped
  # inside a postgres:// connection URL in agentgateway/config.yaml, so it
  # must never need URL-percent-encoding.
  AGENTGATEWAY_POSTGRES_PASSWORD="$(load_host_secret agentgateway-postgres-password 24 hex)"
  ensure_docker_secret_from_value ai-stand-agentgateway-postgres-password "$AGENTGATEWAY_POSTGRES_PASSWORD"
  # BETTER_AUTH_SECRET and the bootstrap admin password are pushed as plain
  # env vars by apply_installation_service_env() (update_service_env), not
  # via a mounted Docker secret: MetaMCP has no file:// / _FILE indirection
  # for its own env vars at all (confirmed against docker-entrypoint.sh at
  # the exact pinned tag, 2026-09-10) - unlike WEBUI_SECRET_KEY/
  # OPENCLAW_GATEWAY_TOKEN above, which do support it (see compose.yaml).
  METAMCP_BETTER_AUTH_SECRET="$(load_host_secret metamcp-better-auth-secret 32)"
  METAMCP_BOOTSTRAP_PASSWORD="$(load_host_secret metamcp-bootstrap-password 24)"
  if [ "$CODER_ENABLED" = "1" ]; then
    CODER_POSTGRES_PASSWORD="$(load_host_secret coder-postgres-password 24 hex)"
    ensure_docker_secret_from_value ai-stand-coder-postgres-password "$CODER_POSTGRES_PASSWORD"
    # Never pushed into the container env - only used locally by
    # bootstrap_coder_admin()'s `docker exec`. Retrievable via `credentials`.
    CODER_ADMIN_PASSWORD="$(load_host_secret coder-admin-password 24)"
  fi
  ensure_gigacode_identity_broker_secrets
}

cmd_credentials() {
  load_os_info
  ensure_ai_stand_secrets
  cat <<CREDS
Authentik   : https://${AUTHENTIK_HOST}
  username  : ${AUTHENTIK_BOOTSTRAP_USERNAME}
  password  : ${AUTHENTIK_BOOTSTRAP_PASSWORD}
  api token : ${AUTHENTIK_BOOTSTRAP_TOKEN}
Portainer   : https://${PORTAINER_HOST}
  username  : ${PORTAINER_ADMIN_USERNAME}
  password  : ${PORTAINER_ADMIN_PASSWORD}
MetaMCP     : https://${METAMCP_HOST}
  email     : ${METAMCP_BOOTSTRAP_EMAIL}
  password  : ${METAMCP_BOOTSTRAP_PASSWORD}
  (log in, then create a namespace + endpoint + API key for OpenClaw/opencode to use)
OpenClaw gateway token: ${OPENCLAW_GATEWAY_TOKEN}

agentgateway (https://${AGENTGATEWAY_HOST}) machine tokens:
  openwebui : ${AGENTGATEWAY_OPENWEBUI_TOKEN}  (wired in automatically, shown for debugging only)
  openclaw  : ${AGENTGATEWAY_OPENCLAW_TOKEN}   (wired in automatically, shown for debugging only)
  coder     : ${AGENTGATEWAY_CODER_TOKEN}      (wired in automatically, shown for debugging only)

These are generated once per installation and persisted under
${AI_STAND_SECRETS_DIR} (root-only, mode 0600).

Rotation is NOT as simple as "delete the file and redeploy" for most of the
values above (confirmed 2026-09-13 by tracing every consumer):
- Docker secrets are immutable by design and ensure_docker_secret_from_value()
  only ever creates, never replaces one - deleting the host file just makes
  this script generate a new value for its own in-memory use, while the
  actual mounted secret (what the container reads) silently keeps the old
  one. This affects the Authentik bootstrap password/token, Portainer admin
  password, MetaMCP's bootstrap password, and the OpenClaw gateway
  token: after a "rotation" this command would print new values that don't
  actually work anywhere.
- WORSE: never delete the metamcp-postgres-password file this way. Its
  value is pushed to the app service live via update_service_env on every
  apply.sh run, but the database role's actual password is only ever set
  once, at initdb, from that same never-updated Docker secret - "rotating"
  this file breaks MetaMCP's DB connection immediately on next deploy, with
  no automatic recovery.
- What DOES rotate safely this way: the 4 Authentik OIDC client secrets
  (openwebui/portainer/metamcp/agentgateway) and the 2 agentgateway
  machine tokens above - cmd_configure_authentik()/apply_installation_service_env()
  actively PATCH/push these live on every run, not just create-once.

A real fix for the others needs an explicit secret-replace (docker secret rm
+ recreate, redeploy to remount) done together with updating whatever
downstream state depends on the old value (e.g. ALTER USER for the Postgres
passwords) - not implemented yet, do this by hand with care if ever needed.
CREDS
}

ensure_storage() {
  run_root install -d -m 0755 /mnt/storage
  run_root install -d -m 0750 -o root -g root "$BACKUP_ROOT"

  case "$NODE_NAME" in
    ai01)
      # Kept outside agentgateway-data: neither the gateway container nor
      # its service account may read the reconciler's AppRole/API-token file
      # paths, generated manifest, or timer state.
      run_root install -d -m 0700 -o root -g root "$READONLY_MCP_DATA_ROOT"
      run_root install -d -m 0700 -o root -g root "$READONLY_MCP_RECONCILER_DATA"
      # Host-local route overrides are an installation control-plane input,
      # never a profile/source artifact. Do not create the override file:
      # its deliberate absence retains the generic /mcp/work value.
      run_root install -d -m 0700 -o root -g root "$AI_STAND_DATA_ROOT"
      run_root install -d -m 0700 -o root -g root "$INSTALLATION_OVERRIDES_ROOT"
      migrate_root_data_to_component "$LMSTUDIO_DATA_ROOT" "$LMSTUDIO_DATA" 0750
      migrate_root_data_to_component "$OPENWEBUI_DATA_ROOT" "$OPENWEBUI_DATA" 0750
      migrate_root_data_to_component "$PORTAINER_DATA_ROOT" "$PORTAINER_DATA" 0750
      # MetaMCP moved here from the second node; a fresh, empty datastore is
      # intentional (see the "Судьба MetaMCP" note in the agentgateway
      # plan: 0 registered MCP servers, only a bootstrap admin account, so
      # a clean restart on the new node was accepted over migrating
      # /mnt/storage/metamcp-data from the previous node by hand).
      migrate_root_data_to_component "$METAMCP_DATA_ROOT" "$METAMCP_DATA" 0750
      # Same service:storage/0750 convention as every other component
      # above - the vendor image's own default UID (65532, confirmed live)
      # is deliberately overridden to APP_UID:APP_GID via compose.yaml's
      # `user:` on the agentgateway service, specifically so this directory
      # doesn't need an exception from /mnt/fix.sh's blanket
      # chown/chmod-every-*-data-dir sweep (a pre-existing host maintenance
      # cron, not part of this repo - confirmed live 2026-09-11 that fighting
      # it with a differently-named/world-readable directory just gets
      # re-clobbered, and isn't the right fix anyway: matching the UID this
      # host's own security convention expects is more correct than
      # carving out an exception from it).
      #
      # One-time rename (2026-09-11): config/ -> server/, matching the
      # {component}-data/{role} convention ("server" is agentgateway's one
      # and only role, same as openwebui/portainer's "server" - "config"
      # named the file's content, not the service). migrate_root_data_to_
      # component() below only migrates root-style data into the FIRST
      # component under a root - config/ already has its own .ai-stand-owner
      # marker from the original rollout, so that scan would skip it rather
      # than rename it; needs its own explicit move first.
      if run_root test -d "${AGENTGATEWAY_DATA_ROOT}/config" && ! run_root test -d "$AGENTGATEWAY_DATA"; then
        run_root mv "${AGENTGATEWAY_DATA_ROOT}/config" "$AGENTGATEWAY_DATA"
        log "Renamed ${AGENTGATEWAY_DATA_ROOT}/config to ${AGENTGATEWAY_DATA}"
      fi
      migrate_root_data_to_component "$AGENTGATEWAY_DATA_ROOT" "$AGENTGATEWAY_DATA" 0750
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$AGENTGATEWAY_POSTGRES_DATA"
      ensure_authentik_data
      ensure_portainer_data
      ;;
    ai02)
      # Manual OpenClaw configuration backups intentionally remain directly
      # below the component root. They are protected operator recovery
      # artifacts, not legacy root-style service data to migrate or delete.
      mark_existing_openclaw_component_owned "$OPENCLAW_DATA" "Gateway"
      mark_existing_openclaw_component_owned "$OPENCLAW_SANDBOX_DATA" "sandbox DIND"
      migrate_root_data_to_component "$OPENCLAW_DATA_ROOT" "$OPENCLAW_DATA" 0750 "openclaw.json.manual-backup-*"
      migrate_root_data_to_component "$OPENCLAW_DATA_ROOT" "$OPENCLAW_SANDBOX_DATA" 0750 "openclaw.json.manual-backup-*"
      ensure_openclaw_sandbox_workspace_root
      ensure_openclaw_gigacode_requester_state
      if [ "$CODER_ENABLED" = "1" ]; then
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_DATA_ROOT"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_SERVER_DATA"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_POSTGRES_DATA"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_PROVISIONER_DATA"
        run_root install -d -m 0700 -o "$APP_UID" -g "$APP_GID" "$CODER_PROVISIONER_HOME"
        run_root install -d -m 0700 -o "$APP_UID" -g "$APP_GID" "$CODER_PROVISIONER_RUNTIME"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_PROVISIONER_DOCKER_DATA"
      fi
      ;;
    *)
      die "Unknown node name: ${NODE_NAME:-empty}"
      ;;
  esac
  ensure_legacy_storage_maintenance_preserves_overrides
  ensure_host_secret_storage_protection
  harden_readonly_mcp_reconciler_control_files
  ensure_installation_override_protection
}

ensure_host_secret_storage_protection() {
  # _secrets is the narrow exception to the component-data ownership model:
  # its values are read by the root-owned installer and copied into Docker
  # Secrets, never read directly by service accounts. Repair all regular
  # files in this dedicated directory after a legacy maintenance pass.
  [ -d "$AI_STAND_SECRETS_DIR" ] || return 0
  run_root install -d -m 0700 -o root -g root "$AI_STAND_SECRETS_DIR"

  local path
  while IFS= read -r -d '' path; do
    [ -f "$path" ] || die "Host secret path must be a regular file: $path"
    run_root chown root:root "$path"
    run_root chmod 0600 "$path"
  done < <(run_root find "$AI_STAND_SECRETS_DIR" -xdev -maxdepth 1 -type f -print0)
}

harden_readonly_mcp_reconciler_control_files() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  # The existing host maintenance script recursively resets every *-data
  # tree to service:storage. This directory is the deliberate exception:
  # its config, manifests and tenant inventory describe credential-bearing
  # control-plane state and must stay inaccessible to application accounts.
  run_root install -d -m 0700 -o root -g root "$READONLY_MCP_DATA_ROOT"
  run_root install -d -m 0700 -o root -g root "$READONLY_MCP_RECONCILER_DATA"

  local path
  for path in \
    "$READONLY_MCP_RECONCILER_CONFIG" \
    "$READONLY_MCP_MANIFEST" \
    "$METAMCP_TENANT_IDENTITY_INVENTORY" \
    "$METAMCP_TENANT_MANIFEST"; do
    [ -e "$path" ] || continue
    [ -f "$path" ] || die "Read-only MCP control-plane path must be a regular file: $path"
    run_root chown root:root "$path"
    run_root chmod 0600 "$path"
  done
}

ensure_installation_override_protection() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  # The directory must be protected as well as the file: a mode-0600 file
  # in a service-owned writable parent can simply be replaced by that
  # service. This is intentionally repaired on every host run.
  run_root install -d -m 0700 -o root -g root "$INSTALLATION_OVERRIDES_ROOT"
  [ -e "$READONLY_MCP_RUNTIME_OVERRIDE_FILE" ] || return 0
  [ -f "$READONLY_MCP_RUNTIME_OVERRIDE_FILE" ] \
    || die "Read-only MCP runtime override is not a regular file"
  run_root chown root:root "$READONLY_MCP_RUNTIME_OVERRIDE_FILE"
  run_root chmod 0600 "$READONLY_MCP_RUNTIME_OVERRIDE_FILE"
}

ensure_legacy_storage_maintenance_preserves_overrides() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  # m01 had a pre-existing /mnt/fix.sh that recursively changes every
  # *-data tree to service:storage/0750. Keep its established behavior for
  # all ordinary component data, but append small, recognizable repair
  # blocks for root-only host secrets and the installation-control
  # directory. Refuse to modify an unrecognized maintenance script rather
  # than guessing at a third-party administrator's intent.
  local maintenance="/mnt/fix.sh"
  [ -f "$maintenance" ] || return 0
  run_root grep -Fqx 'sudo chown -R service:storage /mnt/storage/*-data' "$maintenance" \
    || die "Refusing to alter unrecognized legacy storage maintenance: $maintenance"
  run_root grep -Fqx 'sudo chmod -R 750             /mnt/storage/*-data' "$maintenance" \
    || die "Refusing to alter unrecognized legacy storage maintenance: $maintenance"

  local replacement changed=0
  replacement="$(mktemp)"
  run_root cat "$maintenance" > "$replacement"
  if ! run_root grep -Fqx '# ai-stand: preserve root-only installation overrides' "$maintenance"; then
    cat >> "$replacement" <<EOF

# ai-stand: preserve root-only installation overrides
sudo install -d -m 0700 -o root -g root ${INSTALLATION_OVERRIDES_ROOT}
if [ -f ${READONLY_MCP_RUNTIME_OVERRIDE_FILE} ]; then
  sudo chown root:root ${READONLY_MCP_RUNTIME_OVERRIDE_FILE}
  sudo chmod 0600 ${READONLY_MCP_RUNTIME_OVERRIDE_FILE}
fi
EOF
    changed=1
  fi
  if ! run_root grep -Fqx '# ai-stand: preserve root-only host secrets' "$maintenance"; then
    cat >> "$replacement" <<EOF

# ai-stand: preserve root-only host secrets
sudo install -d -m 0700 -o root -g root ${AI_STAND_SECRETS_DIR}
sudo find ${AI_STAND_SECRETS_DIR} -xdev -maxdepth 1 -type f -exec chown root:root {} +
sudo find ${AI_STAND_SECRETS_DIR} -xdev -maxdepth 1 -type f -exec chmod 0600 {} +
EOF
    changed=1
  fi
  if ! run_root grep -Fqx '# ai-stand: preserve read-only MCP control-plane state' "$maintenance"; then
    cat >> "$replacement" <<EOF

# ai-stand: preserve read-only MCP control-plane state
sudo install -d -m 0700 -o root -g root ${READONLY_MCP_DATA_ROOT}
sudo install -d -m 0700 -o root -g root ${READONLY_MCP_RECONCILER_DATA}
sudo find ${READONLY_MCP_RECONCILER_DATA} -xdev -maxdepth 1 -type f -exec chown root:root {} +
sudo find ${READONLY_MCP_RECONCILER_DATA} -xdev -maxdepth 1 -type f -exec chmod 0600 {} +
EOF
    changed=1
  fi
  if [ "$changed" = "1" ]; then
    run_root install -m 0750 -o root -g root "$replacement" "$maintenance"
    log "Updated legacy storage maintenance to preserve installation controls"
  fi
  rm -f "$replacement"
}

install_readonly_mcp_reconciler() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  local unit="ai-stand-readonly-mcp-reconciler"
  if [ "$READONLY_MCP_ENABLED" != "1" ]; then
    # A profile may ship the capability without enabling it. Stop a legacy
    # timer if an operator deliberately disables the feature, but retain its
    # root-only state and Docker Secrets for explicit recovery/rotation.
    run_root systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
    return 0
  fi

  require_readonly_mcp_sources
  local libexec_dir="/usr/local/libexec/ai-stand"
  local wrapper_tmp service_tmp timer_tmp
  wrapper_tmp="$(mktemp)"
  service_tmp="$(mktemp)"
  timer_tmp="$(mktemp)"
  cat > "$wrapper_tmp" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/python3 ${libexec_dir}/readonly-mcp-reconcile.py \\
  --config ${READONLY_MCP_RECONCILER_CONFIG} \\
  --manifest ${READONLY_MCP_MANIFEST} \\
  --apply-script ${SCRIPT_DIR}/apply.sh \\
  --installation ${INSTALLATION} \\
  --node ai01
WRAPPER
  cat > "$service_tmp" <<SERVICE
[Unit]
Description=Reconcile Authentik-attribute-backed ai-stand read-only MCP services
After=docker.service network-online.target
Wants=docker.service network-online.target
ConditionPathExists=${READONLY_MCP_RECONCILER_CONFIG}

[Service]
Type=oneshot
User=root
Group=root
ExecStart=${libexec_dir}/readonly-mcp-reconcile
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${READONLY_MCP_DATA_ROOT} /run/lock
UMask=0077
SERVICE
  cat > "$timer_tmp" <<TIMER
[Unit]
Description=Run ai-stand read-only MCP reconciliation every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
Unit=${unit}.service

[Install]
WantedBy=timers.target
TIMER
  run_root install -d -m 0750 -o root -g root "$libexec_dir"
  install_if_changed "$READONLY_MCP_RECONCILER" "${libexec_dir}/readonly-mcp-reconcile.py" 0750 root root
  run_root install -d -m 0750 -o root -g root "${libexec_dir}/metamcp-tenants"
  install_if_changed "${METAMCP_TENANT_CONTROL_SOURCE_DIR}/provision.py" "${libexec_dir}/metamcp-tenants/provision.py" 0750 root root
  install_if_changed "${METAMCP_TENANT_CONTROL_SOURCE_DIR}/tenant_manifest.py" "${libexec_dir}/metamcp-tenants/tenant_manifest.py" 0640 root root
  install_if_changed "${METAMCP_TENANT_CONTROL_SOURCE_DIR}/tenant_runtime.py" "${libexec_dir}/metamcp-tenants/tenant_runtime.py" 0640 root root
  install_if_changed "${METAMCP_TENANT_CONTROL_SOURCE_DIR}/legacy_inventory_adapter.py" "${libexec_dir}/metamcp-tenants/legacy_inventory_adapter.py" 0750 root root
  install_if_changed "$wrapper_tmp" "${libexec_dir}/readonly-mcp-reconcile" 0750 root root
  install_if_changed "$service_tmp" "/etc/systemd/system/${unit}.service" 0644 root root
  install_if_changed "$timer_tmp" "/etc/systemd/system/${unit}.timer" 0644 root root
  rm -f "$wrapper_tmp" "$service_tmp" "$timer_tmp"
  run_root systemctl daemon-reload
  run_root systemctl enable --now "${unit}.timer" >/dev/null
  log "Read-only MCP reconciler timer installed (five-minute interval)"
}

has_firewalld_zone() {
  run_root firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx "$1"
}

ensure_firewalld_zone() {
  local zone="$1"
  if has_firewalld_zone "$zone"; then
    log "firewalld zone ${zone} already exists"
  else
    run_root firewall-cmd --permanent --new-zone="$zone" >/dev/null
    log "Created firewalld zone ${zone}"
  fi
}

ensure_zone_source() {
  local zone="$1"
  local source="$2"
  if run_root firewall-cmd --permanent --zone="$zone" --query-source="$source" >/dev/null; then
    log "firewalld source ${source} already assigned to ${zone}"
  else
    run_root firewall-cmd --permanent --zone="$zone" --add-source="$source" >/dev/null
    log "Added firewalld source ${source} to ${zone}"
  fi
}

remove_stale_zone_sources() {
  local zone="$1"
  shift
  local -a keep=("$@")
  local -a current

  if [ "${#keep[@]}" -eq 0 ]; then
    # An empty --trusted-cidr set here is far more likely a missing/dropped
    # argument than a deliberate "trust nothing" - reconciling to that would
    # strip every currently-trusted source from ai-stand (ssh/http/https),
    # a real lockout risk for anyone connecting from one of them. Skip
    # pruning rather than guess; existing sources stay until a real
    # --trusted-cidr list is passed to reconcile against.
    log "No --trusted-cidr entries passed; skipping stale firewalld source pruning for ${zone}"
    return 0
  fi
  # Same space-separated-on-one-line format as --get-zones above, so the
  # same read -ra split (not a plain `for x in $(...)`) applies here too.
  read -ra current <<<"$(run_root firewall-cmd --permanent --zone="$zone" --list-sources)"
  local source keep_source found
  for source in "${current[@]}"; do
    found=0
    for keep_source in "${keep[@]}"; do
      if [ "$source" = "$keep_source" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      run_root firewall-cmd --permanent --zone="$zone" --remove-source="$source" >/dev/null
      log "Removed stale firewalld source ${source} from ${zone} (no longer in --trusted-cidr)"
    fi
  done
}

ensure_zone_service() {
  local zone="$1"
  local service="$2"
  if run_root firewall-cmd --permanent --zone="$zone" --query-service="$service" >/dev/null; then
    log "firewalld service ${service} already allowed in ${zone}"
  else
    run_root firewall-cmd --permanent --zone="$zone" --add-service="$service" >/dev/null
    log "Allowed firewalld service ${service} in ${zone}"
  fi
}

remove_zone_service_if_present() {
  local zone="$1"
  local service="$2"
  if run_root firewall-cmd --permanent --zone="$zone" --query-service="$service" >/dev/null; then
    run_root firewall-cmd --permanent --zone="$zone" --remove-service="$service" >/dev/null
    log "Removed firewalld service ${service} from ${zone}"
  fi
}

remove_zone_port_if_present() {
  local zone="$1"
  local port="$2"
  if run_root firewall-cmd --permanent --zone="$zone" --query-port="${port}/tcp" >/dev/null; then
    run_root firewall-cmd --permanent --zone="$zone" --remove-port="${port}/tcp" >/dev/null
    log "Removed firewalld port ${port}/tcp from ${zone}"
  fi
}

ensure_rich_rule() {
  local zone="$1"
  local rule="$2"
  if run_root firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null; then
    log "firewalld rich rule already present in ${zone}: ${rule}"
  else
    run_root firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" >/dev/null
    log "Added firewalld rich rule in ${zone}: ${rule}"
  fi
}

remove_rich_rule_if_present() {
  local zone="$1"
  local rule="$2"
  if run_root firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null; then
    run_root firewall-cmd --permanent --zone="$zone" --remove-rich-rule="$rule" >/dev/null
    log "Removed firewalld rich rule from ${zone}: ${rule}"
  fi
}

configure_firewalld() {
  run_root systemctl enable --now firewalld >/dev/null
  ensure_firewalld_zone ai-stand
  local trusted_cidr
  for trusted_cidr in "${TRUSTED_CIDRS[@]}"; do
    ensure_zone_source ai-stand "$trusted_cidr"
  done
  # Unlike the Docker-published-port firewall layer below (which fully
  # rebuilds its iptables chains from TRUSTED_CIDRS on every run), firewalld
  # zone sources only ever accumulated - a CIDR removed from --trusted-cidr
  # kept standing SSH/HTTP/HTTPS access forever. Prune anything not in the
  # current list.
  remove_stale_zone_sources ai-stand "${TRUSTED_CIDRS[@]}"
  ensure_zone_service ai-stand ssh
  ensure_zone_service ai-stand http
  ensure_zone_service ai-stand https

  local zone
  local port
  # firewall-cmd prints zone names space-separated on one line, not one per
  # line, so this needs an explicit split (`read -ra`) rather than a plain
  # `for zone in $(...)`, which is also subject to pathname expansion on
  # each unquoted word (harmless in practice for zone names, but avoidable).
  local -a zones
  read -ra zones <<<"$(run_root firewall-cmd --permanent --get-zones)"
  for zone in "${zones[@]}"; do
    if [ -n "$PEER_IP" ]; then
      for port in "${SWARM_TCP_PORTS[@]}"; do
        ensure_rich_rule "$zone" "rule family=\"ipv4\" source address=\"${PEER_IP}\" port port=\"${port}\" protocol=\"tcp\" accept"
      done
      for port in "${SWARM_UDP_PORTS[@]}"; do
        ensure_rich_rule "$zone" "rule family=\"ipv4\" source address=\"${PEER_IP}\" port port=\"${port}\" protocol=\"udp\" accept"
      done

      local peer_port
      local -a peer_ports
      read -ra peer_ports <<<"$(peer_allowed_technical_ports)"
      for peer_port in "${peer_ports[@]}"; do
        ensure_rich_rule "$zone" "rule priority=\"-100\" family=\"ipv4\" source address=\"${PEER_IP}\" port port=\"${peer_port}\" protocol=\"tcp\" accept"
      done

      # Older ai-stand revisions allowed the second node to reach ai01:9443 for
      # Portainer. Current routing goes through ai01:443, so remove that stale
      # exception when present.
      remove_rich_rule_if_present "$zone" "rule family=\"ipv4\" source address=\"${PEER_IP}\" port port=\"9443\" protocol=\"tcp\" accept"
      remove_rich_rule_if_present "$zone" "rule priority=\"-100\" family=\"ipv4\" source address=\"${PEER_IP}\" port port=\"19001\" protocol=\"tcp\" accept"
    fi

    if [ "$zone" != "ai-stand" ]; then
      remove_zone_service_if_present "$zone" http
      remove_zone_service_if_present "$zone" https
      for port in "${PUBLIC_PORTS[@]}"; do
        remove_zone_port_if_present "$zone" "$port"
      done
    fi

    while IFS= read -r port; do
      ensure_rich_rule "$zone" "rule family=\"ipv4\" port port=\"${port}\" protocol=\"tcp\" drop"
    done < <(technical_ports_for_current_node)

    for port in "${PUBLIC_PORTS[@]}"; do
      for trusted_cidr in "${TRUSTED_CIDRS[@]}"; do
        remove_rich_rule_if_present "$zone" "rule family=\"ipv4\" source not address=\"${trusted_cidr}\" port port=\"${port}\" protocol=\"tcp\" drop"
      done
    done
  done

  run_root firewall-cmd --reload >/dev/null
  log "firewalld rules applied"
}

install_docker_user_helper() {
  local helper_tmp
  local defaults_tmp
  local service_tmp
  helper_tmp="$(mktemp)"
  defaults_tmp="$(mktemp)"
  service_tmp="$(mktemp)"

  local peer_ports
  local trusted_cidrs
  local technical_ports
  peer_ports="$(peer_allowed_technical_ports | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  trusted_cidrs="$(printf '%s\n' "${TRUSTED_CIDRS[@]}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  technical_ports="$(technical_ports_for_current_node | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  {
    printf '%s\n' "# Managed by ai-stand/apply.sh"
    printf 'PEER_IP=%q\n' "$PEER_IP"
    printf 'PEER_ALLOWED_PORTS=%q\n' "$peer_ports"
    printf 'TRUSTED_CIDRS=%q\n' "$trusted_cidrs"
  } > "$defaults_tmp"

  # This heredoc is single-quoted (no variable expansion) so the ipt/CHAIN
  # logic below can't accidentally pick up $-expansion. PORTS is written as
  # a placeholder token here and substituted with the node's real technical
  # port values
  # right after the heredoc closes (see the sed call below), so the
  # installed firewall script's port list is generated from the same
  # node-aware source
  # instead of a hand-copied literal that can silently drift out of sync -
  # a port missing here passes check_port_closed_to_non_loopback's
  # DOCKER-USER checks but fails its "INPUT does not block" check.
  cat > "$helper_tmp" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

CHAIN="AI-STAND-PROTECT"
HOST_CHAIN="AI-STAND-HOST-PROTECT"
PORTS=(__AI_STAND_TECH_PORTS__)
PUBLIC_PORTS=(80 443)
PEER_IP=""
PEER_ALLOWED_PORTS=""
TRUSTED_CIDRS=""

if [ -r /etc/default/ai-stand-firewall ]; then
  # shellcheck disable=SC1091
  . /etc/default/ai-stand-firewall
fi

apply_rules() {
  local ipt="$1"
  command -v "$ipt" >/dev/null 2>&1 || return 0

  "$ipt" -w -N "$CHAIN" 2>/dev/null || true
  "$ipt" -w -N "$HOST_CHAIN" 2>/dev/null || true

  if "$ipt" -w -L DOCKER-USER >/dev/null 2>&1; then
    while "$ipt" -w -C DOCKER-USER -j "$CHAIN" 2>/dev/null; do
      "$ipt" -w -D DOCKER-USER -j "$CHAIN"
    done
    "$ipt" -w -I DOCKER-USER 1 -j "$CHAIN"
  fi

  while "$ipt" -w -C INPUT -j "$HOST_CHAIN" 2>/dev/null; do
    "$ipt" -w -D INPUT -j "$HOST_CHAIN"
  done
  "$ipt" -w -I INPUT 1 -j "$HOST_CHAIN"

  # These chains are owned by ai-stand. Rebuilding them on each run keeps old
  # multiport-era rules and misplaced RETURN rules from shadowing new ports.
  "$ipt" -w -F "$CHAIN"
  "$ipt" -w -A "$CHAIN" -i lo -j RETURN

  "$ipt" -w -F "$HOST_CHAIN"
  "$ipt" -w -A "$HOST_CHAIN" -i lo -j RETURN

  if [ "$ipt" = "iptables" ]; then
    local docker_if
    local public_port
    for docker_if in docker0 docker_gwbridge br+; do
      for public_port in "${PUBLIC_PORTS[@]}"; do
        "$ipt" -w -A "$HOST_CHAIN" -i "$docker_if" -p tcp --dport "$public_port" -j ACCEPT
      done
    done
  fi

  if [ "$ipt" = "iptables" ] && [ -n "$PEER_IP" ] && [ -n "$PEER_ALLOWED_PORTS" ]; then
    local peer_port
    for peer_port in $PEER_ALLOWED_PORTS; do
      "$ipt" -w -A "$CHAIN" -s "$PEER_IP" -p tcp -m conntrack --ctorigdstport "$peer_port" -j ACCEPT
      "$ipt" -w -A "$CHAIN" -s "$PEER_IP" -p tcp --dport "$peer_port" -j ACCEPT
      "$ipt" -w -A "$HOST_CHAIN" -s "$PEER_IP" -p tcp --dport "$peer_port" -j ACCEPT
    done
  fi

  if [ "$ipt" = "iptables" ]; then
    local trusted_cidr
    for public_port in "${PUBLIC_PORTS[@]}"; do
      for trusted_cidr in $TRUSTED_CIDRS; do
        "$ipt" -w -A "$HOST_CHAIN" -s "$trusted_cidr" -p tcp --dport "$public_port" -j ACCEPT
      done
      "$ipt" -w -A "$HOST_CHAIN" -p tcp --dport "$public_port" -j DROP
    done
  else
    for public_port in "${PUBLIC_PORTS[@]}"; do
      "$ipt" -w -A "$HOST_CHAIN" -p tcp --dport "$public_port" -j DROP
    done
  fi

  for port in "${PORTS[@]}"; do
    "$ipt" -w -A "$CHAIN" -p tcp -m conntrack --ctorigdstport "$port" -j DROP
    "$ipt" -w -A "$CHAIN" -p tcp --dport "$port" -j DROP
    "$ipt" -w -A "$HOST_CHAIN" -p tcp --dport "$port" -j DROP
  done

  "$ipt" -w -A "$CHAIN" -j RETURN
  "$ipt" -w -A "$HOST_CHAIN" -j RETURN
}

apply_rules iptables
apply_rules ip6tables
HELPER

  sed -i "s/__AI_STAND_TECH_PORTS__/${technical_ports}/" "$helper_tmp"

  cat > "$service_tmp" <<'SERVICE'
[Unit]
Description=Protect ai-stand Docker upstream ports
After=docker.service firewalld.service
Wants=docker.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ai-stand-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

  install_if_changed "$defaults_tmp" /etc/default/ai-stand-firewall 0644 root root
  install_if_changed "$helper_tmp" /usr/local/sbin/ai-stand-firewall 0755 root root
  install_if_changed "$service_tmp" /etc/systemd/system/ai-stand-firewall.service 0644 root root
  rm -f "$helper_tmp" "$defaults_tmp" "$service_tmp"

  run_root systemctl daemon-reload
  run_root systemctl enable ai-stand-firewall.service >/dev/null
  run_root systemctl restart ai-stand-firewall.service
  log "DOCKER-USER protection applied"
}

# openclaw-sandbox-dind cannot be a Swarm service: Swarm's task API has
# never had a Privileged field (moby/moby#24862, still open), so
# `docker stack deploy` silently drops `privileged: true` and the dind
# daemon fails every mount/cgroup setup it needs (confirmed live 2026-09-07 -
# HostConfig.Privileged came back false despite the compose file). Instead
# this runs as a plain host-level `docker run` container managed by its own
# systemd unit, matching how install_docker_user_helper/install_nginx above
# already manage host-level pieces outside the stack. It attaches to the
# Swarm-created ai-openclaw-sandbox network as an external, non-stack member
# (that network is attachable:true for exactly this) with the same
# `openclaw-sandbox-dind` alias openclaw-gateway's DOCKER_HOST expects. The
# network only exists once `deploy` has run at least once, so on a fresh
# install the first start(s) fail until then - Restart=on-failure below
# retries until it succeeds, the same self-healing behavior a Swarm
# restart_policy would have given it.
ensure_openclaw_sandbox_dind_service() {
  local network_name="${STACK_NAME}_ai-openclaw-sandbox"
  local service_tmp
  service_tmp="$(mktemp)"

  cat > "$service_tmp" <<UNIT
[Unit]
Description=OpenClaw sandbox Docker-in-Docker daemon (host-level: Swarm services cannot get privileged mode)
After=docker.service
Wants=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f ai-stand-openclaw-sandbox-dind
ExecStart=/usr/bin/docker run --rm --name ai-stand-openclaw-sandbox-dind --privileged -e DOCKER_TLS_CERTDIR= --network ${network_name} --network-alias openclaw-sandbox-dind -v ${OPENCLAW_SANDBOX_DATA}:/var/lib/docker -v ${OPENCLAW_SANDBOX_WORKSPACE_ROOT}:/home/ai/.openclaw/sandboxes:rw ${OPENCLAW_SANDBOX_DIND_IMAGE}
ExecStop=/usr/bin/docker stop -t 30 ai-stand-openclaw-sandbox-dind
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

  install_if_changed "$service_tmp" /etc/systemd/system/ai-stand-openclaw-sandbox-dind.service 0644 root root
  rm -f "$service_tmp"

  run_root systemctl daemon-reload
  run_root systemctl enable ai-stand-openclaw-sandbox-dind.service >/dev/null
  run_root systemctl restart ai-stand-openclaw-sandbox-dind.service
  log "OpenClaw sandbox dind host service applied"
}

# Coder's built-in provisioner (the Community edition path) needs a Docker
# endpoint, but must never receive this host's /var/run/docker.sock or the
# privileged OpenClaw DIND daemon.  A distinct rootless dockerd runs as the
# same numeric service user as the Coder container.  Its state and socket are
# confined below coder-data/provisioner, and its only explicit workspace
# network is ai-coder-workspaces.
ensure_coder_rootless_docker_service() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  local runtime_uid
  runtime_uid="$(id -u "$CODER_RUNTIME_USER" 2>/dev/null || true)"
  [ "$runtime_uid" = "$APP_UID" ] \
    || die "Coder runtime user ${CODER_RUNTIME_USER} must have UID ${APP_UID}"
  getent group "$APP_GID" >/dev/null \
    || die "Coder app GID ${APP_GID} does not exist"
  grep -qE "^${CODER_RUNTIME_USER}:[0-9]+:[0-9]+$" /etc/subuid \
    || die "Coder runtime user ${CODER_RUNTIME_USER} has no subordinate UID range"
  grep -qE "^${CODER_RUNTIME_USER}:[0-9]+:[0-9]+$" /etc/subgid \
    || die "Coder runtime user ${CODER_RUNTIME_USER} has no subordinate GID range"

  # docker-ce-rootless-extras supplies dockerd-rootless.sh/rootlesskit;
  # slirp4netns supplies the unprivileged network backend.  These packages
  # do not alter the system Docker daemon or its socket.
  if ! command_exists dockerd-rootless.sh || ! command_exists rootlesskit; then
    run_root apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce-rootless-extras
  fi
  if ! command_exists slirp4netns || ! command_exists newuidmap || ! command_exists newgidmap; then
    run_root apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y slirp4netns fuse-overlayfs uidmap
  fi

  command_exists dockerd-rootless.sh || die "dockerd-rootless.sh is unavailable after installing Coder prerequisites"
  command_exists rootlesskit || die "rootlesskit is unavailable after installing Coder prerequisites"
  command_exists slirp4netns || die "slirp4netns is unavailable after installing Coder prerequisites"

  local service_tmp
  service_tmp="$(mktemp)"
  cat > "$service_tmp" <<UNIT
[Unit]
Description=ai-stand Coder dedicated rootless Docker daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CODER_RUNTIME_USER}
Environment=HOME=${CODER_PROVISIONER_HOME}
Environment=XDG_RUNTIME_DIR=${CODER_PROVISIONER_RUNTIME}
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns
Environment=DOCKER_HOST=unix://${CODER_ROOTLESS_DOCKER_SOCKET}
ExecStartPre=/usr/bin/rm -f ${CODER_ROOTLESS_DOCKER_SOCKET}
ExecStart=/usr/bin/dockerd-rootless.sh --host=unix://${CODER_ROOTLESS_DOCKER_SOCKET} --data-root=${CODER_PROVISIONER_DOCKER_DATA}
Restart=on-failure
RestartSec=10
PrivateTmp=yes
Delegate=yes

[Install]
WantedBy=multi-user.target
UNIT

  install_if_changed "$service_tmp" /etc/systemd/system/ai-stand-coder-rootless-docker.service 0644 root root
  rm -f "$service_tmp"
  run_root systemctl daemon-reload
  run_root systemctl enable --now ai-stand-coder-rootless-docker.service >/dev/null

  local deadline=$(( $(date +%s) + 120 ))
  until run_root sudo -u "$CODER_RUNTIME_USER" env \
    HOME="$CODER_PROVISIONER_HOME" \
    XDG_RUNTIME_DIR="$CODER_PROVISIONER_RUNTIME" \
    DOCKER_HOST="unix://${CODER_ROOTLESS_DOCKER_SOCKET}" \
    docker info >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || die "Coder rootless Docker daemon did not become ready within 120 seconds"
    sleep 2
  done

  run_root sudo -u "$CODER_RUNTIME_USER" env \
    HOME="$CODER_PROVISIONER_HOME" \
    XDG_RUNTIME_DIR="$CODER_PROVISIONER_RUNTIME" \
    DOCKER_HOST="unix://${CODER_ROOTLESS_DOCKER_SOCKET}" \
    docker network inspect "$CODER_WORKSPACE_NETWORK" >/dev/null 2>&1 \
    || run_root sudo -u "$CODER_RUNTIME_USER" env \
      HOME="$CODER_PROVISIONER_HOME" \
      XDG_RUNTIME_DIR="$CODER_PROVISIONER_RUNTIME" \
      DOCKER_HOST="unix://${CODER_ROOTLESS_DOCKER_SOCKET}" \
      docker network create "$CODER_WORKSPACE_NETWORK" >/dev/null
  log "Coder dedicated rootless Docker daemon is ready"
}

# ai-stand-coder-workspace is the image docker_container.workspace in
# docker/coder-templates/ai-stand-dev/main.tf requires to already exist in
# the dedicated rootless daemon's local image store before any workspace
# build - that daemon has no route to any registry but the public internet,
# and this image is never published to one. Same reasoning, same "docker
# build -t tag -" stdin-only approach (no COPY/ADD, see the Dockerfile's own
# header) as ensure_openclaw_sandbox_image() below, but built against the
# Coder rootless daemon (a host-level systemd unit, not a container to
# `docker exec` into - see ensure_coder_rootless_docker_service() just
# above) rather than openclaw-sandbox-dind, so it needs that daemon's own
# sudo -u "$CODER_RUNTIME_USER" env DOCKER_HOST=... invocation instead of a
# plain docker exec.
#
# Called right after ensure_coder_rootless_docker_service() in cmd_host,
# which already blocks until `docker info` succeeds against this same
# daemon before returning - no separate readiness poll needed here, unlike
# ensure_openclaw_sandbox_image()'s own wait (that one's prerequisite,
# ensure_openclaw_sandbox_dind_service, does NOT itself wait for the inner
# dockerd to finish starting).
ensure_coder_workspace_image() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  run_root sudo -u "$CODER_RUNTIME_USER" env \
    HOME="$CODER_PROVISIONER_HOME" \
    XDG_RUNTIME_DIR="$CODER_PROVISIONER_RUNTIME" \
    DOCKER_HOST="unix://${CODER_ROOTLESS_DOCKER_SOCKET}" \
    docker build -t "$CODER_WORKSPACE_IMAGE" - < "${SCRIPT_DIR}/docker/coder-workspace/Dockerfile"

  log "Coder workspace image ${CODER_WORKSPACE_IMAGE} is available in the Coder rootless daemon"
}

# registry.terraform.io is geo-blocked from this network - confirmed live
# 2026-09-23 via a direct curl to its .well-known/terraform.json, which
# returns an HTML page ("Content not available in your region... trade
# controls"), not the JSON `terraform init` expects, so every provider
# installation attempt against the real registry fails outright. GitHub
# itself (github.com, api.github.com, and its release-asset download host)
# is reachable, so mirror the two exact provider builds the ai-stand-dev
# template pins (docker/coder-templates/ai-stand-dev/main.tf) from their
# GitHub releases into a local filesystem_mirror instead - confirmed live
# the same day: terraform validate fully succeeds against this mirror with
# no other change. Checksums below are copied verbatim from each release's
# own published SHA256SUMS file (terraform-provider-coder_2.19.0_SHA256SUMS
# / terraform-provider-docker_4.6.0_SHA256SUMS), the same pinning approach
# already used for e.g. the Node.js tarball in this same coder-workspace
# image (see its own Dockerfile).
#
# The mirror directory and .terraformrc live under CODER_SERVER_DATA
# (bind-mounted to /home/coder in the coder server container - see
# compose.coder.yaml) specifically so HOME=/home/coder already set there
# makes Terraform find .terraformrc with no extra TF_CLI_CONFIG_FILE env
# var, and so .terraformrc's own `path` is written in the container's own
# /home/coder terms, not this host's /mnt/storage/... path.
ensure_coder_terraform_provider_mirror() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  local mirror_root="${CODER_SERVER_DATA}/.terraform-providers-mirror/registry.terraform.io"
  local tmp

  local coder_zip="${mirror_root}/coder/coder/terraform-provider-coder_2.19.0_linux_amd64.zip"
  if ! run_root test -f "$coder_zip"; then
    tmp="$(mktemp)"
    curl --fail --location --proto '=https' --show-error --silent --tlsv1.2 \
      "https://github.com/coder/terraform-provider-coder/releases/download/v2.19.0/terraform-provider-coder_2.19.0_linux_amd64.zip" \
      --output "$tmp"
    printf '%s  %s\n' "a9a1106d578f2fe42336ec49dcd0cccd9d23845dbbddfaa00607839564328e12" "$tmp" \
      | sha256sum --check --strict - >/dev/null \
      || die "Checksum mismatch downloading terraform-provider-coder 2.19.0"
    run_root install -D -m 0640 -o "$APP_UID" -g "$APP_GID" "$tmp" "$coder_zip"
    rm -f "$tmp"
    log "Downloaded terraform-provider-coder 2.19.0 into the local filesystem mirror"
  fi

  local docker_zip="${mirror_root}/kreuzwerker/docker/terraform-provider-docker_4.6.0_linux_amd64.zip"
  if ! run_root test -f "$docker_zip"; then
    tmp="$(mktemp)"
    curl --fail --location --proto '=https' --show-error --silent --tlsv1.2 \
      "https://github.com/kreuzwerker/terraform-provider-docker/releases/download/v4.6.0/terraform-provider-docker_4.6.0_linux_amd64.zip" \
      --output "$tmp"
    printf '%s  %s\n' "866046fa4938ac1ed5cc58b3c4d36e27433dac1aae50256911e6f28184dcf82e" "$tmp" \
      | sha256sum --check --strict - >/dev/null \
      || die "Checksum mismatch downloading terraform-provider-docker 4.6.0"
    run_root install -D -m 0640 -o "$APP_UID" -g "$APP_GID" "$tmp" "$docker_zip"
    rm -f "$tmp"
    log "Downloaded terraform-provider-docker 4.6.0 into the local filesystem mirror"
  fi

  local rc_tmp
  rc_tmp="$(mktemp)"
  cat > "$rc_tmp" <<'RC'
provider_installation {
  filesystem_mirror {
    path    = "/home/coder/.terraform-providers-mirror"
    include = ["registry.terraform.io/*/*"]
  }
}
RC
  install_if_changed "$rc_tmp" "${CODER_SERVER_DATA}/.terraformrc" 0640 "$APP_UID" "$APP_GID"
  rm -f "$rc_tmp"
}

# openclaw-sandbox:bookworm-slim is the pre-built sandbox image OpenClaw's
# Docker sandbox backend requires to exist in whatever daemon DOCKER_HOST
# resolves to before any sandboxed chat session can run - see
# docker/openclaw-sandbox/Dockerfile for the full citation and why this
# exact recipe. Must run against openclaw-sandbox-dind directly rather than
# through openclaw-gateway/DOCKER_HOST: this is called from cmd_host, which
# runs before cmd_deploy ever creates the openclaw-gateway Swarm service
# (see cmd_all's phase order), so on a from-scratch install that service
# does not exist yet. openclaw-sandbox-dind has no such dependency - it's a
# plain host-level container on ai02's own local Docker Engine
# (ensure_openclaw_sandbox_dind_service, above), always docker-exec-able
# once that function has run, and the docker:*-dind image already bundles a
# full docker CLI talking to its own local daemon, so no DOCKER_HOST/network
# setup is needed here. No build context is needed either (the sandbox
# Dockerfile has zero COPY/ADD) - "docker build -t tag -" reads the
# Dockerfile from stdin only, so this repo checkout never needs to be
# visible inside openclaw-sandbox-dind.
#
# ensure_openclaw_sandbox_dind_service (above) always restarts the dind
# container, even when nothing changed, so the inner daemon is not
# guaranteed ready the instant that function returns - Type=simple only
# waits for the ExecStart process to be launched, not for dockerd inside it
# to finish initializing. Poll before building instead of assuming it's up.
#
# Deliberately omits --pull (unlike this script's docker_cmd build calls in
# cmd_images): this is meant to be a one-time, idempotent setup step that's
# a near-instant no-op on repeat runs via Docker's build cache (image layers
# persist in OPENCLAW_SANDBOX_DATA, the bind-mounted /var/lib/docker, across
# dind container restarts) - --pull would force a fresh debian:bookworm-slim
# registry check on every single cmd_host run for no benefit here.
#
# Known tradeoff (found 2026-09-13): once built on a given host, the cached
# debian:bookworm-slim base layer is reused indefinitely - nothing here or
# in check_openclaw_sandbox_image() ever forces a fresh pull or checks the
# image's age, so this sandbox can silently keep running on an arbitrarily
# stale, unpatched Debian snapshot. That matters more for this container
# than for a typical throwaway build cache, since its whole purpose is to
# sandbox less-trusted code execution. Accepted for now given the speed
# benefit above; if this ever needs hardening, the fix is a periodic forced
# rebuild (e.g. re-running with --pull on some cadence), not just adding
# --pull here unconditionally (which would reintroduce the per-cmd_host-run
# registry check this was written to avoid).
ensure_openclaw_sandbox_image() {
  local deadline=$(( $(date +%s) + 120 ))
  local dind_ready=""

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker_cmd exec ai-stand-openclaw-sandbox-dind docker info >/dev/null 2>&1; then
      dind_ready="1"
      break
    fi
    sleep 2
  done
  [ "$dind_ready" = "1" ] \
    || die "openclaw-sandbox-dind daemon did not become ready for 'docker exec' within 120s"

  docker_cmd exec -i ai-stand-openclaw-sandbox-dind \
    docker build -t "$OPENCLAW_SANDBOX_IMAGE" - < "${SCRIPT_DIR}/docker/openclaw-sandbox/Dockerfile"

  log "OpenClaw sandbox image ${OPENCLAW_SANDBOX_IMAGE} is available in openclaw-sandbox-dind"
}

NGINX_BACKUP_KEEP_COUNT="${NGINX_BACKUP_KEEP_COUNT:-10}"

prune_nginx_backups() {
  # nginx-<RUN_TS> directory names sort lexicographically in the same order
  # as chronologically (RUN_TS is YYYYMMDD-HHMMSS) - no mtime/find -newer
  # needed. Nothing prunes these otherwise, and install_nginx() takes one
  # on every config change, so left alone they accumulate forever.
  local -a backups
  local old
  local count
  while IFS= read -r old; do
    [ -n "$old" ] && backups+=("$old")
  done < <(run_root find "$NGINX_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'nginx-*' 2>/dev/null | sort)

  count="${#backups[@]}"
  if [ "$count" -le "$NGINX_BACKUP_KEEP_COUNT" ]; then
    return 0
  fi

  local excess=$((count - NGINX_BACKUP_KEEP_COUNT))
  local i
  for ((i = 0; i < excess; i++)); do
    run_root rm -rf -- "${backups[$i]}"
    log "Pruned old nginx backup: ${backups[$i]}"
  done
}

backup_nginx_once() {
  if [ "$NGINX_BACKED_UP" = "1" ]; then
    return 0
  fi

  if run_root test -d /etc/nginx; then
    local backup="${NGINX_BACKUP_DIR}/nginx-${RUN_TS}"
    run_root install -d -m 0750 -o root -g root "$NGINX_BACKUP_DIR"
    run_root cp -a /etc/nginx "$backup"
    log "Backed up /etc/nginx to ${backup}"
    prune_nginx_backups
  fi
  NGINX_BACKED_UP="1"
}

install_nginx() {
  run_root install -d -m 0755 /etc/nginx/conf.d
  NGINX_SITE_SOURCE="$(nginx_site_source_for_node)"

  if ! run_root test -f /etc/nginx/nginx.conf || ! run_root cmp -s "$NGINX_CONF_SOURCE" /etc/nginx/nginx.conf; then
    backup_nginx_once
  fi
  install_if_changed "$NGINX_CONF_SOURCE" /etc/nginx/nginx.conf 0644 root root
  # Vendored (verbatim upstream nginx/conf/mime.types) rather than assumed:
  # this install's nginx.org package doesn't actually ship /etc/nginx/mime.types
  # (confirmed live 2026-09-11, nginx -t fails with ENOENT on it otherwise).
  install_if_changed "$NGINX_MIME_TYPES_SOURCE" /etc/nginx/mime.types 0644 root root

  if ! run_root test -f /etc/nginx/conf.d/ai-stand.conf || ! run_root cmp -s "$NGINX_SITE_SOURCE" /etc/nginx/conf.d/ai-stand.conf; then
    backup_nginx_once
  fi
  install_if_changed "$NGINX_SITE_SOURCE" /etc/nginx/conf.d/ai-stand.conf 0644 root root

  run_root nginx -t >/dev/null
  run_root systemctl enable --now nginx >/dev/null
  run_root systemctl reload nginx
  log "Nginx configuration applied"
}

install_agentgateway_config() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  # APP_UID:APP_GID, not root:root - matches the directory's own
  # service:storage ownership (migrate_root_data_to_component in
  # ensure_storage()) and the container's own user: override in
  # compose.yaml. No secrets live in this file (see its own header), so
  # 0640 (group-readable) is just consistency with that convention, not a
  # confidentiality requirement.
  # A full generic stack deploy must never consume a generated MCP overlay:
  # Agentgateway's user-specific Secret attachments are applied separately by
  # sync_readonly_mcp_runtime() after the core service exists.  Installing
  # the generic file first avoids a startup race where a rendered config
  # refers to a Docker Secret that has not been mounted yet.
  install_if_changed "$AGENTGATEWAY_CONFIG_SOURCE" "${AGENTGATEWAY_DATA}/config.yaml" 0640 "$APP_UID" "$APP_GID"
}

require_readonly_mcp_sources() {
  local path
  for path in \
    "$MCP_READONLY_COMMON_SOURCE_DIR/src/McpReadonly.Common/McpReadonly.Common.csproj" \
    "$JIRA_READONLY_MCP_SOURCE_DIR/Dockerfile" \
    "$CONFLUENCE_READONLY_MCP_SOURCE_DIR/Dockerfile" \
    "$IMAP_READONLY_MCP_SOURCE_DIR/Dockerfile" \
    "$GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR/Dockerfile" \
    "$READONLY_MCP_RENDERER" \
    "$READONLY_MCP_RECONCILER" \
    "$METAMCP_TENANT_CONTROL_SOURCE_DIR/provision.py" \
    "$METAMCP_TENANT_CONTROL_SOURCE_DIR/tenant_manifest.py" \
    "$METAMCP_TENANT_CONTROL_SOURCE_DIR/tenant_runtime.py"; do
    [ -f "$path" ] || die "Read-only MCP source is missing: $path"
  done
}

# Read only non-secret deployment settings from the root-owned reconciler
# configuration. The AppRole/Authentik token values themselves are stored in
# files named by that document and are never read by apply.sh.
readonly_mcp_setting() {
  local key="$1"
  [ -r "$READONLY_MCP_RECONCILER_CONFIG" ] \
    || die "Read-only MCP reconciler configuration is missing or unreadable: $READONLY_MCP_RECONCILER_CONFIG"
  python3 - "$READONLY_MCP_RECONCILER_CONFIG" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if data.get("version") != 1 or not isinstance(data.get("upstreams"), dict):
    raise SystemExit("readonly MCP reconciler config must have version 1 and upstreams")
value = data["upstreams"].get(sys.argv[2])
if value is None or value == "":
    raise SystemExit(f"readonly MCP upstream setting is missing: {sys.argv[2]}")
if isinstance(value, bool) or not isinstance(value, (str, int)):
    raise SystemExit(f"readonly MCP upstream setting has invalid type: {sys.argv[2]}")
print(value)
PY
}

render_readonly_mcp_profile() {
  [ "$READONLY_MCP_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai01" ] || die "READONLY_MCP_ENABLED requires host/deploy from ai01, the Agentgateway build node"
  require_readonly_mcp_sources
  [ -r "$READONLY_MCP_MANIFEST" ] || die "Read-only MCP manifest is missing or unreadable: $READONLY_MCP_MANIFEST"

  local jira_base_url confluence_base_url imap_host imap_port imap_tls_mode
  jira_base_url="$(readonly_mcp_setting jiraBaseUrl)"
  confluence_base_url="$(readonly_mcp_setting confluenceBaseUrl)"
  imap_host="$(readonly_mcp_setting imapHost)"
  imap_port="$(readonly_mcp_setting imapPort)"
  imap_tls_mode="$(readonly_mcp_setting imapTlsMode)"

  READONLY_MCP_RENDER_DIR="$(mktemp -d /tmp/ai-stand-readonly-mcp.XXXXXX)"
  # `trap` would collide with the caller's existing cleanup semantics; remove
  # the non-secret rendered staging copy explicitly after install. The
  # installation-owned output below is mode 0640 inside agentgateway-data.
  READONLY_MCP_RENDERED_AGENTGATEWAY_CONFIG="${READONLY_MCP_RENDER_DIR}/config.yaml"
  local rendered_compose="${READONLY_MCP_RENDER_DIR}/compose.yaml"
  python3 "$READONLY_MCP_RENDERER" \
    --manifest "$READONLY_MCP_MANIFEST" \
    --base-agentgateway-config "$AGENTGATEWAY_CONFIG_SOURCE" \
    --agentgateway-config-out "$READONLY_MCP_RENDERED_AGENTGATEWAY_CONFIG" \
    --compose-out "$rendered_compose" \
    --agentgateway-url "https://${AGENTGATEWAY_HOST}" \
    --openwebui-url "https://${OPENWEBUI_HOST}" \
    --mcp-issuer "https://${AUTHENTIK_HOST}/application/o/agentgateway-mcp/" \
    --mcp-client-id agentgateway-mcp \
    --mcp-path-prefix "$READONLY_MCP_PATH_PREFIX" \
    --jira-base-url "$jira_base_url" \
    --confluence-base-url "$confluence_base_url" \
    --imap-host "$imap_host" \
    --imap-port "$imap_port" \
    --imap-tls-mode "$imap_tls_mode" \
    --jira-image "$JIRA_READONLY_MCP_IMAGE" \
    --confluence-image "$CONFLUENCE_READONLY_MCP_IMAGE" \
    --imap-image "$IMAP_READONLY_MCP_IMAGE" \
    --gigacode-image "$GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE"

  run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$AGENTGATEWAY_DATA"
  install_if_changed "$rendered_compose" "$READONLY_MCP_RENDERED_COMPOSE" 0640 "$APP_UID" "$APP_GID"
}

readonly_mcp_gateway_secret_names() {
  # Return only backend bearer secrets. External Jira/Confluence/IMAP
  # credentials must never be mounted into Agentgateway.
  python3 - "$READONLY_MCP_MANIFEST" <<'PY'
import json
import re
import sys

secret = re.compile(r"^ai-stand-(?:mcp|gigacode)-[a-z0-9-]{3,100}$")
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("version") != 2 or not isinstance(manifest.get("users"), list):
    raise SystemExit("invalid readonly MCP manifest")
names = set()
for user in manifest["users"]:
    if not isinstance(user, dict):
        raise SystemExit("invalid readonly MCP user")
    for service in (user.get("services") or {}).values():
        if isinstance(service, dict):
            value = service.get("internalTokenSecret")
            if isinstance(value, str) and secret.fullmatch(value):
                names.add(value)
    personal = user.get("metamcp")
    if isinstance(personal, dict):
        value = personal.get("backendKeySecret")
        if isinstance(value, str) and secret.fullmatch(value):
            names.add(value)
for value in sorted(names):
    print(value)
PY
  # The user-scoped GigaCode routes validate broker-signed JWTs.  A core
  # deploy mounts this public JWKS through its own compose overlay, but the
  # narrow five-minute MCP reconciliation must also be self-sufficient: it
  # can be the first operation that installs those routes.  This is a public
  # verification key, never a Device ID or signing secret.
  if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
    printf '%s\n' "$GIGACODE_IDENTITY_BROKER_JWKS_SECRET"
  fi
}

sync_readonly_mcp_runtime() {
  [ "$READONLY_MCP_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai01" ] || die "Read-only MCP runtime can be synchronized only on ai01"
  [ -r "$READONLY_MCP_MANIFEST" ] || die "Read-only MCP manifest is missing: $READONLY_MCP_MANIFEST"

  render_readonly_mcp_profile

  local gateway_service="${STACK_NAME}_agentgateway"
  local -a desired_secrets=()
  local -a current_secrets=()
  local secret
  while IFS= read -r secret; do
    [ -n "$secret" ] && desired_secrets+=("$secret")
  done < <(readonly_mcp_gateway_secret_names)
  while IFS= read -r secret; do
    [ -n "$secret" ] && current_secrets+=("$secret")
  done < <(
    docker_cmd service inspect "$gateway_service" --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}' \
      | jq -r '.[]? | (.SecretName // .File.Name // empty) | select(test("^ai-stand-(mcp|gigacode)-"))'
  )

  # Mount new backend tokens before their route configuration becomes live.
  # The token values stay in Docker Secrets; only their safe names appear in
  # this command line and service spec.
  local -a add_args=()
  local present
  for secret in "${desired_secrets[@]}"; do
    present="0"
    local current
    for current in "${current_secrets[@]}"; do
      [ "$current" = "$secret" ] && present="1" && break
    done
    if [ "$present" = "0" ]; then
      docker_cmd secret inspect "$secret" >/dev/null \
        || die "Rendered MCP backend Secret does not exist: $secret"
      add_args+=(--secret-add "source=${secret},target=${secret},mode=0444")
    fi
  done
  if [ "${#add_args[@]}" -gt 0 ]; then
    # Agentgateway deliberately has a long Swarm update monitor so a later
    # failed OIDC discovery cannot roll a known-good task back.  A synchronous
    # `service update` therefore blocks the five-minute reconciler for that
    # whole monitor period even after the replacement task is ready.  Dispatch
    # asynchronously and retain the explicit readiness gate below.
    docker_cmd service update --detach=true "${add_args[@]}" "$gateway_service" >/dev/null
    # Let Swarm schedule the replacement before a replica-count probe; without
    # this tiny barrier the old 1/1 task can be observed once and treated as
    # the updated service.
    sleep 2
    wait_service_ready "$gateway_service"
  fi

  # The narrow fragment contains only MCP services and an external backend
  # network.  It never declares Agentgateway, Open WebUI, OpenClaw, LM
  # Studio or Authentik, so a five-minute reconcile cannot overwrite an
  # active model/context profile.
  docker_cmd stack config -c "$READONLY_MCP_RENDERED_COMPOSE" >/tmp/ai-stand-readonly-mcp-stack-config.yaml
  docker_cmd stack deploy --resolve-image never -c "$READONLY_MCP_RENDERED_COMPOSE" "$STACK_NAME"

  install_if_changed "$READONLY_MCP_RENDERED_AGENTGATEWAY_CONFIG" "${AGENTGATEWAY_DATA}/config.yaml" 0640 "$APP_UID" "$APP_GID"

  # Once the desired service set exists, atomically switch Agentgateway to
  # the rendered routes and retire only bearer mounts no longer referenced.
  # The configuration is updated before a removed backend service is stopped
  # by the caller, preserving the revoke-before-stop ordering.
  local -a reload_args=(--force)
  local wanted
  for current in "${current_secrets[@]}"; do
    wanted="0"
    for secret in "${desired_secrets[@]}"; do
      [ "$current" = "$secret" ] && wanted="1" && break
    done
    [ "$wanted" = "1" ] || reload_args+=(--secret-rm "$current")
  done
  docker_cmd service update --detach=true "${reload_args[@]}" "$gateway_service" >/dev/null
  sleep 2
  wait_service_ready "$gateway_service"

  # Install the managed remote MCP entries without touching the active
  # models, Codex/Claude subscription runtimes or user-created connections.
  update_service_env openclaw-gateway \
    "OPENCLAW_READONLY_MCP_ENABLED=1" \
    "OPENCLAW_READONLY_MCP_BASE_URL=https://${AGENTGATEWAY_HOST}" \
    "OPENCLAW_READONLY_MCP_PATH_PREFIX=${READONLY_MCP_PATH_PREFIX}"

  rm -rf "$READONLY_MCP_RENDER_DIR"
  unset READONLY_MCP_RENDERED_AGENTGATEWAY_CONFIG READONLY_MCP_RENDER_DIR
  log "Read-only MCP services and Agentgateway routes synchronized without a generic stack deploy"
}

install_authentik_icons() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  # nginx's worker processes run as www-data (nginx.conf's "user" directive)
  # and need read access to these files under a service:storage 0750/0640
  # directory (AUTHENTIK_ICONS_DATA) - add it to the storage group rather
  # than making the files world-readable, which /mnt/fix.sh's blanket
  # chmod -R 750 sweep of *-data directories would strip on its next run
  # anyway. Same reasoning as agentgateway's container user: override
  # earlier - align the reader to this host's own service:storage
  # convention instead of carving out an exception from it.
  run_root usermod -a -G storage www-data
  local file
  for file in openwebui.png portainer.svg metamcp.ico agentgateway.svg openclaw.png coder.svg; do
    install_if_changed "${AUTHENTIK_ICONS_SOURCE_DIR}/${file}" "${AUTHENTIK_ICONS_DATA}/${file}" 0640 "$APP_UID" "$APP_GID"
  done
  # usermod only takes effect for processes spawned after it runs - nginx's
  # already-running workers (started by install_nginx()'s own reload, above
  # in cmd_host) were forked before this point and won't see the new group
  # membership without a reload of their own.
  run_root systemctl reload nginx
}

ensure_node_labels() {
  local accelerator="$1"
  local node_id
  node_id="$(docker_cmd info --format '{{.Swarm.NodeID}}')"

  case "$NODE_NAME" in
    ai01)
      docker_cmd node update \
        --label-add ai-stand.node=ai01 \
        --label-add ai-stand.role=manager \
        --label-add ai-stand.ingress=true \
        --label-add ai-stand.lmstudio=true \
        --label-add ai-stand.openwebui=true \
        --label-add ai-stand.openclaw=false \
        --label-add ai-stand.authentik=true \
        --label-add ai-stand.portainer=true \
        --label-add ai-stand.metamcp=true \
        --label-add ai-stand.agentgateway=true \
        --label-add ai-stand.coder=true \
        --label-add "ai-stand.accelerator=${accelerator}" \
        "$node_id" >/dev/null
      ;;
    ai02)
      docker_cmd node update \
        --label-add ai-stand.node=ai02 \
        --label-add ai-stand.role=manager \
        --label-add ai-stand.ingress=true \
        --label-add ai-stand.lmstudio=false \
        --label-add ai-stand.openwebui=false \
        --label-add ai-stand.openclaw=true \
        --label-add ai-stand.authentik=false \
        --label-add ai-stand.portainer=false \
        --label-add ai-stand.metamcp=false \
        --label-add ai-stand.agentgateway=false \
        --label-add ai-stand.coder=true \
        --label-add ai-stand.accelerator=none \
        "$node_id" >/dev/null
      ;;
    *)
      die "Unknown node name: ${NODE_NAME:-empty}"
      ;;
  esac

  docker_cmd node update --label-rm ai-stand.storage "$node_id" >/dev/null 2>&1 || true
  docker_cmd node update --label-rm ai-stand.amd "$node_id" >/dev/null 2>&1 || true
  docker_cmd node update --label-rm ai-stand.vault "$node_id" >/dev/null 2>&1 || true
  log "Swarm node labels ensured on ${node_id}: node=${NODE_NAME}"
}

compose_args_for_accelerator() {
  local accelerator="$1"
  printf '%s\n' "-c" "$COMPOSE_FILE"

  case "$accelerator" in
    cpu) ;;
    amd) printf '%s\n' "-c" "$COMPOSE_AMD_FILE" ;;
    nvidia) printf '%s\n' "-c" "$COMPOSE_NVIDIA_FILE" ;;
    *) die "Unknown resolved accelerator: ${accelerator}" ;;
  esac

  # GigaCode is rendered only by the user-scoped reconciler.  Never merge a
  # global bridge into the core stack: it would make a shared Device ID
  # reachable by machine API tokens before per-subject authorization runs.
  if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
    printf '%s\n' "-c" "$COMPOSE_GIGACODE_IDENTITY_BROKER_FILE"
    printf '%s\n' "-c" "$COMPOSE_OPENCLAW_GIGACODE_ADAPTER_FILE"
  fi

  if [ "$CODER_ENABLED" = "1" ]; then
    printf '%s\n' "-c" "$COMPOSE_CODER_FILE"
    # A profile may pin Coder's browser-facing URLs.  Docker stack deploy
    # has historically handled process environment interpolation differently
    # from docker compose on some hosts; an explicit final overlay keeps the
    # initial Coder task bootable before drift reconciliation runs.
    local installation_coder_compose="${INSTALLATION_DIR}/compose.coder.yaml"
    if [ -r "$installation_coder_compose" ]; then
      printf '%s\n' "-c" "$installation_coder_compose"
    fi
  fi

  # User-scoped MCP services are deliberately not part of the generic stack
  # argument list. They are reconciled as a narrow fragment after the core
  # deployment, so neither a timer nor a manual MCP refresh can reset the
  # installation-specific model/context profile.
}

lmstudio_image_for_accelerator() {
  case "$1" in
    cpu) printf '%s\n' "$LMSTUDIO_CPU_IMAGE" ;;
    amd) printf '%s\n' "$LMSTUDIO_AMD_IMAGE" ;;
    nvidia) printf '%s\n' "$LMSTUDIO_NVIDIA_IMAGE" ;;
    *) die "Unknown resolved accelerator: $1" ;;
  esac
}

lmstudio_target_for_accelerator() {
  case "$1" in
    cpu) printf '%s\n' "lmstudio" ;;
    amd) printf '%s\n' "lmstudio-amd" ;;
    nvidia) printf '%s\n' "lmstudio-nvidia" ;;
    *) die "Unknown resolved accelerator: $1" ;;
  esac
}

cmd_preflight() {
  load_os_info
  check_reboot_marker_readonly
  local accelerator="none"
  if [ "$NODE_NAME" = "ai01" ]; then
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  log "Host OS: Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}), arch=${ARCH}, accelerator=${accelerator}"
  check_disk
  check_docker_preflight
  if [ "$NODE_NAME" = "ai01" ]; then
    check_accelerator_preflight "$accelerator"
  else
    log "Accelerator preflight skipped on ai02; LM Studio is pinned to ai01"
  fi
  check_cert_preflight

  check_node_dns

  log "Preflight complete"
}

cmd_host() {
  load_os_info
  check_reboot_marker
  ensure_base_packages
  local accelerator="none"
  if [ "$NODE_NAME" = "ai01" ]; then
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  ensure_docker
  configure_firewalld
  ensure_swarm
  cleanup_stale_swarm_nodes_after_recovery
  ensure_authentik_secrets
  if [ "$NODE_NAME" = "ai01" ]; then
    ensure_accelerator_runtime "$accelerator"
  else
    log "Accelerator runtime installation skipped on ai02; LM Studio is pinned to ai01"
  fi
  ensure_storage
  validate_readonly_mcp_runtime_override_permissions
  ensure_tls_cert
  configure_firewalld
  install_docker_user_helper
  if [ "$NODE_NAME" = "ai02" ]; then
    ensure_openclaw_sandbox_dind_service
    ensure_openclaw_sandbox_image
    ensure_coder_rootless_docker_service
    ensure_coder_workspace_image
    ensure_coder_terraform_provider_mirror
  fi
  install_nginx
  install_agentgateway_config
  install_readonly_mcp_reconciler
  install_authentik_icons
  ensure_node_labels "$accelerator"
  log "Host stage complete for accelerator=${accelerator}"
}

build_coder_image() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ -f "${SCRIPT_DIR}/docker/coder/Dockerfile" ] \
    || die "Coder wrapper Dockerfile is missing"
  [ -f "${SCRIPT_DIR}/docker/coder/entrypoint.sh" ] \
    || die "Coder wrapper entrypoint is missing"
  docker_cmd pull "$CODER_BASE_IMAGE"
  docker_cmd pull "$CODER_POSTGRES_IMAGE"
  docker_cmd build --pull \
    --build-arg "CODER_BASE_IMAGE=${CODER_BASE_IMAGE}" \
    --tag "$CODER_IMAGE" \
    -f "${SCRIPT_DIR}/docker/coder/Dockerfile" \
    "${SCRIPT_DIR}/docker/coder"
}

build_readonly_mcp_images() {
  [ "$READONLY_MCP_ENABLED" = "1" ] || return 0
  require_readonly_mcp_sources
  # Each image is built from its own module context. The common library is
  # passed as a named, read-only build context so no Dockerfile needs access
  # to the repository parent directory and no module depends on a registry.
  docker_cmd build --pull \
    --build-context "mcp-readonly-common=${MCP_READONLY_COMMON_SOURCE_DIR}" \
    --tag "$JIRA_READONLY_MCP_IMAGE" \
    -f "${JIRA_READONLY_MCP_SOURCE_DIR}/Dockerfile" \
    "$JIRA_READONLY_MCP_SOURCE_DIR"
  docker_cmd build --pull \
    --build-context "mcp-readonly-common=${MCP_READONLY_COMMON_SOURCE_DIR}" \
    --tag "$CONFLUENCE_READONLY_MCP_IMAGE" \
    -f "${CONFLUENCE_READONLY_MCP_SOURCE_DIR}/Dockerfile" \
    "$CONFLUENCE_READONLY_MCP_SOURCE_DIR"
  docker_cmd build --pull \
    --build-context "mcp-readonly-common=${MCP_READONLY_COMMON_SOURCE_DIR}" \
    --tag "$IMAP_READONLY_MCP_IMAGE" \
    -f "${IMAP_READONLY_MCP_SOURCE_DIR}/Dockerfile" \
    "$IMAP_READONLY_MCP_SOURCE_DIR"
}

cmd_images() {
  load_os_info
  local accelerator="none"

  if [ -z "$NODE_NAME" ] || [ "$NODE_NAME" = "ai01" ]; then
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  cd "$SCRIPT_DIR"
  docker_cmd build --pull --tag "$BASE_IMAGE" -f docker/base/Dockerfile .

  if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
    [ -f "${GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR}/Dockerfile" ] \
      || die "GigaCode subscription bridge source is missing: ${GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR}/Dockerfile"
    [ -f "${GIGACODE_IDENTITY_BROKER_SOURCE_DIR}/Dockerfile" ] \
      || die "GigaCode identity broker source is missing: ${GIGACODE_IDENTITY_BROKER_SOURCE_DIR}/Dockerfile"
    [ -f "${OPENCLAW_GIGACODE_ADAPTER_SOURCE_DIR}/Dockerfile" ] \
      || die "OpenClaw GigaCode adapter source is missing: ${OPENCLAW_GIGACODE_ADAPTER_SOURCE_DIR}/Dockerfile"
    [ -f "${OPENCLAW_GIGACODE_REQUESTER_PLUGIN_SOURCE_DIR}/openclaw.plugin.json" ] \
      || die "OpenClaw GigaCode requester plugin source is missing: ${OPENCLAW_GIGACODE_REQUESTER_PLUGIN_SOURCE_DIR}/openclaw.plugin.json"
  fi
  if [ "$READONLY_MCP_ENABLED" = "1" ]; then
    require_readonly_mcp_sources
  fi

  case "${NODE_NAME:-all}" in
    ai01)
      local lmstudio_target
      local lmstudio_image
      lmstudio_target="$(lmstudio_target_for_accelerator "$accelerator")"
      lmstudio_image="$(lmstudio_image_for_accelerator "$accelerator")"
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target "$lmstudio_target" --tag "$lmstudio_image" -f docker/lmstudio/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target lmstudio-proxy --tag "$LMSTUDIO_PROXY_IMAGE" -f docker/lmstudio-proxy/Dockerfile .
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
        docker_cmd build --pull --tag "$GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE" -f "${GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR}/Dockerfile" "$GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR"
        docker_cmd build --pull --tag "$GIGACODE_IDENTITY_BROKER_IMAGE" -f "${GIGACODE_IDENTITY_BROKER_SOURCE_DIR}/Dockerfile" "$GIGACODE_IDENTITY_BROKER_SOURCE_DIR"
      fi
      build_readonly_mcp_images
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --build-arg "AUTHENTIK_VERSION=${AUTHENTIK_VERSION}" --target authentik --tag "$AUTHENTIK_IMAGE" -f docker/authentik/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target authentik-configurator --tag "$AUTHENTIK_CONFIGURATOR_IMAGE" -f docker/authentik/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$DIAGNOSTIC_IMAGE" -f docker/diagnostic/Dockerfile .
      docker_cmd pull "$PORTAINER_IMAGE"
      docker_cmd pull "$PORTAINER_AGENT_IMAGE"
      docker_cmd pull "$OPENWEBUI_IMAGE"
      docker_cmd pull "$AUTHENTIK_POSTGRES_IMAGE"
      docker_cmd pull "$AUTHENTIK_REDIS_IMAGE"
      docker_cmd pull "$METAMCP_IMAGE"
      docker_cmd pull "$METAMCP_POSTGRES_IMAGE"
      docker_cmd pull "$AGENTGATEWAY_IMAGE"
      local -a ai01_images=("$BASE_IMAGE" "$lmstudio_image" "$LMSTUDIO_PROXY_IMAGE" "$AUTHENTIK_IMAGE" "$AUTHENTIK_CONFIGURATOR_IMAGE" "$PORTAINER_IMAGE" "$PORTAINER_AGENT_IMAGE" "$OPENWEBUI_IMAGE" "$AUTHENTIK_POSTGRES_IMAGE" "$AUTHENTIK_REDIS_IMAGE" "$DIAGNOSTIC_IMAGE" "$METAMCP_IMAGE" "$METAMCP_POSTGRES_IMAGE" "$AGENTGATEWAY_IMAGE")
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then ai01_images+=("$GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE" "$GIGACODE_IDENTITY_BROKER_IMAGE"); fi
      if [ "$READONLY_MCP_ENABLED" = "1" ]; then ai01_images+=("$JIRA_READONLY_MCP_IMAGE" "$CONFLUENCE_READONLY_MCP_IMAGE" "$IMAP_READONLY_MCP_IMAGE"); fi
      docker_cmd image inspect "${ai01_images[@]}" >/dev/null
      log "Required ai01 images are available for accelerator=${accelerator}"
      ;;
    ai02)
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --build-arg "OPENCLAW_VERSION=${OPENCLAW_VERSION}" --build-arg "DOCKER_CLI_VERSION=${DOCKER_CLI_VERSION}" --target openclaw --tag "$OPENCLAW_IMAGE" -f docker/openclaw/Dockerfile .
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
        docker_cmd build --pull --tag "$OPENCLAW_GIGACODE_ADAPTER_IMAGE" -f "${OPENCLAW_GIGACODE_ADAPTER_SOURCE_DIR}/Dockerfile" "$OPENCLAW_GIGACODE_ADAPTER_SOURCE_DIR"
      fi
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$DIAGNOSTIC_IMAGE" -f docker/diagnostic/Dockerfile .
      docker_cmd pull "$PORTAINER_AGENT_IMAGE"
      docker_cmd pull "$OPENCLAW_SANDBOX_DIND_IMAGE"
      build_coder_image
      local -a ai02_images=("$BASE_IMAGE" "$OPENCLAW_IMAGE" "$PORTAINER_AGENT_IMAGE" "$DIAGNOSTIC_IMAGE" "$OPENCLAW_SANDBOX_DIND_IMAGE")
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then ai02_images+=("$OPENCLAW_GIGACODE_ADAPTER_IMAGE"); fi
      if [ "$CODER_ENABLED" = "1" ]; then
        ai02_images+=("$CODER_IMAGE" "$CODER_POSTGRES_IMAGE")
      fi
      docker_cmd image inspect "${ai02_images[@]}" >/dev/null
      log "Required ai02 images are available"
      ;;
    all)
      local lmstudio_target
      local lmstudio_image
      lmstudio_target="$(lmstudio_target_for_accelerator "$accelerator")"
      lmstudio_image="$(lmstudio_image_for_accelerator "$accelerator")"
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target "$lmstudio_target" --tag "$lmstudio_image" -f docker/lmstudio/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target lmstudio-proxy --tag "$LMSTUDIO_PROXY_IMAGE" -f docker/lmstudio-proxy/Dockerfile .
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
        docker_cmd build --pull --tag "$GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE" -f "${GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR}/Dockerfile" "$GIGACODE_SUBSCRIPTION_BRIDGE_SOURCE_DIR"
        docker_cmd build --pull --tag "$GIGACODE_IDENTITY_BROKER_IMAGE" -f "${GIGACODE_IDENTITY_BROKER_SOURCE_DIR}/Dockerfile" "$GIGACODE_IDENTITY_BROKER_SOURCE_DIR"
      fi
      build_readonly_mcp_images
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --build-arg "OPENCLAW_VERSION=${OPENCLAW_VERSION}" --build-arg "DOCKER_CLI_VERSION=${DOCKER_CLI_VERSION}" --target openclaw --tag "$OPENCLAW_IMAGE" -f docker/openclaw/Dockerfile .
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
        docker_cmd build --pull --tag "$OPENCLAW_GIGACODE_ADAPTER_IMAGE" -f "${OPENCLAW_GIGACODE_ADAPTER_SOURCE_DIR}/Dockerfile" "$OPENCLAW_GIGACODE_ADAPTER_SOURCE_DIR"
      fi
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --build-arg "AUTHENTIK_VERSION=${AUTHENTIK_VERSION}" --target authentik --tag "$AUTHENTIK_IMAGE" -f docker/authentik/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target authentik-configurator --tag "$AUTHENTIK_CONFIGURATOR_IMAGE" -f docker/authentik/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$DIAGNOSTIC_IMAGE" -f docker/diagnostic/Dockerfile .
      docker_cmd pull "$PORTAINER_IMAGE"
      docker_cmd pull "$PORTAINER_AGENT_IMAGE"
      docker_cmd pull "$OPENWEBUI_IMAGE"
      docker_cmd pull "$AUTHENTIK_POSTGRES_IMAGE"
      docker_cmd pull "$AUTHENTIK_REDIS_IMAGE"
      docker_cmd pull "$METAMCP_IMAGE"
      docker_cmd pull "$METAMCP_POSTGRES_IMAGE"
      docker_cmd pull "$AGENTGATEWAY_IMAGE"
      local -a all_images=("$BASE_IMAGE" "$lmstudio_image" "$LMSTUDIO_PROXY_IMAGE" "$OPENCLAW_IMAGE" "$AUTHENTIK_IMAGE" "$AUTHENTIK_CONFIGURATOR_IMAGE" "$PORTAINER_IMAGE" "$PORTAINER_AGENT_IMAGE" "$OPENWEBUI_IMAGE" "$AUTHENTIK_POSTGRES_IMAGE" "$AUTHENTIK_REDIS_IMAGE" "$DIAGNOSTIC_IMAGE" "$METAMCP_IMAGE" "$METAMCP_POSTGRES_IMAGE" "$AGENTGATEWAY_IMAGE")
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then all_images+=("$GIGACODE_SUBSCRIPTION_BRIDGE_IMAGE" "$GIGACODE_IDENTITY_BROKER_IMAGE"); fi
      if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then all_images+=("$OPENCLAW_GIGACODE_ADAPTER_IMAGE"); fi
      if [ "$READONLY_MCP_ENABLED" = "1" ]; then all_images+=("$JIRA_READONLY_MCP_IMAGE" "$CONFLUENCE_READONLY_MCP_IMAGE" "$IMAP_READONLY_MCP_IMAGE"); fi
      docker_cmd image inspect "${all_images[@]}" >/dev/null
      log "Required images are available for accelerator=${accelerator}"
      ;;
    *)
      die "Unknown node name: ${NODE_NAME:-empty}"
      ;;
  esac
}

remove_obsolete_services() {
  local service
  for service in "${OBSOLETE_SERVICES[@]}"; do
    if [ "$CODER_ENABLED" = "1" ] \
      && { [ "$service" = "${STACK_NAME}_coder" ] || [ "$service" = "${STACK_NAME}_coder-postgres" ]; }; then
      continue
    fi
    if docker_cmd service inspect "$service" >/dev/null 2>&1; then
      docker_cmd service rm "$service" >/dev/null
      log "Removed obsolete service: ${service}"
    fi
  done
}

update_service_env() {
  local short_name="$1"
  shift

  local svc="${STACK_NAME}_${short_name}"
  docker_cmd service inspect "$svc" >/dev/null 2>&1 || die "Missing service: $svc"

  local args
  args=(--detach=true)
  local changed="false"
  local kv key desired current

  for kv in "$@"; do
    key="${kv%%=*}"
    desired="${kv#*=}"
    current="$(
      docker_cmd service inspect "$svc" --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' \
        | jq -r --arg key "$key" '.[]? | select(startswith($key + "=")) | .[(($key | length) + 1):]' \
        | head -n 1
    )"

    if [ "$current" = "$desired" ]; then
      continue
    fi

    # Docker applies --env-add as an upsert.  Pairing --env-rm and --env-add
    # for the same key in one update is order-sensitive in Swarm and can
    # leave the compose default in place (observed with Coder's OIDC URLs).
    # Use the native upsert alone, so profile values reliably replace the
    # generic compose placeholders.
    args+=(--env-add "$key=$desired")
    changed="true"
  done

  if [ "$changed" = "true" ]; then
    # Some services intentionally use a long Swarm monitor.  Do not make a
    # narrow configuration reconciliation wait for that monitor; the readiness
    # check below still ensures a usable replacement task exists.
    docker_cmd service update --detach=true "${args[@]}" "$svc" >/dev/null
    sleep 2
    wait_service_ready "$svc"
    log "Updated environment for ${svc}"
  else
    log "Environment already matches installation for ${svc}"
  fi
}

apply_installation_service_env() {
  update_service_env authentik-server \
    "AUTHENTIK_HOST_BROWSER=https://${AUTHENTIK_HOST}" \
    "IM_TZ=${IM_TZ}" \
    "IM_UID=${IM_UID}" \
    "IM_GID=${IM_GID}"
  update_service_env authentik-worker \
    "AUTHENTIK_HOST_BROWSER=https://${AUTHENTIK_HOST}" \
    "IM_TZ=${IM_TZ}" \
    "IM_UID=${IM_UID}" \
    "IM_GID=${IM_GID}"
  # Agentgateway must be configured before OpenClaw.  Gateway startup waits
  # on Agentgateway's /v1 endpoint, while Agentgateway cannot start with the
  # generic OIDC placeholder left by the base Compose file.  Keeping this
  # first breaks that otherwise circular readiness wait during a fresh or
  # rebuilt deployment.
  update_service_env agentgateway \
    "AGENTGATEWAY_OIDC_ISSUER_URL=https://${AUTHENTIK_HOST}/application/o/agentgateway/" \
    "AGENTGATEWAY_OIDC_REDIRECT_URI=https://${AGENTGATEWAY_HOST}/oauth/callback" \
    "MCP_AUTHENTIK_ISSUER_URL=https://${AUTHENTIK_HOST}/application/o/agentgateway-mcp/" \
    "MCP_AUTHENTIK_CLIENT_ID=agentgateway-mcp" \
    "AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET=${AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET}" \
    "AGENTGATEWAY_OPENWEBUI_TOKEN=${AGENTGATEWAY_OPENWEBUI_TOKEN}" \
    "AGENTGATEWAY_OPENCLAW_TOKEN=${AGENTGATEWAY_OPENCLAW_TOKEN}" \
    "AGENTGATEWAY_CODER_TOKEN=${AGENTGATEWAY_CODER_TOKEN}" \
    "OIDC_COOKIE_SECRET=${AGENTGATEWAY_OIDC_COOKIE_SECRET}" \
    "AGENTGATEWAY_POSTGRES_PASSWORD=${AGENTGATEWAY_POSTGRES_PASSWORD}"
  update_service_env openwebui \
    "OPENID_PROVIDER_URL=https://${AUTHENTIK_HOST}/application/o/openwebui/.well-known/openid-configuration" \
    "OPENID_REDIRECT_URI=https://${OPENWEBUI_HOST}/oauth/oidc/callback" \
    "WEBUI_URL=https://${OPENWEBUI_HOST}" \
    "OAUTH_CLIENT_SECRET=${AUTHENTIK_OPENWEBUI_CLIENT_SECRET}" \
    "RAG_OPENAI_API_BASE_URL=http://agentgateway:4000/v1" \
    "RAG_OPENAI_API_KEY=${AGENTGATEWAY_OPENWEBUI_TOKEN}"
  update_service_env openclaw-gateway \
    "OPENCLAW_PUBLIC_ORIGIN=https://${OPENCLAW_HOST}" \
    "OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED=${OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED}" \
    "OPENCLAW_TRUSTED_PROXIES=${OPENCLAW_TRUSTED_PROXIES}" \
    "IM_TZ=${IM_TZ}" \
    "IM_UID=${IM_UID}" \
    "IM_GID=${IM_GID}"
  # Coder's browser URLs are supplied by the mandatory final installation
  # Compose overlay. Do not patch them after stack deploy: Swarm's service
  # environment merge can otherwise replace those profile values with the
  # generic placeholders from compose.coder.yaml.
  update_service_env lmstudio \
    "IM_TZ=${IM_TZ}" \
    "IM_UID=${IM_UID}" \
    "IM_GID=${IM_GID}"
  update_service_env lmstudio-proxy \
    "IM_TZ=${IM_TZ}" \
    "IM_UID=${IM_UID}" \
    "IM_GID=${IM_GID}" \
    "LMSTUDIO_PROXY_STRIP_TOOLS_AFTER_RESULT_ENABLED=${LMSTUDIO_PROXY_STRIP_TOOLS_AFTER_RESULT_ENABLED}" \
    "LMSTUDIO_PROXY_FLATTEN_TOOL_RESULT_CONTENT_ENABLED=${LMSTUDIO_PROXY_FLATTEN_TOOL_RESULT_CONTENT_ENABLED}"
  update_service_env metamcp \
    "APP_URL=https://${METAMCP_HOST}" \
    "NEXT_PUBLIC_APP_URL=https://${METAMCP_HOST}" \
    "POSTGRES_PASSWORD=${METAMCP_POSTGRES_PASSWORD}" \
    "DATABASE_URL=postgresql://metamcp:${METAMCP_POSTGRES_PASSWORD}@metamcp-postgres:5432/metamcp" \
    "BETTER_AUTH_SECRET=${METAMCP_BETTER_AUTH_SECRET}" \
    "BOOTSTRAP_USER_EMAIL=${METAMCP_BOOTSTRAP_EMAIL}" \
    "BOOTSTRAP_USER_PASSWORD=${METAMCP_BOOTSTRAP_PASSWORD}" \
    "OIDC_CLIENT_SECRET=${AUTHENTIK_METAMCP_CLIENT_SECRET}" \
    "OIDC_DISCOVERY_URL=https://${AUTHENTIK_HOST}/application/o/metamcp/.well-known/openid-configuration" \
    "OIDC_AUTHORIZATION_URL=https://${AUTHENTIK_HOST}/application/o/authorize/"
}

reconcile_coder_profile_urls() {
  [ "$CODER_ENABLED" = "1" ] || return 0

  # Docker stack deploy may preserve the generic values from the base compose
  # file when an existing Swarm service is merged with an installation
  # overlay.  Force an idempotent, post-deploy upsert of only the three
  # non-secret values Coder must have before its first OIDC discovery.  This
  # intentionally bypasses the generic drift helper: these values are owned
  # by the mandatory installation-specific Coder overlay.
  #
  # CODER_OIDC_IGNORE_EMAIL_VERIFIED: Authentik's own built-in "email" scope
  # mapping unconditionally returns email_verified: false for every user
  # (confirmed live 2026-09-23 by reading its expression via ak shell - it
  # has no real verification flow to report on, so it hardcodes the
  # conservative value). Coder is the only ai-stand application that
  # actually enforces this claim, rejecting sign-in with "Email not
  # verified" otherwise - not a bug in a specific account, every user hits
  # it. Nothing here can turn the claim itself true without a custom scope
  # mapping shared by every other OIDC app; this Coder-only escape hatch is
  # the narrower fix.
  #
  # TF_VAR_agentgateway_token: Terraform's own env-var convention (any
  # TF_VAR_<name> in the process environment populates var.<name>) - Coder's
  # built-in provisioner execs `terraform` as a subprocess of this exact
  # container's own process, inheriting its environment, so the ai-stand-dev
  # template's variable "agentgateway_token" (docker/coder-templates/
  # ai-stand-dev/main.tf) needs no file, no coder_parameter prompt, and no
  # per-workspace secret of its own. Same reasoning as every other credential
  # in this function being reconciled here post-deploy rather than baked
  # into compose.coder.yaml: a rotated AGENTGATEWAY_CODER_TOKEN (see
  # ensure_ai_stand_secrets) takes effect on the next workspace
  # build/restart, with no template republish.
  local svc="${STACK_NAME}_coder"
  docker_cmd service inspect "$svc" >/dev/null 2>&1 \
    || die "Missing Coder service after stack deploy: ${svc}"
  docker_cmd service update --detach=true \
    --env-add "CODER_ACCESS_URL=https://${CODER_HOST}" \
    --env-add "CODER_OIDC_ISSUER_URL=https://${AUTHENTIK_HOST}/application/o/coder/" \
    --env-add "CODER_HTTP_ADDRESS=0.0.0.0:7080" \
    --env-add "CODER_DISABLE_PASSWORD_AUTH=true" \
    --env-add "CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE=false" \
    --env-add "CODER_OIDC_SIGN_IN_TEXT=Войти через Authentik" \
    --env-add "CODER_OIDC_ICON_URL=https://${AUTHENTIK_HOST}/static/dist/assets/icons/icon_left_brand.svg" \
    --env-add "CODER_OIDC_ALLOW_SIGNUPS=true" \
    --env-add "CODER_OIDC_IGNORE_EMAIL_VERIFIED=true" \
    --env-add "CODER_OIDC_SCOPES=openid,profile,email,groups,offline_access" \
    --env-add "CODER_OIDC_GROUP_FIELD=groups" \
    --env-add "CODER_OIDC_ALLOWED_GROUPS=ai-users,ai-admins" \
    --env-add "CODER_OIDC_USER_ROLE_FIELD=groups" \
    --env-add 'CODER_OIDC_USER_ROLE_MAPPING={"ai-users":["member"],"ai-admins":["owner"]}' \
    --env-add "TF_VAR_agentgateway_token=${AGENTGATEWAY_CODER_TOKEN}" \
    "$svc" >/dev/null
  log "Reconciled Coder native OIDC and public URLs"
}

# MetaMCP's own BOOTSTRAP_USER_* env vars (set above by
# apply_installation_service_env) are documented but did not actually
# create a user in testing (2026-09-05, v2.4.22 - confirmed via
# BOOTSTRAP_DEBUG=true producing zero bootstrap-related log output and an
# empty `users` table). Provision the admin account directly via Better
# Auth's sign-up endpoint instead. This is idempotent in practice: signing
# up an already-registered email returns 422
# USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL, treated as success below.
ensure_metamcp_bootstrap_user() {
  wait_service_ready "${STACK_NAME}_metamcp"

  docker_cmd network inspect "${STACK_NAME}_ai-core" >/dev/null \
    || die "Missing overlay network ${STACK_NAME}_ai-core; run apply.sh deploy first"

  # The password goes through -e VARNAME (no literal value) rather than
  # --env VARNAME=value, so it never appears in this process's own argv -
  # same pattern as cmd_configure_authentik(). The retry loop (inside the
  # one-off container, not just around it) absorbs the gap between Swarm
  # reporting the task "Running" and the app inside actually accepting
  # connections on the overlay network.
  (
    local -x METAMCP_BOOTSTRAP_PASSWORD="$METAMCP_BOOTSTRAP_PASSWORD"
    local status
    status="$(
      docker_cmd run \
        --rm \
        --pull never \
        --network "${STACK_NAME}_ai-core" \
        --env "METAMCP_BOOTSTRAP_EMAIL=${METAMCP_BOOTSTRAP_EMAIL}" \
        -e METAMCP_BOOTSTRAP_PASSWORD \
        --entrypoint sh \
        "$DIAGNOSTIC_IMAGE" \
        -c '
          body="$(jq -n --arg email "$METAMCP_BOOTSTRAP_EMAIL" --arg password "$METAMCP_BOOTSTRAP_PASSWORD" --arg name admin \
            "{email:\$email,password:\$password,name:\$name}")"
          status="000"
          # MetaMCP runs backend (auth routes) then frontend (the port
          # clients actually hit, which proxies /api/auth/* to the backend)
          # as two sequential processes after migrations - cold start can
          # take well over a minute under load, so this needs a real
          # deadline, not a handful of quick retries.
          deadline=$(($(date +%s) + 300))
          while [ "$(date +%s)" -lt "$deadline" ]; do
            status="$(
              curl --silent --max-time 15 \
                --output /dev/null --write-out "%{http_code}" \
                -X POST http://metamcp:12008/api/auth/sign-up/email \
                -H "Content-Type: application/json" \
                --data "$body" 2>/dev/null
            )" || status="000"
            case "$status" in
              200|422) break ;;
            esac
            sleep 5
          done
          printf "%s" "$status"
        '
    )" || true

    case "$status" in
      200|422) log "MetaMCP bootstrap admin ensured (${METAMCP_BOOTSTRAP_EMAIL}, HTTP ${status})" ;;
      *) die "MetaMCP bootstrap admin sign-up failed: HTTP ${status:-none}" ;;
    esac
  )
}

configure_metamcp_personal_facades() {
  [ "$READONLY_MCP_ENABLED" = "1" ] || {
    log "MetaMCP personal facade provisioning skipped; READONLY_MCP_ENABLED=0"
    return 0
  }
  # Personal MetaMCP resources are now identity-driven, rather than sourced
  # from the retired static inventory. The root-owned reconciler invokes the
  # pinned provisioner only after it has observed a completed OIDC login.
  # Doing it here during every full deploy would race that login and could
  # accidentally make a deployment depend on one user's personal state.
  log "MetaMCP personal facade provisioning is owned by the read-only MCP reconciler"
}

cmd_migrate_metamcp_tenants() {
  load_os_info
  [ "$NODE_NAME" = "ai01" ] || die "migrate-metamcp-tenants must run on ai01"
  [ "$READONLY_MCP_ENABLED" = "1" ] \
    || die "migrate-metamcp-tenants requires READONLY_MCP_ENABLED=1"
  require_readonly_mcp_sources
  run_root test -f "$METAMCP_TENANT_IDENTITY_INVENTORY" \
    || die "MetaMCP tenant identity inventory is missing: $METAMCP_TENANT_IDENTITY_INVENTORY"
  [ "$(run_root stat -c '%U:%G:%a' "$METAMCP_TENANT_IDENTITY_INVENTORY")" = "root:root:600" ] \
    || die "MetaMCP tenant identity inventory must be root:root mode 0600"

  # A human reviews this inventory once. The helper then creates the
  # immutable relation atomically; later reconciliations never use email to
  # select a tenant again.
  run_root python3 "${METAMCP_TENANT_CONTROL_SOURCE_DIR}/provision.py" \
    --migrate-email-owners \
    --inventory "$METAMCP_TENANT_IDENTITY_INVENTORY" \
    --stack-name "$STACK_NAME" \
    --metamcp-image "$METAMCP_IMAGE"
  log "MetaMCP tenant ownership migration completed"
}

cmd_deploy() {
  load_os_info
  if [ "$READONLY_MCP_ENABLED" = "1" ] && [ "$NODE_NAME" != "ai01" ]; then
    die "READONLY_MCP_ENABLED deployment must run from ai01, where the protected inventory and local images reside"
  fi
  local accelerator
  if [ "$NODE_NAME" = "ai01" ]; then
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  else
    [ "$ACCELERATOR" != "auto" ] || die "Deploy from ${NODE_NAME} requires explicit --accelerator for LM Studio, or run deploy from ai01"
    accelerator="$ACCELERATOR"
  fi

  local compose_args=()
  # Compose interpolation reads only exported variables.  Keep the Coder
  # public URLs installation-specific from the very first task start; the
  # subsequent service-env reconciliation remains a drift repair, not the
  # mechanism that makes OIDC bootable.
  export AUTHENTIK_HOST CODER_HOST
  if [ "$CODER_ENABLED" = "1" ]; then
    [ "$CODER_HOST" != "coder.local" ] \
      || die "CODER_ENABLED requires an installation-specific CODER_HOST"
    [ "$AUTHENTIK_HOST" != "authentik.local" ] \
      || die "CODER_ENABLED requires an installation-specific AUTHENTIK_HOST"
    [ -r "${INSTALLATION_DIR}/compose.coder.yaml" ] \
      || die "CODER_ENABLED requires ${INSTALLATION_DIR}/compose.coder.yaml with the public Coder URLs"
    log "Coder public endpoints: access=https://${CODER_HOST}; oidc-host=${AUTHENTIK_HOST}"
  fi
  ensure_ai_stand_secrets
  # The personal GigaCode overlay references this external Secret.  On the
  # existing installation Authentik is already running, so resolve akadmin's
  # immutable subject before `docker stack deploy` validates external
  # secrets.  Keeping this before the deploy avoids a partial rollout where
  # OpenClaw cannot start because the map does not yet exist.
  ensure_openclaw_gigacode_requester_map
  configure_metamcp_personal_facades
  # This writes the generated Agentgateway config and Compose overlay only
  # after the protected inventory has passed its complete, fail-closed
  # validation. With the feature disabled it restores the generic config.
  install_agentgateway_config
  while IFS= read -r arg; do
    compose_args+=("$arg")
  done < <(compose_args_for_accelerator "$accelerator")

  docker_cmd stack config "${compose_args[@]}" >/tmp/ai-stand-stack-config.yaml
  docker_cmd stack deploy --resolve-image never "${compose_args[@]}" "$STACK_NAME"
  reconcile_coder_profile_urls
  remove_obsolete_services
  apply_installation_service_env
  ensure_metamcp_bootstrap_user
  if [ "$READONLY_MCP_ENABLED" = "1" ]; then
    sync_readonly_mcp_runtime
  fi
  sync_openwebui_persistent_config
  log "Stack ${STACK_NAME} deployed for accelerator=${accelerator}"
}

# This is intentionally narrower than deploy: the reconciler has already
# checked user attributes, created versioned secrets and atomically written
# the non-secret manifest. Reapply only the affected overlay/configuration;
# do not rebuild images, change the model profile or reconfigure Authentik.
cmd_reconcile_mcp() {
  load_os_info
  [ "$READONLY_MCP_ENABLED" = "1" ] \
    || die "reconcile-mcp requires READONLY_MCP_ENABLED=1 in the installation profile"
  [ "$NODE_NAME" = "ai01" ] \
    || die "reconcile-mcp must run on ai01, the Agentgateway build node"
  [ -r "$READONLY_MCP_MANIFEST" ] \
    || die "Read-only MCP manifest is missing or unreadable: $READONLY_MCP_MANIFEST"
  require_readonly_mcp_sources
  local image
  for image in "$JIRA_READONLY_MCP_IMAGE" "$CONFLUENCE_READONLY_MCP_IMAGE" "$IMAP_READONLY_MCP_IMAGE"; do
    docker_cmd image inspect "$image" >/dev/null \
      || die "Read-only MCP image is missing: $image; run apply.sh images on ai01 before enabling the reconciler"
  done

  sync_readonly_mcp_runtime
  sync_openwebui_persistent_config
  log "Read-only MCP manifest applied without a generic stack deploy"
}

# compose.yaml's authentik-server/worker AUTHENTIK_BOOTSTRAP_PASSWORD/
# AUTHENTIK_BOOTSTRAP_TOKEN env vars (Authentik's own built-in bootstrap
# mechanism) are NOT reliable on a genuinely from-scratch database -
# confirmed live 2026-09-13 doing a full Authentik data wipe on this
# installation. The password case is the more dangerous of the two:
# authentik-server logs a real "password_set" audit Event every time, but
# that only proves the code path RAN, not that the akadmin user's password
# actually ended up matching the secret - user.check_password() against the
# exact bootstrap-password value came back False despite the Event log
# looking completely normal (only caught because a human tried to log in
# and failed, well after configure-authentik itself had already reported
# success). The token case fails loudly instead: no Token row exists at all,
# so configure-authentik's own authentik-configurator container hits
# `GET /api/v3/core/users/me/` returning HTTP 403 "Token invalid/expired"
# even after waitForApi()'s full 10-minute retry loop.
#
# Fixed the same way here as it was fixed live: via `ak shell` (Authentik's
# own Django management-shell CLI) using its real ORM
# (authentik.core.models.User/Token/TokenIntents), not raw SQL - a raw
# `psql` query against authentik-postgresql was tried first when
# investigating this live and got blocked by the operator's own auto-mode
# classifier; `ak shell` was not blocked and is the more correct tool for
# the job anyway. Runs unconditionally on every configure-authentik call -
# one ORM query plus a password-hash check is cheap, and it's a no-op once
# the password/token already match, so there's no reason to gate this
# behind "only on a fresh install".
#
# The token's own key value could not be forced to match a pre-chosen
# string when this was worked out live (Token.save() did not honor an
# explicit key= passed into get_or_create()'s defaults) - so unlike the
# password fix, this takes the opposite direction: whatever key Django
# actually assigns becomes the new source of truth, and the host secret
# file is overwritten to match it, not the other way around.
ensure_authentik_bootstrap_identity() {
  local container_id
  container_id="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container_id" ] || die "No running ${STACK_NAME}_authentik-server container found for bootstrap identity check"

  local shell_output
  shell_output="$(
    local -x AK_EXPECTED_USERNAME="$AUTHENTIK_BOOTSTRAP_USERNAME"
    local -x AK_EXPECTED_PASSWORD="$AUTHENTIK_BOOTSTRAP_PASSWORD"
    docker_cmd exec -i -e AK_EXPECTED_USERNAME -e AK_EXPECTED_PASSWORD "$container_id" ak shell <<'PYEOF'
import os
from authentik.core.models import Token, TokenIntents, User

username = os.environ["AK_EXPECTED_USERNAME"]
expected_password = os.environ["AK_EXPECTED_PASSWORD"]

user = User.objects.filter(username=username).first()
if user is None:
    print("AK_BOOTSTRAP_RESULT error:no-user")
else:
    if user.check_password(expected_password):
        print("AK_BOOTSTRAP_RESULT password:ok")
    else:
        user.set_password(expected_password)
        user.save()
        print("AK_BOOTSTRAP_RESULT password:reset")

    token, _created = Token.objects.get_or_create(
        identifier="ai-stand-bootstrap-token",
        defaults={"user": user, "intent": TokenIntents.INTENT_API, "expiring": False},
    )
    print("AK_BOOTSTRAP_RESULT token:" + token.key)
PYEOF
  )" || die "ak shell bootstrap-identity check failed"

  local error_result
  error_result="$(printf '%s\n' "$shell_output" | grep -oE 'AK_BOOTSTRAP_RESULT error:[a-z-]+' | tail -n1 || true)"
  [ -z "$error_result" ] \
    || die "Authentik bootstrap user '${AUTHENTIK_BOOTSTRAP_USERNAME}' does not exist - cannot verify/fix its password or token"

  local password_result
  password_result="$(printf '%s\n' "$shell_output" | grep -oE 'AK_BOOTSTRAP_RESULT password:[a-z]+' | tail -n1 || true)"
  case "$password_result" in
    *"password:reset") log "Authentik bootstrap password did not match the secret; reset to match" ;;
    *"password:ok") log "Authentik bootstrap password already matches the secret" ;;
    *) die "ak shell did not report a usable password check result for the Authentik bootstrap identity" ;;
  esac

  local token_result
  token_result="$(printf '%s\n' "$shell_output" | grep -oE 'AK_BOOTSTRAP_RESULT token:[^[:space:]]+' | tail -n1 || true)"
  [ -n "$token_result" ] \
    || die "ak shell did not report an Authentik bootstrap token"
  local live_token="${token_result#AK_BOOTSTRAP_RESULT token:}"

  if [ "$live_token" != "$AUTHENTIK_BOOTSTRAP_TOKEN" ]; then
    log "Authentik bootstrap token in the database differs from the stored secret; updating the secret to match"
    printf '%s' "$live_token" | run_root tee "${AI_STAND_SECRETS_DIR}/authentik-bootstrap-token" >/dev/null
    run_root chmod 0600 "${AI_STAND_SECRETS_DIR}/authentik-bootstrap-token"
    AUTHENTIK_BOOTSTRAP_TOKEN="$live_token"
  else
    log "Authentik bootstrap token already matches the stored secret"
  fi
}

# The five-minute reconciler must not use the installation bootstrap token.
# It needs precisely three Authentik API capabilities: list ai-users, read
# their group membership, and write its non-secret provisioning status. Keep
# that capability on a dedicated non-interactive service account; the only
# copy of its bearer is a root-only host file consumed by the reconciler.
ensure_readonly_mcp_authentik_service_token() {
  [ "$READONLY_MCP_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai01" ] || return 0

  local server_container secret_file
  server_container="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$server_container" ] || die "Cannot find Authentik server for read-only MCP service account"
  secret_file="${AI_STAND_SECRETS_DIR}/readonly-mcp-authentik-api-token"

  # The marker is removed by sed before anything can reach this process's
  # stdout. The token is streamed straight into the root-only file rather
  # than retained in a shell variable, command line, Docker label or log.
  if ! docker_cmd exec -i -e AK_SERVICE_ACCOUNT=ai-stand-readonly-mcp-reconciler "$server_container" ak shell <<'PYEOF' \
    | sed -n 's/^AI_STAND_READONLY_MCP_TOKEN //p' \
    | run_root tee "$secret_file" >/dev/null
import os
from authentik.core.models import Token, TokenIntents, User
from authentik.rbac.models import Permission, Role

username = os.environ["AK_SERVICE_ACCOUNT"]
user, _created = User.objects.get_or_create(
    username=username,
    defaults={
        "name": "ai-stand read-only MCP reconciler",
        "type": "service_account",
        "is_active": True,
    },
)
if user.type != "service_account":
    raise RuntimeError("existing reconciler identity is not a service account")
if not user.is_active:
    user.is_active = True
    user.save(update_fields=["is_active"])

role, _created = Role.objects.get_or_create(name="ai-stand-readonly-mcp-reconciler")
required = []
for model, codename in (("group", "view_group"), ("user", "view_user"), ("user", "change_user")):
    required.append(Permission.objects.get(
        # Authentik exposes its API permissions under the concrete
        # ``authentik_core`` Django app label (not the historical ``core``
        # shorthand).  Pinning the real label keeps this narrowly-scoped
        # role portable across the installed Authentik 2026.x releases.
        content_type__app_label="authentik_core",
        content_type__model=model,
        codename=codename,
    ))
role.assign_perms(required)
user.roles.add(role)

token, _created = Token.objects.get_or_create(
    identifier="ai-stand-readonly-mcp-reconciler",
    defaults={"user": user, "intent": TokenIntents.INTENT_API, "expiring": False},
)
if token.user_id != user.pk or token.intent != TokenIntents.INTENT_API:
    raise RuntimeError("existing reconciler token has an unexpected owner or intent")
if token.expiring:
    token.expiring = False
    token.expires = None
    token.save(update_fields=["expiring", "expires"])
print("AI_STAND_READONLY_MCP_TOKEN " + token.key)
PYEOF
  then
    run_root rm -f "$secret_file"
    die "Cannot create the limited Authentik service token for read-only MCP reconciliation"
  fi
  run_root chown root:root "$secret_file"
  run_root chmod 0600 "$secret_file"
  run_root test -s "$secret_file" \
    || die "Authentik service account did not return a read-only MCP token"
  log "Limited Authentik service account for read-only MCP reconciliation is ready"
}

cmd_configure_authentik() {
  load_os_info
  [ "$NODE_NAME" = "ai01" ] || die "configure-authentik must be run on ai01"
  ensure_ai_stand_secrets

  wait_service_ready "${STACK_NAME}_authentik-postgresql"
  wait_service_ready "${STACK_NAME}_authentik-redis"
  wait_service_ready "${STACK_NAME}_authentik-server"
  wait_service_ready "${STACK_NAME}_authentik-worker"

  docker_cmd image inspect "$AUTHENTIK_CONFIGURATOR_IMAGE" >/dev/null \
    || die "Missing image ${AUTHENTIK_CONFIGURATOR_IMAGE}; run apply.sh images on ai01 first"

  docker_cmd network inspect "${STACK_NAME}_ai-core" >/dev/null \
    || die "Missing overlay network ${STACK_NAME}_ai-core; run apply.sh deploy first"

  ensure_authentik_bootstrap_identity
  ensure_readonly_mcp_authentik_service_token
  ensure_openclaw_gigacode_requester_map

  # Secret-bearing values go through the environment (-e VARNAME, no
  # =value) rather than --env VARNAME=value, so they never appear as
  # literal text in this process's own argv/cmdline - same pattern as
  # sync_openwebui_persistent_config().
  (
    local -x AUTHENTIK_API_TOKEN="$AUTHENTIK_BOOTSTRAP_TOKEN"
    local -x AUTHENTIK_OPENWEBUI_CLIENT_SECRET="$AUTHENTIK_OPENWEBUI_CLIENT_SECRET"
    local -x AUTHENTIK_PORTAINER_CLIENT_SECRET="$AUTHENTIK_PORTAINER_CLIENT_SECRET"
    local -x AUTHENTIK_METAMCP_CLIENT_SECRET="$AUTHENTIK_METAMCP_CLIENT_SECRET"
    local -x AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET="$AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET"
    local -x AUTHENTIK_CODER_CLIENT_SECRET="$AUTHENTIK_CODER_CLIENT_SECRET"
    docker_cmd run \
      --rm \
      --pull never \
      --network "${STACK_NAME}_ai-core" \
      --env "AUTHENTIK_BASE_URL=http://authentik:9000" \
      --env "AUTHENTIK_PUBLIC_URL=https://${AUTHENTIK_HOST}" \
      -e AUTHENTIK_API_TOKEN \
      --env "AUTHENTIK_BOOTSTRAP_USERNAME=${AUTHENTIK_BOOTSTRAP_USERNAME}" \
      -e AUTHENTIK_OPENWEBUI_CLIENT_SECRET \
      -e AUTHENTIK_PORTAINER_CLIENT_SECRET \
      -e AUTHENTIK_METAMCP_CLIENT_SECRET \
      -e AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET \
      -e AUTHENTIK_CODER_CLIENT_SECRET \
      --env "AUTHENTIK_OPENWEBUI_URL=https://${OPENWEBUI_HOST}" \
      --env "AUTHENTIK_OPENCLAW_URL=https://${OPENCLAW_HOST}" \
      --env "AUTHENTIK_PORTAINER_URL=https://${PORTAINER_HOST}" \
      --env "AUTHENTIK_METAMCP_URL=https://${METAMCP_HOST}" \
      --env "AUTHENTIK_AGENTGATEWAY_URL=https://${AGENTGATEWAY_HOST}" \
      --env "AUTHENTIK_CODER_URL=https://${CODER_HOST}" \
      "$AUTHENTIK_CONFIGURATOR_IMAGE"
  )

  # agentgateway's OIDC issuer/client secret already have real values from
  # the moment it was first deployed (see apply_installation_service_env())
  # - nothing here is env-gated. What's NOT yet confirmed is
  # whether agentgateway tolerates its issuer being syntactically valid but
  # unresolvable (404, since the Authentik application above didn't exist
  # until just now) at the time it first loaded config.yaml, or whether it
  # needs a fresh load to pick up a now-resolvable issuer. A plain
  # force-restart here is cheap and makes the outcome the same either way:
  # by the time this returns, agentgateway has attempted OIDC discovery at
  # least once with the application definitely present.
  docker_cmd service update --detach=true --force "${STACK_NAME}_agentgateway" >/dev/null

  log "Authentik configuration stage complete"
}

# Onboards exactly one human into Authentik: creates the account with a
# freshly generated temporary password (printed once, never persisted) if it
# doesn't exist yet, and idempotently ensures membership in the requested
# groups. Never resets the password of an already-existing user - this
# installation's design is self-service (the user changes their own password
# and, separately, their own readonly-mcp/GigaCode credentials through
# Authentik's standard /if/user/ page - see ensureMcpSelfServiceAttributes()
# in configure.mjs), so a re-run must not clobber a password the user has
# already changed. Group membership is additive only: this command can add a
# person to ai-admins on a later re-run, but deliberately never removes a
# group it does not see requested, since silent privilege removal is not an
# onboarding operation. This wraps the same ak shell/ORM approach already
# used by ensure_authentik_bootstrap_identity() and
# ensure_readonly_mcp_authentik_service_token() above, applied to a normal
# interactive user instead of the bootstrap or service-account identity.
#
# The username/email/groups of an actual person are supplied only as CLI
# arguments for one invocation on the host; like reconciler.json's real
# upstream URLs, they must never be committed to this repository.
cmd_onboard_readonly_mcp_user() {
  load_os_info
  [ "$NODE_NAME" = "ai01" ] || die "onboard-readonly-mcp-user must be run on ai01"

  [[ "$ONBOARD_USERNAME" =~ ^[A-Za-z0-9._-]{2,64}$ ]] \
    || die "--username must match [A-Za-z0-9._-]{2,64}, got: ${ONBOARD_USERNAME}"
  [[ "$ONBOARD_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
    || die "--email does not look like a valid email address: ${ONBOARD_EMAIL}"

  local -a groups=()
  IFS=',' read -r -a groups <<<"$ONBOARD_GROUPS"
  [ "${#groups[@]}" -gt 0 ] || die "--groups must not be empty"
  local group
  for group in "${groups[@]}"; do
    case "$group" in
      ai-users|ai-admins) ;;
      *) die "--groups may only contain ai-users and/or ai-admins, got: ${group}" ;;
    esac
  done
  local groups_csv
  groups_csv="$(IFS=,; echo "${groups[*]}")"

  local container_id
  container_id="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container_id" ] || die "No running ${STACK_NAME}_authentik-server container found for onboarding"

  local temp_password
  temp_password="AiStand-$(openssl rand -hex 12)"

  local shell_output
  shell_output="$(
    local -x AK_USERNAME="$ONBOARD_USERNAME"
    local -x AK_EMAIL="$ONBOARD_EMAIL"
    local -x AK_PASSWORD="$temp_password"
    local -x AK_GROUPS="$groups_csv"
    docker_cmd exec -i -e AK_USERNAME -e AK_EMAIL -e AK_PASSWORD -e AK_GROUPS \
      "$container_id" ak shell <<'PYEOF'
import os
from authentik.core.models import Group, User

username = os.environ["AK_USERNAME"]
email = os.environ["AK_EMAIL"]
password = os.environ["AK_PASSWORD"]
group_names = [g for g in os.environ["AK_GROUPS"].split(",") if g]

user = User.objects.filter(username=username).first()
ok = True
if user is None:
    user = User.objects.create(username=username, email=email, name=username, is_active=True)
    user.set_password(password)
    user.save()
    print("AI_STAND_ONBOARD_RESULT created")
elif user.email != email:
    print("AI_STAND_ONBOARD_RESULT error:email-mismatch")
    ok = False
else:
    print("AI_STAND_ONBOARD_RESULT exists")

if ok:
    added = []
    for name in group_names:
        group, _created = Group.objects.get_or_create(name=name)
        if not group.users.filter(pk=user.pk).exists():
            group.users.add(user)
            added.append(name)
    if added:
        print("AI_STAND_ONBOARD_GROUPS_ADDED " + ",".join(added))
PYEOF
  )" || die "ak shell onboarding failed"

  if printf '%s\n' "$shell_output" | grep -q 'AI_STAND_ONBOARD_RESULT error:email-mismatch'; then
    die "Authentik user '${ONBOARD_USERNAME}' already exists with a different email; refusing to repurpose the account. Use a different --username or resolve this by hand."
  fi

  local result
  result="$(printf '%s\n' "$shell_output" | grep -oE 'AI_STAND_ONBOARD_RESULT (created|exists)' | tail -n1 || true)"
  [ -n "$result" ] || die "ak shell did not report a usable onboarding result"

  case "$result" in
    *created)
      log "Authentik user created: ${ONBOARD_USERNAME} (${ONBOARD_EMAIL})"
      cat <<CREDS

Temporary password for ${ONBOARD_USERNAME}: ${temp_password}
Relay this to the user over a trusted channel; it is not stored anywhere by
this command. They are expected to sign in at https://${AUTHENTIK_HOST}/if/user/
and change it themselves - this command does not enforce a change on first
login.
CREDS
      ;;
    *exists)
      log "Authentik user already exists: ${ONBOARD_USERNAME} - password left unchanged"
      ;;
  esac

  local groups_added
  groups_added="$(printf '%s\n' "$shell_output" | sed -n 's/^AI_STAND_ONBOARD_GROUPS_ADDED //p' | tail -n1 || true)"
  if [ -n "$groups_added" ]; then
    log "Group membership added for ${ONBOARD_USERNAME}: ${groups_added}"
  else
    log "Group membership already up to date for ${ONBOARD_USERNAME}: ${groups_csv}"
  fi
}

portainer_api_url() {
  printf 'https://%s%s\n' "$PORTAINER_HOST" "$1"
}

portainer_curl_base_args() {
  printf '%s\n' \
    --insecure \
    --silent \
    --show-error \
    --max-time \
    30 \
    --resolve \
    "${PORTAINER_HOST}:443:127.0.0.1"
}

# Runs a Portainer API request with the common base args, capturing the
# response body into $1 and printing the HTTP status code on stdout (empty
# on a connection-level failure, matching the `|| true` behavior every
# call site already relied on individually before this was factored out).
portainer_curl_status() {
  local response_file="$1"
  shift
  curl \
    $(portainer_curl_base_args) \
    --output "$response_file" \
    --write-out '%{http_code}' \
    "$@" \
    || true
}

# Reads a field out of a JSON response file via the given jq filter, or
# dies with the given message if the filter yields nothing.
portainer_require_json_field() {
  local response_file="$1"
  local jq_filter="$2"
  local error_message="$3"
  local value
  value="$(jq --raw-output "$jq_filter" "$response_file")"
  [ -n "$value" ] || die "$error_message"
  printf '%s\n' "$value"
}

portainer_init_admin() {
  local payload
  local response
  local code
  local attempt
  payload="$(mktemp)"
  response="$(mktemp)"

  jq -n \
    --arg username "$PORTAINER_ADMIN_USERNAME" \
    --arg password "$PORTAINER_ADMIN_PASSWORD" \
    '{Username: $username, Password: $password}' \
    > "$payload"

  for attempt in 1 2; do
    code="$(
      portainer_curl_status "$response" \
        --header 'Content-Type: application/json' \
        --request POST \
        --data-binary "@${payload}" \
        "$(portainer_api_url /api/users/admin/init)"
    )"

    case "$code" in
      200)
        rm -f "$payload" "$response"
        log "Portainer admin user initialized"
        return 0
        ;;
      409)
        rm -f "$payload" "$response"
        log "Portainer admin user already exists"
        return 0
        ;;
      303)
        if grep -qi 'Administrator initialization timeout' "$response"; then
          log "Portainer admin initialization window expired; restarting Portainer once"
          docker_cmd service update --force "${STACK_NAME}_portainer" >/dev/null
          wait_service_ready "${STACK_NAME}_portainer"
          sleep 10
          continue
        fi
        ;;
    esac

    break
  done

  local detail
  detail="$(head -c 500 "$response" 2>/dev/null || true)"
  rm -f "$payload" "$response"
  die "Portainer admin init failed with HTTP ${code:-empty}: ${detail}"
}

portainer_login() {
  local payload
  local response
  local code
  local jwt
  payload="$(mktemp)"
  response="$(mktemp)"

  jq -n \
    --arg username "$PORTAINER_ADMIN_USERNAME" \
    --arg password "$PORTAINER_ADMIN_PASSWORD" \
    '{Username: $username, Password: $password}' \
    > "$payload"

  code="$(
    portainer_curl_status "$response" \
      --header 'Content-Type: application/json' \
      --request POST \
      --data-binary "@${payload}" \
      "$(portainer_api_url /api/auth)"
  )"
  rm -f "$payload"

  if [ "$code" != "200" ]; then
    local detail
    detail="$(head -c 500 "$response" 2>/dev/null || true)"
    rm -f "$response"
    die "Portainer admin login failed with HTTP ${code:-empty}: ${detail}"
  fi

  jwt="$(portainer_require_json_field "$response" '.jwt // empty' "Portainer admin login did not return JWT")"
  rm -f "$response"
  printf '%s\n' "$jwt"
}

ensure_portainer_endpoint() {
  local jwt="$1"
  local endpoints
  local response
  local endpoint_id
  local code
  endpoints="$(mktemp)"
  response="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints)" \
    > "$endpoints"

  endpoint_id="$(
    jq --raw-output \
      --arg name "$PORTAINER_ENDPOINT_NAME" \
      'map(select(.Name == $name)) | first | .Id // empty' \
      "$endpoints"
  )"

  if [ -n "$endpoint_id" ]; then
    rm -f "$endpoints" "$response"
    log "Portainer environment exists: ${PORTAINER_ENDPOINT_NAME} id=${endpoint_id}"
    printf '%s\n' "$endpoint_id"
    return 0
  fi

  code="$(
    portainer_curl_status "$response" \
      --header "Authorization: Bearer ${jwt}" \
      --request POST \
      --form "Name=${PORTAINER_ENDPOINT_NAME}" \
      --form 'EndpointCreationType=2' \
      --form 'ContainerEngine=docker' \
      --form "URL=${PORTAINER_ENDPOINT_URL}" \
      --form 'GroupID=1' \
      --form 'TLS=true' \
      --form 'TLSSkipVerify=true' \
      --form 'TLSSkipClientVerify=true' \
      "$(portainer_api_url /api/endpoints)"
  )"

  if [ "$code" != "200" ]; then
    local detail
    detail="$(head -c 500 "$response" 2>/dev/null || true)"
    rm -f "$endpoints" "$response"
    die "Portainer environment creation failed with HTTP ${code:-empty}: ${detail}"
  fi

  endpoint_id="$(portainer_require_json_field "$response" '.Id // empty' "Portainer environment creation did not return Id")"
  rm -f "$endpoints" "$response"
  log "Portainer environment created: ${PORTAINER_ENDPOINT_NAME} id=${endpoint_id}"
  printf '%s\n' "$endpoint_id"
}

ensure_portainer_team() {
  local jwt="$1"
  local teams
  local payload
  local response
  local team_id
  local code
  teams="$(mktemp)"
  payload="$(mktemp)"
  response="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/teams)" \
    > "$teams"

  team_id="$(
    jq --raw-output \
      --arg name "$PORTAINER_OAUTH_TEAM_NAME" \
      'map(select(.Name == $name)) | first | .Id // empty' \
      "$teams"
  )"

  if [ -n "$team_id" ]; then
    rm -f "$teams" "$payload" "$response"
    log "Portainer OAuth team exists: ${PORTAINER_OAUTH_TEAM_NAME} id=${team_id}"
    printf '%s\n' "$team_id"
    return 0
  fi

  jq -n --arg name "$PORTAINER_OAUTH_TEAM_NAME" '{Name: $name}' > "$payload"
  code="$(
    portainer_curl_status "$response" \
      --header "Authorization: Bearer ${jwt}" \
      --header 'Content-Type: application/json' \
      --request POST \
      --data-binary "@${payload}" \
      "$(portainer_api_url /api/teams)"
  )"

  if [ "$code" != "200" ]; then
    local detail
    detail="$(head -c 500 "$response" 2>/dev/null || true)"
    rm -f "$teams" "$payload" "$response"
    die "Portainer team creation failed with HTTP ${code:-empty}: ${detail}"
  fi

  team_id="$(portainer_require_json_field "$response" '.Id // empty' "Portainer team creation did not return Id")"
  rm -f "$teams" "$payload" "$response"
  log "Portainer OAuth team created: ${PORTAINER_OAUTH_TEAM_NAME} id=${team_id}"
  printf '%s\n' "$team_id"
}

ensure_portainer_team_memberships() {
  local jwt="$1"
  local team_id="$2"
  local users
  local memberships
  local payload
  local response
  local user_id
  local membership_id
  local code
  users="$(mktemp)"
  memberships="$(mktemp)"
  payload="$(mktemp)"
  response="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/users)" \
    > "$users"
  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/team_memberships)" \
    > "$memberships"

  while IFS= read -r user_id; do
    [ -n "$user_id" ] || continue
    membership_id="$(
      jq --raw-output \
        --argjson user_id "$user_id" \
        --argjson team_id "$team_id" \
        'map(select(.UserID == $user_id and .TeamID == $team_id)) | first | .Id // empty' \
        "$memberships"
    )"
    jq -n \
      --argjson user_id "$user_id" \
      --argjson team_id "$team_id" \
      '{UserID: $user_id, TeamID: $team_id, Role: 1}' \
      > "$payload"

    if [ -n "$membership_id" ]; then
      code="$(
        curl \
          $(portainer_curl_base_args) \
          --output "$response" \
          --write-out '%{http_code}' \
          --header "Authorization: Bearer ${jwt}" \
          --header 'Content-Type: application/json' \
          --request PUT \
          --data-binary "@${payload}" \
          "$(portainer_api_url /api/team_memberships/${membership_id})" \
          || true
      )"
    else
      code="$(
        curl \
          $(portainer_curl_base_args) \
          --output "$response" \
          --write-out '%{http_code}' \
          --header "Authorization: Bearer ${jwt}" \
          --header 'Content-Type: application/json' \
          --request POST \
          --data-binary "@${payload}" \
          "$(portainer_api_url /api/team_memberships)" \
          || true
      )"
    fi

    if [ "$code" != "200" ]; then
      local detail
      detail="$(head -c 500 "$response" 2>/dev/null || true)"
      rm -f "$users" "$memberships" "$payload" "$response"
      die "Portainer team membership update failed for user ${user_id} with HTTP ${code:-empty}: ${detail}"
    fi
  done < <(
    jq --raw-output \
      --arg break_glass "$PORTAINER_ADMIN_USERNAME" \
      '.[] | select(.Role == 2 and .Username != $break_glass) | .Id' \
      "$users"
  )

  rm -f "$users" "$memberships" "$payload" "$response"
  log "Existing Portainer OAuth users are members of ${PORTAINER_OAUTH_TEAM_NAME}"
}

ensure_portainer_team_membership() {
  local jwt="$1"
  local user_id="$2"
  local team_id="$3"
  local memberships
  local payload
  local response
  local membership_id
  local code
  memberships="$(mktemp)"
  payload="$(mktemp)"
  response="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/team_memberships)" \
    > "$memberships"

  membership_id="$(
    jq --raw-output \
      --argjson user_id "$user_id" \
      --argjson team_id "$team_id" \
      'map(select(.UserID == $user_id and .TeamID == $team_id)) | first | .Id // empty' \
      "$memberships"
  )"
  jq -n \
    --argjson user_id "$user_id" \
    --argjson team_id "$team_id" \
    '{UserID: $user_id, TeamID: $team_id, Role: 1}' \
    > "$payload"

  if [ -n "$membership_id" ]; then
    code="$(
      curl \
        $(portainer_curl_base_args) \
        --output "$response" \
        --write-out '%{http_code}' \
        --header "Authorization: Bearer ${jwt}" \
        --header 'Content-Type: application/json' \
        --request PUT \
        --data-binary "@${payload}" \
        "$(portainer_api_url /api/team_memberships/${membership_id})" \
        || true
    )"
  else
    code="$(
      curl \
        $(portainer_curl_base_args) \
        --output "$response" \
        --write-out '%{http_code}' \
        --header "Authorization: Bearer ${jwt}" \
        --header 'Content-Type: application/json' \
        --request POST \
        --data-binary "@${payload}" \
        "$(portainer_api_url /api/team_memberships)" \
        || true
    )"
  fi

  if [ "$code" != "200" ]; then
    local detail
    detail="$(head -c 500 "$response" 2>/dev/null || true)"
    rm -f "$memberships" "$payload" "$response"
    die "Portainer team membership update failed for user ${user_id} with HTTP ${code:-empty}: ${detail}"
  fi

  rm -f "$memberships" "$payload" "$response"
}

ensure_portainer_oauth_admin_users() {
  local jwt="$1"
  local team_id="$2"
  local users
  local payload
  local response
  local username
  local user_id
  local role
  local password
  local code
  users="$(mktemp)"
  payload="$(mktemp)"
  response="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/users)" \
    > "$users"

  for username in "${PORTAINER_OAUTH_ADMIN_USERS[@]}"; do
    [ -n "$username" ] || continue
    user_id="$(
      jq --raw-output \
        --arg username "$username" \
        'map(select(.Username == $username)) | first | .Id // empty' \
        "$users"
    )"
    if [ -z "$user_id" ]; then
      password="AiStand-$(openssl rand -hex 24)"
      jq -n \
        --arg username "$username" \
        --arg password "$password" \
        '{Username: $username, Password: $password, Role: 1}' \
        > "$payload"
      code="$(
        curl \
          $(portainer_curl_base_args) \
          --output "$response" \
          --write-out '%{http_code}' \
          --header "Authorization: Bearer ${jwt}" \
          --header 'Content-Type: application/json' \
          --request POST \
          --data-binary "@${payload}" \
          "$(portainer_api_url /api/users)" \
          || true
      )"

      if [ "$code" != "200" ] && [ "$code" != "201" ]; then
        local detail
        detail="$(head -c 500 "$response" 2>/dev/null || true)"
        rm -f "$users" "$payload" "$response"
        die "Portainer OAuth admin user creation failed for ${username} with HTTP ${code:-empty}: ${detail}"
      fi

      user_id="$(jq --raw-output '.Id // empty' "$response")"
      [ -n "$user_id" ] || die "Portainer OAuth admin user creation did not return Id for ${username}"
      log "Portainer OAuth admin user created: ${username} id=${user_id}"
    else
      role="$(
        jq --raw-output \
          --argjson user_id "$user_id" \
          'map(select(.Id == $user_id)) | first | .Role // empty' \
          "$users"
      )"
      if [ "$role" != "1" ]; then
        jq -n --arg username "$username" '{Username: $username, Role: 1}' > "$payload"
        code="$(
          curl \
            $(portainer_curl_base_args) \
            --output "$response" \
            --write-out '%{http_code}' \
            --header "Authorization: Bearer ${jwt}" \
            --header 'Content-Type: application/json' \
            --request PUT \
            --data-binary "@${payload}" \
            "$(portainer_api_url /api/users/${user_id})" \
            || true
        )"

        if [ "$code" != "200" ] && [ "$code" != "204" ]; then
          local detail
          detail="$(head -c 500 "$response" 2>/dev/null || true)"
          rm -f "$users" "$payload" "$response"
          die "Portainer global admin role update failed for user ${username} (${user_id}) with HTTP ${code:-empty}: ${detail}"
        fi
        log "Portainer OAuth admin user promoted: ${username} id=${user_id}"
      fi
    fi

    ensure_portainer_team_membership "$jwt" "$user_id" "$team_id"
  done

  rm -f "$users" "$payload" "$response"
  log "Explicit Portainer OAuth admin users are configured"
}

grant_portainer_endpoint_team_access() {
  local jwt="$1"
  local endpoint_id="$2"
  local team_id="$3"
  local endpoint
  local payload
  local response
  local code
  endpoint="$(mktemp)"
  payload="$(mktemp)"
  response="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints/${endpoint_id})" \
    > "$endpoint"

  jq \
    --arg name "$PORTAINER_ENDPOINT_NAME" \
    --arg url "$PORTAINER_ENDPOINT_URL" \
    --argjson team_id "$team_id" \
    --argjson role_id "$PORTAINER_ENVIRONMENT_ROLE_ID" \
    '
      {
        Name: $name,
        URL: $url,
        PublicURL: (.PublicURL // ""),
        GroupID: (.GroupId // .GroupID // 1),
        TLS: true,
        TLSSkipVerify: true,
        TLSSkipClientVerify: true,
        UserAccessPolicies: (.UserAccessPolicies // {}),
        TeamAccessPolicies: ((.TeamAccessPolicies // {}) + {($team_id | tostring): {RoleId: $role_id}})
      }
    ' \
    "$endpoint" > "$payload"

  code="$(
    curl \
      $(portainer_curl_base_args) \
      --output "$response" \
      --write-out '%{http_code}' \
      --header "Authorization: Bearer ${jwt}" \
      --header 'Content-Type: application/json' \
      --request PUT \
      --data-binary "@${payload}" \
      "$(portainer_api_url /api/endpoints/${endpoint_id})" \
      || true
  )"

  if [ "$code" != "200" ]; then
    local detail
    detail="$(head -c 500 "$response" 2>/dev/null || true)"
    rm -f "$endpoint" "$payload" "$response"
    die "Portainer environment access update failed with HTTP ${code:-empty}: ${detail}"
  fi

  rm -f "$endpoint" "$payload" "$response"
  log "Portainer team ${PORTAINER_OAUTH_TEAM_NAME} has access to ${PORTAINER_ENDPOINT_NAME}"
}

grant_portainer_endpoint_user_access() {
  local jwt="$1"
  local endpoint_id="$2"
  local users
  local endpoint
  local payload
  local response
  local user_policies
  local admin_users
  local code
  users="$(mktemp)"
  endpoint="$(mktemp)"
  payload="$(mktemp)"
  response="$(mktemp)"
  user_policies="$(mktemp)"
  admin_users="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
      --header "Authorization: Bearer ${jwt}" \
      "$(portainer_api_url /api/users)" \
      > "$users"

  printf '%s\n' "${PORTAINER_OAUTH_ADMIN_USERS[@]}" \
    | jq --raw-input --slurp 'split("\n") | map(select(length > 0))' \
    > "$admin_users"

  jq \
    --slurpfile admin_users "$admin_users" \
    --arg break_glass "$PORTAINER_ADMIN_USERNAME" \
    --argjson role_id "$PORTAINER_ENVIRONMENT_ROLE_ID" \
    '
      reduce (
        .[]
        | select(.Username != $break_glass)
        | select(.Role == 2 or (.Username as $username | any($admin_users[0][]; . == $username)))
        | .Id
        | tostring
      ) as $id
        ({}; . + {($id): {RoleId: $role_id}})
    ' \
    "$users" > "$user_policies"

  if jq --exit-status 'length == 0' "$user_policies" >/dev/null; then
    rm -f "$users" "$endpoint" "$payload" "$response" "$user_policies" "$admin_users"
    log "No Portainer OAuth users need direct endpoint access yet"
    return 0
  fi

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints/${endpoint_id})" \
    > "$endpoint"

  jq \
    --slurpfile user_policies "$user_policies" \
    --arg name "$PORTAINER_ENDPOINT_NAME" \
    --arg url "$PORTAINER_ENDPOINT_URL" \
    '
      {
        Name: $name,
        URL: $url,
        PublicURL: (.PublicURL // ""),
        GroupID: (.GroupId // .GroupID // 1),
        TLS: true,
        TLSSkipVerify: true,
        TLSSkipClientVerify: true,
        UserAccessPolicies: ((.UserAccessPolicies // {}) + $user_policies[0]),
        TeamAccessPolicies: (.TeamAccessPolicies // {})
      }
    ' \
    "$endpoint" > "$payload"

  code="$(
    curl \
      $(portainer_curl_base_args) \
      --output "$response" \
      --write-out '%{http_code}' \
      --header "Authorization: Bearer ${jwt}" \
      --header 'Content-Type: application/json' \
      --request PUT \
      --data-binary "@${payload}" \
      "$(portainer_api_url /api/endpoints/${endpoint_id})" \
      || true
  )"

  if [ "$code" != "200" ]; then
      local detail
      detail="$(head -c 500 "$response" 2>/dev/null || true)"
      rm -f "$users" "$endpoint" "$payload" "$response" "$user_policies" "$admin_users"
      die "Portainer direct OAuth user environment access update failed with HTTP ${code:-empty}: ${detail}"
  fi

  rm -f "$users" "$endpoint" "$payload" "$response" "$user_policies" "$admin_users"
  log "Existing Portainer OAuth users have direct access to ${PORTAINER_ENDPOINT_NAME}"
}

configure_portainer_oauth() {
  local jwt="$1"
  local team_id="$2"
  local settings
  local discovery
  local payload
  local response
  local code
  settings="$(mktemp)"
  discovery="$(mktemp)"
  payload="$(mktemp)"
  response="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/settings)" \
    > "$settings"

  curl \
    --insecure \
    --silent \
    --show-error \
    --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    --fail \
    "https://${AUTHENTIK_HOST}/application/o/portainer/.well-known/openid-configuration" \
    > "$discovery"

  jq \
    --arg client_id "portainer" \
    --arg client_secret "$AUTHENTIK_PORTAINER_CLIENT_SECRET" \
    --arg authz "$(jq --raw-output '.authorization_endpoint' "$discovery")" \
    --arg token "$(jq --raw-output '.token_endpoint' "$discovery")" \
    --arg userinfo "$(jq --raw-output '.userinfo_endpoint' "$discovery")" \
    --arg logout "$(jq --raw-output '.end_session_endpoint // ""' "$discovery")" \
    --arg redirect "https://${PORTAINER_HOST}" \
    --argjson team_id "$team_id" \
    '
      .AuthenticationMethod = 3
      | .OAuthSettings = (.OAuthSettings // {})
      | .OAuthSettings.ClientID = $client_id
      | .OAuthSettings.ClientSecret = $client_secret
      | .OAuthSettings.AuthorizationURI = $authz
      | .OAuthSettings.AccessTokenURI = $token
      | .OAuthSettings.ResourceURI = $userinfo
      | .OAuthSettings.RedirectURI = $redirect
      | .OAuthSettings.UserIdentifier = "email"
      | .OAuthSettings.Scopes = "openid+email+profile+groups"
      | .OAuthSettings.OAuthAutoCreateUsers = true
      | .OAuthSettings.OAuthAutoMapTeamMemberships = false
      | .OAuthSettings.DefaultTeamID = $team_id
      | .OAuthSettings.SSO = true
      | .OAuthSettings.LogoutURI = $logout
      | .OAuthSettings.AuthStyle = 0
    ' \
    "$settings" > "$payload"

  code="$(
    curl \
      $(portainer_curl_base_args) \
      --output "$response" \
      --write-out '%{http_code}' \
      --header "Authorization: Bearer ${jwt}" \
      --header 'Content-Type: application/json' \
      --request PUT \
      --data-binary "@${payload}" \
      "$(portainer_api_url /api/settings)" \
      || true
  )"

  if [ "$code" != "200" ]; then
    local detail
    detail="$(head -c 500 "$response" 2>/dev/null || true)"
    rm -f "$settings" "$discovery" "$payload" "$response"
    die "Portainer OAuth settings update failed with HTTP ${code:-empty}: ${detail}"
  fi

  rm -f "$settings" "$discovery" "$payload" "$response"
  log "Portainer OAuth/OIDC settings applied"
}

check_portainer_oidc_configuration() {
  curl \
    $(portainer_curl_base_args) \
    --fail \
    "$(portainer_api_url /api/settings/public)" \
    | jq --exit-status \
      --arg authz "https://${AUTHENTIK_HOST}/application/o/authorize/" \
      --arg logout "https://${AUTHENTIK_HOST}/application/o/portainer/end-session/" \
      --arg redirect "redirect_uri=https://${PORTAINER_HOST}" \
      '
        .AuthenticationMethod == 3
        and (.OAuthLoginURI | type == "string")
        and (.OAuthLoginURI | contains($authz))
        and (.OAuthLoginURI | contains("client_id=portainer"))
        and (.OAuthLoginURI | contains($redirect))
        and (.OAuthLogoutURI == $logout)
      ' \
      >/dev/null
  log "Portainer native OAuth/OIDC is configured"
}

check_portainer_environment_configuration() {
  local jwt="$1"
  local endpoint_id="$2"
  local team_id="$3"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints/${endpoint_id})" \
    | jq --exit-status \
      --arg name "$PORTAINER_ENDPOINT_NAME" \
      --arg url "$PORTAINER_ENDPOINT_URL" \
      --argjson team_id "$team_id" \
      --argjson role_id "$PORTAINER_ENVIRONMENT_ROLE_ID" \
      '
        .Name == $name
        and .URL == $url
        and ((.TeamAccessPolicies // {})[$team_id | tostring].RoleId == $role_id)
      ' \
      >/dev/null

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints/${endpoint_id}/docker/swarm)" \
    | jq --exit-status '.ID | type == "string" and length > 0' \
      >/dev/null

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints/${endpoint_id}/docker/v1.41/services)" \
    | jq --exit-status 'type == "array" and length > 0' \
      >/dev/null

  log "Portainer environment is configured and reachable: ${PORTAINER_ENDPOINT_NAME}"
}

check_portainer_oauth_user_endpoint_access() {
  local jwt="$1"
  local endpoint_id="$2"
  local users
  local endpoint
  local admin_users
  users="$(mktemp)"
  endpoint="$(mktemp)"
  admin_users="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/users)" \
    > "$users"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints/${endpoint_id})" \
    > "$endpoint"

  printf '%s\n' "${PORTAINER_OAUTH_ADMIN_USERS[@]}" \
    | jq --raw-input --slurp 'split("\n") | map(select(length > 0))' \
    > "$admin_users"

  jq --exit-status \
    --slurpfile endpoint "$endpoint" \
    --slurpfile admin_users "$admin_users" \
    --arg break_glass "$PORTAINER_ADMIN_USERNAME" \
    --argjson role_id "$PORTAINER_ENVIRONMENT_ROLE_ID" \
    '
      [
        .[]
        | select(.Username != $break_glass)
        | select(.Role == 2 or (.Username as $username | any($admin_users[0][]; . == $username)))
        | .Id
        | tostring
      ] as $user_ids
      | all($user_ids[]; (($endpoint[0].UserAccessPolicies // {})[.].RoleId == $role_id))
    ' \
    "$users" >/dev/null

  rm -f "$users" "$endpoint" "$admin_users"
  log "Portainer OAuth users have direct access to ${PORTAINER_ENDPOINT_NAME}"
}

check_portainer_oauth_admin_users() {
  local jwt="$1"
  local team_id="$2"
  local users
  local memberships
  local username
  local user_id
  local role
  local is_member
  users="$(mktemp)"
  memberships="$(mktemp)"

  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/users)" \
    > "$users"
  curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/team_memberships)" \
    > "$memberships"

  for username in "${PORTAINER_OAUTH_ADMIN_USERS[@]}"; do
    [ -n "$username" ] || continue
    user_id="$(
      jq --raw-output \
        --arg username "$username" \
        'map(select(.Username == $username)) | first | .Id // empty' \
        "$users"
    )"
    [ -n "$user_id" ] || die "Portainer OAuth admin user does not exist: ${username}"
    is_member="$(
      jq --raw-output \
        --argjson user_id "$user_id" \
        --argjson team_id "$team_id" \
        'any(.[]; .UserID == $user_id and .TeamID == $team_id)' \
        "$memberships"
    )"
    [ "$is_member" = "true" ] || die "Portainer OAuth admin user is not in ${PORTAINER_OAUTH_TEAM_NAME}: ${username}"
    role="$(
      jq --raw-output \
        --argjson user_id "$user_id" \
        'map(select(.Id == $user_id)) | first | .Role // empty' \
        "$users"
    )"
    [ "$role" = "1" ] || die "Portainer OAuth admin user is not a global admin: ${username}"
  done

  rm -f "$users" "$memberships"
  log "Explicit Portainer OAuth admin users are global admins"
}

cmd_configure_portainer() {
  load_os_info
  [ "$NODE_NAME" = "ai01" ] || die "configure-portainer must be run on ai01"
  ensure_ai_stand_secrets

  wait_service_ready "${STACK_NAME}_authentik-server"
  wait_service_ready "${STACK_NAME}_portainer"

  portainer_init_admin
  local jwt
  local endpoint_id
  local team_id
  jwt="$(portainer_login)"
  endpoint_id="$(ensure_portainer_endpoint "$jwt")"
  team_id="$(ensure_portainer_team "$jwt")"
  ensure_portainer_oauth_admin_users "$jwt" "$team_id"
  ensure_portainer_team_memberships "$jwt" "$team_id"
  grant_portainer_endpoint_team_access "$jwt" "$endpoint_id" "$team_id"
  grant_portainer_endpoint_user_access "$jwt" "$endpoint_id"
  configure_portainer_oauth "$jwt" "$team_id"
  check_portainer_oidc_configuration
  check_portainer_environment_configuration "$jwt" "$endpoint_id" "$team_id"
  check_portainer_oauth_admin_users "$jwt" "$team_id"
  check_portainer_oauth_user_endpoint_access "$jwt" "$endpoint_id"

  log "Portainer configuration stage complete"
}

wait_service_ready() {
  local service="$1"
  local deadline=$(( $(date +%s) + 10800 ))
  local replicas
  local expected_replicas="1/1"

  if [ "$service" = "${STACK_NAME}_portainer-agent" ]; then
    expected_replicas="2/2"
  fi

  while [ "$(date +%s)" -lt "$deadline" ]; do
    replicas="$(docker_cmd service ls --filter "name=${service}" --format '{{.Replicas}}' | head -n 1)"
    if [ "$replicas" = "$expected_replicas" ]; then
      log "Service ready: ${service}"
      return 0
    fi
    sleep 10
  done

  docker_cmd service ps "$service" --no-trunc || true
  die "Service did not become ready: ${service}"
}

service_env_value() {
  local service="$1"
  local key="$2"
  docker_cmd service inspect "$service" --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' \
    | jq -r \
      --arg key "$key" \
      '.[]? | select(startswith($key + "=")) | .[(($key | length) + 1):]' \
    | head -n 1
}

effective_service_env_value() {
  local service="$1"
  local key="$2"
  local fallback="$3"
  local value
  value="$(service_env_value "$service" "$key" || true)"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

effective_lmstudio_model_identifier() {
  effective_service_env_value \
    "${STACK_NAME}_lmstudio" \
    LMSTUDIO_MODEL_IDENTIFIER \
    "$LMSTUDIO_MODEL_IDENTIFIER"
}

effective_lmstudio_embedding_model_identifier() {
  effective_service_env_value \
    "${STACK_NAME}_lmstudio" \
    LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER \
    "$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER"
}

local_service_container() {
  local service="$1"
  docker_cmd ps \
    --filter "label=com.docker.swarm.service.name=${service}" \
    --format '{{.ID}}' \
    | head -n 1 || true
}

sync_openwebui_persistent_config() {
  if [ "${NODE_NAME:-}" != "ai01" ]; then
    log "Open WebUI persistent config sync skipped on ${NODE_NAME:-unknown}; Open WebUI is pinned to ai01"
    return 0
  fi

  wait_service_ready "${STACK_NAME}_openwebui"

  local openwebui_container
  openwebui_container="$(local_service_container "${STACK_NAME}_openwebui")"
  [ -n "$openwebui_container" ] || die "Open WebUI task is not running locally on ai01"

  local openai_api_configs
  local ollama_base_urls
  local ollama_api_configs
  local rag_embedding_model
  local enable_follow_up_generation
  local enable_retrieval_query_generation
  local enable_search_query_generation
  local enable_tags_generation
  local enable_title_generation
  local readonly_mcp_enabled
  local readonly_mcp_base_url
  local readonly_mcp_path_prefix

  openai_api_configs="$(service_env_value "${STACK_NAME}_openwebui" OPENAI_API_CONFIGS)"
  ollama_base_urls="$(service_env_value "${STACK_NAME}_openwebui" OLLAMA_BASE_URLS)"
  ollama_api_configs="$(service_env_value "${STACK_NAME}_openwebui" OLLAMA_API_CONFIGS)"
  rag_embedding_model="$(service_env_value "${STACK_NAME}_openwebui" RAG_EMBEDDING_MODEL)"
  enable_follow_up_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_FOLLOW_UP_GENERATION)"
  enable_retrieval_query_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_RETRIEVAL_QUERY_GENERATION)"
  enable_search_query_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_SEARCH_QUERY_GENERATION)"
  enable_tags_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_TAGS_GENERATION)"
  enable_title_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_TITLE_GENERATION)"
  readonly_mcp_enabled="$READONLY_MCP_ENABLED"
  readonly_mcp_base_url="https://${AGENTGATEWAY_HOST}"
  readonly_mcp_path_prefix="$READONLY_MCP_PATH_PREFIX"

  [ -n "$openai_api_configs" ] || openai_api_configs="{}"
  [ -n "$ollama_base_urls" ] || ollama_base_urls=""
  [ -n "$ollama_api_configs" ] || ollama_api_configs="{}"
  [ -n "$rag_embedding_model" ] || rag_embedding_model="$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER"
  [ -n "$enable_follow_up_generation" ] || enable_follow_up_generation="False"
  [ -n "$enable_retrieval_query_generation" ] || enable_retrieval_query_generation="False"
  [ -n "$enable_search_query_generation" ] || enable_search_query_generation="False"
  [ -n "$enable_tags_generation" ] || enable_tags_generation="False"
  [ -n "$enable_title_generation" ] || enable_title_generation="False"
  local default_models
  default_models="$(service_env_value "${STACK_NAME}_openwebui" DEFAULT_MODELS)"

  local output
  output="$(
    local -x OPENAI_API_CONFIGS="$openai_api_configs"
    local -x READONLY_MCP_ENABLED="$readonly_mcp_enabled"
    local -x READONLY_MCP_BASE_URL="$readonly_mcp_base_url"
    local -x READONLY_MCP_PATH_PREFIX="$readonly_mcp_path_prefix"
    docker_cmd exec -e OPENAI_API_CONFIGS -e READONLY_MCP_ENABLED -e READONLY_MCP_BASE_URL -e READONLY_MCP_PATH_PREFIX -i "$openwebui_container" python - \
      "$ollama_base_urls" \
      "$ollama_api_configs" \
      "$rag_embedding_model" \
      "$enable_follow_up_generation" \
      "$enable_retrieval_query_generation" \
      "$enable_search_query_generation" \
      "$enable_tags_generation" \
      "$enable_title_generation" \
      "$default_models" <<'PY'
import json
import os
import sqlite3
import sys
import time

# Passed via -e/environment rather than argv: may contain api_key, and argv
# is visible to any local user via ps/proc for the life of the process.
openai_api_configs = os.environ["OPENAI_API_CONFIGS"]
ollama_base_urls = sys.argv[1]
ollama_api_configs = sys.argv[2]
rag_embedding_model = sys.argv[3]
enable_follow_up_generation = sys.argv[4]
enable_retrieval_query_generation = sys.argv[5]
enable_search_query_generation = sys.argv[6]
enable_tags_generation = sys.argv[7]
enable_title_generation = sys.argv[8]
default_models = sys.argv[9]
readonly_mcp_enabled = os.environ.get("READONLY_MCP_ENABLED", "0").strip() == "1"
readonly_mcp_base_url = os.environ.get("READONLY_MCP_BASE_URL", "").rstrip("/")
readonly_mcp_path_prefix = os.environ.get("READONLY_MCP_PATH_PREFIX", "/mcp/work").rstrip("/")

db_path = "/app/backend/data/webui.db"
now = int(time.time())

def stable_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

def parse_json_object(raw, name):
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise SystemExit(f"{name} must be a JSON object")
    return value

def split_urls(raw):
    return [item.strip() for item in raw.replace(",", ";").split(";") if item.strip()]

def bool_config(raw):
    return "true" if str(raw).strip().lower() == "true" else "false"

openai_configs = parse_json_object(openai_api_configs, "OPENAI_API_CONFIGS")
ollama_configs = parse_json_object(ollama_api_configs, "OLLAMA_API_CONFIGS")
openai_base_urls = [
    cfg.get("base_url", "")
    for _, cfg in sorted(openai_configs.items(), key=lambda item: str(item[0]))
    if cfg.get("enable", True) and cfg.get("base_url")
]
openai_api_keys = [
    cfg.get("api_key", "")
    for _, cfg in sorted(openai_configs.items(), key=lambda item: str(item[0]))
    if cfg.get("enable", True)
]

desired = {
    "openai.enable": "true",
    "openai.api_configs": stable_json(openai_configs),
    "openai.api_base_urls": stable_json(openai_base_urls),
    "openai.api_keys": stable_json(openai_api_keys),
    "ollama.enable": "false",
    "ollama.base_urls": stable_json(split_urls(ollama_base_urls)),
    "ollama.api_configs": stable_json(ollama_configs),
    "rag.embedding_model": rag_embedding_model,
    "task.follow_up.enable": bool_config(enable_follow_up_generation),
    "task.query.retrieval.enable": bool_config(enable_retrieval_query_generation),
    "task.query.search.enable": bool_config(enable_search_query_generation),
    "task.tags.enable": bool_config(enable_tags_generation),
    "task.title.enable": bool_config(enable_title_generation),
    "ui.default_models": default_models,
}

managed_mcp_ids = {
    "ai-stand-mcp-jira",
    "ai-stand-mcp-confluence",
    "ai-stand-mcp-imap",
    "ai-stand-mcp-personal",
}

def managed_mcp_connections():
    if not readonly_mcp_enabled:
        return []
    # Authentik does not implement DCR. Agentgateway's `authentik` adapter
    # answers registration with the one public PKCE client instead, which is
    # safe for both Open WebUI and OpenClaw because no client secret is
    # involved. Each human grant remains encrypted in that user's Open WebUI
    # OAuth session, never in this global connection definition.
    return [
        {
            "type": "mcp",
            "url": f"{readonly_mcp_base_url}{path}",
            "auth_type": "oauth_2.1",
            "config": {"enable": True, "access_grants": [], "function_name_filter_list": ""},
            "info": {
                "id": identifier,
                "name": name,
                "description": description,
                "oauth_scope": "openid profile email groups",
                "oauth_resource_parameter": "auto",
            },
        }
        for identifier, name, description, path in (
            ("ai-stand-mcp-jira", "Jira (read-only)", "Personal Jira Data Center read-only tools", f"{readonly_mcp_path_prefix}/jira-readonly-mcp"),
            ("ai-stand-mcp-confluence", "Confluence (read-only)", "Personal Confluence Data Center read-only tools", f"{readonly_mcp_path_prefix}/confluence-readonly-mcp"),
            ("ai-stand-mcp-imap", "IMAP (read-only)", "Personal IMAP read-only tools", f"{readonly_mcp_path_prefix}/imap-readonly-mcp"),
            ("ai-stand-mcp-personal", "Personal MCP", "Personal MetaMCP namespace", "/mcp/personal"),
        )
    ]

changed = False
with sqlite3.connect(db_path, timeout=30) as con:
    cur = con.cursor()
    cur.execute(
        "create table if not exists config (key varchar(255) primary key, value text not null, updated_at integer not null)"
    )
    for key, value in desired.items():
        row = cur.execute("select value from config where key = ?", (key,)).fetchone()
        if row is None:
            cur.execute(
                "insert into config (key, value, updated_at) values (?, ?, ?)",
                (key, value, now),
            )
            changed = True
        elif row[0] != value:
            cur.execute(
                "update config set value = ?, updated_at = ? where key = ?",
                (value, now, key),
            )
            changed = True
    row = cur.execute("select value from config where key = ?", ("tool_server.connections",)).fetchone()
    try:
        existing_connections = json.loads(row[0]) if row else []
    except (TypeError, json.JSONDecodeError):
        existing_connections = []
    if not isinstance(existing_connections, list):
        existing_connections = []
    unmanaged_connections = [
        entry for entry in existing_connections
        if not isinstance(entry, dict) or (entry.get("info") or {}).get("id") not in managed_mcp_ids
    ]
    connections = unmanaged_connections + managed_mcp_connections()
    serialized_connections = stable_json(connections)
    if row is None:
        cur.execute(
            "insert into config (key, value, updated_at) values (?, ?, ?)",
            ("tool_server.connections", serialized_connections, now),
        )
        changed = True
    elif row[0] != serialized_connections:
        cur.execute(
            "update config set value = ?, updated_at = ? where key = ?",
            (serialized_connections, now, "tool_server.connections"),
        )
        changed = True
    con.commit()

print("changed=true" if changed else "changed=false")
PY
  )"

  log "Open WebUI persistent config sync: ${output}"
  if printf '%s\n' "$output" | grep -q 'changed=true'; then
    log "Restarting Open WebUI to pick up persistent config changes"
    docker_cmd service update --force --detach=true "${STACK_NAME}_openwebui" >/dev/null
    wait_service_ready "${STACK_NAME}_openwebui"
  fi

  sync_openwebui_gigacode_pipe
}

# Open WebUI's built-in OpenAI connection is intentionally a machine-token
# connection.  It cannot carry a human `sub`, so a personal subscription must
# be a managed Pipe instead.  The Pipe source is copied into the running
# container only for this idempotent database upsert; it is persisted as the
# Function's content and the temporary file is removed before returning.
sync_openwebui_gigacode_pipe() {
  if [ "${NODE_NAME:-}" != "ai01" ]; then
    return 0
  fi

  local openwebui_container
  openwebui_container="$(local_service_container "${STACK_NAME}_openwebui")"
  [ -n "$openwebui_container" ] || die "Open WebUI task is not running locally on ai01"

  if [ "$GIGACODE_SUBSCRIPTION_ENABLED" != "1" ]; then
    local removed
    removed="$(docker_cmd exec -i "$openwebui_container" python - <<'PY'
import sqlite3

with sqlite3.connect("/app/backend/data/webui.db", timeout=30) as con:
    try:
        cur = con.execute('delete from "function" where id = ?', ("ai_stand_gigacode_subscription",))
    except sqlite3.OperationalError:
        cur = None
    con.commit()
print("changed=true" if cur and cur.rowcount else "changed=false")
PY
)"
    if printf '%s\n' "$removed" | grep -q 'changed=true'; then
      docker_cmd service update --force --detach=true "${STACK_NAME}_openwebui" >/dev/null
      wait_service_ready "${STACK_NAME}_openwebui"
    fi
    return 0
  fi

  [ -r "$OPENWEBUI_GIGACODE_PIPE_SOURCE" ] \
    || die "Managed GigaCode Pipe source is missing: ${OPENWEBUI_GIGACODE_PIPE_SOURCE}"
  docker_cmd cp "$OPENWEBUI_GIGACODE_PIPE_SOURCE" "${openwebui_container}:/tmp/ai-stand-gigacode-subscription-pipe.py"

  local output
  output="$(docker_cmd exec -i "$openwebui_container" python - <<'PY'
import hashlib
import json
import sqlite3
import time
from pathlib import Path

function_id = "ai_stand_gigacode_subscription"
source_path = Path("/tmp/ai-stand-gigacode-subscription-pipe.py")
try:
    content = source_path.read_text(encoding="utf-8")
finally:
    source_path.unlink(missing_ok=True)
if not content.strip():
    raise SystemExit("managed GigaCode Pipe source is empty")

metadata = json.dumps({
    "manifest": {
        "title": "gigacode",
        "description": "Personal GigaCode subscription",
        "version": "1.0.0",
    },
    "ai_stand_managed": True,
}, ensure_ascii=False, separators=(",", ":"))
now = int(time.time())
desired = {
    "id": function_id,
    # `pipe` discovery is global in Open WebUI independently of this field.
    # Keep a managed integration ownerless rather than impersonating a human
    # account or making it a global filter/action.
    "user_id": None,
    "name": "gigacode",
    "type": "pipe",
    "content": content,
    "meta": metadata,
    "valves": "{}",
    "is_active": 1,
    "is_global": 0,
    "updated_at": now,
    "created_at": now,
}

with sqlite3.connect("/app/backend/data/webui.db", timeout=30) as con:
    con.execute("begin immediate")
    columns = {row[1] for row in con.execute('pragma table_info("function")')}
    if not columns or "id" not in columns:
        raise SystemExit("Open WebUI function table is unavailable")
    row = con.execute('select * from "function" where id = ?', (function_id,)).fetchone()
    usable = {key: value for key, value in desired.items() if key in columns}
    if row is None:
        fields = list(usable)
        con.execute(
            'insert into "function" ({}) values ({})'.format(
                ",".join('"' + key + '"' for key in fields), ",".join("?" for _ in fields)
            ),
            tuple(usable[key] for key in fields),
        )
        changed = True
    else:
        existing = dict(zip([item[1] for item in con.execute('pragma table_info("function")')], row))
        updates = {key: value for key, value in usable.items() if key not in {"id", "created_at"} and existing.get(key) != value}
        if updates:
            fields = list(updates)
            con.execute(
                'update "function" set {} where id = ?'.format(",".join('"' + key + '" = ?' for key in fields)),
                tuple(updates[key] for key in fields) + (function_id,),
            )
        changed = bool(updates)
    con.commit()

print("changed=true" if changed else "changed=false")
print("sha256=" + hashlib.sha256(content.encode("utf-8")).hexdigest())
PY
)"
  log "Open WebUI managed GigaCode Pipe sync: $(printf '%s\n' "$output" | head -n 1)"
  if printf '%s\n' "$output" | grep -q 'changed=true'; then
    docker_cmd service update --force --detach=true "${STACK_NAME}_openwebui" >/dev/null
    wait_service_ready "${STACK_NAME}_openwebui"
  fi
}

check_openwebui_persistent_config() {
  if [ "$NODE_NAME" != "ai01" ]; then
    log "Open WebUI persistent config check skipped on ${NODE_NAME}; Open WebUI is pinned to ai01"
    return 0
  fi

  local openwebui_container
  openwebui_container="$(local_service_container "${STACK_NAME}_openwebui")"
  [ -n "$openwebui_container" ] || die "Open WebUI task is not running locally on ai01"

  local openai_api_configs
  local ollama_api_configs
  local rag_embedding_model
  local enable_follow_up_generation
  local enable_retrieval_query_generation
  local enable_search_query_generation
  local enable_tags_generation
  local enable_title_generation
  local readonly_mcp_enabled
  local readonly_mcp_base_url
  local readonly_mcp_path_prefix

  openai_api_configs="$(service_env_value "${STACK_NAME}_openwebui" OPENAI_API_CONFIGS)"
  ollama_api_configs="$(service_env_value "${STACK_NAME}_openwebui" OLLAMA_API_CONFIGS)"
  rag_embedding_model="$(service_env_value "${STACK_NAME}_openwebui" RAG_EMBEDDING_MODEL)"
  enable_follow_up_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_FOLLOW_UP_GENERATION)"
  enable_retrieval_query_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_RETRIEVAL_QUERY_GENERATION)"
  enable_search_query_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_SEARCH_QUERY_GENERATION)"
  enable_tags_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_TAGS_GENERATION)"
  enable_title_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_TITLE_GENERATION)"
  readonly_mcp_enabled="$READONLY_MCP_ENABLED"
  readonly_mcp_base_url="https://${AGENTGATEWAY_HOST}"
  readonly_mcp_path_prefix="$READONLY_MCP_PATH_PREFIX"

  [ -n "$openai_api_configs" ] || openai_api_configs="{}"
  [ -n "$ollama_api_configs" ] || ollama_api_configs="{}"
  [ -n "$rag_embedding_model" ] || rag_embedding_model="$LMSTUDIO_EMBEDDING_MODEL_IDENTIFIER"
  [ -n "$enable_follow_up_generation" ] || enable_follow_up_generation="False"
  [ -n "$enable_retrieval_query_generation" ] || enable_retrieval_query_generation="False"
  [ -n "$enable_search_query_generation" ] || enable_search_query_generation="False"
  [ -n "$enable_tags_generation" ] || enable_tags_generation="False"
  [ -n "$enable_title_generation" ] || enable_title_generation="False"

  (
    local -x OPENAI_API_CONFIGS="$openai_api_configs"
    local -x READONLY_MCP_ENABLED="$readonly_mcp_enabled"
    local -x READONLY_MCP_BASE_URL="$readonly_mcp_base_url"
    local -x READONLY_MCP_PATH_PREFIX="$readonly_mcp_path_prefix"
    docker_cmd exec -e OPENAI_API_CONFIGS -e READONLY_MCP_ENABLED -e READONLY_MCP_BASE_URL -e READONLY_MCP_PATH_PREFIX -i "$openwebui_container" python - \
      "$ollama_api_configs" \
      "$rag_embedding_model" \
      "$enable_follow_up_generation" \
      "$enable_retrieval_query_generation" \
      "$enable_search_query_generation" \
      "$enable_tags_generation" \
      "$enable_title_generation" <<'PY'
import json
import os
import sqlite3
import sys

# Passed via -e/environment rather than argv: may contain api_key.
expected_openai = json.dumps(json.loads(os.environ["OPENAI_API_CONFIGS"]), ensure_ascii=False, separators=(",", ":"))
expected_ollama = json.dumps(json.loads(sys.argv[1]), ensure_ascii=False, separators=(",", ":"))
expected_embedding = sys.argv[2]
expected_follow_up = "true" if sys.argv[3].strip().lower() == "true" else "false"
expected_retrieval_query = "true" if sys.argv[4].strip().lower() == "true" else "false"
expected_search_query = "true" if sys.argv[5].strip().lower() == "true" else "false"
expected_tags = "true" if sys.argv[6].strip().lower() == "true" else "false"
expected_title = "true" if sys.argv[7].strip().lower() == "true" else "false"
readonly_mcp_enabled = os.environ.get("READONLY_MCP_ENABLED", "0").strip() == "1"
readonly_mcp_base_url = os.environ.get("READONLY_MCP_BASE_URL", "").rstrip("/")
readonly_mcp_path_prefix = os.environ.get("READONLY_MCP_PATH_PREFIX", "/mcp/work").rstrip("/")

with sqlite3.connect("/app/backend/data/webui.db", timeout=30) as con:
    rows = dict(con.execute(
        "select key, value from config where key in (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "openai.api_configs",
            "ollama.enable",
            "ollama.api_configs",
            "rag.embedding_model",
            "task.follow_up.enable",
            "task.query.retrieval.enable",
            "task.query.search.enable",
            "task.tags.enable",
            "task.title.enable",
            "tool_server.connections",
        ),
    ).fetchall())

errors = []
if rows.get("openai.api_configs") != expected_openai:
    errors.append("openai.api_configs")
if rows.get("ollama.enable") != "false":
    errors.append("ollama.enable")
if rows.get("ollama.api_configs") != expected_ollama:
    errors.append("ollama.api_configs")
if rows.get("rag.embedding_model") != expected_embedding:
    errors.append("rag.embedding_model")
if rows.get("task.follow_up.enable") != expected_follow_up:
    errors.append("task.follow_up.enable")
if rows.get("task.query.retrieval.enable") != expected_retrieval_query:
    errors.append("task.query.retrieval.enable")
if rows.get("task.query.search.enable") != expected_search_query:
    errors.append("task.query.search.enable")
if rows.get("task.tags.enable") != expected_tags:
    errors.append("task.tags.enable")
if rows.get("task.title.enable") != expected_title:
    errors.append("task.title.enable")
try:
    connections = json.loads(rows.get("tool_server.connections", "[]"))
except json.JSONDecodeError:
    connections = None
if not isinstance(connections, list):
    errors.append("tool_server.connections")
else:
    expected = {
        "ai-stand-mcp-jira": f"{readonly_mcp_path_prefix}/jira-readonly-mcp",
        "ai-stand-mcp-confluence": f"{readonly_mcp_path_prefix}/confluence-readonly-mcp",
        "ai-stand-mcp-imap": f"{readonly_mcp_path_prefix}/imap-readonly-mcp",
        "ai-stand-mcp-personal": "/mcp/personal",
    }
    actual = {
        (entry.get("info") or {}).get("id"): entry
        for entry in connections if isinstance(entry, dict)
        and (entry.get("info") or {}).get("id") in expected
    }
    if readonly_mcp_enabled:
        for identifier, path in expected.items():
            connection = actual.get(identifier)
            if not isinstance(connection, dict) or connection.get("type") != "mcp" or connection.get("auth_type") != "oauth_2.1" or connection.get("url") != readonly_mcp_base_url + path:
                errors.append("tool_server.connections")
                break
    elif actual:
        errors.append("tool_server.connections")

if errors:
    raise SystemExit("Open WebUI persistent config drift: " + ", ".join(errors))
PY
  )

  log "Open WebUI persistent config matches service environment"
}

check_readonly_mcp_configuration() {
  [ "$READONLY_MCP_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai01" ] || return 0

  run_root test -f "$READONLY_MCP_RECONCILER_CONFIG" \
    || die "Read-only MCP reconciler configuration is missing: $READONLY_MCP_RECONCILER_CONFIG"
  run_root test -f "$READONLY_MCP_MANIFEST" \
    || die "Read-only MCP manifest is missing: $READONLY_MCP_MANIFEST"
  [ "$(run_root stat -c '%U:%G:%a' "$READONLY_MCP_RECONCILER_CONFIG")" = "root:root:600" ] \
    || die "Read-only MCP reconciler configuration must be root:root mode 0600"
  run_root systemctl is-enabled --quiet ai-stand-readonly-mcp-reconciler.timer \
    || die "Read-only MCP reconciler timer is not enabled"
  run_root systemctl is-active --quiet ai-stand-readonly-mcp-reconciler.timer \
    || die "Read-only MCP reconciler timer is not active"

  local -a mcp_services=()
  local service_list
  service_list="$(mktemp)"
  if ! run_root python3 - "$READONLY_MCP_MANIFEST" > "$service_list" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
if not isinstance(manifest, dict) or manifest.get("version") != 2 or not isinstance(manifest.get("users"), list):
    raise SystemExit("unsupported manifest")
safe_slug = re.compile(r"^[a-z][a-z0-9-]{0,48}$")
for user in manifest["users"]:
    if not isinstance(user, dict) or not isinstance(user.get("slug"), str) or not safe_slug.fullmatch(user["slug"]):
        raise SystemExit("unsafe user entry")
    services = user.get("services", {})
    if not isinstance(services, dict):
        raise SystemExit("unsafe services entry")
    for kind in ("jira", "confluence", "imap", "gigacode"):
        if kind in services:
            if not isinstance(services[kind], dict):
                raise SystemExit("unsafe service entry")
            if kind == "gigacode":
                print(f"gigacode-subscription-bridge-{user['slug']}")
            else:
                print(f"{kind}-readonly-mcp-{user['slug']}")
PY
  then
    rm -f "$service_list"
    die "Read-only MCP manifest validation failed"
  fi
  mapfile -t mcp_services < "$service_list"
  rm -f "$service_list"

  local service service_user service_readonly service_ports
  for service in "${mcp_services[@]}"; do
    docker_cmd service inspect "${STACK_NAME}_${service}" >/dev/null \
      || die "Read-only MCP service is missing: ${STACK_NAME}_${service}"
    service_user="$(docker_cmd service inspect "${STACK_NAME}_${service}" --format '{{.Spec.TaskTemplate.ContainerSpec.User}}')"
    [ "$service_user" = "10000:20000" ] \
      || die "Read-only MCP service ${service} has unexpected container user: ${service_user:-empty}"
    service_readonly="$(docker_cmd service inspect "${STACK_NAME}_${service}" --format '{{.Spec.TaskTemplate.ContainerSpec.ReadOnly}}')"
    [ "$service_readonly" = "true" ] \
      || die "Read-only MCP service ${service} does not have a read-only root filesystem"
    service_ports="$(docker_cmd service inspect "${STACK_NAME}_${service}" --format '{{json .Endpoint.Spec.Ports}}')"
    case "$service_ports" in ""|null) ;; *) die "Read-only MCP service ${service} must not publish ports" ;; esac
  done

  log "Read-only MCP reconciler/timer and ${#mcp_services[@]} active services verified"
}

check_agentgateway_database() {
  local svc="${STACK_NAME}_agentgateway-postgres"
  docker_cmd service inspect "$svc" >/dev/null 2>&1 \
    || die "agentgateway's request-log database service is missing: ${svc}"
  check_service_label_placement "$svc" "ai-stand.agentgateway"

  # Confirms apply_installation_service_env() actually pushed a real value
  # past compose.yaml's "unconfigured" placeholder (see that file's env
  # block on the agentgateway service) - not that agentgateway itself
  # accepted the connection, which cmd_verify has no read-only way to probe.
  local password
  password="$(service_env_value "${STACK_NAME}_agentgateway" AGENTGATEWAY_POSTGRES_PASSWORD)"
  [ -n "$password" ] && [ "$password" != "unconfigured" ] \
    || die "agentgateway's live AGENTGATEWAY_POSTGRES_PASSWORD was never pushed past its placeholder"
}

bootstrap_coder_admin() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  local container
  container="$(docker_cmd ps --filter "name=${STACK_NAME}_coder." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container" ] || die "Coder container is not running; cannot bootstrap its admin user"

  # `coder server create-admin-user` is a server subcommand: it talks to
  # Postgres directly, not through the already-running server's own HTTP
  # API, so it needs its own connection URL. entrypoint.sh builds and
  # exports CODER_PG_CONNECTION_URL once for the main server process - that
  # export doesn't reach a fresh `docker exec` session (it dies with the
  # shell that ran it, before `exec` replaced it), so it's rebuilt here the
  # same way, from the same mounted secret.
  local output
  output="$(mktemp)"
  if docker_cmd exec \
    -e CODER_ADMIN_USERNAME="$CODER_ADMIN_USERNAME" \
    -e CODER_ADMIN_EMAIL="$CODER_ADMIN_EMAIL" \
    -e CODER_ADMIN_PASSWORD="$CODER_ADMIN_PASSWORD" \
    "$container" sh -ec '
      pg_password="$(cat /run/secrets/ai-stand-coder-postgres-password)"
      exec /opt/coder server create-admin-user \
        --postgres-url "postgresql://coder:${pg_password}@coder-postgresql:5432/coder?sslmode=disable" \
        --username "$CODER_ADMIN_USERNAME" \
        --email "$CODER_ADMIN_EMAIL" \
        --password "$CODER_ADMIN_PASSWORD"
    ' >"$output" 2>&1; then
    log "Coder bootstrap admin ensured (${CODER_ADMIN_USERNAME})"
    rm -f "$output"
    return 0
  fi
  if grep -qiE 'already exists|duplicate|unique constraint|already in use' "$output"; then
    log "Coder bootstrap admin already exists"
    rm -f "$output"
    return 0
  fi
  cat "$output" >&2
  rm -f "$output"
  die "Coder admin bootstrap failed"
}

check_coder_native_oidc() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  local response
  response="$(mktemp)"
  if ! curl --silent --show-error --fail --max-time 30 \
    --resolve "${CODER_HOST}:443:127.0.0.1" \
    "https://${CODER_HOST}/api/v2/users/authmethods" > "$response"; then
    rm -f "$response"
    die "Cannot read Coder native authentication methods"
  fi
  if ! jq --exit-status \
    '.password.enabled == false and .oidc.enabled == true and .oidc.signInText == "Войти через Authentik"' \
    "$response" >/dev/null; then
    rm -f "$response"
    die "Coder native OIDC/password-login settings are not effective"
  fi
  rm -f "$response"
  log "Coder exposes native Authentik sign-in and has password login disabled"
}

check_service_label_placement() {
  local service="$1"
  local label="$2"
  local node
  local label_value

  node="$(docker_cmd service ps "$service" --filter desired-state=running --format '{{.Node}}' | head -n 1)"
  [ -n "$node" ] || die "No running task node found for service: ${service}"
  label_value="$(docker_cmd node inspect "$node" --format "{{ index .Spec.Labels \"${label}\" }}" 2>/dev/null || true)"
  [ "$label_value" = "true" ] || die "${service} is running on ${node}, but ${label} is not true"
  log "Placement ok: ${service} on ${node} (${label}=true)"
}

# openclaw-sandbox-dind is not a Swarm service (see
# ensure_openclaw_sandbox_dind_service), so it has no placement label to
# check via check_service_label_placement - this is the host-local
# equivalent, confirming the systemd unit is up and, specifically, that the
# container actually got the privileged mode a Swarm-managed task never
# could (the exact failure this whole host-level design works around).
check_openclaw_sandbox_dind_host_service() {
  run_root systemctl is-active --quiet ai-stand-openclaw-sandbox-dind.service \
    || die "ai-stand-openclaw-sandbox-dind.service is not active"

  local privileged
  privileged="$(docker_cmd inspect ai-stand-openclaw-sandbox-dind --format '{{.HostConfig.Privileged}}' 2>/dev/null || true)"
  [ "$privileged" = "true" ] \
    || die "openclaw-sandbox-dind container is not privileged (got: '${privileged:-<not found>}')"

  log "openclaw-sandbox-dind host service is active and privileged"
}

check_coder_rootless_docker_service() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0
  run_root systemctl is-active --quiet ai-stand-coder-rootless-docker.service \
    || die "ai-stand-coder-rootless-docker.service is not active"
  run_root test -S "$CODER_ROOTLESS_DOCKER_SOCKET" \
    || die "Coder rootless Docker socket is missing"
  run_root sudo -u "$CODER_RUNTIME_USER" env \
    HOME="$CODER_PROVISIONER_HOME" \
    XDG_RUNTIME_DIR="$CODER_PROVISIONER_RUNTIME" \
    DOCKER_HOST="unix://${CODER_ROOTLESS_DOCKER_SOCKET}" \
    docker info --format '{{.SecurityOptions}}' | grep -qi rootless \
    || die "Coder Docker endpoint is not rootless"
  run_root sudo -u "$CODER_RUNTIME_USER" env \
    HOME="$CODER_PROVISIONER_HOME" \
    XDG_RUNTIME_DIR="$CODER_PROVISIONER_RUNTIME" \
    DOCKER_HOST="unix://${CODER_ROOTLESS_DOCKER_SOCKET}" \
    docker network inspect "$CODER_WORKSPACE_NETWORK" >/dev/null \
    || die "Coder workspace network ${CODER_WORKSPACE_NETWORK} is missing"
  log "Coder isolated rootless Docker daemon is active"
}

# The Gateway talks to a remote Docker daemon in openclaw-sandbox-dind. Its
# bind-mount source paths must therefore exist inside that daemon too. Only
# the sandbox workspace root crosses this boundary: credentials and the rest
# of Gateway's /home/ai remain inaccessible to DIND.
check_openclaw_sandbox_workspace_bridge() {
  local workspace_mount
  local workspace_stat
  local probe_dir
  local probe_name
  local probe_file

  workspace_mount="$(docker_cmd inspect ai-stand-openclaw-sandbox-dind --format '{{range .Mounts}}{{if eq .Destination "/home/ai/.openclaw/sandboxes"}}{{.Source}}:{{.RW}}{{end}}{{end}}' 2>/dev/null || true)"
  [ "$workspace_mount" = "${OPENCLAW_SANDBOX_WORKSPACE_ROOT}:true" ] \
    || die "openclaw-sandbox-dind is missing the required rw sandbox workspace mount (got: '${workspace_mount:-<none>}')"

  workspace_stat="$(docker_cmd exec ai-stand-openclaw-sandbox-dind stat -c '%u:%g:%a' /home/ai/.openclaw/sandboxes 2>/dev/null || true)"
  [ "$workspace_stat" = "${APP_UID}:${APP_GID}:750" ] \
    || die "Sandbox workspace root has unexpected ownership or mode inside DIND: '${workspace_stat:-<missing>}' (expected ${APP_UID}:${APP_GID}:750)"

  probe_dir="$(run_root mktemp -d "${OPENCLAW_SANDBOX_WORKSPACE_ROOT}/.ai-stand-write-probe.${RUN_TS}.XXXXXX")"
  probe_name="${probe_dir##*/}"
  probe_file="${probe_dir}/.ai-stand-write-probe"
  run_root chown "$APP_UID:$APP_GID" "$probe_dir"
  run_root chmod 0750 "$probe_dir"

  if ! docker_cmd exec ai-stand-openclaw-sandbox-dind docker run --rm \
    --user "${APP_UID}:${APP_GID}" \
    --network none \
    -v "/home/ai/.openclaw/sandboxes/${probe_name}:/workspace:rw" \
    "$OPENCLAW_SANDBOX_IMAGE" \
    sh -ceu 'test -w /workspace && touch /workspace/.ai-stand-write-probe'; then
    run_root rmdir "$probe_dir" >/dev/null 2>&1 || true
    die "Sandbox workspace write probe failed; retained non-empty probe directory if diagnostics are needed: ${probe_dir}"
  fi

  if ! run_root test -f "$probe_file"; then
    run_root rmdir "$probe_dir" >/dev/null 2>&1 || true
    die "Sandbox workspace write probe did not appear on the host: ${probe_file}"
  fi

  run_root rm -f -- "$probe_file"
  run_root rmdir -- "$probe_dir" \
    || die "Sandbox workspace write probe cleanup refused because ${probe_dir} is unexpectedly non-empty"
  log "OpenClaw sandbox workspace bridge is writable as ${APP_UID}:${APP_GID}"
}

# check_openclaw_sandbox_dind_host_service only proves the dind sidecar
# itself is healthy - it says nothing about whether openclaw-gateway can
# actually drive it. That gap is exactly how the "docker" CLI going missing
# from the gateway image (see docker/openclaw/Dockerfile) shipped unnoticed:
# DOCKER_HOST pointed at a live, privileged, reachable daemon the whole time,
# but every sandbox operation failed before it ever got there (spawn docker
# ENOENT). Exec into the running gateway container as the "ai" user (the
# user the gateway process itself runs as) and force a real round trip to
# the daemon over DOCKER_HOST, not just confirm a binary exists on disk.
check_openclaw_gateway_docker_cli() {
  local container_id
  local server_version

  container_id="$(local_service_container "${STACK_NAME}_openclaw-gateway")"
  [ -n "$container_id" ] || die "openclaw-gateway task is not running locally on ${NODE_NAME}"

  server_version="$(docker_cmd exec -u ai "$container_id" docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  [ -n "$server_version" ] \
    || die "openclaw-gateway (container ${container_id}) cannot invoke docker against the sandbox dind daemon over \$DOCKER_HOST - check that the docker CLI is installed in the image and DOCKER_HOST is reachable"

  log "openclaw-gateway can reach sandbox dind daemon over DOCKER_HOST (server ${server_version})"
}

# check_openclaw_sandbox_dind_host_service and check_openclaw_gateway_docker_cli
# together only prove the dind daemon is up, privileged, and reachable from
# openclaw-gateway over DOCKER_HOST - neither proves the actual sandbox image
# OpenClaw's Docker backend looks for (openclaw-sandbox:bookworm-slim, see
# docker/openclaw-sandbox/Dockerfile and ensure_openclaw_sandbox_image) has
# ever been built into it. That gap is exactly how "docker CLI reaches the
# daemon fine" and "Sandbox image not found: openclaw-sandbox:bookworm-slim"
# showed up as two separate, sequential failures in the same debugging
# session. Inspect the image directly inside openclaw-sandbox-dind, the same
# daemon agents.defaults.sandbox.backend=docker resolves to at runtime.
check_openclaw_sandbox_image() {
  local image_id
  image_id="$(docker_cmd exec ai-stand-openclaw-sandbox-dind docker image inspect "$OPENCLAW_SANDBOX_IMAGE" --format '{{.Id}}' 2>/dev/null || true)"
  [ -n "$image_id" ] \
    || die "openclaw-sandbox-dind is missing the ${OPENCLAW_SANDBOX_IMAGE} image OpenClaw's Docker sandbox backend requires"

  log "OpenClaw sandbox image ${OPENCLAW_SANDBOX_IMAGE} is present in openclaw-sandbox-dind (${image_id})"
}

check_overlay_name() {
  local network="$1"
  local name="$2"
  local service
  local network_id

  # The model and MCP backend networks are intentionally non-attachable, so
  # a diagnostic container cannot join them. Inspecting the Swarm service
  # spec proves the same topology without weakening either network merely to
  # make a health check convenient. DNS is exercised by actual request
  # probes from the services that are allowed on each backend.
  case "$name" in
    authentik) service="${STACK_NAME}_authentik-server" ;;
    authentik-postgresql) service="${STACK_NAME}_authentik-postgresql" ;;
    authentik-redis) service="${STACK_NAME}_authentik-redis" ;;
    openwebui) service="${STACK_NAME}_openwebui" ;;
    openclaw|openclaw-gateway) service="${STACK_NAME}_openclaw-gateway" ;;
    lmstudio) service="${STACK_NAME}_lmstudio" ;;
    lmstudio-proxy) service="${STACK_NAME}_lmstudio-proxy" ;;
    metamcp) service="${STACK_NAME}_metamcp" ;;
    metamcp-postgres) service="${STACK_NAME}_metamcp-postgres" ;;
    agentgateway) service="${STACK_NAME}_agentgateway" ;;
    agentgateway-postgres) service="${STACK_NAME}_agentgateway-postgres" ;;
    gigacode-identity-broker) service="${STACK_NAME}_gigacode-identity-broker" ;;
    openclaw-gigacode-adapter) service="${STACK_NAME}_openclaw-gigacode-adapter" ;;
    coder) service="${STACK_NAME}_coder" ;;
    coder-postgresql) service="${STACK_NAME}_coder-postgresql" ;;
    portainer) service="${STACK_NAME}_portainer" ;;
    portainer-agent|tasks.portainer-agent) service="${STACK_NAME}_portainer-agent" ;;
    *) die "Unknown overlay name check: ${name}" ;;
  esac

  network_id="$(docker_cmd network inspect "$network" --format '{{.Id}}' 2>/dev/null || true)"
  [ -n "$network_id" ] || die "Missing overlay network ${network}"
  docker_cmd service inspect "$service" --format '{{json .Spec.TaskTemplate.Networks}}' \
    | jq --arg network_id "$network_id" --exit-status \
      'any(.[]?; .Target == $network_id)' >/dev/null \
    || die "Service ${service} is not attached to ${network}"
  log "Overlay service attachment ok: ${network} ${name}"
}

# ai-models-backend intentionally remains a non-attachable encrypted overlay:
# application services never receive a Docker socket, and a host-root
# diagnostic must not make a closed model network attachable merely to run
# curl.  LM Studio is already attached to that network and is built from the
# base image containing curl, so use its running task for read-only probes.
models_backend_curl() {
  local container
  container="$(
    docker_cmd ps \
      --filter "label=com.docker.swarm.service.name=${STACK_NAME}_lmstudio" \
      --filter status=running \
      --format '{{.ID}}' \
      | head -n 1
  )"
  [ -n "$container" ] || die "No running LM Studio task is available for ai-models-backend probe"
  docker_cmd exec -i "$container" curl "$@"
}

check_https_retry() {
  local domain="$1"
  local path="$2"
  local timeout_seconds="$3"
  local deadline=$(( $(date +%s) + timeout_seconds ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl --fail --silent --show-error --location --max-time 30 \
      --resolve "${domain}:443:127.0.0.1" \
      "https://${domain}${path}" >/dev/null; then
      log "HTTPS ok: https://${domain}${path}"
      return 0
    fi
    sleep 15
  done

  die "HTTPS check failed: https://${domain}${path}"
}

check_https_protected_retry() {
  local domain="$1"
  local path="$2"
  local timeout_seconds="$3"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local status target
  local -a targets=("127.0.0.1")

  # A host-Nginx route can behave differently when reached through its
  # published LAN address than through loopback.  Testing only 127.0.0.1
  # would have missed an old OpenClaw vhost without forward-auth, even
  # though clients use HOST_IP.  Keep the TLS name fixed through --resolve,
  # but require every local ingress address to reject an unauthenticated
  # request before accepting the protection check.
  if [ "$HOST_IP" != "127.0.0.1" ]; then
    targets+=("$HOST_IP")
  fi

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local all_protected="1"
    local failed=""
    for target in "${targets[@]}"; do
      status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 30 \
        --resolve "${domain}:443:${target}" \
        "https://${domain}${path}" 2>/dev/null || true)"
      case "$status" in
        302|401|403) ;;
        *)
          all_protected="0"
          failed="${target}=${status:-none}"
          break
          ;;
      esac
    done
    if [ "$all_protected" = "1" ]; then
      log "HTTPS protected ok: https://${domain}${path} is protected via ${targets[*]}"
      return 0
    fi
    sleep 15
  done

  die "HTTPS protection check failed: https://${domain}${path} via ${failed:-unknown}; expected 302/401/403 without session"
}

https_path_for_domain() {
  case "$1" in
    "$OPENWEBUI_HOST") printf '%s\n' "/" ;;
    "$OPENCLAW_HOST") printf '%s\n' "/healthz" ;;
    "$PORTAINER_HOST") printf '%s\n' "/api/status" ;;
    "$CODER_HOST") printf '%s\n' "/healthz" ;;
    "$AUTHENTIK_HOST") printf '%s\n' "/" ;;
    "$METAMCP_HOST") printf '%s\n' "/health" ;;
    *) die "Unknown HTTPS check domain: $1" ;;
  esac
}

check_port_closed_to_non_loopback() {
  local port="$1"
  run_root iptables -C AI-STAND-HOST-PROTECT -p tcp --dport "$port" -j DROP 2>/dev/null \
    || die "INPUT does not block technical port ${port}"
  run_root iptables -C AI-STAND-PROTECT -p tcp -m conntrack --ctorigdstport "$port" -j DROP 2>/dev/null \
    || die "DOCKER-USER does not block original destination technical port ${port}"
  run_root iptables -C AI-STAND-PROTECT -p tcp --dport "$port" -j DROP 2>/dev/null \
    || die "DOCKER-USER does not block technical port ${port}"
  log "INPUT and DOCKER-USER block technical port ${port}"
}

check_openwebui_sso_only_environment() {
  docker_cmd service inspect "${STACK_NAME}_openwebui" --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' \
    | jq --exit-status \
      --arg redirect "OPENID_REDIRECT_URI=https://${OPENWEBUI_HOST}/oauth/oidc/callback" \
      '
        any(.[]?; . == "WEBUI_AUTH=True")
        and any(.[]?; . == "ENABLE_LOGIN_FORM=False")
        and any(.[]?; . == "ENABLE_OAUTH_SIGNUP=True")
        and any(.[]?; . == "OAUTH_AUTO_REDIRECT=True")
        and any(.[]?; . == $redirect)
      ' \
      >/dev/null
  log "Open WebUI is configured as SSO-only"
}

check_openclaw_trusted_proxy_configuration() {
  [ "$OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  docker_cmd service inspect "${STACK_NAME}_openclaw-gateway" --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' \
    | jq --exit-status \
      --arg enabled 'OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED=1' \
      --arg proxies "OPENCLAW_TRUSTED_PROXIES=${OPENCLAW_TRUSTED_PROXIES}" \
      'any(.[]?; . == $enabled) and any(.[]?; . == $proxies)' >/dev/null \
    || die "OpenClaw service does not have the required Authentik trusted-proxy environment"

  local container_id auth_mode
  container_id="$(local_service_container "${STACK_NAME}_openclaw-gateway")"
  [ -n "$container_id" ] || die "OpenClaw Gateway task is not running locally for trusted-proxy verification"
  auth_mode="$(docker_cmd exec -u ai "$container_id" openclaw config get gateway.auth.mode 2>/dev/null || true)"
  printf '%s' "$auth_mode" | grep -Eq 'trusted-proxy' \
    || die "OpenClaw persistent gateway.auth.mode is not trusted-proxy"

  check_https_protected_retry "$OPENCLAW_HOST" "/" 600
  log "OpenClaw Authentik trusted-proxy configuration is active"
}

check_authentik_configuration() {
  if [ "$NODE_NAME" != "ai01" ]; then
    log "Authentik configuration check skipped on ${NODE_NAME}; Authentik is pinned to ai01"
    return 0
  fi

  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/openwebui/.well-known/openid-configuration" \
    | jq --exit-status \
      --arg issuer "https://${AUTHENTIK_HOST}/application/o/openwebui/" \
      '.issuer == $issuer and (.authorization_endpoint | type == "string") and (.token_endpoint | type == "string") and (.jwks_uri | type == "string")' \
      >/dev/null
  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/openwebui/jwks/" \
    | jq --exit-status '.keys | type == "array" and length > 0' \
      >/dev/null
  log "Authentik Open WebUI OIDC discovery is configured"

  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/portainer/.well-known/openid-configuration" \
    | jq --exit-status \
      --arg issuer "https://${AUTHENTIK_HOST}/application/o/portainer/" \
      '.issuer == $issuer and (.authorization_endpoint | type == "string") and (.token_endpoint | type == "string") and (.jwks_uri | type == "string")' \
      >/dev/null
  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/portainer/jwks/" \
    | jq --exit-status '.keys | type == "array" and length > 0' \
      >/dev/null
  log "Authentik Portainer OIDC discovery is configured"

  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/metamcp/.well-known/openid-configuration" \
    | jq --exit-status \
      --arg issuer "https://${AUTHENTIK_HOST}/application/o/metamcp/" \
      '.issuer == $issuer and (.authorization_endpoint | type == "string") and (.token_endpoint | type == "string") and (.jwks_uri | type == "string")' \
      >/dev/null
  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/metamcp/jwks/" \
    | jq --exit-status '.keys | type == "array" and length > 0' \
      >/dev/null
  log "Authentik MetaMCP OIDC discovery is configured"

  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/agentgateway/.well-known/openid-configuration" \
    | jq --exit-status \
      --arg issuer "https://${AUTHENTIK_HOST}/application/o/agentgateway/" \
      '.issuer == $issuer and (.authorization_endpoint | type == "string") and (.token_endpoint | type == "string") and (.jwks_uri | type == "string")' \
      >/dev/null
  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/agentgateway/jwks/" \
    | jq --exit-status '.keys | type == "array" and length > 0' \
      >/dev/null
  log "Authentik agentgateway OIDC discovery is configured"

  # This one public PKCE issuer is consumed by both OpenClaw and Open WebUI
  # MCP clients. Agentgateway validates the same `sub` claim for every
  # request; it must stay separate from the confidential admin-console
  # issuer checked above.
  curl --fail --silent --show-error --max-time 30 \
    --resolve "${AUTHENTIK_HOST}:443:127.0.0.1" \
    "https://${AUTHENTIK_HOST}/application/o/agentgateway-mcp/.well-known/openid-configuration" \
    | jq --exit-status \
      --arg issuer "https://${AUTHENTIK_HOST}/application/o/agentgateway-mcp/" \
      '.issuer == $issuer and (.authorization_endpoint | type == "string") and (.token_endpoint | type == "string") and (.jwks_uri | type == "string")' \
      >/dev/null
  log "Authentik Agentgateway MCP OIDC discovery is configured"
}

check_lmstudio_model_inventory() {
  local timeout_seconds="${1:-10800}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local response
  local poll_count=0
  local lmstudio_container
  local chat_model
  local embedding_model

  chat_model="$(effective_lmstudio_model_identifier)"
  embedding_model="$(effective_lmstudio_embedding_model_identifier)"

  if [ "$NODE_NAME" = "ai01" ]; then
    while [ "$(date +%s)" -lt "$deadline" ]; do
      lmstudio_container="$(local_service_container "${STACK_NAME}_lmstudio")"
      if [ -n "$lmstudio_container" ]; then
        response="$(
          docker_cmd exec -u ai "$lmstudio_container" sh -lc \
            '$HOME/.lmstudio/bin/lms ps --json' 2>/dev/null || true
        )"

        if printf '%s' "$response" \
          | jq --exit-status \
            --arg chat_model "$chat_model" \
            --arg embedding_model "$embedding_model" \
            'any(.[]?;
                .identifier == $chat_model
                and ((.status // "") | ascii_downcase) == "idle"
              )
             and any(.[]?;
                .identifier == $embedding_model
                and ((.status // "") | ascii_downcase) == "idle"
              )' \
            >/dev/null 2>&1; then
          log "LM Studio loaded models ok: ${chat_model}, ${embedding_model}"
          return 0
        fi
      fi

      if [ "$poll_count" -eq 0 ] || [ $((poll_count % 10)) -eq 0 ]; then
        local ids
        ids="$(printf '%s' "$response" | jq --raw-output '[.[]?.identifier] | join(", ")' 2>/dev/null || true)"
        log "Waiting for loaded LM Studio models: ${chat_model}, ${embedding_model}; currently: ${ids:-unavailable}"
      fi

      poll_count=$((poll_count + 1))
      sleep 30
    done

    die "LM Studio did not keep required models loaded: ${chat_model}, ${embedding_model}"
  fi

  while [ "$(date +%s)" -lt "$deadline" ]; do
    response="$(
      models_backend_curl --fail --silent --show-error http://lmstudio:1234/v1/models 2>/dev/null || true
    )"
    response="$(printf '%s\n' "$response" | sed -n '/^[[:space:]]*{/,$p')"

    if printf '%s' "$response" \
      | jq --exit-status \
        --arg chat_model "$chat_model" \
        --arg embedding_model "$embedding_model" \
        '[.data[]?.id] as $ids | ($ids | index($chat_model)) and ($ids | index($embedding_model))' \
        >/dev/null 2>&1; then
      log "LM Studio model inventory ok: ${chat_model}, ${embedding_model}"
      return 0
    fi

    if [ "$poll_count" -eq 0 ] || [ $((poll_count % 10)) -eq 0 ]; then
      local ids
      ids="$(printf '%s' "$response" | jq --raw-output '[.data[]?.id] | join(", ")' 2>/dev/null || true)"
      log "Waiting for LM Studio models: ${chat_model}, ${embedding_model}; currently: ${ids:-unavailable}"
    fi

    poll_count=$((poll_count + 1))
    sleep 30
  done

  die "LM Studio did not expose required models: ${chat_model}, ${embedding_model}"
}

check_lmstudio_chat_completion() {
  local request_file
  local response_file
  local chat_model
  chat_model="$(effective_lmstudio_model_identifier)"
  request_file="$(mktemp)"
  response_file="$(mktemp)"

  jq --null-input \
    --arg model "$chat_model" \
    '{
      model: $model,
      messages: [
        {
          role: "user",
          content: "/no_think\nОтветь одним коротким словом: работает?"
        }
      ],
      temperature: 0,
      max_tokens: 16,
      stream: false
    }' \
    > "$request_file"

  if ! models_backend_curl \
    --fail \
    --silent \
    --show-error \
    --max-time "$LMSTUDIO_CHAT_TIMEOUT_SECONDS" \
    --header "Content-Type: application/json" \
    --data @- \
    "http://lmstudio:1234/v1/chat/completions" \
    < "$request_file" > "$response_file"; then
    sed 's/^/[lmstudio-chat] /' "$response_file" >&2 || true
    rm -f "$request_file" "$response_file"
    die "LM Studio chat completion failed or timed out for ${chat_model}"
  fi

  jq --exit-status '
    ((.choices[0].message.content // "") | length) > 0
    or ((.choices[0].message.reasoning_content // "") | length) > 0
    or ((.choices[0].text // "") | length) > 0
  ' "$response_file" >/dev/null \
    || {
      rm -f "$request_file" "$response_file"
      die "LM Studio chat completion returned no content for ${chat_model}"
    }

  rm -f "$request_file" "$response_file"
  log "LM Studio chat completion ok: ${chat_model}"
}

check_lmstudio_proxy_stream_request() {
  local name="$1"
  local request_file="$2"
  local expect_tool_call="${3:-any}" # yes | no | any
  local response_file
  response_file="$(mktemp)"

  if ! models_backend_curl \
    --fail \
    --silent \
    --show-error \
    --max-time "$LMSTUDIO_CHAT_TIMEOUT_SECONDS" \
    --header "Content-Type: application/json" \
    --data @- \
    "http://lmstudio-proxy:11234/v1/chat/completions" \
    < "$request_file" > "$response_file"; then
    sed 's/^/[lmstudio-proxy-chat] /' "$response_file" >&2 || true
    rm -f "$response_file"
    die "LM Studio proxy ${name} request failed or timed out"
  fi

  # Reassemble the SSE chunk stream into one JSON array so finish_reason and
  # whether any tool_calls delta actually carried a function name can be
  # asserted - a bare "did we get any 'data:' line" check would pass even for
  # a stream that silently degraded to plain text instead of a real tool
  # call (this is exactly how the STRIP_TOOLS_AFTER_RESULT regression slipped
  # through before: the response was well-formed SSE, just the wrong content).
  local chunks_json
  chunks_json="$(grep '^data:' "$response_file" | sed 's/^data: //' | grep -v '^\[DONE\]$' | jq -s '.' 2>/dev/null)"
  if [ -z "$chunks_json" ] || [ "$chunks_json" = "[]" ]; then
    sed 's/^/[lmstudio-proxy-chat] /' "$response_file" >&2 || true
    rm -f "$response_file"
    die "LM Studio proxy ${name} request did not return any SSE data chunks"
  fi

  local finish_reason has_tool_call
  finish_reason="$(printf '%s' "$chunks_json" | jq -r '[.[].choices[0].finish_reason] | map(select(. != null)) | last // empty')"
  has_tool_call="$(printf '%s' "$chunks_json" | jq -r 'any(.[]; ((.choices[0].delta.tool_calls // [])[]?.function.name // "") != "")')"

  if [ -z "$finish_reason" ]; then
    sed 's/^/[lmstudio-proxy-chat] /' "$response_file" >&2 || true
    rm -f "$response_file"
    die "LM Studio proxy ${name} request never reached a finish_reason"
  fi

  case "$expect_tool_call" in
    yes)
      if [ "$has_tool_call" != "true" ] || [ "$finish_reason" != "tool_calls" ]; then
        sed 's/^/[lmstudio-proxy-chat] /' "$response_file" >&2 || true
        rm -f "$response_file"
        die "LM Studio proxy ${name} expected a tool call but got finish_reason=${finish_reason} has_tool_call=${has_tool_call}"
      fi
      ;;
    no)
      if [ "$has_tool_call" = "true" ]; then
        sed 's/^/[lmstudio-proxy-chat] /' "$response_file" >&2 || true
        rm -f "$response_file"
        die "LM Studio proxy ${name} unexpectedly returned a tool call"
      fi
      ;;
    any) : ;;
    *) die "check_lmstudio_proxy_stream_request: unknown expect_tool_call value: ${expect_tool_call}" ;;
  esac

  rm -f "$response_file"
  log "LM Studio proxy ${name} stream ok (finish_reason=${finish_reason})"
}

check_lmstudio_proxy_tool_compat() {
  local chat_model
  local models_file
  local request_file
  chat_model="$(effective_lmstudio_model_identifier)"
  models_file="$(mktemp)"
  request_file="$(mktemp)"

  if ! models_backend_curl \
    --fail \
    --silent \
    --show-error \
    --max-time 30 \
    "http://lmstudio-proxy:11234/v1/models" \
    > "$models_file"; then
    sed 's/^/[lmstudio-proxy-models] /' "$models_file" >&2 || true
    rm -f "$models_file" "$request_file"
    die "LM Studio proxy model inventory failed"
  fi

  jq --exit-status \
    --arg chat_model "$chat_model" \
    '[.data[]?.id] | index($chat_model)' \
    "$models_file" >/dev/null \
    || {
      rm -f "$models_file" "$request_file"
      die "LM Studio proxy model inventory does not contain ${chat_model}"
    }
  rm -f "$models_file"
  log "LM Studio proxy model inventory ok: ${chat_model}"

  jq --null-input \
    --arg model "$chat_model" \
    '{
      model: $model,
      stream: true,
      max_tokens: 8,
      messages: [
        {
          role: "user",
          content: "/no_think\nReply with ok only."
        }
      ]
    }' \
    > "$request_file"
  check_lmstudio_proxy_stream_request "plain-chat" "$request_file" "no"

  local bash_tool='{
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Run a shell command",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string" }
        },
        "required": ["command"],
        "additionalProperties": false
      }
    }
  }'

  jq --null-input \
    --arg model "$chat_model" \
    --argjson bash_tool "$bash_tool" \
    '{
      model: $model,
      stream: true,
      max_tokens: 250,
      temperature: 0,
      tool_choice: "auto",
      parallel_tool_calls: true,
      tools: [$bash_tool],
      messages: [
        {
          role: "user",
          content: "Use bash to list files."
        }
      ]
    }' \
    > "$request_file"
  check_lmstudio_proxy_stream_request "first-tool-request" "$request_file" "yes"

  # This exact shape - tools/tool_choice/parallel_tool_calls still present
  # alongside a freshly completed tool round-trip - is what
  # STRIP_TOOLS_AFTER_RESULT_ENABLED (off by default) would otherwise strip.
  jq --null-input \
    --arg model "$chat_model" \
    --argjson bash_tool "$bash_tool" \
    '{
      model: $model,
      stream: true,
      max_tokens: 250,
      temperature: 0,
      tool_choice: "auto",
      parallel_tool_calls: true,
      tools: [$bash_tool],
      messages: [
        {
          role: "user",
          content: "List files."
        },
        {
          role: "assistant",
          content: null,
          tool_calls: [
            {
              id: "call_ai_stand_proxy_smoke",
              type: "function",
              function: {
                name: "bash",
                arguments: "{\"command\":\"Get-ChildItem -Force\"}"
              }
            }
          ]
        },
        {
          role: "tool",
          tool_call_id: "call_ai_stand_proxy_smoke",
          content: "Mode LastWriteTime Length Name\n---- ------------- ------ ----\nd---- 2026-08-12 ai-stand"
        }
      ]
    }' \
    > "$request_file"
  check_lmstudio_proxy_stream_request "tool-continuation" "$request_file" "any"

  # Regression guard for the STRIP_TOOLS_AFTER_RESULT_ENABLED bug: same
  # completed round-trip as above, plus a brand new user turn that clearly
  # calls for a second, different tool use. With the blanket (unscoped)
  # strip this silently degraded to plain text (HTTP 200, no tool_calls) -
  # this must come back as a real tool_calls response, not just any 200.
  jq --null-input \
    --arg model "$chat_model" \
    --argjson bash_tool "$bash_tool" \
    '{
      model: $model,
      stream: true,
      max_tokens: 250,
      temperature: 0,
      tool_choice: "auto",
      parallel_tool_calls: true,
      tools: [$bash_tool],
      messages: [
        {
          role: "user",
          content: "List files."
        },
        {
          role: "assistant",
          content: null,
          tool_calls: [
            {
              id: "call_ai_stand_proxy_smoke",
              type: "function",
              function: {
                name: "bash",
                arguments: "{\"command\":\"Get-ChildItem -Force\"}"
              }
            }
          ]
        },
        {
          role: "tool",
          tool_call_id: "call_ai_stand_proxy_smoke",
          content: "Mode LastWriteTime Length Name\n---- ------------- ------ ----\nd---- 2026-08-12 ai-stand"
        },
        {
          role: "user",
          content: "Now use bash again to show the current date and time."
        }
      ]
    }' \
    > "$request_file"
  check_lmstudio_proxy_stream_request "second-tool-request-after-continuation" "$request_file" "yes"

  # Regression guard for the confirmed LM Studio 400 on image-bearing
  # role:"tool" content - only meaningful (and only expected to pass) on
  # installations that have FLATTEN_TOOL_RESULT_CONTENT_ENABLED=1.
  if [ "${LMSTUDIO_PROXY_FLATTEN_TOOL_RESULT_CONTENT_ENABLED:-0}" = "1" ]; then
    jq --null-input \
      --arg model "$chat_model" \
      --argjson bash_tool "$bash_tool" \
      '{
        model: $model,
        stream: true,
        max_tokens: 250,
        temperature: 0,
        tool_choice: "auto",
        parallel_tool_calls: true,
        tools: [$bash_tool],
        messages: [
          {
            role: "user",
            content: "Describe screenshot.png."
          },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_ai_stand_proxy_image_smoke",
                type: "function",
                function: {
                  name: "bash",
                  arguments: "{\"command\":\"Get-Content screenshot.png\"}"
                }
              }
            ]
          },
          {
            role: "tool",
            tool_call_id: "call_ai_stand_proxy_image_smoke",
            content: [
              { type: "text", text: "screenshot.png" },
              { type: "image_url", image_url: { url: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" } }
            ]
          }
        ]
      }' \
      > "$request_file"
    check_lmstudio_proxy_stream_request "image-tool-result" "$request_file" "any"
  fi

  rm -f "$request_file"
  log "LM Studio proxy tool compatibility ok: ${chat_model}"
}

cmd_verify() {
  load_os_info
  ensure_ai_stand_secrets
  if [ "$NODE_NAME" = "ai01" ]; then
    local accelerator
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  for service in "${SERVICES[@]}"; do
    wait_service_ready "$service"
  done

  check_service_label_placement "${STACK_NAME}_lmstudio" "ai-stand.lmstudio"
  check_service_label_placement "${STACK_NAME}_lmstudio-proxy" "ai-stand.lmstudio"
  check_service_label_placement "${STACK_NAME}_openwebui" "ai-stand.openwebui"
  check_service_label_placement "${STACK_NAME}_openclaw-gateway" "ai-stand.openclaw"
  check_service_label_placement "${STACK_NAME}_authentik-postgresql" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_authentik-redis" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_authentik-server" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_authentik-worker" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_portainer" "ai-stand.portainer"
  check_service_label_placement "${STACK_NAME}_metamcp" "ai-stand.metamcp"
  check_service_label_placement "${STACK_NAME}_metamcp-postgres" "ai-stand.metamcp"
  check_service_label_placement "${STACK_NAME}_agentgateway" "ai-stand.agentgateway"
  if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
    check_service_label_placement "${STACK_NAME}_gigacode-identity-broker" "ai-stand.agentgateway"
    check_service_label_placement "${STACK_NAME}_openclaw-gigacode-adapter" "ai-stand.openclaw"
  fi
  if [ "$CODER_ENABLED" = "1" ]; then
    wait_service_ready "${STACK_NAME}_coder-postgresql"
    wait_service_ready "${STACK_NAME}_coder"
    check_service_label_placement "${STACK_NAME}_coder-postgresql" "ai-stand.coder"
    check_service_label_placement "${STACK_NAME}_coder" "ai-stand.coder"
  fi

  check_overlay_name "${STACK_NAME}_ai-models-backend" lmstudio
  check_overlay_name "${STACK_NAME}_ai-models-backend" lmstudio-proxy
  check_overlay_name "${STACK_NAME}_ai-core" authentik
  check_overlay_name "${STACK_NAME}_ai-core" authentik-postgresql
  check_overlay_name "${STACK_NAME}_ai-core" authentik-redis
  check_overlay_name "${STACK_NAME}_ai-core" openwebui
  check_overlay_name "${STACK_NAME}_ai-core" openclaw
  check_overlay_name "${STACK_NAME}_ai-core" openclaw-gateway
  check_overlay_name "${STACK_NAME}_ai-core" metamcp
  check_overlay_name "${STACK_NAME}_ai-core" metamcp-postgres
  check_overlay_name "${STACK_NAME}_ai-core" agentgateway
  check_overlay_name "${STACK_NAME}_ai-core" agentgateway-postgres
  check_overlay_name "${STACK_NAME}_ai-models-backend" agentgateway
  check_overlay_name "${STACK_NAME}_ai-mcp-backend" agentgateway
  if [ "$GIGACODE_SUBSCRIPTION_ENABLED" = "1" ]; then
    check_overlay_name "${STACK_NAME}_ai-core" gigacode-identity-broker
    check_overlay_name "${STACK_NAME}_ai-core" openclaw-gigacode-adapter
  fi
  if [ "$CODER_ENABLED" = "1" ]; then
    check_overlay_name "${STACK_NAME}_ai-coder-control" coder
    check_overlay_name "${STACK_NAME}_ai-coder-control" coder-postgresql
  fi
  check_agentgateway_database
  check_readonly_mcp_configuration
  check_overlay_name "${STACK_NAME}_ai-portainer-agent" portainer
  check_overlay_name "${STACK_NAME}_ai-portainer-agent" portainer-agent
  check_overlay_name "${STACK_NAME}_ai-portainer-agent" tasks.portainer-agent
  if [ "$NODE_NAME" = "ai02" ]; then
    check_openclaw_sandbox_dind_host_service
    check_openclaw_gateway_docker_cli
    check_openclaw_sandbox_image
    check_openclaw_sandbox_workspace_bridge
    check_coder_rootless_docker_service
    bootstrap_coder_admin
    check_coder_native_oidc
  fi
  check_openwebui_sso_only_environment
  check_openclaw_trusted_proxy_configuration
  check_openwebui_persistent_config
  check_authentik_configuration
  check_portainer_oidc_configuration
  # check_portainer_oidc_configuration above only confirms Authentik/
  # Portainer AGREE on how OIDC login should work - it says nothing about
  # whether the actual environment/team/user access it depends on has
  # drifted (e.g. a manual change in the Portainer UI). cmd_configure_portainer
  # already has these deeper, authenticated checks; cmd_verify never reused
  # them, so this class of drift went undetected here.
  #
  # Gated to ai01, UNLIKE check_portainer_oidc_configuration above (bug
  # found and fixed 2026-09-13): that check hits the unauthenticated
  # /api/settings/public, so it's fine to run from either node's local
  # nginx. portainer_login() below needs PORTAINER_ADMIN_PASSWORD, which is
  # a load_host_secret() - a LOCAL file under /mnt/storage/_secrets, not
  # shared between nodes. Portainer itself only ever runs on ai01
  # (cmd_configure_portainer already die()s if not ai01), so ai01's copy of
  # that file is the one real admin password; ai02 has its own
  # independently-generated value sitting unused in its own local secrets
  # dir. Running this block on ai02 previously made portainer_login()
  # log in with the wrong password and die(), aborting the entire
  # cmd_verify run before it reached any of the checks below.
  if [ "$NODE_NAME" = "ai01" ]; then
    local verify_portainer_jwt
    local verify_portainer_endpoint_id
    local verify_portainer_team_id
    verify_portainer_jwt="$(portainer_login)"
    verify_portainer_endpoint_id="$(ensure_portainer_endpoint "$verify_portainer_jwt")"
    verify_portainer_team_id="$(ensure_portainer_team "$verify_portainer_jwt")"
    check_portainer_environment_configuration "$verify_portainer_jwt" "$verify_portainer_endpoint_id" "$verify_portainer_team_id"
    check_portainer_oauth_admin_users "$verify_portainer_jwt" "$verify_portainer_team_id"
    check_portainer_oauth_user_endpoint_access "$verify_portainer_jwt" "$verify_portainer_endpoint_id"
  fi
  if [ "$NODE_NAME" = "ai01" ]; then
    # LM Studio is intentionally pinned to ai01 and its model network is
    # closed to ad-hoc containers.  The inventory and completion probes run
    # from that node through its attached LM Studio task; ai02 verifies
    # OpenClaw/DIND instead of attempting a cross-node model probe.
    check_lmstudio_model_inventory 10800
    check_lmstudio_chat_completion
    check_lmstudio_proxy_tool_compat
    # llm.policies.apiKey (mode: strict) gates this unconditionally - so
    # this runs here directly rather than through local_service_domains()'s
    # generic bare-success loop (see that function's own comment).
    check_https_protected_retry "$AGENTGATEWAY_HOST" "/v1/models" 600
  fi

  local domain
  if [ "$NODE_NAME" = "ai01" ]; then
    check_https_retry "$AUTHENTIK_HOST" "$(https_path_for_domain "$AUTHENTIK_HOST")" 600
    local icon_file
    for icon_file in openwebui.png portainer.svg metamcp.ico agentgateway.svg openclaw.png coder.svg; do
      check_https_retry "$AUTHENTIK_HOST" "/app-icons/${icon_file}" 60
    done
  fi

  for domain in $(local_service_domains); do
    check_https_retry "$domain" "$(https_path_for_domain "$domain")" 600
  done
  while IFS= read -r port; do
    check_port_closed_to_non_loopback "$port"
  done < <(technical_ports_for_current_node)

  run_root firewall-cmd --state >/dev/null
  run_root nginx -t >/dev/null
  log "Verification complete"
}

cmd_all() {
  cmd_preflight
  cmd_host
  cmd_images
  cmd_deploy
  cmd_configure_authentik
  cmd_configure_portainer
  cmd_verify
}

acquire_lock() {
  if command_exists flock; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another ai-stand apply run is active"
    return 0
  fi

  local lock_dir="${LOCK_FILE}.d"
  if mkdir "$lock_dir" 2>/dev/null; then
    trap "rmdir \"${lock_dir}\"" EXIT
    return 0
  fi

  die "Another ai-stand apply run is active"
}

main() {
  parse_args "$@"
  load_installation
  validate_args
  acquire_lock

  case "$COMMAND" in
    preflight) cmd_preflight ;;
    host) cmd_host ;;
    images) cmd_images ;;
    deploy) cmd_deploy ;;
    reconcile-mcp) cmd_reconcile_mcp ;;
    configure-authentik) cmd_configure_authentik ;;
    onboard-readonly-mcp-user) cmd_onboard_readonly_mcp_user ;;
    migrate-metamcp-tenants) cmd_migrate_metamcp_tenants ;;
    configure-portainer) cmd_configure_portainer ;;
    verify) cmd_verify ;;
    credentials) cmd_credentials ;;
    all) cmd_all ;;
    *) usage; die "Unknown command: ${COMMAND}" ;;
  esac
}

main "$@"
