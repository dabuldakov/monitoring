# Деплой и переезд со старого расположения

Стек наблюдаемости раньше жил в репозитории `loadtest` и разворачивался в
`/opt/loadtest` на машине мониторинга. Сейчас его место — этот репозиторий и
каталог `/opt/monitoring`. Ниже — порядок переезда; он же пригодится, когда
будешь добавлять новый сервер.

Имена томов в `docker-compose.yaml` зафиксированы (`loadtest_*`), поэтому
при переезде **история метрик и логов сохраняется** — не запускай
`docker compose down -v`, если не хочешь всё потерять.

## Что должно получиться

```
89.104.66.226  /opt/monitoring   Prometheus, Alertmanager, blackbox, Grafana, Loki
               /opt/promtail     promtail: wcm живёт на этом же хосте
               node_exporter     метрики самого себя (127.0.0.1:9101)
               apps-tunnel       SSH-туннели к 168.222.194.206
               akm-tunnel        SSH-туннель к 90.188.89.63
               k6-rw-tunnel      обратный SSH-туннель: k6-метрики в Prometheus

168.222.194.206                  chat, makeup + promtail + node_exporter

90.188.89.63                    gitlab и прочее + node_exporter (без promtail —
                                Loki туда не доставить, логи не нужны)
                                + генератор нагрузки k6 (репозиторий loadtest)
```

Promtail нужен на двух хостах: на `168.222.194.206` (chat, makeup) и на самом
хосте мониторинга (wcm). На машине мониторинга Loki доступен напрямую, без
туннеля, поэтому `install-promtail.sh` там отработает с первого раза.

## Шаг 1. Доступ по ключу с машины мониторинга на сервер приложений

Без этого туннели не поднимутся.

```bash
# на 89.104.66.226
ssh-keygen -y -f /root/.ssh/id_ed25519
```

Добавь полученную строку в `/root/.ssh/authorized_keys` на `168.222.194.206`
(рядом с ключом `github-actions-deploy` и ключом ноутбука) и проверь:

```bash
ssh -o BatchMode=yes root@168.222.194.206 hostname
```

## Шаг 2. Агенты на сервере приложений

Скопируй скрипты с машины мониторинга (или со своей) и запусти:

```bash
scp server/install-node-exporter.sh server/install-promtail.sh root@168.222.194.206:/root/
ssh root@168.222.194.206
  ./install-node-exporter.sh     # -> 127.0.0.1:9100
  ./install-promtail.sh          # -> /opt/promtail, логи в 127.0.0.1:3100
```

`install-promtail.sh` предупредит, если Loki на `127.0.0.1:3100` недоступен —
на этом шаге так и будет, туннели ещё не подняты. Это нормально, вернись сюда
после шага 3.

На самой машине мониторинга promtail тоже нужен — там живёт wcm:

```bash
cd /opt/monitoring
PROMTAIL_DIR=/opt/promtail ./server/install-promtail.sh
```

Loki тут локальный, скрипт отработает сразу. Контейнеры самого стека
мониторинга в сбор логов не попадают: в `promtail/promtail.yml` для этого есть
`monitoring-*` в drop-регексе, иначе promtail на хосте мониторинга собирал бы
логи самого себя.

Если скрипт запускается на хосте, где у контейнеров уже накопился большой буфер
логов (например, при переезде promtail на существующий хост), Loki отклонит
старые записи как `400 entry too far behind`, и весь батч не пройдёт. Лечится
посевом positions на «сейчас», чтобы promtail не переигрывал старый буфер:

```bash
docker stop promtail
NOW=$(date +%s)
{ echo positions:; docker ps -q --no-trunc | while read id; do
    echo "  cursor-$id: \"$NOW\""; done; } > /opt/promtail/positions/positions.yaml
docker start promtail
```

Идентификаторы нужны полные: `docker ps -q` без `--no-trunc` даёт 12 символов,
а promtail ключует курсоры по полным 64, и посев не подействует.

