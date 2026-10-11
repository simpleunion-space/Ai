#!/usr/bin/env node
// Runs as 10000:20000 in a short-lived node-pinned job. No memory text reaches stdout.
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const MARKER = "AI_STAND_MODEL_MIGRATION_RECEIPT=";
const sha = (value) => crypto.createHash("sha256").update(value).digest("hex");
let phase = "arguments";

function args(argv) {
  if (argv.shift() !== "migrate") throw new Error("unsupported migration mode");
  const result = {};
  while (argv.length) {
    const key = argv.shift();
    if (!key.startsWith("--") || !argv.length || result[key] !== undefined) throw new Error("invalid migration arguments");
    result[key] = argv.shift();
  }
  for (const key of ["--packages", "--plugin-version", "--memory-root", "--source-path", "--target-path", "--generation",
    "--backend-url", "--token-file", "--model", "--dimensions"]) {
    if (!result[key]) throw new Error("missing migration argument");
  }
  if (!/^[a-f0-9]{64}$/.test(result["--generation"])) throw new Error("invalid migration generation");
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(result["--plugin-version"])) throw new Error("invalid pinned plugin version");
  if (result["--model"] !== "qwen3-embedding-8b" || result["--dimensions"] !== "4096") throw new Error("unsupported migration target");
  for (const key of ["--source-path", "--target-path"]) {
    const value = result[key];
    if (!/^[a-zA-Z0-9_.-]+$/.test(value) || value === "." || value === "..") throw new Error("unsafe memory path");
  }
  if (result["--target-path"] !== "lancedb-" + result["--generation"].slice(0, 16)) throw new Error("target does not match generation");
  if (result["--source-path"] === result["--target-path"]) throw new Error("source and target must differ");
  const backend = new URL(result["--backend-url"]);
  if (backend.protocol !== "http:" || backend.hostname !== "agentgateway" || backend.port !== "4000" || backend.pathname !== "/v1") {
    throw new Error("invalid internal embedding endpoint");
  }
  return result;
}

async function regularDirectory(value, create = false) {
  let info;
  try { info = await fs.lstat(value); }
  catch (error) {
    if (error.code !== "ENOENT" || !create) throw error;
    await fs.mkdir(value, { mode: 0o700 });
    info = await fs.lstat(value);
  }
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("unsafe migration directory");
}

async function atomicJson(file, value) {
  const existing = await fs.lstat(file).catch((error) => error.code === "ENOENT" ? null : Promise.reject(error));
  if (existing?.isSymbolicLink()) throw new Error("unsafe migration receipt");
  const temporary = file + "." + crypto.randomUUID() + ".tmp";
  const handle = await fs.open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(JSON.stringify(value) + "\n");
    await handle.sync();
  } finally { await handle.close(); }
  await fs.rename(temporary, file);
}

async function packageRequire(packages, version) {
  await regularDirectory(packages);
  const projects = path.join(packages, "projects");
  await regularDirectory(projects);
  const candidates = [];
  for (const name of await fs.readdir(projects)) {
    const manifest = path.join(projects, name, "node_modules/@openclaw/memory-lancedb/package.json");
    try {
      const pkg = JSON.parse(await fs.readFile(manifest, "utf8"));
      if (pkg.name === "@openclaw/memory-lancedb" && pkg.version === version) candidates.push(manifest);
    } catch (error) { if (error.code !== "ENOENT") throw error; }
  }
  if (candidates.length !== 1) throw new Error("pinned LanceDB package is absent or ambiguous");
  return { require: createRequire(candidates[0]), root: path.dirname(candidates[0]) };
}

function metadataOf(rows, fields) {
  return rows.map((row) => Object.fromEntries(fields.filter((field) => field !== "vector").map((field) => [field, row[field]])))
    .sort((a, b) => String(a.id).localeCompare(String(b.id)));
}

