#!/usr/bin/env bash

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

STACK_NAME="ai-stand"
READ_ONLY_VERIFY="0"
# Fixed by the images (the users they are built with), llamacpp/runtime.py and verify; not an installation value.
IM_UID="10000"
IM_GID="20000"
# Time zone of every service and of both hosts. The generic default is UTC; an installation profile overrides it with its own
# IM_TZ.
IM_TZ="UTC"
APP_UID="$IM_UID"
APP_GID="$IM_GID"

IMAGE_VERSION="2026.10.13-1"
BASE_IMAGE="ghcr.io/simpleunion/base:${IMAGE_VERSION}"
LLAMACPP_IMAGE_VERSION="2026.10.13-1"
LLAMACPP_CPU_IMAGE="ghcr.io/kukurusik/ai-stand-llamacpp:${LLAMACPP_IMAGE_VERSION}-cpu"
# Filled after the installation profile provides each node's GFX. There is
# deliberately no shared mutable AMD tag across incompatible architectures.
LLAMACPP01_AMD_IMAGE=""
LLAMACPP02_AMD_IMAGE=""
LLAMACPP_NVIDIA_IMAGE="ghcr.io/kukurusik/ai-stand-llamacpp:${LLAMACPP_IMAGE_VERSION}-nvidia"
# The OpenClaw image contains a version-pinned trusted-proxy patch that
# renders a display-only Authentik name.  Bump the shared rebuilt tag so a
# Swarm deployment cannot silently reuse the old image after the Dockerfile
# changes.
REBUILT_IMAGE_VERSION="2026.10.21-2"
# The configure-authentik script is baked into its own image. Changing only that
# script must not force a rebuild and restart of the Authentik server image, so
# its tag is bumped independently (same reasoning as OPENCLAW_IMAGE_VERSION).
AUTHENTIK_CONFIGURATOR_IMAGE_VERSION="2026.10.24-1"
# The Gitea SSH-key synchronizer (docker/gitea-ssh-sync) is a small Python
# service of its own; bump this whenever sync.py or its Dockerfile changes.
GITEA_SSH_SYNC_IMAGE_VERSION="2026.10.24-2"
# The SSH private-key delivery (docker/ssh-key-delivery) bundles docker/gitea-ssh-sync/sync.py; bump this whenever
# delivery.py, that sync.py or the Dockerfile changes.
SSH_KEY_DELIVERY_IMAGE_VERSION="2026.10.24-3"
# The controller (docker/controller) runs the recurring jobs that used to be host systemd timers: the MCP/Telegram
# reconciler, the Open WebUI model-access reconciler and the certificate renewal; the same image is the certificate
# receiver on the other node. Bump this whenever controller.py, certbot/*.sh or its Dockerfile changes.
CONTROLLER_IMAGE_VERSION="2026.10.24-2"
# OpenClaw contains version-pinned runtime patches and needs an independent
# tag bump whenever its image changes.  Keeping this separate avoids
# needlessly rebuilding the unrelated Authentik image.
OPENCLAW_IMAGE_VERSION="2026.10.25-1"
READONLY_MCP_IMAGE_VERSION="2026.10.13-1"
# Bump together with both C# and Python Terraform templates: their image
# literals cannot interpolate this shell variable.
CODER_WORKSPACE_IMAGE_VERSION="2026.10.21-1"
CODER_VERSION="2.38.0"
GITEA_VERSION="28.1.0"
GITEA_IMAGE="docker.gitea.com/gitea:${GITEA_VERSION}-rootless"
POSTGRES_IMAGE="docker.io/library/postgres:18.6-alpine"
GITEA_POSTGRES_IMAGE="$POSTGRES_IMAGE"
# OpenClaw's trusted-proxy patch below is version-pinned and verified
# against the exact 2026.10.2 npm payload. Keep the upstream version and the
# image tag together: a later package must fail the build until its source
# hashes and single-occurrence snippets are reviewed again.
OPENCLAW_VERSION="2026.10.2"
AUTHENTIK_VERSION="2026.8.3"
OPENCLAW_IMAGE="ghcr.io/kukurusik/ai-stand-openclaw:${OPENCLAW_IMAGE_VERSION}"
# 2.45.2 LTS includes the fixes from 2.45.1 for Critical CVEs (openssl/libssl3: CVE-2026-63073,
# CVE-2026-75803; kubectl: CVE-2026-39821), confirmed against the upstream
# release notes 2026-09-23.
PORTAINER_IMAGE="portainer/portainer-ce:2.45.2"
PORTAINER_AGENT_IMAGE="portainer/agent:2.45.2"
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:v0.12.3"
AUTHENTIK_IMAGE="ghcr.io/kukurusik/ai-stand-authentik:${REBUILT_IMAGE_VERSION}"
AUTHENTIK_POSTGRES_IMAGE="$POSTGRES_IMAGE"
AUTHENTIK_REDIS_IMAGE="docker.io/library/redis:8.10.2-alpine"
# LLM gateway in front of the transport-only model proxies. Its admin console
# uses OIDC/RBAC; its LLM API uses per-service bearer tokens. An opt-in
# profile additionally renders identity-scoped read-only MCP routes here.
AGENTGATEWAY_IMAGE="cr.agentgateway.dev/agentgateway:v1.6.0"
# Coder is an upstream image. ai-stand builds a tiny local wrapper so its
# PostgreSQL and OIDC secrets stay mounted files rather than service env.
# Image identities are pinned by version tag only, not by registry digest.
CODER_BASE_IMAGE="ghcr.io/coder/coder:v${CODER_VERSION}"
CODER_IMAGE="ai-stand-coder:${CODER_VERSION}-1"
CODER_POSTGRES_IMAGE="$POSTGRES_IMAGE"
AGENTGATEWAY_POSTGRES_IMAGE="$POSTGRES_IMAGE"
DOCKER_SOCKET_PROXY_IMAGE="ghcr.io/tecnativa/docker-socket-proxy:v0.5.0"
# The two non-published Coder workspace images are built locally on ai02.
# They have distinct C# and Python tags; neither image contains a Docker
# daemon or receives a Docker socket.
CODER_CSHARP_WORKSPACE_IMAGE="ai-stand-coder-workspace-csharp:${CODER_WORKSPACE_IMAGE_VERSION}"
CODER_PYTHON_WORKSPACE_IMAGE="ai-stand-coder-workspace-python:${CODER_WORKSPACE_IMAGE_VERSION}"
AUTHENTIK_CONFIGURATOR_IMAGE="ghcr.io/kukurusik/ai-stand-authentik-configurator:${AUTHENTIK_CONFIGURATOR_IMAGE_VERSION}"
GITEA_SSH_SYNC_IMAGE="ghcr.io/kukurusik/ai-stand-gitea-ssh-sync:${GITEA_SSH_SYNC_IMAGE_VERSION}"
SSH_KEY_DELIVERY_IMAGE="ghcr.io/kukurusik/ai-stand-ssh-key-delivery:${SSH_KEY_DELIVERY_IMAGE_VERSION}"
CONTROLLER_IMAGE="ghcr.io/kukurusik/ai-stand-controller:${CONTROLLER_IMAGE_VERSION}"
JIRA_READONLY_MCP_IMAGE="ai-stand-jira-readonly-mcp:${READONLY_MCP_IMAGE_VERSION}"
CONFLUENCE_READONLY_MCP_IMAGE="ai-stand-confluence-readonly-mcp:${READONLY_MCP_IMAGE_VERSION}"
IMAP_READONLY_MCP_IMAGE="ai-stand-imap-readonly-mcp:${READONLY_MCP_IMAGE_VERSION}"
DIAGNOSTIC_IMAGE="ghcr.io/kukurusik/ai-stand-diagnostic:${IMAGE_VERSION}"

AMD_AMDGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/31.60/ubuntu/resolute/amdgpu-install_31.60.316000-1_all.deb"
AMD_AMDGPU_INSTALL_SHA256="aa11c1f098abc64a9da05c0ad6eaea523787a39780513a72baceb857fc123f10"
AMD_ROCM_APT_CODENAME="resolute"
AMD_CONTAINER_TOOLKIT_KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"
AMD_CONTAINER_TOOLKIT_REPO_URL="https://repo.radeon.com/amd-container-toolkit/apt/"
# ROCm compute-library release line (stable.repo.amd.com's "amdrocm<release>-gfx<gfx>"
# package scheme - see ensure_amd_driver()). AMD_ROCM_GFX_VERSION has no default;
# each installation profile must set it per node to that node's actual GPU.
AMD_ROCM_RELEASE="10.1"
AMD_ROCM_GFX_VERSION="${AMD_ROCM_GFX_VERSION:-}"
NGINX_VERSION="1.30.6"
NGINX_SIGNING_FINGERPRINT="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
NVIDIA_CONTAINER_TOOLKIT_KEY_URL="https://nvidia.github.io/libnvidia-container/gpgkey"
NVIDIA_CONTAINER_TOOLKIT_LIST_URL="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"

# --- storage layout -----------------------------------------------------------------------------------------------------
# Every component keeps its data in <storage root>/<component>-data/<part>, and the storage root is a property of the
# installation: STORAGE_ROOT in its profile (installation.sh). No path under it is spelled out anywhere else - the compose
# files, the nginx sites, the wrapper and the Python helpers all receive it from here (STORAGE_ROOT is exported, and
# apply.sh renders the nginx sites with it). define_storage_paths() derives every path; it runs once now with the default
# root, for anything that runs before a profile is loaded, and again in load_installation() after the profile is sourced.
STORAGE_ROOT="/mnt/storage"
# A profile input (the certificate directory of its domain); empty takes the default under CERTBOT_DATA.
CERT_DIR=""

define_storage_paths() {
  [[ "$STORAGE_ROOT" =~ ^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ ]] && [[ "$STORAGE_ROOT" != *..* ]] \
    || die "STORAGE_ROOT must be an absolute path without a trailing slash"
  export STORAGE_ROOT
  LLAMACPP_DATA_ROOT="${STORAGE_ROOT}/llamacpp-data"
  OPENCLAW_DATA_ROOT="${STORAGE_ROOT}/openclaw-data"
  OPENWEBUI_DATA_ROOT="${STORAGE_ROOT}/openwebui-data"
  AUTHENTIK_DATA="${STORAGE_ROOT}/authentik-data"
  # authentik-server and authentik-worker share both subdirectories below -
  # "server" names the role (matching openwebui/portainer's own single-app
  # "server" role), not the file type - data/templates aren't a role of their
  # own the way postgresql/redis are (see ensure_authentik_data()).
  AUTHENTIK_DATA_SERVER="${AUTHENTIK_DATA}/server"
  AUTHENTIK_ICONS_DATA="${AUTHENTIK_DATA}/icons"
  PORTAINER_DATA_ROOT="${STORAGE_ROOT}/portainer-data"
  AGENTGATEWAY_DATA_ROOT="${STORAGE_ROOT}/agentgateway-data"
  # Reconciler state is deliberately separate from agentgateway-data: only a
  # root-owned host timer may read its API-token files, generate Docker Secrets
  # or alter the dynamic MCP manifest. The running gateway sees only its
  # rendered config and explicitly mounted backend bearer secrets.
  READONLY_MCP_DATA_ROOT="${STORAGE_ROOT}/readonly-mcp-data"
  # Installation-specific deployment overrides deliberately live outside the
  # source tree. They are not an environment-file include: the loader below
  # accepts one exact key/value record only, so a root-local override cannot
  # execute arbitrary shell while apply.sh is running as root.
  AI_STAND_DATA_ROOT="${STORAGE_ROOT}/ai-stand-data"
  INSTALLATION_OVERRIDES_ROOT="${AI_STAND_DATA_ROOT}/installation-overrides"
  READONLY_MCP_RUNTIME_OVERRIDE_FILE="${INSTALLATION_OVERRIDES_ROOT}/readonly-mcp.env"
  CODER_DATA_ROOT="${STORAGE_ROOT}/coder-data"
  # Written by the ssh-key-receiver (docker/ssh-key-delivery): users/<login> is bind-mounted read-only into that member's
  # Coder workspaces, services/<name> into that service (the OpenClaw Gateway mounts services/openclaw; compose.yaml, so it
  # always exists). Directories 0700 and files 0400, owned by the workspace identity.
  SSH_KEY_DELIVERY_DATA_ROOT="${STORAGE_ROOT}/ssh-key-delivery-data"
  SSH_KEYS_ROOT="${SSH_KEY_DELIVERY_DATA_ROOT}/users"
  SSH_SERVICE_KEYS_ROOT="${SSH_KEY_DELIVERY_DATA_ROOT}/services"
  LLAMACPP01_DATA="${LLAMACPP_DATA_ROOT}/llamacpp01"
  LLAMACPP02_DATA="${LLAMACPP_DATA_ROOT}/llamacpp02"
  OPENCLAW_DATA="${OPENCLAW_DATA_ROOT}/gateway"
  OPENCLAW_DOCKER_SANDBOX_WORKSPACE_ROOT="${OPENCLAW_DATA_ROOT}/sandboxes"
  OPENWEBUI_DATA="${OPENWEBUI_DATA_ROOT}/server"
  PORTAINER_DATA="${PORTAINER_DATA_ROOT}/server"
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
  GITEA_DATA_ROOT="${STORAGE_ROOT}/gitea-data"
  GITEA_SERVER_DATA="${GITEA_DATA_ROOT}/gitea/data"
  GITEA_CONFIG_DATA="${GITEA_DATA_ROOT}/gitea/config"
  GITEA_POSTGRES_DATA="${GITEA_DATA_ROOT}/gitea/postgres"
  GITEA_BACKUPS_DATA="${GITEA_DATA_ROOT}/gitea/backups"
  LEGACY_GITLAB_DATA_ROOT="${STORAGE_ROOT}/gitlab-data"
  BACKUP_ROOT="${STORAGE_ROOT}/_backups"
  LEGACY_GITLAB_ARCHIVE_ROOT="${BACKUP_ROOT}/gitlab-retired"
  NGINX_BACKUP_DIR="${BACKUP_ROOT}/nginx"
  # ensure_ai_stand_secrets() generates and persists each secret under this directory on first use.
  AI_STAND_SECRETS_DIR="${STORAGE_ROOT}/_secrets"
  CERTBOT_DATA="${STORAGE_ROOT}/certbot-data"
  CERT_DIR="${CERT_DIR:-${CERTBOT_DATA}/live/local}"
  CODER_TEMPLATE_PUBLISHER_TOKEN_FILE="${AI_STAND_SECRETS_DIR}/coder-template-publisher-token"
  OPENWEBUI_MODEL_ACCESS_CONFIG="${AI_STAND_DATA_ROOT}/identity/openwebui-model-access.json"
  READONLY_MCP_RECONCILER_DATA="${READONLY_MCP_DATA_ROOT}/reconciler"
  READONLY_MCP_MANIFEST="${READONLY_MCP_RECONCILER_DATA}/manifest.json"
  READONLY_MCP_RECONCILER_CONFIG="${READONLY_MCP_RECONCILER_DATA}/reconciler.json"
  READONLY_MCP_RENDERED_COMPOSE="${AGENTGATEWAY_DATA}/readonly-mcp.compose.yaml"
}
define_storage_paths

# name=Authentik username[,...]: services (not people) with a dedicated SSH key. The Authentik account holds the key in the
# attributes of a person's key (generated by configure-ssh-key-delivery when it has none), the delivery puts it in
# services/<name>, and the Gitea synchronizer registers its public half in the Gitea account of the same name.
SSH_SERVICE_ACCOUNTS="${SSH_SERVICE_ACCOUNTS:-openclaw=ai-stand-openclaw-bot}"
GITEA_HOST="${GITEA_HOST:-gitea.local}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
CERT_DOMAIN="local"

AI01_HOST="ai01.local"
AI02_HOST="ai02.local"
OPENWEBUI_HOST="openwebui.local"
OPENCLAW_HOST="openclaw.local"
OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED="0"
OPENCLAW_TRUSTED_PROXIES="127.0.0.1,::1"
PORTAINER_HOST="portainer.local"
AUTHENTIK_HOST="authentik.local"
AGENTGATEWAY_HOST="agentgateway.local"
CODER_HOST="coder.local"
GITEA_HOST="${GITEA_HOST:-gitea.local}"

LLAMACPP_MODEL_IDENTIFIER="qwen/qwen3-1.7b"
LLAMACPP_EMBEDDING_MODEL_IDENTIFIER="qwen3-embedding-0.6b"
# Verification budget only; this never changes service/provider timeouts.
# Busy installations can supply a longer bounded budget for queued probes.
LLAMACPP_CHAT_TIMEOUT_SECONDS="${LLAMACPP_CHAT_TIMEOUT_SECONDS:-300}"

