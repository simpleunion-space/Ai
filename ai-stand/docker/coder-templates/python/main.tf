terraform {
  required_providers {
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

# Set by the installation when the templates are published (publisher.py --variable). The host directory that holds one SSH
# key directory per Coder user (docker/ssh-key-delivery); empty mounts nothing.
variable "ssh_keys_root" {
  type    = string
  default = ""
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  # Git over SSH uses the owner's own key from Authentik (docker/ssh-key-delivery, see the startup script) through
  # the normal ssh configuration, not the key Coder generates for the account.
  env = {
    GIT_SSH_COMMAND = "ssh"
  }

  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    test "$(id -u)" -ne 0
    install -d -m 0700 /home/coder/project
    # Loopback only: auth is off, and the workspaces share one Docker bridge, so
    # a wildcard bind would hand this IDE to every other workspace. The Coder
    # agent reaches it on localhost inside this container.
    code-server --auth none --bind-addr 127.0.0.1:13337 /home/coder/project >/tmp/code-server.log 2>&1 &

    # The owner's SSH key from Authentik. /run/ai-stand/ssh is a read-only mount that holds only this owner's files; the
    # key is used in place and never copied into the persistent home. A failure here must not stop the IDE.
    keys=/run/ai-stand/ssh
    if [ -r "$keys/id_ed25519" ]; then
      (
        install -d -m 0700 /home/coder/.ssh
        conf=/home/coder/.ssh/ai-stand.conf
        {
          echo "# Managed by the workspace template and rewritten at every start."
          echo "IdentityFile $keys/id_ed25519"
          if [ -r "$keys/passphrase" ]; then echo "IdentityAgent /tmp/ai-stand-ssh-agent.sock"; fi
        } > "$conf"
        chmod 0600 "$conf"
        if ! grep -qsx 'Include ~/.ssh/ai-stand.conf' /home/coder/.ssh/config; then
          { echo 'Include ~/.ssh/ai-stand.conf'; cat /home/coder/.ssh/config 2>/dev/null || true; } > /home/coder/.ssh/config.new
          chmod 0600 /home/coder/.ssh/config.new
          mv -f /home/coder/.ssh/config.new /home/coder/.ssh/config
        fi
        if [ -r "$keys/passphrase" ]; then
          rm -f /tmp/ai-stand-ssh-agent.sock
          ssh-agent -a /tmp/ai-stand-ssh-agent.sock >/dev/null
          # ssh-add runs the askpass program, and /tmp is a noexec tmpfs, so the helper lives in the home volume. It holds
          # no secret (it only prints the passphrase file) and is removed again. ssh-add asks again after a wrong
          # passphrase until the answer is empty, so it needs a time limit.
          askpass=/home/coder/.ssh/ai-stand-askpass
          { echo '#!/bin/sh'; echo "cat $keys/passphrase"; } > "$askpass"
          chmod 0700 "$askpass"
          SSH_AUTH_SOCK=/tmp/ai-stand-ssh-agent.sock SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
            timeout 20 ssh-add "$keys/id_ed25519" </dev/null >/dev/null 2>&1 \
            || echo "ssh-add could not load the key (wrong passphrase?)" >&2
          rm -f "$askpass"
        fi
      ) || echo "SSH key setup failed; git over SSH will not use the Authentik key" >&2
    fi
  EOT
}

resource "coder_app" "code_server" {
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
  name = "coder-${data.coder_workspace.me.id}-python-home"
  lifecycle {
    ignore_changes = all
  }
}

resource "docker_container" "workspace" {
  count      = data.coder_workspace.me.start_count
  image      = "ai-stand-coder-workspace-python:2026.10.21-1"
  name       = "coder-python-${data.coder_workspace.me.id}"
  hostname   = data.coder_workspace.me.name
  # Pinned native bootstrap honors BINARY_DIR. Keep noexec private /tmp; its
  # executable belongs in this owner's persistent home, never a shared path.
  entrypoint = ["/usr/bin/tini", "--", "bash", "-lc", "set -e; install -d -m 0700 /home/coder/.cache/coder-agent; export BINARY_DIR=/home/coder/.cache/coder-agent; ${coder_agent.main.init_script}"]
  user       = "coder"
  working_dir = "/home/coder"
  init       = true
  read_only  = true
  privileged = false
  # Native stop/destroy must never ask Docker to remove persistent volumes.
  remove_volumes = false
  capabilities {
    drop = ["ALL"]
  }
  security_opts = ["no-new-privileges:true"]
  # ai02 (32 GB RAM) also runs the embeddings model and OpenClaw, so a
  # workspace gets a fixed share and no swap; raise per need.
  memory      = 4096
  memory_swap = 4096
  cpus        = "2"
  tmpfs = {
    "/tmp" = "rw,nosuid,nodev,size=536870912,mode=1777"
  }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "HOME=/home/coder",
    "XDG_CACHE_HOME=/home/coder/.cache",
    "PIP_CACHE_DIR=/home/coder/.cache/pip",
    "PIP_REQUIRE_VIRTUALENV=true",
  ]

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
    read_only      = false
  }

  # Only this owner's SSH key from Authentik (docker/ssh-key-delivery), read-only, and only when the installation told the
  # template where the keys live. A bind mount, unlike a host_path volume, never creates a missing source as a root-owned
  # directory; the receiver creates the directory of every ai-users and ai-admins member, which is everyone who can sign
  # in to Coder.
  dynamic "mounts" {
    for_each = var.ssh_keys_root == "" ? [] : [var.ssh_keys_root]
    content {
      target    = "/run/ai-stand/ssh"
      source    = "${mounts.value}/${data.coder_workspace_owner.me.name}"
      type      = "bind"
      read_only = true
    }
  }
}
