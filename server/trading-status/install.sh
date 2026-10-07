#!/usr/bin/env bash
# Установка сборщика статуса trading на сервер приложений.
#
#   scp -r server/trading-status root@<trading-host>:/root/trading-status
#   ssh root@<trading-host> '/root/trading-status/install.sh'
#
# Пишет метрики в $TEXTFILE_DIR/trading.prom — туда же смотрит node_exporter
# (см. server/install-node-exporter.sh, флаг --collector.textfile.directory).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${DEST:-/opt/trading-status}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
UNIT_DIR=/etc/systemd/system

for cmd in docker curl jq systemctl; do
  command -v "$cmd" >/dev/null || { echo "нет команды: $cmd" >&2; exit 1; }
done

install -d -m 0755 "$DEST" "$TEXTFILE_DIR"
install -m 0755 "$SRC/collect.sh" "$DEST/collect.sh"
install -m 0644 "$SRC/trading-status-collector.service" "$UNIT_DIR/"
install -m 0644 "$SRC/trading-status-collector.timer" "$UNIT_DIR/"

systemctl daemon-reload
systemctl enable --now trading-status-collector.timer
systemctl start trading-status-collector.service

echo "==> таймер:"
systemctl is-active trading-status-collector.timer
echo "==> файл метрик: $TEXTFILE_DIR/trading.prom"
head -25 "$TEXTFILE_DIR/trading.prom"
echo "==> проверка node_exporter (если уже пересоздан с textfile-директорией):"
if curl -sf "http://127.0.0.1:${PORT:-9100}/metrics" | grep -q '^trading_'; then
  echo "    trading_* метрики отдаются"
else
  echo "    trading_* пока не отдаются — перезапусти node_exporter:" \
       "PORT=${PORT:-9100} ./install-node-exporter.sh"
fi
