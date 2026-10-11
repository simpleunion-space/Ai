import { spawnSync } from "node:child_process";
import { lstatSync, readFileSync } from "node:fs";
import { managedCodexAppServer, optionalConfigResult, subscriptionCatalog, subscriptionConfigUpdates } from "./subscription-models.mjs";

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
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) throw result.error;
  // OpenClaw 2026.9 returns non-zero for an already-absent path.  Treat only
  // that documented condition as an idempotent no-op; every other failure
  // still stops deployment rather than leaving retired Docker settings live.
  if (result.status !== 0) {
    const detail = `${result.stdout || ""}\n${result.stderr || ""}`;
    if (detail.includes("Config path not found")) return;
    throw new Error(`OpenClaw config unset failed: ${path}: ${detail.trim()}`);
  }
}

function optionalConfig(path) {
  const result = spawnSync("openclaw", ["config", "get", path, "--json"], {
    cwd: process.env.HOME, env: process.env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
  });
  return optionalConfigResult(path, result);
}

function isEnabled(name) {
  return ["1", "true", "yes", "on"].includes(process.env[name]?.trim().toLowerCase());
}

// API-key profiles are a higher-priority credential source than the managed
// provider config below. A previous profile with the old agentgateway token
// made OpenClaw send a 401 even though models.providers.agentgateway.apiKey had
// already been updated. Remove only this local provider's profiles; OAuth or
// API-key profiles for every other provider remain untouched.
function clearAgentgatewayAuthProfiles() {
  const listed = runCliJson(["models", "auth", "list", "--agent", "main", "--json"]);
  const profiles = Array.isArray(listed) ? listed : listed?.profiles;
  if (!Array.isArray(profiles)) {
    throw new Error("OpenClaw auth profile list has an unexpected JSON shape");
  }

  for (const profile of profiles) {
    if (profile?.provider !== "agentgateway" || typeof profile.id !== "string" || profile.id === "") continue;
    runCli(["models", "auth", "logout", "--agent", "main", "--yes", profile.id]);
  }
}

const modelId = required("OPENCLAW_CHAT_MODEL_ID");
const sourceModel = required("OPENCLAW_CHAT_MODEL_SOURCE");
const contextWindow = positiveInteger("OPENCLAW_CHAT_CONTEXT_LENGTH");
const maxTokens = positiveInteger("OPENCLAW_MAX_TOKENS");
const baseUrl = required("OPENCLAW_AGENTGATEWAY_BASE_URL");
const providerTimeoutSeconds = positiveInteger("OPENCLAW_PROVIDER_TIMEOUT_SECONDS");
const agentgatewayToken = required("AGENTGATEWAY_TOKEN");
const authentikTrustedProxyEnabled = isEnabled("OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED");
const gatewayToken = authentikTrustedProxyEnabled ? null : required("OPENCLAW_GATEWAY_TOKEN");
const publicOrigin = new URL(required("OPENCLAW_PUBLIC_ORIGIN"));
const trustedProxies = optionalList("OPENCLAW_TRUSTED_PROXIES");
const modelRef = `agentgateway/${modelId}`;
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
  throw new Error("OPENCLAW_MAX_TOKENS must be smaller than OPENCLAW_CHAT_CONTEXT_LENGTH");
}

// The check above only rejects the degenerate case - it enforces no actual
// safety MARGIN for input/history. The only real backstop is
// the installation's apply-model-profile.sh and its own
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
    `OPENCLAW_MAX_TOKENS (${maxTokens}) leaves too little of OPENCLAW_CHAT_CONTEXT_LENGTH (${contextWindow}) for input/history - keep it at or below half of the context window`,
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

if (!/^\/mcp\/[a-z][a-z0-9-]{0,62}$/.test(readonlyMcpPathPrefix)) {
  throw new Error("OPENCLAW_READONLY_MCP_PATH_PREFIX must match /mcp/<lowercase-slug>");
}

