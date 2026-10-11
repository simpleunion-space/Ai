#!/usr/bin/env node

import { cleanupGitlabArtifacts } from "./cleanup-gitlab.mjs";
import { cleanupMetamcpArtifacts } from "./cleanup-metamcp.mjs";

const config = {
  baseUrl: env("AUTHENTIK_BASE_URL", "http://authentik:9000").replace(/\/+$/, ""),
  publicUrl: env("AUTHENTIK_PUBLIC_URL", "https://authentik.local").replace(/\/+$/, ""),
  token: requiredEnv("AUTHENTIK_API_TOKEN"),
  bootstrapUsername: env("AUTHENTIK_BOOTSTRAP_USERNAME", "akadmin"),
  openwebuiClientSecret: requiredEnv("AUTHENTIK_OPENWEBUI_CLIENT_SECRET"),
  portainerClientSecret: requiredEnv("AUTHENTIK_PORTAINER_CLIENT_SECRET"),
  agentgatewayClientSecret: requiredEnv("AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET"),
  coderClientSecret: requiredEnv("AUTHENTIK_CODER_CLIENT_SECRET"),
  giteaEnabled: env("AUTHENTIK_GITEA_ENABLED", "false") === "true",
  giteaClientSecret: env("AUTHENTIK_GITEA_CLIENT_SECRET", ""),
};

const groups = {
  admins: "ai-admins",
  users: "ai-users",
};

for (const [role, name] of Object.entries(groups)) {
  if (!/^ai-[a-z0-9-]+$/.test(name)) {
    throw new Error(`Managed Authentik group ${role} must use the ai- prefix: ${name}`);
  }
}

const hosts = {
  openwebui: env("AUTHENTIK_OPENWEBUI_URL", "https://openwebui.local").replace(/\/+$/, ""),
  openclaw: env("AUTHENTIK_OPENCLAW_URL", "https://openclaw.local").replace(/\/+$/, ""),
  portainer: env("AUTHENTIK_PORTAINER_URL", "https://portainer.local").replace(/\/+$/, ""),
  agentgateway: env("AUTHENTIK_AGENTGATEWAY_URL", "https://agentgateway.local").replace(/\/+$/, ""),
  coder: env("AUTHENTIK_CODER_URL", "https://coder.local").replace(/\/+$/, ""),
  gitea: env("AUTHENTIK_GITEA_URL", "https://gitea.local").replace(/\/+$/, ""),
};

// Vendored into docker/authentik/icons/ and served by nginx at
// config.publicUrl + /app-icons/ (see install_authentik_icons() in
// apply.sh) rather than referencing each project's own site or another
// ai-stand component's live instance directly - confirmed live 2026-09-11
// that a couple of those "obvious" sources are actively wrong
// (agentgateway's own /favicon.ico returns HTTP 200 with Content-Type:
// image/vnd.microsoft.icon but the real bytes are SVG; GitHub's
// openwebui "vector" logos are real image/svg+xml but each just
// wraps a raster/diagram, not a usable icon) - vendoring means every icon
// here was individually downloaded and verified byte-for-byte (`file`, not
// just Content-Type) once, and Authentik's own app-list tiles no longer
// depend on any of those sites - or on each other's live instance - staying
// reachable.
const icons = {
  openwebui: `${config.publicUrl}/app-icons/openwebui.png`,
  portainer: `${config.publicUrl}/app-icons/portainer.svg`,
  agentgateway: `${config.publicUrl}/app-icons/agentgateway.svg`,
  // The OAuth resource-server contract is Agentgateway itself, not a
  // separate product. Reuse its official mark instead of a look-alike tile.
  agentgatewayMcp: `${config.publicUrl}/app-icons/agentgateway.svg`,
  openclaw: `${config.publicUrl}/app-icons/openclaw.png`,
  coder: `${config.publicUrl}/app-icons/coder.svg`,
  gitea: `${config.publicUrl}/app-icons/gitea.svg`,
};

