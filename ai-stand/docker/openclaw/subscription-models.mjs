import { readFileSync } from "node:fs";

// These are request IDs, not aliases such as "sonnet" or "latest". Provider
// capability metadata is supplied by the version-pinned upstream catalogs;
// this selection policy neither fabricates account access nor adds API keys.
export const subscriptionCatalog = JSON.parse(
  readFileSync(new URL("./subscription-models.json", import.meta.url), "utf8"),
);
if (subscriptionCatalog.version !== 1 || subscriptionCatalog.openclawVersion !== "2026.10.2") {
  throw new Error("Unsupported managed subscription model catalog");
}

const record = (value) => value && typeof value === "object" && !Array.isArray(value) ? value : {};

export function optionalConfigResult(path, result) {
  if (result.error) throw result.error;
  let parsed;
  try { parsed = JSON.parse(result.stdout); }
  catch { throw new Error(`Cannot read existing OpenClaw configuration: ${path}`); }
  if (result.status === 0) return parsed;
  // 2026.10.2 emits a structured error for a valid authored field that has
  // never been set. A malformed config, invalid path, provider validation
  // failure or another field's error is NOT an optional absence.
  const unsetMessage = `Config path is valid but unset: ${path}. The runtime default applies until you set an authored value with openclaw config set ${path} <value>.`;
  if (result.status === 1 && !result.stderr?.trim() && parsed?.ok === false &&
      parsed.error?.type === "cli_error" && parsed.error.message === unsetMessage) return {};
  // Providers may contain secrets: do not include raw stdout, stderr, or a
  // vendor error body in the error emitted during reconciliation.
  throw new Error(`Cannot read existing OpenClaw configuration: ${path}`);
}

export function subscriptionModelRefs(agentId) {
  const agent = subscriptionCatalog.agents[agentId];
  if (!agent) throw new Error("Not a managed subscription agent");
  return agent.models.map(({ id }) => `${agent.provider}/${id}`);
}

export function subscriptionConfigUpdates({ providers = {}, agents = {}, selectableModels = {} } = {}) {
  const updates = [];
  const selectable = structuredClone(selectableModels);
  for (const [agentId, spec] of Object.entries(subscriptionCatalog.agents)) {
    const ownedIds = new Set([...spec.retiredModels, ...spec.models.map(({ id }) => id)]);
    const existingProvider = record(providers[spec.provider]);
    const foreignModels = Array.isArray(existingProvider.models)
      ? existingProvider.models.filter((item) => !ownedIds.has(item?.id))
      : [];
    updates.push([`models.providers.${spec.provider}`, {
      ...existingProvider,
      // Minimal config overlays deliberately retain upstream context, pricing,
      // thinking capabilities and native account availability discovery.
      models: [...foreignModels, ...spec.models.map((model) => ({ ...model }))],
    }]);

    const existingAgent = record(agents[agentId]);
    const metadata = structuredClone(record(existingAgent.models));
    const ownedRefs = new Set([...ownedIds].map((id) => `${spec.provider}/${id}`));
    // Retired aliases must not survive a restart, but unrelated metadata is
    // installation-owned and must not be removed by a subscription upgrade.
    for (const ref of ownedRefs) delete metadata[ref];
    for (const { id, name } of spec.models) {
      const ref = `${spec.provider}/${id}`;
      const previous = record(existingAgent.models?.[ref]);
      const selection = {
        ...previous,
        alias: name,
        agentRuntime: { ...record(previous.agentRuntime), id: spec.runtime },
      };
      metadata[ref] = selection;
      selectable[ref] = selection;
    }
    const policy = record(existingAgent.modelPolicy);
    const foreignAllow = Array.isArray(policy.allow) ? policy.allow.filter((ref) => !ownedRefs.has(ref)) : [];
    updates.push([`agents.entries.${agentId}.model`, `${spec.provider}/${spec.defaultModel}`]);
    if (spec.thinkingDefault) updates.push([`agents.entries.${agentId}.thinkingDefault`, spec.thinkingDefault]);
    updates.push([`agents.entries.${agentId}.models`, metadata]);
    updates.push([`agents.entries.${agentId}.modelPolicy`, {
      ...policy,
      allow: [...new Set([...foreignAllow, ...subscriptionModelRefs(agentId)])],
    }]);
  }
  return { updates, selectableModels: selectable, allowedModels: Object.keys(selectable) };
}

export function managedCodexAppServer(existing, executionPolicy, command) {
  if (typeof command !== "string" || !command.startsWith("/") || /[\0\r\n]/.test(command)) {
    throw new Error("OPENCLAW_CODEX_APP_SERVER_BIN must be an absolute executable path");
  }
  const current = record(existing);
  if (current.transport && current.transport !== "stdio") {
    // The native image executable cannot satisfy a persisted remote socket
    // contract. Deployment must handle that explicitly rather than redirect it.
    throw new Error("Managed Codex subscription binary requires stdio transport");
  }
  return { ...current, ...executionPolicy, transport: "stdio", command };
}
