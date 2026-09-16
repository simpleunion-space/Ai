#!/usr/bin/env node

import assert from "node:assert/strict";
import http from "node:http";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

async function reservePort() {
  const server = http.createServer();
  const port = await listen(server);
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function getText(port, gapMs) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      host: "127.0.0.1",
      port,
      path: "/v1/chat/completions",
      method: "POST",
      headers: { "content-type": "application/json", "x-test-gap-ms": String(gapMs) },
    }, async (response) => {
      try {
        let body = "";
        for await (const chunk of response) body += chunk;
        resolve({ statusCode: response.statusCode, body });
      } catch (error) {
        reject(error);
      }
    });
    request.once("error", reject);
    request.end(JSON.stringify({ model: "test", stream: true, messages: [{ role: "user", content: "test" }] }));
  });
}

const upstream = http.createServer((request, response) => {
  const gapMs = Number.parseInt(request.headers["x-test-gap-ms"] ?? "0", 10);
  response.writeHead(200, { "content-type": "text/event-stream" });
  response.write("data: {\"n\":1}\n\n");
  setTimeout(() => {
    response.write("data: {\"n\":2}\n\n");
    response.end("data: [DONE]\n\n");
  }, gapMs);
});

const upstreamPort = await listen(upstream);
const proxyPort = await reservePort();

const proxy = spawn(process.execPath, [join(here, "server.mjs")], {
  env: {
    ...process.env,
    LMSTUDIO_PROXY_HOST: "127.0.0.1",
    LMSTUDIO_PROXY_PORT: String(proxyPort),
    LMSTUDIO_PROXY_UPSTREAM_BASE_URL: `http://127.0.0.1:${upstreamPort}/v1`,
    LMSTUDIO_PROXY_UPSTREAM_TIMEOUT_MS: "1000",
    LMSTUDIO_PROXY_UPSTREAM_IDLE_TIMEOUT_MS: "200",
  },
  stdio: ["ignore", "pipe", "pipe"],
});

try {
  await Promise.race([new Promise((resolve, reject) => {
    let output = "";
    proxy.stdout.on("data", (chunk) => {
      output += chunk;
      if (output.includes("listening on")) resolve();
    });
    proxy.once("exit", (code) => reject(new Error(`proxy exited before start: ${code}`)));
  }), new Promise((_, reject) => setTimeout(() => reject(new Error("proxy did not start")), 3000))]);

  const healthyStream = await getText(proxyPort, 120);
  assert.equal(healthyStream.statusCode, 200);
  assert.match(healthyStream.body, /\"n\":1/);
  assert.match(healthyStream.body, /\"n\":2/);

  const idleStream = await getText(proxyPort, 350);
  assert.equal(idleStream.statusCode, 200);
  assert.match(idleStream.body, /Upstream was idle for 200ms/);
} finally {
  proxy.kill("SIGTERM");
  await once(proxy, "exit").catch(() => {});
  await new Promise((resolve) => upstream.close(resolve));
}

console.log("lmstudio-proxy stream timeout tests passed");