const provider = {
  baseUrl,
  apiKey: agentgatewayToken,
  // Agentgateway advertises the local Agentgateway backend as Chat
  // Completions, not as a full Responses implementation. In particular,
  // an OpenClaw transcript can contain its own role-less `compaction`
  // records; the Responses adapter forwards those raw records into
  // `input`, which Agentgateway correctly rejects as an invalid InputParam.
  // The Chat Completions adapter serializes ordinary conversation messages
  // instead, preserving the existing Agentgateway -> llama.cpp path and its
  // tool-call handling.
  api: "openai-completions",
  // The model lifecycle is owned by Agentgateway/model-apply. Do not probe its
  // non-OpenAI /api/v1/models preload endpoint through agentgateway.
  params: { preload: false },
  timeoutSeconds: providerTimeoutSeconds,
  models: [
    {
      id: modelId,
      name: modelId,
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
      // Without this block OpenClaw sends NO reasoning control to the backend
      // at any thinking level (verified by capturing real requests), so /think
      // did nothing and the model always thought at the template default.
      // Qwen3.8's chat template accepts exactly four reasoning_effort values -
      // none, low, medium and xhigh (its default); minimal, high and max make
      // llama.cpp answer HTTP 500 ("Unexpected reasoning effort"). So: expose
      // those, and map the OpenClaw labels onto them. "off" has to be mapped
      // explicitly, otherwise nothing is sent and thinking stays on.
      compat: {
        supportsReasoningEffort: true,
        supportedReasoningEfforts: ["none", "low", "medium", "xhigh"],
        reasoningEffortMap: { off: "none", minimal: "low", high: "xhigh", max: "xhigh" },
      },
    },
  ],
};

// OpenClaw's Codex harness otherwise chooses its own implicit mode from the
// local runtime requirements. Be explicit: a profile must never silently
// fall back from autonomous execution to a 30-second model reviewer and an
// approval request that a long-running tool turn cannot answer. The generic
// profile remains Guardian; an installation has to opt in to autonomous
// Codex execution deliberately.
const codexExecutionPolicy =
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

const codexAppServer = managedCodexAppServer(
  optionalConfig("plugins.entries.codex.config.appServer"),
  codexExecutionPolicy,
  required("OPENCLAW_CODEX_APP_SERVER_BIN"),
);

// `plugins.entries.codex.config.appServer` controls the managed Codex
// harness, but OpenClaw's native exec tool has an independent, central
// policy. Leaving the latter unset lets a runtime/session choose Guardian
// despite the autonomous Codex app-server configuration. Keep the two
// policies derived from the same explicit installation profile: generic
// deployments retain Guardian's normalized `auto` mode, while an
// installation opting into autonomous Codex execution gets `full` without
// the interpreter-inline approval override. Do not set `host` here: its
// default `auto` lets the explicitly configured Docker sandbox backend govern
// non-main execution below.
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

clearAgentgatewayAuthProfiles();

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
// stale entry per former default model in models.providers.agentgateway.models
// and agents.defaults.models, each still carrying whatever
// contextWindow/maxTokens applied when IT was current. A pre-existing
// OpenClaw session pinned to one of those old entries could still
// successfully request that model by name, forcing Agentgateway to load it
// alongside the current one - two large models sharing this host's fixed
// VRAM aperture is what caused a real kernel OOM on 2026-09-06 (see
// project_ai_stand_openclaw_jit_oom_incident memory notes). Every other
// setConfig call in this file already omits --merge and is confirmed (via
// live `cat openclaw.json`) to fully replace at its path with no
// accumulation. models.providers.agentgateway behaves the same way with plain
// --strict-json. agents.defaults.models is treated by openclaw's CLI as a
// "protected" path, though - confirmed live: omitting --merge there made
// the container crash-loop with "Refusing to replace agents.defaults.models
// ... Use --merge to merge object values or --replace to replace
// intentionally", so it needs --replace instead to get the same
// full-replace behavior without silently re-merging the old entries back.
// sensitive=true: provider now embeds a real agentgateway bearer token
// (previously the harmless constant "agentgateway"), so keep it out of a
// thrown-error message the way gatewayToken already is below.
setConfig("models.providers.agentgateway", JSON.stringify(provider), ["--strict-json"], { sensitive: true });
setConfig("agents.defaults.model.primary", JSON.stringify(modelRef), ["--strict-json"]);
// With the reasoning map above a session that never chose a level would start at
// "medium"; the local model used to think at its template default (xhigh). Keep
// that, and let people lower it per session with /think.
setConfig("agents.defaults.thinkingDefault", JSON.stringify("xhigh"), ["--strict-json"]);
const selectableModels = { [modelRef]: { alias: "Local Qwen" } };
const subscriptions = subscriptionConfigUpdates({
  providers: Object.fromEntries(Object.values(subscriptionCatalog.agents).map(({ provider }) =>
    [provider, optionalConfig(`models.providers.${provider}`)])),
  agents: Object.fromEntries(Object.keys(subscriptionCatalog.agents).map((agent) =>
    [agent, optionalConfig(`agents.entries.${agent}`)])),
  selectableModels,
});
for (const [path, value] of subscriptions.updates) {
  setConfig(path, JSON.stringify(value), ["--strict-json", ...(path.endsWith(".models") ? ["--replace"] : [])], {
    sensitive: path.startsWith("models.providers."),
  });
}
setConfig(
  "agents.defaults.models",
  JSON.stringify(subscriptions.selectableModels),
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
// accumulating history. Keep exact refs rather than provider wildcards. The
// subscription catalog adds native Codex/Claude selections, not additional
// local GPU backends.
setConfig(
  "agents.defaults.modelPolicy.allow",
  JSON.stringify(subscriptions.allowedModels),
  ["--strict-json"],
);
// The default list above is what every agent inherits, but the Codex and Claude runtimes belong to their own agents:
// their sign-ins are stored per agent (Claude's setup-token only in `claude`), so main would offer models it cannot
// run and the picker marks the provider "login required". The agent main works with the local model only, exactly as
// codex and claude each list only their own models (subscriptionConfigUpdates).
setConfig(
  "agents.entries.main.modelPolicy",
  JSON.stringify({ ...optionalConfig("agents.entries.main.modelPolicy"), allow: [modelRef] }),
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
  })) {
    setConfig(`mcp.servers.${name}`, JSON.stringify(remoteMcp(path)), ["--strict-json"]);
  }
  // "Personal MCP" lived on MetaMCP, which was removed on 2026-10-23; drop the
  // entry an older init left in openclaw.json.
  unsetConfig("mcp.servers.personalMcp");
}

