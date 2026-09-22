# Generic ai-stand Coder workspace template - Docker-based, provisioned only
# against Coder's own dedicated rootless daemon (see CODER_ROOTLESS_DOCKER_SOCKET
# / ensure_coder_rootless_docker_service() in apply.sh). apply.sh only
# prepares the prerequisites (workspace image, Terraform provider mirror,
# agentgateway token - see ensure_coder_workspace_image()/
# ensure_coder_terraform_provider_mirror()/reconcile_coder_profile_urls()):
# `coder templates push` itself is a one-time manual step (see README),
# since it needs an interactive, browser-authenticated `coder login` that
# apply.sh has no non-interactive equivalent for. The one installation-
# specific, non-secret value (agentgateway_url) is supplied with --var at
# that manual push - this file itself stays generic and installation-
# agnostic, same principle as every other generic/ vs installations/ split
# in this repo.
#
# Network and isolation are inherited from ai-stand's own design, not
# reconfigured here: the workspace container joins only the
# ai-coder-workspaces bridge that ensure_coder_rootless_docker_service()
# already creates on that same rootless daemon - it has no route to the
# Swarm's ai-core/ai-models-backend overlays, no host Docker socket, and no
# AI/MCP credential beyond the one scoped agentgateway machine token below
# (explicitly requested access, unlike every other ai-stand component on
# this daemon - see AGENTGATEWAY_CODER_TOKEN in apply.sh).

terraform {
  required_providers {
    # Pinned to exactly what ensure_coder_terraform_provider_mirror() in
    # apply.sh downloads into the local filesystem mirror (see that
    # function's own comment for why: registry.terraform.io is geo-blocked
    # from this network - "Content not available in your region" - so
    # Coder's Terraform runs against a local mirror with only these two
    # exact provider builds available, not a version range).
    coder = {
      source  = "coder/coder"
      version = "2.19.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.6.0"
    }
  }
}

variable "agentgateway_url" {
  type        = string
  description = "This installation's public agentgateway base URL (e.g. https://agentgateway.example.org)."
}

# Supplied by Terraform's own TF_VAR_agentgateway_token convention, not a
# --var at template-push time: Coder's built-in provisioner execs `terraform`
# as a subprocess of the coder server container, which reconcile_coder_
# profile_urls() in apply.sh keeps populated with the current
# AGENTGATEWAY_CODER_TOKEN via `docker service update --env-add` on every
# deploy. Read fresh on every workspace build/start rather than baked in at
# template push - survives token rotation without a template republish.
variable "agentgateway_token" {
  type      = string
  sensitive = true
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  env = {
    # OpenAI-compatible surface most coding-assistant CLIs/extensions
    # (Continue, opencode and similar) already know how to read.
    OPENAI_API_BASE = "${var.agentgateway_url}/v1"
    OPENAI_API_KEY  = var.agentgateway_token
    DOCKER_HOST     = "unix:///run/coder-rootless/docker.sock"
  }

  startup_script = <<-EOT
    #!/bin/sh
    set -eu
    code-server --auth none --bind-addr 0.0.0.0:13337 >/tmp/code-server.log 2>&1 &
  EOT
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:13337"
  icon         = "/icon/code.svg"
  share        = "owner"
  subdomain    = false

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 15
  }
}

resource "docker_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle {
    ignore_changes = all
  }
}

resource "docker_container" "workspace" {
  count      = data.coder_workspace.me.start_count
  image      = "ai-stand-coder-workspace:2026.09.23-1"
  name       = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
  hostname   = data.coder_workspace.me.name
  entrypoint = ["sh", "-c", coder_agent.main.init_script]
  user       = "coder"

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
  ]

  volumes {
    container_path = "/home/coder"
    volume_name     = docker_volume.home.name
    read_only       = false
  }

  # Sibling-container access to the same dedicated rootless daemon that
  # created this workspace - same pattern openclaw-gateway already uses
  # against openclaw-sandbox-dind, never the host's real Docker socket.
  volumes {
    host_path      = "/mnt/storage/coder-data/provisioner/docker.sock"
    container_path = "/run/coder-rootless/docker.sock"
    read_only       = false
  }

  networks_advanced {
    name = "ai-coder-workspaces"
  }
}
