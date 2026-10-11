# ai-stand

Лёгкая лаборатория для разработки и опытов с AI-сервисами. Это не промышленная среда: общие сервисы используются совместно, а пользовательские данные и credentials разделены по владельцам.

## Компоненты

**Общие:** Authentik — вход и группы; Agentgateway — маршрутизация моделей и MCP; llama.cpp — chat и embeddings (отдельные серверы, напрямую за Agentgateway); Open WebUI; OpenClaw — один общий Gateway с общим sandbox, памятью LanceDB, Codex/Claude-подписками и OAuth для всех пользователей группы `ai-users` (вход через Authentik, изоляции данных между пользователями внутри OpenClaw нет — решение владельца для лаборатории); Coder (встроенный provisioner работает через ограниченный docker-socket-proxy); Gitea; read-only MCP; Portainer; PostgreSQL/Redis.

**Персональные:** Coder workspace и home; SSH-ключ пользователя и доступ к собственным проектам Gitea. Профили могут предоставлять разные наборы моделей и подписок.

```mermaid
flowchart LR
  U[Пользователь] --> A[Authentik]
  subgraph Shared[Общие компоненты]
    A[Authentik]
    AG[Agentgateway]
    OW[Open WebUI]
    C[Coder control plane]
    G[Gitea]
    MCP[Read-only MCP]
    M[llama.cpp: chat и embeddings]
    P[Профиль установки моделей]
    PT[Portainer]
    DB[PostgreSQL / Redis]
    O[OpenClaw Gateway]
    S[OpenClaw sandbox]
    L[LanceDB / память]
  end
  subgraph Personal[На каждого пользователя]
    W[Coder workspace / home]
    K[SSH-ключ]
  end
  A --> O
  A --> OW
  A --> C
  O --> S
  O --> L
  O --> AG
  OW --> AG
  W --> AG
  W --> G
  W --> K
  AG --> M
  P --> M
  AG --> MCP
  A --> DB
  C --> DB
  G --> DB
  PT -. администрирование .-> C
  PT -. администрирование .-> O
```

Сетевой ingress (Nginx) в логической схеме опущен, но остаётся частью установки. Codex/Claude-подписки OpenClaw общие; корпоративные MCP включаются только при наличии пользовательских credentials.

## Развёртывание

Generic-модуль находится в этом каталоге и не содержит значений площадки: имена, адреса, домен, часовой пояс, модели, флаги подсистем задаёт `installations/<profile>/installation.sh`, а `apply.sh` читает их как переменные (при загрузке профиля проверяется, что `INSTALLATION_NAME` совпадает с именем каталога, а все публичные имена лежат под `CERT_DOMAIN`). Секреты, runtime state и пользовательские данные в Git не хранятся. Справочник переменных профиля, предусловия, порядок раскатки с нуля и создание новой инсталляции — в [INSTALLATION.md](INSTALLATION.md).

Для `kurkin-family__labs__m01` сначала посмотрите доступные команды:

```sh
cd ai-stand
bash installations/kurkin-family__labs__m01/apply.sh --help
```

Профильный wrapper задаёт узлы, сеть, ускорители и значения модели; общий `apply.sh` содержит повторно используемые stages. Раскатка модели выполняется отдельно от полного deploy:

```sh
bash installations/kurkin-family__labs__m01/apply.sh model-catalog-ai01
bash installations/kurkin-family__labs__m01/apply.sh model-catalog-ai02
bash installations/kurkin-family__labs__m01/apply.sh model-apply
bash installations/kurkin-family__labs__m01/apply.sh model-verify
```

## Хранилище

Все данные на хостах лежат в `<корень хранилища>/<компонент>-data/<часть>` (плюс `_secrets` и `_backups`). Корень хранилища — свойство инсталляции: `STORAGE_ROOT` в её `installation.sh` (на m01 `/mnt/storage`). Нигде в репозитории он не прописан литералом: `apply.sh` выводит все пути из него (`define_storage_paths`) и экспортирует `STORAGE_ROOT`, compose-файлы берут источники монтирования из `${STORAGE_ROOT}`, сайты nginx содержат `@STORAGE_ROOT@` и при установке получают значение, обёртка инсталляции и Python-помощники (`model-migration`, `model-catalog`, `docker/openwebui/model_access_snapshot.py`, контроллер) читают его из окружения. Исключение одно, и это сам умолчательный корень `/mnt/storage` в начале `apply.sh` на случай профиля без `STORAGE_ROOT`. Что лежит вне профиля и репозитория — например файл `reconciler.json` с путём к токену и cron-скрипты владельца — ведётся им самим и должно совпадать с корнем.

## Сертификат

