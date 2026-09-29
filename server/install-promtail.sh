#!/usr/bin/env bash
# Установка Promtail на сервер приложений: читает docker.sock и шлёт логи
# всех контейнеров в Loki на 127.0.0.1:3100 (туда его пробрасывает обратный
# SSH-туннель с машины мониторинга — server/tunnels/apps.service).
#
# Запуск на сервере приложений:
#   ./server/install-promtail.sh [ПУТЬ_К_ПРОМТЕЙЛ_КОНФИГУ]
# Путь по умолчанию берётся из этого же репозитория (../promtail/promtail.yml).
set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)/promtail/promtail.yml}"
DEST="${PROMTAIL_DIR:-/opt/promtail}"
IMAGE="${IMAGE:-grafana/promtail:3.4.2}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100/loki/api/v1/push}"

[[ -f "$SRC" ]] || { echo "!! не найден конфиг promtail: $SRC"; exit 1; }

echo "==> promtail: конфиг $SRC -> $DEST/promtail.yml (push в $LOKI_URL)"
mkdir -p "$DEST"
sed "s#http://127.0.0.1:3100/loki/api/v1/push#$LOKI_URL#" "$SRC" > "$DEST/promtail.yml"

if [[ -f "$DEST/docker-compose.yaml" ]] && grep -q 'promtail' "$DEST/docker-compose.yaml"; then
  echo "==> обновляю существующий compose в $DEST"
else
  cat > "$DEST/docker-compose.yaml" <<'YAML'
services:
  promtail:
    image: grafana/promtail:3.4.2
    container_name: promtail
    restart: unless-stopped
    command: -config.file=/etc/promtail/promtail.yml
    network_mode: host
    user: "0"
    mem_limit: 256m
    volumes:
      - ./promtail.yml:/etc/promtail/promtail.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./positions:/promtail

volumes:
  positions:
YAML
  echo "==> создан $DEST/docker-compose.yaml"
fi

cd "$DEST"
docker compose up -d
sleep 3

echo "==> promtail: $(docker ps --filter name=^/promtail$ --format '{{.Status}}')"

# Проверяем, что Loki реально виден (иначе логи уйдут в никуда молча).
# /ready у single-binary Loki периодически отдаёт 503 ("waiting for 15s after
# being ready"), поэтому ориентируемся на сам факт ответа, а не на код 200.
loki_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:3100/ready || echo 000)
case "$loki_code" in
  000)
    echo "!! Loki на 127.0.0.1:3100 недоступен — проверь обратный туннель с машины мониторинга" >&2
    echo "!! Без него promtail будет копить логи в буфер и ничего не отправит." >&2
    ;;
  200) echo "==> Loki на 127.0.0.1:3100 готов" ;;
  503) echo "==> Loki на 127.0.0.1:3100 отвечает (503 — штатный цикл готовности, скоро отдаст 200)" ;;
  *)   echo "==> Loki на 127.0.0.1:3100 отвечает кодом $loki_code" ;;
esac

echo
echo "Проверка в Grafana (datasource Loki):"
echo '  {app="chat"}'
echo '  {app="makeup"} | json | level="ERROR"'
echo '  {app="wcm"}    |= "ERROR"'