AUTHENTIK_SECRET_KEY_SECRET="ai-stand-authentik-secret-key"
AUTHENTIK_POSTGRES_PASSWORD_SECRET="ai-stand-authentik-postgres-password"
# AUTHENTIK_BOOTSTRAP_TOKEN, AUTHENTIK_OPENWEBUI_CLIENT_SECRET,
# AUTHENTIK_PORTAINER_CLIENT_SECRET, AUTHENTIK_BOOTSTRAP_PASSWORD,
# PORTAINER_ADMIN_PASSWORD, WEBUI_SECRET_KEY, OPENCLAW_GATEWAY_TOKEN,
# are not literals:
# ensure_ai_stand_secrets() generates and persists each one under
# AI_STAND_SECRETS_DIR on first use and reuses it on every later run.
# (AI_STAND_SECRETS_DIR is derived in define_storage_paths.)
# The controller container (ai01) and, with CERTBOT_RECEIVER_ENABLED, the cert-receiver on the other node.
CONTROLLER_ENABLED="1"
# Ceiling the model selector may pick the chat context from; empty means LLAMACPP_CHAT_CONTEXT_LENGTH.
LLAMACPP_CHAT_POLICY_MAX_CONTEXT=""
# 1: a full deploy needs the model migration controller's completion receipt for the selected embedding model first
# (model-migrate-q4, see the installation's apply-model-profile.sh) and points OpenClaw's memory at its generation.
MODEL_MIGRATION_REQUIRED="0"
# Automatic wildcard certificate: DNS-01 through an installation-provided hook,
# renewed by the controller container on ai01 and handed to ai02's cert-receiver
# (see certbot/README.md). Off by default; an installation turns it on and names
# its DNS provider's pieces.
CERTBOT_ENABLED="0"
CERTBOT_IMAGE="docker.io/certbot/certbot:v5.7.0"
CERTBOT_EMAIL=""
# (CERTBOT_DATA is derived in define_storage_paths.)
# File name under AI_STAND_SECRETS_DIR holding the DNS API credentials (env-file format).
CERTBOT_CREDENTIALS_NAME=""
# DNS hook script, relative to the installation directory (mounted into the certbot container as /hooks).
CERTBOT_HOOK_SOURCE=""
# 1 when the other node runs a cert-receiver service that gets every renewed certificate over the encrypted overlay
# network (bearer token from a Docker secret). 0: no hand-over.
CERTBOT_RECEIVER_ENABLED="0"
AUTHENTIK_BOOTSTRAP_USERNAME="akadmin"
PORTAINER_ADMIN_USERNAME="admin"
# Bootstrap-only Coder owner, created non-interactively via `coder server
# create-admin-user` (see bootstrap_coder_admin()) so the native /setup
# password form - which CODER_DISABLE_PASSWORD_AUTH=true breaks, since it
# can never be submitted once password auth is off - never needs to run.
# Real day-to-day access is still Authentik OIDC (ai-admins -> owner via
# CODER_OIDC_USER_ROLE_MAPPING); this is only the emergency/first-boot
# account, same role as akadmin for Authentik. {component}@ai-stand.local,
# not a shared admin@ai-stand.local: an OIDC login whose email already belongs
# to a same-app password account gets rejected (confirmed live 2026-09-09).
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
# llama.cpp deliberately has no host-published ports. Its API is reachable
# only from Agentgateway on ai-models-backend;
# the remaining entries below are loopback technical listeners protected by
# the host firewall.
TECH_PORTS=(18789 9443 18080 19001 9001 4000 17080 18082)
PUBLIC_PORTS=(80 443)
SWARM_TCP_PORTS=(2377 7946)
SWARM_UDP_PORTS=(7946 4789)
SERVICES=(
  "ai-stand_authentik-postgresql"
  "ai-stand_authentik-redis"
  "ai-stand_authentik-server"
  "ai-stand_authentik-worker"
  "ai-stand_llamacpp01"
  "ai-stand_llamacpp02"
  "ai-stand_openclaw-gateway"
  "ai-stand_docker-socket-proxy-openclaw"
  "ai-stand_openwebui"
  "ai-stand_portainer"
  "ai-stand_portainer-agent"
  "ai-stand_agentgateway-postgres"
  "ai-stand_agentgateway"
)
OBSOLETE_SERVICES=(
  "ai-stand_shannon"
  "ai-stand_lightrag"
  # This was an old, external Coder provisioner. Current Coder uses its
  # built-in provisioner through docker-socket-proxy-coder; external
  # provisioners are deliberately not part of the deployment.
  "ai-stand_coder-provisioner"
  # The owner-aware mTLS Docker broker was retired together with per-user
  # Coder workspace isolation (2026-10-21); Coder is back on the socket proxy.
  "ai-stand_docker-lifecycle-broker-coder"
  "ai-stand_coder-postgres"
  "ai-stand_coder"
  "ai-stand_openclaw-sandbox-main"
  "ai-stand_openclaw-sandbox-codex"
  "ai-stand_openclaw-sandbox-claude"
  "ai-stand_gitlab"
  "ai-stand_gitlab-access-reconciler"
  # Transport-only proxies in front of llama.cpp, removed 2026-10-23:
  # Agentgateway now talks to llamacpp01/llamacpp02 directly and itself owns
  # the model allow-list (explicit llm.models, no wildcard).
  "ai-stand_model-chat-proxy"
  "ai-stand_model-embeddings-proxy"
  # MetaMCP and its database, removed 2026-10-23 (no registered servers, no
  # MCP traffic; user-facing MCP is served by Agentgateway routes).
  "ai-stand_metamcp"
  "ai-stand_metamcp-postgres"
)

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  */*) SCRIPT_DIR="$(cd -- "${SCRIPT_PATH%/*}" && pwd)" ;;
  *) SCRIPT_DIR="$(pwd)" ;;
esac

COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"
COMPOSE_AMD_FILE="${SCRIPT_DIR}/compose.amd.yaml"
COMPOSE_NVIDIA_FILE="${SCRIPT_DIR}/compose.nvidia.yaml"
COMPOSE_CODER_FILE="${SCRIPT_DIR}/compose.coder.yaml"
COMPOSE_GITEA_FILE="${SCRIPT_DIR}/compose.gitea.yaml"
COMPOSE_CONTROLLER_FILE="${SCRIPT_DIR}/compose.controller.yaml"
# Only with the file above, and only for deploy-controller, which deploys it alone (the generic deploy gets the networks
# from compose.yaml).
COMPOSE_CONTROLLER_STANDALONE_FILE="${SCRIPT_DIR}/compose.controller-standalone.yaml"
# Deployed alone by configure-gitea-ssh-sync, never combined with the files above.
COMPOSE_GITEA_SSH_SYNC_FILE="${SCRIPT_DIR}/compose.gitea-ssh-sync.yaml"
# Deployed alone by configure-ssh-key-delivery, never combined with the files above.
COMPOSE_SSH_KEY_DELIVERY_FILE="${SCRIPT_DIR}/compose.ssh-key-delivery.yaml"
# ai-stand consumes separately versioned source modules but builds their
# images locally. Deployment stages them next to the ai-stand checkout.
AI_STAND_MODULES_ROOT="${AI_STAND_MODULES_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
OPENWEBUI_MODEL_ACCESS_SOURCE_DIR="${SCRIPT_DIR}/docker/openwebui"
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
READONLY_MCP_RECONCILER="${SCRIPT_DIR}/readonly-mcp/reconcile.py"
CERTBOT_SOURCE_DIR="${SCRIPT_DIR}/certbot"
READONLY_MCP_ENABLED="0"
# Generic core publishes a neutral endpoint family. A protected host-local
# override may replace this only at deployment time; profile sources never
# carry organization-specific paths.
READONLY_MCP_PATH_PREFIX="/mcp/work"
CODER_ENABLED="0"
GITEA_ENABLED="0"
NGINX_CONF_SOURCE="${SCRIPT_DIR}/nginx/nginx.conf"
NGINX_MIME_TYPES_SOURCE="${SCRIPT_DIR}/nginx/mime.types"
NGINX_SITE_AI01_SOURCE="${SCRIPT_DIR}/nginx/conf.d/ai-stand-ai01.conf"
NGINX_SITE_AI02_SOURCE="${SCRIPT_DIR}/nginx/conf.d/ai-stand-ai02.conf"
NGINX_RESTART_DROPIN_SOURCE="${SCRIPT_DIR}/nginx/nginx-restart.conf"
NGINX_RELOAD_UNIT_SOURCE_DIR="${SCRIPT_DIR}/nginx"
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
# Under /run/lock, not /tmp: the controller container mounts the host's /run/lock, so a stage it runs and a stage the
# operator runs on the host exclude each other.
LOCK_FILE="${AI_STAND_LOCK_FILE:-/run/lock/ai-stand-apply.lock}"
REBOOT_MARKER="/var/lib/ai-stand/reboot-required"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
NGINX_BACKED_UP="0"
SWARM_RECOVERED="0"

COMMAND="all"
COMMAND_SET="0"
CREDENTIALS_ACTION=""
CREDENTIALS_NAME=""
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
Usage: $0 [preflight|host|images|deploy-models|configure-model-routing|deploy|templates|reconcile-mcp|configure-authentik|configure-gitea|configure-gitea-ssh-sync|cleanup-legacy-gitea-ssh-sync|deploy-controller|configure-ssh-key-delivery|cleanup-legacy-host-timers|onboard-readonly-mcp-user|configure-portainer|verify|credentials|all] [options]

Commands:
  preflight              Check host prerequisites without changing state.
  host                   Install/configure host prerequisites, storage, TLS, firewall, Nginx and labels.
  images                 Build/pull required images for the selected accelerator.
  deploy-models          Submit only the four isolated model services, preserving consumer/control-plane state.
  configure-model-routing  Replace only Agentgateway model routing, preserving personal MCP routes during maintenance.
  deploy                 Validate and deploy the Swarm stack.
  templates              Idempotently publish the managed C# and Python Coder templates.
  reconcile-mcp          Apply an already rendered read-only MCP manifest; intended for the root-owned timer only.
  configure-authentik    Idempotently configure Authentik groups and OIDC applications.
  configure-gitea        Configure native Gitea OIDC after Authentik reconciliation.
  configure-gitea-ssh-sync  Issue the SSH-key synchronizer's credentials and deploy it (after configure-gitea).
  cleanup-legacy-gitea-ssh-sync  Remove the host-installed predecessor of the SSH-key synchronizer (after the service ran).
  deploy-controller      Deploy only the controller and cert-receiver services (the recurring jobs); nothing else changes.
  configure-ssh-key-delivery  Issue the SSH private-key delivery credentials and deploy it (Coder workspaces get their member's key).
  cleanup-legacy-host-timers  Remove the host timers and scripts the controller container replaced (after its jobs ran).
  onboard-readonly-mcp-user  Idempotently create (or verify) one Authentik user and its group membership.
  configure-portainer    Idempotently initialize Portainer admin and enable Authentik OAuth/OIDC.
  verify                 Verify services, routing and protection rules.
  credentials list       List known root-only generated credential files without values.
  credentials show NAME  Print one explicitly requested credential value to stdout.
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
  sudo bash apply.sh all --installation <installation> --node-name ai01 --host-ip <ai01-ip> --peer-ip <ai02-ip> --trusted-cidr <trusted-cidr> --accelerator auto
  sudo bash apply.sh host --installation <installation> --node-name ai02 --host-ip <ai02-ip> --peer-ip <ai01-ip> --trusted-cidr <trusted-cidr> --manager-join-token <token>
  sudo bash apply.sh images --installation <installation> --node-name ai02
  sudo bash apply.sh onboard-readonly-mcp-user --installation <installation> --node-name ai01 --username <username> --email <email> --groups ai-users
  sudo bash apply.sh credentials list --installation <installation>
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      preflight|host|images|deploy-models|configure-model-routing|deploy|templates|reconcile-mcp|configure-authentik|configure-gitea|configure-gitea-ssh-sync|cleanup-legacy-gitea-ssh-sync|deploy-controller|configure-ssh-key-delivery|cleanup-legacy-host-timers|onboard-readonly-mcp-user|configure-portainer|verify|credentials|all)
        if [ "$COMMAND_SET" = "1" ]; then
          die "Only one command can be specified"
        fi
        COMMAND="$1"
        COMMAND_SET="1"
        shift
        ;;
      list|show)
        [ "$COMMAND" = "credentials" ] && [ -z "$CREDENTIALS_ACTION" ] \
          || die "credentials accepts exactly one of: list, show <name>"
        CREDENTIALS_ACTION="$1"
        shift
        if [ "$CREDENTIALS_ACTION" = "show" ]; then
          [ "$#" -ge 1 ] || die "credentials show requires a credential name"
          CREDENTIALS_NAME="$1"
          shift
        fi
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
  if [ "$COMMAND" = "credentials" ]; then
    [ -n "$CREDENTIALS_ACTION" ] || CREDENTIALS_ACTION="list"
    [ "$#" -eq 0 ] || die "Unexpected arguments after credentials command"
  fi
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

# With a real certificate domain every public name must sit one label below it: the wildcard certificate covers nothing else.
# A name left at its ".local" default next to a real domain is the typical result of a half-edited profile.
validate_public_host_names() {
  [ "$CERT_DOMAIN" != "local" ] || return 0
  [[ "$CERT_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "CERT_DOMAIN must be a DNS domain name"
  local -a names=(AI01_HOST AI02_HOST OPENWEBUI_HOST OPENCLAW_HOST PORTAINER_HOST AUTHENTIK_HOST AGENTGATEWAY_HOST)
  [ "${CODER_ENABLED:-0}" != "1" ] || names+=(CODER_HOST)
  [ "${GITEA_ENABLED:-0}" != "1" ] || names+=(GITEA_HOST)
  local name value label
  for name in "${names[@]}"; do
    value="${!name}"
    label="${value%".${CERT_DOMAIN}"}"
    { [ "$label" != "$value" ] && [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; } \
      || die "${name} is '${value}'; with CERT_DOMAIN=${CERT_DOMAIN} it must be <name>.${CERT_DOMAIN} (set it in the installation profile)"
  done
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

  CERT_DIR=""
  # shellcheck disable=SC1090
  . "$installation_file"
  # A profile copied from another installation keeps that installation's name, and with it its storage and state paths.
  [ "${INSTALLATION_NAME:-}" = "$INSTALLATION" ] \
    || die "INSTALLATION_NAME in ${installation_file} is '${INSTALLATION_NAME:-}', it must equal the directory name '${INSTALLATION}'"
  define_storage_paths
  # The compose files take the time zone from here. The service identity is not an installation value: the images' users,
  # llamacpp/runtime.py and verify all assume 10000:20000.
  [ "${IM_UID:-}" = "10000" ] && [ "${IM_GID:-}" = "20000" ] || die "IM_UID and IM_GID are fixed by the images at 10000 and 20000"
  [[ "${IM_TZ:-}" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$ ]] || die "IM_TZ must be a time zone name such as Europe/Moscow"
  export IM_TZ
  validate_public_host_names

  validate_readonly_mcp_path_prefix "$READONLY_MCP_PATH_PREFIX"
  load_readonly_mcp_runtime_override

  local gfx_instance gfx_key image_key gfx_value
  for gfx_instance in 01 02; do
    gfx_key="AI${gfx_instance}_ROCM_GFX_VERSION"
    image_key="LLAMACPP${gfx_instance}_AMD_IMAGE"
    gfx_value="${!gfx_key:-${AMD_ROCM_GFX_VERSION:-}}"
    if [ -n "$gfx_value" ]; then
      [[ "$gfx_value" =~ ^gfx[0-9a-f]{3,5}$ ]] || die "Invalid AMD GFX architecture for ai${gfx_instance}"
      printf -v "$gfx_key" '%s' "$gfx_value"
      printf -v "$image_key" '%s' "ghcr.io/kukurusik/ai-stand-llamacpp:${LLAMACPP_IMAGE_VERSION}-amd-${gfx_value}"
    fi
  done

  case "${READONLY_MCP_ENABLED:-0}" in
    0|1) ;;
    *) die "READONLY_MCP_ENABLED must be 0 or 1" ;;
  esac

  case "${GITEA_ENABLED:-0}" in
    0|1) ;;
    *) die "GITEA_ENABLED must be 0 or 1" ;;
  esac
  if [ "${GITEA_ENABLED}" = "1" ]; then
    [[ "${GITEA_HOST}" =~ ^[a-z0-9][a-z0-9.-]{0,251}[a-z0-9]$ ]] \
      || die "GITEA_HOST must be a DNS hostname"
    [[ "${GITEA_SSH_PORT}" =~ ^[0-9]{1,5}$ ]] \
      && [ "${GITEA_SSH_PORT}" -ge 1 ] && [ "${GITEA_SSH_PORT}" -le 65535 ] \
      || die "GITEA_SSH_PORT must be in the range 1..65535"
    SERVICES+=("${STACK_NAME}_gitea" "${STACK_NAME}_gitea-postgresql")
    PUBLIC_PORTS+=("${GITEA_SSH_PORT}")
  fi

  case "${GITEA_SSH_SYNC_ENABLED:-0}" in
    0|1) ;;
    *) die "GITEA_SSH_SYNC_ENABLED must be 0 or 1" ;;
  esac
  case "${GITEA_SSH_SYNC_APPLY:-1}" in
    0|1) ;;
    *) die "GITEA_SSH_SYNC_APPLY must be 0 (plan only) or 1" ;;
  esac
  if [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ]; then
    [ "${GITEA_ENABLED:-0}" = "1" ] || die "GITEA_SSH_SYNC_ENABLED requires GITEA_ENABLED=1"
    SERVICES+=("${STACK_NAME}_gitea-ssh-sync")
  fi

  case "${SSH_KEY_DELIVERY_ENABLED:-0}" in
    0|1) ;;
    *) die "SSH_KEY_DELIVERY_ENABLED must be 0 or 1" ;;
  esac
  if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then
    [ "${CODER_ENABLED:-0}" = "1" ] || die "SSH_KEY_DELIVERY_ENABLED requires CODER_ENABLED=1"
    SERVICES+=("${STACK_NAME}_ssh-key-sender" "${STACK_NAME}_ssh-key-receiver")
  fi

  case "${CONTROLLER_ENABLED:-1}" in
    0|1) ;;
    *) die "CONTROLLER_ENABLED must be 0 or 1" ;;
  esac
  case "${CERTBOT_RECEIVER_ENABLED:-0}" in
    0|1) ;;
    *) die "CERTBOT_RECEIVER_ENABLED must be 0 or 1" ;;
  esac
  if [ "${CONTROLLER_ENABLED}" = "1" ]; then
    SERVICES+=("${STACK_NAME}_controller")
    if [ "${CERTBOT_RECEIVER_ENABLED}" = "1" ]; then
      [ "${CERTBOT_ENABLED:-0}" = "1" ] || die "CERTBOT_RECEIVER_ENABLED requires CERTBOT_ENABLED=1"
      SERVICES+=("${STACK_NAME}_cert-receiver")
    fi
  fi

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
    credentials)
      [ "$COMMAND_SET" = "1" ] || die "credentials is a local secret-inspection command"
      [ -z "$NODE_NAME" ] && [ -z "$HOST_IP" ] && [ -z "$PEER_IP" ] \
        || die "credentials list/show does not accept node, network or deployment options"
      return 0
      ;;
    images)
      if [ -n "$HOST_IP" ]; then
        validate_ipv4 "$HOST_IP" || die "--host-ip must be an IPv4 address"
      fi
      if [ -n "$PEER_IP" ]; then
        validate_ipv4 "$PEER_IP" || die "--peer-ip must be an IPv4 address"
      fi
      return 0
      ;;
    deploy-models|configure-model-routing|reconcile-mcp|configure-gitea|configure-gitea-ssh-sync|cleanup-legacy-gitea-ssh-sync|deploy-controller|configure-ssh-key-delivery|cleanup-legacy-host-timers)
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

  local trusted_cidr port
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

ensure_nginx_repo() {
  local key_ascii key_binary source_tmp preference_tmp
  key_ascii="$(mktemp)"; key_binary="$(mktemp)"
  source_tmp="$(mktemp)"; preference_tmp="$(mktemp)"
  curl --fail --show-error --silent --location --proto '=https' \
    https://nginx.org/keys/nginx_signing.key --output "$key_ascii"
  gpg --batch --with-colons --show-keys "$key_ascii" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10 }' \
    | grep -Fxq "$NGINX_SIGNING_FINGERPRINT" \
    || die "Unexpected official Nginx signing key"
  gpg --batch --yes --dearmor --output "$key_binary" "$key_ascii"
  printf '%s\n' \
    'Types: deb' \
    'URIs: https://nginx.org/packages/ubuntu/' \
    "Suites: ${OS_CODENAME}" \
    'Components: nginx' \
    'Signed-By: /usr/share/keyrings/ai-stand-nginx.gpg' > "$source_tmp"
  printf '%s\n' 'Package: nginx nginx-module-*' 'Pin: release o=nginx' \
    'Pin-Priority: 900' > "$preference_tmp"
  install_if_changed "$key_binary" /usr/share/keyrings/ai-stand-nginx.gpg 0644 root root
  install_if_changed "$source_tmp" /etc/apt/sources.list.d/ai-stand-nginx.sources 0644 root root
  install_if_changed "$preference_tmp" /etc/apt/preferences.d/ai-stand-nginx 0644 root root
  rm -f -- "$key_ascii" "$key_binary" "$source_tmp" "$preference_tmp"
  run_root apt-get update
  run_root env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confold install --yes "nginx=${NGINX_VERSION}-1~${OS_CODENAME}"
  [ "$(nginx -v 2>&1)" = "nginx version: nginx/${NGINX_VERSION}" ] \
    || die "Nginx release mismatch after installation"
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

  if [ "$accelerator" = "amd" ]; then
    case "$OS_VERSION_ID" in
      24.04|26.04) ;;
      *) die "AMD ROCm ${AMD_ROCM_RELEASE} is supported here only on Ubuntu 24.04 or 26.04" ;;
    esac
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

  # Historical gfx1151 queue-eviction failures require a kernel >=7.0.
  # This prerequisite is not evidence that a particular ROCm inference
  # configuration is safe: the native image still needs its own GPU canary.
  # Current AMD deployments are ROCm-only; historical Vulkan workarounds
  # in issues/ are not runtime-selection policy or an allowed fallback.
  local kernel_major
  kernel_major="$(uname -r | cut -d. -f1)"

  if [ "$kernel_major" -lt 7 ]; then
    local kernel_package
    case "$OS_VERSION_ID" in
      24.04) kernel_package="linux-generic-hwe-24.04" ;;
      26.04) kernel_package="linux-generic" ;;
      *) die "Cannot select an AMD kernel meta-package for Ubuntu ${OS_VERSION_ID}" ;;
    esac
    if ! dpkg -s "$kernel_package" >/dev/null 2>&1; then
      log "Installing ${kernel_package} (running kernel $(uname -r) is older than the minimum 7.0 required for AMD ROCm)"
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$kernel_package"
    fi
    mark_reboot_required "${kernel_package} installed to reach kernel >=7.0 (running kernel is still $(uname -r))"
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

  # The installer owns the matching apt repository metadata. Upgrade it even
  # when the inbox amdgpu device is already healthy: hosts upgraded from
  # Ubuntu 24.04 otherwise retain 31.50 and can silently restore old repo
  # definitions during later maintenance.
  local amdgpu_installer_version deb_tmp
  amdgpu_installer_version="$(dpkg-query -W -f='${Version}' amdgpu-install 2>/dev/null || true)"
  # AMD's package version includes two zero components before the build
  # number (for example 31.60.0.0.31600000-2407772.26.04).  Match the
  # release line and build family rather than an invented shortened form,
  # so an already-correct installer is not needlessly reinstalled.
  if [[ ! "$amdgpu_installer_version" == 31.60.*316000* ]]; then
    deb_tmp="$(mktemp --suffix=.deb)"
    curl --fail --show-error --silent --location \
      "$AMD_AMDGPU_INSTALL_URL" \
      --output "$deb_tmp"
    echo "${AMD_AMDGPU_INSTALL_SHA256}  ${deb_tmp}" | sha256sum --check --strict \
      || die "amdgpu-install package checksum mismatch: $AMD_AMDGPU_INSTALL_URL"
    # The installer package owns several APT source files.  On an upgraded
    # host dpkg may otherwise ask an interactive conffile question while
    # applying this local .deb, leaving the unattended host stage blocked
    # indefinitely.  Keep the current, managed files until the following
    # explicit renderer replaces them with the release-specific sources.
    run_root env DEBIAN_FRONTEND=noninteractive apt-get \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      install -y "$deb_tmp"
    rm -f "$deb_tmp"
    run_root apt-get update
  fi

  if ! amd_gpu_ready; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      "linux-headers-$(uname -r)" || true

    # Ryzen APUs use the kernel's own inbox amdgpu driver (confirmed via
    # AMD's per-model install picker with fam=ryzen); no DKMS build needed.
    run_root modprobe amdgpu >/dev/null 2>&1 || true

    if ! amd_gpu_ready; then
      mark_reboot_required "amdgpu-install completed but GPU devices are not ready yet"
    fi
  fi

  # Always render this source. A 24.04 entry left by a previous deployment is
  # invalid after a host upgrade to Ubuntu 26.04 and must never survive just
  # because the file already exists.
  {
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
      "URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/" \
      "Suites: stable" \
      "Components: main" \
      "Architectures: amd64" \
      "Signed-By: /etc/apt/keyrings/amdrocm.gpg" \
      "Enabled: yes" \
      > "$sources_tmp"
    write_root_file_if_changed "$sources_tmp" /etc/apt/sources.list.d/amdrocm-stable.sources 0644
    rm -f "$sources_tmp"
    run_root apt-get update
  }

  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "amdrocm${AMD_ROCM_RELEASE}-${AMD_ROCM_GFX_VERSION}"

  # APT permits ROCm 10.0 and 10.1 to coexist after a distribution upgrade.
  # That leaves competing /opt/rocm alternatives and makes an ostensibly
  # 10.1 runtime non-deterministic. Purge only installed package *names* from
  # the retired 10.0 line after the 10.1 metapackage is known installed.
  local -a stale_rocm_packages=()
  local package
  while IFS= read -r package; do
    [ -n "$package" ] && stale_rocm_packages+=("$package")
  done < <(dpkg-query -W -f='${binary:Package}\n' 'amdrocm*10.0*' 2>/dev/null || true)
  if [ "${#stale_rocm_packages[@]}" -gt 0 ]; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${stale_rocm_packages[@]}"
    run_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
  fi
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
  local disk_path="$STORAGE_ROOT"
  if [ ! -d "$disk_path" ]; then
    disk_path="$(dirname "$STORAGE_ROOT")"
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
      printf '%s\n' "$OPENWEBUI_HOST" "$PORTAINER_HOST"
      if [ "${GITEA_ENABLED:-0}" = "1" ]; then
        printf '%s\n' "$GITEA_HOST"
      fi
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

  # Authentik and Agentgateway are pinned to ai01. Validate their actual
  # ingress IP from either host instead of incorrectly expecting the ai02
  # preflight to resolve them to itself.
  check_dns "$AUTHENTIK_HOST" "$AI01_IP"
  # Not part of local_service_domains() (see its own comment) because the
  # full Agentgateway surface is authenticated, but its DNS is still a hard
  # deployment prerequisite.
  check_dns "$AGENTGATEWAY_HOST" "$AI01_IP"
}

cert_valid() {
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  run_root test -r "$fullchain" || return 1
  run_root test -r "$privkey" || return 1
  # Only an expired certificate is invalid here. One that is merely close to
  # expiry must not block the host stage, which is what installs its renewal.
  run_root openssl x509 -in "$fullchain" -noout -checkend 0 >/dev/null || return 1
  run_root openssl x509 -in "$fullchain" -noout -ext subjectAltName \
    | grep -q "DNS:\\*.${CERT_DOMAIN}"
}

check_cert_preflight() {
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  if run_root_no_prompt test -r "$fullchain" >/dev/null 2>&1 && run_root_no_prompt test -r "$privkey" >/dev/null 2>&1; then
    if run_root_no_prompt openssl x509 -in "$fullchain" -noout -checkend 0 >/dev/null 2>&1; then
      log "TLS certificate exists; host command will validate SAN before Nginx reload"
      warn_cert_expiring
    else
      die "Existing TLS certificate is expired or invalid: ${fullchain}"
    fi
  elif run_root_no_prompt test -e "$fullchain" >/dev/null 2>&1 || run_root_no_prompt test -e "$privkey" >/dev/null 2>&1; then
    die "TLS certificate directory is partially populated; fix ${CERT_DIR} before continuing"
  else
    log "TLS certificate is absent; host command will generate a self-signed bootstrap wildcard certificate"
  fi
}

# A certificate under 21 days from expiry means renewal is not working (certbot
# renews at 30 days). Loud, but never a reason to stop a stage.
warn_cert_expiring() {
  if ! run_root_no_prompt openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 1814400 >/dev/null 2>&1; then
    warn "TLS certificate $(run_root_no_prompt openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -enddate 2>/dev/null) is under 21 days away: renewal is not working (see certbot/README.md)"
  fi
}

ensure_tls_cert() {
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  if cert_valid; then
    log "TLS certificate is valid and covers *.${CERT_DOMAIN}"
    warn_cert_expiring
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
    -addext "subjectAltName=DNS:*.${CERT_DOMAIN},DNS:${CERT_DOMAIN},DNS:authentik.${CERT_DOMAIN},DNS:openwebui.${CERT_DOMAIN},DNS:openclaw.${CERT_DOMAIN},DNS:portainer.${CERT_DOMAIN}" \
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
  if [ "$component_name" = "Gateway" ]; then
    # OpenClaw 2026.10.2 deliberately keeps its two managed npm plugin
    # generations root-owned and immutable to the runtime user. Validate
    # those exact namespaces without following links; every other state or
    # workspace path must retain APP_UID:APP_GID ownership.
    run_root python3 "${SCRIPT_DIR}/docker/openclaw/validate-gateway-ownership.py" \
      --gateway-root "$path" --uid "$APP_UID" --gid "$APP_GID" \
      || die "OpenClaw Gateway ownership conflict; refusing to recursively chown persistent data."
    unexpected_path=""
  elif [[ "$component_name" == sandbox\ DIND* ]]; then
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

ensure_openclaw_docker_sandbox_storage() {
  local path unexpected_path ownership mode

  # The Docker backend is scoped per agent. These roots contain user Git
  # repositories and MEMORY.md files, so unexpected ownership is a hard
  # error, never an invitation to recursively chown user data.
  for path in \
    "${OPENCLAW_DOCKER_SANDBOX_WORKSPACE_ROOT}/main" \
    "${OPENCLAW_DOCKER_SANDBOX_WORKSPACE_ROOT}/codex" \
    "${OPENCLAW_DOCKER_SANDBOX_WORKSPACE_ROOT}/claude"; do
    if ! run_root test -e "$path"; then
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$path"
    fi
    ownership="$(run_root stat -c '%u:%g' "$path")"
    mode="$(run_root stat -c '%a' "$path")"
    [ "$ownership" = "${APP_UID}:${APP_GID}" ] && [ "$mode" = "750" ] \
      || die "OpenClaw Docker sandbox root has unexpected ownership/mode at ${path}: ${ownership} ${mode}; expected ${APP_UID}:${APP_GID} 750"
    unexpected_path="$(run_root find "$path" -xdev \( ! -uid "$APP_UID" -o ! -gid "$APP_GID" \) -print -quit 2>/dev/null || true)"
    [ -z "$unexpected_path" ] \
      || die "OpenClaw Docker sandbox ownership conflict at ${unexpected_path}; expected ${APP_UID}:${APP_GID}. Refusing to recursively chown user workspace data."
  done
  log "OpenClaw Docker sandbox roots are ready"
}

migrate_root_data_to_component() {
  local root="$1"
  local component="$2"
  local mode="$3"
  local -a preserved_root_entry_patterns=()
  local -a migration_find_exclusions
  local component_name
  local old_entry
  local component_entry
  local pattern
  component_name="${component##*/}"

  # A component root may intentionally hold several managed siblings or
  # recovery artifacts.  Honour every explicit exclusion argument: dropping
  # a later one could move an active sandbox root as though it were legacy
  # flat-layout data.
  migration_find_exclusions=( ! -name "$component_name" ! -name ".ai-stand-owner" )
  if [ "$#" -gt 3 ]; then
    preserved_root_entry_patterns=("${@:4}")
  fi
  for pattern in "${preserved_root_entry_patterns[@]}"; do
    [ -n "$pattern" ] || continue
    migration_find_exclusions+=( ! -name "$pattern" )
  done

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
      "${migration_find_exclusions[@]}" \
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
      "${migration_find_exclusions[@]}" \
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
  local host_name="${secret_name#ai-stand-}" host_file="${AI_STAND_SECRETS_DIR}/${secret_name#ai-stand-}"
  local service_name container_ids container_id target expected_hash actual_hash consumer_count local_node_name task_rows remote_node_count

  case "$secret_name" in
    "$AUTHENTIK_SECRET_KEY_SECRET") service_name="${STACK_NAME}_authentik-server" ;;
    "$AUTHENTIK_POSTGRES_PASSWORD_SECRET") service_name="${STACK_NAME}_authentik-postgresql" ;;
    *) die "No protected host source mapping exists for Docker secret ${secret_name}" ;;
  esac
  target="/run/secrets/${secret_name}"

  if docker_cmd secret inspect "$secret_name" >/dev/null 2>&1; then
    container_ids="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${service_name}" --format '{{.ID}}')"
    consumer_count="$(printf '%s\n' "$container_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$consumer_count" = "0" ] && [ "$READ_ONLY_VERIFY" = "1" ]; then
      # Authentik is deliberately pinned to ai01. A Swarm Secret is cluster
      # scoped, but the source file and its consumer are node-local; verifying
      # ai02 must not attempt to copy or recreate ai01's signing/database
      # credentials. Prove the exact single running consumer is remote before
      # treating this secret as outside the local verification scope.
      case "$secret_name" in
        "$AUTHENTIK_SECRET_KEY_SECRET"|"$AUTHENTIK_POSTGRES_PASSWORD_SECRET") ;;
        *) die "Cannot verify ${secret_name}: no local consumer and no approved remote owner" ;;
      esac
      local_node_name="$(docker_cmd info --format '{{.Name}}')"
      [[ "$local_node_name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] \
        || die "Cannot verify ${secret_name}: local Swarm node name is unavailable"
      task_rows="$(docker_cmd service ps --filter desired-state=running --format '{{.Node}}|{{.CurrentState}}' "$service_name")"
      remote_node_count="$(printf '%s\n' "$task_rows" | awk -F'|' -v local="$local_node_name" \
        '$1 != "" && $1 != local && $2 ~ /^Running/ { n++ } END { print n+0 }')"
      [ "$remote_node_count" = "1" ] \
        || die "Cannot verify ${secret_name}: expected one exact remote Authentik consumer"
      log "Docker secret is owned by the remote Authentik service; no node-local copy required: ${secret_name}"
      return 0
    fi
    [ "$consumer_count" = "1" ] \
      || die "Cannot safely persist/verify ${secret_name}: expected one active local consumer"
    container_id="$(printf '%s\n' "$container_ids" | sed '/^$/d')"
    if ! run_root test -s "$host_file"; then
      [ "$READ_ONLY_VERIFY" != "1" ] \
        || die "Read-only verification requires the existing protected source for ${secret_name}"
      run_root install -d -m 0700 -o root -g root "$AI_STAND_SECRETS_DIR"
      docker_cmd exec "$container_id" cat "$target" | run_root tee "$host_file" >/dev/null \
        || die "Cannot persist existing ${secret_name} before continuing"
      run_root chown root:root "$host_file"
      run_root chmod 0600 "$host_file"
    fi
    if [ "$READ_ONLY_VERIFY" = "1" ]; then
      local host_metadata
      host_metadata="$(run_root stat -c '%F|%u|%g|%a|%h' -- "$host_file")" \
        || die "Cannot inspect protected source metadata for ${secret_name}"
      [ "$host_metadata" = "regular file|0|0|600|1" ] \
        || die "Unsafe protected source metadata for ${secret_name}"
    fi
    expected_hash="$(run_root sha256sum "$host_file" | awk '{print $1}')"
    actual_hash="$(docker_cmd exec "$container_id" cat "$target" | sha256sum | awk '{print $1}')"
    [ -n "$expected_hash" ] && [ "$expected_hash" = "$actual_hash" ] \
      || die "Protected host source differs from active Docker secret ${secret_name}; no rotation attempted"
    log "Docker secret source persisted and verified: ${secret_name}"
    return 0
  fi

  [ "$READ_ONLY_VERIFY" != "1" ] \
    || die "Read-only verification requires existing Docker secret ${secret_name}"
  load_host_secret "$host_name" "$bytes" >/dev/null
  run_root cat -- "$host_file" | docker_cmd secret create "$secret_name" - >/dev/null
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

  if [ "$READ_ONLY_VERIFY" = "1" ]; then
    run_root test -s "$path" \
      || die "Read-only verification requires existing protected credential: ${name}"
    local metadata
    metadata="$(run_root stat -c '%F|%u|%g|%a|%h' -- "$path")" \
      || die "Cannot inspect protected credential metadata: ${name}"
    [ "$metadata" = "regular file|0|0|600|1" ] \
      || die "Unsafe protected credential metadata during read-only verification: ${name}"
    run_root cat -- "$path"
    return 0
  fi

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

  [ "$READ_ONLY_VERIFY" != "1" ] \
    || die "Read-only verification requires existing Docker secret ${secret_name}"

  printf '%s' "$value" | docker_cmd secret create "$secret_name" - >/dev/null
  log "Created Docker secret: ${secret_name}"
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
  AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET="$(load_host_secret authentik-agentgateway-client-secret 32)"
  AUTHENTIK_CODER_CLIENT_SECRET="$(load_host_secret authentik-coder-client-secret 32)"
  ensure_docker_secret_from_value ai-stand-authentik-coder-client-secret "$AUTHENTIK_CODER_CLIENT_SECRET"
  # Opaque machine bearer tokens for agentgateway's llm.policies.apiKey -
  # one per consumer service, not tied to any Authentik group/claim (see
  # agentgateway/config.yaml). Same generate-and-forget pattern as
  # OPENCLAW_GATEWAY_TOKEN below.
  AGENTGATEWAY_OPENWEBUI_TOKEN="$(load_host_secret agentgateway-openwebui-token 32)"
  AGENTGATEWAY_OPENCLAW_TOKEN="$(load_host_secret agentgateway-openclaw-token 32)"
  # Same generate-and-forget pattern as the two above, unconditionally:
  # config.yaml substitutes every referenced var over the whole file, so a
  # Coder-disabled installation would otherwise crash agentgateway on an
  # unset var. No Coder template uses the key at the moment (the earlier
  # TF_VAR_agentgateway_token hand-off was removed); it stays so a workspace
  # that needs the model API can be given a service key without a redeploy.
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

  # Backs agentgateway-postgres. hex mode (like coder's own Postgres
  # password) matters here specifically: this value is embedded unescaped
  # inside a postgres:// connection URL in agentgateway/config.yaml, so it
  # must never need URL-percent-encoding.
  AGENTGATEWAY_POSTGRES_PASSWORD="$(load_host_secret agentgateway-postgres-password 24 hex)"
  ensure_docker_secret_from_value ai-stand-agentgateway-postgres-password "$AGENTGATEWAY_POSTGRES_PASSWORD"
  if [ "$CODER_ENABLED" = "1" ]; then
    CODER_POSTGRES_PASSWORD="$(load_host_secret coder-postgres-password 24 hex)"
    ensure_docker_secret_from_value ai-stand-coder-postgres-password "$CODER_POSTGRES_PASSWORD"
    # Never pushed into the container env - only used locally by
    # bootstrap_coder_admin()'s `docker exec`. Retrievable via `credentials`.
    CODER_ADMIN_PASSWORD="$(load_host_secret coder-admin-password 24)"
  fi
  if [ "${GITEA_ENABLED:-0}" = "1" ]; then
    GITEA_POSTGRES_PASSWORD="$(load_host_secret gitea-postgres-password 24 hex)"
    AUTHENTIK_GITEA_CLIENT_SECRET="$(load_host_secret authentik-gitea-client-secret 32)"
    ensure_docker_secret_from_value ai-stand-gitea-postgres-password "$GITEA_POSTGRES_PASSWORD"
    ensure_docker_secret_from_value ai-stand-authentik-gitea-client-secret "$AUTHENTIK_GITEA_CLIENT_SECRET"
  fi
  ensure_controller_secrets
}

ensure_controller_secrets() {
  [ "${CONTROLLER_ENABLED:-0}" = "1" ] || return 0
  # A Swarm-wide Docker secret: it is created from, and its value kept on, the node that deploys the controller.
  [ "$NODE_NAME" = "ai01" ] || return 0
  # Authenticates the controller to the cert-receiver on the other node.
  CERTBOT_RECEIVER_TOKEN="$(load_host_secret certbot-receiver-token 32)"
  ensure_docker_secret_from_value ai-stand-certbot-receiver-token "$CERTBOT_RECEIVER_TOKEN"
}

cmd_credentials() {
  local -a names=(
    authentik-secret-key authentik-postgres-password authentik-bootstrap-token authentik-bootstrap-password
    authentik-openwebui-client-secret authentik-portainer-client-secret
    authentik-agentgateway-client-secret authentik-coder-client-secret authentik-gitea-client-secret
    readonly-mcp-authentik-api-token gitea-ssh-sync-authentik-api-token gitea-ssh-sync-gitea-token
    coder-admin-password coder-postgres-password
    portainer-admin-password openwebui-secret-key openclaw-gateway-token agentgateway-openwebui-token
    agentgateway-openclaw-token agentgateway-coder-token agentgateway-oidc-cookie-secret
    agentgateway-postgres-password
    gitea-postgres-password
    certbot-receiver-token
    ssh-key-delivery-authentik-api-token ssh-key-delivery-token
  )
  local name path metadata found
  [ "$(id -u)" -eq 0 ] || die "credentials command must run as root"
  case "$CREDENTIALS_ACTION" in
    list)
      for name in "${names[@]}"; do
        path="${AI_STAND_SECRETS_DIR}/${name}"
        if run_root test -e "$path"; then
          metadata="$(run_root stat -c '%F|%u|%g|%a|%h' -- "$path")"
          [ "$metadata" = "regular file|0|0|600|1" ] || die "Unsafe credential file metadata: ${name}"
          log "available: ${name}"
        else
          log "missing: ${name}"
        fi
      done
      ;;
    show)
      [[ "$CREDENTIALS_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "Invalid credential name"
      found="0"
      for name in "${names[@]}"; do [ "$name" = "$CREDENTIALS_NAME" ] && found="1"; done
      [ "$found" = "1" ] || die "Credential name is not in the supported script-generated allowlist"
      path="${AI_STAND_SECRETS_DIR}/${CREDENTIALS_NAME}"
      metadata="$(run_root stat -c '%F|%u|%g|%a|%h' -- "$path")" || die "Credential is missing"
      [ "$metadata" = "regular file|0|0|600|1" ] || die "Unsafe credential file metadata"
      run_root cat -- "$path"
      ;;
    *) die "credentials action must be list or show" ;;
  esac
}

