import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { subscriptionCatalog } from "./subscription-models.mjs";

const MAX_TARGETS = 100;
const PAGE_SIZE = 100;
const MAX_SESSIONS = 10000;
const PRESERVED_FIELDS = [
  "nativeSessionId", "cliSessionId", "cliSessionIds", "authProfileOverride", "authProfileOverrideSource",
  "thinkingLevel", "reasoningLevel", "agentRuntime", "permissionMode", "sandboxMode", "nativeRuntimeConsent",
  "workspaceDir", "projectId", "parentSessionId", "parentSessionKey",
];

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  return value;
}
function preservedFingerprint(row) {
  const fields = Object.fromEntries(PRESERVED_FIELDS.filter((key) => Object.hasOwn(row, key)).map((key) => [key, row[key]]));
  return createHash("sha256").update(JSON.stringify(stable(fields))).digest("hex");
}
function agentFor(row) {
  return row.agentId ?? /^agent:([^:]+):/.exec(row.key ?? "")?.[1];
}
function modelRef(row) {
  if (typeof row.model !== "string" || !row.model) return null;
  return row.model.includes("/") ? row.model : typeof row.modelProvider === "string" ? `${row.modelProvider}/${row.model}` : null;
}
function shouldReset(row, spec) {
  const ref = modelRef(row);
  const owned = new Set([...spec.retiredModels, ...spec.models.map(({ id }) => id)]
    .flatMap((id) => [`${spec.provider}/${id}`, `${spec.runtime}/${id}`]));
  if (!owned.has(ref)) return false;
  const expected = `${spec.provider}/${spec.defaultModel}`;
  // A projected default already on the new model is an idempotent no-op.
  // Legacy cached selections are reset even when provenance was not exported.
  return !(ref === expected && (row.modelOverrideSource === null || row.modelOverrideSource === "inherited"));
}
function identity(row) {
  const agentId = agentFor(row);
  if (!row.key || typeof row.sessionId !== "string" || !row.sessionId || !subscriptionCatalog.agents[agentId]) {
    throw new Error("Subscription session identity is incomplete");
  }
  return {
    key: row.key, agentId, expectedSessionId: row.sessionId,
    ...(typeof row.lifecycleRevision === "string" && row.lifecycleRevision
      ? { expectedLifecycleRevision: row.lifecycleRevision } : {}),
  };
}
function unchanged(row, observed) {
  return row && row.key === observed.key && row.sessionId === observed.expectedSessionId &&
    agentFor(row) === observed.agentId &&
    (observed.expectedLifecycleRevision === undefined || row.lifecycleRevision === observed.expectedLifecycleRevision) &&
    modelRef(row) === observed.previousModel && row.modelOverrideSource === observed.previousSource &&
    preservedFingerprint(row) === observed.preservedFingerprint;
}

export async function inventorySubscriptions(rpc) {
  const candidates = [];
  const counts = { visible: 0, selected: 0, unchanged: 0, unrelated: 0, busy: 0 };
  const seen = new Set();
  for (const agentId of Object.keys(subscriptionCatalog.agents)) {
    for (let offset = 0; offset < MAX_SESSIONS; offset += PAGE_SIZE) {
      const result = await rpc("sessions.list", {
        agentId, limit: PAGE_SIZE, offset, archived: "all", includeGlobal: false, includeUnknown: false,
        configuredAgentsOnly: true, excludeSubagents: true, excludeCron: true, excludeSystem: true,
        includeDerivedTitles: false, includeLastMessage: false,
      });
      if (!Array.isArray(result?.sessions)) throw new Error("Unexpected sessions.list response");
      for (const listed of result.sessions) {
        if (agentFor(listed) !== agentId || typeof listed.key !== "string") {
          throw new Error("sessions.list returned an unexpected subscription scope");
        }
        const unique = `${agentId}\0${listed.key}`;
        if (seen.has(unique)) throw new Error("Session pagination changed during inventory; retry");
        seen.add(unique);
        counts.visible++;
        const described = await rpc("sessions.describe", { key: listed.key, agentId, includeDerivedTitles: false, includeLastMessage: false });
        const row = described?.session;
        if (!row || row.key !== listed.key || agentFor(row) !== agentId || row.sessionId !== listed.sessionId) {
          throw new Error("Subscription session changed or access was revoked during inventory");
        }
        const spec = subscriptionCatalog.agents[agentId];
        if (!shouldReset(row, spec)) {
          if (modelRef(row) === `${spec.provider}/${spec.defaultModel}`) counts.unchanged++;
          else counts.unrelated++;
          continue;
        }
        if (row.status === "running" || row.status === "queued" || row.hasActiveSubagentRun === true) counts.busy++;
        const target = identity(row);
        candidates.push({
          ...target, previousModel: modelRef(row), previousSource: row.modelOverrideSource,
          preservedFingerprint: preservedFingerprint(row),
        });
        counts.selected++;
      }
      if (result.sessions.length < PAGE_SIZE) break;
      if (offset + PAGE_SIZE === MAX_SESSIONS) throw new Error("Subscription session inventory limit exceeded");
    }
  }
  return { version: 1, openclawVersion: subscriptionCatalog.openclawVersion, counts, candidates };
}

