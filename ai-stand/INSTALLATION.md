# Инсталляция: профиль, предусловия, раскатка с нуля

Общий код (`apply.sh`, `compose*.yaml`, `nginx/`, `docker/`, `readonly-mcp/`, …) не содержит значений площадки. Всё, что отличает одну установку от другой, — переменные в `installations/<имя>/installation.sh`. Этот файл читают `apply.sh`, обёртка `installations/<имя>/apply.sh` и `apply-model-profile.sh`.

Порядок ниже собран из кода и документации. Целиком, на пустых машинах, он не прогонялся: после последней раскатки с нуля (2026-09-13) добавились контроллер, доставка SSH-ключей, `STORAGE_ROOT` и контейнер `gitea-ssh-sync`. Ожидайте мелких правок и сообщайте о них.

## Что устроено жёстко (не параметр профиля)

- **Две машины с ролями `ai01` и `ai02`.** `ai01` — менеджер Swarm: Authentik, Gitea, Open WebUI, Agentgateway, llama.cpp (чат), контроллер. `ai02` — OpenClaw, Coder, llama.cpp (эмбеддинги), приёмник сертификата. `--node-name` принимает только эти два значения. Короткое имя хоста (`hostname -s`) должно совпадать с ролью: стадии `model-catalog-*` это проверяют. Адреса и DNS-имена машин — параметры профиля, роли — нет.
- **Ubuntu 26.04** на хостах (базовый образ `ubuntu:26.04`, репозитории ROCm `resolute`). Живьём проверялось только оборудование AMD (ROCm).
- **UID/GID служб 10000:20000.** Их задают пользователи в образах, `docker/llamacpp/runtime.py` и проверки `verify`; `apply.sh` отвергает профиль с другими значениями.
- **Версии образов и пакетов** закреплены в начале `apply.sh`. Образы собираются на самих хостах стадией `images`, остальные тянутся из публичных реестров (нужен выход в интернет).
- Рядом с каталогом `ai-stand` должны лежать `jira-readonly-mcp`, `confluence-readonly-mcp`, `imap-readonly-mcp` и `mcp-readonly-common`, если `READONLY_MCP_ENABLED=1`. Одна и та же ревизия дерева — на обоих хостах.

`apply.sh` при загрузке профиля проверяет: `INSTALLATION_NAME` равен имени каталога (скопированный профиль иначе работал бы с хранилищем исходной установки); `STORAGE_ROOT` — абсолютный путь без хвостового `/`; `IM_TZ` — имя часового пояса; при `CERT_DOMAIN` не `local` каждое публичное имя имеет вид `<метка>.<CERT_DOMAIN>` (иначе wildcard-сертификат его не покроет); флаги подсистем согласованы между собой.

## Справочник переменных профиля

«Обяз.» — без значения установка не заработает или будет работать с `.local`-значениями по умолчанию из `apply.sh`.

### Идентичность и хранилище

| Переменная | Обяз. | Смысл |
|---|---|---|
| `INSTALLATION_NAME` | да | Равна имени каталога профиля. Имя состоит из `[A-Za-z0-9_-]`, по образцу `организация__площадка__id`. |
| `INSTALLATION_TITLE` | нет | Человеческое название для сообщений. |
| `STORAGE_ROOT` | да | Корень данных на хостах: `<корень>/<компонент>-data/…`, `_secrets`, `_backups`. |
| `IM_TZ` | нет | Часовой пояс всех служб и обоих хостов. По умолчанию в `ai-stand` `UTC`, профиль переопределяет его своим значением (у m01 `Europe/Moscow`, то есть UTC+3 без перехода на летнее время). Стадия `host` выставляет его системе через `timedatectl`, `verify` проверяет. |

### Узлы и сеть

| Переменная | Обяз. | Смысл |
|---|---|---|
| `AI01_NODE_NAME`, `AI02_NODE_NAME` | да | Имена ролей: `ai01`, `ai02`. |
| `AI01_IP`, `AI02_IP` | да | Адреса машин; обёртка передаёт их как `--host-ip`/`--peer-ip`. |
| `TRUSTED_CIDRS` | да | Массив сетей, которым открыт доступ к службам хоста (firewall). |
| `PRIMARY_SWARM_NODE`, `MODEL_PROFILE_NODE` | да | Узел менеджера Swarm и узел, где выполняется профиль моделей (`ai01`). |
| `DEFAULT_ACCELERATOR` | да | `auto`, `amd`, `nvidia` или `cpu`. |
| `AI01_ROCM_GFX_VERSION`, `AI02_ROCM_GFX_VERSION` | при AMD | Архитектура GPU каждого узла (`gfx1151`, `gfx1103`, …); образ llama.cpp собирается под неё. |
| `OPENCLAW_AUTHENTIK_TRUSTED_PROXY_ENABLED`, `OPENCLAW_TRUSTED_PROXIES` | нет | Вход в OpenClaw через nginx и Authentik; адреса прокси, которым OpenClaw верит. |

