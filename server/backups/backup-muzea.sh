#!/usr/bin/env bash
# Ежедневный бэкап состояния muzea на машину мониторинга.
#
# Запускается на машине мониторинга (systemd timer). Тянет данные с сервера
# приложений по уже настроенному SSH-ключу (apps-tunnel):
#   - pg_dump -Fc каждой БД (makeup, chat, auth) + проверка pg_restore --list;
#   - mc mirror всех bucket'ов MinIO (read-only пользователь backup).
#
# Ничего не пишет на сервер приложений: дампы и объекты сразу ложатся на диск
# машины мониторинга. Каталог и ретеншн задаются в .env (BACKUP_DIR).
set -euo pipefail

MONITORING_DIR="${MONITORING_DIR:-/opt/monitoring}"
set -a
# shellcheck disable=SC1091
. "$MONITORING_DIR/.env"
set +a

DEST="${BACKUP_DIR:-/opt/backups/muzea}"
APPS_SSH_PORT="${APPS_SSH_PORT:-22}"

SSH_BASE=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
  -p "$APPS_SSH_PORT" -i "$APPS_SSH_KEY" "$APPS_SSH_TARGET")

# Контейнер Postgres -> короткое имя для файла дампа.
POSTGRES=(
  "makeup-backend-postgres-1:makeup"
  "chat-backend-postgres-1:chat"
  "muzea-auth-service-postgres-1:auth"
)

mkdir -p "$DEST/postgres" "$DEST/minio"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

echo "==> backup started: $STAMP -> $DEST"

# ---------- PostgreSQL ----------
for pair in "${POSTGRES[@]}"; do
  container="${pair%%:*}"
  name="${pair##*:}"
  user="$("${SSH_BASE[@]}" "docker exec $container printenv POSTGRES_USER")"
  db="$("${SSH_BASE[@]}" "docker exec $container printenv POSTGRES_DB")"
  out="$DEST/postgres/${name}-${STAMP}.dump"

  echo "--> pg_dump $name ($container/$db)"
  "${SSH_BASE[@]}" "docker exec $container pg_dump -U '$user' -d '$db' -Fc" > "$out"
  test -s "$out" || { echo "!! empty dump: $out" >&2; exit 1; }

  # Проверяем, что дамп читается: pg_restore --list гоняем в самом контейнере.
  "${SSH_BASE[@]}" "docker exec -i $container pg_restore --list" < "$out" >/dev/null
  echo "    ok: $(du -h "$out" | cut -f1)"
done

# ---------- MinIO ----------
if [[ -n "${MINIO_BACKUP_ACCESS_KEY:-}" && -n "${MINIO_BACKUP_SECRET_KEY:-}" ]]; then
  echo "--> mc mirror MinIO -> $DEST/minio"
  export MC_HOST_muzea="http://${MINIO_BACKUP_ACCESS_KEY}:${MINIO_BACKUP_SECRET_KEY}@127.0.0.1:9000"
  # --remove: бэкап повторяет текущее состояние (удалённое в проде не храним).
  /usr/local/bin/mc mirror --overwrite --remove --quiet muzea "$DEST/minio"
  echo "    ok: $(du -sh "$DEST/minio" | cut -f1)"
else
  echo "!! MINIO_BACKUP_ACCESS_KEY/SECRET_KEY не заданы — MinIO пропущен" >&2
fi

# ---------- Ретеншн ----------
# Дампы БД — 14 дней. MinIO-зеркало хранится в одном экземпляре (текущее состояние).
find "$DEST/postgres" -type f -name '*.dump' -mtime +14 -delete
find "$DEST/postgres" -type f -name '*.dump' -printf '%f\n' | sort | tail -5

echo "==> backup finished"
