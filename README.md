# Мониторинг сервисов

Постоянный стек наблюдаемости: **метрики, логи, алерты, Grafana**.
Живёт на отдельной машине и не связан с нагрузочными прогонами — они живут
в отдельном репозитории `loadtest` и пишут метрики сюда через remote-write.

Полная картина — [архитектура, инстансы и бэкапы](docs/ARCHITECTURE.md).

## Что внутри

| Компонент | Роль | Наружу |
|---|---|---|
| Prometheus | метрики всех серверов и приложений, Правила алертов | нет (`127.0.0.1:9090`) |
| Alertmanager | рассылка алертов на email | нет (`127.0.0.1:9093`) |
| blackbox_exporter | живость приложений (`/actuator/health`), TCP, ICMP | нет (`127.0.0.1:9115`) |
| Loki | хранилище логов всех контейнеров, ретеншн 14 дней | нет (`127.0.0.1:3100`) |
| Grafana | дашборды: k6, node_exporter, availability, logs, trading status | да, адрес из `.env` |

Агенты на целевых серверах (`server/`): **node_exporter** (метрики хоста)
и **promtail** (сбор docker-логов в Loki). Оба слушают только loopback,
доступны через SSH-туннели — подробности в [server/README.md](server/README.md).
На trading-сервере дополнительно собирается **статус контейнеров и сессий**
(`server/trading-status/`, дашборд `Trading / Trading Status`), а также
**метрики трейдеров** (heartbeat из логов: тики, заявки, латентность, ошибки).

**Метрики приложений.** `makeup`, `chat` и `auth` отдают Micrometer на
`/actuator/prometheus`. На каждом app-хосте работает Prometheus-агент
(`server/app-metrics`): он находит все реплики через Docker DNS и отдаёт
центральному Prometheus через `/federate` по SSH-туннелю. В Grafana и алертах
видна каждая реплика отдельно (`instance`), дашборд — `App / App Runtime`.

## Быстрый старт

```bash
git clone <repo> /opt/monitoring && cd /opt/monitoring
cp .env.example .env && nano .env     # хосты, порты, пароль Grafana, SMTP
./run.sh up
./run.sh status
```

`./run.sh up` рендерит конфиги из шаблонов и `.env` в `*.local.yml`
(в git не коммитятся), проверяет их через `promtool` и поднимает стек.

## Где что настраивается

**Все таргеты — только в `.env`.** В `prometheus/prometheus.yml.tmpl` нет ни
одного зашитого IP, конфиг генерируется из шаблона. Чтобы добавить сервер,
достаточно дописать переменные в `.env`.

Шаблоны, которые рендерятся (`./run.sh render`):

| Шаблон | Результат | Подставляется |
|---|---|---|
| `prometheus/prometheus.yml.tmpl` | `prometheus/prometheus.local.yml` | хосты, порты приложений, порты туннелей |
| `alertmanager/alertmanager.yml.tmpl` | `alertmanager/alertmanager.local.yml` | SMTP и адреса получателей |

## Команды

```
./run.sh up / down / restart / reload   — жизненный цикл
./run.sh status                          — контейнеры + доступность туннелей
./run.sh logs                            — логи стека
./run.sh render                          — перегенерировать конфиги из .env
./run.sh backup                          — дамп правил Alertmanager и datasource'ов
```

## Данные

Docker volume'ы: `prometheus_data`, `alertmanager_data`, `loki_data`, `grafana_data`.
`./run.sh down` их сохраняет; `docker compose down -v` удалит — сносит всю
историю метрик и логов.

## Бэкапы

`server/backups/` — ежедневный бэкап состояния muzea на машину мониторинга:

- `pg_dump -Fc` каждой БД (makeup/chat/auth) + проверка `pg_restore --list`;
- `mc mirror` всех bucket'ов MinIO read-only пользователем `backup`;
- дампы БД хранятся 14 дней, MinIO-зеркало — в одном экземпляре (текущее состояние);
- шифрованный offsite-снимок restic на отдельном хосте: 30 daily / 12 weekly / 12 monthly;
- еженедельная read-data проверка и алерты `MuzeaBackupStale` / `MuzeaBackupOffsiteStale`.

Подробно: [BACKUP_OFFSITE.md](docs/BACKUP_OFFSITE.md).

Установка (на машине мониторинга):

```bash
cp server/backups/muzea-backup.service /etc/systemd/system/
cp server/backups/muzea-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now muzea-backup.timer
systemctl start muzea-backup.service   # первый прогон
```

Требуется `mc` в `/usr/local/bin/mc`, доступ по SSH к серверу приложений
(тот же ключ, что у `apps-tunnel`) и read-only пользователь MinIO
(`MINIO_BACKUP_*` в `.env`).

Пользователь MinIO и политика создаются один раз (в образе `minio/minio`
есть готовый `mc`):

```bash
# mc из образа MinIO (dl.min.io может быть недоступен)
docker create --name mc-tmp minio/minio:latest
docker cp mc-tmp:/usr/bin/mc /usr/local/bin/mc && chmod +x /usr/local/bin/mc
docker rm mc-tmp

# на сервере приложений, с root-кредами из shared-minio/.env
mc admin user add local backup '<secret>'
mc admin policy create local muzea-backup-readonly server/backups/minio-backup-policy.json
mc admin policy attach local muzea-backup-readonly --user backup
```

Встроенной политики `readonly` недостаточно: `mc mirror` делает list
сравнения и получает Access Denied. Нужны `s3:Get*` и `s3:List*`.

## Логи

Promtail на каждом сервере приложений шлёт логи в Loki; лейблы:

```
{app="chat"}                     логи chat
{app="makeup"}                   логи makeup
{app="minio"}                    логи общего MinIO (проект shared-minio)
{app="wcm"}                      логи world-country-monitoring
{app="trading"}                  логи trading-инфраструктуры (app/caddy/collector/postgres/redis)
{app="trader"}                   логи live-трейдеров (pairs-mn, donchian-*)
{app=~"chat|makeup"} |="ERROR"   ошибки
{app="chat"} | json | user="42"  логи конкретного пользователя
```

Дашборд `Logs / Backend Logs` уже настроен на эти лейблы и содержит отдельную
панель `Trading logs`.