async function main() {
  const options = args(process.argv.slice(2));
  const root = options["--memory-root"];
  if (root !== "/memory" || options["--packages"] !== "/packages") throw new Error("unexpected job mounts");
  await regularDirectory(root);
  phase = "sdk";
  const { require, root: packageRoot } = await packageRequire(options["--packages"], options["--plugin-version"]);
  // The pinned plugin bundles its JavaScript SDK. Use its matching loader,
  // rather than assuming an unbundled development dependency is installed.
  const { loadLanceDbModule } = await import(pathToFileURL(path.join(packageRoot, "dist/lancedb-runtime.js")));
  const lancedb = await loadLanceDbModule();
  const arrow = require("apache-arrow");
  phase = "private-storage";
  const generation = options["--generation"];
  const privateRoot = path.join(root, ".ai-stand-migration");
  await regularDirectory(privateRoot, true);
  await fs.chmod(privateRoot, 0o700);
  const privateGeneration = path.join(privateRoot, generation);
  await regularDirectory(privateGeneration, true);
  await fs.chmod(privateGeneration, 0o700);
  const sourcePath = path.join(root, options["--source-path"]);
  const targetPath = path.join(root, options["--target-path"]);
  const receiptFile = path.join(privateGeneration, "receipt.json");
  const backupFile = path.join(privateGeneration, "rows.backup.json");
  const completed = await fs.readFile(receiptFile, "utf8").then(JSON.parse).catch((error) => error.code === "ENOENT" ? null : Promise.reject(error));
  if (completed) {
    phase = "receipt-validation";
    if (completed.state !== "complete" || completed.generation !== generation || completed.dimensions !== 4096 ||
        completed.source !== options["--source-path"] || completed.target !== options["--target-path"]) throw new Error("incompatible migration receipt");
    const db = await lancedb.connect(targetPath);
    const table = await db.openTable("memories");
    const schema = await table.schema();
    const field = schema.fields.find((value) => value.name === "vector");
    if (field?.type.listSize !== 4096 || await table.countRows() !== completed.rows) throw new Error("completed index no longer matches receipt");
    table.close(); db.close();
    process.stdout.write(MARKER + JSON.stringify(completed) + "\n");
    return;
  }

  let rows = [];
  let schema;
  phase = "read-source";
  const sourceExists = await fs.lstat(sourcePath).catch((error) => error.code === "ENOENT" ? null : Promise.reject(error));
  if (sourceExists) {
    await regularDirectory(sourcePath);
    const db = await lancedb.connect(sourcePath);
    const tables = await db.tableNames();
    if (tables.some((name) => name !== "memories")) throw new Error("unexpected source tables require explicit migration");
    if (tables.includes("memories")) {
      const table = await db.openTable("memories");
      schema = await table.schema();
      const count = await table.countRows();
      if (count > 100000) throw new Error("memory migration exceeds bounded inventory");
      const names = schema.fields.map((field) => field.name);
      for (const required of ["id", "text", "vector", "importance", "category", "createdAt", "agentId"]) {
        if (!names.includes(required)) throw new Error("unsupported legacy memory schema");
      }
      const queried = count ? await table.query().limit(count).toArray() : [];
      rows = queried.map((row) => Object.fromEntries(names.map((name) => [name, name === "vector" ? Array.from(row[name]) : row[name]])));
      if (rows.length !== count || new Set(rows.map((row) => row.id)).size !== count) throw new Error("source count/identity mismatch");
      table.close();
    }
    db.close();
  }
  if (!schema) {
    schema = new arrow.Schema([
      new arrow.Field("id", new arrow.Utf8(), true), new arrow.Field("text", new arrow.Utf8(), true),
      new arrow.Field("vector", new arrow.FixedSizeList(4096, new arrow.Field("item", new arrow.Float32(), true)), true),
      new arrow.Field("importance", new arrow.Float64(), true), new arrow.Field("category", new arrow.Utf8(), true),
      new arrow.Field("createdAt", new arrow.Float64(), true), new arrow.Field("agentId", new arrow.Utf8(), true),
    ]);
  }
  const fields = schema.fields.map((field) => field.name);
  const originalMetadata = metadataOf(rows, fields);
  const metadataSha = sha(JSON.stringify(originalMetadata));
  phase = "backup";
  const existingBackup = await fs.readFile(backupFile, "utf8").then(JSON.parse).catch((error) => error.code === "ENOENT" ? null : Promise.reject(error));
  if (existingBackup) {
    if (existingBackup.metadataSha256 !== metadataSha || existingBackup.generation !== generation) throw new Error("source changed during interrupted migration");
  } else {
    await atomicJson(backupFile, { version: 1, generation, source: options["--source-path"], metadataSha256: metadataSha, rows });
  }
  const token = (await fs.readFile(options["--token-file"], "utf8")).trim();
  if (!token) throw new Error("missing internal embedding credential");
  phase = "embedding";
  for (const row of rows) {
    if (typeof row.text !== "string" || row.text.length > 1000000) throw new Error("invalid memory text");
    const response = await fetch(options["--backend-url"] + "/embeddings", {
      method: "POST", headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify({ model: options["--model"], input: row.text }), signal: AbortSignal.timeout(3600000),
    });
    if (!response.ok) throw new Error("embedding request failed");
    const value = await response.json();
    const vector = value.data?.[0]?.embedding;
    if (!Array.isArray(vector) || vector.length !== 4096 || vector.some((item) => typeof item !== "number" || !Number.isFinite(item))) {
      throw new Error("invalid embedding dimensions/value");
    }
    const norm = Math.hypot(...vector);
    if (!Number.isFinite(norm) || norm === 0) throw new Error("invalid embedding norm");
    row.vector = vector.map((item) => item / norm);
  }

  if (await fs.lstat(targetPath).catch((error) => error.code === "ENOENT" ? null : Promise.reject(error))) {
    throw new Error("target exists without a completed receipt; preserved for inspection");
  }
  const staging = path.join(privateGeneration, "index-" + crypto.randomUUID());
  phase = "new-index";
  const targetSchema = new arrow.Schema(schema.fields.map((field) => field.name === "vector"
    ? new arrow.Field("vector", new arrow.FixedSizeList(4096, new arrow.Field("item", new arrow.Float32(), true)), field.nullable)
    : field), schema.metadata);
  const db = await lancedb.connect(staging);
  const table = rows.length
    ? await db.createTable("memories", rows, { schema: targetSchema })
    : await db.createEmptyTable("memories", targetSchema);
  const saved = rows.length ? await table.query().limit(rows.length).toArray() : [];
  if (await table.countRows() !== rows.length || sha(JSON.stringify(metadataOf(saved, fields))) !== metadataSha) {
    throw new Error("new index failed metadata/count validation");
  }
  table.close(); db.close();
  phase = "publish";
  await fs.rename(staging, targetPath);
  const verifyDb = await lancedb.connect(targetPath);
  const verifyTable = await verifyDb.openTable("memories");
  if ((await verifyTable.schema()).fields.find((field) => field.name === "vector").type.listSize !== 4096 ||
      await verifyTable.countRows() !== rows.length) throw new Error("published index failed verification");
  verifyTable.close(); verifyDb.close();
  const receipt = { state: "complete", generation, rows: rows.length, dimensions: 4096,
    source: options["--source-path"], target: options["--target-path"], metadataSha256: metadataSha };
  await atomicJson(receiptFile, receipt);
  process.stdout.write(MARKER + JSON.stringify(receipt) + "\n");
}

main().catch(() => {
  // Do not include database rows, provider response bodies or credentials in logs.
  process.stderr.write("LanceDB migration failed at " + phase + "; private backups and old database are retained.\n");
  process.exitCode = 1;
});

