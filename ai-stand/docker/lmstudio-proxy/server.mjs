#!/usr/bin/env node

import http from "node:http";
import https from "node:https";
import { once } from "node:events";

function boolEnv(name, fallback) {
  return ["1", "true", "yes", "on"].includes(env(name, fallback ? "1" : "0").toLowerCase());
}

const upstreamTimeoutMs = numberEnv("LMSTUDIO_PROXY_UPSTREAM_TIMEOUT_MS", 300000);

const config = {
  host: env("LMSTUDIO_PROXY_HOST", "0.0.0.0"),
  port: numberEnv("LMSTUDIO_PROXY_PORT", 11234),
  upstreamBaseUrl: new URL(env("LMSTUDIO_PROXY_UPSTREAM_BASE_URL", "http://lmstudio:1234/v1").replace(/\/+$/, "")),
  debug: ["1", "true", "yes", "on"].includes(env("LMSTUDIO_PROXY_DEBUG", "0").toLowerCase()),
  maxBodyBytes: numberEnv("LMSTUDIO_PROXY_MAX_BODY_BYTES", 128 * 1024 * 1024),
  maxResponseBytes: numberEnv("LMSTUDIO_PROXY_MAX_RESPONSE_BYTES", 128 * 1024 * 1024),
  // A full local-model request and a period with no bytes from it are
  // independent failure modes. Node's built-in fetch leaves Undici's own
  // 300-second bodyTimeout enabled, which silently won over our AbortSignal
  // for slow streaming completions. These explicit HTTP timers are the only
  // timeout authority for the upstream connection.
  upstreamTimeoutMs,
  upstreamIdleTimeoutMs: numberEnv("LMSTUDIO_PROXY_UPSTREAM_IDLE_TIMEOUT_MS", upstreamTimeoutMs),
  // Both default OFF: neither has empirical support from direct testing against
  // LM Studio (tools + a fresh tool-result last message consistently returns 200
  // unmodified), but are kept as an opt-in escape hatch rather than deleted outright.
  stripToolsAfterResultEnabled: boolEnv("LMSTUDIO_PROXY_STRIP_TOOLS_AFTER_RESULT_ENABLED", false),
  // Default OFF at the generic level; installations where LM Studio's 400 on
  // image-bearing tool-result content is confirmed should enable this explicitly.
  flattenToolResultContentEnabled: boolEnv("LMSTUDIO_PROXY_FLATTEN_TOOL_RESULT_CONTENT_ENABLED", false),
};

// Per RFC 7230 6.1 - Content-Length is deliberately NOT included here (it's
// an end-to-end header, not hop-by-hop), unlike an earlier version of this
// set which had it. That misclassification silently stripped a real,
// preservable Content-Length from every response relayed through
// writeHeaders() below, including fully unmodified passthrough ones (e.g.
// GET /v1/models) - forwardHeaders()/writeHeaders() each handle it
// explicitly instead, conditioned on whether the body was actually modified.
const hopByHopHeaders = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

