import { spawnSync } from "node:child_process";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function positiveInteger(name) {
  const raw = required(name);
  // Number.parseInt truncates at the first non-digit rather than
  // validating the whole string ("8192.5" -> 8192, "4096abc" -> 4096) -
  // this is the one function responsible for validating contextWindow/
  // maxTokens, which the check below relies on being exact.
  if (!/^[0-9]+$/.test(raw)) {
    throw new Error(`${name} must be a positive integer`);
  }
  const value = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

function optionalList(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    return [];
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function enumValue(name, allowed) {
  const value = required(name);
  if (!allowed.includes(value)) {
    throw new Error(`${name} must be one of: ${allowed.join(", ")}`);
  }
  return value;
}

function runCli(args, redactIndexes = []) {
  const result = spawnSync("openclaw", args, {
    cwd: process.env.HOME,
    env: process.env,
    stdio: "inherit",
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    const displayArgs = args.map((arg, index) => (redactIndexes.includes(index) ? "<redacted>" : arg));
    throw new Error(`OpenClaw command failed: ${displayArgs.join(" ")}`);
  }
}

function runCliJson(args) {
  const result = spawnSync("openclaw", args, {
    cwd: process.env.HOME,
    env: process.env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`OpenClaw command failed: ${args.join(" ")}: ${result.stderr.trim()}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`OpenClaw command did not return JSON: ${args.join(" ")}: ${error.message}`);
  }
}

function setConfig(path, value, options = [], { sensitive = false } = {}) {
  // sensitive=true keeps the value out of the thrown error message (and
  // therefore out of container logs) if this specific call fails; it cannot
  // hide the value from this process's own argv/environ while it runs -
  // that is an inherent property of shelling out to a third-party CLI.
  runCli(["config", "set", path, value, ...options], sensitive ? [3] : []);
}

function unsetConfig(path) {
  const result = spawnSync("openclaw", ["config", "unset", path], {
    cwd: process.env.HOME,
    env: process.env,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  // `config unset` is idempotent in the pinned OpenClaw CLI. A non-zero
  // result indicates an actual invalid configuration/path and must stop the
  // deployment rather than leave a retired static subscription provider live.
  if (result.status !== 0) {
    throw new Error(`OpenClaw config unset failed: ${path}`);
  }
}

function isEnabled(name) {
  return ["1", "true", "yes", "on"].includes(process.env[name]?.trim().toLowerCase());
}

// API-key profiles are a higher-priority credential source than the managed
// provider config below. A previous profile with the old agentgateway token
// made OpenClaw send a 401 even though models.providers.lmstudio.apiKey had
// already been updated. Remove only this local provider's profiles; OAuth or
// API-key profiles for every other provider remain untouched.
function clearLmstudioAuthProfiles() {
  const listed = runCliJson(["models", "auth", "list", "--agent", "main", "--json"]);
  const profiles = Array.isArray(listed) ? listed : listed?.profiles;
  if (!Array.isArray(profiles)) {
    throw new Error("OpenClaw auth profile list has an unexpected JSON shape");
  }

  for (const profile of profiles) {
    if (profile?.provider !== "lmstudio" || typeof profile.id !== "string" || profile.id === "") continue;
    runCli(["models", "auth", "logout", "--agent", "main", "--yes", profile.id]);
  }
}

const modelId = required("LMSTUDIO_MODEL_IDENTIFIER");
const sourceModel = required("LMSTUDIO_MODEL");
const contextWindow = positiveInteger("LMSTUDIO_CONTEXT_LENGTH");
const maxTokens = positiveInteger("OPENCLAW_MAX_TOKENS");
const baseUrl = required("OPENCLAW_LMSTUDIO_BASE_URL");
const providerTimeoutSeconds = positiveInteger("OPENCLAW_PROVIDER_TIMEOUT_SECONDS");
const agentgatewayToken = required("AGENTGATEWAY_TOKEN");
const authentikTrustedProxyEnabled = isEnabled("OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED");
const gatewayToken = authentikTrustedProxyEnabled ? null : required("OPENCLAW_GATEWAY_TOKEN");
const publicOrigin = new URL(required("OPENCLAW_PUBLIC_ORIGIN"));
const trustedProxies = optionalList("OPENCLAW_TRUSTED_PROXIES");
const modelRef = `lmstudio/${modelId}`;
const gigacodeEnabled = isEnabled("OPENCLAW_GIGACODE_SUBSCRIPTION_ENABLED");
const gigacodeModelId = gigacodeEnabled ? required("OPENCLAW_GIGACODE_MODEL_ID") : null;
const gigacodeDisplayName = gigacodeEnabled ? required("OPENCLAW_GIGACODE_DISPLAY_NAME") : null;
const gigacodeContextWindow = gigacodeEnabled ? positiveInteger("OPENCLAW_GIGACODE_CONTEXT_WINDOW") : null;
const gigacodeAdapterBaseUrl = gigacodeEnabled
  ? new URL(required("OPENCLAW_GIGACODE_ADAPTER_BASE_URL"))
  : null;
const gigacodeAdapterBearer = gigacodeEnabled ? required("OPENCLAW_GIGACODE_ADAPTER_BEARER") : null;
const gigacodeTelegramSubjectMapPath = gigacodeEnabled
  ? required("OPENCLAW_GIGACODE_TELEGRAM_SUBJECT_MAP_FILE")
  : null;
// The bridge's public model ID intentionally includes a slash. OpenClaw
// identifies the provider with the first segment only and sends the complete
// model ID to agentgateway, where the explicit gigacode/codechat route is
// evaluated before the local LM Studio wildcard.
const gigacodeModelRef = gigacodeEnabled ? `gigacode/${gigacodeModelId}` : null;
const readonlyMcpEnabled = isEnabled("OPENCLAW_READONLY_MCP_ENABLED");
const readonlyMcpBaseUrl = readonlyMcpEnabled ? new URL(required("OPENCLAW_READONLY_MCP_BASE_URL")) : null;
const readonlyMcpPathPrefix = readonlyMcpEnabled
  ? required("OPENCLAW_READONLY_MCP_PATH_PREFIX")
  : "/mcp/work";
const codexExecutionProfile = enumValue("OPENCLAW_CODEX_EXECUTION_PROFILE", ["guardian", "autonomous"]);
const lancedbEnabled = isEnabled("OPENCLAW_LANCEDB_ENABLED");
const lancedb = lancedbEnabled
  ? {
      dbPath: required("OPENCLAW_LANCEDB_DB_PATH"),
      embedding: {
        // Keep the token symbolic in persistent config. OpenClaw expands it
        // at runtime, so the Docker secret never lands in openclaw.json.
        apiKey: "${AGENTGATEWAY_TOKEN}",
        baseUrl,
        model: required("OPENCLAW_LANCEDB_EMBEDDING_MODEL"),
        dimensions: positiveInteger("OPENCLAW_LANCEDB_EMBEDDING_DIMENSIONS"),
      },
      autoRecall: true,
      autoCapture: false,
    }
  : null;

if (maxTokens >= contextWindow) {
  throw new Error("OPENCLAW_MAX_TOKENS must be smaller than LMSTUDIO_CONTEXT_LENGTH");
}

// The check above only rejects the degenerate case - it enforces no actual
// safety MARGIN for input/history. The only real backstop is
// installations/kurkin-family__labs__m01/apply-model-profile.sh's own
// divisor/floor/cap policy (1/4 of context, following a real 2026-09-06 OOM
// incident where a stale session's oversized maxTokens left almost no
// margin) - that policy is installation-specific, so a different/future
// installation, or a manual `docker service update --env-add
// OPENCLAW_MAX_TOKENS=...`, had no backstop here at all. Cap at half of
// context as a broad safety net - well above that installation's own
// tighter 1/4 policy, so it never conflicts with it, but still catches a
// clearly dangerous configuration reaching this file directly.
if (maxTokens > contextWindow / 2) {
  throw new Error(
    `OPENCLAW_MAX_TOKENS (${maxTokens}) leaves too little of LMSTUDIO_CONTEXT_LENGTH (${contextWindow}) for input/history - keep it at or below half of the context window`,
  );
}

if (publicOrigin.protocol !== "https:" || publicOrigin.pathname !== "/") {
  throw new Error("OPENCLAW_PUBLIC_ORIGIN must be an HTTPS origin without a path");
}

if (authentikTrustedProxyEnabled && trustedProxies.length === 0) {
  throw new Error("OPENCLAW_TRUSTED_PROXIES is required when Authentik trusted-proxy mode is enabled");
}

if (readonlyMcpBaseUrl && readonlyMcpBaseUrl.protocol !== "https:") {
  throw new Error("OPENCLAW_READONLY_MCP_BASE_URL must be an HTTPS origin");
}

if (gigacodeAdapterBaseUrl && (
  gigacodeAdapterBaseUrl.protocol !== "http:" ||
  gigacodeAdapterBaseUrl.pathname !== "/v1" ||
  gigacodeAdapterBaseUrl.search ||
  gigacodeAdapterBaseUrl.hash
)) {
  throw new Error("OPENCLAW_GIGACODE_ADAPTER_BASE_URL must be an internal HTTP /v1 origin");
}

if (!/^\/mcp\/[a-z][a-z0-9-]{0,62}$/.test(readonlyMcpPathPrefix)) {
  throw new Error("OPENCLAW_READONLY_MCP_PATH_PREFIX must match /mcp/<lowercase-slug>");
}

const provider = {
  baseUrl,
  apiKey: agentgatewayToken,
  api: "openai-responses",
  // The model lifecycle is owned by LM Studio/model-apply. Do not probe its
  // non-OpenAI /api/v1/models preload endpoint through agentgateway.
  params: { preload: false },
  timeoutSeconds: providerTimeoutSeconds,
  models: [
    {
      id: modelId,
      name: `${sourceModel} via LM Studio`,
      reasoning: true,
      input: ["text", "image"],
      cost: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
      },
      contextWindow,
      maxTokens,
    },
  ],
};

const gigacodeProvider = gigacodeEnabled
  ? {
      // This is a local ai02 adapter, not Agentgateway and not GigaCode.
      // The adapter proves an authenticated requester before it obtains a
      // short-lived broker JWT for a single personal Agentgateway route.
      baseUrl: gigacodeAdapterBaseUrl.toString().replace(/\/$/, ""),
      apiKey: gigacodeAdapterBearer,
      api: "openai-responses",
      timeoutSeconds: providerTimeoutSeconds,
      models: [
        {
          id: gigacodeModelId,
          name: gigacodeDisplayName,
          reasoning: true,
          input: ["text", "image"],
          cost: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
          },
          contextWindow: gigacodeContextWindow,
          maxTokens: Math.min(maxTokens, Math.floor(gigacodeContextWindow / 2)),
        },
      ],
    }
  : null;

// OpenClaw's Codex harness otherwise chooses its own implicit mode from the
// local runtime requirements. Be explicit: a profile must never silently
// fall back from autonomous execution to a 30-second model reviewer and an
// approval request that a long-running tool turn cannot answer. The generic
// profile remains Guardian; an installation has to opt in to autonomous
// Codex execution deliberately.
const codexAppServer =
  codexExecutionProfile === "autonomous"
    ? {
        mode: "yolo",
        approvalPolicy: "never",
        sandbox: "danger-full-access",
        approvalsReviewer: "user",
      }
    : {
        mode: "guardian",
        approvalPolicy: "on-request",
        sandbox: "workspace-write",
        approvalsReviewer: "auto_review",
      };

// `plugins.entries.codex.config.appServer` controls the managed Codex
// harness, but OpenClaw's native exec tool has an independent, central
// policy. Leaving the latter unset lets a runtime/session choose Guardian
// despite the autonomous Codex app-server configuration. Keep the two
// policies derived from the same explicit installation profile: generic
// deployments retain Guardian's normalized `auto` mode, while an
// installation opting into autonomous Codex execution gets `full` without
// the interpreter-inline approval override. Do not set `host` here: its
// default `auto` continues to select the Docker sandbox configured below.
const execPolicy =
  codexExecutionProfile === "autonomous"
    ? { mode: "full", strictInlineEval: false }
    : { mode: "auto" };

const gatewayAuth = authentikTrustedProxyEnabled
  ? {
      mode: "trusted-proxy",
      allowTailscale: false,
      trustedProxy: {
        // Authentik documents this as a stable hashed identifier, unlike a
        // mutable username or email. ai02 Nginx overwrites it from the
        // forward-auth response and strips every client-supplied variant.
        userHeader: "x-authentik-uid",
        requiredHeaders: ["x-forwarded-host", "x-forwarded-proto", "x-authentik-meta-provider"],
        allowUsers: [],
        // The profile's native Nginx reaches the host-published Gateway on
        // loopback. This opt-in is safe only with strict loopback proxy
        // addresses and a host firewall that closes direct port 18789 access.
        allowLoopback: true,
        deviceAutoApprove: {
          enabled: true,
          scopes: ["operator.read", "operator.write", "operator.approvals", "operator.questions"],
        },
      },
    }
  : {
      mode: "token",
      token: gatewayToken,
      allowTailscale: false,
    };

clearLmstudioAuthProfiles();

setConfig("gateway.mode", JSON.stringify("local"), ["--strict-json"]);
// Kept in sync by hand with entrypoint.sh's own `--bind lan` CLI flag on
// `openclaw gateway run` - not derived from one another, same kind of
// gotcha already noted elsewhere in this repo for other "kept in sync by
// hand" pairs (e.g. compose.yaml's AUTHENTIK_BOOTSTRAP_USERNAME).
setConfig("gateway.bind", JSON.stringify("lan"), ["--strict-json"]);
// Replace the complete object: this removes a persisted token when switching
// an existing Gateway state to the mutually exclusive trusted-proxy mode.
setConfig("gateway.auth", JSON.stringify(gatewayAuth), ["--strict-json"], { sensitive: !authentikTrustedProxyEnabled });
setConfig("gateway.trustedProxies", JSON.stringify(trustedProxies), ["--strict-json"]);
setConfig("gateway.allowRealIpFallback", JSON.stringify(false), ["--strict-json"]);
setConfig("gateway.controlUi.enabled", JSON.stringify(true), ["--strict-json"]);
// File/binary links are constructed by the gateway itself. Persist the
// externally reachable origin, otherwise a replaced sandbox can make links
// fall back to its internal localhost address.
setConfig("gateway.publicOrigin", JSON.stringify(publicOrigin.origin), ["--strict-json"]);
setConfig(
  "gateway.controlUi.allowedOrigins",
  JSON.stringify([publicOrigin.origin]),
  ["--strict-json"],
);
setConfig("models.mode", JSON.stringify("merge"), ["--strict-json"]);
// No --merge on these two: this container's entrypoint runs on every start,
// including after model-apply switches the active model, and `provider`
// above is always a complete, self-sufficient object for the CURRENT model
// only. --merge on an array/map path appends by id/key instead of
// replacing - across repeated model switches this silently accumulated one
// stale entry per former default model in models.providers.lmstudio.models
// and agents.defaults.models, each still carrying whatever
// contextWindow/maxTokens applied when IT was current. A pre-existing
// OpenClaw session pinned to one of those old entries could still
// successfully request that model by name, forcing LM Studio to load it
// alongside the current one - two large models sharing this host's fixed
// VRAM aperture is what caused a real kernel OOM on 2026-09-06 (see
// project_ai_stand_openclaw_jit_oom_incident memory notes). Every other
// setConfig call in this file already omits --merge and is confirmed (via
// live `cat openclaw.json`) to fully replace at its path with no
// accumulation. models.providers.lmstudio behaves the same way with plain
// --strict-json. agents.defaults.models is treated by openclaw's CLI as a
// "protected" path, though - confirmed live: omitting --merge there made
// the container crash-loop with "Refusing to replace agents.defaults.models
// ... Use --merge to merge object values or --replace to replace
// intentionally", so it needs --replace instead to get the same
// full-replace behavior without silently re-merging the old entries back.
// sensitive=true: provider now embeds a real agentgateway bearer token
// (previously the harmless constant "lmstudio"), so keep it out of a
// thrown-error message the way gatewayToken already is below.
setConfig("models.providers.lmstudio", JSON.stringify(provider), ["--strict-json"], { sensitive: true });
if (gigacodeProvider) {
  // This provider ends at the local ai02 adapter. The adapter accepts only
  // an opaque session record produced by the version-pinned requester
  // plugin, then obtains a short-lived subject JWT for one Agentgateway
  // route. No shared machine token can address a subscription backend.
  setConfig("models.providers.gigacode", JSON.stringify(gigacodeProvider), ["--strict-json"], { sensitive: true });
} else {
  // GigaCode is now a personal subscription path.  Remove a provider written
  // by earlier m01 profiles so a static machine token cannot keep invoking a
  // former shared bridge after the personal adapter is enabled.
  unsetConfig("models.providers.gigacode");
}
if (gigacodeEnabled) {
  setConfig(
    "plugins.entries.ai-stand-gigacode-requester",
    JSON.stringify({
      enabled: true,
      hooks: { allowConversationAccess: true },
      config: {
        sessionMapPath: "/home/ai/.openclaw/gigacode-requester/sessions.json",
        telegramSubjectMapPath: gigacodeTelegramSubjectMapPath,
      },
    }),
    ["--strict-json"],
  );
} else {
  unsetConfig("plugins.entries.ai-stand-gigacode-requester");
}
setConfig("agents.defaults.model.primary", JSON.stringify(modelRef), ["--strict-json"]);
const selectableModels = { [modelRef]: { alias: "Local Qwen" } };
if (gigacodeModelRef) {
  selectableModels[gigacodeModelRef] = { alias: gigacodeDisplayName };
}
setConfig(
  "agents.defaults.models",
  JSON.stringify(selectableModels),
  ["--strict-json", "--replace"],
);
// agents.defaults.modelPolicy.allow is OpenClaw's actual allowlist for
// /model, session overrides, and the Control UI model picker - separate
// from and not implied by agents.defaults.models above, which is only
// alias/settings metadata ("adding an entry does not restrict model
// overrides" - docs/concepts/models.md). Left unmanaged here, it does NOT
// self-heal like every other model-identity setting in this file: found
// live 2026-09-09 still holding three refs (qwen3-1.7b-q8,
// qwen3.6-35b-a3b-q8, qwen/qwen3.6-35b-a3b) from some earlier point in this
// installation's history, long after the active model had moved on to
// qwen3.8-27b - stale entries the picker kept offering alongside the real
// current default. Re-deriving it from modelRef on every container start,
// the same way as agents.defaults.model.primary above, keeps it in lockstep
// with whatever model this container is actually configured for instead of
// accumulating history. A single exact ref (not a "lmstudio/*" wildcard)
// matches this installation's own intent: only the current profiled model
// should be selectable, not every model LM Studio happens to have
// available.
setConfig(
  "agents.defaults.modelPolicy.allow",
  JSON.stringify(gigacodeModelRef ? [modelRef, gigacodeModelRef] : [modelRef]),
  ["--strict-json"],
);

setConfig("tools.exec", JSON.stringify(execPolicy), ["--strict-json"]);

if (readonlyMcpBaseUrl) {
  // Per-requester OAuth isolates the Authentik grant of every sender. The
  // resource server then maps the JWT subject to that person's dedicated
  // Jira/Confluence/IMAP target. Do not replace mcp.servers as a whole: it
  // would erase a user's separately managed personal MCP configuration.
  const remoteMcp = (path) => ({
    url: new URL(path, readonlyMcpBaseUrl).toString(),
    transport: "streamable-http",
    auth: "oauth",
    oauth: { identity: "per-requester", scope: "openid profile email groups" },
    requestTimeoutMs: 86400000,
    connectionTimeoutMs: 30000,
    sslVerify: true,
  });
  for (const [name, path] of Object.entries({
    jiraReadonly: `${readonlyMcpPathPrefix}/jira-readonly-mcp`,
    confluenceReadonly: `${readonlyMcpPathPrefix}/confluence-readonly-mcp`,
    imapReadonly: `${readonlyMcpPathPrefix}/imap-readonly-mcp`,
    personalMcp: "/mcp/personal",
  })) {
    setConfig(`mcp.servers.${name}`, JSON.stringify(remoteMcp(path)), ["--strict-json"]);
  }
}

// The Codex binary is a managed OpenClaw harness process inside this same
// container, not a separate ai-stand service. The yolo preset does not grant
// host Docker access: openclaw-gateway has no docker.sock and its Docker CLI
// is already pinned through DOCKER_HOST to openclaw-sandbox-dind.
setConfig("plugins.entries.codex.enabled", JSON.stringify(true), ["--strict-json"]);
setConfig(
  "plugins.entries.codex.config.appServer",
  JSON.stringify(codexAppServer),
  ["--strict-json"],
);

if (lancedb) {
  // Only one plugin can own the memory slot. Replacing memory-core prevents
  // duplicate recall/sync work and removes its unused OpenAI dependency.
  setConfig(
    "plugins.entries.memory-lancedb",
    // LanceDB is installed from npm rather than bundled with OpenClaw.
    // Explicitly permit its recall hook to read the current conversation;
    // without this OpenClaw blocks before_prompt_build and autoRecall=true
    // is silently ineffective. autoCapture remains false in its own config.
    JSON.stringify({
      enabled: true,
      hooks: { allowConversationAccess: true },
      config: lancedb,
    }),
    ["--strict-json"],
  );
  setConfig("plugins.slots.memory", JSON.stringify("memory-lancedb"), ["--strict-json"]);
  setConfig("memory.search.enabled", JSON.stringify(true), ["--strict-json"]);
}

// Docker-backed sandbox isolation: DOCKER_HOST (set in compose.yaml's
// x-openclaw-environment) points the docker CLI/SDK this backend uses at
// the isolated openclaw-sandbox-dind sidecar, not the host's real Docker -
// openclaw-gateway itself has no docker.sock, no docker binary, and a
// hardened capability set (see compose.yaml). "non-main" sandboxes spawned/
// tool-use work but leaves the primary chat session unsandboxed, the least
// disruptive default; "all" is available if that's ever wanted instead.
// prune keeps old sandbox containers from accumulating forever in the
// isolated dind's own storage.
setConfig("agents.defaults.sandbox.mode", JSON.stringify("non-main"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.backend", JSON.stringify("docker"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.scope", JSON.stringify("agent"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.workspaceAccess", JSON.stringify("none"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.workspaceRoot", JSON.stringify("~/.openclaw/sandboxes"), ["--strict-json"]);
setConfig(
  "agents.defaults.sandbox.prune",
  JSON.stringify({ idleHours: 24, maxAgeDays: 7 }),
  ["--strict-json"],
);

runCli(["config", "validate"]);

if (lancedb) {
  // Config validation checks the slot exists; runtime inspection additionally
  // loads LanceDB's Linux native module before the Gateway is allowed to run.
  runCli(["plugins", "inspect", "memory-lancedb", "--runtime", "--json"]);
}

console.log(`OpenClaw is configured to use ${modelRef} at ${baseUrl}`);
