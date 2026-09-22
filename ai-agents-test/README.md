# ai-agents-test

`ai-agents-test` автономно сравнивает coding-агентов в Docker. Каждый запуск
собирает свежий образ, проверяет модели коротким запросом и, только если все
preflight-проверки успешны, передаёт им одно и то же задание в независимых
workspace.

## Предварительные условия

- Windows с работающим Docker Desktop и доступным для текущей учётной записи
  Docker daemon;
- доступ в интернет к npm registry и API выбранных провайдеров;
- ключи провайдеров в локальном `set-api-keys.ps1`. Этот файл игнорируется Git.

Контейнер не получает Docker socket, не запускается в privileged-режиме и не
монтирует каталог проекта. В него передаются только `benchmark.json` и
`task.md` в режиме read-only, а `results/` — на запись. Агенты работают от
`root` лишь внутри одноразового контейнера: это необходимо, чтобы исходное
Ansible-задание можно было реально применить и повторно проверить.

## Быстрый запуск

Создайте локальный файл credentials из шаблона и заполните нужные строки:

```powershell
Copy-Item .\set-api-keys.ps1.example .\set-api-keys.ps1
# Отредактировать set-api-keys.ps1, затем:
.\run.ps1
```

`run.ps1` сам подключает `set-api-keys.ps1`, проверяет Docker daemon, каждый
раз выполняет `docker compose build --pull --no-cache` и запускает контейнер
через `docker compose run --rm`. В образ всегда попадают актуальные версии
OpenCode, Crush и Kilo CLI; фактические версии сохраняются в результатах.

Первый запуск без ключей тоже допустим: он создаст диагностический отчёт,
выполнение задания не начнёт и завершится с ненулевым кодом.

## Credentials

Шаблон содержит только комментарии:

```powershell
# $env:OPENROUTER_API_KEY = '...'
# $env:OPENAI_COMPATIBLE_BASE_URL = 'https://provider.example/v1'
# $env:OPENAI_COMPATIBLE_API_KEY = '...'
# $env:ANTHROPIC_COMPATIBLE_BASE_URL = 'https://provider.example/v1'
# $env:ANTHROPIC_COMPATIBLE_API_KEY = '...'
```

Значения не записываются в `benchmark.json`, сгенерированные конфигурации,
snapshot или отчёты. Runner передаёт дочернему CLI только credentials его
провайдера и маскирует известные значения в его выводе.

## Задание и матрица

[task.md](task.md) — текст задания. Меняйте его содержимое, но оставляйте путь
`task.md`, заданный в [benchmark.json](benchmark.json).

`benchmark.json` — единственный источник активной матрицы:

- `clis` — зарегистрированные CLI. Сейчас: `opencode`, `crush`, `kilo`;
- `providers` — зарегистрированные типы провайдеров: `openrouter`,
  `openai-compatible`, `anthropic-compatible`;
- `runs` — явные связки `cli` → `provider` → полный model ID;
- `execution.max_parallel` равен `1`: запуски выполняются строго последовательно;
- `command_timeout_seconds` — общий лимит одного preflight или execution.

Стартовая конфигурация содержит 18 запусков: шесть моделей OpenRouter через
каждый из трёх CLI. Записи `openai-compatible` и `anthropic-compatible`
намеренно выключены и служат шаблонами. Чтобы включить один из них, укажите URL
и key в `set-api-keys.ps1`, добавьте модели в `providers[].models`, переведите
`enabled` в `true` и добавьте явные записи в `runs`.

OpenRouter использует нативный runtime каждого CLI. Для compatible-провайдера
runner генерирует изолированную конфигурацию конкретного CLI с одним URL и API
key; дополнительные HTTP-заголовки не поддерживаются. Новые CLI и типы
провайдеров добавляются через реестры и адаптеры в `scripts/cli-adapters.mjs`,
после чего их можно использовать в `benchmark.json`.

## Поведение и exit code

1. Runner очищает только сгенерированное содержимое `results/`.
2. Preflight выполняется для всех активных `runs` тем же CLI, провайдером и
   моделью, что и основное задание.
3. Если хотя бы один preflight завершился ошибкой, задание не отправляется ни
   одной модели, но отчёт и все диагностические логи сохраняются.
4. После успешного preflight основной текст последовательно выполняется во
   всех изолированных workspace. Ошибка одного execution не отменяет другие,
   но делает итоговый код ненулевым.

Код `0` означает, что все preflight и execution успешны. Код `1` означает
ошибку инфраструктуры, preflight или минимум одного execution.

## Результаты

Результаты доступны на хосте сразу после завершения `run.ps1`:

```text
results/
├── benchmark-config.snapshot.json
├── run.json
├── _run-info.json
├── report.md
└── {cli}/{provider}/{model}/
    ├── preflight.meta.json
    ├── preflight.log
    ├── execution.meta.json
    ├── execution.log
    └── workspace/
```

`{model}` — безопасный `target_id` модели из `benchmark.json`; фактический API
model ID указан в metadata. При неуспешном preflight в ветке модели есть только
preflight-артефакты. `report.md` фиксирует технический исход, длительности,
логи и workspace, но не оценивает качество решения.

## Стоимость

Один полный прогон отправляет задание 18 раз, а также делает 18 коротких
preflight-запросов. Стоимость зависит от текущих цен OpenRouter и фактического
числа input, output и reasoning-токенов, поэтому перед запуском задайте лимит
расходов ключа в OpenRouter. Модуль не выставляет лимит и не может заранее
гарантировать стоимость agentic-выполнения.