// Telegram: who may talk to the bot, and where. Everything comes from Authentik through the read-only MCP reconciler, which
// apply.sh passes on as variables: the people (OPENCLAW_TELEGRAM_ALLOW_FROM, a JSON array of the numeric ids in their
// ai_stand_telegram_user_id attribute), the bot's owner (OPENCLAW_TELEGRAM_OWNER_IDS, the same attribute of the Telegram
// owner account) and the groups with their topics (OPENCLAW_TELEGRAM_GROUPS, a JSON object from that account's
// ai_stand_telegram_groups attribute). Ids kept by hand in the gateway's own state directory are added for anyone without
// an Authentik account. The bot token is the one thing Authentik does not hold: it is read from TELEGRAM_TOKEN_FILE, which
// apply.sh installs from the host's secret storage.
//
// With OPENCLAW_TELEGRAM_GROUPS set, this block writes the whole channel (token file, policies, groups and topics, the
// binding to the main agent, the owner); a group missing from the variable is removed, a fresh installation needs nothing
// by hand. Without it, only the allowlists of an already configured channel are updated, as they always were.
const TELEGRAM_FIXED_IDS_FILE = `${process.env.HOME}/.openclaw/telegram-static-allow-from.json`;
const TELEGRAM_TOKEN_FILE = `${process.env.HOME}/.openclaw/telegram-bot-token`;
const TELEGRAM_GROUP_ID = /^-[1-9][0-9]{4,19}$/;
const TELEGRAM_TOPIC_ID = /^(?:[1-9][0-9]{0,9}|\*)$/;
const TELEGRAM_AGENT_ID = /^[a-z][a-z0-9_-]{0,31}$/;
const TELEGRAM_DEFAULT_AGENT = "main";

