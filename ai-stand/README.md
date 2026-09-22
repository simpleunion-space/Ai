# ai-stand

Воспроизводимая локальная AI-платформа на Docker Swarm. Generic core не
содержит реальных адресов и использует `*.local`; реальные домены, IP-адреса,
сертификаты и модельный профиль находятся в installation profile. Профиль
`m01` намеренно остаётся публичным рабочим референсом с реальной topology.

Текущий профиль: [`installations/kurkin-family__labs__m01`](installations/kurkin-family__labs__m01/README.md).

## Состав

- Authentik с PostgreSQL и Redis — идентификация и OIDC-провайдеры;
- LM Studio и LM Studio Proxy — внутренний model backend;
- Open WebUI — пользовательский интерфейс чата;
- OpenClaw Gateway и изолированный sandbox dind;
- MetaMCP с PostgreSQL — агрегация MCP;
- agentgateway — модельный шлюз перед LM Studio Proxy и, в opt-in profile,
  перед персональными GigaCode subscription bridge;
- `gigacode-subscription-bridge` — необязательный ASP.NET Core/.NET 10
  adapter прямого subscription protocol `gigacode.ru` в OpenAI-compatible API;
- Coder с отдельной PostgreSQL и rootless Docker daemon — необязательный
  control plane рабочих окружений;
- Portainer Server и глобальный Portainer Agent.

Generic Nginx публикует по HTTPS Authentik, Open WebUI, MetaMCP,
agentgateway, Portainer, OpenClaw и включённый profile Coder. LM Studio и LM Studio Proxy не имеют
публичного HTTP(S) ingress: их обслуживает только Agentgateway на отдельной
`ai-models-backend` сети. Конкретные узлы, FQDN, размещение сервисов и
межузловая маршрутизация определяются installation profile; для текущей
площадки они описаны в его README.

## Доступ и защита

Nginx выполняет TLS reverse-proxy. OpenClaw может явно включить поддерживаемый
режим `trusted-proxy`: тогда профиль обязан поставить Authentik forward-auth,
перезаписывать identity/forwarding headers и закрыть прямой Gateway ingress.

- Open WebUI использует собственный OIDC-вход; доступны группы `ai-users` и
  `ai-admins`.
- Portainer и read-only консоль agentgateway используют OIDC для
  административного доступа (`ai-admins`).
- MetaMCP UI использует OIDC для `ai-users` и `ai-admins`. Его native
  registration UI и sign-up API снаружи возвращают `404` на Nginx; native
  MCP/OpenAPI/SSE data-plane также закрыт, чтобы не обходить Agentgateway.
- LLM API agentgateway требует строгий service bearer token: отдельные токены
  получает Open WebUI и OpenClaw.
- OpenClaw по умолчанию использует gateway token; в trusted-proxy profile
  токен удаляется из публичного Gateway path, а проверенный Authentik `sub`
  становится requester identity.

Open WebUI chat/RAG и Local OpenClaw обращаются к моделям только через service
bearer Agentgateway. Персональный GigaCode получает короткоживущий
subject-bound JWT от internal broker; внешний клиент использует HTTPS `/v1` с
отдельным scoped key. Codex и Claude Code остаются нативными subscription
runtimes OpenClaw и намеренно не проксируются через Agentgateway.

Технические порты сервисов закрыты снаружи: публичный доступ проходит через
Nginx по HTTPS.

## Публикация

Профиль `m01` — намеренно публикуемый референс: FQDN, private IP/CIDR, node
layout, TLS paths и hardware являются раскрываемыми operational metadata, а не
секретами. Автоматически обезличивать или переносить их в private overlay не
нужно.

Literal passwords, tokens, private keys и certificate material не хранятся в
исходниках: deployment создаёт их на хосте и передаёт компонентам через host
secret storage и Docker Secrets. Перед публикацией выполнять из корня
репозитория следующий checklist; каждая команда должна вернуть пустой вывод.

```bash
# Не должно быть tracked credential/key-файлов.
git ls-files ai-stand | rg -i '(^|/)(\.env(?:\..*)?|.*\.(pem|key|p12|pfx)|id_(rsa|ecdsa|ed25519)|.*(credential|secret|token|password).*)$'

# Показываются только имена файлов, а не совпавшие потенциальные секреты.
git grep -IlE -e '-----BEGIN ([A-Z0-9 ]* )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|glpat-[A-Za-z0-9_-]{20,}' -- ai-stand
```

Совпадение означает: остановить публикацию, исследовать файл вне публичного
лога и удалить или заменить material до повторной проверки.

## Длительные запросы локальной модели

