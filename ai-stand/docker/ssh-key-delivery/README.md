# SSH private-key delivery to Coder workspaces

Every minute the sender reads the members of the Authentik groups `ai-users` and `ai-admins` (everyone who can sign in to Coder) and hands each member's personal SSH **private** key to the Coder node. The managed Coder templates bind-mount the owner's directory — and only that — read-only into the owner's workspaces, and set up `ssh` to use it. Git over SSH to Gitea then works without anyone copying a key into a workspace. (The matching **public** key reaches Gitea through the separate `gitea-ssh-sync` service.)

```
Authentik attribute ai_stand_git_ssh_private_key (+ ai_stand_git_ssh_passphrase)
        │  ssh-key-sender (Authentik node, read-only Authentik credential)
        ▼  PUT /v1/keys over the encrypted overlay, bearer token (Docker secret)
ssh-key-receiver (Coder node, no Authentik credential)
        ▼  <storage root>/ssh-key-delivery-data/users/<login>/{id_ed25519,id_ed25519.pub,passphrase}   (0700 dir, 0400 files)
Coder workspace of <login>:  /run/ai-stand/ssh (read-only bind mount) + ~/.ssh/ai-stand.conf
```

**What the user does.** In Authentik (`/if/user/` → Settings → User details → Update details) paste the private key (the whole `-----BEGIN OPENSSH PRIVATE KEY-----` block) into *Personal Gitea SSH private key* and, only for an encrypted key, the passphrase into *SSH key passphrase*. Only `ssh-ed25519` keys in the OpenSSH format are accepted. Within about a minute the key is on the Coder node; a workspace started (or restarted) afterwards uses it. Never paste the key into a chat.

**What the services do.**

- The sender validates each key completely (an unencrypted key including its check integers and matching public half; an encrypted one structurally) and never logs a key or passphrase — only one status word per member. The receiver validates everything again, so it does not trust the sender.
- A value that does not parse (a typo, a pasted public key) is reported as `invalid-kept` and leaves the delivered key alone. A blank attribute, a disabled account or a member removed from both groups withdraws the key; the member's directory stays while they are a member, because the template's bind mount needs it to exist.
- `…+public-key-differs` in a log line means the private key does not belong to the public key registered for Gitea; the private key is delivered anyway.
- The receiver runs as the workspace identity (`10000:20000`), so the files it writes are owned by the account that must read them and need no capability. Files are replaced in place, never the directory, so running workspaces see a rotated key without a restart.
- A Coder user name must be 1–32 letters, digits or hyphens, because it is the directory name the template builds from the owner's Coder name; other Authentik user names are reported as `unsupported-username`.

**In the workspace** (`docker/coder-templates/*/main.tf`): the startup script writes `~/.ssh/ai-stand.conf` (`IdentityFile /run/ai-stand/ssh/id_ed25519`), includes it from `~/.ssh/config`, and, when a passphrase is present, starts an `ssh-agent` and loads the key from the passphrase file with a time-limited `ssh-add`. The agent's `GIT_SSH_COMMAND` is `ssh`, so git uses this configuration instead of the key Coder generates for the account. The key stays on the read-only mount and is never copied into the persistent home.

**Credentials** are Docker secrets: a read-only Authentik service account (`view_user`, `view_group`; its own identity, so it can be revoked alone) for the sender, and one shared bearer token (hex, generated once into `_secrets/ssh-key-delivery-token`) for both services. Neither service has Docker access; both have a read-only root filesystem and no capabilities.

**Operating it** — `apply.sh images` on both nodes builds `ssh-key-delivery`; `apply.sh host` on the Coder node creates `<storage root>/ssh-key-delivery-data` with `users/` and `services/` (0700, workspace identity; the storage root is `STORAGE_ROOT` of the installation profile, `/mnt/storage` on m01); `apply.sh configure-ssh-key-delivery` on the Authentik node issues the credentials, creates the secrets and deploys `compose.ssh-key-delivery.yaml` alone. Republish the Coder templates (`apply.sh templates` on the Coder node) after changing `main.tf`.

```
docker service logs ai-stand_ssh-key-sender --tail 3        # {"event":"push","members":{"alice":"plain",...},"sent":false}
docker service logs ai-stand_ssh-key-receiver --tail 3      # {"event":"keys","delivered":2,"members":3,...}
python -m unittest docker/ssh-key-delivery/test_delivery.py # no network, no Docker (POSIX for the file-mode tests)
```

## Dedicated keys of services (OpenClaw)

The same pipeline can deliver the key of a **service** rather than a person. `SSH_SERVICE_ACCOUNTS` in `apply.sh` (`openclaw=ai-stand-openclaw-bot`) maps a service name to the Authentik account that holds its key; the sender gets it as `SERVICE_KEYS`, and `SERVICE_NAMES` on the receiver is the only set of names that receiver accepts. The account is a **service account** in no group (so it is never treated as a member) that cannot sign in.

**Nothing is done by hand.** `configure-ssh-key-delivery` creates the account when it is missing and, when the account has no private key, generates an Ed25519 pair inside Authentik (OpenSSH format, no passphrase) and stores both halves in the same two attributes as a person's key (`ai_stand_git_ssh_private_key`, `ai_stand_git_ssh_public_key`); the private half never reaches the shell, a log or a file. A key that is already there, generated earlier or put there by the owner, is never replaced; to rotate, blank both attributes in Authentik (Directory → Users → the account → Attributes) and rerun the stage. `configure-gitea-ssh-sync` creates the Gitea account of the same name (a local account without a usable password, not an administrator) and `gitea-ssh-sync` registers the public half in it, as for people (`SERVICE_ACCOUNTS`; only a LOCAL Gitea account and an Authentik account of type `service_account` qualify, so a person is never mistaken for a service). The owner only decides which repositories that Gitea account may use (add it as a collaborator).

A service key **must not be encrypted** (nothing could supply the passphrase); a key that does not parse is reported as `invalid-kept` and leaves the delivered one alone, a blank attribute or an inactive account withdraws it. Within about a minute of a change the receiver writes `<storage root>/ssh-key-delivery-data/services/openclaw/id_ed25519` (directory 0700, files 0400, the workspace identity `10000:20000`), and the OpenClaw Gateway sees it read-only at `/run/ai-stand/ssh` (`compose.yaml`; the image's `/etc/ssh/ssh_config.d/50-ai-stand.conf` points `ssh` at it and records a host key on first contact in the Gateway's persistent home). A running Gateway picks up a rotated key without a restart, because files are replaced in place.

Treat this key as shared by everyone who can make the Gateway run a command, and give its Gitea account the narrowest rights accordingly. OpenClaw's sandboxes run without a network, so the key serves work the Gateway process itself runs, not sandboxed tools.
