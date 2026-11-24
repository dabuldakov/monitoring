#!/usr/bin/env bash
# Ежедневный full backup PostgreSQL через pgBackRest.
# Запускается на app-хосте systemd-таймером; WAL уезжает в SFTP-репозиторий
# непрерывно через archive_command.
set -euo pipefail

declare -A CONTAINERS=(
  [auth]="muzea-auth-service-postgres-1"
  [chat]="chat-backend-postgres-1"
  [makeup]="makeup-backend-postgres-1"
)

TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
ok=1
for service in auth chat makeup; do
  container="${CONTAINERS[$service]}"
  echo "==> pgBackRest full backup: $service ($container)"
  if docker exec -u postgres "$container" pgbackrest --stanza="$service" --type=full backup; then
    echo "    ok: $service"
  else
    echo "!! backup failed: $service" >&2
    ok=0
  fi
done

mkdir -p "$TEXTFILE_DIR"
tmp="$TEXTFILE_DIR/.muzea_pitr.prom.$$"
{
  echo "# HELP muzea_pitr_last_success_timestamp_seconds Unix time of last successful pgBackRest full backup"
  echo "# TYPE muzea_pitr_last_success_timestamp_seconds gauge"
  if [ "$ok" = "1" ]; then
    echo "muzea_pitr_last_success_timestamp_seconds $(date +%s)"
  else
    echo "muzea_pitr_last_success_timestamp_seconds 0"
  fi
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$TEXTFILE_DIR/muzea_pitr.prom"

[ "$ok" = "1" ]