function telegramIds(raw, label) {
  let parsed;
  try { parsed = JSON.parse(raw); } catch { throw new Error(`${label} must be a JSON array of Telegram user ids`); }
  if (!Array.isArray(parsed)) throw new Error(`${label} must be a JSON array of Telegram user ids`);
  return parsed.map((value) => {
    const text = String(value).trim();
    if (!/^[1-9][0-9]{4,14}$/.test(text)) throw new Error(`${label} holds an invalid Telegram user id`);
    return text;
  });
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// {"<group id>": {"requireMention": true, "topics": {"<topic id>": "<agent id>"}}} -> the entries of channels.telegram.groups
// without their allowFrom. Anything outside that shape stops the start: a half-read list could drop a group silently.
function telegramGroups(raw) {
  const label = "OPENCLAW_TELEGRAM_GROUPS";
  let parsed;
  try { parsed = JSON.parse(raw); } catch { throw new Error(`${label} must be a JSON object`); }
  if (!isPlainObject(parsed)) throw new Error(`${label} must be a JSON object`);
  const groups = {};
  for (const [groupId, group] of Object.entries(parsed)) {
    if (!TELEGRAM_GROUP_ID.test(groupId) || !isPlainObject(group)) throw new Error(`${label} holds an invalid group`);
    if (Object.keys(group).some((key) => key !== "requireMention" && key !== "topics")) {
      throw new Error(`${label} holds an unknown group setting`);
    }
    const requireMention = group.requireMention ?? true;
    const topics = group.topics ?? {};
    if (typeof requireMention !== "boolean" || !isPlainObject(topics)) throw new Error(`${label} holds an invalid group`);
    const entry = { requireMention, groupPolicy: "allowlist" };
    for (const [topicId, agentId] of Object.entries(topics)) {
      if (!TELEGRAM_TOPIC_ID.test(topicId) || typeof agentId !== "string" || !TELEGRAM_AGENT_ID.test(agentId)) {
        throw new Error(`${label} holds an invalid topic`);
      }
      entry.topics = { ...entry.topics, [topicId]: { agentId } };
    }
    groups[groupId] = entry;
  }
  return groups;
}

function telegramTokenFilePresent() {
  try {
    const status = lstatSync(TELEGRAM_TOKEN_FILE);
    return status.isFile() && status.size > 0;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

const telegramAllowEnv = process.env.OPENCLAW_TELEGRAM_ALLOW_FROM?.trim();
const telegramOwnerEnv = process.env.OPENCLAW_TELEGRAM_OWNER_IDS?.trim();
const telegramGroupsEnv = process.env.OPENCLAW_TELEGRAM_GROUPS?.trim();
if (telegramAllowEnv || telegramGroupsEnv) {
  const telegram = optionalConfig("channels.telegram") ?? {};
  const owners = telegramOwnerEnv ? telegramIds(telegramOwnerEnv, "OPENCLAW_TELEGRAM_OWNER_IDS") : [];
  const wantedGroups = telegramGroupsEnv ? telegramGroups(telegramGroupsEnv) : null;
  const tokenFile = telegramTokenFilePresent();
  // A managed channel needs a token (the file, or one an earlier setup left in the config); without one it stays as it is.
  const configured = Object.keys(telegram).length > 0;
  if (wantedGroups && !tokenFile && !telegram.botToken) {
    console.warn(`[openclaw] Telegram groups are configured but there is no bot token (${TELEGRAM_TOKEN_FILE}); the channel stays off`);
  } else if (wantedGroups || configured) {
    let fixedIds = [];
    try {
      fixedIds = telegramIds(readFileSync(TELEGRAM_FIXED_IDS_FILE, "utf8"), TELEGRAM_FIXED_IDS_FILE);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const people = telegramAllowEnv ? telegramIds(telegramAllowEnv, "OPENCLAW_TELEGRAM_ALLOW_FROM") : [];
    const allowed = [...new Set([...fixedIds, ...people, ...owners])].sort();
    const strict = ["--strict-json"];
    if (wantedGroups) {
      setConfig("channels.telegram.enabled", JSON.stringify(true), strict);
      if (tokenFile) {
        setConfig("channels.telegram.tokenFile", JSON.stringify(TELEGRAM_TOKEN_FILE), strict);
        unsetConfig("channels.telegram.botToken");
      }
      setConfig("channels.telegram.dmPolicy", JSON.stringify("disabled"), strict);
      setConfig("channels.telegram.groupPolicy", JSON.stringify("allowlist"), strict);
      const groups = Object.fromEntries(Object.entries(wantedGroups).map(([id, group]) => [id, { ...group, allowFrom: allowed }]));
      setConfig("channels.telegram.groups", JSON.stringify(groups), strict);
      // Every Telegram chat goes to the main agent unless a topic names another one. Bindings of other channels stay.
      const bindings = optionalConfig("bindings");
      const isOurs = (binding) => binding?.match?.channel === "telegram" && binding.match.accountId === "*" && !binding.type;
      const kept = Array.isArray(bindings) ? bindings.filter((binding) => !isOurs(binding)) : [];
      kept.push({ agentId: TELEGRAM_DEFAULT_AGENT, match: { channel: "telegram", accountId: "*" } });
      setConfig("bindings", JSON.stringify(kept), strict);
    } else {
      for (const groupId of Object.keys(telegram.groups ?? {})) {
        setConfig(`channels.telegram.groups.${groupId}.allowFrom`, JSON.stringify(allowed), strict);
      }
    }
    setConfig("channels.telegram.allowFrom", JSON.stringify(allowed), strict);
    setConfig("channels.telegram.groupAllowFrom", JSON.stringify(allowed), strict);
    // Slash commands (/status, /model, ...): once commands.ownerAllowFrom names an owner, an allowlisted sender who is not
    // an owner may use only /new and /reset. commands.allowFrom makes the same list the command authorization source, so
    // every member the bot talks to may also use ordinary commands. Owner-only commands (/config, /restart, /update,
    // exec approvals, ...) are for commands.ownerAllowFrom, the Telegram owner account's own id; owners of other
    // channels stay as they are.
    setConfig("commands.allowFrom", JSON.stringify({ telegram: allowed }), strict);
    if (owners.length > 0) {
      const current = optionalConfig("commands.ownerAllowFrom");
      const others = Array.isArray(current) ? current.filter((entry) => !String(entry).startsWith("telegram:")) : [];
      setConfig("commands.ownerAllowFrom", JSON.stringify([...others, ...owners.map((id) => `telegram:${id}`)]), strict);
    }
    console.log(`[openclaw] Telegram set for ${allowed.length} user id(s), ${owners.length} owner(s)${wantedGroups ? `, ${Object.keys(wantedGroups).length} group(s)` : ""}`);
  }
}

// LM Studio is gone from this stand (llama.cpp behind Agentgateway replaced it).
// Its provider plugin ships inside OpenClaw and cannot be uninstalled, only
// disabled; an older init had enabled it.
setConfig("plugins.entries.lmstudio.enabled", JSON.stringify(false), ["--strict-json"]);
unsetConfig("plugins.entries.lmstudio.config");

// The Codex binary is a managed OpenClaw harness process inside this same
// container, not a separate ai-stand service. Its execution profile does not
// grant a raw host socket: sandboxed tool work reaches Docker only through
// the private, least-privilege socket proxy declared in compose.yaml.
setConfig("plugins.entries.codex.enabled", JSON.stringify(true), ["--strict-json"]);
setConfig(
  "plugins.entries.codex.config.appServer",
  JSON.stringify(codexAppServer),
  ["--strict-json"],
  { sensitive: true },
);
// Session discovery is independent of model availability and stays disabled.
setConfig("plugins.entries.codex.config.sessionCatalog.enabled", JSON.stringify(false), ["--strict-json"]);
setConfig("plugins.entries.anthropic.config.sessionCatalog.enabled", JSON.stringify(false), ["--strict-json"]);

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

// Docker-out-of-Docker sandbox isolation.  The Gateway sees a private socket
// proxy over DOCKER_HOST, never the raw host socket.  The proxy and Gateway
// are co-located on ai02; Docker can therefore inspect the Gateway and reuse
// this narrowly mounted persistent workspace root in sibling sandbox
// containers. Scope=agent keeps Main, Codex and Claude workspaces separate.
setConfig("agents.defaults.sandbox.mode", JSON.stringify("non-main"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.backend", JSON.stringify("docker"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.scope", JSON.stringify("agent"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.workspaceAccess", JSON.stringify("none"), ["--strict-json"]);
setConfig("agents.defaults.sandbox.browser.enabled", JSON.stringify(false), ["--strict-json"]);
setConfig(
  "agents.defaults.sandbox.workspaceRoot",
  JSON.stringify("/home/ai/.openclaw/sandboxes"),
  ["--strict-json"],
);
setConfig(
  "agents.defaults.sandbox.docker",
  JSON.stringify({
    image: "openclaw-sandbox:bookworm-slim",
    containerPrefix: "openclaw-sbx-",
    network: "none",
    user: "10000:20000",
  }),
  ["--strict-json"],
);
setConfig(
  "agents.defaults.sandbox.prune",
  JSON.stringify({ idleHours: 24, maxAgeDays: 7 }),
  ["--strict-json"],
);
unsetConfig("agents.defaults.sandbox.ssh");
for (const agentId of ["main", "codex", "claude"]) {
  // Keep the persisted bind source separate for every trusted agent.  The
  // Docker backend will create session workspaces below this agent root.
  setConfig(
    `agents.entries.${agentId}.sandbox.workspaceRoot`,
    JSON.stringify(`/home/ai/.openclaw/sandboxes/${agentId}`),
    ["--strict-json"],
  );
  unsetConfig(`agents.entries.${agentId}.sandbox.ssh`);
}

runCli(["config", "validate"]);

if (lancedb) {
  // Config validation checks the slot exists; runtime inspection additionally
  // loads LanceDB's Linux native module before the Gateway is allowed to run.
  runCli(["plugins", "inspect", "memory-lancedb", "--runtime", "--json"]);
}

console.log(`OpenClaw is configured to use ${modelRef} at ${baseUrl}`);