ensure_storage() {
  run_root install -d -m 0755 "$STORAGE_ROOT"
  run_root install -d -m 0750 -o root -g root "$BACKUP_ROOT"

  case "$NODE_NAME" in
    ai01)
      # Kept outside agentgateway-data: neither the gateway container nor
      # its service account may read the reconciler's API-token file
      # paths, generated manifest, or timer state.
      run_root install -d -m 0700 -o root -g root "$READONLY_MCP_DATA_ROOT"
      run_root install -d -m 0700 -o root -g root "$READONLY_MCP_RECONCILER_DATA"
      # Host-local route overrides are an installation control-plane input,
      # never a profile/source artifact. Do not create the override file:
      # its deliberate absence retains the generic /mcp/work value.
      run_root install -d -m 0700 -o root -g root "$AI_STAND_DATA_ROOT"
      run_root install -d -m 0700 -o root -g root "$INSTALLATION_OVERRIDES_ROOT"
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$LLAMACPP_DATA_ROOT"
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$LLAMACPP01_DATA"
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "${LLAMACPP01_DATA}/models" "${LLAMACPP01_DATA}/state"
      migrate_root_data_to_component "$OPENWEBUI_DATA_ROOT" "$OPENWEBUI_DATA" 0750
      migrate_root_data_to_component "$PORTAINER_DATA_ROOT" "$PORTAINER_DATA" 0750
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
      # Agentgateway PostgreSQL has its own sibling role below the same
      # component root.  It predates the `server/` layout and intentionally
      # has no generic ownership marker, so preserve it while detecting any
      # truly flat legacy Gateway data that still needs migration.
      migrate_root_data_to_component "$AGENTGATEWAY_DATA_ROOT" "$AGENTGATEWAY_DATA" 0750 "postgres"
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$AGENTGATEWAY_POSTGRES_DATA"
      ensure_authentik_data
      ensure_portainer_data
      if [ "${GITEA_ENABLED:-0}" = "1" ]; then
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$GITEA_DATA_ROOT"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$GITEA_SERVER_DATA"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$GITEA_CONFIG_DATA"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$GITEA_POSTGRES_DATA"
        run_root install -d -m 0700 -o "$APP_UID" -g "$APP_GID" "$GITEA_BACKUPS_DATA"
      fi
      ;;
    ai02)
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$LLAMACPP_DATA_ROOT"
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$LLAMACPP02_DATA"
      run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "${LLAMACPP02_DATA}/models" "${LLAMACPP02_DATA}/state"
      # Manual OpenClaw configuration backups intentionally remain directly
      # below the component root. They are protected operator recovery
      # artifacts, not legacy root-style service data to migrate or delete.
      mark_existing_openclaw_component_owned "$OPENCLAW_DATA" "Gateway"
      ensure_openclaw_docker_sandbox_storage
      migrate_root_data_to_component "$OPENCLAW_DATA_ROOT" "$OPENCLAW_DATA" 0750 \
        "openclaw.json.manual-backup-*" "sandboxes"
      if [ "$CODER_ENABLED" = "1" ]; then
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_DATA_ROOT"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_SERVER_DATA"
        run_root install -d -m 0750 -o "$APP_UID" -g "$APP_GID" "$CODER_POSTGRES_DATA"
      fi
      # The workspace identity owns the key directories, so the receiver (which runs as that identity) writes keys it can
      # leave at 0400. Docker refuses a bind mount whose source is missing, and the Gateway mounts services/openclaw
      # whatever the delivery state, so the service tree exists unconditionally.
      run_root install -d -m 0700 -o "$APP_UID" -g "$APP_GID" \
        "$SSH_KEY_DELIVERY_DATA_ROOT" "$SSH_SERVICE_KEYS_ROOT" "${SSH_SERVICE_KEYS_ROOT}/openclaw"
      if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then
        run_root install -d -m 0700 -o "$APP_UID" -g "$APP_GID" "$SSH_KEYS_ROOT"
      fi
      install_openclaw_telegram_token
      ;;
    *)
      die "Unknown node name: ${NODE_NAME:-empty}"
      ;;
  esac
  check_legacy_storage_maintenance_safety
  ensure_host_secret_storage_protection
  harden_readonly_mcp_reconciler_control_files
  ensure_installation_override_protection
}

# The Telegram bot token is the one Telegram setting Authentik does not hold (init.mjs reads the groups and people from
# there). The owner puts it, as a bare token, into ${AI_STAND_SECRETS_DIR}/openclaw-telegram-bot-token on this node
# (root, 0600); it is copied to the Gateway's state directory, where init.mjs points channels.telegram.tokenFile at it.
# Without the file nothing happens here and the channel is configured only once there is a token. The value is never
# printed or put on a command line.
install_openclaw_telegram_token() {
  local source="${AI_STAND_SECRETS_DIR}/openclaw-telegram-bot-token"
  local target_dir="${OPENCLAW_DATA}/.openclaw"
  if ! run_root test -f "$source"; then
    log "No ${source}: the OpenClaw Telegram channel stays off until it exists"
    return 0
  fi
  run_root install -d -m 0700 -o "$APP_UID" -g "$APP_GID" "$target_dir"
  local outcome
  outcome="$(run_root python3 - "$source" "${target_dir}/telegram-bot-token" "$APP_UID" "$APP_GID" <<'PY'
import os
import re
import sys

source, target, uid, gid = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
token = open(source, encoding="utf-8").read().strip()
if not re.fullmatch(r"[0-9]{6,12}:[A-Za-z0-9_-]{30,64}", token):
    print("invalid")
    sys.exit(1)
try:
    current = open(target, encoding="utf-8").read()
except OSError:
    current = None
if current == token:
    os.chown(target, uid, gid)
    os.chmod(target, 0o600)
    print("unchanged")
    sys.exit(0)
temporary = target + ".new"
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    handle.write(token)
os.chown(temporary, uid, gid)
os.replace(temporary, target)
print("installed")
PY
)" || die "${source} must hold exactly one Telegram bot token (<digits>:<30 to 64 characters>)"
  case "$outcome" in
    installed) log "Installed the OpenClaw Telegram bot token for the Gateway; it is read at the next Gateway start" ;;
    *) log "OpenClaw Telegram bot token already installed" ;;
  esac
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
    "$READONLY_MCP_MANIFEST"; do
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

check_legacy_storage_maintenance_safety() {
  # /mnt/fix.sh belongs to the operator and is never edited by ai-stand.
  # Broad recursive chown/chmod rules can silently expose root-only secrets
  # or break application-owned data.  Refuse a rollout until the operator
  # has replaced legacy wildcard rules with a narrow, reviewed policy.
  local maintenance="/mnt/fix.sh"
  [ -f "$maintenance" ] || return 0

  # The storage root with its dots made literal for the extended regular expression.
  local root_re="${STORAGE_ROOT//./[.]}"
  if run_root grep -Eq \
    "(^|[[:space:];])((sudo[[:space:]]+)?(chown|chmod)[[:space:]]+-R[^[:cntrl:]]*${root_re}/(_secrets|ai-stand-data)|${root_re}/\*|\*-data)" \
    "$maintenance"; then
    die "Unsafe recursive ownership/permission rule in ${maintenance}; ai-stand will not modify it. Exclude ${STORAGE_ROOT}/_secrets and root-only overrides, then rerun preflight."
  fi

  log "Operator-owned ${maintenance} passed narrow recursive-permissions safety check"
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

ensure_zone_port() {
  local zone="$1"
  local port="$2"
  if run_root firewall-cmd --permanent --zone="$zone" --query-port="${port}/tcp" >/dev/null; then
    log "firewalld port ${port}/tcp already allowed in ${zone}"
  else
    run_root firewall-cmd --permanent --zone="$zone" --add-port="${port}/tcp" >/dev/null
    log "Allowed firewalld port ${port}/tcp in ${zone}"
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
  local trusted_cidr port
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
  for port in "${PUBLIC_PORTS[@]}"; do
    case "$port" in
      80|443) ;;
      *) ensure_zone_port ai-stand "$port" ;;
    esac
  done

  local zone
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

    # Drop rules only ever accumulated: the ports of retired services (1234,
    # 7080, 11234, 12008, ...) stayed forever. Remove every drop rule of exactly
    # the shape written above whose port is no longer a technical port here.
    local live_rule live_port
    while IFS= read -r live_rule; do
      live_port="${live_rule#rule family=\"ipv4\" port port=\"}"
      live_port="${live_port%%\"*}"
      technical_ports_for_current_node | grep -qx "$live_port" && continue
      remove_rich_rule_if_present "$zone" "$live_rule"
    done < <(run_root firewall-cmd --permanent --zone="$zone" --list-rich-rules | grep -E '^rule family="ipv4" port port="[0-9]+" protocol="tcp" drop$' || true)

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
PUBLIC_PORTS=(__AI_STAND_PUBLIC_PORTS__)
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

  local public_ports
  public_ports="$(printf '%s ' "${PUBLIC_PORTS[@]}" | sed 's/[[:space:]]*$//')"
  sed -i "s/__AI_STAND_TECH_PORTS__/${technical_ports}/" "$helper_tmp"
  sed -i "s/__AI_STAND_PUBLIC_PORTS__/${public_ports}/" "$helper_tmp"

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

ensure_coder_workspace_images() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  [ "$NODE_NAME" = "ai02" ] || return 0

  # Coder reaches the host Docker daemon only through its dedicated socket
  # proxy. Build these trusted administrator-owned images on ai02 before
  # publishing templates; neither image receives a socket at runtime.
  local image source
  for image in "$CODER_CSHARP_WORKSPACE_IMAGE" "$CODER_PYTHON_WORKSPACE_IMAGE"; do
    case "$image" in
      *csharp*) source="${SCRIPT_DIR}/docker/coder-workspace-csharp/Dockerfile" ;;
      *python*) source="${SCRIPT_DIR}/docker/coder-workspace-python/Dockerfile" ;;
      *) die "Unexpected Coder workspace image: $image" ;;
    esac
    docker_cmd build --pull --tag "$image" -f "$source" "$(dirname "$source")"
  done
  log "Coder workspace images are available in the ai02 Docker daemon"
}

# registry.terraform.io is geo-blocked from this network - confirmed live
# 2026-09-23 via a direct curl to its .well-known/terraform.json, which
# returns an HTML page ("Content not available in your region... trade
# controls"), not the JSON `terraform init` expects, so every provider
# installation attempt against the real registry fails outright. GitHub
# itself (github.com, api.github.com, and its release-asset download host)
# is reachable, so mirror the two exact provider builds the C# and Python
# templates pin (docker/coder-templates/{csharp,python}/main.tf) from their
# GitHub releases into a local filesystem_mirror instead - confirmed live
# the same day: terraform validate fully succeeds against this mirror with
# no other change. Checksums below are copied verbatim from each release's
# own published SHA256SUMS file (terraform-provider-coder_2.19.0_SHA256SUMS
# / terraform-provider-docker_4.6.0_SHA256SUMS), the same pinning approach
# already used for e.g. the Node.js tarball in the OpenClaw image.
#
# The mirror directory and .terraformrc live under CODER_SERVER_DATA
# (bind-mounted to /home/coder in the coder server container - see
# compose.coder.yaml) specifically so HOME=/home/coder already set there
# makes Terraform find .terraformrc with no extra TF_CLI_CONFIG_FILE env
# var, and so .terraformrc's own `path` is written in the container's own
# /home/coder terms, not this host's storage path.
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

  # The site sources are templates: every installation value is a @PLACEHOLDER@ (the storage root, the certificate directory,
  # the public host names and the two nodes' addresses); the installed file has them filled in from the profile.
  local site_rendered ai01_ip ai02_ip
  if [ "$NODE_NAME" = "ai01" ]; then ai01_ip="$HOST_IP"; ai02_ip="$PEER_IP"; else ai01_ip="$PEER_IP"; ai02_ip="$HOST_IP"; fi
  site_rendered="$(mktemp)"
  sed -e "s#@STORAGE_ROOT@#${STORAGE_ROOT}#g" -e "s#@CERT_DIR@#${CERT_DIR}#g" \
    -e "s#@AI01_IP@#${ai01_ip}#g" -e "s#@AI02_IP@#${ai02_ip}#g" \
    -e "s#@AUTHENTIK_HOST@#${AUTHENTIK_HOST}#g" -e "s#@OPENWEBUI_HOST@#${OPENWEBUI_HOST}#g" \
    -e "s#@PORTAINER_HOST@#${PORTAINER_HOST}#g" -e "s#@AGENTGATEWAY_HOST@#${AGENTGATEWAY_HOST}#g" \
    -e "s#@GITEA_HOST@#${GITEA_HOST}#g" -e "s#@OPENCLAW_HOST@#${OPENCLAW_HOST}#g" -e "s#@CODER_HOST@#${CODER_HOST}#g" \
    "$NGINX_SITE_SOURCE" > "$site_rendered"
  if grep -qE '@[A-Z0-9_]+@' "$site_rendered"; then
    rm -f "$site_rendered"
    die "${NGINX_SITE_SOURCE} still has an unfilled placeholder after rendering"
  fi
  if ! run_root test -f /etc/nginx/conf.d/ai-stand.conf || ! run_root cmp -s "$site_rendered" /etc/nginx/conf.d/ai-stand.conf; then
    backup_nginx_once
  fi
  install_if_changed "$site_rendered" /etc/nginx/conf.d/ai-stand.conf 0644 root root
  rm -f "$site_rendered"

  # The packaged unit never restarts nginx. A restart that fails once (a DNS
  # hiccup on an upstream name took ai02 down for eight hours on 2026-10-23)
  # then stays failed until someone notices; retry instead.
  local dropin="/etc/systemd/system/nginx.service.d/ai-stand-restart.conf" dropin_changed=0
  run_root install -d -m 0755 /etc/systemd/system/nginx.service.d
  run_root cmp -s "$NGINX_RESTART_DROPIN_SOURCE" "$dropin" 2>/dev/null || dropin_changed=1
  install_if_changed "$NGINX_RESTART_DROPIN_SOURCE" "$dropin" 0644 root root
  [ "$dropin_changed" = 0 ] || run_root systemctl daemon-reload

  install_nginx_reload_units

  run_root nginx -t >/dev/null
  run_root systemctl enable --now nginx >/dev/null
  run_root systemctl reload nginx
  log "Nginx configuration applied"
}

# nginx stays on the host, but the certificate is installed from containers (the controller's certbot job and the
# cert-receiver), which cannot reach the host's nginx. This path unit notices a changed lineage, tests the configuration,
# reloads nginx and records the fingerprint of the certificate it serves in $CERTBOT_DATA/.served-fingerprint, which the
# containers wait for (certbot/served.sh). It is the only host-side piece of the certificate automation.
install_nginx_reload_units() {
  [ "${CERTBOT_ENABLED:-0}" = "1" ] || return 0
  local kind rendered target changed=0
  for kind in path service; do
    rendered="$(mktemp)"
    sed -e "s#@CERT_DOMAIN@#${CERT_DOMAIN}#g" -e "s#@CERTBOT_DATA@#${CERTBOT_DATA}#g" \
      -e "s#@PROBE_HOST@#${PORTAINER_HOST}#g" \
      "${NGINX_RELOAD_UNIT_SOURCE_DIR}/ai-stand-nginx-reload.${kind}" > "$rendered"
    target="/etc/systemd/system/ai-stand-nginx-reload.${kind}"
    run_root cmp -s "$rendered" "$target" 2>/dev/null || changed=1
    install_if_changed "$rendered" "$target" 0644 root root
    rm -f "$rendered"
  done
  [ "$changed" = 0 ] || run_root systemctl daemon-reload
  run_root systemctl enable --now ai-stand-nginx-reload.path >/dev/null
}

# The settings the certificate automation needs, checked early. The DNS credentials file is created by the owner; until
# it exists renewal stays inactive (the controller's certbot job says so in its log).
validate_certbot_profile() {
  [ "${CERTBOT_ENABLED:-0}" = "1" ] || return 0
  [ -n "$CERTBOT_EMAIL" ] && [ -n "$CERTBOT_CREDENTIALS_NAME" ] && [ -n "$CERTBOT_HOOK_SOURCE" ] \
    || die "CERTBOT_ENABLED needs CERTBOT_EMAIL, CERTBOT_CREDENTIALS_NAME and CERTBOT_HOOK_SOURCE in the installation profile"
  [ -f "${INSTALLATION_DIR}/${CERTBOT_HOOK_SOURCE}" ] \
    || die "The DNS hook ${INSTALLATION_DIR}/${CERTBOT_HOOK_SOURCE} is missing"
  [ "${CONTROLLER_ENABLED:-0}" = "1" ] || die "CERTBOT_ENABLED needs CONTROLLER_ENABLED=1: the controller runs the renewal"
  if ! run_root test -r "${AI_STAND_SECRETS_DIR}/${CERTBOT_CREDENTIALS_NAME}"; then
    warn "Certificate renewal is INACTIVE until ${AI_STAND_SECRETS_DIR}/${CERTBOT_CREDENTIALS_NAME} exists (see certbot/README.md)"
  fi
}

build_controller_image() {
  [ "${CONTROLLER_ENABLED:-0}" = "1" ] || return 0
  docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$CONTROLLER_IMAGE" -f docker/controller/Dockerfile .
  # The certbot job runs the official image as a sibling container.
  if [ "$NODE_NAME" != "ai02" ] && [ "${CERTBOT_ENABLED:-0}" = "1" ]; then
    docker_cmd image inspect "$CERTBOT_IMAGE" >/dev/null 2>&1 || docker_cmd pull "$CERTBOT_IMAGE"
  fi
}

build_gitea_ssh_sync_image() {
  [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ] || return 0
  docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$GITEA_SSH_SYNC_IMAGE" -f docker/gitea-ssh-sync/Dockerfile .
}

# Also callable alone through the stage driver, to roll a changed OpenClaw image without rebuilding llama.cpp.
build_openclaw_image() {
  docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --build-arg "OPENCLAW_VERSION=${OPENCLAW_VERSION}" --target openclaw --tag "$OPENCLAW_IMAGE" -f docker/openclaw/Dockerfile .
}

# One image, two services: the sender on the Authentik node and the receiver on the Coder node.
build_ssh_key_delivery_image() {
  [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ] || return 0
  docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$SSH_KEY_DELIVERY_IMAGE" -f docker/ssh-key-delivery/Dockerfile .
}

# The values compose.controller.yaml interpolates; everything the jobs need comes from the installation profile.
export_controller_environment() {
  [ "${CONTROLLER_ENABLED:-0}" = "1" ] || return 0
  local jobs="model-access" hook_name="" peer_url="" replicas=0
  [ "${READONLY_MCP_ENABLED:-0}" != "1" ] || jobs="reconcile,${jobs}"
  [ "${CERTBOT_ENABLED:-0}" != "1" ] || jobs="${jobs},certbot"
  CONTROLLER_CERTBOT_HOOK_DIR=""; CONTROLLER_CERTBOT_CREDENTIALS=""
  CONTROLLER_CERTBOT_AUTH_HOOK=""; CONTROLLER_CERTBOT_CLEANUP_HOOK=""
  if [ "${CERTBOT_ENABLED:-0}" = "1" ]; then
    hook_name="$(basename "$CERTBOT_HOOK_SOURCE")"
    CONTROLLER_CERTBOT_HOOK_DIR="$(dirname "${INSTALLATION_DIR}/${CERTBOT_HOOK_SOURCE}")"
    CONTROLLER_CERTBOT_CREDENTIALS="${AI_STAND_SECRETS_DIR}/${CERTBOT_CREDENTIALS_NAME}"
    CONTROLLER_CERTBOT_AUTH_HOOK="python3 /hooks/${hook_name} auth"
    CONTROLLER_CERTBOT_CLEANUP_HOOK="python3 /hooks/${hook_name} cleanup"
    if [ "${CERTBOT_RECEIVER_ENABLED:-0}" = "1" ]; then peer_url="http://cert-receiver:8443"; replicas=1; fi
  fi
  CONTROLLER_JOBS="$jobs"
  CONTROLLER_INSTALLATION="$INSTALLATION"
  CONTROLLER_CERTBOT_PEER_URL="$peer_url"
  CONTROLLER_RECEIVER_REPLICAS="$replicas"
  AI_STAND_DIR="$SCRIPT_DIR"
  export CONTROLLER_IMAGE CONTROLLER_JOBS CONTROLLER_INSTALLATION AI_STAND_DIR AI_STAND_MODULES_ROOT \
    CERT_DOMAIN CERTBOT_IMAGE CERTBOT_EMAIL CERTBOT_DATA CONTROLLER_CERTBOT_HOOK_DIR CONTROLLER_CERTBOT_CREDENTIALS \
    CONTROLLER_CERTBOT_AUTH_HOOK CONTROLLER_CERTBOT_CLEANUP_HOOK CONTROLLER_CERTBOT_PEER_URL CONTROLLER_RECEIVER_REPLICAS
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
    "$READONLY_MCP_RENDERER" \
    "$READONLY_MCP_RECONCILER"; do
    [ -f "$path" ] || die "Read-only MCP source is missing: $path"
  done
}

# Read only non-secret deployment settings from the root-owned reconciler
# configuration. The Authentik token values themselves are stored in
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
    --imap-image "$IMAP_READONLY_MCP_IMAGE"

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

secret = re.compile(r"^ai-stand-mcp-[a-z0-9-]{3,100}$")
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
for value in sorted(names):
    print(value)