Один запрос OpenClaw к локальной модели может идти до 24 часов. Предел
согласован на двух уровнях тремя параметрами: OpenClaw
`OPENCLAW_PROVIDER_TIMEOUT_SECONDS` (секунды; записывается в
`models.providers.lmstudio.timeoutSeconds`), а также LM Studio Proxy
`LMSTUDIO_PROXY_UPSTREAM_TIMEOUT_MS` (миллисекунды; полный upstream-запрос)
и `LMSTUDIO_PROXY_UPSTREAM_IDLE_TIMEOUT_MS` (миллисекунды; максимальная пауза
между байтами upstream stream). Он относится к одному запросу модели, а не к
`OPENCLAW_MAX_TOKENS` или общему размеру диалога. Nginx для маршрутов LLM и
OpenClaw также допускает 24 часа.

## Необязательный персональный GigaCode subscription bridge

Installation profile может явно задать `GIGACODE_SUBSCRIPTION_ENABLED=1`. Тогда
reconciler создаёт из атрибутов Authentik отдельный внутренний сервис
`gigacode-subscription-bridge-<subject-hash>` для каждого Authentik `sub`
на узле agentgateway и модель `gigacode/codechat`:

```text
Open WebUI / OpenClaw → agentgateway → gigacode-subscription-bridge → https://gigacode.ru
```

Каждый bridge не публикует порт, не имеет bind-mount/volume, Docker socket,
GigaCode CLI, OAuth cache или telemetry. Он работает как UID/GID
`10000:20000` с read-only root filesystem. Единственный входящий путь —
`ai-models-backend`; полный
и stream-idle timeout составляют 24 часа. У каждого bridge своя FIFO-очередь:
2 активных inference-запроса и до 10 ожидающих, затем OpenAI-совместимый
`429`.

Пользователь сохраняет Device ID в собственном атрибуте Authentik
`ai_stand_mcp_gigacode_device_id` через self-service prompt stage на странице
`/if/user/` (заводится idempotent-но в `configure.mjs`). Root-only reconciler
создаёт версионированный Docker Secret и отдельный bridge только для этого
subject; значение не попадает в Git, логи или image layers. Internal
`gigacode-identity-broker` выдаёт Agentgateway короткоживущий (не более 60
секунд) JWT с immutable `sub`, поэтому общие machine tokens не могут выбрать
чужой backend. Bridge получает короткоживущий token через
`/api/v2/auth/plugin`, обновляет его за 60 секунд
до истечения и держит token/config только в памяти. Он читает динамический
`chat.url` из `/api/v2/config`, но разрешает лишь HTTPS endpoint на
`gigacode.ru`, завершающийся `/chat/.../completions`; fallback —
`/api/v2/chat/completions`.

`gigacode/codechat` — внутренний API ID с context window `65536`; profile
может задать отдельное отображаемое имя для Open WebUI и OpenClaw, не меняя
маршрут или существующие чаты. Chat Completions и Responses facade передают
структурированные OpenAI `tools`, `tool_choice`, `tool_calls` и результаты
tool calls без текстового parser'а. Для streaming Responses bridge назначает
каждому output item отдельный монотонный `output_index`, поэтому инструменты
по-прежнему исполняет sandbox OpenClaw, а не bridge. Этот protocol основан на
поведении CLI-подписки и не является заявленным service API: обновление
CLI/поставщика требует повторной проверки bridge.

GigaCode намеренно не появляется как общий LLM provider в Agentgateway: это
нарушило бы выбор backend по пользователю. Каждый подписанный Authentik
subject получает отдельный внутренний маршрут на свой персональный
`gigacode-subscription-bridge-{slug}`.

## Необязательный Coder

Profile может включить `CODER_ENABLED=1`. Тогда Coder и его PostgreSQL
размещаются на выделенном узле, а Nginx публикует только его HTTPS FQDN.
Coder использует confidential OIDC client Authentik: войти могут только
`ai-users` и `ai-admins`; claim `groups` синхронизирует роли так, что
`ai-admins` получают `owner`, а остальные пользователи — `member`.
Локальная password-аутентификация отключена.
На `/login` Coder показывает native кнопку **«Войти через Authentik»**;
`apply.sh verify-ai02` проверяет этот контракт через Coder API и также
проверяет, что password login остался выключен.

Встроенный provisioner Coder получает единственный Docker endpoint —
выделенный rootless daemon. Этот daemon создаёт локальную сеть
`ai-coder-workspaces`; host Docker socket, OpenClaw DIND, MetaMCP,
AI credentials и model backend в workspace не монтируются. Persistent paths
следуют формуле `/mnt/storage/coder-data/{server,postgres,provisioner}`.

## Identity-scoped read-only MCP

Три самостоятельных исходных модуля в корне репозитория —
`jira-readonly-mcp`, `confluence-readonly-mcp` и `imap-readonly-mcp` —
реализуют Streamable HTTP MCP на .NET 10. Каждый контейнер получает ровно
одну upstream-учётную запись, фиксированный HTTPS/TLS endpoint и отдельный
внутренний bearer secret. Они не принимают URL от MCP-клиента и не содержат
write-tools: Jira/Confluence делают только `GET`, а IMAP открывает ящики через
`EXAMINE` и читает тела через `BODY.PEEK`.

