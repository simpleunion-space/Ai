#!/usr/bin/env node

const config = {
  baseUrl: env("AUTHENTIK_BASE_URL", "http://authentik:9000").replace(/\/+$/, ""),
  publicUrl: env("AUTHENTIK_PUBLIC_URL", "https://authentik.local").replace(/\/+$/, ""),
  token: requiredEnv("AUTHENTIK_API_TOKEN"),
  bootstrapUsername: env("AUTHENTIK_BOOTSTRAP_USERNAME", "akadmin"),
  openwebuiClientSecret: requiredEnv("AUTHENTIK_OPENWEBUI_CLIENT_SECRET"),
  portainerClientSecret: requiredEnv("AUTHENTIK_PORTAINER_CLIENT_SECRET"),
  metamcpClientSecret: requiredEnv("AUTHENTIK_METAMCP_CLIENT_SECRET"),
  agentgatewayClientSecret: requiredEnv("AUTHENTIK_AGENTGATEWAY_CLIENT_SECRET"),
};

const groups = {
  admins: "ai-admins",
  users: "ai-users",
};

const hosts = {
  openwebui: env("AUTHENTIK_OPENWEBUI_URL", "https://openwebui.local").replace(/\/+$/, ""),
  portainer: env("AUTHENTIK_PORTAINER_URL", "https://portainer.local").replace(/\/+$/, ""),
  metamcp: env("AUTHENTIK_METAMCP_URL", "https://metamcp.local").replace(/\/+$/, ""),
  agentgateway: env("AUTHENTIK_AGENTGATEWAY_URL", "https://agentgateway.local").replace(/\/+$/, ""),
};