Wildcard-сертификат продлевается автоматически по DNS-01 (задание `certbot` контейнера `controller` на ai01, раздача на ai02 сервису `cert-receiver`); порядок первого включения,
репетиция на staging Let's Encrypt и запасной ручной путь описаны в [certbot/README.md](certbot/README.md).

## Контроллер (повторяющиеся задания)

Три бывших хостовых systemd-таймера — reconciler MCP и Telegram (`reconcile`), доступ к моделям Open WebUI (`model-access`) и продление сертификата (`certbot`) — выполняет один контейнер `controller` на ai01; приёмник сертификата `cert-receiver` работает на ai02. На хостах остался только path-юнит `ai-stand-nginx-reload` (nginx живёт на хосте). Устройство, эксплуатация и подмонтированные ресурсы — в [docker/controller/README.md](docker/controller/README.md). Сервисы разворачивает общий `deploy`, а отдельно (не затрагивая остальные сервисы) — стадия `deploy-controller`; прежние таймеры убирают `cleanup-legacy-host-timers-ai01` и `-ai02` (только после того, как каждое задание отработало).

## Доступ к LLM API без административных прав

Клиенты вроде OpenCode ходят прямо в Agentgateway (`https://<AGENTGATEWAY_HOST>/v1`, OpenAI-совместимый API). Токен получает сам пользователь группы `ai-users`, администратор и деплой для этого не нужны:

1. В Authentik: настройки пользователя → **Tokens and App passwords** → создать токен с назначением **App password**. Отозвать пароль можно там же.
2. Обменять логин и App password на JWT у провайдера `ai-stand-llm` (Authentik, grant `client_credentials`). Срок жизни JWT — 30 дней, повторить обмен по истечении:

   ```powershell
   $r = Invoke-RestMethod -Method Post -Uri 'https://<AUTHENTIK_HOST>/application/o/token/' -Body @{
     grant_type = 'client_credentials'; client_id = 'ai-stand-llm'
     username = '<логин Authentik>'; password = '<App password>'; scope = 'openid profile email' }
   [Environment]::SetEnvironmentVariable('AI_STAND_API_KEY', $r.access_token, 'User')
   ```

   Тот же обмен через curl: `curl -s -d grant_type=client_credentials -d client_id=ai-stand-llm -d username=<логин> --data-urlencode password=<App password> -d 'scope=openid profile email' https://<AUTHENTIK_HOST>/application/o/token/`, нужное значение — поле `access_token`.
3. Передавать значение клиенту как `Authorization: Bearer ...` (в OpenCode — `apiKey` из переменной `AI_STAND_API_KEY`).

Agentgateway пускает запрос со статическим ключом сервиса (Open WebUI, OpenClaw, Coder) или с JWT пользователя из `ai-users`; администратор без членства в `ai-users` LLM API не получает. Учёт токенов (`request_logs`, Analytics в UI Agentgateway для `ai-admins`) ведётся по email из JWT, для Open WebUI — по email вошедшего пользователя, для остальных сервисов — по имени ключа.

Ограничения: JWT самодостаточен, поэтому удаление App password или отключение пользователя не отзывает уже выданный токен до истечения срока (30 дней); нужно удалить пользователя из `ai-users` и дождаться срока либо сменить ключ подписи провайдера. Токен — секрет: не вставляйте его в чаты, issue и репозиторий. Публичные ключи подписи хранятся в окружении сервиса `agentgateway` (`LLM_AUTHENTIK_JWKS`) и обновляются стадиями `deploy` и `configure-authentik`; `verify` сравнивает их с Authentik.

## Telegram-бот OpenClaw

Всё, кроме токена бота, хранится в Authentik и применяется само; с нуля руками остаются создание бота и группы в Telegram и токен.

**Люди.** Пользователь из `ai-users` открывает настройки профиля в Authentik и заполняет поле **Telegram user ID (numeric)** — числовой ID (его показывает, например, @userinfobot), а не @username. Изменение вступает в силу примерно через десять минут.

**Владелец и группы.** Это атрибуты одной учётной записи — владельца Telegram (по умолчанию `akadmin`, другое имя задаётся ключом `authentik.telegramOwner` в `reconciler.json`; учётная запись должна быть активным суперпользователем, иначе она не считается):

- `ai_stand_telegram_user_id` — Telegram ID владельца. Он становится `commands.ownerAllowFrom` (команды владельца: `/config`, `/restart`, `/update`, подтверждения exec) и всегда входит в список допущенных.
- `ai_stand_telegram_groups` — группы бота, объект `{"<id группы>": {"requireMention": true, "topics": {"<id темы>": "<id агента>"}}}`. Задаётся в админке Authentik: Каталог → Пользователи → владелец → Атрибуты (YAML или JSON). Идентификатор группы отрицателен (`-100…`), тема `"*"` — все остальные темы форума, `requireMention` по умолчанию `true`, темы необязательны. Пример для m01: группа `-1004424854981` с темами 5 → `codex`, 7 → `main`, 9 → `claude`. Атрибут нельзя править из пользовательской самообслуживаемой формы: источник — только учётная запись владельца, значения других пользователей игнорируются.

