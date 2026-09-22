# OpenClaw GigaCode requester adapter

Internal-only adapter for the personal GigaCode subscription route. It accepts
requests only from the OpenClaw Gateway using a Docker Secret, resolves a
short-lived session-to-Authentik-subject mapping written by the pinned
OpenClaw plugin, asks the identity broker for a 60-second JWT, and streams the
request to Agentgateway.

It does not mount a GigaCode Device ID, the broker signing key, or the
complete OpenClaw state. Its sole bind mount is the read-only session mapping.