export async function migrateSubscriptionSelections(rpc, { apply = false, expectedCounts, onInventory } = {}) {
  const inventory = await inventorySubscriptions(rpc);
  if (expectedCounts) {
    for (const [agentId, count] of Object.entries(expectedCounts)) {
      if (!subscriptionCatalog.agents[agentId] || !Number.isSafeInteger(count) || count < 0 ||
          inventory.candidates.filter((row) => row.agentId === agentId).length !== count) {
        throw new Error("Subscription selection count differs from the approved inventory");
      }
    }
  }
  // A protected inventory must be durable before the first authorized write;
  // failure to create it is not reported only after mutating live sessions.
  if (onInventory) await onInventory({ ...inventory, applied: 0 });
  if (!apply) return { ...inventory, applied: 0 };
  if (inventory.counts.busy) throw new Error("Stop running/queued subscription turns before selection migration");
  let applied = 0;
  for (let offset = 0; offset < inventory.candidates.length; offset += MAX_TARGETS) {
    const observed = inventory.candidates.slice(offset, offset + MAX_TARGETS);
    // Re-read immediately before every batch. CLI calls retain existing
    // authenticated operator authority; the helper never invents a UID or
    // obtains direct database custody to evade session access checks.
    for (const candidate of observed) {
      const { session } = await rpc("sessions.describe", { key: candidate.key, agentId: candidate.agentId });
      if (!unchanged(session, candidate) || session.status === "running" || session.status === "queued" || session.hasActiveSubagentRun === true) {
        throw new Error(`Subscription session changed before batch; ${applied} selections already applied`);
      }
    }
    const targets = observed.map(({ key, agentId, expectedSessionId, expectedLifecycleRevision }) => ({
      key, agentId, expectedSessionId, ...(expectedLifecycleRevision ? { expectedLifecycleRevision } : {}),
    }));
    const result = await rpc("sessions.patchMany", { targets, patch: { model: null } });
    if (!Array.isArray(result?.outcomes) || result.outcomes.length !== targets.length) {
      throw new Error("Unexpected sessions.patchMany receipt; stop and inventory before retrying");
    }
    const received = new Set();
    let failures = 0;
    for (const outcome of result.outcomes) {
      const candidate = observed.find((row) => row.key === outcome.key && (!outcome.agentId || row.agentId === outcome.agentId));
      if (!candidate || received.has(candidate.key)) throw new Error("Mismatched sessions.patchMany receipt");
      received.add(candidate.key);
      if (outcome.ok === true) applied++;
      else failures++;
    }
    if (failures) throw new Error(`Subscription selection batch rejected ${failures} targets; ${applied} applied; stop and inventory`);
    for (const candidate of observed) {
      const { session } = await rpc("sessions.describe", { key: candidate.key, agentId: candidate.agentId });
      const spec = subscriptionCatalog.agents[candidate.agentId];
      if (!session || session.sessionId !== candidate.expectedSessionId ||
          (candidate.expectedLifecycleRevision !== undefined && session.lifecycleRevision !== candidate.expectedLifecycleRevision) ||
          preservedFingerprint(session) !== candidate.preservedFingerprint ||
          modelRef(session) !== `${spec.provider}/${spec.defaultModel}` ||
          (session.modelOverrideSource !== null && session.modelOverrideSource !== "inherited")) {
        throw new Error("Post-migration identity/native-state verification failed; stop without rewriting history");
      }
    }
  }
  return { ...inventory, applied };
}

function rpcFromCli(expectUrl) {
  const url = new URL(expectUrl);
  if (!["ws:", "wss:"].includes(url.protocol) || url.username || url.password || url.hash || url.search) {
    throw new Error("--expect-url must name the authenticated Gateway WebSocket origin");
  }
  return async (method, params) => {
    const result = spawnSync("openclaw", ["gateway", "call", method, "--params", JSON.stringify(params), "--json", "--timeout", "90000", "--expect-url", expectUrl], {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: process.env, timeout: 120000, maxBuffer: 16 * 1024 * 1024,
    });
    if (result.error || result.status !== 0) throw new Error(`Authenticated Gateway RPC failed: ${method}`);
    try { return JSON.parse(result.stdout); }
    catch { throw new Error(`Gateway RPC did not return JSON: ${method}`); }
  };
}

async function main(args) {
  let expectUrl, inventoryPath;
  let apply = false;
  const expectedCounts = {};
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === "--apply") apply = true;
    else if (arg === "--dry-run") apply = false;
    else if (arg === "--expect-url") expectUrl = args[++index];
    else if (arg === "--inventory") inventoryPath = args[++index];
    else if (arg === "--expect-count") {
      const match = /^(codex|claude)=([0-9]+)$/.exec(args[++index] ?? "");
      if (!match) throw new Error("--expect-count must be codex=N or claude=N");
      expectedCounts[match[1]] = Number(match[2]);
    } else throw new Error("Unknown selection migration option");
  }
  if (!expectUrl) throw new Error("--expect-url is required; existing operator authentication is never bypassed");
  const result = await migrateSubscriptionSelections(rpcFromCli(expectUrl), {
    apply, expectedCounts,
    ...(inventoryPath ? { onInventory: (inventory) => writeFile(inventoryPath, `${JSON.stringify(inventory)}\n`, { flag: "wx", mode: 0o600 }) } : {}),
  });
  // Keys, native identifiers and user-facing names stay in the protected
  // optional inventory file, not rollout logs.
  console.log(JSON.stringify({ operation: "subscription-current-selection", dryRun: !apply, counts: result.counts, applied: result.applied }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => { console.error(error.message); process.exitCode = 1; });
}