### Имена и сертификат

| Переменная | Обяз. | Смысл |
|---|---|---|
| `CERT_DOMAIN` | да | Домен wildcard-сертификата (`*.<домен>`). |
| `CERT_DIR` | да | Каталог с `fullchain.pem`/`privkey.pem`, обычно `${STORAGE_ROOT}/certbot-data/live/<домен>`. |
| `AI01_HOST`, `AI02_HOST` | да | DNS-имена машин. |
| `OPENWEBUI_HOST`, `OPENCLAW_HOST`, `PORTAINER_HOST`, `AUTHENTIK_HOST`, `AGENTGATEWAY_HOST` | да | Публичные имена служб. |
| `CODER_HOST`, `GITEA_HOST` | при включённых службах | Имена Coder и Gitea; `GITEA_SSH_PORT` — порт SSH Gitea (по умолчанию 2222). |
| `AUTHENTIK_PUBLIC_URL`, `OPENWEBUI_PUBLIC_URL`, `OPENCLAW_PUBLIC_ORIGIN`, `PORTAINER_PUBLIC_URL`, `PORTAINER_MULTI_A_HOST` | да | Публичные адреса, обычно `https://${…_HOST}`. |
| `AUTHENTIK_IDENTITY_ISSUER_PATH` | да | Стабильное пространство имён UUID пользователей Authentik. |

Страницы nginx — шаблоны `nginx/conf.d/ai-stand-ai01.conf` и `…-ai02.conf`: `install_nginx` подставляет в них `@STORAGE_ROOT@`, `@CERT_DIR@`, `@AI01_IP@`, `@AI02_IP@` и `@…_HOST@` из профиля и отказывается ставить файл с неподставленным `@…@`. Отдельные файлы nginx в профиле не нужны.

### Подсистемы и контроллер

| Переменная | Обяз. | Смысл |
|---|---|---|
| `READONLY_MCP_ENABLED` | нет | Пользовательские Jira/Confluence/IMAP MCP (нужен `reconciler.json`, см. ниже). |
| `CODER_ENABLED` | нет | Coder на ai02 (шаблоны публикует `templates-ai02`). |
| `GITEA_ENABLED`, `GITEA_SSH_SYNC_ENABLED` | нет | Gitea на ai01 и регистрация SSH-ключей пользователей в ней. |
| `SSH_KEY_DELIVERY_ENABLED` | нет | Доставка личного SSH-ключа в рабочие места Coder (требует `CODER_ENABLED=1`). |
| `CONTROLLER_ENABLED` | нет | Контейнер `controller` с повторяющимися заданиями (reconcile, model-access, certbot). |
| `CERTBOT_ENABLED`, `CERTBOT_EMAIL`, `CERTBOT_CREDENTIALS_NAME`, `CERTBOT_HOOK_SOURCE`, `CERTBOT_RECEIVER_ENABLED` | нет | Автоматический wildcard-сертификат; `CERTBOT_HOOK_SOURCE` — хук DNS-01 нужного провайдера внутри каталога профиля (у m01 — `certbot/selectel-dns-hook.py`). См. [certbot/README.md](certbot/README.md). |

### Модели

| Переменная | Обяз. | Смысл |
|---|---|---|
| `LLAMACPP_CHAT_MODEL_SOURCE`, `LLAMACPP_CHAT_MODEL_ID` | да | Чат-модель из `model-catalog/catalog.lock.json`. |
| `LLAMACPP_CHAT_CONTEXT_LENGTH` | да | Желаемый контекст. |
| `LLAMACPP_CHAT_POLICY_MAX_CONTEXT` | нет | Потолок для выбора контекста селектором (по умолчанию равен `LLAMACPP_CHAT_CONTEXT_LENGTH`). |
| `LLAMACPP_CHAT_CONTEXT_CANDIDATES` | да | Массив контекстов, которые `model-apply` пробует по убыванию; остаётся первый, который тянет железо. |
| `LLAMACPP_CHAT_PARALLEL` | да | Число параллельных запросов llama.cpp. |
| `LLAMACPP_EMBEDDING_MODEL_ID`, `LLAMACPP_EMBEDDING_CONTEXT_LENGTH`, `LLAMACPP_EMBEDDING_CONTEXT_CANDIDATES` | да | Модель эмбеддингов, её контекст и допустимые значения. Размерность вектора берётся из каталога. |
| `MODEL_MIGRATION_REQUIRED` | нет | `1`: полный `deploy` ждёт расписку контроллера миграции индекса и привязывает память OpenClaw к её поколению. Расписку оформляет `model-apply` (им же начинается `deploy`): по коду `model-migration/migrate.py` признаёт пустое хранилище «fresh» и оформляет её сам; на реально пустой установке это не проверялось. |
| `MODEL_PROFILE_SCRIPT` | да | Скрипт профиля моделей (`apply-model-profile.sh`); все его значения берутся из этих переменных. |
| `OPENCLAW_CODEX_EXECUTION_PROFILE` | нет | `guardian` или `autonomous`. |

