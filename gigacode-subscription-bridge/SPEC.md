# Specification

The bridge exposes health, model catalog, OpenAI Chat Completions and Responses
endpoints on the internal ai-network. It authenticates to gigacode.ru with a
short-lived in-memory token derived from the mounted device-id secret. It does
not publish a port, persist subscription state, or log prompts, responses,
headers, token material, or device identifiers.