function env(name, fallback) {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

function requiredEnv(name) {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function regexEscape(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function log(message) {
  process.stdout.write(`[authentik-config] ${message}\n`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function qs(params = {}) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null || value === "") continue;
    if (Array.isArray(value)) {
      for (const item of value) search.append(key, item);
    } else {
      search.set(key, String(value));
    }
  }
  return search.toString();
}

async function rawFetch(path, options = {}) {
  const url = path.startsWith("http") ? path : `${config.baseUrl}${path}`;
  const response = await fetch(url, {
    ...options,
    headers: {
      ...(options.headers ?? {}),
    },
  });
  return response;
}

async function api(method, path, body, options = {}) {
  const urlPath = path.startsWith("/api/v3/") ? path : `/api/v3${path}`;
  const response = await rawFetch(urlPath, {
    method,
    headers: {
      Authorization: `Bearer ${config.token}`,
      Accept: "application/json",
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  if (options.allow404 && response.status === 404) {
    return null;
  }

  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }

  if (!response.ok) {
    throw new Error(`${method} ${urlPath} failed with HTTP ${response.status}: ${typeof payload === "string" ? payload : JSON.stringify(payload)}`);
  }

  return payload;
}

async function list(path, params = {}) {
  const pageSize = 100;
  const maxPages = 1000; // 100k objects - a real API response never gets
  // remotely close to this; it exists only to fail loudly instead of
  // spinning forever if pagination.count is ever inconsistent across pages.
  let page = 1;
  const results = [];

  while (page <= maxPages) {
    const query = qs({ ...params, page, page_size: pageSize });
    const payload = await api("GET", `${path}${query ? `?${query}` : ""}`);
    if (Array.isArray(payload)) {
      // A handful of Authentik endpoints legitimately return a bare array
      // instead of the paginated {results, pagination} envelope.
      return payload;
    }
    if (!payload || !Array.isArray(payload.results)) {
      // Every ensureX function in this file relies on list() to say
      // whether an object already exists - silently treating an
      // unrecognized response shape as "no results" would make all of
      // them believe nothing exists and mass-create duplicates if
      // Authentik's pagination envelope ever changes shape. Fail loudly
      // instead.
      throw new Error(`Unexpected response shape from ${path}: ${JSON.stringify(payload)}`);
    }
    results.push(...payload.results);
    const total = payload.pagination?.count ?? results.length;
    if (results.length >= total || payload.results.length === 0) return results;
    page += 1;
  }

  throw new Error(`list(${path}) exceeded ${maxPages} pages - pagination.count is likely inconsistent`);
}

async function waitForApi() {
  const deadline = Date.now() + 10 * 60 * 1000;
  let lastError = "";

  while (Date.now() < deadline) {
    try {
      const me = await api("GET", "/core/users/me/");
      log(`API token accepted as ${me.username ?? me.name ?? "current user"}`);
      return;
    } catch (error) {
      lastError = error.message;
      await sleep(5000);
    }
  }

  throw new Error(`Authentik API did not become ready or bootstrap token is invalid: ${lastError}`);
}

async function getFlow(slugCandidates, designation) {
  for (const slug of slugCandidates) {
    const flow = await api("GET", `/flows/instances/${encodeURIComponent(slug)}/`, undefined, { allow404: true });
    if (flow?.pk) {
      log(`Using ${designation} flow: ${slug}`);
      return flow.pk;
    }
  }

  const flows = await list("/flows/instances/", { designation });
  const flow = flows.find((item) => item.designation === designation);
  if (!flow?.pk) {
    throw new Error(`Cannot find Authentik flow with designation=${designation}`);
  }
  log(`Using ${designation} flow: ${flow.slug}`);
  return flow.pk;
}

async function ensureGroup(name) {
  const matches = await list("/core/groups/", { name });
  const existing = matches.find((group) => group.name === name);
  const payload = {
    name,
    is_superuser: false,
    attributes: {
      "ai-stand": "managed",
    },
  };

  if (existing?.pk) {
    await api("PATCH", `/core/groups/${existing.pk}/`, payload);
    log(`Group ensured: ${name}`);
    return { ...existing, ...payload };
  }

  const created = await api("POST", "/core/groups/", payload);
  log(`Group created: ${name}`);
  return created;
}

async function findUserByUsername(username) {
  const users = await list("/core/users/", { username });
  return users.find((candidate) => candidate.username === username);
}

async function waitForBootstrapUser(timeoutMs = 10 * 60 * 1000, intervalMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = "";

  while (Date.now() < deadline) {
    try {
      const user = await findUserByUsername(config.bootstrapUsername);
      if (user?.pk) {
        log(`Bootstrap user found: ${config.bootstrapUsername}`);
        return user;
      }
    } catch (error) {
      // This function exists specifically to ride out the same kind of
      // startup race waitForApi() above tolerates (the bootstrap blueprint
      // still settling) - without this catch, a single transient error
      // here crashed the whole script instead of retrying like waitForApi
      // does for the analogous case.
      lastError = error.message;
    }
    await sleep(intervalMs);
  }

  throw new Error(`Bootstrap user ${config.bootstrapUsername} did not appear within ${Math.round(timeoutMs / 1000)}s${lastError ? `: ${lastError}` : ""}`);
}

function userHasGroups(user, groupPks) {
  const currentGroups = new Set((user.groups ?? []).map((groupPk) => String(groupPk)));
  return groupPks.every((groupPk) => currentGroups.has(String(groupPk)));
}

async function addBootstrapUserToGroups(groupPks) {
  const user = await waitForBootstrapUser();
  const currentGroups = new Set((user.groups ?? []).map((groupPk) => String(groupPk)));
  let changed = false;
  for (const groupPk of groupPks) {
    const normalizedGroupPk = String(groupPk);
    if (!currentGroups.has(normalizedGroupPk)) {
      currentGroups.add(normalizedGroupPk);
      changed = true;
    }
  }

  if (!changed) {
    // changed is false here exactly when every groupPk is already in
    // user.groups - by construction the same condition userHasGroups(user,
    // groupPks) checks, so there's nothing left to verify.
    log(`Bootstrap user ${config.bootstrapUsername} already has ai-stand groups`);
    return user;
  }

  await api("PATCH", `/core/users/${user.pk}/`, {
    groups: [...currentGroups],
  });

  const updated = await api("GET", `/core/users/${user.pk}/`);
  if (!userHasGroups(updated, groupPks)) {
    throw new Error(`Bootstrap user ${config.bootstrapUsername} group membership update did not persist`);
  }
  log(`Bootstrap user ${config.bootstrapUsername} added to ai-stand groups`);
  return updated;
}

async function getScopeMapping(scopeName) {
  const matches = await list("/propertymappings/provider/scope/", { scope_name: scopeName });
  const mapping = matches.find((item) => item.scope_name === scopeName);
  if (!mapping?.pk) {
    throw new Error(`Cannot find OAuth scope mapping: ${scopeName}`);
  }
  return mapping.pk;
}

async function ensureGroupsScopeMapping() {
  const expression = `return {
    "groups": [group.name for group in request.user.ak_groups.all()],
}`;
  const name = "ai-stand OAuth groups";
  const matches = await list("/propertymappings/provider/scope/", { scope_name: "groups" });
  const existing = matches.find((item) => item.name === name || item.managed === "ai-stand/groups");
  const payload = {
    name,
    scope_name: "groups",
    description: "ai-stand group names claim",
    expression,
    managed: "ai-stand/groups",
  };

  if (existing?.pk) {
    const updated = await api("PATCH", `/propertymappings/provider/scope/${existing.pk}/`, payload);
    log("Scope mapping ensured: groups");
    return updated.pk;
  }

  const created = await api("POST", "/propertymappings/provider/scope/", payload);
  log("Scope mapping created: groups");
  return created.pk;
}

async function getOidcSigningKey() {
  const keypairs = await list("/crypto/certificatekeypairs/");
  // The two name-based heuristics below are already proven to match on a
  // real install and are left as-is. Only the last-resort fallback is
  // hardened: `/crypto/certificatekeypairs/` can also list cert-only
  // entries with no private key (e.g. an imported CA/trust cert), which
  // Authentik rejects as a signing_key - if the self-signed cert is ever
  // removed/renamed with no other "authentik"-named match, blindly taking
  // keypairs[0] could pick one of those and fail with a confusing error
  // far from this function. private_key_available is the same field
  // Authentik's own UI uses to populate signing-key pickers.
  const preferred = keypairs.find((keypair) => keypair.name === "authentik Self-signed Certificate")
    ?? keypairs.find((keypair) => /authentik/i.test(keypair.name ?? ""))
    ?? keypairs.find((keypair) => keypair.private_key_available)
    ?? keypairs[0];

  if (!preferred?.pk) {
    throw new Error("Cannot find Authentik certificate/key pair for OIDC signing");
  }

  log(`Using OIDC signing key: ${preferred.name ?? preferred.pk}`);
  return preferred.pk;
}

async function ensureOAuthProvider(name, payload) {
  const matches = await list("/providers/oauth2/", { search: name });
  const existing = matches.find((provider) => provider.name === name);
  if (existing?.pk) {
    const updated = await api("PATCH", `/providers/oauth2/${existing.pk}/`, payload);
    log(`OIDC provider ensured: ${name}`);
    return updated;
  }

  const created = await api("POST", "/providers/oauth2/", payload);
  log(`OIDC provider created: ${name}`);
  return created;
}

async function ensureProxyProvider(name, payload) {
  const matches = await list("/providers/proxy/", { name__iexact: name });
  const existing = matches.find((provider) => provider.name === name);
  if (existing?.pk) {
    const updated = await api("PATCH", `/providers/proxy/${existing.pk}/`, payload);
    log(`Proxy provider ensured: ${name}`);
    return updated;
  }

  const created = await api("POST", "/providers/proxy/", payload);
  log(`Proxy provider created: ${name}`);
  return created;
}

async function getFlowBySlug(slug) {
  const flow = await api("GET", `/flows/instances/${encodeURIComponent(slug)}/`, undefined, { allow404: true });
  if (!flow?.pk) {
    throw new Error(`Cannot find Authentik flow with slug=${slug}`);
  }
  return flow.pk;
}

async function ensurePrompt(fieldKey, payload) {
  const matches = await list("/stages/prompt/prompts/", { field_key: fieldKey });
  const existing = matches.find((item) => item.field_key === fieldKey);
  if (existing?.pk) {
    const updated = await api("PATCH", `/stages/prompt/prompts/${existing.pk}/`, payload);
    log(`Prompt field ensured: ${fieldKey}`);
    return updated;
  }

  const created = await api("POST", "/stages/prompt/prompts/", { ...payload, field_key: fieldKey });
  log(`Prompt field created: ${fieldKey}`);
  return created;
}

async function ensurePromptStage(name, fieldPks) {
  const matches = await list("/stages/prompt/stages/", { search: name });
  const existing = matches.find((item) => item.name === name);
  const payload = { name, fields: fieldPks };
  if (existing?.pk) {
    const updated = await api("PATCH", `/stages/prompt/stages/${existing.pk}/`, payload);
    log(`Prompt stage ensured: ${name}`);
    return updated;
  }

  const created = await api("POST", "/stages/prompt/stages/", payload);
  log(`Prompt stage created: ${name}`);
  return created;
}

async function ensureUserWriteStage(name) {
  const matches = await list("/stages/user_write/", { search: name });
  const existing = matches.find((item) => item.name === name);
  // This flow edits an already-authenticated user's own profile, not
  // registration - the create_users_as_inactive/user_creation_mode-style
  // fields that matter for an enrollment flow's write stage don't apply.
  const payload = { name };
  if (existing?.pk) {
    const updated = await api("PATCH", `/stages/user_write/${existing.pk}/`, payload);
    log(`User write stage ensured: ${name}`);
    return updated;
  }

  const created = await api("POST", "/stages/user_write/", payload);
  log(`User write stage created: ${name}`);
  return created;
}

async function ensureFlowStageBinding(flowPk, stagePk, order) {
  const bindings = await list("/flows/bindings/", { target: flowPk, stage: stagePk });
  const existing = bindings.find((item) => item.target === flowPk && item.stage === stagePk);
  const payload = { target: flowPk, stage: stagePk, order, evaluate_on_plan: true, re_evaluate_policies: false };
  if (existing?.pk) {
    await api("PATCH", `/flows/bindings/${existing.pk}/`, payload);
    log(`Flow stage binding ensured at order ${order}`);
    return;
  }

  await api("POST", "/flows/bindings/", payload);
  log(`Flow stage binding created at order ${order}`);
}

// Lets each ai-users member edit their own readonly-mcp
// credentials (and, only where the installation opts in via
// reconciler.json's userOverrides.upstreamsEnabled, their own upstream
// endpoints) from the standard Authentik user-settings page (/if/user/),
// instead of a separate secret store. reconcile.py reads these same flat
// "ai_stand_mcp_*"
// attribute keys directly (see CREDENTIAL_ATTRIBUTES / UPSTREAM_OVERRIDE_
// ATTRIBUTES there); keep both lists in sync by hand. Appended at high
// binding orders (200+) onto default-user-settings-flow's *existing*
// stages, never reordering or replacing Authentik's own profile-editing
// stages already bound there.
//
// This is the one part of this file with no equivalent already proven
// elsewhere in it (every other ensureX() manages providers/applications,
// never Prompt/Stage/FlowStageBinding objects) - confirm live after
// deploying that /if/user/ actually renders this as an editable card before
// relying on it.
async function ensureMcpSelfServiceAttributes(userSettingsFlowPk) {
  const fields = [
    { key: "ai_stand_telegram_user_id", label: "Telegram user ID (numeric)", subText: "Your numeric Telegram ID, for example from @userinfobot (not your @username). It lets you talk to the OpenClaw bot; the change is applied within about ten minutes.", order: 5 },
    { key: "ai_stand_mcp_jira_pat", label: "Jira personal access token", subText: "Used only by your own jira-readonly-mcp container.", order: 10 },
    { key: "ai_stand_mcp_confluence_pat", label: "Confluence personal access token", subText: "Used only by your own confluence-readonly-mcp container.", order: 20 },
    { key: "ai_stand_mcp_imap_username", label: "IMAP username", subText: "Used only by your own imap-readonly-mcp container.", order: 30 },
    { key: "ai_stand_mcp_imap_password", label: "IMAP password", subText: "Used only by your own imap-readonly-mcp container.", order: 40 },
    { key: "ai_stand_mcp_jira_base_url", label: "Jira base URL (optional override)", subText: "Leave blank to use this installation's default. Only takes effect where the installation allows per-user upstream overrides.", order: 60 },
    { key: "ai_stand_mcp_confluence_base_url", label: "Confluence base URL (optional override)", subText: "Leave blank to use this installation's default. Only takes effect where the installation allows per-user upstream overrides.", order: 70 },
    { key: "ai_stand_mcp_imap_host", label: "IMAP host (optional override)", subText: "Leave blank to use this installation's default. Only takes effect where the installation allows per-user upstream overrides.", order: 80 },
    { key: "ai_stand_git_ssh_public_key", label: "Personal Gitea SSH public key", type: "text_area", subText: "The matching public key (one line, for example the contents of id_ed25519.pub, ssh-ed25519 only). It is registered in your Gitea account within a minute; blank removes it.", order: 85 },
    { key: "ai_stand_git_ssh_private_key", label: "Personal Gitea SSH private key", type: "text_area", subText: "For your Coder workspaces. It is not used to register the key in Gitea; never paste this key into a chat.", order: 90 },
    { key: "ai_stand_git_ssh_passphrase", label: "SSH key passphrase (optional)", type: "password", subText: "Only required for an encrypted personal SSH private key.", order: 100 },
  ];

  const fieldPks = [];
  for (const field of fields) {
    const prompt = await ensurePrompt(`attributes.${field.key}`, {
      name: field.key,
      label: field.label,
      type: field.type ?? "text",
      required: false,
      placeholder: "",
      sub_text: field.subText,
      order: field.order,
    });
    fieldPks.push(prompt.pk);
  }

  const promptStage = await ensurePromptStage("ai-stand-mcp-credentials-prompt", fieldPks);
  const writeStage = await ensureUserWriteStage("ai-stand-mcp-credentials-write");
  await ensureFlowStageBinding(userSettingsFlowPk, promptStage.pk, 200);
  await ensureFlowStageBinding(userSettingsFlowPk, writeStage.pk, 201);

  log("Self-service readonly-mcp attribute stage ensured on the user-settings flow");
}

async function getApplication(slug) {
  return api("GET", `/core/applications/${encodeURIComponent(slug)}/`, undefined, { allow404: true });
}

async function ensureApplication(slug, payload) {
  const existing = await getApplication(slug);
  if (existing?.pk) {
    const updated = await api("PATCH", `/core/applications/${encodeURIComponent(slug)}/`, payload);
    log(`Application ensured: ${slug}`);
    return updated;
  }

  const created = await api("POST", "/core/applications/", { ...payload, slug });
  log(`Application created: ${slug}`);
  return created;
}

async function ensurePolicyBinding(appPk, groupPk, order) {
  const bindings = await list("/policies/bindings/", { target: appPk });
  const existing = bindings.find((binding) => binding.group === groupPk && binding.target === appPk);
  const payload = {
    target: appPk,
    group: groupPk,
    policy: null,
    user: null,
    enabled: true,
    negate: false,
    order,
    timeout: 30,
    failure_result: false,
  };

  if (existing?.pk) {
    await api("PATCH", `/policies/bindings/${existing.pk}/`, payload);
    log(`Policy binding ensured: target=${appPk} group=${groupPk}`);
    return;
  }

  await api("POST", "/policies/bindings/", payload);
  log(`Policy binding created: target=${appPk} group=${groupPk}`);
}

async function bindApplicationGroups(app, groupsToBind) {
  let order = 0;
  for (const group of groupsToBind) {
    await ensurePolicyBinding(app.pk, group.pk, order);
    order += 10;
  }
}

async function ensureEmbeddedOutpost(proxyProviderIds) {
  const outposts = await list("/outposts/instances/");
  const embedded = outposts.find((outpost) => outpost.type === "proxy" && /embedded/i.test(outpost.name))
    ?? outposts.find((outpost) => outpost.type === "proxy");

  if (!embedded?.pk) {
    throw new Error("Cannot find Authentik embedded proxy outpost");
  }

  const outpostConfig = {
    ...(embedded.config ?? {}),
    authentik_host: config.publicUrl,
    authentik_host_browser: config.publicUrl,
    authentik_host_insecure: false,
  };

  await api("PATCH", `/outposts/instances/${embedded.pk}/`, {
    // Additive: a generic configure-authentik must not silently detach
    // providers that are already attached to the embedded outpost.
    providers: [...new Set([...(embedded.providers ?? []), ...proxyProviderIds])],
    config: outpostConfig,
  });
  log(`Embedded outpost ensured: ${embedded.name}; authentik_host=${config.publicUrl}`);
}

async function deleteApplicationIfExists(slug) {
  const existing = await getApplication(slug);
  if (!existing?.pk) {
    log(`Stale application absent: ${slug}`);
    return;
  }
  await api("DELETE", `/core/applications/${encodeURIComponent(slug)}/`);
  log(`Stale application deleted: ${slug}`);
}

async function deleteProxyProviderIfExists(name) {
  const matches = await list("/providers/proxy/", { name__iexact: name });
  const existing = matches.find((provider) => provider.name === name);
  if (!existing?.pk) {
    log(`Stale proxy provider absent: ${name}`);
    return;
  }
  await api("DELETE", `/providers/proxy/${existing.pk}/`);
  log(`Stale proxy provider deleted: ${name}`);
}

async function cleanupStaleProxyArtifacts() {
  const stale = [
    ["openwebui-proxy", "ai-stand-openwebui-proxy"],
    ["portainer-proxy", "ai-stand-portainer-proxy"],
  ];

  for (const [slug] of stale) {
    await deleteApplicationIfExists(slug);
  }
  for (const [, providerName] of stale) {
    await deleteProxyProviderIfExists(providerName);
  }

  // "portainer-oidc" was this application's slug before it was renamed to
  // the plain "portainer" ensureApplication() below now uses - an
  // application-only rename, not a proxy-provider pair, so it doesn't fit
  // the `stale` array shape above.
  await deleteApplicationIfExists("portainer-oidc");
}

async function verifyOpenWebuiDiscovery() {
  const response = await rawFetch("/application/o/openwebui/.well-known/openid-configuration");
  if (!response.ok) {
    throw new Error(`Open WebUI OIDC discovery failed with HTTP ${response.status}`);
  }
  const discovery = await response.json();
  const jwksResponse = await rawFetch(discovery.jwks_uri);
  if (!jwksResponse.ok) {
    throw new Error(`Open WebUI OIDC JWKS failed with HTTP ${jwksResponse.status}`);
  }
  const jwks = await jwksResponse.json();
  if (!Array.isArray(jwks.keys) || jwks.keys.length === 0) {
    throw new Error("Open WebUI OIDC JWKS does not contain signing keys");
  }
  log(`Open WebUI OIDC discovery is available with ${jwks.keys.length} JWKS key(s)`);
}

async function verifyPortainerDiscovery() {
  const response = await rawFetch("/application/o/portainer/.well-known/openid-configuration");
  if (!response.ok) {
    throw new Error(`Portainer OIDC discovery failed with HTTP ${response.status}`);
  }
  const discovery = await response.json();
  const jwksResponse = await rawFetch(discovery.jwks_uri);
  if (!jwksResponse.ok) {
    throw new Error(`Portainer OIDC JWKS failed with HTTP ${jwksResponse.status}`);
  }
  const jwks = await jwksResponse.json();
  if (!Array.isArray(jwks.keys) || jwks.keys.length === 0) {
    throw new Error("Portainer OIDC JWKS does not contain signing keys");
  }
  log(`Portainer OIDC discovery is available with ${jwks.keys.length} JWKS key(s)`);
}

async function verifyAgentgatewayDiscovery() {
  const response = await rawFetch("/application/o/agentgateway/.well-known/openid-configuration");
  if (!response.ok) {
    throw new Error(`agentgateway OIDC discovery failed with HTTP ${response.status}`);
  }
  const discovery = await response.json();
  const jwksResponse = await rawFetch(discovery.jwks_uri);
  if (!jwksResponse.ok) {
    throw new Error(`agentgateway OIDC JWKS failed with HTTP ${jwksResponse.status}`);
  }
  const jwks = await jwksResponse.json();
  if (!Array.isArray(jwks.keys) || jwks.keys.length === 0) {
    throw new Error("agentgateway OIDC JWKS does not contain signing keys");
  }
  log(`agentgateway OIDC discovery is available with ${jwks.keys.length} JWKS key(s)`);
}

async function verifyApplicationIcons() {
  const expectedIcons = {
    openwebui: icons.openwebui,
    portainer: icons.portainer,
    agentgateway: icons.agentgateway,
    "agentgateway-mcp": icons.agentgatewayMcp,
    openclaw: icons.openclaw,
    coder: icons.coder,
    gitea: icons.gitea,
  };

  // meta_icon is set as a normal field on the application (see
  // ensureApplication() above), same as name/meta_launch_url/etc, not
  // through a dedicated action endpoint - an earlier version of this
  // code used POST .../set_icon_url/ instead, which 404s on this
  // authentik version regardless of application (confirmed live
  // 2026-09-10, including for apps whose icon was already showing
  // correctly - it had only ever been set successfully once, long
  // before that endpoint broke, and every run since silently failed to
  // re-set it). Kept non-fatal here anyway since it's purely cosmetic
  // (the app-tile logo in the dashboard) and not worth failing the rest
  // of the SSO/proxy configuration over.
  for (const [slug, expectedIcon] of Object.entries(expectedIcons)) {
    const app = await getApplication(slug);
    if (!app?.pk) {
      log(`Skipping icon verification for missing application ${slug}`);
      continue;
    }
    if (app.meta_icon !== expectedIcon) {
      log(`Application ${slug} icon mismatch (got ${app.meta_icon ?? "<empty>"}, expected ${expectedIcon}) - non-fatal`);
    }
  }

  log("Application icons checked");
}

async function main() {
  await waitForApi();

  const flows = {
    authentication: await getFlow(["default-authentication-flow"], "authentication"),
    authorization: await getFlow(["default-provider-authorization-explicit-consent", "default-provider-authorization-implicit-consent"], "authorization"),
    invalidation: await getFlow(["default-provider-invalidation-flow"], "invalidation"),
  };

  const adminGroup = await ensureGroup(groups.admins);
  const userGroup = await ensureGroup(groups.users);
  await addBootstrapUserToGroups([adminGroup.pk, userGroup.pk]);

  const propertyMappings = [
    await getScopeMapping("openid"),
    await getScopeMapping("email"),
    await getScopeMapping("profile"),
    await ensureGroupsScopeMapping(),
  ];
  const signingKey = await getOidcSigningKey();

  const openwebuiProvider = await ensureOAuthProvider("ai-stand-openwebui-oidc", {
    name: "ai-stand-openwebui-oidc",
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: propertyMappings,
    signing_key: signingKey,
    // Fixed 2026-09-13: this provider (and portainer's below) predates the
    // grant_types gotcha documented on agentgatewayProvider below, and on THIS
    // installation already has a working grant_types from whenever it was
    // first created - PATCH-only updates mean re-running this script alone
    // was never going to add the field retroactively. That made the
    // original "already existed, only ever PATCHed" reasoning true only
    // for stands that already had these two providers; a fresh install
    // hits ensureOAuthProvider's POST branch for openwebui/portainer same
    // as any other provider, and would get the identical grant_types: []
    // silent-rejection bug with no self-heal via re-running configure-authentik.
    grant_types: ["authorization_code", "refresh_token"],
    client_type: "confidential",
    client_id: "openwebui",
    client_secret: config.openwebuiClientSecret,
    redirect_uris: [
      {
        matching_mode: "strict",
        url: `${hosts.openwebui}/oauth/oidc/callback`,
      },
    ],
    include_claims_in_id_token: true,
    // Personal MCP routes are selected solely by immutable
    // Authentik subject. Open WebUI merges existing accounts by verified
    // email, so this migration preserves user records while allowing it
    // to obtain the same subject as Agentgateway MCP.
    sub_mode: "user_uuid",
    issuer_mode: "per_provider",
  });

  const portainerProvider = await ensureOAuthProvider("ai-stand-portainer-oidc", {
    name: "ai-stand-portainer-oidc",
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: propertyMappings,
    signing_key: signingKey,
    client_type: "confidential",
    client_id: "portainer",
    client_secret: config.portainerClientSecret,
    // See openwebuiProvider above - same fix, same reasoning.
    grant_types: ["authorization_code", "refresh_token"],
    redirect_uris: [
      {
        matching_mode: "regex",
        url: `^${regexEscape(hosts.portainer)}(/.*)?$`,
      },
    ],
    include_claims_in_id_token: true,
    sub_mode: "user_email",
    issuer_mode: "per_provider",
  });

  const agentgatewayProvider = await ensureOAuthProvider("ai-stand-agentgateway-oidc", {
    name: "ai-stand-agentgateway-oidc",
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: propertyMappings,
    signing_key: signingKey,
    // A brand-new provider (POST) does NOT default grant_types to a usable
    // set - it's left as [], silently rejecting every authorization
    // request with "invalid_request: The request is otherwise malformed".
    // Confirmed live 2026-09-05 by diffing a new provider's saved API
    // representation against portainer's (which already had a working value
    // from however it was first created - see the fix on openwebuiProvider
    // above for why that reasoning doesn't generalize to a fresh install).
    grant_types: ["authorization_code", "refresh_token"],
    client_type: "confidential",
    client_id: "agentgateway",
    client_secret: config.agentgatewayClientSecret,
    redirect_uris: [
      {
        // Confirmed against agentgateway's own quickstart examples
        // (examples/traffic-oidc and traffic-unified-gateway in
        // agentgateway/agentgateway on GitHub): the OIDC policy always
        // serves its callback at this fixed, non-configurable path.
        matching_mode: "strict",
        url: `${hosts.agentgateway}/oauth/callback`,
      },
    ],
    include_claims_in_id_token: true,
    sub_mode: "user_email",
    issuer_mode: "per_provider",
  });

  // Agentgateway's MCP resource-server adapter returns this pre-registered
  // public PKCE client to MCP consumers because upstream Authentik does not
  // implement Dynamic Client Registration. Its subject is a stable user UUID
  // (not the mutable email used by UI login providers), which is the sole
  // key used to select a user's private read-only MCP targets.
  const agentgatewayMcpProvider = await ensureOAuthProvider("ai-stand-agentgateway-mcp", {
    name: "ai-stand-agentgateway-mcp",
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: propertyMappings,
    signing_key: signingKey,
    grant_types: ["authorization_code", "refresh_token"],
    client_type: "public",
    client_id: "agentgateway-mcp",
    redirect_uris: [
      {
        matching_mode: "regex",
        url: `^${regexEscape(hosts.openwebui)}/oauth/clients/mcp:[A-Za-z0-9_.-]+/callback$`,
      },
      {
        matching_mode: "strict",
        url: `${hosts.openclaw}/oauth/mcp/callback`,
      },
    ],
    include_claims_in_id_token: true,
    sub_mode: "user_uuid",
    issuer_mode: "per_provider",
  });

  // OpenClaw uses its supported trusted-proxy mode rather than a native OIDC
  // login. The Authentik outpost authorizes the browser and supplies its
  // stable hashed user identifier; Nginx keeps owning the application proxy.
  const openclawProxyProvider = await ensureProxyProvider("ai-stand-openclaw-proxy", {
    name: "ai-stand-openclaw-proxy",
    authentication_flow: flows.authentication,
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: [],
    internal_host: "",
    internal_host_ssl_validation: true,
    external_host: hosts.openclaw,
    skip_path_regex: "",
    basic_auth_enabled: false,
    basic_auth_password_attribute: "",
    basic_auth_user_attribute: "",
    mode: "forward_single",
    intercept_header_auth: false,
    cookie_domain: "",
    jwt_federation_sources: [],
    jwt_federation_providers: [],
    access_token_validity: "hours=1",
    refresh_token_validity: "days=30",
  });

  // Coder owns its browser session and receives no AI/MCP credential. Its
  // OIDC contract merely limits sign-in to the same ai-stand user groups.
  const coderProvider = await ensureOAuthProvider("ai-stand-coder-oidc", {
    name: "ai-stand-coder-oidc",
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: propertyMappings,
    signing_key: signingKey,
    grant_types: ["authorization_code", "refresh_token"],
    client_type: "confidential",
    client_id: "coder",
    client_secret: config.coderClientSecret,
    redirect_uris: [
      {
        matching_mode: "strict",
        url: `${hosts.coder}/api/v2/users/oidc/callback`,
      },
    ],
    include_claims_in_id_token: true,
    sub_mode: "user_uuid",
    issuer_mode: "per_provider",
  });

  const openwebuiApp = await ensureApplication("openwebui", {
    name: "Open WebUI",
    provider: openwebuiProvider.pk,
    backchannel_providers: [],
    meta_launch_url: hosts.openwebui,
    meta_icon: icons.openwebui,
    meta_description: "ai-stand Open WebUI OIDC application",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(openwebuiApp, [userGroup, adminGroup]);

  const portainerApp = await ensureApplication("portainer", {
    name: "Portainer",
    provider: portainerProvider.pk,
    backchannel_providers: [],
    meta_launch_url: hosts.portainer,
    meta_icon: icons.portainer,
    meta_description: "ai-stand Portainer OIDC application for native Portainer login",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(portainerApp, [adminGroup]);

  // Admin-only: the only thing a human ever reaches via OIDC on
  // agentgateway is its read-only admin/observability console (ui: in
  // config.yaml) - not a chat UI, not something every ai-users member has
  // a reason to open. ai-users' actual model access is transitive, through
  // OpenWebUI's own already-gated login (OpenWebUI then calls
  // agentgateway's LLM surface with its own service token, never a human's
  // OIDC session) - same reasoning as Portainer above.
  const agentgatewayApp = await ensureApplication("agentgateway", {
    name: "agentgateway",
    provider: agentgatewayProvider.pk,
    backchannel_providers: [],
    meta_launch_url: hosts.agentgateway,
    meta_icon: icons.agentgateway,
    meta_description: "ai-stand agentgateway OIDC application (admin console login only)",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(agentgatewayApp, [adminGroup]);

  // Authentik only publishes a per-provider discovery document after an
  // Application references that provider. This application is the OAuth
  // authorization contract for MCP clients, not an Agentgateway UI entry;
  // the actual MCP route policy remains enforced by Agentgateway.
  const agentgatewayMcpApp = await ensureApplication("agentgateway-mcp", {
    name: "Agentgateway MCP authorization",
    provider: agentgatewayMcpProvider.pk,
    backchannel_providers: [],
    meta_launch_url: hosts.agentgateway,
    meta_icon: icons.agentgatewayMcp,
    meta_description: "ai-stand OAuth authorization contract for MCP clients",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(agentgatewayMcpApp, [userGroup, adminGroup]);

  // LLM API access for people and command-line clients (OpenCode, scripts).
  // Every ai-users member mints their own token without any administrative
  // right: create an App password under Authentik user settings ("Tokens and
  // App passwords"), then exchange it at this provider's token endpoint with
  // grant_type=client_credentials (username + that App password). The signed
  // JWT is the Bearer token Agentgateway verifies on its LLM routes
  // (llm.policies.jwtAuth), and its email claim is who the usage is accounted
  // to. The token is self-contained, so deleting the App password does not
  // revoke one already issued: keep the validity short.
  const llmProvider = await ensureOAuthProvider("ai-stand-llm", {
    name: "ai-stand-llm",
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: propertyMappings,
    signing_key: signingKey,
    grant_types: ["client_credentials"],
    client_type: "public",
    client_id: "ai-stand-llm",
    redirect_uris: [],
    access_token_validity: "days=30",
    include_claims_in_id_token: true,
    sub_mode: "user_uuid",
    issuer_mode: "per_provider",
  });
  // blank://blank keeps this token endpoint out of the users' application
  // library: it is not something to open in a browser.
  const llmApp = await ensureApplication("ai-stand-llm", {
    name: "ai-stand LLM access",
    provider: llmProvider.pk,
    backchannel_providers: [],
    meta_launch_url: "blank://blank",
    meta_description: "Token endpoint for LLM API clients (App password to JWT)",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(llmApp, [userGroup, adminGroup]);

  const openclawApp = await ensureApplication("openclaw", {
    name: "OpenClaw",
    provider: openclawProxyProvider.pk,
    backchannel_providers: [],
    meta_launch_url: hosts.openclaw,
    meta_icon: icons.openclaw,
    meta_description: "ai-stand OpenClaw trusted-proxy application",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(openclawApp, [userGroup, adminGroup]);

  const coderApp = await ensureApplication("coder", {
    name: "Coder",
    provider: coderProvider.pk,
    backchannel_providers: [],
    meta_launch_url: hosts.coder,
    meta_icon: icons.coder,
    meta_description: "ai-stand Coder workspace control plane",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(coderApp, [userGroup, adminGroup]);

  if (config.giteaEnabled) {
    if (!config.giteaClientSecret) {
      throw new Error("AUTHENTIK_GITEA_CLIENT_SECRET is required when Gitea is enabled");
    }

    const giteaProvider = await ensureOAuthProvider("ai-stand-gitea-oidc", {
      name: "ai-stand-gitea-oidc",
      authorization_flow: flows.authorization,
      invalidation_flow: flows.invalidation,
      property_mappings: propertyMappings,
      signing_key: signingKey,
      grant_types: ["authorization_code", "refresh_token"],
      client_type: "confidential",
      client_id: "gitea",
      client_secret: config.giteaClientSecret,
      redirect_uris: [
        {
          matching_mode: "strict",
          url: `${hosts.gitea}/user/oauth2/authentik/callback`,
        },
      ],
      include_claims_in_id_token: true,
      // Gitea must retain the immutable subject: email and username can be
      // edited by the person, whereas `sub` drives all external identity.
      sub_mode: "user_uuid",
      issuer_mode: "per_provider",
    });

    const giteaApp = await ensureApplication("gitea", {
      name: "Gitea",
      provider: giteaProvider.pk,
      backchannel_providers: [],
      meta_launch_url: hosts.gitea,
      meta_icon: icons.gitea,
      meta_description: "ai-stand Gitea OIDC application",
      meta_publisher: "ai-stand",
      open_in_new_tab: false,
      policy_engine_mode: "any",
    });
    await bindApplicationGroups(giteaApp, [userGroup, adminGroup]);
  }

  const userSettingsFlowPk = await getFlowBySlug("default-user-settings-flow");
  await ensureMcpSelfServiceAttributes(userSettingsFlowPk);

  // The embedded outpost answers only OpenClaw forward-auth subrequests;
  // Nginx remains the sole OpenClaw application reverse proxy.
  await ensureEmbeddedOutpost([openclawProxyProvider.pk]);
  await cleanupGitlabArtifacts({ api, list, log });
  await cleanupMetamcpArtifacts({ api, list, log });
  await cleanupStaleProxyArtifacts();
  await verifyApplicationIcons();
  await verifyOpenWebuiDiscovery();
  await verifyPortainerDiscovery();
  await verifyAgentgatewayDiscovery();

  log(`Authentik ai-stand configuration complete at ${config.publicUrl}`);
}

main().catch((error) => {
  process.stderr.write(`[authentik-config] ERROR: ${error.stack ?? error.message}\n`);
  process.exit(1);
});
