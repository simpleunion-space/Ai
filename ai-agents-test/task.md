Provision the following 5 Linux system accounts so that they can be created (and
re-created idempotently) via Ansible, driven by inventory/variables rather than
hardcoded values, so the same role could be reused for a different list of
accounts on a different inventory:

| Account  | UID   | Primary GID | Shell     | SSH public key for login | sudo                                                                       |
|----------|-------|-------------|-----------|--------------------------|----------------------------------------------------------------------------|
| storage  | 20000 | 20000       | /bin/bash | no                       | no sudo access                                                             |
| service  | 10000 | 10000       | /bin/bash | no                       | no sudo access                                                             |
| setup    | 9999  | 9999        | /bin/bash | yes                      | passwordless sudo (no password prompt at all)                              |
| user     | 30000 | 30000       | /bin/bash | yes                      | sudo access, but the account's own password is required (not passwordless) |
| user-ai  | 30001 | 30001       | /bin/bash | yes                      | passwordless sudo (no password prompt at all)                              |

Details that apply to all 5 accounts:

- Each account gets its own primary group, named the same as the account, with
  the GID shown above (GID always equals UID here).
- Each account needs a home directory.
- Where an SSH public key is listed as "yes", the actual key material should
  come from inventory/variables (a placeholder value is fine - this is not a
  real key).
- Do not set, change or unlock any account's login password. Only configure
  whether sudo requires that password, not what the password actually is.
- Assume a Debian/Ubuntu-family target (apt, a `sudo` package, and a
  `/etc/sudoers.d/` drop-in directory are available).
- The whole thing should be safe to run more than once (idempotent).

Deliverable: an Ansible role (plus whatever minimal playbook, inventory example
and README are needed to actually run it with `ansible-playbook`) that achieves
this end state. Keep account-specific data (UID/GID/shell/sudo mode/SSH keys) as
inventory/variable data rather than literals inside the role's tasks.
