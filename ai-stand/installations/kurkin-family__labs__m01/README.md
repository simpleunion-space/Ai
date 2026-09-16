# kurkin-family__labs__m01

Installation profile для лабораторной площадки `m01.labs.kurkin-family.ru`.

Этот каталог — единственное место, где должны жить реальные домены, IP-адреса, site-specific Nginx-конфиги и модельный профиль площадки. Generic `ai-stand` остаётся переносимым и использует только `*.local`.

`m01` намеренно публикуется как рабочий референс: его FQDN, private IP/CIDR,
node layout, TLS paths и hardware — раскрываемые operational metadata, а не
секреты. Literal passwords, tokens, private keys и certificate material здесь
не хранятся.

## Узлы и DNS

| Имя | IP | Роль |
| --- | --- | --- |
| `ai01.m01.labs.kurkin-family.ru` | `10.20.0.200` | Swarm manager+worker, LM Studio, Open WebUI, Authentik, Portainer Server |
| `linux01.m01.labs.kurkin-family.ru` | `10.20.0.204` | Swarm manager+worker, OpenClaw |
| `mac01.m01.labs.kurkin-family.ru` | `10.20.0.202` | Внешний macOS client/runner, вне Swarm |

Service DNS:

| Service | DNS |
| --- | --- |
| Authentik | `authentik.m01.labs.kurkin-family.ru -> 10.20.0.200` |
| LM Studio | `lmstudio.m01.labs.kurkin-family.ru -> 10.20.0.200` |
| LM Studio Proxy | `lmstudio-proxy.m01.labs.kurkin-family.ru -> 10.20.0.200` |
| agentgateway | `agentgateway.m01.labs.kurkin-family.ru -> 10.20.0.200` |
| Open WebUI | `openwebui.m01.labs.kurkin-family.ru -> 10.20.0.200` |
| OpenClaw | `openclaw.m01.labs.kurkin-family.ru -> 10.20.0.204` |
| Portainer | `portainer.m01.labs.kurkin-family.ru -> 10.20.0.200` и `10.20.0.204` |
| MetaMCP | `metamcp.m01.labs.kurkin-family.ru -> 10.20.0.200` |

Trusted LAN:

- `10.20.0.0/24`;
- `10.4.0.0/24`.

TLS certificate:

```text
/mnt/storage/certbot-data/live/m01.labs.kurkin-family.ru/fullchain.pem
/mnt/storage/certbot-data/live/m01.labs.kurkin-family.ru/privkey.pem
```

Сертификаты должны быть доступны на обоих Swarm-узлах. Если certbot-data есть только на `ai01`, синхронизировать его на `linux01` до `host-linux01`.

## Wrapper

Для этой инсталляции есть wrapper:

```bash
bash installations/kurkin-family__labs__m01/apply.sh --help
```

Он подставляет:

- `--installation kurkin-family__labs__m01`;
- node/IP/peer-IP;
- оба trusted CIDR;
- дефолтный `--accelerator auto`.