## Предусловия вне репозитория

1. **Машины.** Две машины с Ubuntu 26.04, учётная запись с `sudo`, выход в интернет (реестры образов, apt, Hugging Face для моделей), короткие имена хостов `ai01`/`ai02`, рабочая копия репозитория (с соседними модулями) одной ревизии на обеих.
2. **DNS.** A-записи для `AI01_HOST`, `AI02_HOST` и всех публичных имён: каждое должно указывать на машину, чей nginx его обслуживает (см. шаблоны nginx).
3. **Сертификат.** Пока своего нет, `host` создаёт самоподписанный wildcard-сертификат. Боевой выпуск — файл с учётными данными DNS-провайдера в `${STORAGE_ROOT}/_secrets/<CERTBOT_CREDENTIALS_NAME>` и первый выпуск по [certbot/README.md](certbot/README.md).
4. **`reconciler.json`** при `READONLY_MCP_ENABLED=1`: скопируйте [readonly-mcp/reconciler.example.json](readonly-mcp/reconciler.example.json) в `${STORAGE_ROOT}/readonly-mcp-data/reconciler/reconciler.json` (root, `0600`) и впишите адреса Jira/Confluence/IMAP. Токен Authentik для него создаёт `apply.sh`.
5. **Токен Telegram-бота** (по желанию): `${STORAGE_ROOT}/_secrets/openclaw-telegram-bot-token` на ai02, см. раздел «Telegram-бот OpenClaw» в [README.md](README.md).
6. **Токен входа ai02 в Swarm:** после `host-ai01` на ai01 выполните `docker swarm join-token -q manager`.

## Порядок раскатки с нуля

Команды выполняются на самой машине из каталога `ai-stand` (`bash installations/<имя>/apply.sh <команда>`; полный список — `--help`).

1. На **ai01**: `preflight-ai01`, `host-ai01`, `images-ai01`, `model-catalog-ai01`.
2. На **ai02**: `preflight-ai02`, `host-ai02 --manager-join-token <токен>`, `images-ai02`, `model-catalog-ai02`.
3. На **ai01**: `deploy`. Внутри: профиль моделей, стек Swarm (контроллер входит в него), затем `configure-authentik`, `configure-gitea`, при включении — `configure-gitea-ssh-sync` и `configure-ssh-key-delivery`, снова профиль моделей. Первый запуск долгий: загрузка и проверка моделей.
4. На **ai02**: `templates-ai02` (публикация шаблонов Coder).
5. На **ai01**: `configure-portainer`; затем `verify-ai01` и на ai02 `verify-ai02`.

После раскатки остаются шаги, которые код выполнить не может:

- Войти в Open WebUI под `akadmin` через Authentik. До этого `deploy` завершается с кодом 2 (`native_model_owner_unavailable`); после входа доступ к модели выдаётся не позже чем через пять минут.
- Войти в подписки Codex и Claude в OpenClaw (токены подписок хранятся в самом OpenClaw).
- Завести людей (`onboard-readonly-mcp-user`), заполнить в Authentik их атрибуты (Telegram ID, SSH-ключи, учётные данные MCP).
- Настроить Telegram (раздел «Telegram-бот OpenClaw» в [README.md](README.md)).
- Выпустить боевой сертификат ([certbot/README.md](certbot/README.md)).

## Новая инсталляция

1. Скопируйте каталог существующего профиля: `cp -r installations/kurkin-family__labs__m01 installations/<организация>__<площадка>__<id>`. Обёртка `apply.sh` и `apply-model-profile.sh` одинаковы для всех профилей: значения они берут из `installation.sh`.
2. В `installation.sh` задайте все переменные из справочника выше; `INSTALLATION_NAME` — имя нового каталога. Без этого `apply.sh` откажется работать.
3. В каталоге `certbot/` лежит хук DNS-провайдера прежней площадки (Selectel). Для другого провайдера напишите свой (формат — в [certbot/README.md](certbot/README.md)) и укажите `CERTBOT_HOOK_SOURCE`, либо оставьте `CERTBOT_ENABLED="0"` и ведите сертификат вручную.
4. Модели выбираются из `model-catalog/catalog.lock.json`; другую модель сначала добавьте в каталог (формат — [model-catalog/README.md](model-catalog/README.md)).
5. Пройдите «Порядок раскатки с нуля».
