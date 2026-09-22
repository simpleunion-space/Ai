#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { getRuns, loadBenchmarkConfig } from "./benchmark-config.mjs";
import { commandFor, requiredEnvironmentNames, writeCliConfiguration } from "./cli-adapters.mjs";
import { writeReport } from "./generate-report.mjs";

const configPath = process.env.BENCHMARK_CONFIG_PATH || "/input/benchmark.json";
const taskPath = process.env.BENCHMARK_TASK_PATH || "/input/task.md";
const resultsRoot = process.env.BENCHMARK_RESULTS_ROOT || "/output";
const preflightPrompt = "Reply with exactly OK. Do not create, modify, inspect, or execute files or commands.";

function isoNow() {
  return new Date().toISOString();
}

function log(level, message) {
  console.log(`${isoNow()} [${level}] ${message}`);
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function cleanResults() {
  fs.mkdirSync(resultsRoot, { recursive: true });
  for (const entry of fs.readdirSync(resultsRoot, { withFileTypes: true })) {
    if (entry.name === "README.md") continue;
    fs.rmSync(path.join(resultsRoot, entry.name), { recursive: true, force: true });
  }
}

function relativeResultPath(target) {
  return path.posix.join(target.cli.id, target.provider.id, target.model.targetId);
}

function publicRun(target) {
  return {
    id: target.id,
    cli_id: target.cli.id,
    cli_name: target.cli.displayName,
    provider_id: target.provider.id,
    provider_name: target.provider.displayName,
    provider_type: target.provider.type,
    model: target.model.id,
    model_target_id: target.model.targetId,
    result_directory: relativeResultPath(target)
  };
}

function redact(value, secrets) {
  let redacted = String(value ?? "");
  for (const secret of secrets) {
    if (secret && secret.length >= 4) redacted = redacted.split(secret).join("***");
  }
  return redacted;
}

function runCommand(command, args, options) {
  const { cwd, env, timeoutMs, secrets } = options;
  return new Promise((resolve) => {
    let output = "";
    let timedOut = false;
    let child;
    try {
      child = spawn(command, args, { cwd, env, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      resolve({ exitCode: 127, timedOut: false, output: redact(error.message, secrets) });
      return;
    }
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { output += chunk; });
    child.on("error", (error) => { output += `${error.message}\n`; });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 5000).unref();
    }, timeoutMs);
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ exitCode: code ?? 1, timedOut, output: redact(output, secrets) });
    });
  });
}

function buildChildEnvironment(target, homePath, credentialNames) {
  const env = { ...process.env };
  for (const name of credentialNames) delete env[name];
  for (const name of requiredEnvironmentNames(target.provider)) env[name] = process.env[name] || "";
  env.HOME = homePath;
  env.XDG_CONFIG_HOME = path.join(homePath, ".config");
  env.XDG_CACHE_HOME = path.join(homePath, ".cache");
  env.XDG_DATA_HOME = path.join(homePath, ".local", "share");
  return env;
}

function missingEnvironment(target) {
  return requiredEnvironmentNames(target.provider).filter((name) => !(process.env[name] || "").trim());
}

function makeResult(target, phase, startedAt, endedAt, outcome, logPath) {
  return {
    ...publicRun(target),
    phase,
    started_at: startedAt,
    ended_at: endedAt,
    duration_seconds: Math.max(0, (Date.parse(endedAt) - Date.parse(startedAt)) / 1000),
    exit_code: outcome.exitCode,
    timed_out: outcome.timedOut,
    log_path: logPath
  };
}

