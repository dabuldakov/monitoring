#!/usr/bin/env bash
# Установка node_exporter на сервере приложений (нужен только Docker, без systemd).
# Слушает 127.0.0.1:9100 — наружу не торчит, доступен через SSH-туннель
# с машины мониторинга (server/tunnels/*.service).
#
# Запуск на сервере:
#   ./install-node-exporter.sh
#   PORT=9101 ./install-node-exporter.sh      # другой порт, если 9100 занят
set -euo pipefail

CONTAINER="${CONTAINER:-node_exporter}"
PORT="${PORT:-9100}"
IMAGE="${IMAGE:-quay.io/prometheus/node-exporter:latest}"
# textfile-коллектор: сюда агенты пишут свои .prom (см. server/trading-status/).
# Директория должна быть видна внутри контейнера, поэтому путь указывается
# через уже смонтированный корень /host.
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
mkdir -p "$TEXTFILE_DIR"
chmod 755 "$TEXTFILE_DIR"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "==> пересоздаю контейнер $CONTAINER"
  docker rm -f "$CONTAINER" >/dev/null
fi

docker run -d --name "$CONTAINER" --restart unless-stopped \
  --net host --pid host \
  -v /:/host:ro,rslave \
  "$IMAGE" \
  --path.rootfs=/host \
  --collector.textfile.directory="/host${TEXTFILE_DIR}" \
  --web.listen-address="127.0.0.1:${PORT}" >/dev/null

sleep 2
echo "==> $CONTAINER: $(docker ps --filter "name=$CONTAINER" --format '{{.Status}}')"
curl -sf "http://127.0.0.1:${PORT}/metrics" >/dev/null && echo "==> метрики доступны на 127.0.0.1:${PORT}"

