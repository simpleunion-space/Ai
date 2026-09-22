import fs from "node:fs";
import path from "node:path";

export const CLI_IDS = ["opencode", "crush", "kilo"];
export const PROVIDER_TYPES = ["openrouter", "openai-compatible", "anthropic-compatible"];

export function supportsCombination(cliId, providerType) {
  return CLI_IDS.includes(cliId) && PROVIDER_TYPES.includes(providerType);
}

export function modelSelector(target) {
  return `${target.provider.id}/${target.model.id}`;
}

export function requiredEnvironmentNames(provider) {
  const names = [provider.apiKeyEnv];
  if (provider.type !== "openrouter") names.push(provider.baseUrlEnv);
  return names;
}

function compatiblePackage(provider) {
  return provider.type === "openai-compatible"
    ? "@opencode/ai/providers/openai-compatible"
    : "@opencode/ai/providers/anthropic-compatible";
}

function openCodeLikeConfig(target) {
  const { provider, model } = target;
  const providerConfig = {
    name: provider.displayName,
    env: [provider.apiKeyEnv],
    models: { [model.id]: {} }
  };

  if (provider.type !== "openrouter") {
    providerConfig.package = compatiblePackage(provider);
    providerConfig.settings = { baseURL: `{env:${provider.baseUrlEnv}}` };
  }

  return {
    model: modelSelector(target),
    small_model: modelSelector(target),
    providers: { [provider.id]: providerConfig }
  };
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function crushRc(target) {
  const { provider, model } = target;
  if (provider.type === "openrouter") return "# OpenRouter uses Crush's native provider and OPENROUTER_API_KEY.\n";

  const type = provider.type === "openai-compatible" ? "openai-compat" : "anthropic";
  const selector = modelSelector(target);
  return [
    `provider add ${provider.id} --name ${JSON.stringify(provider.displayName)} --type ${type} --base-url \"$${provider.baseUrlEnv}\" --api-key \"$${provider.apiKeyEnv}\"`,
    `model add ${selector} --name ${JSON.stringify(model.id)} --context-window 200000 --default-max-tokens 16000`,
    "permissions allow view edit bash",
    ""
  ].join("\n");
}

export function writeCliConfiguration(target, homePath) {
  if (target.cli.id === "opencode") {
    writeJson(path.join(homePath, ".config", "opencode", "opencode.json"), {
      $schema: "https://opencode.ai/config.json",
      ...openCodeLikeConfig(target)
    });
    return;
  }

  if (target.cli.id === "kilo") {
    writeJson(path.join(homePath, ".config", "kilo", "kilo.json"), openCodeLikeConfig(target));
    return;
  }

  if (target.cli.id === "crush") {
    const configPath = path.join(homePath, ".config", "crush", "crushrc");
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(configPath, crushRc(target), "utf8");
    return;
  }

  throw new Error(`No adapter is registered for CLI '${target.cli.id}'`);
}

export function commandFor(target, prompt) {
  const selector = modelSelector(target);
  switch (target.cli.id) {
    case "opencode":
      return { command: "opencode", args: ["run", "--standalone", "--model", selector, "--auto", "--format", "json", prompt] };
    case "crush":
      return { command: "crush", args: ["run", "--yolo", "--model", selector, "--verbose", prompt] };
    case "kilo":
      return { command: "kilo", args: ["run", "--model", selector, "--auto", "--format", "json", prompt] };
    default:
      throw new Error(`No adapter is registered for CLI '${target.cli.id}'`);
  }
}