PY
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
      | jq -r '.[]? | (.SecretName // .File.Name // empty) | select(test("^ai-stand-mcp-"))'
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
  docker_cmd stack config -c "$READONLY_MCP_RENDERED_COMPOSE" >/dev/null
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
  if [ "${#reload_args[@]}" -gt 0 ]; then
    docker_cmd service update --detach=true "${reload_args[@]}" "$gateway_service" >/dev/null
    sleep 2
    wait_service_ready "$gateway_service"
  fi

  # The Telegram ids and groups the reconciler collected from Authentik: the people (ai-users attributes), the bot's
  # owner and its groups (the owner account's attributes). A change restarts the gateway, like any service environment
  # change. init.mjs validates all three again before it writes them.
  local telegram_allow_from telegram_owner_ids telegram_groups
  # The pattern lives in a variable on purpose: inside [[ =~ ]] anything in quotes is literal text.
  local telegram_id_list='^\[("[0-9]{5,15}"(,"[0-9]{5,15}")*)?\]$'
  telegram_allow_from="$(jq -c '[(.telegram.userIds // [])[] | tostring]' "$READONLY_MCP_MANIFEST")"
  [[ "$telegram_allow_from" =~ $telegram_id_list ]] \
    || die "Unexpected Telegram user id list in the read-only MCP manifest"
  telegram_owner_ids="$(jq -c '[(.telegram.ownerIds // [])[] | tostring]' "$READONLY_MCP_MANIFEST")"
  [[ "$telegram_owner_ids" =~ $telegram_id_list ]] \
    || die "Unexpected Telegram owner id list in the read-only MCP manifest"
  # No "groups" key (attribute missing or unreadable): empty, which leaves the gateway's groups alone. An object, even an
  # empty one, is the complete list of groups.
  telegram_groups="$(jq -c 'if ((.telegram // {}) | has("groups")) then .telegram.groups else "" end' "$READONLY_MCP_MANIFEST")"
  [ "$telegram_groups" = '""' ] && telegram_groups=""
  if [ -n "$telegram_groups" ]; then
    [ "$(jq -r 'type' <<<"$telegram_groups")" = "object" ] && [ "${#telegram_groups}" -le 16384 ] \
      || die "Unexpected Telegram group list in the read-only MCP manifest"
  fi

  # Install the managed remote MCP entries without touching the active
  # models, Codex/Claude subscription runtimes or user-created connections.
  update_service_env openclaw-gateway \
    "OPENCLAW_READONLY_MCP_ENABLED=1" \
    "OPENCLAW_READONLY_MCP_BASE_URL=https://${AGENTGATEWAY_HOST}" \
    "OPENCLAW_READONLY_MCP_PATH_PREFIX=${READONLY_MCP_PATH_PREFIX}" \
    "OPENCLAW_TELEGRAM_ALLOW_FROM=${telegram_allow_from}" \
    "OPENCLAW_TELEGRAM_OWNER_IDS=${telegram_owner_ids}" \
    "OPENCLAW_TELEGRAM_GROUPS=${telegram_groups}"

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
  for file in openwebui.png portainer.svg agentgateway.svg openclaw.png coder.svg gitea.svg; do
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
      # Coder's image, Socket Proxy and persistent workspace
      # storage deliberately exist only on ai02. Advertising the Coder label
      # on ai01 lets Swarm schedule an unpullable local image there.
      docker_cmd node update \
        --label-add ai-stand.node=ai01 \
        --label-add ai-stand.role=manager \
        --label-add ai-stand.ingress=true \
        --label-add ai-stand.llamacpp01=true \
        --label-add ai-stand.llamacpp02=false \
        --label-add ai-stand.openwebui=true \
        --label-add ai-stand.openclaw=false \
        --label-add ai-stand.authentik=true \
        --label-add ai-stand.portainer=true \
        --label-add ai-stand.agentgateway=true \
        --label-add ai-stand.gitea=true \
        --label-add ai-stand.coder=false \
        --label-add ai-stand.controller=true \
        --label-add ai-stand.cert-receiver=false \
        --label-add "ai-stand.accelerator=${accelerator}" \
        "$node_id" >/dev/null
      ;;
    ai02)
      docker_cmd node update \
        --label-add ai-stand.node=ai02 \
        --label-add ai-stand.role=manager \
        --label-add ai-stand.ingress=true \
        --label-add ai-stand.llamacpp01=false \
        --label-add ai-stand.llamacpp02=true \
        --label-add ai-stand.openwebui=false \
        --label-add ai-stand.openclaw=true \
        --label-add ai-stand.authentik=false \
        --label-add ai-stand.portainer=false \
        --label-add ai-stand.agentgateway=false \
        --label-add ai-stand.gitea=false \
        --label-add ai-stand.coder=true \
        --label-add ai-stand.controller=false \
        --label-add ai-stand.cert-receiver=true \
        --label-add ai-stand.accelerator=none \
        "$node_id" >/dev/null
      ;;
    *)
      die "Unknown node name: ${NODE_NAME:-empty}"
      ;;
  esac

  docker_cmd node update --label-rm ai-stand.storage "$node_id" >/dev/null 2>&1 || true
  docker_cmd node update --label-rm ai-stand.amd "$node_id" >/dev/null 2>&1 || true
  docker_cmd node update --label-rm ai-stand.llamacpp "$node_id" >/dev/null 2>&1 || true
  docker_cmd node update --label-rm ai-stand.gitlab "$node_id" >/dev/null 2>&1 || true
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

  if [ "$CODER_ENABLED" = "1" ]; then
    printf '%s\n' "-c" "$COMPOSE_CODER_FILE"
  fi

  if [ "${GITEA_ENABLED:-0}" = "1" ]; then
    printf '%s\n' "-c" "$COMPOSE_GITEA_FILE"
  fi

  if [ "${CONTROLLER_ENABLED:-0}" = "1" ]; then
    printf '%s\n' "-c" "$COMPOSE_CONTROLLER_FILE"
  fi

  # User-scoped MCP services are deliberately not part of the generic stack
  # argument list. They are reconciled as a narrow fragment after the core
  # deployment, so neither a timer nor a manual MCP refresh can reset the
  # installation-specific model/context profile.
}

llamacpp_image_for_accelerator() {
  case "$1" in
    cpu) printf '%s\n' "$LLAMACPP_CPU_IMAGE" ;;
    amd)
      local image_key
      case "${NODE_NAME:-}" in
        ai01|ai02)
          image_key="LLAMACPP${NODE_NAME#ai}_AMD_IMAGE"
          [ -n "${!image_key:-}" ] || die "Node-specific AMD image is unavailable for ${NODE_NAME}; provide both node GFX settings"
          printf '%s\n' "${!image_key}"
          ;;
        *)
          [[ "${AMD_ROCM_GFX_VERSION:-}" =~ ^gfx[0-9a-f]{3,5}$ ]] || die "AMD_ROCM_GFX_VERSION is required for an unpinned AMD image build"
          printf '%s\n' "ghcr.io/kukurusik/ai-stand-llamacpp:${LLAMACPP_IMAGE_VERSION}-amd-${AMD_ROCM_GFX_VERSION}"
          ;;
      esac
      ;;
    nvidia) printf '%s\n' "$LLAMACPP_NVIDIA_IMAGE" ;;
    *) die "Unknown resolved accelerator: $1" ;;
  esac
}

llamacpp_target_for_accelerator() {
  case "$1" in
    cpu) printf '%s\n' "llamacpp-cpu" ;;
    amd) printf '%s\n' "llamacpp-amd" ;;
    nvidia) printf '%s\n' "llamacpp-nvidia" ;;
    *) die "Unknown resolved accelerator: $1" ;;
  esac
}

cmd_preflight() {
  load_os_info
  check_reboot_marker_readonly
  local accelerator="none"
  if [ "$NODE_NAME" = "ai01" ] || [ "$NODE_NAME" = "ai02" ]; then
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  log "Host OS: Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}), arch=${ARCH}, accelerator=${accelerator}"
  check_disk
  check_docker_preflight
  if [ "$NODE_NAME" = "ai01" ] || [ "$NODE_NAME" = "ai02" ]; then
    check_accelerator_preflight "$accelerator"
  fi
  check_cert_preflight
  check_legacy_storage_maintenance_safety

  check_node_dns

  log "Preflight complete"
}

archive_legacy_gitlab_data() {
  [ "$NODE_NAME" = "ai02" ] || return 0
  run_root test -d "$LEGACY_GITLAB_DATA_ROOT" || return 0

  # GitLab is retired in favour of Gitea. Stop its old service before taking
  # a filesystem archive so PostgreSQL and repository files are consistent.
  # This intentionally does not delete the source directory or attempt an
  # automatic import into Gitea.
  local legacy_service="${STACK_NAME}_gitlab"
  if docker_cmd service inspect "$legacy_service" >/dev/null 2>&1; then
    docker_cmd service scale --detach=true "${legacy_service}=0" >/dev/null
    local deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if ! docker_cmd ps --filter "label=com.docker.swarm.service.name=${legacy_service}" --format '{{.ID}}' | grep -q .; then
        break
      fi
      sleep 2
    done
    if docker_cmd ps --filter "label=com.docker.swarm.service.name=${legacy_service}" --format '{{.ID}}' | grep -q .; then
      die "Legacy GitLab did not stop within five minutes; refusing to archive a live database"
    fi
  fi

  local stamp_file archive checksum
  stamp_file="${LEGACY_GITLAB_ARCHIVE_ROOT}/gitlab-data.sha256"
  if run_root test -s "$stamp_file"; then
    log "Legacy GitLab archive already exists; source data remains preserved"
    return 0
  fi
  run_root install -d -m 0700 -o root -g root "$LEGACY_GITLAB_ARCHIVE_ROOT"
  archive="${LEGACY_GITLAB_ARCHIVE_ROOT}/gitlab-data-${RUN_TS}.tar"
  checksum="${archive}.sha256"
  run_root tar --acls --xattrs --numeric-owner -C "$STORAGE_ROOT" -cf "$archive" gitlab-data
  run_root sh -c 'sha256sum "$1" > "$2"' sh "$archive" "$checksum"
  run_root cp "$checksum" "$stamp_file"
  run_root chown root:root "$archive" "$checksum" "$stamp_file"
  run_root chmod 0600 "$archive" "$checksum" "$stamp_file"
  log "Legacy GitLab data is archived; no automatic Gitea migration was performed"
}

# The hosts' own clock zone is the installation's IM_TZ, the one the services get, so journals, cron and logs of both nodes read
# alike. The hardware clock stays UTC; nothing is restarted by the change.
host_timezone() {
  timedatectl show --property=Timezone --value 2>/dev/null || true
}

ensure_host_timezone() {
  local current
  current="$(host_timezone)"
  if [ -z "$current" ]; then
    warn "timedatectl is unavailable, the host time zone was not checked"
    return 0
  fi
  if [ "$current" = "$IM_TZ" ]; then
    log "Host time zone is already ${IM_TZ}"
    return 0
  fi
  run_root test -e "/usr/share/zoneinfo/${IM_TZ}" || die "Time zone ${IM_TZ} is not installed on this host"
  run_root timedatectl set-timezone "$IM_TZ"
  log "Host time zone changed from ${current} to ${IM_TZ}"
}

check_host_timezone() {
  local current
  current="$(host_timezone)"
  [ -z "$current" ] || [ "$current" = "$IM_TZ" ] \
    || die "Host time zone is ${current}, the installation says ${IM_TZ}; run the host stage"
}

cmd_host() {
  load_os_info
  check_reboot_marker
  ensure_base_packages
  ensure_host_timezone
  backup_nginx_once
  ensure_nginx_repo
  local accelerator="none"
  if [ "$NODE_NAME" = "ai01" ] || [ "$NODE_NAME" = "ai02" ]; then
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  ensure_docker
  configure_firewalld
  ensure_swarm
  cleanup_stale_swarm_nodes_after_recovery
  archive_legacy_gitlab_data
  ensure_authentik_secrets
  if [ "$NODE_NAME" = "ai01" ] || [ "$NODE_NAME" = "ai02" ]; then
    ensure_accelerator_runtime "$accelerator"
  fi
  ensure_storage
  validate_readonly_mcp_runtime_override_permissions
  ensure_tls_cert
  configure_firewalld
  install_docker_user_helper
  if [ "$NODE_NAME" = "ai02" ]; then
    ensure_coder_workspace_images
    ensure_coder_terraform_provider_mirror
  fi
  install_nginx
  validate_certbot_profile
  install_agentgateway_config
  install_openwebui_model_access
  install_authentik_icons
  ensure_node_labels "$accelerator"
  log "Host stage complete for accelerator=${accelerator}"
}

verify_llamacpp_built_image() {
  local image="$1" accelerator="$2"
  local commit archive native_tag gfx=""
  commit="$(jq -er '.runtime.commit' "${SCRIPT_DIR}/model-catalog/catalog.lock.json")"
  archive="$(jq -er '.runtime.archiveSha256' "${SCRIPT_DIR}/model-catalog/catalog.lock.json")"
  native_tag="$(jq -er '.runtime.tag' "${SCRIPT_DIR}/model-catalog/catalog.lock.json")"
  if [ "$accelerator" = amd ]; then gfx="$AMD_ROCM_GFX_VERSION"; fi
  docker_cmd run --rm --network none --read-only --entrypoint python3 "$image" -c '
import json
from pathlib import Path
import re
import subprocess
import sys
m = json.loads(Path("/opt/llamacpp-build.json").read_text())
expected = dict(commit=sys.argv[1], archiveSha256=sys.argv[2], accelerator=sys.argv[3], gfx=sys.argv[4])
if any(m.get(k) != v for k, v in expected.items()) or m.get("nativeTag") != sys.argv[6]:
    raise SystemExit("Native llama.cpp build provenance mismatch")
if sys.argv[3] == "amd" and m.get("rocmVersion") != sys.argv[5]:
    raise SystemExit("ROCm release mismatch")
if sys.argv[3] == "amd":
    # readobj is read-only; objdump --offloading extracts bundle files beside
    # the inspected library and is unsuitable for an immutable runtime.
    output = subprocess.run(
        ["/opt/rocm/llvm/bin/llvm-readobj", "--offloading", "/opt/llamacpp/bin/libggml-hip.so"],
        check=True, capture_output=True, text=True, timeout=60,
    ).stdout
    bundles = re.findall(
        r"(?m)^hip-amdgcn-amd-amdhsa--(gfx[0-9a-f]+)(?::[^\t ]+)?\s+file://[^\n]*#offset=\d+&size=([1-9]\d*)$",
        output,
    )
    if not bundles or {architecture for architecture, size in bundles} != {sys.argv[4]}:
        raise SystemExit("Native HIP code bundles do not match the required GFX architecture")
' "$commit" "$archive" "$accelerator" "$gfx" "$AMD_ROCM_RELEASE" "$native_tag" \
    || die "Built native model image failed provenance verification"
  if [ "$accelerator" = amd ]; then
    local built_gfx
    built_gfx="$(docker_cmd image inspect "$image" --format '{{ index .Config.Labels "org.ai-stand.rocm.gfx" }}')"
    [ "$built_gfx" = "$gfx" ] || die "Built AMD image architecture label mismatch"
  fi
  # Root-only inspection can hide missing traversal bits on COPY-created
  # directories. Exercise the installed wrapper and full native argv as the
  # real UID, offline and without models, GPU devices, secrets or inference.
  docker_cmd run --rm --user 10000:20000 --network none --read-only --cap-drop ALL \
    --entrypoint python3 "$image" -c '
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
s = importlib.util.spec_from_file_location("native_runtime", "/usr/local/lib/llamacpp/runtime.py")
m = importlib.util.module_from_spec(s)
sys.modules[s.name] = m
s.loader.exec_module(m)
for role in ("chat", "embedding"):
    environment = dict(os.environ, LLAMACPP_ROLE=role, LLAMACPP_MODEL_ID="build-cli-probe", LLAMACPP_MODEL_SHA256="0" * 64)
    config = m.Config.read(environment)
    projector = Path("/models/cli-projector.gguf") if role == "chat" else None
    command = m.command(config, Path("/models/cli-probe.gguf"), projector)
    result = subprocess.run(command + ["--help"], capture_output=True, timeout=60)
    if result.returncode:
        raise SystemExit("Pinned native CLI rejected runtime arguments")
' || die "Built native image failed non-root traversal/CLI smoke test"
  log "Verified local native image provenance: ${image} (${accelerator}${gfx:+/$gfx})"
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

  if [ -z "$NODE_NAME" ] || [ "$NODE_NAME" = "ai01" ] || [ "$NODE_NAME" = "ai02" ]; then
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  cd "$SCRIPT_DIR"
  docker_cmd build --pull --tag "$BASE_IMAGE" -f docker/base/Dockerfile .
  local -a llamacpp_build_args=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
  if [ "$accelerator" = "amd" ]; then
    [ -n "${AMD_ROCM_GFX_VERSION:-}" ] || die "AMD_ROCM_GFX_VERSION is required for the llama.cpp AMD image"
    llamacpp_build_args+=(--build-arg "AMD_ROCM_RELEASE=${AMD_ROCM_RELEASE}" --build-arg "AMD_ROCM_GFX_VERSION=${AMD_ROCM_GFX_VERSION}")
  fi

  if [ "$READONLY_MCP_ENABLED" = "1" ]; then
    require_readonly_mcp_sources
  fi

  case "${NODE_NAME:-all}" in
    ai01)
      local llamacpp_target
      local llamacpp_image
      llamacpp_target="$(llamacpp_target_for_accelerator "$accelerator")"
      llamacpp_image="$(llamacpp_image_for_accelerator "$accelerator")"
      docker_cmd build "${llamacpp_build_args[@]}" --target "$llamacpp_target" --tag "$llamacpp_image" -f docker/llamacpp/Dockerfile .
      verify_llamacpp_built_image "$llamacpp_image" "$accelerator"
      build_readonly_mcp_images
      docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --build-arg "AUTHENTIK_VERSION=${AUTHENTIK_VERSION}" --target authentik --tag "$AUTHENTIK_IMAGE" -f docker/authentik/Dockerfile .
      docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target authentik-configurator --tag "$AUTHENTIK_CONFIGURATOR_IMAGE" -f docker/authentik/Dockerfile .
      build_gitea_ssh_sync_image
      build_controller_image
      build_ssh_key_delivery_image
      docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$DIAGNOSTIC_IMAGE" -f docker/diagnostic/Dockerfile .
      docker_cmd pull "$PORTAINER_IMAGE"
      docker_cmd pull "$PORTAINER_AGENT_IMAGE"
      docker_cmd pull "$DOCKER_SOCKET_PROXY_IMAGE"
      docker_cmd pull "$OPENWEBUI_IMAGE"
      docker_cmd pull "$AUTHENTIK_POSTGRES_IMAGE"
      docker_cmd pull "$AUTHENTIK_REDIS_IMAGE"
      docker_cmd pull "$AGENTGATEWAY_IMAGE"
      if [ "${GITEA_ENABLED:-0}" = "1" ]; then
        docker_cmd pull "$GITEA_IMAGE"
        docker_cmd pull "$GITEA_POSTGRES_IMAGE"
      fi
      local -a ai01_images=("$BASE_IMAGE" "$llamacpp_image" "$AUTHENTIK_IMAGE" "$AUTHENTIK_CONFIGURATOR_IMAGE" "$PORTAINER_IMAGE" "$PORTAINER_AGENT_IMAGE" "$OPENWEBUI_IMAGE" "$AUTHENTIK_POSTGRES_IMAGE" "$AUTHENTIK_REDIS_IMAGE" "$DIAGNOSTIC_IMAGE" "$AGENTGATEWAY_IMAGE")
      if [ "$READONLY_MCP_ENABLED" = "1" ]; then ai01_images+=("$JIRA_READONLY_MCP_IMAGE" "$CONFLUENCE_READONLY_MCP_IMAGE" "$IMAP_READONLY_MCP_IMAGE"); fi
      if [ "${GITEA_ENABLED:-0}" = "1" ]; then ai01_images+=("$GITEA_IMAGE" "$GITEA_POSTGRES_IMAGE"); fi
      if [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ]; then ai01_images+=("$GITEA_SSH_SYNC_IMAGE"); fi
      if [ "${CONTROLLER_ENABLED:-0}" = "1" ]; then ai01_images+=("$CONTROLLER_IMAGE"); fi
      if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then ai01_images+=("$SSH_KEY_DELIVERY_IMAGE"); fi
      docker_cmd image inspect "${ai01_images[@]}" >/dev/null
      log "Required ai01 images are available for accelerator=${accelerator}"
      ;;
    ai02)
      local llamacpp_target
      local llamacpp_image
      llamacpp_target="$(llamacpp_target_for_accelerator "$accelerator")"
      llamacpp_image="$(llamacpp_image_for_accelerator "$accelerator")"
      docker_cmd build "${llamacpp_build_args[@]}" --target "$llamacpp_target" --tag "$llamacpp_image" -f docker/llamacpp/Dockerfile .
      verify_llamacpp_built_image "$llamacpp_image" "$accelerator"
      build_openclaw_image
      docker_cmd build --tag openclaw-sandbox:bookworm-slim -f docker/openclaw-sandbox/Dockerfile .
      docker_cmd build --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$DIAGNOSTIC_IMAGE" -f docker/diagnostic/Dockerfile .
      docker_cmd pull "$PORTAINER_AGENT_IMAGE"
      docker_cmd pull "$DOCKER_SOCKET_PROXY_IMAGE"
      build_coder_image
      if [ "$CODER_ENABLED" = "1" ]; then ensure_coder_workspace_images; fi
      build_controller_image
      build_ssh_key_delivery_image
      local -a ai02_images=("$BASE_IMAGE" "$llamacpp_image" "$OPENCLAW_IMAGE" openclaw-sandbox:bookworm-slim "$PORTAINER_AGENT_IMAGE" "$DOCKER_SOCKET_PROXY_IMAGE" "$DIAGNOSTIC_IMAGE")
      if [ "$CODER_ENABLED" = "1" ]; then
        ai02_images+=("$CODER_IMAGE" "$CODER_POSTGRES_IMAGE" "$CODER_CSHARP_WORKSPACE_IMAGE" "$CODER_PYTHON_WORKSPACE_IMAGE")
      fi
      if [ "${CONTROLLER_ENABLED:-0}" = "1" ]; then ai02_images+=("$CONTROLLER_IMAGE"); fi
      if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then ai02_images+=("$SSH_KEY_DELIVERY_IMAGE"); fi
      docker_cmd image inspect "${ai02_images[@]}" >/dev/null
      log "Required ai02 images are available"
      ;;
    all)
      local llamacpp_target
      local llamacpp_image
      llamacpp_target="$(llamacpp_target_for_accelerator "$accelerator")"
      llamacpp_image="$(llamacpp_image_for_accelerator "$accelerator")"
      docker_cmd build "${llamacpp_build_args[@]}" --target "$llamacpp_target" --tag "$llamacpp_image" -f docker/llamacpp/Dockerfile .
      verify_llamacpp_built_image "$llamacpp_image" "$accelerator"
      build_readonly_mcp_images
      build_openclaw_image
      docker_cmd build --tag openclaw-sandbox:bookworm-slim -f docker/openclaw-sandbox/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --build-arg "AUTHENTIK_VERSION=${AUTHENTIK_VERSION}" --target authentik --tag "$AUTHENTIK_IMAGE" -f docker/authentik/Dockerfile .
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --target authentik-configurator --tag "$AUTHENTIK_CONFIGURATOR_IMAGE" -f docker/authentik/Dockerfile .
      build_gitea_ssh_sync_image
      build_controller_image
      build_ssh_key_delivery_image
      docker_cmd build --pull --build-arg "BASE_IMAGE=${BASE_IMAGE}" --tag "$DIAGNOSTIC_IMAGE" -f docker/diagnostic/Dockerfile .
      docker_cmd pull "$PORTAINER_IMAGE"
      docker_cmd pull "$PORTAINER_AGENT_IMAGE"
      docker_cmd pull "$DOCKER_SOCKET_PROXY_IMAGE"
      docker_cmd pull "$OPENWEBUI_IMAGE"
      docker_cmd pull "$AUTHENTIK_POSTGRES_IMAGE"
      docker_cmd pull "$AUTHENTIK_REDIS_IMAGE"
      docker_cmd pull "$AGENTGATEWAY_IMAGE"
      if [ "${GITEA_ENABLED:-0}" = "1" ]; then
        docker_cmd pull "$GITEA_IMAGE"
        docker_cmd pull "$GITEA_POSTGRES_IMAGE"
      fi
      local -a all_images=("$BASE_IMAGE" "$llamacpp_image" "$OPENCLAW_IMAGE" openclaw-sandbox:bookworm-slim "$AUTHENTIK_IMAGE" "$AUTHENTIK_CONFIGURATOR_IMAGE" "$PORTAINER_IMAGE" "$PORTAINER_AGENT_IMAGE" "$DOCKER_SOCKET_PROXY_IMAGE" "$OPENWEBUI_IMAGE" "$AUTHENTIK_POSTGRES_IMAGE" "$AUTHENTIK_REDIS_IMAGE" "$DIAGNOSTIC_IMAGE" "$AGENTGATEWAY_IMAGE")
      if [ "$READONLY_MCP_ENABLED" = "1" ]; then all_images+=("$JIRA_READONLY_MCP_IMAGE" "$CONFLUENCE_READONLY_MCP_IMAGE" "$IMAP_READONLY_MCP_IMAGE"); fi
      if [ "${GITEA_ENABLED:-0}" = "1" ]; then all_images+=("$GITEA_IMAGE" "$GITEA_POSTGRES_IMAGE"); fi
      if [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ]; then all_images+=("$GITEA_SSH_SYNC_IMAGE"); fi
      if [ "${CONTROLLER_ENABLED:-0}" = "1" ]; then all_images+=("$CONTROLLER_IMAGE"); fi
      if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then all_images+=("$SSH_KEY_DELIVERY_IMAGE"); fi
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

# Signing keys of the ai-stand-llm Authentik provider (the JWTs people mint from
# an App password, see agentgateway/config.yaml llm.policies.jwtAuth). Public
# key material only, so it travels in the service environment as an inline
# JWKS: agentgateway then neither needs Authentik to be up when it starts nor a
# provider that does not exist yet on a fresh install. The loopback port is the
# published Authentik server (closed to every other source by firewalld).
# Prints the normalised JWKS (sorted keys, compact, one line) or fails.
authentik_llm_jwks() {
  local raw
  raw="$(curl --fail --silent --show-error --max-time 20 \
    "http://127.0.0.1:19001/application/o/ai-stand-llm/jwks/")" || return 1
  printf '%s' "$raw" | jq -e -S -c '
    select((.keys | type == "array") and (.keys | length > 0)
      and all(.keys[]; (.kty | type == "string") and (.kid | type == "string")))
    | {keys: (.keys | sort_by(.kid))}' 2>/dev/null
}

# soft: on a fresh install the provider does not exist until configure-authentik
# has run, so a missing JWKS is only reported (the empty compose placeholder
# denies every JWT and keeps the service keys working). hard: used right after
# configure-authentik, where the provider must exist.
sync_agentgateway_llm_jwks() {
  local mode="${1:-soft}" jwks
  [ "$NODE_NAME" = "ai01" ] || return 0
  if ! jwks="$(authentik_llm_jwks)"; then
    if [ "$mode" = "hard" ]; then
      die "Authentik did not return signing keys for the ai-stand-llm provider; check configure-authentik output"
    fi
    warn "ai-stand-llm signing keys are not available yet; LLM JWT access stays closed until configure-authentik has run"
    return 0
  fi
  case "$jwks" in
    *"'"*) die "ai-stand-llm JWKS contains a single quote, which agentgateway/config.yaml cannot embed" ;;
  esac
  update_service_env agentgateway "LLM_AUTHENTIK_JWKS=${jwks}"
}

check_agentgateway_llm_jwks() {
  [ "$NODE_NAME" = "ai01" ] || return 0
  local live desired
  live="$(service_env_value "${STACK_NAME}_agentgateway" LLM_AUTHENTIK_JWKS)"
  desired="$(authentik_llm_jwks)" \
    || die "Authentik does not serve signing keys for the ai-stand-llm provider (run configure-authentik)"
  [ "$live" = "$desired" ] \
    || die "Agentgateway LLM_AUTHENTIK_JWKS differs from the keys Authentik serves for ai-stand-llm; run configure-authentik"
  log "Agentgateway LLM JWT keys match Authentik (ai-stand-llm)"
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
    "LLM_AUTHENTIK_ISSUER_URL=https://${AUTHENTIK_HOST}/application/o/ai-stand-llm/" \
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
  update_service_env llamacpp01 \
    "IM_TZ=${IM_TZ}" \
    "IM_UID=${IM_UID}" \
    "IM_GID=${IM_GID}"
  update_service_env llamacpp02 \
    "IM_TZ=${IM_TZ}" \
    "IM_UID=${IM_UID}" \
    "IM_GID=${IM_GID}"
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
    # Role sync (USER_ROLE_*) is a licensed Coder feature: on this Free deployment it is
    # inert, and a signed-in user is a plain member. ALLOWED_GROUPS is the active gate.
    --env-add "CODER_OIDC_USER_ROLE_FIELD=groups" \
    --env-add 'CODER_OIDC_USER_ROLE_MAPPING={"ai-users":["member"],"ai-admins":["owner"]}' \
    "$svc" >/dev/null
  log "Reconciled Coder native OIDC and public URLs"
}

