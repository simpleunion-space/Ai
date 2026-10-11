# Open WebUI

Open WebUI предоставляет общий web-интерфейс локальных моделей. Все model requests идут через Agentgateway. Managed model records и grants синхронизируются штатным ORM helper; доступ выдаётся сопоставленной Authentik identity, без wildcard grant и повышения до administrator.

История чатов и база Open WebUI — persistent installation data. Перед обновлением или изменением model grants сохраните backup БД. Embedding-модель не публикуется как chat-модель.

## Эксплуатация

- **Версия образа и запуск.** `SUPPORTED_VERSION` в `model_access.py` сверяется с версией Open WebUI. Раз в пять минут скрипт
  запускает задание `model-access` контейнера `controller` (`docker/controller`) из рабочей копии репозитория, смонтированной
  в контейнер, поэтому отдельной копии на хосте и systemd-таймера нет. Если версия Open WebUI повышена, а `SUPPORTED_VERSION`
  нет, задание падает с `unsupported_openwebui_version`; смотрите `docker service logs ai-stand_controller`.
  Конфигурацию `identity/openwebui-model-access.json` пишет стадия `host` (`model_access_snapshot.py --install-config`).
- **Откат версии.** Миграции БД идут вперёд (v0.12.3 обновила схему): возврат тега без восстановления `webui.db` из
  резервной копии не гарантирован.
- **Пустой экран «Необходимо подключение к серверу».** После пересоздания БД или смены `WEBUI_SECRET_KEY` браузер держит
  токен прежней базы (`/api/config` отвечает 401). Лечится сбросом cookie сайта `openwebui.<домен>`.
- **MCP-подключения** (Jira/Confluence/IMAP) задаются только переменной `TOOL_SERVER_CONNECTIONS` сервиса: при
  `ENABLE_PERSISTENT_CONFIG=False` записи в БД игнорируются, а правки в админке External Tools теряются при рестарте.
  Список собирает `sync_openwebui_tool_servers` (apply.sh) при `deploy` и `reconcile-mcp`.