## Шаг 3. Новый каталог на машине мониторинга

```bash
git clone <repo> /opt/monitoring && cd /opt/monitoring
cp /opt/loadtest/.env .env       # переносим SMTP-реквизиты и секреты как есть
```

Поправь в `.env`:

```diff
- MAKEUP_BASE_URL=http://90.188.89.63:8085
- CHAT_BASE_URL=http://90.188.89.63:8086
- SSH_TARGET=dmitry_buldakov@90.188.89.63
- WCM_BASE_URL=http://127.0.0.1:8087
+ APPS_HOST=168.222.194.206
+ WCM_HOST=89.104.66.226
+ AKM_HOST=90.188.89.63
+ APPS_SERVER_NAME="Muzea"
+ WCM_SERVER_NAME="WCM Loadtest Monitoring"
+ AKM_SERVER_NAME="AKM Gitlab"
+ MAKEUP_PORT=8085
+ CHAT_PORT=8086
+ WCM_PORT=8087
+ GRAFANA_BIND_ADDR=0.0.0.0     # Grafana должен быть доступен снаружи
```

`*_SERVER_NAME` — отображаемые имена, они попадают в `instance` для `job=node`
и в лейбл `server` у blackbox-задач. По ним подписаны панели дашбордов и тема
письма об аварии, поэтому в письме видно, чей сервер упал, а не IP.

**Кавычки обязательны**, если в имени есть пробелы: `render.sh` делает
`source .env`, и без кавычек `WCM_SERVER_NAME=WCM Loadtest Monitoring`
превратится в попытку выполнить команду `Loadtest`, а переменная станет `WCM`.
`render.sh` печатает итоговые значения и падает на пустой переменной, но
обрезанное имя он не поймает — поэтому печатает.

`GRAFANA_BIND_ADDR` заменил `docker-compose.override.yaml`, который на старом
хосте переопределял compose. Override больше не нужен.

Пароль Grafana и SMTP-реквизиты в `.env` не коммитятся.

## Шаг 4. Туннели

```bash
cp server/tunnels/apps.service /etc/systemd/system/apps-tunnel.service
cp server/tunnels/akm.service  /etc/systemd/system/akm-tunnel.service
cp server/tunnels/k6-rw.service /etc/systemd/system/k6-rw-tunnel.service
cp server/tunnels/k6-wcm.service /etc/systemd/system/k6-wcm-tunnel.service
systemctl daemon-reload
systemctl enable --now apps-tunnel akm-tunnel k6-rw-tunnel k6-wcm-tunnel

# старый юнит дублирует akm-tunnel — выключаем
systemctl disable --now node-exporter-tunnel
```

`k6-rw-tunnel` нужен только если нагрузка генерируется на `90.188.89.63`.
Это обратный туннель: на akm появляется `127.0.0.1:9090`, идущий в Prometheus,
поэтому генератор шлёт метрики по дефолтному `K6_PROMETHEUS_RW_SERVER_URL`
и настраивать ничего не нужно. Проверка:

```bash
# на машине мониторинга
systemctl is-active k6-rw-tunnel

# с akm: порт слушает и отвечает (400 — пустое тело, ожидаемо)
ssh -p 2222 dmitry_buldakov@90.188.89.63 \
  'ss -tln | grep 9090; curl -s -o /dev/null -w "%{http_code}\n" -XPOST http://127.0.0.1:9090/api/v1/write'
```

`k6-wcm-tunnel` — то же для бэкенда wcm, который закрыт снаружи. Нужен
нагрузочным тестам: без него сценарий wcm на akm не достучится до API.
Заголовок `X-WCM-Client` обязателен, иначе `FrontendAccessFilter` даёт 403.

```bash
ssh -p 2222 dmitry_buldakov@90.188.89.63 \
  'curl -s -o /dev/null -w "%{http_code}\n" -H "X-WCM-Client: wcm-frontend" \
     http://127.0.0.1:8087/api/wcm/v0/country/all'   # ожидается 200
```