load_llamacpp_catalog_selection() {
  local accelerator="${1:-${ACCELERATOR:-amd}}"
  local helper="${SCRIPT_DIR}/model-catalog/selection.py"
  [ -r "$helper" ] || die "Pinned llama.cpp model selector is missing"
  local selected policy_max_context="${LLAMACPP_CHAT_POLICY_MAX_CONTEXT:-${LLAMACPP_CHAT_CONTEXT_LENGTH:-8192}}"
  selected="$(run_root python3 "$helper" \
    --catalog "${SCRIPT_DIR}/model-catalog/catalog.lock.json" \
    --chat-model "${LLAMACPP_CHAT_MODEL_ID:-$LLAMACPP_MODEL_IDENTIFIER}" \
    --embedding-model "${LLAMACPP_EMBEDDING_MODEL_ID:-$LLAMACPP_EMBEDDING_MODEL_IDENTIFIER}" \
    --chat-context "${LLAMACPP_CHAT_CONTEXT_LENGTH:-8192}" \
    --chat-policy-max-context "$policy_max_context" \
    --embedding-context "${LLAMACPP_EMBEDDING_CONTEXT_LENGTH:-8192}" \
    --chat-gfx "${AI01_ROCM_GFX_VERSION:-none}" \
    --embedding-gfx "${AI02_ROCM_GFX_VERSION:-none}" \
    --accelerator "$accelerator" \
    --image-version "$LLAMACPP_IMAGE_VERSION" --format shell)" \
    || die "Pinned Q4/projector model selection is invalid"
  # The checked repository helper emits only quoted, managed export records.
  eval "$selected"
  LLAMACPP_CHAT_MODEL_SOURCE="${LLAMACPP_CHAT_MODEL_ID}@q4_k_m"
  if docker_cmd service inspect "${STACK_NAME}_openclaw-gateway" >/dev/null 2>&1; then
    local current_db current_tokens current_codex_profile
    current_db="$(service_env_value "${STACK_NAME}_openclaw-gateway" OPENCLAW_LANCEDB_DB_PATH)"
    if [[ "$current_db" =~ ^/home/ai/\.openclaw/memory/lancedb-[a-f0-9]{16}$ ]]; then
      OPENCLAW_LANCEDB_DB_PATH="$current_db"
    fi
    current_tokens="$(service_env_value "${STACK_NAME}_openclaw-gateway" OPENCLAW_MAX_TOKENS)"
    if [[ "$current_tokens" =~ ^[1-9][0-9]*$ ]]; then OPENCLAW_MAX_TOKENS="$current_tokens"; fi
    current_codex_profile="$(service_env_value "${STACK_NAME}_openclaw-gateway" OPENCLAW_CODEX_EXECUTION_PROFILE)"
    case "$current_codex_profile" in guardian|autonomous) OPENCLAW_CODEX_EXECUTION_PROFILE="$current_codex_profile" ;; esac
  fi
  local context_file="${LLAMACPP01_DATA}/state/.ai-stand/${INSTALLATION}/context.env"
  if run_root test -f "$context_file"; then
    # No sourcing of writable host data: check root-owned private state and
    # its generation before using the tested context and immutable images.
    local approved
    approved="$(run_root python3 - "$context_file" "$LLAMACPP_MODEL_CATALOG_FINGERPRINT" <<'PY'
from pathlib import Path
import re
import stat
import sys

p = Path(sys.argv[1])
for target, mode, kind in ((p.parent, 0o700, stat.S_ISDIR), (p, 0o600, stat.S_ISREG)):
    s = target.lstat()
    if s.st_uid != 0 or not kind(s.st_mode) or stat.S_IMODE(s.st_mode) != mode:
        raise SystemExit("Model context state must be private and root-owned")
values = {}
for line in p.read_text(encoding="utf-8").splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        if key in values:
            raise SystemExit("Duplicate model context state field")
        values[key] = value
if values.get("MODEL_FINGERPRINT") == sys.argv[2]:
    context = values.get("CHAT_CONTEXT_LENGTH", "")
    chat, embedding = values.get("CHAT_IMAGE_ID", ""), values.get("EMBEDDING_IMAGE_ID", "")
    if not re.fullmatch(r"[1-9][0-9]*", context) or not all(re.fullmatch(r"sha256:[a-f0-9]{64}", v) for v in (chat, embedding)):
        raise SystemExit("Model context state lacks approved image/context proof")
    tokens = values.get("OPENCLAW_MAX_TOKENS", "")
    if tokens and (not re.fullmatch(r"[1-9][0-9]*", tokens) or int(tokens) > int(context)):
        raise SystemExit("Invalid model response token state")
    print(context, chat, embedding, tokens)
PY
    )" || die "Invalid model context state"
    if [ -n "$approved" ]; then
      local approved_tokens
      read -r LLAMACPP_CHAT_CONTEXT_LENGTH LLAMACPP01_APPROVED_IMAGE LLAMACPP02_APPROVED_IMAGE approved_tokens <<<"$approved"
      if [ -n "$approved_tokens" ]; then OPENCLAW_MAX_TOKENS="$approved_tokens"; fi
    fi
  fi
  export LLAMACPP_CHAT_MODEL_SOURCE LLAMACPP_CHAT_MODEL_ID LLAMACPP_CHAT_MODEL_PATH LLAMACPP_CHAT_MODEL_SHA256 \
    LLAMACPP_CHAT_CONTEXT_LENGTH LLAMACPP_CHAT_PROJECTOR_PATH LLAMACPP_CHAT_PROJECTOR_SHA256 \
    LLAMACPP_EMBEDDING_MODEL_ID LLAMACPP_EMBEDDING_MODEL_PATH LLAMACPP_EMBEDDING_MODEL_SHA256 \
    LLAMACPP_EMBEDDING_CONTEXT_LENGTH LLAMACPP_EMBEDDING_DIMENSIONS LLAMACPP_MODEL_CATALOG_FINGERPRINT \
    LLAMACPP01_APPROVED_IMAGE LLAMACPP02_APPROVED_IMAGE OPENCLAW_LANCEDB_DB_PATH OPENCLAW_MAX_TOKENS OPENCLAW_CODEX_EXECUTION_PROFILE
}

export_model_images() {
  local accelerator="$1" approved
  case "$accelerator" in
    cpu) LLAMACPP01_RUNTIME_IMAGE="$LLAMACPP_CPU_IMAGE"; LLAMACPP02_RUNTIME_IMAGE="$LLAMACPP_CPU_IMAGE" ;;
    nvidia) LLAMACPP01_RUNTIME_IMAGE="$LLAMACPP_NVIDIA_IMAGE"; LLAMACPP02_RUNTIME_IMAGE="$LLAMACPP_NVIDIA_IMAGE" ;;
    amd) LLAMACPP01_RUNTIME_IMAGE="$LLAMACPP01_AMD_IMAGE"; LLAMACPP02_RUNTIME_IMAGE="$LLAMACPP02_AMD_IMAGE" ;;
    *) die "Unsupported model accelerator: $accelerator" ;;
  esac
  for approved in "${LLAMACPP01_APPROVED_IMAGE:-}" "${LLAMACPP02_APPROVED_IMAGE:-}"; do
    [ -z "$approved" ] || [[ "$approved" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Approved model image must be an immutable local ID"
  done
  LLAMACPP01_RUNTIME_IMAGE="${LLAMACPP01_APPROVED_IMAGE:-$LLAMACPP01_RUNTIME_IMAGE}"
  LLAMACPP02_RUNTIME_IMAGE="${LLAMACPP02_APPROVED_IMAGE:-$LLAMACPP02_RUNTIME_IMAGE}"
  export LLAMACPP_CPU_IMAGE LLAMACPP01_AMD_IMAGE LLAMACPP02_AMD_IMAGE LLAMACPP_NVIDIA_IMAGE \
    LLAMACPP01_RUNTIME_IMAGE LLAMACPP02_RUNTIME_IMAGE AI01_ROCM_GFX_VERSION AI02_ROCM_GFX_VERSION
}

ensure_llamacpp_runtime_groups() {
  local name service current group changed args
  for name in llamacpp01 llamacpp02; do
    service="${STACK_NAME}_${name}"
    [ "$(docker_cmd service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.User}}' "$service")" = '10000:20000' ] \
      || die "Native model service must run as 10000:20000: $name"
    current="$(docker_cmd service inspect --format '{{json .Spec.TaskTemplate.ContainerSpec.Groups}}' "$service")"
    local -a args=(--detach=true)
    changed=false
    # Docker's Swarm API supports supplementary groups even though its
    # legacy v3 Compose schema rejects group_add. Match the tested process
    # identity without retaining root or granting runtime capabilities.
    while IFS= read -r group; do
      case "$group" in 44|993|'') ;; *) args+=(--group-rm "$group"); changed=true ;; esac
    done < <(printf '%s' "$current" | jq -r '. // [] | .[]')
    for group in 44 993; do
      if ! printf '%s' "$current" | jq -e --arg value "$group" '(. // []) | index($value) != null' >/dev/null; then
        args+=(--group-add "$group"); changed=true
      fi
    done
    if [ "$changed" = true ]; then docker_cmd service update "${args[@]}" "$service" >/dev/null; fi
  done
}

# Create/update only the four model services. This stage cannot restart any
# consumer, replace Agentgateway's profile, access Secrets or prune services.
cmd_deploy_models() (
  load_os_info
  local accelerator="${ACCELERATOR}"
  if [ "$accelerator" = auto ]; then accelerator="$(detect_accelerator)"; fi
  validate_accelerator_compatibility "$accelerator"
  load_llamacpp_catalog_selection "$accelerator"
  export_model_images "$accelerator"
  local temp_dir
  temp_dir="$(mktemp -d /tmp/ai-stand-models.XXXXXX)"
  trap 'rm -f -- "$temp_dir/all.json" "$temp_dir/models.json"; rmdir -- "$temp_dir"' EXIT
  local -a compose_args=(-f "$COMPOSE_FILE")
  case "$accelerator" in
    amd) compose_args+=(-f "$COMPOSE_AMD_FILE") ;;
    nvidia) compose_args+=(-f "$COMPOSE_NVIDIA_FILE") ;;
  esac
  # Parse the baseline without installation/control-plane overlays. They
  # are irrelevant to model boot and may reference not-yet-created Secrets.
  export AUTHENTIK_IMAGE AUTHENTIK_POSTGRES_IMAGE AUTHENTIK_REDIS_IMAGE \
    OPENCLAW_IMAGE OPENWEBUI_IMAGE PORTAINER_IMAGE PORTAINER_AGENT_IMAGE \
    AGENTGATEWAY_IMAGE AGENTGATEWAY_POSTGRES_IMAGE DOCKER_SOCKET_PROXY_IMAGE
  docker_cmd compose --project-name "$STACK_NAME" "${compose_args[@]}" config --format json >"$temp_dir/all.json"
  python3 - "$temp_dir/all.json" "$temp_dir/models.json" <<'PY'
import json
from pathlib import Path
import sys

source = json.loads(Path(sys.argv[1]).read_text())
names = ("llamacpp01", "llamacpp02")
services = {name: source["services"][name] for name in names}
for service in services.values():
    # Compose's canonical JSON uses null for image-default command/entrypoint;
    # the legacy Swarm Compose parser expects those keys to be absent.
    for key in ("command", "entrypoint"):
        if service.get(key) is None:
            service.pop(key, None)
    for mount in service.get("volumes", []):
        if mount.get("type") == "tmpfs":
            # Compose canonical JSON emits the byte size as a decimal string;
            # the legacy Swarm parser requires a numeric long-mount value.
            for key in ("size", "mode"):
                if key in mount.get("tmpfs", {}):
                    mount["tmpfs"][key] = int(mount["tmpfs"][key])
    if service.get("ports") or service.get("secrets") or service.get("configs"):
        raise SystemExit("Model deployment must not publish ports or import control-plane Secrets")
    if set(service.get("networks", {})) != {"ai-models-backend"}:
        raise SystemExit("Unexpected model service network")
network = dict(source["networks"]["ai-models-backend"])
network.pop("name", None)
if network.get("driver") != "overlay" or network.get("attachable", False) is not False:
    raise SystemExit("Model backend network must remain a closed overlay")
Path(sys.argv[2]).write_text(json.dumps({"version": "3.8", "services": services, "networks": {"ai-models-backend": network}}))
PY
  docker_cmd stack config -c "$temp_dir/models.json" >/dev/null
  docker_cmd stack deploy --resolve-image never -c "$temp_dir/models.json" "$STACK_NAME"
  ensure_llamacpp_runtime_groups
  log "Only native model servers submitted for deployment"
)

require_completed_model_migration_before_deploy() {
  [ "$MODEL_MIGRATION_REQUIRED" = "1" ] || return 0
  [[ "${LLAMACPP01_APPROVED_IMAGE:-}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    && [[ "${LLAMACPP02_APPROVED_IMAGE:-}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "A full deployment of ${INSTALLATION} requires the immutable image IDs from matching tested context state"
  # Both verified fresh storage and an existing index require the migration
  # controller's matching completion receipt. Absent services are not proof
  # that persistent data is empty.
  local state_file="${AI_STAND_DATA_ROOT}/model-migration/${INSTALLATION}/state.json"
  if ! run_root python3 - "$state_file" "$LLAMACPP_MODEL_CATALOG_FINGERPRINT" "$LLAMACPP_EMBEDDING_MODEL_ID" "$LLAMACPP_EMBEDDING_DIMENSIONS" <<'PY'
import json
from pathlib import Path
import re
import stat
import sys

try:
    path, generation = Path(sys.argv[1]), sys.argv[2]
    if not re.fullmatch(r'[a-f0-9]{64}', generation):
        sys.exit(1)
    directory, metadata = path.parent.lstat(), path.lstat()
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != 0 or stat.S_IMODE(directory.st_mode) != 0o700:
        sys.exit(1)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) != 0o600:
        sys.exit(1)
    state = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(state, dict) or state.get('phase') != 'complete' or state.get('generation') != generation \
            or state.get('model') != sys.argv[3] or type(state.get('dimensions')) is not int \
            or state['dimensions'] != int(sys.argv[4]):
        sys.exit(1)
except (OSError, ValueError, TypeError):
    sys.exit(1)
PY
  then
    die "${INSTALLATION} requires a completed matching ${LLAMACPP_EMBEDDING_MODEL_ID}/${LLAMACPP_EMBEDDING_DIMENSIONS} migration or verified fresh-storage receipt; run model-migrate-q4 with passed canaries first. No deployment services were changed"
  fi
  # The first replacement Gateway must point at the completed generation and
  # its memory slot, not briefly reactivate an archived/default index.
  OPENCLAW_LANCEDB_ENABLED=1
  OPENCLAW_LANCEDB_DB_PATH="/home/ai/.openclaw/memory/lancedb-${LLAMACPP_MODEL_CATALOG_FINGERPRINT:0:16}"
  export OPENCLAW_LANCEDB_ENABLED OPENCLAW_LANCEDB_DB_PATH
}

cmd_configure_model_routing() {
  [ "$NODE_NAME" = ai01 ] || die "Model routing must be configured on the Agentgateway node ai01"
  local accelerator="$ACCELERATOR"
  if [ "$accelerator" = auto ]; then accelerator="$(detect_accelerator)"; fi
  load_llamacpp_catalog_selection "$accelerator"
  [[ "${LLAMACPP01_APPROVED_IMAGE:-}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    && [[ "${LLAMACPP02_APPROVED_IMAGE:-}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "Model routing requires approved immutable images and tested context state"
  local gateway_service="${STACK_NAME}_agentgateway" service replicas secret source="$AGENTGATEWAY_CONFIG_SOURCE"
  docker_cmd service inspect "$gateway_service" >/dev/null \
    || die "Agentgateway service is absent; a verified fresh installation uses full deploy after its fresh-storage receipt"
  if [ "$READONLY_MCP_ENABLED" = 1 ]; then
    # Render from the validated installation manifest and new generic base;
    # never deploy MCP services or change their Secret attachments here.
    render_readonly_mcp_profile
    source="$READONLY_MCP_RENDERED_AGENTGATEWAY_CONFIG"
    local mounted
    mounted="$(docker_cmd service inspect "$gateway_service" --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}')"
    while IFS= read -r secret; do
      [ -z "$secret" ] || printf '%s' "$mounted" | jq -e --arg expected "$secret" \
        'any(.[]?; .SecretName == $expected or .File.Name == $expected)' >/dev/null \
        || die "Personal MCP route requires an already mounted backend Secret; reconcile it before model maintenance"
    done < <(readonly_mcp_gateway_secret_names)
  fi
  local current_image desired_image_id current_image_id
  desired_image_id="$(docker_cmd image inspect "$AGENTGATEWAY_IMAGE" --format '{{.Id}}')" \
    || die "Pinned Agentgateway image must already be available locally"
  current_image="$(docker_cmd service inspect "$gateway_service" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
  current_image_id="$(docker_cmd image inspect "$current_image" --format '{{.Id}}' 2>/dev/null || true)"
  if run_root cmp -s "$source" "${AGENTGATEWAY_DATA}/config.yaml" \
    && [ "$(service_env_value "$gateway_service" AGENTGATEWAY_CHAT_MODEL_ID)" = "$LLAMACPP_CHAT_MODEL_ID" ] \
    && [ "$(service_env_value "$gateway_service" AGENTGATEWAY_EMBEDDING_MODEL_ID)" = "$LLAMACPP_EMBEDDING_MODEL_ID" ] \
    && [ "$current_image_id" = "$desired_image_id" ]; then
    if [ "$READONLY_MCP_ENABLED" = 1 ]; then
      rm -f -- "$READONLY_MCP_RENDER_DIR/config.yaml" "$READONLY_MCP_RENDER_DIR/compose.yaml"
      rmdir -- "$READONLY_MCP_RENDER_DIR"
    fi
    wait_service_ready "$gateway_service"
    log "Agentgateway native model routing already matches; running consumers and routes preserved"
    return 0
  fi
  # A changed route must never dispatch into running old-vector consumers.
  for service in openclaw-gateway openwebui; do
    if docker_cmd service inspect "${STACK_NAME}_${service}" >/dev/null 2>&1; then
      replicas="$(docker_cmd service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "${STACK_NAME}_${service}")"
      [ "$replicas" = 0 ] || die "Stop model consumers before configuring migration routing: $service"
    fi
  done
  install_if_changed "$source" "${AGENTGATEWAY_DATA}/config.yaml" 0640 "$APP_UID" "$APP_GID"
  if [ "$READONLY_MCP_ENABLED" = 1 ]; then
    rm -f -- "$READONLY_MCP_RENDER_DIR/config.yaml" "$READONLY_MCP_RENDER_DIR/compose.yaml"
    rmdir -- "$READONLY_MCP_RENDER_DIR"
  fi
  docker_cmd service update --detach=true --no-resolve-image --image "$AGENTGATEWAY_IMAGE" --force \
    --env-rm AGENTGATEWAY_CHAT_MODEL_ID --env-add "AGENTGATEWAY_CHAT_MODEL_ID=$LLAMACPP_CHAT_MODEL_ID" \
    --env-rm AGENTGATEWAY_EMBEDDING_MODEL_ID --env-add "AGENTGATEWAY_EMBEDDING_MODEL_ID=$LLAMACPP_EMBEDDING_MODEL_ID" \
    "$gateway_service" >/dev/null
  sleep 2
  wait_service_ready "$gateway_service"
  log "Agentgateway model routing applied; personal MCP routes and consumer replicas preserved"
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
    [ "$ACCELERATOR" != "auto" ] || die "Deploy from ${NODE_NAME} requires explicit --accelerator for llama.cpp, or run deploy from ai01"
    accelerator="$ACCELERATOR"
  fi

  local compose_args=()
  load_llamacpp_catalog_selection "$accelerator"
  require_completed_model_migration_before_deploy
  export_model_images "$accelerator"
  # Compose interpolation reads only exported variables.  Keep the Coder
  # public URLs installation-specific from the very first task start; the
  # subsequent service-env reconciliation remains a drift repair, not the
  # mechanism that makes OIDC bootable.
  export AUTHENTIK_HOST CODER_HOST GITEA_HOST GITEA_SSH_PORT \
    AUTHENTIK_IMAGE AUTHENTIK_POSTGRES_IMAGE AUTHENTIK_REDIS_IMAGE \
    AI01_ROCM_GFX_VERSION AI02_ROCM_GFX_VERSION \
    LLAMACPP_CPU_IMAGE LLAMACPP01_AMD_IMAGE LLAMACPP02_AMD_IMAGE LLAMACPP_NVIDIA_IMAGE \
    OPENCLAW_IMAGE OPENWEBUI_IMAGE PORTAINER_IMAGE PORTAINER_AGENT_IMAGE \
    AGENTGATEWAY_IMAGE \
    GITEA_IMAGE GITEA_POSTGRES_IMAGE DOCKER_SOCKET_PROXY_IMAGE \
    CODER_IMAGE CODER_POSTGRES_IMAGE AGENTGATEWAY_POSTGRES_IMAGE
  if [ "$CODER_ENABLED" = "1" ]; then
    [ "$CODER_HOST" != "coder.local" ] \
      || die "CODER_ENABLED requires an installation-specific CODER_HOST"
    [ "$AUTHENTIK_HOST" != "authentik.local" ] \
      || die "CODER_ENABLED requires an installation-specific AUTHENTIK_HOST"
    [ -r "${INSTALLATION_DIR}/compose.coder.yaml" ] \
      || die "CODER_ENABLED requires ${INSTALLATION_DIR}/compose.coder.yaml with the public Coder URLs"
    log "Coder public endpoints: access=https://${CODER_HOST}; oidc-host=${AUTHENTIK_HOST}"
  fi
  if [ "${GITEA_ENABLED:-0}" = "1" ]; then
    [ "$GITEA_HOST" != "gitea.local" ] \
      || die "GITEA_ENABLED requires an installation-specific GITEA_HOST"
    log "Gitea public endpoints: https://${GITEA_HOST}; ssh=${GITEA_SSH_PORT}"
  fi
  ensure_ai_stand_secrets
  # This writes the generated Agentgateway config and Compose overlay only
  # after the protected inventory has passed its complete, fail-closed
  # validation. With the feature disabled it restores the generic config.
  install_agentgateway_config
  while IFS= read -r arg; do
    compose_args+=("$arg")
  done < <(compose_args_for_accelerator "$accelerator")

  export_controller_environment
  # The Gateway's service key directory (compose.yaml) follows the installation's storage root.
  export SSH_SERVICE_KEYS_ROOT
  # Validation only. The rendered configuration carries literal credentials
  # (Authentik bootstrap and secret key, database passwords, gateway keys), so
  # it must not be left behind in a world-readable temporary file.
  docker_cmd stack config "${compose_args[@]}" >/dev/null
  docker_cmd stack deploy --resolve-image never "${compose_args[@]}" "$STACK_NAME"
  ensure_llamacpp_runtime_groups
  reconcile_coder_profile_urls
  remove_obsolete_services
  apply_installation_service_env
  sync_agentgateway_llm_jwks soft
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

  # The controller container runs this command with the checkout mounted
  # read-only; the Open WebUI access configuration is maintained by the host
  # and deploy stages, so only the snapshot is refreshed here.
  OPENWEBUI_MODEL_ACCESS_SKIP_INSTALL=1
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

# Five-minute model ACL and MCP reconciliation share a limited identity reader.
# Both list users/groups; only enabled MCP provisioning needs change_user to
# write its non-secret provisioning status. Never use the bootstrap bearer. Keep
# that capability on a dedicated non-interactive service account; the only
# copy of its bearer is a root-only host file consumed by the reconciler.
ensure_readonly_mcp_authentik_service_token() {
  [ "$NODE_NAME" = "ai01" ] || return 0

  local server_container secret_file
  server_container="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$server_container" ] || die "Cannot find Authentik server for the shared identity reader"
  secret_file="${AI_STAND_SECRETS_DIR}/readonly-mcp-authentik-api-token"

  # The marker is removed by sed before anything can reach this process's
  # stdout. The token is streamed straight into the root-only file rather
  # than retained in a shell variable, command line, Docker label or log.
  if ! docker_cmd exec -i -e AK_SERVICE_ACCOUNT=ai-stand-readonly-mcp-reconciler \
    -e "AK_MCP_STATUS_WRITES=${READONLY_MCP_ENABLED}" "$server_container" ak shell <<'PYEOF' \
    | sed -n 's/^AI_STAND_READONLY_MCP_TOKEN //p' \
    | run_root tee "$secret_file" >/dev/null
import os
from authentik.core.models import Token, TokenIntents, User
from authentik.rbac.models import Permission, Role

username = os.environ["AK_SERVICE_ACCOUNT"]
user, _created = User.objects.get_or_create(
    username=username,
    defaults={
        "name": "ai-stand shared identity reader",
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
permissions = [("group", "view_group"), ("user", "view_user")]
if os.environ.get("AK_MCP_STATUS_WRITES") == "1":
    permissions.append(("user", "change_user"))
else:
    # assign_perms adds permissions; explicitly revoke the optional write
    # capability when an existing installation disables MCP provisioning.
    role.remove_perms([Permission.objects.get(
        content_type__app_label="authentik_core", content_type__model="user", codename="change_user",
    )])
for model, codename in permissions:
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
    die "Cannot create the limited shared Authentik identity-reader token"
  fi
  run_root chown root:root "$secret_file"
  run_root chmod 0600 "$secret_file"
  run_root test -s "$secret_file" \
    || die "Authentik service account did not return an identity-reader token"
  log "Limited shared Authentik identity reader is ready"
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

  # Secret-bearing values go through the environment (-e VARNAME, no
  # =value) rather than --env VARNAME=value, so they never appear as
  # literal text in this process's own argv/cmdline - same pattern as
  # sync_openwebui_persistent_config().
  (
    local -x AUTHENTIK_API_TOKEN="$AUTHENTIK_BOOTSTRAP_TOKEN"
    local -x AUTHENTIK_OPENWEBUI_CLIENT_SECRET="$AUTHENTIK_OPENWEBUI_CLIENT_SECRET"
    local -x AUTHENTIK_PORTAINER_CLIENT_SECRET="$AUTHENTIK_PORTAINER_CLIENT_SECRET"
    local -x AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET="$AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET"
    local -x AUTHENTIK_CODER_CLIENT_SECRET="$AUTHENTIK_CODER_CLIENT_SECRET"
    local -x AUTHENTIK_GITEA_CLIENT_SECRET="${AUTHENTIK_GITEA_CLIENT_SECRET:-}"
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
      -e AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET \
      -e AUTHENTIK_CODER_CLIENT_SECRET \
      -e AUTHENTIK_GITEA_CLIENT_SECRET \
      --env "AUTHENTIK_OPENWEBUI_URL=https://${OPENWEBUI_HOST}" \
      --env "AUTHENTIK_OPENCLAW_URL=https://${OPENCLAW_HOST}" \
      --env "AUTHENTIK_PORTAINER_URL=https://${PORTAINER_HOST}" \
      --env "AUTHENTIK_AGENTGATEWAY_URL=https://${AGENTGATEWAY_HOST}" \
      --env "AUTHENTIK_CODER_URL=https://${CODER_HOST}" \
      --env "AUTHENTIK_GITEA_ENABLED=$( [ "${GITEA_ENABLED:-0}" = "1" ] && printf true || printf false )" \
      --env "AUTHENTIK_GITEA_URL=https://${GITEA_HOST}" \
      "$AUTHENTIK_CONFIGURATOR_IMAGE"
  )

  # The ai-stand-llm provider exists now: hand its signing keys to Agentgateway
  # first (this waits for the service to be ready), then force the fresh load
  # below, so the two asynchronous service updates never overlap.
  sync_agentgateway_llm_jwks hard

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

publish_coder_template() {
  local language="$1"
  local display_name="$2"
  local slug="${language}-personal"
  local source_dir="${SCRIPT_DIR}/docker/coder-templates/${language}"
  local container postgres_container

  [ -d "$source_dir" ] || die "Coder template source is missing: ${source_dir}"
  container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_coder" --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container" ] || die "No local Coder container is running on ai02"
  postgres_container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_coder-postgresql" --format '{{.ID}}')"
  [ -n "$postgres_container" ] && [[ "$postgres_container" != *$'\n'* ]] \
    || die "Exactly one native Coder PostgreSQL container is required for read-only policy verification"
  # The templates mount the owner's key directory only when they are told where the keys live.
  local -a variable_args=()
  if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then
    variable_args+=(--variable "ssh_keys_root=${SSH_KEYS_ROOT}")
  fi
  # Approved Free policy: native creation atomically grants Everyone read/use,
  # not edit. Existing private templates require an explicit migration choice.
  run_root python3 "${SCRIPT_DIR}/docker/coder-templates/publisher.py" publish \
    --coder-container "$container" \
    --postgres-container "$postgres_container" --access-policy shared-vetted \
    --token-file "$CODER_TEMPLATE_PUBLISHER_TOKEN_FILE" \
    --source-dir "$source_dir" --slug "$slug" --display-name "$display_name" \
    "${variable_args[@]}"
}

ensure_coder_template_publisher() {
  local container postgres_container
  container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_coder" --format '{{.ID}}' | head -n 1 || true)"
  postgres_container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_coder-postgresql" --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container" ] && [ -n "$postgres_container" ] \
    || die "Coder and PostgreSQL must be running locally before publishing templates"
  command_exists python3 || die "Coder template publisher requires host Python 3"
  run_root python3 "${SCRIPT_DIR}/docker/coder-templates/publisher.py" bootstrap \
    --coder-container "$container" --postgres-container "$postgres_container" \
    --image "$CODER_IMAGE" --token-file "$CODER_TEMPLATE_PUBLISHER_TOKEN_FILE" \
    --postgres-password-file "${AI_STAND_SECRETS_DIR}/coder-postgres-password" \
    --admin-password-file "${AI_STAND_SECRETS_DIR}/coder-admin-password" \
    --admin-username "$CODER_ADMIN_USERNAME" --admin-email "$CODER_ADMIN_EMAIL"
}

cmd_templates() {
  load_os_info
  [ "$CODER_ENABLED" = "1" ] || { log "Coder is disabled; no templates to publish"; return 0; }
  [ "$NODE_NAME" = "ai02" ] || die "templates must run on ai02, where Coder is placed"
  wait_service_ready "${STACK_NAME}_coder"
  wait_service_ready "${STACK_NAME}_docker-socket-proxy-coder"
  check_coder_docker_endpoint

  # Missing/expired tokens are bootstrapped without changing the public
  # password=false runtime. Permission/auth failures stop the stage; they
  # must not be reported as successful deployment with no templates.
  ensure_coder_template_publisher
  publish_coder_template csharp 'C#'
  publish_coder_template python Python
}

cmd_configure_gitea() {
  [ "${GITEA_ENABLED:-0}" = "1" ] || die "configure-gitea requires GITEA_ENABLED=1"
  [ "$NODE_NAME" = "ai01" ] || die "configure-gitea must run on ai01, where Gitea is placed"

  wait_service_ready "${STACK_NAME}_gitea-postgresql"
  wait_service_ready "${STACK_NAME}_gitea"
  local container postgres_container source_record source_id source_type source_provider
  container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_gitea" --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container" ] || die "No local Gitea container is running on ai01"
  postgres_container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_gitea-postgresql" --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$postgres_container" ] || die "No local Gitea PostgreSQL container is running on ai01"

  # `login_source.name` is unique in Gitea.  Inspect precisely that one row
  # through a fixed, read-only query before writing anything.  Do not use an
  # interpolated SQL value: the managed source name is intentionally a literal
  # and the actual mutation below stays on Gitea's supported native CLI.
  source_record="$(
    docker_cmd exec "$postgres_container" \
      psql -X -qAt -F $'\t' -U gitea -d gitea \
        -c "SELECT id, type, COALESCE(cfg::jsonb ->> 'Provider', '') FROM login_source WHERE name = 'authentik';"
  )" || die "Cannot inspect the exact Gitea authentication source"

  source_id=""
  if [ -n "$source_record" ]; then
    [ "$(printf '%s\n' "$source_record" | wc -l | tr -d '[:space:]')" = "1" ] \
      || die "Conflicting Gitea authentication sources named authentik"
    IFS=$'\t' read -r source_id source_type source_provider <<EOF
$source_record
EOF
    [[ "$source_id" =~ ^[1-9][0-9]*$ ]] \
      || die "Malformed Gitea authentication source named authentik"
    [ "$source_type" = "6" ] && [ "$source_provider" = "openidConnect" ] \
      || die "Conflicting Gitea authentication source named authentik is not the managed OAuth2/OpenID Connect source"
  fi

  # A managed exact OAuth/OIDC source is updated on every deployment, so
  # corrected scopes and Authentik settings converge rather than being hidden
  # by a broad `grep`.  Gitea 28 uses a StringSlice flag: each requested scope
  # must have its own --scopes argument; `openid` itself is implicit for OIDC.
  # The Docker Secret is read only inside the short-lived Gitea exec and is
  # never written to stdout, stderr, SQL or host environment.
  if [ -n "$source_id" ]; then
    docker_cmd exec \
      -e "AUTHENTIK_HOST=${AUTHENTIK_HOST}" \
      -e "GITEA_AUTH_SOURCE_ID=${source_id}" \
      "$container" sh -eu -c '
        secret="$(cat /run/secrets/ai-stand-authentik-gitea-client-secret)"
        exec gitea admin auth update-oauth \
          --config /etc/gitea/app.ini \
          --id "$GITEA_AUTH_SOURCE_ID" \
          --name authentik \
          --provider openidConnect \
          --key gitea \
          --secret "$secret" \
          --auto-discover-url "https://${AUTHENTIK_HOST}/application/o/gitea/.well-known/openid-configuration" \
          --scopes profile --scopes email --scopes groups \
          --group-claim-name groups \
          --admin-group ai-admins \
          --skip-local-2fa
      ' >/dev/null
  else
    docker_cmd exec \
      -e "AUTHENTIK_HOST=${AUTHENTIK_HOST}" \
      "$container" sh -eu -c '
        secret="$(cat /run/secrets/ai-stand-authentik-gitea-client-secret)"
        exec gitea admin auth add-oauth \
          --config /etc/gitea/app.ini \
          --name authentik \
          --provider openidConnect \
          --key gitea \
          --secret "$secret" \
          --auto-discover-url "https://${AUTHENTIK_HOST}/application/o/gitea/.well-known/openid-configuration" \
          --scopes profile --scopes email --scopes groups \
          --group-claim-name groups \
          --admin-group ai-admins \
          --skip-local-2fa
      ' >/dev/null
  fi
  log "Gitea Authentik OIDC source is ready"
}

# --- Gitea SSH-key synchronizer (docker/gitea-ssh-sync) -----------------------------------------------------------------
# The service registers each ai-users member's SSH public key (an Authentik
# attribute) in their Gitea account. It runs as an ordinary Swarm service with
# two Docker secrets: a view-only Authentik service token and the token of a
# dedicated local Gitea administrator (Gitea has no narrower token that can
# manage other users' keys). Both credentials are issued by services that must
# already be running, so the service is deployed by this stage, alone, after
# they exist - see compose.gitea-ssh-sync.yaml.
GITEA_SSH_SYNC_ACCOUNT="ai-stand-ssh-sync"

# Read-only Authentik identity for the synchronizer: it may only view users
# (their attributes carry the public key) and groups. The token is stable
# (get_or_create), so a re-run returns the same value.
ensure_gitea_ssh_sync_authentik_token() {
  local server_container secret_file candidate
  server_container="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$server_container" ] || die "Cannot find the Authentik server for the Gitea SSH-key synchronizer"
  secret_file="${AI_STAND_SECRETS_DIR}/gitea-ssh-sync-authentik-api-token"
  candidate="${secret_file}.new"
  run_root rm -f "$candidate"

  # The marker is removed by sed before anything can reach this process's
  # stdout; the token goes straight into a root-only file, never a shell
  # variable, command line or log.
  if ! docker_cmd exec -i "$server_container" ak shell <<'PYEOF' \
    | sed -n 's/^AI_STAND_GITEA_SSH_SYNC_TOKEN //p' \
    | run_root tee "$candidate" >/dev/null
from authentik.core.models import Token, TokenIntents, User
from authentik.rbac.models import Permission, Role

username = "ai-stand-gitea-ssh-sync"
user, _created = User.objects.get_or_create(
    username=username,
    defaults={"name": "ai-stand Gitea SSH-key synchronizer", "type": "service_account", "is_active": True},
)
if user.type != "service_account":
    raise RuntimeError("existing Gitea SSH-key synchronizer identity is not a service account")
if not user.is_active:
    user.is_active = True
    user.save(update_fields=["is_active"])

role, _created = Role.objects.get_or_create(name=username)
role.assign_perms([
    Permission.objects.get(content_type__app_label="authentik_core", content_type__model=model, codename=codename)
    for model, codename in (("group", "view_group"), ("user", "view_user"))
])
user.roles.add(role)

token, _created = Token.objects.get_or_create(
    identifier=username,
    defaults={"user": user, "intent": TokenIntents.INTENT_API, "expiring": False},
)
if token.user_id != user.pk or token.intent != TokenIntents.INTENT_API:
    raise RuntimeError("existing Gitea SSH-key synchronizer token has an unexpected owner or intent")
if token.expiring:
    token.expiring = False
    token.expires = None
    token.save(update_fields=["expiring", "expires"])
print("AI_STAND_GITEA_SSH_SYNC_TOKEN " + token.key)
PYEOF
  then
    run_root rm -f "$candidate"
    die "Cannot create the Gitea SSH-key synchronizer's Authentik service token"
  fi
  run_root test -s "$candidate" \
    || { run_root rm -f "$candidate"; die "Authentik did not return the Gitea SSH-key synchronizer token"; }
  run_root chown root:root "$candidate"
  run_root chmod 0600 "$candidate"
  if run_root test -s "$secret_file" && run_root cmp -s "$candidate" "$secret_file"; then
    run_root rm -f "$candidate"
  else
    run_root mv -f "$candidate" "$secret_file"
    GITEA_SSH_SYNC_AUTHENTIK_TOKEN_CHANGED=1
  fi
  log "Gitea SSH-key synchronizer's Authentik service identity is ready"
}

