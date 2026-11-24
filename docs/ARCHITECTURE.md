# Архитектура Muzea: инстансы, данные и бэкапы

Дата: 2026-11-24  
Статус: актуальное описание продакшена.

## Хосты

| Роль | Адрес | Назначение |
|---|---|---|
| App | `176.120.27.77` | приложения, nginx, PostgreSQL, Redis, MinIO |
| Monitoring | `89.104.66.226` | Prometheus, Grafana, Loki, Alertmanager, node_exporter, backup-скрипт |
| Backup | `90.188.89.63:2222` | offsite restic-репозиторий |
| Old app | `168.222.194.206` | выключен, диск сохранён на время наблюдения |

## Приложения и инстансы

На app-хосте по **два именованных инстанса** каждого сервиса:

```
host nginx :443
 ├─ 127.0.0.1:8085 → makeup nginx → makeup-app / makeup-app-2
 ├─ 127.0.0.1:8086 → chat nginx   → chat-app / chat-app-2
 └─ 127.0.0.1:8087 → auth nginx   → auth-app / auth-app-2
```

Почему не `deploy.replicas`: Docker Compose не умеет rolling-обновление реплик.
Поэтому в compose явно описаны `app` и `app2`, а `scripts/rolling-deploy.sh`
обновляет их по одному, временно убирая инстанс из upstream.

Приложения stateless:

- JWT/refresh — в БД auth-service;
- локи и кэш — Redis;
- фоновые задачи — advisory-locks PostgreSQL и `SKIP LOCKED`;
- медиа — MinIO.

Подробности и команды: [TWO_INSTANCES.md](TWO_INSTANCES.md).

## Данные

| Компонент | Инстансы | Расположение |
|---|---|---|
| PostgreSQL | 3 отдельные БД (makeup, chat, auth) | один хост |
| Redis | 3 инстанса | один хост |
| MinIO | 1 инстанс, бакеты attachments/videos/avatars/news-image/thumbnails | один хост |

Это даёт деплой без простоя, но **не** защиту от падения app-хоста. Реплик и
PITR пока нет.

## Мониторинг

- node_exporter и promtail на app-хосте;
- Prometheus-агент `server/app-metrics` находит обе реплики через Docker DNS;
- центральный Prometheus получает их через federation по SSH-туннелю;
- в метриках видна каждая реплика отдельно;
- алерты: доступность, диск, контейнеры, свежесть бэкапов.

## Бэкапы

### Логические бэкапы + offsite

Ежедневно systemd-таймер на monitoring-хосте запускает
`server/backups/backup-muzea.sh`:

1. `pg_dump -Fc` трёх БД на monitoring-хост;
2. проверка каждого дампа через `pg_restore --list`;
3. `mc mirror` всех бакетов MinIO (read-only пользователь);
4. **offsite**: `restic backup` каталога `/opt/backups/muzea` на
   `90.188.89.63` по SFTP;
5. retention: локальные дампы 14 дней, restic — 30 daily / 12 weekly /
   12 monthly + prune;
6. раз в неделю `restic check --read-data-subset=10%`;
7. textfile-метрики для алертов `MuzeaBackupStale` и
   `MuzeaBackupOffsiteStale`.

Схема:

```
app DB/MinIO ──pg_dump/mc mirror──> /opt/backups/muzea (monitoring)
                                            │
                                            └─ restic (encrypted) ──SFTP──> 90.188.89.63
```

`mc mirror --remove` повторяет текущее состояние MinIO, но restic хранит
неизменяемые снимки, поэтому удалённые объекты остаются в старых снимках до
истечения retention.

### PITR PostgreSQL

Для каждой БД (auth, chat, makeup) включён pgBackRest:

- образ `muzea/postgres:17-pgbackrest` (postgres:17 + pgBackRest);
- `archive_mode=on`, `wal_level=replica`, `archive_timeout=300`;
- WAL непрерывно уезжает в SFTP-репозиторий на backup-хосте;
- ежедневно в 02:30 UTC systemd-таймер на app-хосте делает full backup;
- retention: 7 full + 7 архивов WAL;
- репозиторий шифруется `aes-256-cbc`;
- конфиги: `/home/administrator/muzea/pgbackrest/<service>/`, пароль — в защищённой копии вне сервера.

Схема:

```
PostgreSQL ──WAL archive_command──> pgBackRest SFTP ──> 90.188.89.63
    │
    └──daily full backup (02:30 UTC)
```

### Текущие RPO/RTO

| Что | RPO | RTO |
|---|---|---|
| PostgreSQL (PITR) | до 5 минут (archive_timeout), при активности — секунды | 15–60 минут |
| MinIO | до 24 часов | зависит от объёма |
| Offsite-копия | до 24 часов | + время скачивания |

PITR проверен restore drill для auth: восстановлена БД и сверено количество пользователей.

### Восстановление

Пароль restic: `/opt/monitoring/.restic-password` (root, 600) + защищённая
копия вне сервера. Репозиторий:
`sftp:muzea-backup:/home/dmitry_buldakov/muzea-restic`.

Команды и проверка — в [BACKUP_OFFSITE.md](BACKUP_OFFSITE.md).

## Домены отказа

| Отказ | Последствия | Что спасает |
|---|---|---|
| Падение одного app-инстанса | нет, второй обслуживает | nginx upstream |
| Падение app-хоста | простой | бэкапы, но не HA |
| Потеря monitoring-хоста | нет свежих бэкапов | offsite-снимки на backup-хосте |
| Потеря backup-хоста | offsite-копия недоступна | локальные бэкапы на monitoring |
| Порча БД | потеря до суток | offsite restic + restore drill |
| Порча/удаление медиа | файлы 404 | restic-снимки MinIO |

## Что осталось

1. PITR для PostgreSQL: WAL-архивирование (`pgBackRest`/`WAL-G`) + restore drill.
2. Реплика/standby PostgreSQL и вторая площадка — защита от падения ноды.
3. Автоматический еженедельный restore не только файлов, но и БД в отдельный
   контейнер с проверкой таблиц.
4. Retention/versioning для MinIO на стороне offsite (object lock).
5. Расширение диска monitoring-хоста.
