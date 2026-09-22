# OpenClaw personal GigaCode requester

This local OpenClaw plugin writes only ephemeral `session → Authentik sub`
bindings. It neither receives a GigaCode Device ID nor contacts Agentgateway
or GigaCode directly. The `ai02` adapter is the sole consumer of its state
file.

For browser turns, the version-pinned OpenClaw image patch propagates the
trusted-proxy Authentik UID into the normal sender field. Telegram senders
are resolved solely from the root-managed mapping mounted as a Docker Secret.
