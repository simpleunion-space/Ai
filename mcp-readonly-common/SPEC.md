# Specification

This internal library centralizes security invariants shared by ai-stand's
read-only MCP adapters: HTTPS upstream validation, bounded requests, redacted
logging and dependency-free MCP JSON-RPC response construction. It never opens
network connections or holds credentials itself.
