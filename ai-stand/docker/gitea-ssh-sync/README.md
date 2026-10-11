# Gitea SSH key sync

A small Swarm service on the Gitea node. Every minute it reads the members of the Authentik group `ai-users` and registers each member's personal SSH **public** key in their Gitea account, so `git push` over SSH works without anyone adding keys by hand.

**What the user does.** In Authentik (`/if/user/` → Settings → User details → Update details) paste the matching public key, for example the contents of `id_ed25519.pub`, into *Personal Gitea SSH public key*. Only `ssh-ed25519` keys on a single line are accepted. The *private key* and *passphrase* fields next to it are not read by this service; `docker/ssh-key-delivery` delivers them to the member's Coder workspaces.

**What the service does.**

- Finds the Gitea account through the OIDC link: Gitea stores the Authentik subject (the user's UUID) as `login_name`, and the account is used only if its login also equals the Authentik username. Local Gitea accounts are never touched. A member who has not signed in to Gitea yet is reported (`waitingForFirstGiteaSignIn`) and picked up after the first sign-in.
- Creates and deletes only keys titled `ai-stand personal SSH <login>` (optionally followed by ` [SHA256:...]`). Keys a user added by hand are never modified, and a key that a user registered by hand is never adopted.
- Rotation registers the new key, verifies it, and only then deletes the old managed one.
- A blank attribute, a disabled account or removal from `ai-users` withdraws the managed key. A value that is not a valid key (a typo, a pasted private key) is reported as `keep-invalid-value` and leaves the registered key alone.
- One failing account never blocks the others; the log line of each pass lists every account with its status.

**Service accounts.** With `SERVICE_ACCOUNTS` (set by `apply.sh` from `SSH_SERVICE_ACCOUNTS`) the same rules also keep the key of a bot, such as the OpenClaw Gateway's, registered: an Authentik **service account** (type `service_account`) and a **local** Gitea account carry the same name, and the key is the Authentik account's `ai_stand_git_ssh_public_key`. A Gitea account linked to a person is never taken for a service account, and neither is an Authentik person of that name. Until the Gitea account exists the entry reads `waiting-for-gitea-account` (`apply.sh configure-gitea-ssh-sync` creates it); `docker/ssh-key-delivery` generates the key and delivers the private half.

**Credentials** are Docker secrets: a read-only Authentik service account (`view_user`, `view_group`) and a token of a dedicated local Gitea administrator that has no password. Gitea has no narrower token that can manage other users' keys; the service has no Docker access, a read-only root filesystem, no capabilities and runs as the unprivileged service identity.

**Operating it** — see `apply.sh configure-gitea-ssh-sync` (issues the credentials, creates the secrets, deploys `compose.gitea-ssh-sync.yaml`). `GITEA_SSH_SYNC_APPLY=0` makes the service only log what it would change.

```
docker service logs ai-stand_gitea-ssh-sync --tail 5
python -m unittest docker/gitea-ssh-sync/test_sync.py      # no network, no Docker
```