# True when the stored token authenticates as the synchronizer's administrator.
# The token reaches the container through stdin, never a command line.
gitea_ssh_sync_token_works() {
  local container="$1" secret_file="$2" answer
  run_root test -s "$secret_file" || return 1
  answer="$(run_root cat "$secret_file" | docker_cmd exec -i "$container" sh -c \
    'T="$(cat)"; exec wget -qO- --header "Authorization: token $T" http://127.0.0.1:3000/api/v1/user' 2>/dev/null)" || return 1
  printf '%s' "$answer" \
    | jq -e --arg user "$GITEA_SSH_SYNC_ACCOUNT" '.login == $user and .is_admin == true' >/dev/null 2>&1
}

# A dedicated local administrator without a usable password (sign-in forms and
# basic authentication are disabled anyway) and an access token limited to the
# admin and user API scopes. Gitea shows a token once; a lost or broken token is
# replaced by a new one under a new name.
ensure_gitea_ssh_sync_gitea_token() {
  local container secret_file candidate admin_list
  container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_gitea" --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container" ] || die "No local Gitea container is running on ai01"
  secret_file="${AI_STAND_SECRETS_DIR}/gitea-ssh-sync-gitea-token"

  if gitea_ssh_sync_token_works "$container" "$secret_file"; then
    log "Gitea SSH-key synchronizer's administrator token is valid"
    return 0
  fi

  admin_list="$(docker_cmd exec "$container" gitea --config /etc/gitea/app.ini admin user list --admin)" \
    || die "Cannot list Gitea administrators"
  if ! printf '%s\n' "$admin_list" | awk -v user="$GITEA_SSH_SYNC_ACCOUNT" 'NR > 1 && $2 == user { found = 1 } END { exit !found }'; then
    # The generated password is printed once by the CLI and deliberately dropped.
    docker_cmd exec "$container" gitea --config /etc/gitea/app.ini admin user create \
      --username "$GITEA_SSH_SYNC_ACCOUNT" \
      --email "${GITEA_SSH_SYNC_ACCOUNT}@${GITEA_HOST}" \
      --admin --random-password --must-change-password=false >/dev/null \
      || die "Cannot create the Gitea SSH-key synchronizer administrator"
    log "Created the Gitea administrator ${GITEA_SSH_SYNC_ACCOUNT}"
  fi

  candidate="${secret_file}.new"
  run_root rm -f "$candidate"
  if ! docker_cmd exec "$container" gitea --config /etc/gitea/app.ini admin user generate-access-token \
      --username "$GITEA_SSH_SYNC_ACCOUNT" \
      --token-name "ai-stand-ssh-sync-$(date -u +%Y%m%dT%H%M%SZ)" \
      --scopes write:admin,read:user --raw | run_root tee "$candidate" >/dev/null; then
    run_root rm -f "$candidate"
    die "Cannot issue the Gitea SSH-key synchronizer's administrator token"
  fi
  run_root chown root:root "$candidate"
  run_root chmod 0600 "$candidate"
  if ! run_root grep -Eq '^[0-9a-f]{40}$' "$candidate"; then
    run_root rm -f "$candidate"
    die "Gitea returned an unexpected token format for the SSH-key synchronizer"
  fi
  run_root mv -f "$candidate" "$secret_file"
  GITEA_SSH_SYNC_GITEA_TOKEN_CHANGED=1
  gitea_ssh_sync_token_works "$container" "$secret_file" \
    || die "The new Gitea SSH-key synchronizer token does not authenticate as an administrator"
  log "Gitea SSH-key synchronizer's administrator token is ready"
}

# The Gitea account of each service account (SSH_SERVICE_ACCOUNTS): a plain local account without a usable password, not an
# administrator and owning nothing. The owner gives it access to the repositories it may use; its SSH public key is
# registered by this synchronizer from the Authentik account of the same name (which configure-ssh-key-delivery created
# and gave a key). Created only when missing.
ensure_gitea_service_accounts() {
  local container user_list username
  [ -n "$SSH_SERVICE_ACCOUNTS" ] || return 0
  container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_gitea" --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$container" ] || die "No local Gitea container is running on ai01"
  user_list="$(docker_cmd exec "$container" gitea --config /etc/gitea/app.ini admin user list)" \
    || die "Cannot list Gitea accounts"
  for username in $(printf '%s' "$SSH_SERVICE_ACCOUNTS" | tr ',' '\n' | sed -n 's/^[^=]*=//p'); do
    if ! printf '%s\n' "$user_list" | awk -v user="$username" 'NR > 1 && $2 == user { found = 1 } END { exit !found }'; then
      # The generated password is printed once by the CLI and deliberately dropped.
      docker_cmd exec "$container" gitea --config /etc/gitea/app.ini admin user create \
        --username "$username" --email "${username}@${GITEA_HOST}" \
        --random-password --must-change-password=false >/dev/null \
        || die "Cannot create the Gitea account ${username}"
      log "Created the Gitea account ${username}"
    fi
  done
}

# Docker secrets cannot be edited: when a credential was replaced, remove the
# service and the stale secret first so the new value is what the next task reads.
ensure_gitea_ssh_sync_secret() {
  local secret_name="$1" file_name="$2" changed="$3"
  if [ "$changed" = "1" ] && docker_cmd secret inspect "$secret_name" >/dev/null 2>&1; then
    docker_cmd service rm "${STACK_NAME}_gitea-ssh-sync" >/dev/null 2>&1 || true
    docker_cmd secret rm "$secret_name" >/dev/null
    log "Replaced stale Docker secret: ${secret_name}"
  fi
  ensure_docker_secret_from_value "$secret_name" "$(run_root cat "${AI_STAND_SECRETS_DIR}/${file_name}")"
}

cmd_configure_gitea_ssh_sync() {
  [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ] || die "configure-gitea-ssh-sync requires GITEA_SSH_SYNC_ENABLED=1"
  [ "${GITEA_ENABLED:-0}" = "1" ] || die "configure-gitea-ssh-sync requires GITEA_ENABLED=1"
  [ "$NODE_NAME" = "ai01" ] || die "configure-gitea-ssh-sync must run on ai01, where Gitea is placed"
  docker_cmd image inspect "$GITEA_SSH_SYNC_IMAGE" >/dev/null 2>&1 \
    || die "Missing image ${GITEA_SSH_SYNC_IMAGE}; run apply.sh images on ai01 first"

  wait_service_ready "${STACK_NAME}_authentik-server"
  wait_service_ready "${STACK_NAME}_gitea-postgresql"
  wait_service_ready "${STACK_NAME}_gitea"

  GITEA_SSH_SYNC_AUTHENTIK_TOKEN_CHANGED=0
  GITEA_SSH_SYNC_GITEA_TOKEN_CHANGED=0
  ensure_gitea_ssh_sync_authentik_token
  ensure_gitea_ssh_sync_gitea_token

  # The synchronizer trusts only accounts created through this OIDC source.
  local postgres_container auth_source_id
  postgres_container="$(docker_cmd ps --filter "label=com.docker.swarm.service.name=${STACK_NAME}_gitea-postgresql" --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$postgres_container" ] || die "No local Gitea PostgreSQL container is running on ai01"
  auth_source_id="$(docker_cmd exec "$postgres_container" \
    psql -X -qAt -U gitea -d gitea \
      -c "SELECT id FROM login_source WHERE name = 'authentik' AND type = 6;")" \
    || die "Cannot read the Gitea authentication source"
  [[ "$auth_source_id" =~ ^[1-9][0-9]*$ ]] \
    || die "The Gitea Authentik source is missing; run configure-gitea first"

  ensure_gitea_ssh_sync_secret ai-stand-gitea-ssh-sync-authentik-token gitea-ssh-sync-authentik-api-token \
    "$GITEA_SSH_SYNC_AUTHENTIK_TOKEN_CHANGED"
  ensure_gitea_ssh_sync_secret ai-stand-gitea-ssh-sync-gitea-token gitea-ssh-sync-gitea-token \
    "$GITEA_SSH_SYNC_GITEA_TOKEN_CHANGED"

  ensure_gitea_service_accounts
  GITEA_SSH_SYNC_SERVICE_ACCOUNTS="$(printf '%s' "$SSH_SERVICE_ACCOUNTS" | tr ',' '\n' | sed -n 's/^[^=]*=//p' | paste -sd, -)"
  export STACK_NAME GITEA_SSH_SYNC_IMAGE GITEA_SSH_SYNC_APPLY="${GITEA_SSH_SYNC_APPLY:-1}"
  export GITEA_SSH_SYNC_AUTH_SOURCE_ID="$auth_source_id" GITEA_SSH_SYNC_SERVICE_ACCOUNTS
  docker_cmd stack config -c "$COMPOSE_GITEA_SSH_SYNC_FILE" >/dev/null
  docker_cmd stack deploy --resolve-image never -c "$COMPOSE_GITEA_SSH_SYNC_FILE" "$STACK_NAME"
  wait_gitea_ssh_sync_running
  log "Gitea SSH-key synchronizer is running (apply=${GITEA_SSH_SYNC_APPLY:-1})"
}

# wait_service_ready waits up to three hours for a service that cannot start;
# this optional service should fail fast instead.
wait_gitea_ssh_sync_running() {
  local service="${STACK_NAME}_gitea-ssh-sync" replicas
  local deadline=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    replicas="$(docker_cmd service ls --filter "name=${service}" --format '{{.Name}} {{.Replicas}}' | awk -v name="$service" '$1 == name { print $2 }')"
    if [ "$replicas" = "1/1" ]; then
      log "Service ready: ${service}"
      return 0
    fi
    sleep 5
  done
  docker_cmd service ps "$service" --no-trunc || true
  die "Service did not become ready within five minutes: ${service}"
}

ensure_ssh_key_delivery_authentik_token() {
  local server_container secret_file candidate
  server_container="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$server_container" ] || die "Cannot find the Authentik server for the SSH key delivery"
  secret_file="${AI_STAND_SECRETS_DIR}/ssh-key-delivery-authentik-api-token"
  candidate="${secret_file}.new"
  run_root rm -f "$candidate"

  # The marker is removed by sed before anything can reach this process's
  # stdout; the token goes straight into a root-only file, never a shell
  # variable, command line or log.
  if ! docker_cmd exec -i "$server_container" ak shell <<'PYEOF' \
    | sed -n 's/^AI_STAND_SSH_KEY_DELIVERY_TOKEN //p' \
    | run_root tee "$candidate" >/dev/null
from authentik.core.models import Token, TokenIntents, User
from authentik.rbac.models import Permission, Role

username = "ai-stand-ssh-key-delivery"
user, _created = User.objects.get_or_create(
    username=username,
    defaults={"name": "ai-stand SSH key delivery", "type": "service_account", "is_active": True},
)
if user.type != "service_account":
    raise RuntimeError("existing SSH key delivery identity is not a service account")
if not user.is_active:
    user.is_active = True
    user.save(update_fields=["is_active"])

role, _created = Role.objects.get_or_create(name=username)
role.assign_perms([
    Permission.objects.get(content_type__app_label="authentik_core", content_type__model=model, codename=codename)
    for model, codename in (("group", "view_group"), ("user", "view_user"))
])
user.roles.add(role)

token, _created = Token.objects.get_or_create(
    identifier=username,
    defaults={"user": user, "intent": TokenIntents.INTENT_API, "expiring": False},
)
if token.user_id != user.pk or token.intent != TokenIntents.INTENT_API:
    raise RuntimeError("existing SSH key delivery token has an unexpected owner or intent")
if token.expiring:
    token.expiring = False
    token.expires = None
    token.save(update_fields=["expiring", "expires"])
print("AI_STAND_SSH_KEY_DELIVERY_TOKEN " + token.key)
PYEOF
  then
    run_root rm -f "$candidate"
    die "Cannot create the SSH key delivery's Authentik service token"
  fi
  run_root test -s "$candidate" \
    || { run_root rm -f "$candidate"; die "Authentik did not return the SSH key delivery token"; }
  run_root chown root:root "$candidate"
  run_root chmod 0600 "$candidate"
  if run_root test -s "$secret_file" && run_root cmp -s "$candidate" "$secret_file"; then
    run_root rm -f "$candidate"
  else
    run_root mv -f "$candidate" "$secret_file"
    SSH_KEY_DELIVERY_AUTHENTIK_TOKEN_CHANGED=1
  fi
  log "SSH key delivery's Authentik service identity is ready"
}

# The Authentik accounts that hold the dedicated keys of services (SSH_SERVICE_ACCOUNTS=name=username,...). They are
# service accounts, so they cannot sign in and are in no group. An account without a private key gets a fresh Ed25519
# pair (OpenSSH format, no passphrase) in the attributes of a person's key, generated inside Authentik so the private
# half never reaches this shell, a log or a file; a key that is already there - generated earlier or put there by the
# owner - is never replaced. Created and generated only when missing, so a rerun changes nothing.
ensure_ssh_key_delivery_service_accounts() {
  local server_container usernames
  usernames="$(printf '%s' "$SSH_SERVICE_ACCOUNTS" | tr ',' '\n' | sed -n 's/^[^=]*=//p' | paste -sd, -)"
  [ -n "$usernames" ] || return 0
  server_container="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$server_container" ] || die "Cannot find the Authentik server for the SSH key delivery"
  docker_cmd exec -i -e "AI_STAND_SERVICE_ACCOUNTS=${usernames}" "$server_container" ak shell <<'PYEOF' \
    | sed -n 's/^AI_STAND_SERVICE_ACCOUNT //p' | while IFS= read -r line; do log "service key account: ${line}"; done
import os
from authentik.core.models import User
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

for username in filter(None, os.environ["AI_STAND_SERVICE_ACCOUNTS"].split(",")):
    user, created = User.objects.get_or_create(
        username=username,
        defaults={"name": "ai-stand service SSH key", "type": "service_account", "is_active": True},
    )
    if user.type != "service_account":
        raise RuntimeError("the account for a service key exists but is not a service account")
    attributes = dict(user.attributes or {})
    state = "created" if created else "exists"
    if not str(attributes.get("ai_stand_git_ssh_private_key") or "").strip():
        key = Ed25519PrivateKey.generate()
        attributes["ai_stand_git_ssh_private_key"] = key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, serialization.NoEncryption()).decode()
        attributes["ai_stand_git_ssh_public_key"] = key.public_key().public_bytes(
            serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode() + " " + username
        user.attributes = attributes
        user.save(update_fields=["attributes"])
        state += ", key generated"
    print("AI_STAND_SERVICE_ACCOUNT " + username + " " + state)
PYEOF
}

# The sender and the receiver authenticate each other with one shared bearer token (hex, so it fits the services'
# credential syntax); the file is created once and never rotated by this script.
ensure_ssh_key_delivery_secret() {
  local secret_name="$1" file_name="$2" changed="$3"
  if [ "$changed" = "1" ] && docker_cmd secret inspect "$secret_name" >/dev/null 2>&1; then
    docker_cmd service rm "${STACK_NAME}_ssh-key-sender" "${STACK_NAME}_ssh-key-receiver" >/dev/null 2>&1 || true
    docker_cmd secret rm "$secret_name" >/dev/null
    log "Replaced stale Docker secret: ${secret_name}"
  fi
  ensure_docker_secret_from_value "$secret_name" "$(run_root cat "${AI_STAND_SECRETS_DIR}/${file_name}")"
}

# Delivers each ai-users member's personal SSH private key (an Authentik attribute) to the Coder node (docker/ssh-key-delivery).
# Issues the sender's Authentik credential and the shared token, creates the secrets and deploys compose.ssh-key-delivery.yaml
# ALONE into the existing stack. The receiver's node needs the image (images-ai02) and the key directory (host-ai02).
cmd_configure_ssh_key_delivery() {
  [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ] || die "configure-ssh-key-delivery requires SSH_KEY_DELIVERY_ENABLED=1"
  [ "$NODE_NAME" = "ai01" ] || die "configure-ssh-key-delivery must run on ai01, where Authentik is placed"
  docker_cmd image inspect "$SSH_KEY_DELIVERY_IMAGE" >/dev/null 2>&1 \
    || die "Missing image ${SSH_KEY_DELIVERY_IMAGE}; run apply.sh images on ai01 first"

  wait_service_ready "${STACK_NAME}_authentik-server"

  SSH_KEY_DELIVERY_AUTHENTIK_TOKEN_CHANGED=0
  ensure_ssh_key_delivery_authentik_token
  load_host_secret ssh-key-delivery-token 32 hex >/dev/null
  ensure_ssh_key_delivery_secret ai-stand-ssh-key-delivery-authentik-token ssh-key-delivery-authentik-api-token \
    "$SSH_KEY_DELIVERY_AUTHENTIK_TOKEN_CHANGED"
  ensure_ssh_key_delivery_secret ai-stand-ssh-key-delivery-token ssh-key-delivery-token 0
  ensure_ssh_key_delivery_service_accounts

  # The receiver accepts only the service names the sender is configured for.
  SSH_KEY_DELIVERY_SERVICE_NAMES="$(printf '%s' "$SSH_SERVICE_ACCOUNTS" | tr ',' '\n' | sed -n 's/=.*$//p' | paste -sd, -)"
  export STACK_NAME SSH_KEY_DELIVERY_IMAGE SSH_KEYS_ROOT SSH_SERVICE_KEYS_ROOT SSH_SERVICE_ACCOUNTS SSH_KEY_DELIVERY_SERVICE_NAMES
  docker_cmd stack config -c "$COMPOSE_SSH_KEY_DELIVERY_FILE" >/dev/null
  docker_cmd stack deploy --resolve-image never -c "$COMPOSE_SSH_KEY_DELIVERY_FILE" "$STACK_NAME"
  wait_service_running_bounded "${STACK_NAME}_ssh-key-sender" 1/1
  wait_service_running_bounded "${STACK_NAME}_ssh-key-receiver" 1/1
  log "SSH private-key delivery is running"
}