Фича выключена по умолчанию (`READONLY_MCP_ENABLED=0`). При включении её
control plane состоит только из root-owned reconciler на узле `ai01` —
отдельного сервиса хранения credentials больше нет. Пользователь редактирует
свои `ai_stand_mcp_*` атрибуты через self-service prompt stage на обычной
странице `/if/user/` в Authentik (`configure.mjs` idempotent-но заводит эту
prompt- и write-стадию); credentials имеют строго фиксированную схему:
Jira/Confluence — PAT, IMAP — `username`/`password`, GigaCode — `device_id`.
Пустой или отсутствующий атрибут читается reconciler'ом как
`needs_credentials`, отдельной `CHANGE_ME`-заглушки больше нет. Reconciler
никогда не пишет значение credential обратно в атрибут. Администратор задаёт
общие URL, TLS trust store и IMAP port в root-owned `reconciler.json`;
пользователь не может менять upstream или маршрутизацию, если только
installation явно не включит per-user override этих же URL тем же
`reconciler.json` (`userOverrides.upstreamsEnabled`, по умолчанию выключено).

Раз в пять минут reconciler читает `ai-users` и их Authentik-атрибуты, а
также Swarm. Каждая из трёх интеграций обрабатывается независимо: перед
публикацией он выполняет безопасный read-only probe, создаёт versioned
Docker Secrets — номер версии теперь берётся из fingerprint значения
credential, а не из внешнего KV-счётчика версий, — и пишет manifest без
plaintext credentials. Ошибка Jira не блокирует Confluence или IMAP.
`render-profile.py` рендерит по этому manifest на `ai01` четыре Agentgateway
resource-server маршрута:

```text
/mcp/work/jira-readonly-mcp
/mcp/work/confluence-readonly-mcp
/mcp/work/imap-readonly-mcp
/mcp/personal
```

`READONLY_MCP_PATH_PREFIX` — единственный источник первых трёх путей и по
умолчанию равен `/mcp/work`. Оно принимает только `/mcp/<lowercase-slug>`.
Инсталляция при необходимости может использовать root-only runtime override
вне репозитория; профиль и generic README остаются нейтральными.

Первым трём маршрутам Authentik передаёт стабильный user UUID (`sub`), а
Agentgateway допускает только target того же UUID. Неизвестный, неполный или
не состоящий в `ai-users` пользователь получает `403` без списка
инструментов. Backend получает только свой внутренний bearer, а не credentials
Jira/Confluence/IMAP.

`/mcp/personal` не является shared MetaMCP endpoint. Перед включением
персонального data-plane администратор один раз выполняет reviewed migration
существующих владельцев: root-owned inventory связывает MetaMCP OIDC user с
неизменяемой парой Authentik `(issuer, sub)`. Pinned helper проверяет образ и
схему MetaMCP `2.4.22` и делает transaction serializable. Получившийся
descriptor не содержит email, endpoint API key или credential. Он может быть
применён только tenant runtime controller-ом, который создаёт отдельные
state/database, private `ai-metamcp-tenant-<subject>` network, rootless DIND
и узкий router к `ai-mcp-backend`. Пока controller не подтвердил такое
применение, у `/mcp/personal` нет target и Agentgateway возвращает отказ.

После включения `openclaw-gateway` добавляет те же четыре remote MCP entries
с `oauth.identity: per-requester`. Open WebUI `v0.11.3` имеет global MCP
connection definitions, но хранит OAuth grant отдельно для каждого своего
пользователя: пользователь регистрирует общий OAuth 2.1 инструмент один раз,
затем сам завершает Authentik redirect. Authentik не поддерживает DCR, поэтому
Agentgateway возвращает один заранее зарегистрированный public PKCE client
`agentgateway-mcp`; этот public identifier не является секретом и не меняет
изоляцию по JWT `sub`. OAuth MCP-инструменты нельзя делать default/pre-enabled:
до первого interactive sign-in пользователь включает их в конкретном чате.
Telegram остаётся допустимым только для доверенной группы, потому что
OAuth-link привязан к requester-сообщению.

Все четыре модуля собираются локально. При доставке на build node они лежат
рядом с `ai-stand` под `/home/setup`; `apply.sh images-ai01` использует named
build context для `mcp-readonly-common` и локальные теги, а `docker stack
deploy --resolve-image never` не обращается к внешнему registry для этих
образов.

## Выполнение Codex-задач

