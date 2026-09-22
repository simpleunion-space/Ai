#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { CLI_IDS, PROVIDER_TYPES, supportsCombination } from "./cli-adapters.mjs";

const SAFE_ID = /^[a-z0-9][a-z0-9-]*$/;
const SAFE_ENV = /^[A-Z][A-Z0-9_]*$/;

function fail(message) {
  throw new Error(`Invalid benchmark.json: ${message}`);
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim() === "") fail(`${name} must be a non-empty string`);
  return value;
}

function requireEnv(value, name) {
  const env = requireString(value, name);
  if (!SAFE_ENV.test(env)) fail(`${name} must be an uppercase environment-variable name`);
  return env;
}

export function loadBenchmarkConfig(configPath) {
  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (error) {
    fail(`cannot read ${configPath}: ${error.message}`);
  }

  if (!config || typeof config !== "object" || Array.isArray(config)) fail("root must be an object");
  if (config.schema_version !== 1) fail("schema_version must be 1");
  const taskFile = requireString(config.task_file, "task_file");
  if (taskFile !== "task.md" || path.isAbsolute(taskFile) || taskFile.split(/[\\/]+/).includes("..")) {
    fail("task_file must be the module task.md file");
  }
  if (!config.execution || typeof config.execution !== "object" || Array.isArray(config.execution)) fail("execution must be an object");
  if (config.execution.max_parallel !== 1) fail("execution.max_parallel must be 1 because runs are sequential");
  if (!Number.isInteger(config.execution.command_timeout_seconds) || config.execution.command_timeout_seconds < 1) {
    fail("execution.command_timeout_seconds must be a positive integer");
  }
  if (!Array.isArray(config.clis) || config.clis.length === 0) fail("clis must be a non-empty array");
  if (!Array.isArray(config.providers) || config.providers.length === 0) fail("providers must be a non-empty array");

  const cliIds = new Set();
  const clis = config.clis.map((cli, cliIndex) => {
    const prefix = `clis[${cliIndex}]`;
    if (!cli || typeof cli !== "object" || Array.isArray(cli)) fail(`${prefix} must be an object`);
    const id = requireString(cli.id, `${prefix}.id`);
    if (!CLI_IDS.includes(id)) fail(`${prefix}.id '${id}' is not registered`);
    if (cliIds.has(id)) fail(`duplicate CLI id '${id}'`);
    cliIds.add(id);
    if (typeof cli.enabled !== "boolean") fail(`${prefix}.enabled must be boolean`);
    return { id, displayName: requireString(cli.display_name, `${prefix}.display_name`), enabled: cli.enabled };
  });

  const providerIds = new Set();
  const targetIds = new Set();
  const providers = config.providers.map((provider, providerIndex) => {
    const prefix = `providers[${providerIndex}]`;
    if (!provider || typeof provider !== "object" || Array.isArray(provider)) fail(`${prefix} must be an object`);
    const id = requireString(provider.id, `${prefix}.id`);
    if (!SAFE_ID.test(id)) fail(`${prefix}.id must use lowercase letters, digits and hyphens`);
    if (providerIds.has(id)) fail(`duplicate provider id '${id}'`);
    providerIds.add(id);

    const type = requireString(provider.type, `${prefix}.type`);
    if (!PROVIDER_TYPES.includes(type)) fail(`${prefix}.type '${type}' is not registered`);
    const displayName = requireString(provider.display_name, `${prefix}.display_name`);
    if (typeof provider.enabled !== "boolean") fail(`${prefix}.enabled must be boolean`);
    if (!Array.isArray(provider.models)) fail(`${prefix}.models must be an array`);
    if (provider.enabled && provider.models.length === 0) fail(`${prefix}.models must not be empty for an enabled provider`);

    const normalized = { id, type, displayName, enabled: provider.enabled, models: [] };
    normalized.apiKeyEnv = requireEnv(provider.api_key_env, `${prefix}.api_key_env`);
    if (type !== "openrouter") normalized.baseUrlEnv = requireEnv(provider.base_url_env, `${prefix}.base_url_env`);

    const modelIds = new Set();
    provider.models.forEach((model, modelIndex) => {
      const modelPrefix = `${prefix}.models[${modelIndex}]`;
      if (!model || typeof model !== "object" || Array.isArray(model)) fail(`${modelPrefix} must be an object`);
      const modelId = requireString(model.id, `${modelPrefix}.id`);
      const targetId = requireString(model.target_id, `${modelPrefix}.target_id`);
      if (!SAFE_ID.test(targetId)) fail(`${modelPrefix}.target_id must use lowercase letters, digits and hyphens`);
      if (modelIds.has(modelId)) fail(`duplicate model '${modelId}' for provider '${id}'`);
      if (targetIds.has(`${id}/${targetId}`)) fail(`duplicate target_id '${targetId}' for provider '${id}'`);
      modelIds.add(modelId);
      targetIds.add(`${id}/${targetId}`);
      normalized.models.push({ id: modelId, targetId });
    });
    return normalized;
  });

  if (!Array.isArray(config.runs) || config.runs.length === 0) fail("runs must be a non-empty array");
  const cliById = new Map(clis.map((cli) => [cli.id, cli]));
  const providerById = new Map(providers.map((provider) => [provider.id, provider]));
  const runIds = new Set();
  const runs = config.runs.map((run, runIndex) => {
    const prefix = `runs[${runIndex}]`;
    if (!run || typeof run !== "object" || Array.isArray(run)) fail(`${prefix} must be an object`);
    const cliId = requireString(run.cli, `${prefix}.cli`);
    const providerId = requireString(run.provider, `${prefix}.provider`);
    const modelId = requireString(run.model, `${prefix}.model`);
    const cli = cliById.get(cliId);
    const provider = providerById.get(providerId);
    if (!cli) fail(`${prefix}.cli '${cliId}' is not declared`);
    if (!provider) fail(`${prefix}.provider '${providerId}' is not declared`);
    if (!cli.enabled) fail(`${prefix}.cli '${cliId}' is disabled`);
    if (!provider.enabled) fail(`${prefix}.provider '${providerId}' is disabled`);
    if (!supportsCombination(cliId, provider.type)) fail(`${prefix} has no registered adapter for ${cliId}/${provider.type}`);
    const model = provider.models.find((entry) => entry.id === modelId);
    if (!model) fail(`${prefix}.model '${modelId}' is not declared for provider '${providerId}'`);
    const id = `${cliId}/${providerId}/${model.targetId}`;
    if (runIds.has(id)) fail(`duplicate run '${id}'`);
    runIds.add(id);
    return { id, cli, provider, model };
  });

  return {
    taskFile,
    execution: { commandTimeoutSeconds: config.execution.command_timeout_seconds },
    clis,
    providers,
    runs
  };
}

export function getRuns(config) {
  return config.runs;
}

function main() {
  const [command, configPath, outputPath] = process.argv.slice(2);
  if (!command || !configPath) {
    throw new Error("Usage: benchmark-config.mjs <validate|runs> <benchmark.json>");
  }
  const config = loadBenchmarkConfig(configPath);
  if (command === "validate") {
    console.log(`Validated ${config.clis.length} CLI entries, ${config.providers.length} provider entries and ${getRuns(config).length} runs.`);
  } else if (command === "runs") {
    process.stdout.write(`${JSON.stringify(getRuns(config), null, 2)}\n`);
  } else {
    throw new Error(`Unknown command '${command}'`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