# Removes what the host-installed predecessor of this service left behind: a
# root systemd timer, an immutable source snapshot with its fingerprint
# machinery, root-only token and state directories, migration backups, and the
# OpenClaw-era Authentik reader it borrowed. Exact paths only. Refuses to run
# until the containerized service is up, applying, and has finished a pass.
cmd_cleanup_legacy_gitea_ssh_sync() {
  [ "$NODE_NAME" = "ai01" ] || die "cleanup-legacy-gitea-ssh-sync must run on ai01"
  [ "$(id -u)" -eq 0 ] || die "cleanup-legacy-gitea-ssh-sync must run as root"
  [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ] || die "cleanup-legacy-gitea-ssh-sync requires GITEA_SSH_SYNC_ENABLED=1"
  [ "${GITEA_SSH_SYNC_APPLY:-1}" = "1" ] || die "The replacement service only plans (GITEA_SSH_SYNC_APPLY=0); enable it first"

  local service="${STACK_NAME}_gitea-ssh-sync" replicas
  replicas="$(docker_cmd service ls --filter "name=${service}" --format '{{.Name}} {{.Replicas}}' | awk -v name="$service" '$1 == name { print $2 }')"
  [ "$replicas" = "1/1" ] || die "The replacement service ${service} is not running (replicas: ${replicas:-none})"
  # A here-string, not a pipe: grep -q exits on the first match and, with
  # pipefail, a still-writing producer would turn that into a false failure.
  local recent
  recent="$(docker_cmd service logs --tail 50 "$service" 2>&1)"
  grep -q '"event":"sync".*"mode":"apply"\|"mode":"apply".*"event":"sync"' <<<"$recent" \
    || die "The replacement service has not completed a synchronization pass in apply mode yet"

  local unit path
  for unit in ai-stand-gitea-ssh-key-sync.timer ai-stand-gitea-ssh-key-sync.service; do
    run_root systemctl disable --now "$unit" >/dev/null 2>&1 || true
    run_root rm -f "/etc/systemd/system/${unit}"
  done
  run_root systemctl daemon-reload
  run_root systemctl reset-failed >/dev/null 2>&1 || true
  log "Removed the legacy systemd timer and service"

  for path in \
    /usr/local/libexec/ai-stand/source \
    "${AI_STAND_DATA_ROOT}/gitea-ssh-sync" \
    "${STORAGE_ROOT}/gitea-ssh-key-sync-state" \
    "${AI_STAND_SECRETS_DIR}/gitea-ssh-key-sync"; do
    if run_root test -e "$path" || run_root test -L "$path"; then
      run_root rm -rf -- "$path"
      log "Removed ${path}"
    fi
  done
  if run_root test -e "${AI_STAND_SECRETS_DIR}/openclaw-tenants-authentik-token"; then
    run_root rm -f -- "${AI_STAND_SECRETS_DIR}/openclaw-tenants-authentik-token"
    log "Removed the borrowed OpenClaw identity-reader token"
  fi
  run_root find "$BACKUP_ROOT" -maxdepth 1 -type f \
    \( -name 'ai-stand-runtime-source-migration-*.tar.gz' -o -name 'gitea-ssh-sync-config-*.json' \) \
    -print -delete | sed 's/^/[ai-stand] Removed /'

  local server_container
  server_container="$(docker_cmd ps --filter "name=${STACK_NAME}_authentik-server." --format '{{.ID}}' | head -n 1 || true)"
  [ -n "$server_container" ] || die "Cannot find the Authentik server to retire the legacy identity reader"
  # Only the exact, script-owned account, role and token; anything carrying a
  # different ownership marker is left alone.
  docker_cmd exec -i "$server_container" ak shell <<'PYEOF' | sed -n 's/^AI_STAND_LEGACY_READER /[ai-stand] Authentik legacy reader: /p'
from authentik.core.models import Token, User
from authentik.rbac.models import Role

name = "ai-stand-openclaw-identity-reader"
marker = "ai-stand/openclaw-identity-reader/v1"
user = User.objects.filter(username=name, type="service_account").first()
if user is not None and (user.attributes or {}).get("ai_stand_openclaw_identity_reader") == marker:
    Token.objects.including_expired().filter(identifier=name, user=user).delete()
    user.delete()
    print("AI_STAND_LEGACY_READER account removed")
role = Role.objects.filter(name=name, managed=marker).first()
if role is not None:
    role.delete()
    print("AI_STAND_LEGACY_READER role removed")
print("AI_STAND_LEGACY_READER done")
PYEOF
  log "Legacy Gitea SSH-key synchronizer host state removed"
}

# Deploys the controller and the cert-receiver ALONE into the existing stack, so that the recurring jobs can be rolled out
# or updated (a new CONTROLLER_IMAGE_VERSION) without a generic `deploy`, which also resets service settings that live
# only in the running services. A generic deploy includes both services through compose.controller.yaml as well.
# Needs the controller image on ai01 (and on the receiver's node), the node labels from `host`, and runs on ai01.
cmd_deploy_controller() {
  [ "${CONTROLLER_ENABLED:-0}" = "1" ] || die "deploy-controller requires CONTROLLER_ENABLED=1"
  [ "$NODE_NAME" = "ai01" ] || die "deploy-controller must run on ai01, where the controller is placed"
  docker_cmd image inspect "$CONTROLLER_IMAGE" >/dev/null 2>&1 \
    || die "Missing image ${CONTROLLER_IMAGE}; run apply.sh images on ai01 first"
  local node label label_value
  for label in ai-stand.controller ai-stand.cert-receiver; do
    label_value=""
    for node in $(docker_cmd node ls --format '{{.ID}}'); do
      if [ "$(docker_cmd node inspect "$node" --format "{{ index .Spec.Labels \"${label}\" }}" 2>/dev/null)" = "true" ]; then
        label_value="true"
      fi
    done
    if [ "$label" = "ai-stand.controller" ] || [ "${CERTBOT_RECEIVER_ENABLED:-0}" = "1" ]; then
      [ "$label_value" = "true" ] || die "No Swarm node has the label ${label}=true; run apply.sh host on both nodes first"
    fi
  done

  ensure_controller_secrets
  export_controller_environment
  export STACK_NAME
  docker_cmd stack config -c "$COMPOSE_CONTROLLER_FILE" -c "$COMPOSE_CONTROLLER_STANDALONE_FILE" >/dev/null
  docker_cmd stack deploy --resolve-image never \
    -c "$COMPOSE_CONTROLLER_FILE" -c "$COMPOSE_CONTROLLER_STANDALONE_FILE" "$STACK_NAME"
  wait_service_running_bounded "${STACK_NAME}_controller" 1/1
  if [ "$CONTROLLER_RECEIVER_REPLICAS" != "0" ]; then
    wait_service_running_bounded "${STACK_NAME}_cert-receiver" "${CONTROLLER_RECEIVER_REPLICAS}/${CONTROLLER_RECEIVER_REPLICAS}"
  fi
  log "Controller is running (jobs: ${CONTROLLER_JOBS}; cert-receiver replicas: ${CONTROLLER_RECEIVER_REPLICAS})"
}

# wait_service_ready waits up to three hours; an optional service that fails to start should fail fast instead.
wait_service_running_bounded() {
  local service="$1" expected="$2" replicas
  local deadline=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    replicas="$(docker_cmd service ls --filter "name=${service}" --format '{{.Name}} {{.Replicas}}' | awk -v name="$service" '$1 == name { print $2 }')"
    if [ "$replicas" = "$expected" ]; then
      log "Service ready: ${service}"
      return 0
    fi
    sleep 5
  done
  docker_cmd service ps "$service" --no-trunc || true
  die "Service did not become ready within five minutes: ${service}"
}

# Removes what the host timers of the controller's jobs left behind on THIS node: the three timers and their services,
# the installed scripts under /usr/local/libexec/ai-stand, the certbot configuration and state, the SSH hand-over key
# and the forced-command line that accepted it. Exact paths only. Refuses to run until the controller (and, where the
# profile has one, the cert-receiver) is running and every enabled job has finished successfully at least once.
cmd_cleanup_legacy_host_timers() {
  [ "$(id -u)" -eq 0 ] || die "cleanup-legacy-host-timers must run as root"
  [ "${CONTROLLER_ENABLED:-0}" = "1" ] || die "cleanup-legacy-host-timers requires CONTROLLER_ENABLED=1"
  local service replicas logs job jobs
  service="${STACK_NAME}_controller"
  replicas="$(docker_cmd service ls --filter "name=${service}" --format '{{.Name}} {{.Replicas}}' | awk -v name="$service" '$1 == name { print $2 }')"
  [ "$replicas" = "1/1" ] || die "The controller ${service} is not running (replicas: ${replicas:-none})"
  jobs="model-access"
  [ "${READONLY_MCP_ENABLED:-0}" != "1" ] || jobs="reconcile ${jobs}"
  [ "${CERTBOT_ENABLED:-0}" != "1" ] || jobs="${jobs} certbot"
  logs="$(docker_cmd service logs --tail 2000 "$service" 2>&1)"
  for job in $jobs; do
    grep -q "\"event\":\"job\",\"exit\":0,\"job\":\"${job}\"" <<<"$logs" \
      || die "The controller has not completed the ${job} job successfully yet; wait for its first pass"
  done
  if [ "${CERTBOT_RECEIVER_ENABLED:-0}" = "1" ]; then
    replicas="$(docker_cmd service ls --filter "name=${STACK_NAME}_cert-receiver" --format '{{.Name}} {{.Replicas}}' \
      | awk -v name="${STACK_NAME}_cert-receiver" '$1 == name { print $2 }')"
    [ "$replicas" = "1/1" ] || die "The cert-receiver is not running (replicas: ${replicas:-none})"
  fi

  local unit path keys
  for unit in ai-stand-certbot-renew ai-stand-readonly-mcp-reconciler ai-stand-openwebui-model-access; do
    run_root systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
    run_root systemctl stop "${unit}.service" >/dev/null 2>&1 || true
    run_root rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service"
  done
  run_root systemctl daemon-reload
  run_root systemctl reset-failed >/dev/null 2>&1 || true
  log "Removed the legacy certbot, reconciler and model-access timers and services"

  for path in \
    /usr/local/libexec/ai-stand \
    /etc/ai-stand/certbot.conf \
    /etc/ai-stand/certbot-peer.known_hosts \
    /var/lib/ai-stand/certbot \
    "${AI_STAND_SECRETS_DIR}/certbot-distribute-key" \
    "${AI_STAND_SECRETS_DIR}/certbot-distribute-key.pub"; do
    if run_root test -e "$path" || run_root test -L "$path"; then
      run_root rm -rf -- "$path"
      log "Removed ${path}"
    fi
  done
  run_root rmdir /etc/ai-stand /var/lib/ai-stand >/dev/null 2>&1 || true

  # The hand-over key was accepted on the other node as a forced command; withdraw that line (a copy is kept).
  keys="/home/setup/.ssh/authorized_keys"
  if run_root test -f "$keys" && run_root grep -q 'certbot/receive-cert.sh' "$keys"; then
    run_root cp -p "$keys" "${keys}.before-controller"
    run_root sh -c 'grep -v "certbot/receive-cert.sh" "$1" > "$1.new" && chmod --reference="$1" "$1.new" && chown --reference="$1" "$1.new" && mv -f "$1.new" "$1"' sh "$keys"
    log "Removed the certificate hand-over line from ${keys} (copy: ${keys}.before-controller)"
  fi
  log "Legacy host timers of the controller's jobs removed on ${NODE_NAME}"
}

# Onboards exactly one human into Authentik: creates the account with a
# freshly generated temporary password (printed once, never persisted) if it
# doesn't exist yet, and idempotently ensures membership in the requested
# groups. Never resets the password of an already-existing user - this
# installation's design is self-service (the user changes their own password
# and, separately, their own readonly-mcp credentials through
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

verify_portainer_endpoint() {
  local jwt="$1" endpoints endpoint_ids endpoint_count
  endpoints="$(curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/endpoints)")" \
    || die "Cannot read Portainer endpoints during verification"
  endpoint_ids="$(jq --compact-output --arg name "$PORTAINER_ENDPOINT_NAME" \
    '[.[] | select(.Name == $name) | .Id]' <<<"$endpoints")"
  endpoint_count="$(jq 'length' <<<"$endpoint_ids")"
  [ "$endpoint_count" = "1" ] \
    || die "Expected exactly one existing Portainer environment: ${PORTAINER_ENDPOINT_NAME}"
  jq --raw-output '.[0]' <<<"$endpoint_ids"
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

verify_portainer_team() {
  local jwt="$1" teams team_ids team_count
  teams="$(curl \
    $(portainer_curl_base_args) \
    --fail \
    --header "Authorization: Bearer ${jwt}" \
    "$(portainer_api_url /api/teams)")" \
    || die "Cannot read Portainer teams during verification"
  team_ids="$(jq --compact-output --arg name "$PORTAINER_OAUTH_TEAM_NAME" \
    '[.[] | select(.Name == $name) | .Id]' <<<"$teams")"
  team_count="$(jq 'length' <<<"$team_ids")"
  [ "$team_count" = "1" ] \
    || die "Expected exactly one existing Portainer OAuth team: ${PORTAINER_OAUTH_TEAM_NAME}"
  jq --raw-output '.[0]' <<<"$team_ids"
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

# wait_service_ready only counts replicas. During a stop-first rolling update
# the replaced task's container can still be listed (and counted) for a few
# seconds, and a docker exec into it dies with 137 when it stops. Wait until the
# task Swarm wants running is Running and its local container is healthy.
wait_local_service_healthy() {
  local service="$1"
  local deadline=$(( $(date +%s) + 1800 ))
  local state container health

  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(docker_cmd service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' | head -n 1)"
    case "$state" in
      Running*)
        container="$(local_service_container "$service")"
        if [ -n "$container" ]; then
          health="$(docker_cmd inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
          if [ "$health" = "healthy" ] || [ "$health" = "none" ]; then
            return 0
          fi
        fi
        ;;
    esac
    sleep 5
  done

  docker_cmd service ps "$service" --no-trunc || true
  die "Service container did not become healthy: ${service}"
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

effective_llamacpp_model_identifier() {
  effective_service_env_value \
    "${STACK_NAME}_llamacpp01" \
    LLAMACPP_MODEL_ID \
    "$LLAMACPP_MODEL_IDENTIFIER"
}

effective_llamacpp_embedding_model_identifier() {
  effective_service_env_value \
    "${STACK_NAME}_llamacpp02" \
    LLAMACPP_MODEL_ID \
    "$LLAMACPP_EMBEDDING_MODEL_IDENTIFIER"
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
  wait_local_service_healthy "${STACK_NAME}_openwebui"

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

  openai_api_configs="$(service_env_value "${STACK_NAME}_openwebui" OPENAI_API_CONFIGS)"
  ollama_base_urls="$(service_env_value "${STACK_NAME}_openwebui" OLLAMA_BASE_URLS)"
  ollama_api_configs="$(service_env_value "${STACK_NAME}_openwebui" OLLAMA_API_CONFIGS)"
  rag_embedding_model="$(service_env_value "${STACK_NAME}_openwebui" RAG_EMBEDDING_MODEL)"
  enable_follow_up_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_FOLLOW_UP_GENERATION)"
  enable_retrieval_query_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_RETRIEVAL_QUERY_GENERATION)"
  enable_search_query_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_SEARCH_QUERY_GENERATION)"
  enable_tags_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_TAGS_GENERATION)"
  enable_title_generation="$(service_env_value "${STACK_NAME}_openwebui" ENABLE_TITLE_GENERATION)"

  [ -n "$openai_api_configs" ] || openai_api_configs="{}"
  [ -n "$ollama_base_urls" ] || ollama_base_urls=""
  [ -n "$ollama_api_configs" ] || ollama_api_configs="{}"
  [ -n "$rag_embedding_model" ] || rag_embedding_model="$LLAMACPP_EMBEDDING_MODEL_IDENTIFIER"
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
    docker_cmd exec -e OPENAI_API_CONFIGS -i "$openwebui_container" python - \
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
    con.commit()

print("changed=true" if changed else "changed=false")
PY
  )"

  log "Open WebUI persistent config sync: ${output}"
  if printf '%s\n' "$output" | grep -q 'changed=true'; then
    log "Restarting Open WebUI to pick up persistent config changes"
    docker_cmd service update --force --detach=true "${STACK_NAME}_openwebui" >/dev/null
    wait_service_ready "${STACK_NAME}_openwebui"
    wait_local_service_healthy "${STACK_NAME}_openwebui"
  fi

  sync_openwebui_tool_servers
  sync_openwebui_model_access
}

# Open WebUI runs with ENABLE_PERSISTENT_CONFIG=False, so it reads its tool
# servers only from TOOL_SERVER_CONNECTIONS; rows written to its database are
# ignored. Each connection needs an encrypted OAuth client blob
# (info.oauth_client_info). It is produced by the same registration code the
# admin UI calls, then encrypted with the key Open WebUI derives from its own
# secret. Fernet output is not deterministic, so a blob that still decrypts to
# the expected client is reused; otherwise every apply would restart Open WebUI.
# Authentik has no dynamic client registration: Agentgateway's `authentik`
# adapter answers it with the one pre-registered public PKCE client, which is
# safe for every consumer because no client secret is involved. Each person's
# own grant stays encrypted in that user's Open WebUI OAuth session. Access
# stays enforced at Agentgateway ('ai-users' in jwt.groups plus the per-user
# target rule), so the connections themselves are readable by every user.
sync_openwebui_tool_servers() {
  [ "${NODE_NAME:-}" = "ai01" ] || return 0

  local openwebui_container current output desired note
  wait_local_service_healthy "${STACK_NAME}_openwebui"
  openwebui_container="$(local_service_container "${STACK_NAME}_openwebui")"
  [ -n "$openwebui_container" ] || die "Open WebUI task is not running locally on ai01"
  current="$(service_env_value "${STACK_NAME}_openwebui" TOOL_SERVER_CONNECTIONS)"
  [ -n "$current" ] || current="[]"

  output="$(
    local -x CURRENT_TOOL_SERVER_CONNECTIONS="$current"
    local -x READONLY_MCP_ENABLED="$READONLY_MCP_ENABLED"
    local -x READONLY_MCP_BASE_URL="https://${AGENTGATEWAY_HOST}"
    local -x READONLY_MCP_PATH_PREFIX="$READONLY_MCP_PATH_PREFIX"
    docker_cmd exec -e CURRENT_TOOL_SERVER_CONNECTIONS -e READONLY_MCP_ENABLED -e READONLY_MCP_BASE_URL -e READONLY_MCP_PATH_PREFIX \
      -i "$openwebui_container" python - <<'PY'
import asyncio
import json
import os
import sys
import types

# docker exec sees the container definition, not start.sh's exported process
# environment: read the signing secret the same way start.sh does.
if not os.environ.get("WEBUI_SECRET_KEY"):
    with open("/run/secrets/ai-stand-openwebui-secret-key", encoding="utf-8") as handle:
        os.environ["WEBUI_SECRET_KEY"] = handle.read().rstrip("\n")
sys.path.insert(0, "/app/backend")

enabled = os.environ.get("READONLY_MCP_ENABLED", "0").strip() == "1"
base_url = os.environ.get("READONLY_MCP_BASE_URL", "").rstrip("/")
prefix = os.environ.get("READONLY_MCP_PATH_PREFIX", "/mcp/work").rstrip("/")
webui_url = os.environ["WEBUI_URL"].rstrip("/")
scope = "openid profile email groups"

try:
    current = json.loads(os.environ.get("CURRENT_TOOL_SERVER_CONNECTIONS") or "[]")
except json.JSONDecodeError:
    current = []
if not isinstance(current, list):
    current = []


def entry_id(entry):
    return (entry.get("info") or {}).get("id") if isinstance(entry, dict) else None


servers = (
    ("ai-stand-mcp-jira", "Jira (read-only)", "Personal Jira Data Center read-only tools", f"{prefix}/jira-readonly-mcp"),
    ("ai-stand-mcp-confluence", "Confluence (read-only)", "Personal Confluence Data Center read-only tools", f"{prefix}/confluence-readonly-mcp"),
    ("ai-stand-mcp-imap", "IMAP (read-only)", "Personal IMAP read-only tools", f"{prefix}/imap-readonly-mcp"),
)
managed = {identifier for identifier, *_ in servers}
retired = {"ai-stand-mcp-personal"}
unmanaged = [entry for entry in current if entry_id(entry) not in managed | retired]
existing = {entry_id(entry): entry for entry in current if entry_id(entry) in managed}

desired = []
if enabled:
    from open_webui.utils.oauth import (
        decrypt_data,
        encrypt_data,
        get_oauth_client_info_with_dynamic_client_registration,
    )

    request = types.SimpleNamespace(base_url=webui_url + "/")

    def reusable(entry, url, client_id):
        if not isinstance(entry, dict) or entry.get("url") != url:
            return None
        blob = (entry.get("info") or {}).get("oauth_client_info") or ""
        try:
            data = decrypt_data(blob)
        except Exception:
            return None
        redirect = [f"{webui_url}/oauth/clients/{client_id}/callback"]
        if data.get("client_id") and data.get("scope") == scope and data.get("redirect_uris") == redirect:
            return blob
        return None

    for identifier, name, description, path in servers:
        client_id = f"mcp:{identifier}"
        url = base_url + path
        previous = existing.get(identifier)
        blob = reusable(previous, url, client_id)
        if blob is None:
            try:
                info = asyncio.run(get_oauth_client_info_with_dynamic_client_registration(
                    request, client_id, url, oauth_scope=scope))
                blob = encrypt_data(info.model_dump(mode="json"))
            except Exception as error:
                # Not fatal: Agentgateway or Authentik may not be configured yet
                # on a fresh deployment. A later run fills the connection in.
                print(f"MCP-NOTE: OAuth client registration failed for {identifier}: {type(error).__name__}")
                if isinstance(previous, dict):
                    desired.append(previous)
                continue
        desired.append({
            "type": "mcp",
            "url": url,
            "path": "",
            "auth_type": "oauth_2.1",
            "key": "",
            "config": {
                "enable": True,
                "function_name_filter_list": "",
                "access_grants": [{"principal_type": "user", "principal_id": "*", "permission": "read"}],
            },
            "info": {
                "id": identifier,
                "name": name,
                "description": description,
                "oauth_scope": scope,
                "oauth_resource_parameter": "auto",
                "oauth_client_info": blob,
            },
        })

print(json.dumps(unmanaged + desired, ensure_ascii=False, separators=(",", ":")))
PY
  )"

  desired="$(printf '%s\n' "$output" | tail -n 1)"
  while IFS= read -r note; do
    [ -n "$note" ] && warn "${note#MCP-NOTE: }"
  done < <(printf '%s\n' "$output" | grep '^MCP-NOTE: ' || true)
  printf '%s' "$desired" | jq -e 'type == "array"' >/dev/null \
    || die "Could not build the Open WebUI tool server connections"

  update_service_env openwebui "TOOL_SERVER_CONNECTIONS=${desired}"
}

# The recurring reconciliation runs as the `model-access` job of the controller container; this only writes the
# identity configuration it reads.
install_openwebui_model_access() {
  [ "${NODE_NAME:-}" = "ai01" ] || return 0
  [ "${OPENWEBUI_MODEL_ACCESS_SKIP_INSTALL:-0}" != "1" ] || return 0
  run_root install -d -m 0700 -o root -g root "$AI_STAND_DATA_ROOT" "${AI_STAND_DATA_ROOT}/identity"
  run_root python3 "${OPENWEBUI_MODEL_ACCESS_SOURCE_DIR}/model_access_snapshot.py" \
    --install-config --authentik-address "https://${AUTHENTIK_HOST}"
}

sync_openwebui_model_access() {
  [ "${NODE_NAME:-}" = "ai01" ] || return 0
  wait_local_service_healthy "${STACK_NAME}_openwebui"
  install_openwebui_model_access
  ensure_readonly_mcp_authentik_service_token
  run_root python3 "${OPENWEBUI_MODEL_ACCESS_SOURCE_DIR}/model_access_snapshot.py" \
    --config "$OPENWEBUI_MODEL_ACCESS_CONFIG" --apply
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
  [ -n "$rag_embedding_model" ] || rag_embedding_model="$LLAMACPP_EMBEDDING_MODEL_IDENTIFIER"
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
    local -x TOOL_SERVER_CONNECTIONS
    TOOL_SERVER_CONNECTIONS="$(service_env_value "${STACK_NAME}_openwebui" TOOL_SERVER_CONNECTIONS)"
    docker_cmd exec -e OPENAI_API_CONFIGS -e READONLY_MCP_ENABLED -e READONLY_MCP_BASE_URL -e READONLY_MCP_PATH_PREFIX -e TOOL_SERVER_CONNECTIONS \
      -i "$openwebui_container" python - \
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
        "select key, value from config where key in (?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
# Open WebUI ignores database config (ENABLE_PERSISTENT_CONFIG=False): tool
# servers live in the TOOL_SERVER_CONNECTIONS environment of the service.
try:
    connections = json.loads(os.environ.get("TOOL_SERVER_CONNECTIONS") or "[]")
except json.JSONDecodeError:
    connections = None
if not isinstance(connections, list):
    errors.append("TOOL_SERVER_CONNECTIONS")
else:
    expected = {
        "ai-stand-mcp-jira": f"{readonly_mcp_path_prefix}/jira-readonly-mcp",
        "ai-stand-mcp-confluence": f"{readonly_mcp_path_prefix}/confluence-readonly-mcp",
        "ai-stand-mcp-imap": f"{readonly_mcp_path_prefix}/imap-readonly-mcp",
    }
    actual = {
        (entry.get("info") or {}).get("id"): entry
        for entry in connections if isinstance(entry, dict)
        and ((entry.get("info") or {}).get("id") in expected or (entry.get("info") or {}).get("id") == "ai-stand-mcp-personal")
    }
    if readonly_mcp_enabled:
        for identifier, path in expected.items():
            connection = actual.get(identifier)
            info = (connection or {}).get("info") or {}
            if (not isinstance(connection, dict) or connection.get("type") != "mcp"
                    or connection.get("auth_type") != "oauth_2.1"
                    or connection.get("url") != readonly_mcp_base_url + path
                    or not info.get("oauth_client_info")
                    or not (connection.get("config") or {}).get("access_grants")):
                errors.append("TOOL_SERVER_CONNECTIONS")
                break
        if "ai-stand-mcp-personal" in actual:
            errors.append("TOOL_SERVER_CONNECTIONS")
    elif actual:
        errors.append("TOOL_SERVER_CONNECTIONS")

if errors:
    raise SystemExit("Open WebUI persistent config drift: " + ", ".join(errors))
PY
  )

  log "Open WebUI persistent config matches service environment"
}

# The recurring jobs run in the controller container (docker/controller); its healthcheck turns unhealthy when the job
# loop stops beating. The host keeps only the path unit that reloads nginx after a certificate change.
check_controller() {
  [ "${CONTROLLER_ENABLED:-0}" = "1" ] || return 0
  local service container health
  if [ "${CERTBOT_ENABLED:-0}" = "1" ]; then
    run_root systemctl is-active --quiet ai-stand-nginx-reload.path \
      || die "ai-stand-nginx-reload.path is not active; a renewed certificate would not be reloaded (run apply.sh host)"
  fi
  service=""
  if [ "$NODE_NAME" = "ai01" ]; then
    service="${STACK_NAME}_controller"
  elif [ "$NODE_NAME" = "ai02" ] && [ "${CERTBOT_RECEIVER_ENABLED:-0}" = "1" ]; then
    service="${STACK_NAME}_cert-receiver"
  fi
  [ -n "$service" ] || return 0
  container="$(local_service_container "$service")"
  [ -n "$container" ] || die "${service} is not running locally on ${NODE_NAME}"
  health="$(docker_cmd inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")"
  [ "$health" = "healthy" ] || die "${service} is ${health}, not healthy"
  log "Controller ok: ${service} (${health})"
}