Codex — managed plugin/harness процесса `openclaw-gateway`, а не отдельный
сервис стенда; entrypoint закреплённо устанавливает его в persistent state.
Generic environment использует профиль `guardian`: Codex запрашивает проверку
выполнения команд и записывает центральный `tools.exec.mode=auto`.
Installation profile может явно переопределить
`OPENCLAW_CODEX_EXECUTION_PROFILE=autonomous`: он согласованно задаёт
`yolo`/`never` для Codex и `tools.exec.mode=full` без model-reviewer и
интерактивного approval. Для этого профиля Gateway также управляет своим
persisted host-approval document (`security=full`, `ask=off`,
`askFallback=full`) на каждом старте.

Автономный профиль не открывает Docker хоста: Gateway работает от
пользователя `ai`, не получает `docker.sock`, а его Docker CLI обращается
только к `openclaw-sandbox-dind` через `DOCKER_HOST`. Однако Codex может
автоматически выполнять команды и создавать контейнеры в DIND, а также
читать доступные пользователю `ai` данные Gateway; применять этот профиль
следует только для доверенных пользователей и задач.

Для Docker sandbox DIND получает только узкий read-write mount
`/home/ai/.openclaw/sandboxes`. Это persistent workspace-корень OpenClaw:
обычный sandbox получает из него только свой `/workspace`, а skills остаются
отдельным read-only mount. Конфигурация Gateway, OAuth state и прочие данные
из `/home/ai` в DIND не монтируются. Агент с автономным доступом к Docker API
DIND потенциально может обращаться к workspace других доверенных агентов;
поэтому такой режим не подходит для взаимно недоверенных агентов.

## Структура данных

Постоянные данные размещаются под `/mnt/storage/*-data` и разделены по
компонентам. Основные пути:

```text
/mnt/storage/lmstudio-data/lmstudio
/mnt/storage/openclaw-data/gateway
/mnt/storage/openclaw-data/gateway/.openclaw/sandboxes
/mnt/storage/openclaw-data/sandbox-dind
/mnt/storage/openwebui-data/server
/mnt/storage/portainer-data/server
/mnt/storage/authentik-data/{postgresql,redis,server,icons}
/mnt/storage/metamcp-data/postgres
/mnt/storage/metamcp-data/tenant-<authentik-sub>/{metamcp,postgres,dind}
/mnt/storage/readonly-mcp-data/reconciler/{reconciler.json,manifest.json,metamcp-tenants.json}
/mnt/storage/agentgateway-data/server/config.yaml
/mnt/storage/coder-data/{server,postgres,provisioner/{home,runtime,docker,docker.sock}}
```

Команда `host` выполняет безопасную идемпотентную миграцию старой root-style
структуры только в пустой target. При конфликте данных работа прекращается;
резервные копии находятся в `/mnt/storage/_backups`.

## Применение

`apply.sh` требует installation profile. Для площадки используйте wrapper:

```bash
cd /home/setup/ai-stand
sudo bash installations/kurkin-family__labs__m01/apply.sh --help
```

Основные команды generic core: `preflight`, `host`, `images`, `deploy`,
`configure-authentik`, `onboard-readonly-mcp-user`, `configure-portainer`,
`migrate-metamcp-tenants`, `verify`, `credentials` и `all`. Поддерживаемые
параметры — `--installation`, `--node-name`, `--host-ip`, `--peer-ip`,
повторяемый `--trusted-cidr`, `--manager-join-token` и `--accelerator`.

`onboard-readonly-mcp-user --username <u> --email <e> [--groups ai-users]`
идемпотентно заводит одного Authentik-пользователя (на `ai01`): создаёт
аккаунт со свежесгенерированным временным паролем, который команда печатает
один раз и нигде не сохраняет, и добавляет его в указанные группы
(`ai-users` и/или `ai-admins`). Повторный запуск с тем же `--username` не
трогает уже изменённый пользователем пароль и только добавляет недостающие
группы — членство никогда не снимается автоматически. Как и для
`reconciler.json`, реальные username/email/группы конкретного человека —
только параметры конкретного запуска на хосте и не должны попадать в Git.

Для текущего профиля wrapper выполняет `deploy` в неизменной последовательности:

1. раскатывает стек;
2. запускает `configure-authentik`;
3. применяет модельный профиль.

После этого отдельно выполните `configure-portainer`, затем `verify-ai01` и
`verify-ai02`. Полный порядок запуска и реальные адреса приведены в
README installation profile.

## Модели

Generic baseline использует chat-модель `qwen/qwen3-1.7b@q8_0` и embedding
`Qwen3-Embedding-0.6B-GGUF` Q8 в одном экземпляре LM Studio. Generic core
поддерживает accelerator `cpu`, `amd` и `nvidia`: выполнение на GPU зависит
от выбранного accelerator и не является свойством baseline. Installation
profile задаёт production-модель, GPU-параметры, каталог загрузок и context
policy. Переключение и проверка выполняются через `model-apply`,
`model-status` и `model-verify` wrapper-а.
