import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import plugin from "../index.js";

const SUBJECT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

function register(config) {
  const events = new Map();
  let provider;
  plugin.register({
    config,
    on(name, handler) { events.set(name, handler); },
    registerProvider(value) { provider = value; },
  });
  return { before: events.get("before_agent_run"), provider };
}

test("binds a trusted-proxy UUID to a short-lived local session", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ai-stand-gigacode-requester-"));
  try {
    const sessionPath = join(dir, "sessions.json");
    const telegramPath = join(dir, "telegram.json");
    await writeFile(telegramPath, JSON.stringify({ version: 1, telegram: {} }));
    const { before, provider } = register({ sessionMapPath: sessionPath, telegramSubjectMapPath: telegramPath });
    const result = await before({}, {
      modelProviderId: "gigacode",
      modelId: "codechat",
      senderId: SUBJECT,
      sessionId: "web-session-00001",
    });
    assert.equal(result, undefined);
    const map = JSON.parse(await readFile(sessionPath, "utf8"));
    assert.equal(map.entries["web-session-00001"].subject, SUBJECT);
    assert.deepEqual(provider.resolveTransportTurnState({ modelId: "codechat", sessionId: "web-session-00001" }), {
      headers: { "X-AI-Stand-Gigacode-Session": "web-session-00001" },
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("permits only root-mapped Telegram IDs", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ai-stand-gigacode-requester-"));
  try {
    const sessionPath = join(dir, "sessions.json");
    const telegramPath = join(dir, "telegram.json");
    await writeFile(telegramPath, JSON.stringify({ version: 1, telegram: { "6990181709": SUBJECT } }));
    const { before } = register({ sessionMapPath: sessionPath, telegramSubjectMapPath: telegramPath });
    assert.equal(await before({}, {
      modelProviderId: "gigacode", modelId: "codechat", senderId: "6990181709", sessionId: "telegram-session-00001",
    }), undefined);
    const rejected = await before({}, {
      modelProviderId: "gigacode", modelId: "codechat", senderId: "7777777777", sessionId: "telegram-session-00002",
    });
    assert.equal(rejected?.block, true);
    const map = JSON.parse(await readFile(sessionPath, "utf8"));
    assert.equal(map.entries["telegram-session-00001"].subject, SUBJECT);
    assert.equal(map.entries["telegram-session-00002"], undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