// Vendored into docker/authentik/icons/ and served by nginx at
// config.publicUrl + /app-icons/ (see install_authentik_icons() in
// apply.sh) rather than referencing each project's own site or another
// ai-stand component's live instance directly - confirmed live 2026-09-11
// that a couple of those "obvious" sources are actively wrong
// (agentgateway's own /favicon.ico returns HTTP 200 with Content-Type:
// image/vnd.microsoft.icon but the real bytes are SVG; GitHub's
// openwebui/metamcp "vector" logos are real image/svg+xml but each just
// wraps a raster/diagram, not a usable icon) - vendoring means every icon
// here was individually downloaded and verified byte-for-byte (`file`, not
// just Content-Type) once, and Authentik's own app-list tiles no longer
// depend on any of those sites - or on each other's live instance - staying
// reachable.
const icons = {
  openwebui: `${config.publicUrl}/app-icons/openwebui.png`,
  portainer: `${config.publicUrl}/app-icons/portainer.svg`,
  metamcp: `${config.publicUrl}/app-icons/metamcp.ico`,
  agentgateway: `${config.publicUrl}/app-icons/agentgateway.svg`,
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
    providers: proxyProviderIds,
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
    // OpenClaw is protected by its own gateway token, not by an Authentik
    // forward-auth layer. The proxy was never bound by Nginx, so delete it
    // during the next configuration run rather than leaving a misleading
    // dormant application/provider pair behind.
    ["openclaw-proxy", "ai-stand-openclaw-proxy"],
    // lmstudio has no viable external-auth story upstream (LM Studio has no
    // "Require Authentication" support at all - lmstudio-ai/lmstudio-bug-
    // tracker#1674), so this Authentik Application/Provider pair is
    // intentionally never (re)created here - both the original
    // direct-lmstudio application and the newer lmstudio-compat-proxy (for
    // the Node normalizing proxy) are unused and were confusingly
    // similarly named; removed rather than kept around inert or renamed.
    ["lmstudio-proxy", "ai-stand-lmstudio-proxy"],
    ["lmstudio-compat-proxy", "ai-stand-lmstudio-compat-proxy"],
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

async function verifyMetamcpDiscovery() {
  const response = await rawFetch("/application/o/metamcp/.well-known/openid-configuration");
  if (!response.ok) {
    throw new Error(`MetaMCP OIDC discovery failed with HTTP ${response.status}`);
  }
  const discovery = await response.json();
  const jwksResponse = await rawFetch(discovery.jwks_uri);
  if (!jwksResponse.ok) {
    throw new Error(`MetaMCP OIDC JWKS failed with HTTP ${jwksResponse.status}`);
  }
  const jwks = await jwksResponse.json();
  if (!Array.isArray(jwks.keys) || jwks.keys.length === 0) {
    throw new Error("MetaMCP OIDC JWKS does not contain signing keys");
  }
  log(`MetaMCP OIDC discovery is available with ${jwks.keys.length} JWKS key(s)`);
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
    metamcp: icons.metamcp,
    agentgateway: icons.agentgateway,
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
    // grant_types gotcha documented on metamcpProvider below, and on THIS
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
    sub_mode: "user_email",
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

  const metamcpProvider = await ensureOAuthProvider("ai-stand-metamcp-oidc", {
    name: "ai-stand-metamcp-oidc",
    authorization_flow: flows.authorization,
    invalidation_flow: flows.invalidation,
    property_mappings: propertyMappings,
    signing_key: signingKey,
    // A brand-new provider (POST) does NOT default grant_types to a usable
    // set - it's left as [], silently rejecting every authorization
    // request with "invalid_request: The request is otherwise malformed".
    // Confirmed live 2026-09-05 by diffing this provider's saved API
    // representation against portainer's (which, unlike this one, already
    // had a working value from however it was first created - see the
    // fix on openwebuiProvider above for why that reasoning doesn't
    // generalize to a fresh install).
    grant_types: ["authorization_code", "refresh_token"],
    client_type: "confidential",
    client_id: "metamcp",
    client_secret: config.metamcpClientSecret,
    redirect_uris: [
      {
        // Better Auth's generic-oauth plugin builds this from
        // OIDC_PROVIDER_ID (compose.yaml, must be "oidc" - see the
        // comment there for why).
        matching_mode: "strict",
        url: `${hosts.metamcp}/api/auth/oauth2/callback/oidc`,
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
    // Same brand-new-provider gotcha as metamcpProvider above.
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

  // MCP client endpoints (OpenClaw/opencode) authenticate with their own
  // per-endpoint bearer API keys, not SSO - this application only gates the
  // human admin-UI login. Admin-only like Portainer: this is a
  // single-admin tool, not something every ai-users member should get an
  // account on just by being able to log in.
  const metamcpApp = await ensureApplication("metamcp", {
    name: "MetaMCP",
    provider: metamcpProvider.pk,
    backchannel_providers: [],
    meta_launch_url: hosts.metamcp,
    meta_icon: icons.metamcp,
    meta_description: "ai-stand MetaMCP OIDC application (admin UI login only)",
    meta_publisher: "ai-stand",
    open_in_new_tab: false,
    policy_engine_mode: "any",
  });
  await bindApplicationGroups(metamcpApp, [adminGroup]);

  // Admin-only: the only thing a human ever reaches via OIDC on
  // agentgateway is its read-only admin/observability console (ui: in
  // config.yaml) - not a chat UI, not something every ai-users member has
  // a reason to open. ai-users' actual model access is transitive, through
  // OpenWebUI's own already-gated login (OpenWebUI then calls
  // agentgateway's LLM surface with its own service token, never a human's
  // OIDC session) - same reasoning as Portainer/MetaMCP above.
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

  // No service uses Authentik forward-auth. Clear the embedded outpost
  // before deleting legacy providers so an upgrade can remove them safely.
  await ensureEmbeddedOutpost([]);
  await cleanupStaleProxyArtifacts();
  await verifyApplicationIcons();
  await verifyOpenWebuiDiscovery();
  await verifyPortainerDiscovery();
  await verifyMetamcpDiscovery();
  await verifyAgentgatewayDiscovery();

  log(`Authentik ai-stand configuration complete at ${config.publicUrl}`);
}

main().catch((error) => {
  process.stderr.write(`[authentik-config] ERROR: ${error.stack ?? error.message}\n`);
  process.exit(1);
});