Health-check wcm в Prometheus идёт на `127.0.0.1:8087` (`WCM_PROBE_HOST`),
а не на публичный IP: снаружи порта уже нет.

## Шаг 5. Запуск стека

```bash
cd /opt/monitoring
./run.sh up
./run.sh status
```

`./run.sh status` покажет контейнеры и доступность всех трёх портов
node_exporter. Ожидаемо:

```
127.0.0.1:9100  доступен     (akm, через akm-tunnel)
127.0.0.1:9102  доступен     (сервер приложений, через apps-tunnel)
127.0.0.1:9101  доступен     (этот хост)
```

## Шаг 6. Проверка, что видно всё

```bash
# таргеты без ошибок
curl -s http://127.0.0.1:9090/api/v1/targets | grep -c '"health":"up"'

# приложения живы
curl -s http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=probe_success{job="blackbox-http-health"}' | grep -o '"1"' | wc -l

# логи идут (должны появиться за минуту)
curl -s 'http://127.0.0.1:3100/loki/api/v1/labels' | grep -o '"app"'
```

В Grafana: `Availability / Backend Availability` — все три бэкенда UP,
`Logs / Backend Logs` — логи chat, makeup и wcm.

### Проверка писем об авариях

Ошибка в шаблоне письма не видна ни при загрузке конфига, ни в
`promtool`/`amtool check-config` — она возникает в момент отправки. То есть
о нерабочей теме можно узнать только тогда, когда что-то уже упало. Поэтому
после правки `alertmanager/alertmanager.yml.tmpl`:

```bash
./server/test-notification.sh "Muzea"
```

Скрипт отправляет синтетический алерт, убеждается, что Alertmanager его
принял, и проверяет логи на ошибку шаблона или SMTP. Тема должна прийти
письмом вида `[CRITICAL] Muzea: TestNotification`.

В шаблонах Alertmanager доступен небольшой свой набор функций, а **не
sprig**: `default`, `trim`, `replace` и прочие sprig-хелперы там не
существуют и дают `function "..." not defined` в момент отправки.

## Шаг 7. Убрать старое

```bash
cd /opt/loadtest && docker compose down      # compose проекта loadtest
# каталог и репозиторий loadtest на хосте больше не нужны:
git -C /opt/loadtest remote -v                # убедись, что всё в origin
rm -rf /opt/loadtest
```

Промтейл на `90.188.89.63` можно удалить — Loki туда не доставить, а логи
gitlab всё равно не нужны. `node_exporter` оставь, его туннель использует
Prometheus:

```bash
ssh -p 2222 dmitry_buldakov@90.188.89.63 docker rm -f promtail
ssh -p 2222 dmitry_buldakov@90.188.89.63 sudo rm -rf ~/logging
```

Каталог `~/logging` принадлежит root (файлы positions пишет promtail от root),
поэтому `sudo` требует пароля — если его нет, каталог можно оставить, он
безвреден.

Перед `rm -rf /opt/loadtest` проверь, что в `/opt/loadtest` не осталось
bind-mount'ов у живых контейнеров, иначе они продолжат работать на удалённых
inode и упадут при первом же рестарте:

```bash
docker ps -q | xargs -r docker inspect --format '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' \
  | grep /opt/loadtest
```

Если что-то осталось — сначала пересоздай контейнер с путями в
`/opt/monitoring` (например, `PROMTAIL_DIR=/opt/promtail ./server/install-promtail.sh`).

## Откат

Если что-то пошло не так, старый стек поднимается обратно: конфиги в
`/opt/loadtest` не тронуты до шага 7, а тома общие.

```bash
cd /opt/loadtest && git stash && docker compose up -d
```

## Обновление после изменений

```bash
cd /opt/monitoring && git pull && ./run.sh up
```

`promtool` в `render.sh` проверяет конфиг до старта: если в `.env` забыли
переменную, стек не поднимется с непонятной ошибкой, а рендер упадёт сразу
с списком незаполненных подстановок.
