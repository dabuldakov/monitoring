# Offsite-бэкапы (restic)

Текущий дневной бэкап `server/backups/backup-muzea.sh` делает:

1. `pg_dump -Fc` трёх БД на машине мониторинга;
2. `mc mirror` всех бакетов MinIO;
3. шифрованный `restic`-снимок каталога `/opt/backups/muzea`.

## Куда

| Параметр | Значение |
|---|---|
| Хост | `90.188.89.63:2222`, пользователь `dmitry_buldakov` |
| Репозиторий | `/home/dmitry_buldakov/muzea-restic` |
| SSH alias на monitoring | `muzea-backup` |
| Пароль restic | `/opt/monitoring/.restic-password` (только root, 600) |

Пароль restic обязателен для восстановления. Резервная копия пароля хранится
вне сервера; без него репозиторий не расшифровать.

## Политика

- снимок — ежедневно вместе с обычным бэкапом;
- retention: 30 daily, 12 weekly, 12 monthly, затем `prune`;
- раз в неделю — `restic check --read-data-subset=10%`;
- алерт `MuzeaBackupOffsiteStale` — если снимку больше 48 часов.

## Проверка

```bash
ssh root@89.104.66.226
export RESTIC_PASSWORD_FILE=/opt/monitoring/.restic-password
restic -r sftp:muzea-backup:/home/dmitry_buldakov/muzea-restic snapshots
```

## Восстановление

```bash
export RESTIC_PASSWORD_FILE=/opt/monitoring/.restic-password
REPO=sftp:muzea-backup:/home/dmitry_buldakov/muzea-restic

# список файлов в снимке
restic -r "$REPO" ls latest /opt/backups/muzea/postgres

# восстановить один дамп
restic -r "$REPO" restore latest --target /tmp/restore \
  --include /opt/backups/muzea/postgres/chat-<stamp>.dump

# полное восстановление каталога
restic -r "$REPO" restore latest --target /tmp/restore
```

После восстановления БД запускать `pg_restore` в контейнере нужной БД на
app-хосте; MinIO-объекты возвращать через `mc mirror` в чистый бакет.

## Ограничение

Это offsite-копия **логических** дампов и объектов MinIO. PITR
(восстановление PostgreSQL на секунду) пока не включён. Следующий шаг —
WAL-архивирование через `pgBackRest`/`WAL-G` в отдельный S3-репозиторий.


## PITR PostgreSQL (pgBackRest)

Дополнительно к логическим дампам работает pgBackRest:

| Параметр | Значение |
|---|---|
| Образ | `muzea/postgres:17-pgbackrest` (Dockerfile: `deploy/postgres-pgbackrest/` в каждом backend-репозитории) |
| Репозиторий | `sftp://dmitry_buldakov@90.188.89.63:2222/home/dmitry_buldakov/muzea-pgbackrest` |
| Станзы | `auth`, `chat`, `makeup` |
| WAL | archive_mode=on, archive_timeout=300 |
| Full backup | ежедневно 02:30 UTC, systemd `pgbackrest-backup.timer` на app-хосте |
| Retention | 7 full, 7 архивов WAL |
| Шифрование | aes-256-cbc |
| Конфиги | `/home/administrator/muzea/pgbackrest/<service>/` |

Проверка:

```bash
docker exec -u postgres muzea-auth-service-postgres-1 \
  pgbackrest --stanza=auth info
```

Восстановление на точку времени:

```bash
# остановить приложение/БД, подготовить чистый PGDATA
docker run --rm -v /path/to/empty-pgdata:/var/lib/postgresql/data \
  -v /home/administrator/muzea/pgbackrest/auth:/etc/pgbackrest:ro \
  --entrypoint bash muzea/postgres:17-pgbackrest -lc '
    chown -R postgres:postgres /var/lib/postgresql
    su postgres -c "pgbackrest --stanza=auth --type=time \
      --target=\"2026-11-24 14:00:00+00\" --target-action=promote restore"
  '
```

Затем запустить PostgreSQL с `archive_mode=off` (или в отдельном контейнере) и
проверить данные. WAL-архив и full backup хранятся на offsite-хосте.
