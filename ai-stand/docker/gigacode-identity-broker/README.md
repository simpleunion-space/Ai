# GigaCode identity broker

Internal-only .NET service issuing a maximum 60-second RS256 JWT for the
single `gigacode/codechat` subscription route. It accepts a subject only from
an authenticated, named trusted caller and publishes a public JWKS for
Agentgateway. It has no Device ID, GigaCode CLI, or upstream network access.

The signing key and caller map are Docker Secrets. Neither is logged or
persisted in the image or a volume.
