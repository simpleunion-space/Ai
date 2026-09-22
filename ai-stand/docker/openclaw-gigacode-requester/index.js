/*
 * Personal GigaCode requester binding for the exact OpenClaw 2026.9.4
 * plugin contract.  It never reads a Device ID.  The only emitted fact is a
 * short-lived opaque session id, which the local ai02
 * adapter resolves through a narrow, read-only file into a verified
 * Authentik subject.
 */
import { randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import { dirname, resolve } from "node:path";

const PROVIDER_ID = "gigacode";
const MODEL_ID = "codechat";
const SESSION_TTL_MS = 25 * 60 * 60 * 1000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TELEGRAM_ID = /^[1-9][0-9]{4,19}$/;
const SESSION_ID = /^[0-9a-zA-Z_-]{8,128}$/;

function failClosed(message) {
  return { block: true, blockReason: message };
}

function safePath(value, label) {
  if (typeof value !== "string" || value.length === 0 || value.length > 512 || value.includes("\0")) {
    throw new Error(`${label} is invalid`);
  }
  return resolve(value);
}

function isGigaCodeTurn(ctx) {
  return ctx?.modelProviderId === PROVIDER_ID && ctx?.modelId === MODEL_ID;
}

async function loadTelegramSubjects(path) {
  let raw;
  try {
    raw = await fs.readFile(path, "utf8");
  } catch {
    return new Map();
  }
  if (raw.length > 64 * 1024) return new Map();
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || parsed.version !== 1 || !parsed.telegram || typeof parsed.telegram !== "object" || Array.isArray(parsed.telegram)) {
      return new Map();
    }
    const result = new Map();
    for (const [senderId, subject] of Object.entries(parsed.telegram)) {
      if (TELEGRAM_ID.test(senderId) && typeof subject === "string" && UUID.test(subject)) {
        result.set(senderId, subject.toLowerCase());
      }
    }
    return result;
  } catch {
    return new Map();
  }
}

async function resolveSubject(ctx, telegramSubjectMapPath) {
  const senderId = typeof ctx?.senderId === "string" ? ctx.senderId.trim() : "";
  // ai-stand's version-pinned gateway patch carries the immutable
  // Authentik UID into the runtime only for trusted-proxy Web UI turns.
  // Authentik's OIDC subject is this same immutable UUID.  Never accept a
  // mutable display name, username, prompt field, or client header here.
  if (UUID.test(senderId)) return senderId.toLowerCase();
  if (!TELEGRAM_ID.test(senderId)) return null;
  return (await loadTelegramSubjects(telegramSubjectMapPath)).get(senderId) ?? null;
}

async function writeSession(path, sessionId, subject) {
  let entries = {};
  try {
    const raw = await fs.readFile(path, "utf8");
    if (raw.length <= 1024 * 1024) {
      const parsed = JSON.parse(raw);
      if (parsed?.version === 1 && parsed.entries && typeof parsed.entries === "object" && !Array.isArray(parsed.entries)) {
        entries = parsed.entries;
      }
    }
  } catch {
    // The root-owned deployment creates this path.  A missing or malformed
    // prior map cannot gain authority and is safely replaced below.
  }

  const now = Date.now();
  for (const [key, value] of Object.entries(entries)) {
    if (!SESSION_ID.test(key) || !value || typeof value !== "object" || typeof value.expiresAt !== "string" || Date.parse(value.expiresAt) <= now) {
      delete entries[key];
    }
  }
  entries[sessionId] = { subject, expiresAt: new Date(now + SESSION_TTL_MS).toISOString() };
  const body = JSON.stringify({ version: 1, entries });
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    await fs.mkdir(dirname(path), { recursive: true, mode: 0o750 });
    // 0750, not the tighter 0640 this data would otherwise get: the host's
    // own /mnt/fix.sh cron reasserts 0750 on this whole tree every 5
    // minutes regardless of what this writes (see
    // ensure_openclaw_gigacode_requester_state() in apply.sh), and that
    // mode grants the identical owner/group read-write access for a plain
    // data file this process never executes either way.
    await fs.writeFile(temporary, body, { encoding: "utf8", mode: 0o750, flag: "wx" });
    await fs.rename(temporary, path);
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
  }
}

export default {
  id: "ai-stand-gigacode-requester",
  register(api) {
    // Do not resolve/validate api.config here. ensure_gigacode_requester_plugin()
    // in docker/openclaw/entrypoint.sh runs `openclaw plugins install --link
    // --force` before init.mjs (the script that actually writes this
    // plugin's config.sessionMapPath/telegramSubjectMapPath) - the same
    // ordering ensure_codex_plugin()/ensure_lancedb_plugin() already require
    // for their own packages to exist on disk before init.mjs references
    // them, on pain of Doctor auto-repair / a restart loop, so this file
    // can't just move to the other side of that line instead. A --force
    // reinstall eagerly calls register() as part of the install itself,
    // which can therefore run before the config this plugin needs has been
    // written at all - confirmed live 2026-09-23, every forced reinstall
    // failed register() with "sessionMapPath is invalid" for exactly this
    // reason, even though the config was completely valid moments later.
    // Resolve it fresh from api.config inside each hook below instead -
    // hooks only ever fire during real gateway operation, always well after
    // init.mjs has run.
    function resolvedConfig() {
      const live = api.config ?? {};
      return {
        sessionMapPath: safePath(live.sessionMapPath, "sessionMapPath"),
        telegramSubjectMapPath: safePath(live.telegramSubjectMapPath, "telegramSubjectMapPath"),
      };
    }

    api.registerProvider({
      id: PROVIDER_ID,
      label: "gigacode",
      docsPath: "/providers/gigacode",
      auth: [],
      catalog: { order: "late", run: async () => null },
      resolveTransportTurnState: (ctx) => {
        if (ctx?.modelId !== MODEL_ID) return undefined;
        const sessionId = String(ctx.sessionId ?? ctx.turnId ?? "").trim();
        return SESSION_ID.test(sessionId)
          ? { headers: { "X-AI-Stand-Gigacode-Session": sessionId } }
          : undefined;
      },
    });

    api.on("before_agent_run", async (_event, ctx) => {
      if (!isGigaCodeTurn(ctx)) return undefined;
      const sessionId = String(ctx?.sessionId ?? ctx?.runId ?? "").trim();
      if (!SESSION_ID.test(sessionId)) {
        return failClosed("GigaCode subscription identity is unavailable for this session.");
      }
      const { sessionMapPath, telegramSubjectMapPath } = resolvedConfig();
      const subject = await resolveSubject(ctx, telegramSubjectMapPath);
      if (!subject) {
        return failClosed("GigaCode subscription is not configured for this requester.");
      }
      try {
        await writeSession(sessionMapPath, sessionId, subject);
        return undefined;
      } catch {
        return failClosed("GigaCode subscription identity store is unavailable.");
      }
    });
  },
};