function env(name, fallback) {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

function numberEnv(name, fallback) {
  const value = env(name, String(fallback));
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function debug(message, fields = {}) {
  if (!config.debug) return;
  process.stderr.write(`[lmstudio-proxy] ${message} ${JSON.stringify(fields)}\n`);
}

function log(message) {
  process.stdout.write(`[lmstudio-proxy] ${message}\n`);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function stripBasePath(pathname) {
  const basePath = config.upstreamBaseUrl.pathname.replace(/\/+$/, "");
  if (!basePath || basePath === "/") return pathname || "/";
  if (pathname === basePath) return "/";
  if (pathname.startsWith(`${basePath}/`)) return pathname.slice(basePath.length) || "/";
  return pathname || "/";
}

function joinPaths(basePath, path) {
  const cleanBase = basePath.replace(/\/+$/, "");
  const cleanPath = path.replace(/^\/+/, "");
  if (!cleanBase || cleanBase === "/") return `/${cleanPath}`;
  if (!cleanPath) return cleanBase;
  return `${cleanBase}/${cleanPath}`;
}

function upstreamUrlFor(req) {
  const incoming = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const logicalPath = stripBasePath(incoming.pathname);
  const upstream = new URL(config.upstreamBaseUrl);
  upstream.pathname = joinPaths(config.upstreamBaseUrl.pathname, logicalPath);
  upstream.search = incoming.search;
  return { upstream, logicalPath };
}

async function readBody(req) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > config.maxBodyBytes) {
      const error = new Error(`Request body exceeds ${config.maxBodyBytes} bytes`);
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

// Same bounded-accumulation shape as readBody, but for the upstream
// (LM Studio) response body rather than the inbound client request - an
// oversized response is the upstream misbehaving, not the client, hence
// 502 rather than 413.
//
// Only bounds the buffered, non-streaming JSON path (forwardJson below) -
// forwardSse/forwardTransparent iterate the upstream body directly with no
// byte accounting at all, so LMSTUDIO_PROXY_MAX_RESPONSE_BYTES does NOT
// bound a streamed completion's cumulative size (the largest responses in
// practice) despite what its name implies. There's no good way to bound a
// live stream without either buffering it (defeating the point of
// streaming) or abandoning the connection mid-response, so this is a known
// scope limitation, not something fixed here.
async function readUpstreamBody(stream) {
  const chunks = [];
  let total = 0;
  for await (const chunk of stream) {
    total += chunk.length;
    if (total > config.maxResponseBytes) {
      const error = new Error(`Upstream response exceeds ${config.maxResponseBytes} bytes`);
      error.statusCode = 502;
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function forwardHeaders(req, modifiedBody) {
  const headers = {};
  for (const [name, value] of Object.entries(req.headers)) {
    const key = name.toLowerCase();
    if (hopByHopHeaders.has(key) || key === "host") continue;
    // The client's original content-length only matches the body actually
    // sent upstream when it wasn't rewritten - otherwise it's stale and
    // must not be forwarded alongside a different-sized body.
    if (modifiedBody && (key === "content-type" || key === "content-length")) continue;
    headers[name] = Array.isArray(value) ? value.join(", ") : value;
  }
  headers["accept-encoding"] = "identity";
  if (modifiedBody) {
    headers["content-type"] = "application/json";
  }
  return headers;
}

function upstreamHeader(upstreamResponse, name) {
  const value = upstreamResponse.headers[name.toLowerCase()];
  if (Array.isArray(value)) return value.join(", ");
  return value ?? null;
}

function writeHeaders(res, upstreamResponse, options = {}) {
  res.statusCode = upstreamResponse.statusCode ?? 502;
  for (const [name, value] of Object.entries(upstreamResponse.headers)) {
    const key = name.toLowerCase();
    if (hopByHopHeaders.has(key)) continue;
    if (options.modifiedBody && (key === "content-length" || key === "content-encoding")) continue;
    res.setHeader(name, value);
  }
}

function removeEmptyToolCalls(value) {
  if (Array.isArray(value)) {
    return value.map((item) => removeEmptyToolCalls(item));
  }
  if (!isObject(value)) {
    return value;
  }

  const result = {};
  for (const [key, item] of Object.entries(value)) {
    if (key === "tool_calls" && Array.isArray(item) && item.length === 0) {
      continue;
    }
    result[key] = removeEmptyToolCalls(item);
  }
  return result;
}

// Collapses a role:"tool" message's array-shaped `content` (OpenAI-style
// content parts, e.g. when a client attaches an image/PDF read result) down
// to a plain string. LM Studio's /v1/chat/completions rejects role:"tool"
// messages whose content is anything but a string or text-only parts with a
// 400 ("Invalid 'messages' in payload" / "'type' field that is either 'text'
// or 'image_url'") - confirmed directly against the real backend. Only the
// text parts survive; a message with no text part at all becomes a short
// placeholder so the model still gets a coherent turn instead of a lost one.
function flattenToolResultContent(message) {
  if (!Array.isArray(message.content)) {
    return false;
  }
  const textParts = message.content
    .filter((part) => isObject(part) && part.type === "text" && typeof part.text === "string")
    .map((part) => part.text);
  const droppedCount = message.content.length - textParts.length;
  if (textParts.length === 0) {
    message.content = "[attachment omitted — this backend does not support non-text tool results]";
  } else if (droppedCount > 0) {
    // A tool result mixing text with a non-text part (e.g. an image from
    // opencode's `read` tool) used to keep only the text with no signal
    // that anything was omitted - the model had no way to know an
    // attachment existed at all. Append the same marker style used for
    // the text-less case above instead of dropping it silently.
    message.content = `${textParts.join("\n")}\n[${droppedCount} attachment(s) omitted — this backend does not support non-text tool results]`;
  } else {
    message.content = textParts.join("\n");
  }
  return true;
}

function normalizeRequest(body) {
  const changes = [];
  if (!isObject(body)) {
    return { body, changes };
  }

  const normalized = structuredClone(body);
  const messages = Array.isArray(normalized.messages) ? normalized.messages : [];
  const hasToolResult = messages.some((message) => isObject(message) && message.role === "tool");
  const lastMessage = messages[messages.length - 1];
  const isImmediateToolContinuation = isObject(lastMessage) && lastMessage.role === "tool";

  for (const message of messages) {
    if (!isObject(message)) continue;
    if (Array.isArray(message.tool_calls) && message.tool_calls.length === 0) {
      delete message.tool_calls;
      changes.push("messages.tool_calls[]");
    }
    if (config.flattenToolResultContentEnabled && message.role === "tool" && flattenToolResultContent(message)) {
      changes.push("messages.tool.content[]");
    }
  }

  const removeTopLevel = (field, reason) => {
    if (Object.prototype.hasOwnProperty.call(normalized, field)) {
      delete normalized[field];
      changes.push(`${reason}:${field}`);
    }
  };

  // Scoped to the request that immediately follows a tool call (the last
  // message IS the tool result), not "any tool result anywhere in history" -
  // the wider check used to strip `tools` from every later turn of the
  // conversation too, permanently disabling further tool use after the first
  // round. Off by default: direct testing against LM Studio found no case
  // where sending `tools` alongside a fresh tool result actually fails.
  if (config.stripToolsAfterResultEnabled && isImmediateToolContinuation) {
    removeTopLevel("tools", "tool-result");
    removeTopLevel("tool_choice", "tool-result");
    removeTopLevel("parallel_tool_calls", "tool-result");
  } else if (!hasToolResult) {
    if (normalized.tool_choice === "auto") {
      removeTopLevel("tool_choice", "auto");
    }
    removeTopLevel("parallel_tool_calls", "lmstudio");
  }

  return { body: normalized, changes };
}

function normalizeSseLine(line) {
  if (!line.startsWith("data:")) {
    return line;
  }

  const payload = line.slice(5).trimStart();
  if (payload === "" || payload === "[DONE]") {
    return line;
  }

  try {
    const parsed = JSON.parse(payload);
    return `data: ${JSON.stringify(removeEmptyToolCalls(parsed))}`;
  } catch {
    return line;
  }
}

async function write(res, data) {
  if (!res.write(data)) {
    await once(res, "drain");
  }
}

async function forwardSse(upstreamResponse, res) {
  writeHeaders(res, upstreamResponse, { modifiedBody: true });
  res.setHeader("content-type", upstreamHeader(upstreamResponse, "content-type") ?? "text/event-stream");
  res.setHeader("cache-control", upstreamHeader(upstreamResponse, "cache-control") ?? "no-cache");

  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of upstreamResponse) {
    buffer += decoder.decode(chunk, { stream: true });
    let index;
    while ((index = buffer.indexOf("\n")) !== -1) {
      const rawLine = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      const hasCarriageReturn = rawLine.endsWith("\r");
      const line = hasCarriageReturn ? rawLine.slice(0, -1) : rawLine;
      const normalized = normalizeSseLine(line);
      await write(res, `${normalized}${hasCarriageReturn ? "\r" : ""}\n`);
    }
  }

  buffer += decoder.decode();
  if (buffer.length > 0) {
    await write(res, normalizeSseLine(buffer));
  }
  res.end();
}

async function forwardJson(upstreamResponse, res) {
  const bodyBytes = await readUpstreamBody(upstreamResponse);
  const text = bodyBytes.toString("utf8");
  let body = text;
  try {
    body = JSON.stringify(removeEmptyToolCalls(JSON.parse(text)));
  } catch {
    body = text;
  }

  writeHeaders(res, upstreamResponse, { modifiedBody: true });
  res.setHeader("content-length", Buffer.byteLength(body));
  res.end(body);
}

async function forwardTransparent(upstreamResponse, res) {
  writeHeaders(res, upstreamResponse);
  for await (const chunk of upstreamResponse) {
    await write(res, chunk);
  }
  res.end();
}

function proxyError(message, code, statusCode = 502) {
  const error = new Error(message);
  error.code = code;
  error.statusCode = statusCode;
  return error;
}

// Do not use global fetch here. It delegates to Undici, whose built-in
// bodyTimeout defaults to five minutes and is not controlled by AbortSignal.
// http(s).request lets this proxy own both the absolute lifetime and the
// socket-idle timer, including for an SSE body that takes hours to finish.
function requestUpstream(upstream, options, clientRequest, clientResponse) {
  return new Promise((resolve, reject) => {
    const transport = upstream.protocol === "https:" ? https : http;
    let upstreamRequest;
    let upstreamResponse;
    let settled = false;
    let finished = false;
    let totalTimer;

    const clearTimers = () => {
      if (totalTimer) {
        clearTimeout(totalTimer);
        totalTimer = undefined;
      }
      if (upstreamRequest) upstreamRequest.setTimeout(0);
    };

    const removeClientListeners = () => {
      clientRequest.off("aborted", onClientDisconnect);
      clientResponse.off("close", onClientDisconnect);
    };

    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimers();
      removeClientListeners();
    };

    const fail = (error) => {
      if (finished) return;
      if (upstreamResponse) upstreamResponse.destroy(error);
      if (upstreamRequest) upstreamRequest.destroy(error);
      if (!settled) {
        settled = true;
        finish();
        reject(error);
      }
    };

    const onClientDisconnect = () => {
      // `close` is also emitted after a normal res.end(); only treat it as a
      // cancellation while the upstream is still active.
      if (finished || clientResponse.writableEnded) return;
      fail(proxyError("Client disconnected before the upstream response completed", "CLIENT_DISCONNECTED"));
    };

    const onIdleTimeout = () => {
      fail(proxyError(
        `Upstream was idle for ${config.upstreamIdleTimeoutMs}ms`,
        "UPSTREAM_IDLE_TIMEOUT",
        504,
      ));
    };

    try {
      upstreamRequest = transport.request(upstream, {
        method: options.method,
        headers: options.headers,
      }, (response) => {
        upstreamResponse = response;
        // Socket inactivity is reset by incoming headers/body bytes. Unlike
        // Undici's implicit bodyTimeout, it is explicitly configurable here.
        upstreamRequest.setTimeout(config.upstreamIdleTimeoutMs, onIdleTimeout);
        response.once("end", finish);
        response.once("error", finish);
        response.once("close", () => {
          if (response.complete) finish();
        });
        settled = true;
        resolve(response);
      });
    } catch (error) {
      reject(error);
      return;
    }

    upstreamRequest.once("error", (error) => {
      if (!settled) {
        finish();
        reject(error);
      }
    });
    upstreamRequest.setTimeout(config.upstreamIdleTimeoutMs, onIdleTimeout);
    totalTimer = setTimeout(() => {
      fail(proxyError(
        `Upstream exceeded the total timeout of ${config.upstreamTimeoutMs}ms`,
        "UPSTREAM_TOTAL_TIMEOUT",
        504,
      ));
    }, config.upstreamTimeoutMs);

    clientRequest.once("aborted", onClientDisconnect);
    clientResponse.once("close", onClientDisconnect);
    upstreamRequest.end(options.body);
  });
}

function chatRequestSummary(body, changes) {
  const messages = Array.isArray(body?.messages) ? body.messages : [];
  return {
    stream: body?.stream === true,
    hasTools: Array.isArray(body?.tools),
    toolChoice: body?.tool_choice ?? null,
    hasParallelToolCalls: Object.prototype.hasOwnProperty.call(body ?? {}, "parallel_tool_calls"),
    messageRoles: messages.map((message) => isObject(message) ? message.role : typeof message),
    changes,
  };
}

async function handleRequest(req, res) {
  if (req.method === "GET" && (req.url === "/healthz" || req.url === "/readyz")) {
    res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    res.end("ok\n");
    return;
  }

  const { upstream, logicalPath } = upstreamUrlFor(req);
  const isChatCompletions = logicalPath === "/chat/completions";
  const hasRequestBody = !["GET", "HEAD"].includes(req.method ?? "GET");
  const rawBody = hasRequestBody ? await readBody(req) : undefined;
  let requestBody = rawBody;
  let modifiedBody = false;
  let streamRequested = false;

  if (isChatCompletions && req.method === "POST" && rawBody && rawBody.length > 0) {
    try {
      const parsed = JSON.parse(rawBody.toString("utf8"));
      const before = structuredClone(parsed);
      const normalized = normalizeRequest(parsed);
      requestBody = Buffer.from(JSON.stringify(normalized.body), "utf8");
      modifiedBody = true;
      streamRequested = normalized.body?.stream === true;
      debug("normalized chat request", {
        path: logicalPath,
        before: chatRequestSummary(before, []),
        after: chatRequestSummary(normalized.body, normalized.changes),
      });
    } catch (error) {
      debug("chat request was not valid JSON", { path: logicalPath, error: error.message });
    }
  }

  const upstreamResponse = await requestUpstream(upstream, {
      method: req.method,
      headers: forwardHeaders(req, modifiedBody),
      body: hasRequestBody ? requestBody : undefined,
    }, req, res);

  debug("upstream response", {
    path: logicalPath,
    status: upstreamResponse.statusCode,
    contentType: upstreamHeader(upstreamResponse, "content-type") ?? "",
  });

  const contentType = upstreamHeader(upstreamResponse, "content-type") ?? "";
  if (isChatCompletions && streamRequested && contentType.includes("text/event-stream")) {
    await forwardSse(upstreamResponse, res);
    return;
  }
  if (isChatCompletions && contentType.includes("application/json")) {
    await forwardJson(upstreamResponse, res);
    return;
  }

  await forwardTransparent(upstreamResponse, res);
}

const server = http.createServer((req, res) => {
  handleRequest(req, res).catch((error) => {
    if (error.code === "CLIENT_DISCONNECTED") {
      return;
    }
    const status = error.statusCode ?? 502;
    process.stderr.write(`[lmstudio-proxy] ERROR ${error.stack ?? error.message}\n`);
    const errorPayload = JSON.stringify({ error: { message: error.message, type: "lmstudio_proxy_error" } });
    if (!res.headersSent) {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(errorPayload);
      return;
    }
    // A mid-stream upstream failure (timeout past LMSTUDIO_PROXY_UPSTREAM_TIMEOUT_MS,
    // LM Studio crashing, etc.) lands here after forwardSse() has already
    // flushed at least one chunk - headers are sent and can't be rewritten,
    // but blindly appending bare JSON corrupted the in-progress SSE stream
    // instead of surfacing a readable error (plausibly the actual cause of
    // the "proxy error: error from user's Body stream" incident documented
    // on compose.yaml's lmstudio-proxy service - raising the timeout there
    // only made this rarer, not fixed). Frame it as a proper SSE event when
    // the response was actually SSE; otherwise just end the (non-SSE,
    // already-streaming) response cleanly rather than appending anything.
    const contentType = String(res.getHeader("content-type") ?? "");
    if (contentType.includes("text/event-stream")) {
      res.end(`data: ${errorPayload}\n\n`);
    } else {
      res.end();
    }
  });
});

export { server };

server.listen(config.port, config.host, () => {
  log(`listening on ${config.host}:${config.port}; upstream=${config.upstreamBaseUrl}`);
});
