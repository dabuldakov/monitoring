#!/usr/bin/env bash
# Установка node_exporter на сервер БЕЗ Docker: официальный бинарник + systemd.
# Слушает только 127.0.0.1:9100 — наружу не торчит, доступен через SSH-туннель
# с машины мониторинга (server/tunnels/*.service).
#
# Аналог server/install-node-exporter.sh, но для хостов без Docker.
# Ставит /usr/local/bin/node_exporter и юнит
# node_exporter.service, запускает и оставляет включённым на автозапуск.
#
# Запуск на сервере (от root):
#   ./install-node-exporter-systemd.sh
#   PORT=9101 ./install-node-exporter-systemd.sh       # другой порт, если 9100 занят
#   VERSION=1.9.1 ./install-node-exporter-systemd.sh   # фиксированная версия
set -euo pipefail

PORT="${PORT:-9100}"
VERSION="${VERSION:-}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
BIN="${BIN:-/usr/local/bin/node_exporter}"
RUN_USER="${RUN_USER:-node_exporter}"

[[ "$(id -u)" -eq 0 ]] || { echo "!! запускать от root" >&2; exit 1; }

detect_arch() {
  case "$(uname -m)" in
    x86_64)          echo amd64 ;;
    aarch64|arm64)   echo arm64 ;;
    armv7l)          echo armv7 ;;
    *) echo "!! неподдерживаемая архитектура: $(uname -m)" >&2; exit 1 ;;
  esac
}

# Версия по умолчанию — последний релиз. Определяем по редиректу GitHub,
# а не через API: у API есть лимит запросов с одного IP.
if [[ -z "$VERSION" ]]; then
  VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/prometheus/node_exporter/releases/latest | sed -E 's#.*/tag/v?##')
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "!! не смог определить версию node_exporter (получил '$VERSION')" >&2; exit 1; }

ARCH=$(detect_arch)
TARBALL="node_exporter-${VERSION}.linux-${ARCH}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${TARBALL}"

echo "==> node_exporter ${VERSION} (${ARCH})"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/$TARBALL"
tar -xzf "$tmp/$TARBALL" -C "$tmp"
install -m 0755 "$tmp/node_exporter-${VERSION}.linux-${ARCH}/node_exporter" "$BIN"

id "$RUN_USER" >/dev/null 2>&1 \
  || useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
mkdir -p "$TEXTFILE_DIR"
chown "$RUN_USER":"$RUN_USER" "$TEXTFILE_DIR"
chmod 755 "$TEXTFILE_DIR"

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
Group=$RUN_USER
Type=simple
ExecStart=$BIN --web.listen-address=127.0.0.1:$PORT --collector.textfile.directory=$TEXTFILE_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter >/dev/null
sleep 2
echo "==> node_exporter: $(systemctl is-active node_exporter)"
curl -sf "http://127.0.0.1:${PORT}/metrics" >/dev/null \
  && echo "==> метрики доступны на 127.0.0.1:${PORT}"
