# Автоматический wildcard-сертификат

Сертификат `*.<CERT_DOMAIN>` + `<CERT_DOMAIN>` получается и продлевается по DNS-01 без участия человека.

```
ai01: контейнер controller, задание certbot (дважды в сутки)
        └─ renew.sh ── docker run certbot/certbot ── --manual-auth-hook / --manual-cleanup-hook
        │                                             └─ DNS-хук установки (m01: Selectel DNS Hosting API v2)
        └─ проверки (SAN, срок, ключ↔сертификат)
        └─ хост ai01: ai-stand-nginx-reload.path → nginx -t → reload → запись отпечатка в .served-fingerprint
        └─ renew.sh ждёт, пока nginx не покажет новый отпечаток
        └─ tar archive/<домен> + live/<домен> ── PUT http://cert-receiver:8443/v1/certificate (оверлей, bearer-токен)
                                                  ──► ai02: контейнер cert-receiver → receive-cert.sh
                                                      └─ те же проверки → замена каталогов
                                                      └─ хост ai02: тот же path-юнит → reload → отпечаток
                                                      └─ receive-cert.sh ждёт отпечаток, иначе возвращает прежний сертификат
```

Один certbot на ai01 (один аккаунт ACME, один запрос в DNS на выпуск). На хостах остался только path-юнит
`ai-stand-nginx-reload.{path,service}` (его ставит стадия `host`, шаблон в `nginx/`): контейнеры не могут дотянуться до
nginx хоста, поэтому хост сам перезагружает nginx после смены каталога `live/` и записывает отпечаток отдаваемого
сертификата в `$CERTBOT_DATA/.served-fingerprint` (юнит подключается к 127.0.0.1:443 с SNI `$PORTAINER_HOST` профиля: сервер по умолчанию отвергает незнакомые имена, а это имя обслуживают оба узла). Скрипты ждут, пока запись совпадёт с только что установленным
сертификатом: это и есть доказательство, что nginx принял и отдаёт его. Ключей SSH, `authorized_keys` и forced command
больше нет.

Приёмник принимает загрузку только с bearer-токеном из Docker secret `ai-stand-certbot-receiver-token` (хостовый файл
`${STORAGE_ROOT}/_secrets/certbot-receiver-token`, создаёт `apply.sh`) и сам проверяет имена файлов, ссылки, срок (≥30 дней),
SAN, пару ключ↔сертификат и **цепочку до доверенного CA** (самоподписанный сертификат отвергается). Скрипты `renew.sh`,
`receive-cert.sh`, `served.sh` вшиты в образ `controller`, чтобы проверки приёмника не зависели от изменяемой рабочей копии.

Пока файла с учётными данными DNS нет, `renew.sh` при сроке сертификата меньше 21 дня завершается ошибкой (задание
`certbot` в журнале контроллера), иначе сообщает, что автоматика неактивна. `verify` и `host` предупреждают при остатке
меньше 21 дня. Образ контроллера, сервисы и юниты ставятся/деплоятся стадиями `images`, `host`, `deploy`.

## Первое включение (профиль `kurkin-family__labs__m01`, DNS-зона у Selectel)

1. В панели Selectel создать **сервисного пользователя** с доступом к проекту, где лежит зона `kurkin-family.ru`
   (права на DNS-хостинг этого проекта), и записать номер аккаунта, имя пользователя, пароль и **id** проекта (допустимо вместо id указать имя в `SELECTEL_PROJECT`).
2. На ai01 создать файл `${STORAGE_ROOT}/_secrets/certbot-dns-selectel` (root, `0600`):

   ```
   SELECTEL_ACCOUNT_ID=<номер аккаунта>
   SELECTEL_USER=<сервисный пользователь>
   SELECTEL_PASSWORD=<пароль>
   SELECTEL_PROJECT_ID=<id проекта>
   ```
3. `images-ai01`, `images-ai02`, `host-ai01`, `host-ai02`, `deploy`: собирают образ `controller`, ставят path-юнит nginx и
   запускают сервисы `controller` (ai01) и `cert-receiver` (ai02).
4. **Репетиция** на staging Let's Encrypt (создаёт и удаляет TXT-записи, ничего не меняет на диске):
   `docker exec $(docker ps -q -f name=ai-stand_controller) bash /opt/controller/certbot/renew.sh --dry-run`.