# The sender (Authentik node) and the receiver (Coder node) report healthy only while they work: the sender's heartbeat
# follows a successful pass, the receiver's healthcheck is its own HTTP endpoint. The key directory must be private.
check_ssh_key_delivery() {
  [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ] || return 0
  local service container health
  case "$NODE_NAME" in
    ai01) service="${STACK_NAME}_ssh-key-sender" ;;
    ai02) service="${STACK_NAME}_ssh-key-receiver" ;;
    *) return 0 ;;
  esac
  container="$(local_service_container "$service")"
  [ -n "$container" ] || die "${service} is not running locally on ${NODE_NAME}"
  health="$(docker_cmd inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")"
  [ "$health" = "healthy" ] || die "${service} is ${health}, not healthy"
  if [ "$NODE_NAME" = "ai02" ]; then
    [ "$(run_root stat -c '%a:%u:%g' "$SSH_KEYS_ROOT")" = "700:${APP_UID}:${APP_GID}" ] \
      || die "${SSH_KEYS_ROOT} must be mode 0700 owned by ${APP_UID}:${APP_GID}"
    [ "$(run_root stat -c '%a:%u:%g' "$SSH_SERVICE_KEYS_ROOT")" = "700:${APP_UID}:${APP_GID}" ] \
      || die "${SSH_SERVICE_KEYS_ROOT} must be mode 0700 owned by ${APP_UID}:${APP_GID}"
  fi
  log "SSH key delivery ok: ${service} (${health})"
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
    for kind in ("jira", "confluence", "imap"):
        if kind in services:
            if not isinstance(services[kind], dict):
                raise SystemExit("unsafe service entry")
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

  log "Read-only MCP reconciler configuration and ${#mcp_services[@]} active services verified"
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

check_openclaw_docker_sandbox_configuration() {
  local container_id
  container_id="$(local_service_container "${STACK_NAME}_openclaw-gateway")"
  [ -n "$container_id" ] || die "openclaw-gateway task is not running locally on ${NODE_NAME}"

  docker_cmd exec -u ai "$container_id" sh -ceu '
    test "${DOCKER_HOST:-}" = "tcp://docker-socket-proxy-openclaw:2375"
    command -v docker >/dev/null
    docker version --format "{{.Server.Version}}" >/dev/null
    docker image inspect openclaw-sandbox:bookworm-slim >/dev/null
  ' || die "OpenClaw Gateway cannot reach its restricted Docker socket proxy"

  docker_cmd exec -i -u ai "$container_id" node - <<'NODE' \
    || die "OpenClaw Gateway does not have the expected Docker sandbox configuration"
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.env.OPENCLAW_CONFIG_PATH, "utf8"));
const sandbox = config.agents?.defaults?.sandbox ?? {};
if (sandbox.backend !== "docker" || sandbox.mode !== "non-main" || sandbox.scope !== "agent" || sandbox.workspaceAccess !== "none" || sandbox.browser?.enabled !== false || sandbox.docker?.image !== "openclaw-sandbox:bookworm-slim" || sandbox.docker?.network !== "none" || sandbox.docker?.user !== "10000:20000") process.exit(1);
for (const agent of ["main", "codex", "claude"]) {
  if (config.agents?.entries?.[agent]?.sandbox?.workspaceRoot !== `/home/ai/.openclaw/sandboxes/${agent}`) process.exit(1);
  if (config.agents?.entries?.[agent]?.sandbox?.ssh !== undefined) process.exit(1);
}
NODE

  local spec
  spec="$(docker_cmd service inspect "${STACK_NAME}_openclaw-gateway" --format '{{json .Spec.TaskTemplate.ContainerSpec}}')"
  printf '%s' "$spec" | jq --exit-status --arg sandboxes "$OPENCLAW_DOCKER_SANDBOX_WORKSPACE_ROOT" '
    ((.Mounts // []) | any(.Source == $sandboxes and .Target == "/home/ai/.openclaw/sandboxes" and ((.ReadOnly // false) == false)))
    and ((.Mounts // []) | all(.Source != "/var/run/docker.sock"))
  ' >/dev/null || die "OpenClaw Gateway sandbox mount or raw Docker socket policy is invalid"
  log "OpenClaw Docker sandbox configuration is effective"
}

check_coder_docker_endpoint() {
  [ "$CODER_ENABLED" = "1" ] || return 0
  local container_id
  container_id="$(local_service_container "${STACK_NAME}_coder")"
  [ -n "$container_id" ] || die "Coder task is not running locally on ${NODE_NAME}"
  docker_cmd exec "$container_id" sh -ceu '
    test ! -e /var/run/docker.sock
    test "${DOCKER_HOST:-}" = "tcp://docker-socket-proxy-coder:2375"
    response="$(curl --fail --silent --show-error --max-time 5 --noproxy "*" \
      http://docker-socket-proxy-coder:2375/_ping)"
    test "$response" = "OK"
  ' || die "Coder cannot reach its restricted Docker socket proxy"
  log "Coder uses only its restricted Docker socket proxy"
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
    docker-socket-proxy-openclaw) service="${STACK_NAME}_docker-socket-proxy-openclaw" ;;
    docker-socket-proxy-coder) service="${STACK_NAME}_docker-socket-proxy-coder" ;;
    llamacpp01) service="${STACK_NAME}_llamacpp01" ;;
    llamacpp02) service="${STACK_NAME}_llamacpp02" ;;
    agentgateway) service="${STACK_NAME}_agentgateway" ;;
    agentgateway-postgres) service="${STACK_NAME}_agentgateway-postgres" ;;
    coder) service="${STACK_NAME}_coder" ;;
    coder-postgresql) service="${STACK_NAME}_coder-postgresql" ;;
    gitea) service="${STACK_NAME}_gitea" ;;
    gitea-postgresql) service="${STACK_NAME}_gitea-postgresql" ;;
    gitea-ssh-sync) service="${STACK_NAME}_gitea-ssh-sync" ;;
    controller) service="${STACK_NAME}_controller" ;;
    cert-receiver) service="${STACK_NAME}_cert-receiver" ;;
    ssh-key-sender) service="${STACK_NAME}_ssh-key-sender" ;;
    ssh-key-receiver) service="${STACK_NAME}_ssh-key-receiver" ;;
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
# curl.  llama.cpp tasks are already attached to that network and are built
# from the base image containing curl, so use the requested running task for
# read-only probes.
models_backend_curl() {
  local service="$1"
  local container
  shift
  container="$(
    docker_cmd ps \
      --filter "label=com.docker.swarm.service.name=${STACK_NAME}_${service}" \
      --filter status=running \
      --format '{{.ID}}' \
      | head -n 1
  )"
  [ -n "$container" ] || die "No running ${service} task is available for ai-models-backend probe"
  docker_cmd exec -i -u "${APP_UID}:${APP_GID}" "$container" curl "$@"
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
    "$GITEA_HOST") printf '%s\n' "/api/healthz" ;;
    "$AUTHENTIK_HOST") printf '%s\n' "/" ;;
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



validate_llamacpp_verification_timeout() {
  case "$LLAMACPP_CHAT_TIMEOUT_SECONDS" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#LLAMACPP_CHAT_TIMEOUT_SECONDS}" -le 5 ] \
    && [ "$LLAMACPP_CHAT_TIMEOUT_SECONDS" -gt 0 ] \
    && [ "$LLAMACPP_CHAT_TIMEOUT_SECONDS" -le 86400 ]
}

check_llamacpp_model_inventory() {
  local timeout_seconds="${1:-10800}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local poll_count=0 container service expected_model
  case "$NODE_NAME" in
    ai01) service=llamacpp01; expected_model="$(effective_llamacpp_model_identifier)" ;;
    ai02) service=llamacpp02; expected_model="$(effective_llamacpp_embedding_model_identifier)" ;;
    *) die "Native model verification is unsupported on node $NODE_NAME" ;;
  esac
  while [ "$(date +%s)" -lt "$deadline" ]; do
    container="$(local_service_container "${STACK_NAME}_${service}")"
    if [ -n "$container" ] \
      && docker_cmd exec -u "${APP_UID}:${APP_GID}" "$container" \
        /usr/local/bin/llamacpp-healthcheck.sh --ready --verify-loaded; then
      # Readiness checks build provenance, exact GGUF/projector SHA, native
      # props, successful inference and required GPU offload, not catalog alone.
      log "${service} verified native loaded model: $expected_model"
      return 0
    fi
    if [ "$poll_count" -eq 0 ] || [ $((poll_count % 10)) -eq 0 ]; then
      log "Waiting for ${service} native readiness and inference proof: $expected_model"
    fi
    poll_count=$((poll_count + 1))
    sleep 30
  done
  die "${service} did not pass native model readiness: $expected_model"
}

check_agentgateway_model_inventory() {
  local token models_file chat_model embedding_model
  token="$(run_root cat "${AI_STAND_SECRETS_DIR}/agentgateway-openwebui-token")"
  chat_model="$(effective_llamacpp_model_identifier)"
  embedding_model="$(effective_llamacpp_embedding_model_identifier)"
  models_file="$(mktemp)"

  if ! curl --fail --silent --show-error --max-time 30 \
    --header "Authorization: Bearer ${token}" \
    http://127.0.0.1:4000/v1/models > "$models_file"; then
    sed 's/^/[agentgateway-models] /' "$models_file" >&2 || true
    rm -f "$models_file"
    die "Agentgateway model inventory request failed"
  fi

  # Only the active chat model and the selected embedding model may be
  # public. Other downloaded embedding weights are node-local recovery
  # inventory and must never appear in the client-visible model list.
  jq --exit-status \
    --arg chat_model "$chat_model" \
    --arg embedding_model "$embedding_model" \
    '[.data[]?.id] as $ids
     | ($ids | index($chat_model))
     and ($ids | index($embedding_model))
     and ([ $ids[] | select(startswith("qwen3-embedding-")) ] == [$embedding_model])' \
    "$models_file" >/dev/null \
    || {
      sed 's/^/[agentgateway-models] /' "$models_file" >&2 || true
      rm -f "$models_file"
      die "Agentgateway exposes an unexpected llama.cpp model inventory"
    }

  rm -f "$models_file"
  log "Agentgateway exposes only the selected chat and embedding models"
}

check_agentgateway_embedding() {
  local token request_file response_file embedding_model embedding_dimensions
  token="$(run_root cat "${AI_STAND_SECRETS_DIR}/agentgateway-openwebui-token")"
  embedding_model="$(effective_llamacpp_embedding_model_identifier)"
  embedding_dimensions="$(service_env_value "${STACK_NAME}_openclaw-gateway" OPENCLAW_LANCEDB_EMBEDDING_DIMENSIONS)"
  case "$embedding_model" in
    qwen3-embedding-8b) embedding_dimensions=4096 ;;
    qwen3-embedding-4b) embedding_dimensions=2560 ;;
    qwen3-embedding-0.6b) embedding_dimensions=1024 ;;
  esac
  [[ "$embedding_dimensions" =~ ^[1-9][0-9]*$ ]] || die "Embedding dimension contract is unavailable"
  request_file="$(mktemp)"
  response_file="$(mktemp)"

  jq --null-input --arg model "$embedding_model" \
    '{model: $model, input: "ai-stand embedding route verification"}' \
    > "$request_file"
  if ! curl --fail --silent --show-error --max-time "$LLAMACPP_CHAT_TIMEOUT_SECONDS" \
    --header "Authorization: Bearer ${token}" \
    --header 'Content-Type: application/json' \
    --data @"$request_file" \
    http://127.0.0.1:4000/v1/embeddings > "$response_file"; then
    sed 's/^/[agentgateway-embeddings] /' "$response_file" >&2 || true
    rm -f "$request_file" "$response_file"
    die "Agentgateway embedding request failed for ${embedding_model}"
  fi
  jq --exit-status \
    --arg embedding_model "$embedding_model" \
    --argjson dimensions "$embedding_dimensions" \
    '.model == $embedding_model
     and (.data[0].embedding | type == "array" and length == $dimensions)' \
    "$response_file" >/dev/null \
    || {
      sed 's/^/[agentgateway-embeddings] /' "$response_file" >&2 || true
      rm -f "$request_file" "$response_file"
      die "Agentgateway returned an invalid embedding response for ${embedding_model}"
    }

  rm -f "$request_file" "$response_file"
  log "Agentgateway embedding route ok: ${embedding_model}"
}

check_llamacpp_chat_completion() {
  local request_file
  local response_file
  local chat_model
  chat_model="$(effective_llamacpp_model_identifier)"
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

  if ! models_backend_curl llamacpp01 \
    --fail \
    --silent \
    --show-error \
    --max-time "$LLAMACPP_CHAT_TIMEOUT_SECONDS" \
    --header "Content-Type: application/json" \
    --data @- \
    "http://llamacpp01:1234/v1/chat/completions" \
    < "$request_file" > "$response_file"; then
    sed 's/^/[llamacpp-chat] /' "$response_file" >&2 || true
    rm -f "$request_file" "$response_file"
    die "llama.cpp chat completion failed or timed out for ${chat_model}"
  fi

  jq --exit-status '
    ((.choices[0].message.content // "") | length) > 0
    or ((.choices[0].message.reasoning_content // "") | length) > 0
    or ((.choices[0].text // "") | length) > 0
  ' "$response_file" >/dev/null \
    || {
      rm -f "$request_file" "$response_file"
      die "llama.cpp chat completion returned no content for ${chat_model}"
    }

  rm -f "$request_file" "$response_file"
  log "llama.cpp chat completion ok: ${chat_model}"
}

check_llamacpp_stream_request() {
  local name="$1"
  local request_file="$2"
  local expect_tool_call="${3:-any}" # yes | no | any
  local response_file
  response_file="$(mktemp)"

  if ! models_backend_curl llamacpp01 \
    --fail \
    --silent \
    --show-error \
    --max-time "$LLAMACPP_CHAT_TIMEOUT_SECONDS" \
    --header "Content-Type: application/json" \
    --data @- \
    "http://llamacpp01:1234/v1/chat/completions" \
    < "$request_file" > "$response_file"; then
    sed 's/^/[llamacpp-chat] /' "$response_file" >&2 || true
    rm -f "$response_file"
    die "llama.cpp ${name} request failed or timed out"
  fi

  # Reassemble the SSE chunk stream into one JSON array so finish_reason and
  # whether any tool_calls delta actually carried a function name can be
  # asserted - a bare "did we get any 'data:' line" check would pass even for
  # a stream that silently degraded to plain text instead of a real tool
  # call: valid SSE alone does not prove that the native tool loop works.
  local chunks_json
  chunks_json="$(grep '^data:' "$response_file" | sed 's/^data: //' | grep -v '^\[DONE\]$' | jq -s '.' 2>/dev/null)"
  if [ -z "$chunks_json" ] || [ "$chunks_json" = "[]" ]; then
    sed 's/^/[llamacpp-chat] /' "$response_file" >&2 || true
    rm -f "$response_file"
    die "llama.cpp ${name} request did not return any SSE data chunks"
  fi

  local finish_reason has_tool_call
  finish_reason="$(printf '%s' "$chunks_json" | jq -r '[.[].choices[0].finish_reason] | map(select(. != null)) | last // empty')"
  has_tool_call="$(printf '%s' "$chunks_json" | jq -r 'any(.[]; ((.choices[0].delta.tool_calls // [])[]?.function.name // "") != "")')"

  if [ -z "$finish_reason" ]; then
    sed 's/^/[llamacpp-chat] /' "$response_file" >&2 || true
    rm -f "$response_file"
    die "llama.cpp ${name} request never reached a finish_reason"
  fi

  case "$expect_tool_call" in
    yes)
      if [ "$has_tool_call" != "true" ] || [ "$finish_reason" != "tool_calls" ]; then
        sed 's/^/[llamacpp-chat] /' "$response_file" >&2 || true
        rm -f "$response_file"
        die "llama.cpp ${name} expected a tool call but got finish_reason=${finish_reason} has_tool_call=${has_tool_call}"
      fi
      ;;
    no)
      if [ "$has_tool_call" = "true" ]; then
        sed 's/^/[llamacpp-chat] /' "$response_file" >&2 || true
        rm -f "$response_file"
        die "llama.cpp ${name} unexpectedly returned a tool call"
      fi
      ;;
    any) : ;;
    *) die "check_llamacpp_stream_request: unknown expect_tool_call value: ${expect_tool_call}" ;;
  esac

  rm -f "$response_file"
  log "llama.cpp ${name} stream ok (finish_reason=${finish_reason})"
}

check_llamacpp_tool_compat() {
  local chat_model
  local models_file
  local request_file
  chat_model="$(effective_llamacpp_model_identifier)"
  models_file="$(mktemp)"
  request_file="$(mktemp)"

  if ! models_backend_curl llamacpp01 \
    --fail \
    --silent \
    --show-error \
    --max-time 30 \
    "http://llamacpp01:1234/v1/models" \
    > "$models_file"; then
    sed 's/^/[llamacpp-models] /' "$models_file" >&2 || true
    rm -f "$models_file" "$request_file"
    die "llama.cpp model inventory failed"
  fi

  jq --exit-status \
    --arg chat_model "$chat_model" \
    '[.data[]?.id] | index($chat_model)' \
    "$models_file" >/dev/null \
    || {
      rm -f "$models_file" "$request_file"
      die "llama.cpp model inventory does not contain ${chat_model}"
    }
  rm -f "$models_file"
  log "llama.cpp model inventory ok: ${chat_model}"

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
  check_llamacpp_stream_request "plain-chat" "$request_file" "no"

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
  check_llamacpp_stream_request "first-tool-request" "$request_file" "yes"

  # Keep tools/tool_choice/parallel_tool_calls present through the completed
  # tool round-trip; the transport proxy must not rewrite this payload.
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
  check_llamacpp_stream_request "tool-continuation" "$request_file" "any"

  # The next user turn must still trigger a second tool, not silently
  # degrade to plain text after a previous tool result.
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
  check_llamacpp_stream_request "second-tool-request-after-continuation" "$request_file" "yes"



  rm -f "$request_file"
  log "llama.cpp tool compatibility ok: ${chat_model}"
}

cmd_verify() {
  validate_llamacpp_verification_timeout \
    || die "LLAMACPP_CHAT_TIMEOUT_SECONDS must be an integer from 1 to 86400 (verification only)"
  load_os_info
  READ_ONLY_VERIFY="1"
  ensure_ai_stand_secrets
  if [ "$NODE_NAME" = "ai01" ]; then
    local accelerator
    accelerator="$(detect_accelerator)"
    validate_accelerator_compatibility "$accelerator"
  fi

  for service in "${SERVICES[@]}"; do
    wait_service_ready "$service"
  done

  check_service_label_placement "${STACK_NAME}_llamacpp01" "ai-stand.llamacpp01"
  check_service_label_placement "${STACK_NAME}_llamacpp02" "ai-stand.llamacpp02"
  check_service_label_placement "${STACK_NAME}_openwebui" "ai-stand.openwebui"
  check_service_label_placement "${STACK_NAME}_openclaw-gateway" "ai-stand.openclaw"
  check_service_label_placement "${STACK_NAME}_docker-socket-proxy-openclaw" "ai-stand.openclaw"
  check_service_label_placement "${STACK_NAME}_authentik-postgresql" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_authentik-redis" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_authentik-server" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_authentik-worker" "ai-stand.authentik"
  check_service_label_placement "${STACK_NAME}_portainer" "ai-stand.portainer"
  check_service_label_placement "${STACK_NAME}_agentgateway" "ai-stand.agentgateway"
  if [ "$CODER_ENABLED" = "1" ]; then
    wait_service_ready "${STACK_NAME}_coder-postgresql"
    wait_service_ready "${STACK_NAME}_coder"
    wait_service_ready "${STACK_NAME}_docker-socket-proxy-coder"
    check_service_label_placement "${STACK_NAME}_coder-postgresql" "ai-stand.coder"
    check_service_label_placement "${STACK_NAME}_coder" "ai-stand.coder"
    check_service_label_placement "${STACK_NAME}_docker-socket-proxy-coder" "ai-stand.coder"
  fi
  if [ "${GITEA_ENABLED:-0}" = "1" ]; then
    wait_service_ready "${STACK_NAME}_gitea-postgresql"
    wait_service_ready "${STACK_NAME}_gitea"
    check_service_label_placement "${STACK_NAME}_gitea-postgresql" "ai-stand.gitea"
    check_service_label_placement "${STACK_NAME}_gitea" "ai-stand.gitea"
  fi
  if [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ]; then
    check_service_label_placement "${STACK_NAME}_gitea-ssh-sync" "ai-stand.gitea"
  fi
  if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then
    check_service_label_placement "${STACK_NAME}_ssh-key-sender" "ai-stand.authentik"
    check_service_label_placement "${STACK_NAME}_ssh-key-receiver" "ai-stand.coder"
  fi
  if [ "${CONTROLLER_ENABLED:-0}" = "1" ]; then
    check_service_label_placement "${STACK_NAME}_controller" "ai-stand.controller"
    if [ "${CERTBOT_RECEIVER_ENABLED:-0}" = "1" ]; then
      check_service_label_placement "${STACK_NAME}_cert-receiver" "ai-stand.cert-receiver"
    fi
  fi

  check_overlay_name "${STACK_NAME}_ai-models-backend" llamacpp01
  check_overlay_name "${STACK_NAME}_ai-models-backend" llamacpp02
  check_overlay_name "${STACK_NAME}_ai-core" authentik
  check_overlay_name "${STACK_NAME}_ai-core" authentik-postgresql
  check_overlay_name "${STACK_NAME}_ai-core" authentik-redis
  check_overlay_name "${STACK_NAME}_ai-core" openwebui
  check_overlay_name "${STACK_NAME}_ai-core" openclaw
  check_overlay_name "${STACK_NAME}_ai-core" openclaw-gateway
  check_overlay_name "${STACK_NAME}_ai-core" agentgateway
  check_overlay_name "${STACK_NAME}_ai-core" agentgateway-postgres
  check_overlay_name "${STACK_NAME}_ai-models-backend" agentgateway
  check_overlay_name "${STACK_NAME}_ai-mcp-backend" agentgateway
  if [ "$CODER_ENABLED" = "1" ]; then
    check_overlay_name "${STACK_NAME}_ai-coder-control" coder
    check_overlay_name "${STACK_NAME}_ai-coder-control" coder-postgresql
    check_overlay_name "${STACK_NAME}_ai-coder-docker-control" coder
    check_overlay_name "${STACK_NAME}_ai-coder-docker-control" docker-socket-proxy-coder
  fi
  if [ "${CONTROLLER_ENABLED:-0}" = "1" ]; then
    check_overlay_name "${STACK_NAME}_ai-core" controller
    if [ "${CERTBOT_RECEIVER_ENABLED:-0}" = "1" ]; then
      check_overlay_name "${STACK_NAME}_ai-core" cert-receiver
    fi
  fi
  if [ "${GITEA_SSH_SYNC_ENABLED:-0}" = "1" ]; then
    check_overlay_name "${STACK_NAME}_ai-core" gitea-ssh-sync
    check_overlay_name "${STACK_NAME}_ai-gitea-control" gitea-ssh-sync
  fi
  if [ "${SSH_KEY_DELIVERY_ENABLED:-0}" = "1" ]; then
    check_overlay_name "${STACK_NAME}_ai-core" ssh-key-sender
    check_overlay_name "${STACK_NAME}_ai-core" ssh-key-receiver
  fi
  if [ "${GITEA_ENABLED:-0}" = "1" ]; then
    check_overlay_name "${STACK_NAME}_ai-gitea-control" gitea
    check_overlay_name "${STACK_NAME}_ai-gitea-control" gitea-postgresql
  fi
  check_agentgateway_database
  check_readonly_mcp_configuration
  check_controller
  check_ssh_key_delivery
  check_overlay_name "${STACK_NAME}_ai-portainer-agent" portainer
  check_overlay_name "${STACK_NAME}_ai-portainer-agent" portainer-agent
  check_overlay_name "${STACK_NAME}_ai-portainer-agent" tasks.portainer-agent
  if [ "$NODE_NAME" = "ai02" ]; then
    check_overlay_name "${STACK_NAME}_ai-openclaw-docker-control" openclaw-gateway
    check_overlay_name "${STACK_NAME}_ai-openclaw-docker-control" docker-socket-proxy-openclaw
    check_openclaw_docker_sandbox_configuration
    check_coder_docker_endpoint
    check_coder_native_oidc
  fi
  check_openwebui_sso_only_environment
  check_openclaw_trusted_proxy_configuration
  check_openwebui_persistent_config
  check_agentgateway_llm_jwks
  check_authentik_configuration
  check_portainer_oidc_configuration
  # check_portainer_oidc_configuration above only confirms Authentik/
  # Portainer AGREE on how OIDC login should work. Resolve the managed
  # environment/team with read-only API calls; verification must not create
  # them as a side effect.
  #
  # Gated to ai01, UNLIKE check_portainer_oidc_configuration above (bug
  # found and fixed 2026-09-13): that check hits the unauthenticated
  # /api/settings/public, so it's fine to run from either node's local
  # nginx. portainer_login() below needs PORTAINER_ADMIN_PASSWORD, which is
  # a load_host_secret() - a LOCAL file under AI_STAND_SECRETS_DIR, not
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
    verify_portainer_endpoint_id="$(verify_portainer_endpoint "$verify_portainer_jwt")"
    verify_portainer_team_id="$(verify_portainer_team "$verify_portainer_jwt")"
    check_portainer_environment_configuration "$verify_portainer_jwt" "$verify_portainer_endpoint_id" "$verify_portainer_team_id"
    check_portainer_oauth_admin_users "$verify_portainer_jwt" "$verify_portainer_team_id"
    check_portainer_oauth_user_endpoint_access "$verify_portainer_jwt" "$verify_portainer_endpoint_id"
  fi
  # Each node owns exactly one isolated llama.cpp task. Verify the local
  # task on both hosts, then verify the public Agentgateway routes from the
  # node that hosts Agentgateway.
  local catalog_role catalog_home
  case "$NODE_NAME" in
    ai01) catalog_role=chat; catalog_home="$LLAMACPP01_DATA" ;;
    ai02) catalog_role=embedding; catalog_home="$LLAMACPP02_DATA" ;;
    *) die "Model catalog verification is unsupported for ${NODE_NAME}" ;;
  esac
  run_root python3 "${SCRIPT_DIR}/model-catalog/prepare.py" \
    --role "$catalog_role" --root "$catalog_home" --verify-only
  check_llamacpp_model_inventory 10800
  if [ "$NODE_NAME" = "ai01" ]; then
    check_llamacpp_chat_completion
    check_llamacpp_tool_compat
    check_agentgateway_model_inventory
    check_agentgateway_embedding
    # llm.policies.apiKey (mode: strict) gates this unconditionally - so
    # this runs here directly rather than through local_service_domains()'s
    # generic bare-success loop (see that function's own comment).
    check_https_protected_retry "$AGENTGATEWAY_HOST" "/v1/models" 600
  fi

  local domain
  if [ "$NODE_NAME" = "ai01" ]; then
    check_https_retry "$AUTHENTIK_HOST" "$(https_path_for_domain "$AUTHENTIK_HOST")" 600
    local icon_file
    for icon_file in openwebui.png portainer.svg agentgateway.svg openclaw.png coder.svg gitea.svg; do
      check_https_retry "$AUTHENTIK_HOST" "/app-icons/${icon_file}" 60
    done
  fi

  for domain in $(local_service_domains); do
    check_https_retry "$domain" "$(https_path_for_domain "$domain")" 600
  done
  while IFS= read -r port; do
    check_port_closed_to_non_loopback "$port"
  done < <(technical_ports_for_current_node)

  check_host_timezone
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
    deploy-models) cmd_deploy_models ;;
    configure-model-routing) cmd_configure_model_routing ;;
    deploy) cmd_deploy ;;
    templates) cmd_templates ;;
    reconcile-mcp) cmd_reconcile_mcp ;;
    configure-authentik) cmd_configure_authentik ;;
    configure-gitea) cmd_configure_gitea ;;
    configure-gitea-ssh-sync) cmd_configure_gitea_ssh_sync ;;
    cleanup-legacy-gitea-ssh-sync) cmd_cleanup_legacy_gitea_ssh_sync ;;
    deploy-controller) cmd_deploy_controller ;;
    configure-ssh-key-delivery) cmd_configure_ssh_key_delivery ;;
    cleanup-legacy-host-timers) cmd_cleanup_legacy_host_timers ;;
    onboard-readonly-mcp-user) cmd_onboard_readonly_mcp_user ;;
    configure-portainer) cmd_configure_portainer ;;
    verify) cmd_verify ;;
    credentials) cmd_credentials ;;
    all) cmd_all ;;
    *) usage; die "Unknown command: ${COMMAND}" ;;
  esac
}

main "$@"
