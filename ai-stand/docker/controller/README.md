# Контроллер ai-stand

Один образ вместо трёх хостовых systemd-таймеров и их скриптов в `/usr/local/libexec/ai-stand`. Режимы (`CMD`):

- **`run`** (сервис `controller`, ai01) — запускает задания из `CONTROLLER_JOBS`, каждое в своём потоке, со своим интервалом
  и тайм-аутом (при превышении убивается вся группа процессов):

  | задание | что делает | интервал |
  |---|---|---|
  | `reconcile` | `readonly-mcp/reconcile.py`: атрибуты пользователей Authentik → MCP-сервисы Jira/Confluence/IMAP, список Telegram для OpenClaw (`apply.sh reconcile-mcp`) | 5 мин |
  | `model-access` | `docker/openwebui/model_access_snapshot.py --apply`: доступ к моделям Open WebUI по группам OIDC | 5 мин |
  | `certbot` | `certbot/renew.sh`: продление wildcard-сертификата и передача на другой узел | 12 ч |

  Задание, у которого нет входного файла (например, нет `reconciler.json`), пропускается, а не падает.
- **`receive`** (сервис `cert-receiver`, ai02) — HTTP-приёмник `PUT /v1/certificate` для обновлённого сертификата
  (`certbot/receive-cert.sh`, bearer-токен из Docker secret). Docker-сокета у него нет.
- **`healthcheck`** — 0, пока процесс жив и обновляет отметку.

## Что смонтировано и почему

`controller` получает Docker-сокет (создаёт Docker secrets и сервисы, запускает стадии `apply.sh` и соседний контейнер
certbot), корень хранилища `${STORAGE_ROOT}` (по тому же пути, что на хосте; его значение контейнеру передаёт compose), `/run/lock` (замки `apply.sh` и reconciler общие с запусками оператора на хосте) и рабочую копию
репозитория **только для чтения по тому же пути, что на хосте** (`apply.sh` вычисляет все пути от своего расположения;
`reconcile-mcp` проверяет наличие каталогов исходников MCP-образов). Это та же власть, что была у таймеров от root, поэтому у
контейнера нет опубликованных портов и корневая файловая система только для чтения. Скрипты certbot вшиты в образ.

На хосте от всей автоматики остаётся один path-юнит `ai-stand-nginx-reload.{path,service}` на узел (nginx живёт на хосте).

## Эксплуатация

```
docker service logs ai-stand_controller --tail 50          # строки [reconcile] …, [model-access] …, [certbot] …, JSON-события
docker service logs ai-stand_cert-receiver --tail 20       # на ai02
python -m unittest docker/controller/test_controller.py    # без сети и Docker (POSIX)
```

Задания можно запустить вручную в работающем контейнере, например
`docker exec $(docker ps -q -f name=ai-stand_controller) python3 /home/setup/ai-stand/readonly-mcp/reconcile.py …`.
Образ собирает стадия `images` (`build_controller_image`), сервисы разворачивает `deploy` либо, отдельно и не затрагивая остальные сервисы стека, стадия `deploy-controller` (на ai01; её же запускают при смене `CONTROLLER_IMAGE_VERSION`). Старые таймеры убирает команда
`cleanup-legacy-host-timers-ai01` / `-ai02` — только после того, как каждое включённое задание успешно отработало.
