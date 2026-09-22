/*
 * A deliberately narrow, version-pinned OpenClaw patch.
 *
 * OpenClaw 2026.9.4 authenticates a trusted proxy with its immutable user
 * header, but initializes the UI profile display name from that opaque ID.
 * The m01 Nginx proxy separately receives an Authentik username from its
 * forward-auth subrequest and supplies it in a header that it overwrites on
 * every request.  Upstream has no display-only trusted-proxy field yet.
 *
 * This patch changes only the profile label after trusted-proxy
 * authentication. It cannot change `authResult.user`, authorization,
 * session keys, roles, or any incoming identity header.  A byte-for-byte
 * hash and exact source snippets make an upstream package change fail the
 * image build rather than silently applying a fuzzy patch.
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2] ?? "/usr/local/lib/node_modules/openclaw";
const expectedVersion = "2026.9.4";
const expectedSha256 = "d501d97f832dbbf04d399d64f073df50d5f475aebf5ee30830b169bd337c68cd";
const packageJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
if (packageJson.version !== expectedVersion) {
  throw new Error(`OpenClaw display-name patch requires ${expectedVersion}, found ${packageJson.version}`);
}

const dist = join(root, "dist");
const candidates = ["http-auth-utils-DMgIfzV0.mjs"];
if (candidates.length !== 1) throw new Error("expected exactly one OpenClaw HTTP auth module");
const path = join(dist, candidates[0]);
const original = readFileSync(path, "utf8");
const originalHash = createHash("sha256").update(original).digest("hex");
if (originalHash !== expectedSha256) {
  throw new Error(`OpenClaw HTTP auth module hash mismatch: ${originalHash}`);
}

const importBefore = 'import { a as getUserProfileListItem, i as ensureProfileForTailscaleIdentity, n as ensureGatewayOwnerProfile, p as getUserProfileDisplay, r as ensureProfileForEmail } from "./user-profiles-CLfq6AhS.mjs";';
const importAfter = 'import { a as getUserProfileListItem, i as ensureProfileForTailscaleIdentity, n as ensureGatewayOwnerProfile, p as getUserProfileDisplay, r as ensureProfileForEmail, u as setDisplayName } from "./user-profiles-CLfq6AhS.mjs";';
const bodyBefore = 'const profile = syncGitHubIdentity ? await syncGitHubIdentity() : params.authResult.tailscaleIdentity ? ensureProfileForTailscaleIdentity(params.authResult.tailscaleIdentity) : ensureProfileForEmail(authenticatedUserId);\n\t\treturn resolveHttpProfile("profileId" in profile ? profile.profileId : profile.id, profile.updatedAt, params.cfg);';
const bodyAfter = 'const profile = syncGitHubIdentity ? await syncGitHubIdentity() : params.authResult.tailscaleIdentity ? ensureProfileForTailscaleIdentity(params.authResult.tailscaleIdentity) : ensureProfileForEmail(authenticatedUserId);\n\t\tconst profileId = "profileId" in profile ? profile.profileId : profile.id;\n\t\tconst displayName = params.authResult.method === "trusted-proxy" ? normalizeOptionalString(getHeader(params.req, "x-ai-stand-display-name")) : void 0;\n\t\tif (displayName && /^[A-Za-z0-9._@-]{1,128}$/.test(displayName) && profile.displayName !== displayName) setDisplayName(profileId, displayName);\n\t\treturn resolveHttpProfile(profileId, profile.updatedAt, params.cfg);';

function replaceExactly(source, before, after, label) {
  const first = source.indexOf(before);
  if (first < 0 || source.indexOf(before, first + before.length) >= 0) {
    throw new Error(`OpenClaw display-name patch could not find one ${label} snippet`);
  }
  return source.slice(0, first) + after + source.slice(first + before.length);
}

let patched = replaceExactly(original, importBefore, importAfter, "import");
patched = replaceExactly(patched, bodyBefore, bodyAfter, "profile resolution");
const temporary = `${path}.ai-stand-display-name.tmp`;
writeFileSync(temporary, patched, { encoding: "utf8", mode: 0o644 });
renameSync(temporary, path);
console.log("Applied OpenClaw 2026.9.4 trusted-proxy display-name patch");