async function execute(target, prompt, phase, config, credentialNames) {
  const missing = missingEnvironment(target);
  if (missing.length > 0) {
    return { exitCode: 78, timedOut: false, output: `Required environment variables are not set: ${missing.join(", ")}\n` };
  }

  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), `ai-agents-test-${phase}-`));
  const homePath = path.join(temporaryRoot, "home");
  const workspacePath = path.join(temporaryRoot, "workspace");
  fs.mkdirSync(homePath, { recursive: true });
  fs.mkdirSync(workspacePath, { recursive: true });
  try {
    writeCliConfiguration(target, homePath);
    const invocation = commandFor(target, prompt);
    const outcome = await runCommand(invocation.command, invocation.args, {
      cwd: workspacePath,
      env: buildChildEnvironment(target, homePath, credentialNames),
      timeoutMs: config.execution.commandTimeoutSeconds * 1000,
      secrets: credentialNames.map((name) => process.env[name] || "")
    });
    return { ...outcome, workspacePath };
  } finally {
    if (phase === "preflight") fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

function persistWorkspace(outcome, target) {
  if (!outcome.workspacePath) return;
  const destination = path.join(resultsRoot, relativeResultPath(target), "workspace");
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.cpSync(outcome.workspacePath, destination, { recursive: true, force: true });
  fs.rmSync(path.dirname(outcome.workspacePath), { recursive: true, force: true });
}

async function toolVersion(command, args) {
  const result = await runCommand(command, args, {
    cwd: process.cwd(),
    env: process.env,
    timeoutMs: 30000,
    secrets: []
  });
  return result.exitCode === 0 ? result.output.trim() : `unavailable: ${result.output.trim()}`;
}

async function main() {
  const config = loadBenchmarkConfig(configPath);
  const runs = getRuns(config);
  if (!fs.existsSync(taskPath)) throw new Error(`Task file not found: ${taskPath}`);
  const taskText = fs.readFileSync(taskPath, "utf8");
  if (!taskText.trim()) throw new Error(`Task file is empty: ${taskPath}`);

  cleanResults();
  const credentialNames = [...new Set(config.providers.flatMap((provider) => requiredEnvironmentNames(provider)))];
  const run = {
    started_at: isoNow(),
    finished_at: null,
    status: "running",
    phase: "preflight",
    task_file: config.taskFile,
    execution: { max_parallel: 1, command_timeout_seconds: config.execution.commandTimeoutSeconds },
    runs: runs.map(publicRun),
    preflight: {},
    executions: {}
  };

  writeJson(path.join(resultsRoot, "benchmark-config.snapshot.json"), JSON.parse(fs.readFileSync(configPath, "utf8")));
  writeJson(path.join(resultsRoot, "run.json"), run);
  writeJson(path.join(resultsRoot, "_run-info.json"), {
    run_date: run.started_at,
    container: { platform: process.platform, node: process.version, uid: process.getuid?.() ?? null },
    tool_versions: {
      opencode: await toolVersion("opencode", ["--version"]),
      crush: await toolVersion("crush", ["--version"]),
      kilo: await toolVersion("kilo", ["--version"]),
      ansible_playbook: await toolVersion("ansible-playbook", ["--version"])
    },
    runs: run.runs
  });

  log("INFO", `Starting sequential preflight for ${runs.length} configured runs`);
  for (const target of runs) {
    const startedAt = isoNow();
    const outcome = await execute(target, preflightPrompt, "preflight", config, credentialNames);
    const endedAt = isoNow();
    const logPath = path.join(relativeResultPath(target), "preflight.log");
    const result = makeResult(target, "preflight", startedAt, endedAt, outcome, logPath);
    const absoluteDirectory = path.join(resultsRoot, relativeResultPath(target));
    fs.mkdirSync(absoluteDirectory, { recursive: true });
    fs.writeFileSync(path.join(resultsRoot, logPath), outcome.output, "utf8");
    writeJson(path.join(absoluteDirectory, "preflight.meta.json"), result);
    run.preflight[target.id] = result;
    log(result.exit_code === 0 ? "OK" : "ERROR", `[${target.id}] preflight exit ${result.exit_code}`);
  }

  if (Object.values(run.preflight).some((result) => result.exit_code !== 0)) {
    run.phase = "preflight_failed";
    run.status = "failed";
    run.finished_at = isoNow();
    writeJson(path.join(resultsRoot, "run.json"), run);
    writeReport(resultsRoot, run);
    log("ERROR", "Preflight failed; the task was not sent to any model");
    process.exitCode = 1;
    return;
  }

  run.phase = "execution";
  log("INFO", "Preflight passed; starting sequential task execution");
  for (const target of runs) {
    const startedAt = isoNow();
    const outcome = await execute(target, taskText, "execution", config, credentialNames);
    const endedAt = isoNow();
    const logPath = path.join(relativeResultPath(target), "execution.log");
    const result = makeResult(target, "execution", startedAt, endedAt, outcome, logPath);
    const absoluteDirectory = path.join(resultsRoot, relativeResultPath(target));
    fs.mkdirSync(absoluteDirectory, { recursive: true });
    fs.writeFileSync(path.join(resultsRoot, logPath), outcome.output, "utf8");
    persistWorkspace(outcome, target);
    writeJson(path.join(absoluteDirectory, "execution.meta.json"), result);
    run.executions[target.id] = result;
    log(result.exit_code === 0 ? "OK" : "ERROR", `[${target.id}] execution exit ${result.exit_code}`);
  }

  run.phase = "completed";
  run.status = Object.values(run.executions).every((result) => result.exit_code === 0) ? "passed" : "failed";
  run.finished_at = isoNow();
  writeJson(path.join(resultsRoot, "run.json"), run);
  writeReport(resultsRoot, run);
  if (run.status !== "passed") process.exitCode = 1;
}

main().catch((error) => {
  console.error(`Benchmark infrastructure error: ${error.stack || error.message}`);
  process.exitCode = 1;
});