nginx всегда работает в одном режиме — плоский reverse-proxy, без Authentik
forward-auth на этом уровне (LM Studio и OpenClaw не поддерживают внешнюю
аутентификацию — [lmstudio-ai/lmstudio-bug-tracker#1674](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1674)
— сервисы со своим нативным OIDC-логином (OpenWebUI, Portainer,
agentgateway) защищены им самим).

MetaMCP admin UI использует OIDC только для `ai-admins`. Публичный Nginx на
`ai01` возвращает `404` для native registration UI (`/register` и locale
variants) и sign-up API (`/api/auth/sign-up` с дочерними routes); это не
затрагивает OIDC callback или login. Bootstrap admin создаётся напрямую во
внутренней `ai-network`, минуя Nginx. MCP endpoints сохраняют собственную
bearer-key аутентификацию.

Wrapper не делает SSH и не копирует файлы между серверами. Его нужно запускать локально на соответствующем узле из каталога `/home/setup/ai-stand`.

## Рекомендуемый порядок раскатки

На `ai01`:

```bash
cd /home/setup/ai-stand
sudo bash installations/kurkin-family__labs__m01/apply.sh preflight-ai01
sudo bash installations/kurkin-family__labs__m01/apply.sh host-ai01
sudo bash installations/kurkin-family__labs__m01/apply.sh images-ai01
docker swarm join-token manager -q
```

На `linux01`:

```bash
cd /home/setup/ai-stand
sudo bash installations/kurkin-family__labs__m01/apply.sh preflight-linux01
sudo bash installations/kurkin-family__labs__m01/apply.sh host-linux01 --manager-join-token <manager-token>
sudo bash installations/kurkin-family__labs__m01/apply.sh images-linux01
```

Финальный deploy выполнять с `ai01`:

```bash
cd /home/setup/ai-stand
sudo bash installations/kurkin-family__labs__m01/apply.sh deploy
sudo bash installations/kurkin-family__labs__m01/apply.sh configure-portainer
sudo bash installations/kurkin-family__labs__m01/apply.sh verify-ai01
```

`deploy` в wrapper-е сохраняет фиксированный порядок: раскатывает стек,
затем выполняет `configure-authentik` и применяет модельный профиль
(`model-apply`). Поэтому отдельно запускать `configure-authentik` или
`model-apply` после `deploy` не нужно. Следующая отдельная стадия —
`configure-portainer`; когда и как перевыполнить `model-apply` вручную,
см. в разделе «Model profile» ниже. Проверить результат:

```bash
sudo bash installations/kurkin-family__labs__m01/apply.sh model-verify
```

Перед первым rollout с LanceDB выполняется отдельная полная очистка OpenClaw
state. На `ai01` сначала остановить Gateway, на `linux01` — host-level dind,
переместить оба component directory в timestamped backup и создать пустые
`gateway` и `sandbox-dind`; затем снова запустить dind и выполнить штатный
`deploy`. Это не является частью обычного `deploy`, поэтому дальнейшие
раскатки сохраняют новые сессии и LanceDB.

Проверка второго узла:

```bash
sudo bash installations/kurkin-family__labs__m01/apply.sh verify-linux01
```

## Workload layout

`ai01`:

- Authentik PostgreSQL/Redis/Server/Worker;
- LM Studio;
- LM Studio Proxy;
- agentgateway (unified OIDC+RBAC entry point, fronts LM Studio Proxy only — Open WebUI/OpenClaw all call it, not LM Studio Proxy directly);
- Open WebUI;
- MetaMCP + MetaMCP PostgreSQL;
- Portainer Server;
- Portainer Agent;
- native Nginx routes for Authentik, LM Studio, LM Studio Proxy, agentgateway, Open WebUI, MetaMCP and Portainer.

`linux01`:

- OpenClaw Gateway;
- OpenClaw sandbox dind (host-systemd sidecar, not a Swarm service);
- LanceDB long-term memory внутри persistent state OpenClaw;
- Portainer Agent;
- native Nginx routes for OpenClaw and Portainer.

Shannon и LightRAG не входят в текущую инсталляцию. Generic `apply.sh` только удаляет старые Swarm services `ai-stand_shannon` и `ai-stand_lightrag`, если они остались от прошлых раскаток.

## Persistent storage

Используется component layout:

```text
/mnt/storage/lmstudio-data/lmstudio
/mnt/storage/openclaw-data/gateway
/mnt/storage/openclaw-data/gateway/.openclaw/sandboxes
/mnt/storage/openclaw-data/sandbox-dind
/mnt/storage/openclaw-data/gateway/.openclaw/memory/lancedb
/mnt/storage/openwebui-data/server
/mnt/storage/portainer-data/server
/mnt/storage/authentik-data/postgresql
/mnt/storage/authentik-data/redis
/mnt/storage/authentik-data/server/data
/mnt/storage/authentik-data/server/templates
/mnt/storage/authentik-data/icons
/mnt/storage/metamcp-data/postgres
/mnt/storage/agentgateway-data/server
```

`apply.sh host` переиспользует данные и не удаляет их. Старый root-style layout переносится в component dir только если target пустой. Конфликт данных останавливает выполнение. Backup root: `/mnt/storage/_backups`.

Защищённые ручные backup-файлы `openclaw.json.manual-backup-*` могут оставаться
непосредственно в `/mnt/storage/openclaw-data`; `host` сохраняет их и не
считает legacy root-style state.

На `linux01` host-level `openclaw-sandbox-dind` получает только persistent
корень `/mnt/storage/openclaw-data/gateway/.openclaw/sandboxes`, смонтированный
в DIND как `/home/ai/.openclaw/sandboxes`. Поэтому перезапуск Gateway или DIND
не создаёт новый root-owned workspace: Git, `MEMORY.md` и прочие данные
sandbox остаются на storage. В DIND не передаётся полный Gateway home, включая
`openclaw.json` и subscription/OAuth state.

## Model profile

Generic `ai-stand` стартует быстро (chat и embedding выполняются на GPU):

- chat: `qwen/qwen3-1.7b@q8_0`, id `qwen/qwen3-1.7b` (тот же принцип id — см. ниже);
- embedding: `Qwen/Qwen3-Embedding-0.6B-GGUF` Q8, id
  `qwen3-embedding-0.6b-q8`, размерность `1024`.

Профиль `kurkin-family__labs__m01` переключает активные модели:

- chat: `qwen/qwen3.8-27b@q8_0`, id `qwen/qwen3.8-27b` (без `-q8`: `apply-model-profile.sh`
  вычисляет id как всё до `@`, чтобы совпадать с `service-entrypoint.sh`'s
  `LMSTUDIO_MODEL_KEY` — иначе `lms load` показывает одну и ту же модель
  двумя разными строками в `/v1/models`);
- embedding: `Qwen/Qwen3-Embedding-4B-GGUF` Q8, catalog key
  `text-embedding-qwen3-embedding-4b`, API id `qwen3-embedding-4b-q8`,
  размерность `2560`.

Open WebUI показывает только `qwen/qwen3.8-27b`.
Его внутренний RAG использует `qwen3-embedding-4b-q8`, но embedding-модель не
добавляется в chat model picker.

Фоновый каталог загрузок LM Studio (только Q8 — Q4 не используется, квантизация признана
слишком низкого качества, 2026-09-06):

- `Qwen/Qwen3-Embedding-8B-GGUF` Q8;
- `qwen/qwen3.8-27b` Q8;
- `qwen/qwen3.6-35b-a3b` Q8;
- `qwen/qwen3.6-27b` Q8;
- `qwen/qwen3.5-9b` Q8;
- `qwen/qwen3-8b` Q8;
- `qwen/qwen3-4b` Q8;
- `qwen/qwen3-1.7b` Q8.

Context resolver пробует максимум вниз:

- chat: `262144`, `131072`, `65536`, `32768`, `24576`, `16384`, `8192`, `4096`;
- embedding: `32768`, `16384`, `8192`.

`OPENCLAW_MAX_TOKENS` (собственный потолок OpenClaw на один ответ, не то же
самое, что контекст чата) вычисляется из разрешённого контекста чата, а не
перебирается отдельно - см. `openclaw_tokens_for_context()` в
`apply-model-profile.sh`.

Результат сохраняется здесь:

```text
/mnt/storage/lmstudio-data/lmstudio/.ai-stand/kurkin-family__labs__m01/context.env
```

Если нужно пересчитать context policy, удалить только этот state-файл и повторить:

```bash
sudo bash installations/kurkin-family__labs__m01/apply.sh model-apply
```

Не удалять модели и service data.

## OpenClaw memory

`memory-lancedb` — единственный владелец memory slot; встроенный `memory-core`
после переключения не синхронизирует память и не выполняет dreaming-задачи.
LanceDB работает на `linux01`, но embedding запросы всегда проходят
`OpenClaw → agentgateway → lmstudio-proxy → LM Studio` на `ai01`.

Автоматический recall включён, автоматическое сохранение выключено. Для recall
доверенному плагину явно разрешён доступ к текущему диалогу; это не включает
автоматическое извлечение или сохранение фактов. Сохранять факт, предпочтение
или решение нужно явным tool call `memory_store`. База
`/mnt/storage/openclaw-data/gateway/.openclaw/memory/lancedb` принадлежит
новому state; смена модели или размерности в будущем требует её
переиндексации.

## Codex execution

Для `m01` model profile задаёт
`OPENCLAW_CODEX_EXECUTION_PROFILE=autonomous`. Это относится только к
managed Codex plugin/harness в `openclaw-gateway`: entrypoint закреплённо
устанавливает его в persistent state, а profile явно задаёт `yolo`,
`approvalPolicy: never` и отсутствие Guardian model-reviewer с его
30-секундным пределом. Тот же profile задаёт центральную OpenClaw policy
`tools.exec.mode=full` с `strictInlineEval=false`; entrypoint при каждом
старте записывает host approvals `security=full`, `ask=off` и
`askFallback=full`. Поэтому native exec не может неявно вернуться к
Guardian-approval flow. Agentgateway, LM Studio и LanceDB эта настройка не
меняет.

Codex запускается от пользователя `ai` в Gateway-контейнере. У контейнера нет
Docker socket хоста; команда `docker` обращается к
`openclaw-sandbox-dind` по `DOCKER_HOST`, поэтому созданные workload остаются
в изолированном DIND. Взамен доверенный пользователь разрешает Codex без
подтверждения выполнять команды, создавать DIND-контейнеры и читать доступные
пользователю `ai` данные Gateway.

## Smoke checks

```bash
curl --fail https://authentik.m01.labs.kurkin-family.ru/
curl --fail https://lmstudio.m01.labs.kurkin-family.ru/v1/models
curl --fail https://lmstudio-proxy.m01.labs.kurkin-family.ru/v1/models
curl --fail https://agentgateway.m01.labs.kurkin-family.ru/v1/models
curl --fail https://openwebui.m01.labs.kurkin-family.ru/
curl --fail https://openclaw.m01.labs.kurkin-family.ru/healthz
curl --fail https://portainer.m01.labs.kurkin-family.ru/api/status
curl --fail https://metamcp.m01.labs.kurkin-family.ru/health
```

Ожидаемое состояние Swarm:

- replicated services: `1/1`;
- `ai-stand_portainer-agent`: `2/2`;
- LM Studio `/v1/models` содержит `qwen/qwen3.8-27b` и `qwen3-embedding-4b-q8`;
- с trusted LAN доступны только `80/443`;
- technical ports закрыты: `1234`, `11234`, `18789`, `9443`, `18080`, `19001`, `9001`, `12008`, `4000` (все уже входят в `TECH_PORTS` в `apply.sh`, этот список — только для ручной сверки).
