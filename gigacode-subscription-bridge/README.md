# gigacode-subscription-bridge

ASP.NET Core/.NET 10 adapter from the GigaCode subscription protocol to an
internal OpenAI-compatible API. It is built locally by `ai-stand`; each
running service is scoped to one Vault Device ID and the bridge
does not contain the GigaCode CLI, its OAuth cache, telemetry, or any literal
credential. Runtime credentials are a per-subscription Docker Secret with the
approved Device ID and a separate internal bearer issued by the reconciler.
