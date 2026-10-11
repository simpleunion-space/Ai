# Профиль `kurkin-family__labs__m01`

Профиль связывает общий модуль `ai-stand` с конкретным оборудованием и модельным набором площадки. Он не содержит пользовательские credentials, OAuth tokens, TLS private keys, базы или веса моделей.

## Раскатка

Посмотреть точные команды wrapper:

```sh
bash installations/kurkin-family__labs__m01/apply.sh --help
```

Порядок раскатки с нуля (предусловия, токен входа ai02 в Swarm, этапы `model-catalog-*`, `deploy`, `templates-ai02`, `configure-portainer`, `verify-*` и шаги, которые выполняются вручную) и справочник переменных этого профиля — в [INSTALLATION.md](../../INSTALLATION.md). Команды `apply.sh` запускаются на целевом узле; привилегированные этапы требуют `sudo`. Установочный wrapper передаёт общий код из `ai-stand/apply.sh`.

`deploy` на ai01 после `configure-authentik` и `configure-gitea` выполняет `configure-gitea-ssh-sync` (профиль включает его через `GITEA_SSH_SYNC_ENABLED`): он выпускает учётные данные синхронизатора SSH-ключей, создаёт Docker secrets и разворачивает сервис `gitea-ssh-sync`. Образ собирает `images-ai01`. Подробности — в разделе «SSH-ключи в Gitea» корневого README.

Этап `templates-ai02` публикует C# и Python templates с доступом read/use для всех пользователей, допущенных в Coder через Authentik. Публикация идёт в обычном socket-proxy-режиме: Coder работает с Docker через `docker-socket-proxy-coder`, отдельная защищённая конфигурация владельцев и допуск контроллера не требуются.

Обычный `verify-ai01` / `verify-ai02` не создаёт секреты, Portainer resources или Coder admin user; отсутствующие значения дают точную ошибку вместо побочной настройки.

## Модельный профиль

`installation.sh` задаёт параметры оборудования, accelerator/GFX и идентификаторы выбранных моделей. Общий `model-catalog/catalog.lock.json` фиксирует источники и контрольные суммы артефактов. Веса находятся в persistent storage установки, а не в Git.

Для подготовки/проверки каталога и применения профиля доступны команды `model-catalog-ai01`, `model-catalog-ai02`, `model-apply`, `model-status` и `model-verify`. При создании новой лаборатории добавляется собственный профиль оборудования и моделей; generic-код каталога и deployment stages повторно используются.

## Доступ к LLM API (OpenCode)

LLM API: `https://agentgateway.m01.labs.kurkin-family.ru/v1`, Authentik: `https://authentik.m01.labs.kurkin-family.ru`. Токен выпускается по общей инструкции в [README модуля](../../README.md#доступ-к-llm-api-без-административных-прав). Опубликованы чат-модель `qwen/qwen3.8-27b` (контекст 262144, вывод до 32768) и эмбеддинги `qwen3-embedding-8b`. Порт 4000 снаружи закрыт, нужен именно HTTPS на 443.

Глобальный конфиг OpenCode (`opencode.json`; путь покажет `opencode debug paths`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ai-stand/qwen/qwen3.8-27b",
  "provider": {
    "ai-stand": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "ai-stand (m01)",
      "options": {
        "baseURL": "https://agentgateway.m01.labs.kurkin-family.ru/v1",
        "apiKey": "{env:AI_STAND_API_KEY}"
      },
      "models": {
        "qwen/qwen3.8-27b": { "name": "Qwen3.8 27B (local)", "limit": { "context": 262144, "output": 32768 } }
      }
    }
  }
}
```

Переменная читается при запуске OpenCode: после повторного обмена токена перезапустите клиент. Проверка: `curl -H "Authorization: Bearer $AI_STAND_API_KEY" https://agentgateway.m01.labs.kurkin-family.ru/v1/models` отвечает 200 и перечисляет `qwen/qwen3.8-27b`; без токена или с JWT вне `ai-users` ответ 403.

## Состояние и эксплуатация

Базы, история OpenClaw, LanceDB, Coder workspace, репозитории Gitea, Docker/Swarm state, загруженные модели и секреты сохраняются отдельно от исходников. Повторный deploy не является командой очистки этих данных.

## Принятые ограничения

- **Portainer и UI agentgateway доступны только `ai-admins`.** Обычным пользователям эти консоли не нужны.
- OpenClaw — один общий gateway для всех ai-users; персональная изоляция (tenant-режим) не используется и удалена (решение владельца 2026-10-20, лаборатория).
- MetaMCP удалён вместе с «Personal MCP» (решение владельца 2026-10-23): серверов в нём не было, MCP-трафика тоже; общие и персональные MCP-цели Jira/Confluence/IMAP отдаёт только Agentgateway (`/mcp/*`, claim `sub`).
- Coder — обычная схема с docker-socket-proxy-coder; персональная изоляция workspace (брокер, контроллеры, egress-прокси) не используется и удалена (решение владельца 2026-10-21, лаборатория).