Путь значений: reconciler (`readonly-mcp/reconcile.py`, задание `reconcile` контейнера `controller` на ai01, раз в пять минут) читает атрибуты и кладёт в манифест `telegram.userIds`, `telegram.ownerIds` и `telegram.groups`; `apply.sh reconcile-mcp` передаёт их сервису `openclaw-gateway` в переменных `OPENCLAW_TELEGRAM_ALLOW_FROM`, `OPENCLAW_TELEGRAM_OWNER_IDS`, `OPENCLAW_TELEGRAM_GROUPS`; `docker/openclaw/init.mjs` при каждом старте записывает канал целиком: `channels.telegram` (включён, личные сообщения выключены, `groupPolicy: allowlist`, группы с темами и допущенными, `tokenFile`), привязку всех чатов Telegram к агенту `main` (темы направляют к своим агентам) и владельца. Группа, убранная из атрибута, убирается и из OpenClaw. Если атрибут групп не задан или не проходит проверку (неверный ID группы, неизвестная настройка, плохое имя агента), reconciler его не передаёт, и OpenClaw остаётся как есть; состояние видно в журнале задания `reconcile` (`telegram-groups-checked`). Пустой объект `{}` — осознанное «групп нет».

**Токен бота** Authentik не хранит. Положите токен (одну строку, как его выдал BotFather) в `${STORAGE_ROOT}/_secrets/openclaw-telegram-bot-token` на ai02 (root, права `0600`) и запустите `host-ai02`: стадия проверит формат и скопирует токен в `${STORAGE_ROOT}/openclaw-data/gateway/.openclaw/telegram-bot-token` для Gateway, где `init.mjs` укажет на него `channels.telegram.tokenFile` и уберёт `botToken` из конфигурации. Пока токена нет, канал не включается (в журнале Gateway предупреждение).

К ID из Authentik добавляются «статические» ID из файла `~/.openclaw/telegram-static-allow-from.json` в домашнем каталоге Gateway (JSON-массив строк; на m01 — `${STORAGE_ROOT}/openclaw-data/gateway/.openclaw/`). Файл необязателен: он нужен только для людей без аккаунта в Authentik. ID из файла остаются разрешёнными, даже если убрать его из атрибута, поэтому для тех, у кого аккаунт есть, держите ID только в атрибуте. Список допущенных задаёт и допуск к обычным командам бота (`/status`, `/model`, …): `init.mjs` записывает его в `commands.allowFrom.telegram`.

Что делать на новой площадке: создать бота в BotFather, создать форумную группу с темами и добавить в неё бота, узнать ID группы и тем (например, из журнала Gateway после первого сообщения), записать атрибуты владельца в Authentik, положить токен и выполнить `host-ai02`. Пока `OPENCLAW_TELEGRAM_GROUPS` пуста, `init.mjs` только обновляет списки допущенных уже настроенного канала — как раньше.

Каждое изменение набора ID, владельца или групп перезапускает Gateway OpenClaw (около 3–4 минут, идущие ответы прерываются) и Agentgateway: так работает любое изменение манифеста reconciler.

## SSH-ключи в Gitea

Сервис `gitea-ssh-sync` (`docker/gitea-ssh-sync`, обычный сервис Swarm на узле Gitea) раз в минуту читает членов `ai-users` и регистрирует публичный SSH-ключ каждого в его аккаунте Gitea, чтобы `git push` по SSH работал без ручной загрузки ключей. Пользователь вставляет **публичный** ключ (одна строка `ssh-ed25519 …`, например содержимое `id_ed25519.pub`) в поле **Personal Gitea SSH public key** в Authentik (Settings → User details → Update details); пустое поле удаляет ключ из Gitea. Поля с приватным ключом и паролем сервис не читает: их доставляет в Coder отдельный сервис `ssh-key-delivery` (см. ниже).

Сервис трогает только ключи с заголовком `ai-stand personal SSH <логин>`; ключи, добавленные пользователем вручную, не изменяются и не «усыновляются». Аккаунт Gitea находится по связи OIDC (в `login_name` Gitea хранит UUID пользователя Authentik) и должен совпадать с именем в Authentik; локальные аккаунты Gitea сервису не видны. Недопустимое значение (опечатка, вставленный приватный ключ) только фиксируется в логе и не удаляет уже зарегистрированный ключ. Участник, который ещё не входил в Gitea, подхватывается после первого входа.

