/*
 * A deliberately narrow, version-pinned OpenClaw patch.
 *
 * In 2026.9.4 a browser request authenticated by trusted proxy reaches the
 * gateway with `client.authenticatedUserId`, but that value is discarded when
 * the model turn's `runContext` is created. Channel turns already retain
 * their sender ID. The ai-stand personal GigaCode plugin needs this one
 * immutable identifier to choose the user's own subscription; it must never
 * infer identity from a prompt, display name, or a client-supplied header.
 *
 * The exact package hash and one-occurrence replacement mean a later
 * OpenClaw release cannot silently broaden this behavior. Authentication,
 * authorization, sessions, and the trusted-proxy key itself remain entirely
 * upstream-owned: this only preserves an already authenticated identifier
 * for the provider hook.
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2] ?? "/usr/local/lib/node_modules/openclaw";
const expectedVersion = "2026.9.4";
const expectedSha256 = "a31ff458309426a6be4ba9d8a5052cbeef3e18feb0e6064fde5908e682e444cf";
const packageJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
if (packageJson.version !== expectedVersion) {
  throw new Error(`OpenClaw requester-identity patch requires ${expectedVersion}, found ${packageJson.version}`);
}

const path = join(root, "dist", "worker", "worker.mjs");
const original = readFileSync(path, "utf8");
const originalHash = createHash("sha256").update(original).digest("hex");
if (originalHash !== expectedSha256) {
  throw new Error(`OpenClaw worker hash mismatch: ${originalHash}`);
}

const before = "senderId:Hr?.requesterSenderId,groupId:Ot.groupId,groupChannel:Ot.groupChannel,groupSpace:Ot.groupSpace";
const after = "senderId:Hr?.requesterSenderId??Ot.client?.authenticatedUserId??void 0,groupId:Ot.groupId,groupChannel:Ot.groupChannel,groupSpace:Ot.groupSpace";
const first = original.indexOf(before);
if (first < 0 || original.indexOf(before, first + before.length) >= 0) {
  throw new Error("OpenClaw requester-identity patch could not find one runContext sender snippet");
}

const patched = original.slice(0, first) + after + original.slice(first + before.length);
const temporary = `${path}.ai-stand-requester-identity.tmp`;
writeFileSync(temporary, patched, { encoding: "utf8", mode: 0o644 });
renameSync(temporary, path);
console.log("Applied OpenClaw 2026.9.4 trusted-proxy requester-identity patch");