5. Боевой переход с ручного выпуска на выпуск через хук и раздача на ai02:
   `docker exec … bash /opt/controller/certbot/renew.sh --issue --force`.
6. Проверка: `openssl s_client -connect <узел>:443 -servername authentik.<домен> </dev/null | openssl x509 -noout -dates -ext subjectAltName`
   на обоих узлах; в зоне не осталось `_acme-challenge` (кроме чужих записей); `docker service logs ai-stand_controller`.

## Что проверено

Тесты: `python -m unittest installations/<профиль>/certbot/test_selectel_dns_hook.py` (хук против имитации Selectel и DNS:
выбор самой длинной зоны, apex и wildcard в одном наборе записей, чужие значения не трогаются, NS берутся из зоны,
скоуп проекта по id или по имени, повтор при сетевых сбоях, только IPv4, ошибки без утечки пароля),
`sudo bash certbot/test-certbot-scripts.sh` (оба скрипта целиком с заглушками docker/curl и имитацией хостового юнита:
проверки приёмника, откат, если nginx не отдаёт сертификат, повтор раздачи, токен только через файл заголовка, отказ при
пропавших учётных данных или если nginx этого узла не отдаёт новый сертификат) и
`python -m unittest docker/controller/test_controller.py` (планировщик заданий и HTTP-приёмник).

Репетиция `renew.sh --dry-run` против настоящего Selectel и staging Let's Encrypt на m01 (2026-10-23) прошла: хук
аутентифицируется сервисным пользователем, находит зону, добавляет и убирает значения, ждёт серверы зоны. Что она показала
(всё учтено в хуке):

- публикация изменений у Selectel неровная: первое значение видно на серверах зоны примерно через минуту, второе, добавленное
  сразу после него (wildcard к apex), может появиться через несколько минут; поэтому ожидание по умолчанию 10 минут;
- серверы имён берутся из NS-записей зоны (`a-d.ns.selectel.ru`), а не из зашитого списка;
- LAN-резолвер отвечает REFUSED на AAAA-запрос к `cloud.api.selcloud.ru`, а образ certbot на musl из-за этого проваливает весь
  поиск имени (`Errno -3 Try again`); хук резолвит только IPv4. Если те же симптомы появятся у других контейнеров,
  причина в этом резолвере.

## Запасной путь: выпуск вручную

Пока автоматика не включена (или если она сломана): `Инфраструктура/certbot-as-code/exec-dns.sh m01.labs.kurkin-family.ru`
на ai01 (две TXT-записи `_acme-challenge` вручную в панели Selectel), затем отправить `archive/` и `live/` на ai02 тем же
запросом, что делает `renew.sh`: `tar -C ${STORAGE_ROOT}/certbot-data -cf - archive/<домен> live/<домен> | curl --fail-with-body
-X PUT -H 'Content-Type: application/x-tar' -H "Authorization: Bearer $(cat ${STORAGE_ROOT}/_secrets/certbot-receiver-token)"
--data-binary @- http://cert-receiver:8443/v1/certificate` (из контейнера в сети `ai-core`), или скопировать каталоги вручную
и выполнить `nginx -t && systemctl reload nginx` на обоих узлах.

## Если что-то пошло не так

- `docker service logs ai-stand_controller` (строки `[certbot] …`) — вывод `renew.sh` и хука; пароль в него не попадает.
  На ai02 — `docker service logs ai-stand_cert-receiver`.
- «nginx … did not start serving the new certificate»: смотрите `systemctl status ai-stand-nginx-reload.service` и
  `journalctl -u ai-stand-nginx-reload.service` на этом узле: скорее всего `nginx -t` отверг конфигурацию.
- Ошибка «could not hand the certificate to …»: ai01 уже обслуживает новый сертификат; следующий запуск задания (или
  `renew.sh`) повторит передачу — отметка `distributed.sha256` в `${STORAGE_ROOT}/ai-stand-data/certbot/` обновляется только
  после успеха.
- Остатки TXT после аварии хука: хук удаляет только своё значение; чужие значения в `_acme-challenge.<домен>` не мешают
  выпуску и не трогаются.
- Откат приёмника: прежний каталог лежит рядом как `archive/.<домен>.before-<время>` и `live/.<домен>.before-<время>`.