Учётные данные — два Docker secret: токен служебной учётной записи Authentik с правами только на чтение пользователей и групп и токен отдельного локального администратора Gitea без пароля (более узкого токена для чужих ключей в Gitea нет). Выпуск и развёртывание выполняет стадия `configure-gitea-ssh-sync` (после `configure-gitea`; профиль включает её через `GITEA_SSH_SYNC_ENABLED=1`, `GITEA_SSH_SYNC_APPLY=0` переводит сервис в режим «только план»). Сервис разворачивается отдельно от общего `deploy` (`compose.gitea-ssh-sync.yaml`), потому что его секреты создаются только после запуска Authentik и Gitea. Состояние на хосте не хранится; журнал — `docker service logs ai-stand_gitea-ssh-sync`. Предыдущая версия сервиса (systemd-таймер, неизменяемый снимок кода в `/usr/local/libexec/ai-stand/source`, корневые каталоги токенов) удаляется командой `cleanup-legacy-gitea-ssh-sync` после того, как новый сервис отработал.

## Приватный SSH-ключ в Coder

Пользователь вставляет **приватный** ключ (весь блок `-----BEGIN OPENSSH PRIVATE KEY-----`, только `ssh-ed25519`) в поле **Personal Gitea SSH private key** в Authentik, а для зашифрованного ключа — пароль в поле **SSH key passphrase**. Сервис `ssh-key-sender` (узел Authentik, `docker/ssh-key-delivery`) раз в минуту читает члены групп `ai-users` и `ai-admins`, проверяет ключи и передаёт их по шифрованной оверлейной сети сервису `ssh-key-receiver` на узле Coder; тот кладёт ключ владельца в каталог `<корень хранилища>/ssh-key-delivery-data/users/<логин>` (каталог 0700, файлы 0400; корень хранилища — `STORAGE_ROOT` профиля инсталляции), а шаблоны Coder монтируют только этот каталог, только для чтения, в workspace владельца и настраивают `ssh` (GIT_SSH_COMMAND=`ssh`, ключ остаётся на смонтированном томе и не копируется в домашний каталог). У приёмника нет учётных данных Authentik. Недопустимое значение не затирает доставленный ключ; пустое поле, отключённая учётная запись или выход из групп убирают ключ. Развёртывание — стадия `configure-ssh-key-delivery` (профиль включает её через `SSH_KEY_DELIVERY_ENABLED=1`; путь к ключам шаблоны получают переменной `ssh_keys_root` при публикации), отдельно от общего `deploy` (`compose.ssh-key-delivery.yaml`). Подробности и ограничения — [docker/ssh-key-delivery/README.md](docker/ssh-key-delivery/README.md).

## SSH-ключ OpenClaw

Для самого шлюза OpenClaw (не для людей) тем же конвейером `ssh-key-delivery` доставляется отдельный **выделенный** ключ служебной учётной записи Authentik `ai-stand-openclaw-bot` (`SSH_SERVICE_ACCOUNTS` в `apply.sh`; учётная запись без группы и без входа). Руками ничего делать не нужно: `configure-ssh-key-delivery` создаёт учётную запись и, если у неё нет ключа, генерирует в самом Authentik пару Ed25519 (без пароля) в атрибутах `ai_stand_git_ssh_private_key` / `ai_stand_git_ssh_public_key` — приватная часть не попадает ни в консоль, ни в журнал, ни в файл; существующий ключ никогда не заменяется (для ротации очистите оба атрибута в Authentik и повторите стадию). `configure-gitea-ssh-sync` создаёт одноимённый локальный аккаунт Gitea (без пароля, не администратор), а `gitea-ssh-sync` регистрирует в нём публичную часть. Остаётся решить, к каким репозиториям у этого аккаунта есть доступ (добавьте его соавтором). Через минуту после изменения ключ лежит у Gateway только для чтения в `/run/ai-stand/ssh`, `ssh` в образе настроен на него. Песочницы OpenClaw без сети, поэтому ключ нужен работе самого Gateway, а не инструментам в песочнице. Подробности — [docker/ssh-key-delivery/README.md](docker/ssh-key-delivery/README.md).

## Профиль моделей

`model-catalog/catalog.lock.json` фиксирует источники, версии, quantization и SHA-256 моделей. В каталоге установки выбираются accelerator/GFX, активные модели, контекст и параметры backend. Для новой лаборатории добавьте отдельный профиль, не изменяя generic defaults и не копируя secrets. `model-catalog/README.md` описывает формат каталога.

## Эксперименты

В `EXPERIMENTS.md` записываются только результаты, которые приняты и отражены в конфигурации: дата, цель, версия/модель, применённое решение. Промежуточные прогоны, сырые логи, prompts, ответы и пользовательские данные в репозитории не сохраняются.
