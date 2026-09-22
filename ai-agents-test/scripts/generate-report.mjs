#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function cell(value) {
  return String(value ?? "—").replaceAll("|", "\\|").replaceAll("\n", " ");
}

function duration(value) {
  return typeof value === "number" ? `${value.toFixed(1)} с` : "—";
}

function resultStatus(result) {
  if (!result) return "не запускалась";
  return result.exit_code === 0 ? "✅" : `❌ (exit ${result.exit_code})`;
}

function resultLink(result, fallback) {
  const relative = result?.log_path ?? fallback;
  return `[log](${relative.replaceAll("\\", "/")})`;
}

export function renderReport(run) {
  const lines = [
    "# Отчёт Docker-прогона AI-агентов",
    "",
    `Создан: ${run.finished_at ?? new Date().toISOString()}`,
    "",
    `Задание: \`${run.task_file}\``,
    "",
    `Итог: **${run.status === "passed" ? "успешно" : "ошибка"}**`,
    "",
    "## Предварительная проверка доступности",
    "",
    "| CLI | Провайдер | Модель | Статус | Время | Лог |",
    "|---|---|---|---|---:|---|"
  ];

  for (const target of run.runs) {
    const preflight = run.preflight[target.id];
    lines.push(`| ${cell(target.cli_name)} | ${cell(target.provider_name)} | ${cell(target.model)} | ${resultStatus(preflight)} | ${duration(preflight?.duration_seconds)} | ${resultLink(preflight, `${target.result_directory}/preflight.log`)} |`);
  }

  lines.push("", "## Выполнение задания", "");
  if (run.phase === "preflight_failed") {
    lines.push("Основное задание не запускалось: предварительная проверка хотя бы одной цели завершилась ошибкой.");
  } else {
    lines.push("| CLI | Провайдер | Модель | Статус | Время | Лог | Workspace |", "|---|---|---|---|---:|---|---|");
    for (const target of run.runs) {
      const execution = run.executions[target.id];
      const workspace = execution ? `[workspace](${`${target.result_directory}/workspace`})` : "—";
      lines.push(`| ${cell(target.cli_name)} | ${cell(target.provider_name)} | ${cell(target.model)} | ${resultStatus(execution)} | ${duration(execution?.duration_seconds)} | ${resultLink(execution, `${target.result_directory}/execution.log`)} | ${workspace} |`);
    }
  }

  lines.push("", "## Интерпретация", "", "Отчёт фиксирует доступность, ход запуска и созданные артефакты. Содержательная оценка результата зависит от задания и не выполняется эвристиками этого модуля.", "");
  return lines.join("\n");
}

export function writeReport(resultsRoot, run) {
  fs.writeFileSync(path.join(resultsRoot, "report.md"), renderReport(run), "utf8");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [runPath, resultsRoot] = process.argv.slice(2);
  if (!runPath || !resultsRoot) {
    console.error("Usage: generate-report.mjs <run.json> <results-root>");
    process.exit(1);
  }
  const run = JSON.parse(fs.readFileSync(runPath, "utf8"));
  writeReport(resultsRoot, run);
}
