# ai-stand

Воспроизводимая локальная AI-платформа на Docker Swarm. Generic core не
содержит реальных адресов и использует `*.local`; реальные домены, IP-адреса,
сертификаты и модельный профиль находятся в installation profile. Профиль
`m01` намеренно остаётся публичным рабочим референсом с реальной topology.

Текущий профиль: [`installations/kurkin-family__labs__m01`](installations/kurkin-family__labs__m01/README.md).

## Состав

- Authentik с PostgreSQL и Redis — идентификация и OIDC-провайдеры;
- LM Studio и LM Studio Proxy — модели и OpenAI-совместимый API;
- Open WebUI — пользовательский интерфейс чата;
- OpenClaw Gateway и изолированный sandbox dind;
- MetaMCP с PostgreSQL — агрегация MCP;
- agentgateway — модельный шлюз перед LM Studio Proxy;
- Portainer Server и глобальный Portainer Agent.

Generic Nginx публикует по HTTPS Authentik, LM Studio, LM Studio Proxy, Open
WebUI, MetaMCP, agentgateway, Portainer и OpenClaw. Конкретные узлы, FQDN,
размещение сервисов и межузловая маршрутизация определяются installation
profile; для текущей площадки они описаны в его README.

## Доступ и защита

Nginx выполняет plain TLS reverse-proxy и не использует Authentik
forward-auth.

- Open WebUI использует собственный OIDC-вход; доступны группы `ai-users` и
  `ai-admins`.
- Portainer и read-only консоль agentgateway используют OIDC для
  административного доступа (`ai-admins`).
- MetaMCP admin UI использует OIDC только для `ai-admins`. Его native
  registration UI и sign-up API снаружи возвращают `404` на Nginx; MCP
  endpoints используют собственные bearer keys.
- LLM API agentgateway требует строгий service bearer token: отдельные токены
  получает Open WebUI и OpenClaw.
- OpenClaw использует собственный gateway token.

Прямые HTTPS endpoints LM Studio и LM Studio Proxy — это TLS-прокси без OIDC
и без token-policy agentgateway. Для аутентифицированного service-доступа к
LLM API используйте agentgateway.

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
/mnt/storage/agentgateway-data/server/config.yaml
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
`configure-authentik`, `configure-portainer`, `verify`, `credentials` и
`all`. Поддерживаемые параметры — `--installation`, `--node-name`,
`--host-ip`, `--peer-ip`, повторяемый `--trusted-cidr`,
`--manager-join-token` и `--accelerator`.

Для текущего профиля wrapper выполняет `deploy` в неизменной последовательности:

1. раскатывает стек;
2. запускает `configure-authentik`;
3. применяет модельный профиль.

После этого отдельно выполните `configure-portainer`, затем `verify-ai01` и
`verify-linux01`. Полный порядок запуска и реальные адреса приведены в
README installation profile.

## Модели

Generic baseline использует chat-модель `qwen/qwen3-1.7b@q8_0` и embedding
`Qwen3-Embedding-0.6B-GGUF` Q8 в одном экземпляре LM Studio. Generic core
поддерживает accelerator `cpu`, `amd` и `nvidia`: выполнение на GPU зависит
от выбранного accelerator и не является свойством baseline. Installation
profile задаёт production-модель, GPU-параметры, каталог загрузок и context
policy. Переключение и проверка выполняются через `model-apply`,
`model-status` и `model-verify` wrapper-а.
