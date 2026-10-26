#!/usr/bin/env bash
# Стек наблюдаемости: метрики, логи, алерты.
# Запускается на машине мониторинга и не связан с нагрузочными прогонами
# (они в отдельном репозитории loadtest и пишут метрики сюда через remote-write).
#
# Использование:
#   ./run.sh up            Поднять стек (рендерит конфиги из .env)
#   ./run.sh down          Остановить стек (метрики и логи сохраняются)
#   ./run.sh restart       Перезапустить с перерендером конфигов
#   ./run.sh reload        Перечитать конфиги без перезапуска (SIGHUP Prometheus/Alertmanager)
#   ./run.sh status        Статус контейнеров
#   ./run.sh logs          Логи стека
#   ./run.sh render        Только перерендерить конфиги из .env
#   ./run.sh backup        Дамп правил Alertmanager и источников Grafana в git
#   ./run.sh tunnels       Статус SSH-туннелей к node_exporter
#
# Переменные (все в .env, см. .env.example):
#   APPS_HOST / WCM_HOST / AKM_HOST / TRADING_HOST — что мониторим
#   *_PORT                              — порты приложений и туннелей
#   GRAFANA_BIND_ADDR / GRAFANA_PORT    — как торчит Grafana
#   SMTP_* / ALERT_EMAIL_*              — куда шлём алерты
#
# Grafana:     http://<хост>:${GRAFANA_PORT}  (логин из .env)
# Prometheus:  http://127.0.0.1:9090
# Loki:       http://127.0.0.1:3100 (наружу не торчит)
set -euo pipefail
cd "$(dirname "$0")"

set -a
[[ -f .env ]] && . ./.env
set +a

require_compose() {
  docker compose version >/dev/null 2>&1 || { echo "Нужен Docker Compose v2"; exit 1; }
}

status() {
  require_compose
  docker compose ps
  echo
  echo "Туннели до node_exporter:"
  for p in "${AKM_NODE_EXPORTER_PORT:-9100}" "${APPS_NODE_EXPORTER_PORT:-9102}" "${WCM_NODE_EXPORTER_PORT:-9101}" "${TRADING_NODE_EXPORTER_PORT:-9104}"; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      echo "  127.0.0.1:$p  доступен"
    else
      echo "  127.0.0.1:$p  НЕ доступен"
    fi
  done
}

backup() {
  require_compose
  mkdir -p backup
  curl -sf http://127.0.0.1:9093/api/v2/alerts > backup/alertmanager-alerts.json \
    && echo "==> backup/alertmanager-alerts.json" || echo "!! не смог прочитать Alertmanager"
  curl -sf -u "${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}" \
    "http://127.0.0.1:${GRAFANA_PORT:-3000}/api/datasources" > backup/grafana-datasources.json \
    && echo "==> backup/grafana-datasources.json" || echo "!! не смог прочитать Grafana"
}

# Prometheus и Alertmanager не перечитывают смонтированные конфиги сами:
# после перерендера отправляем им SIGHUP (перечитывание без перезапуска).
#
# Две ловушки, из-за которых стек уже один раз молча лёг:
#
# 1) SIGHUP в первые секунды жизни процесса его убивает: обработчик сигнала
#    ещё не установлен, срабатывает действие по умолчанию (prometheus:v3.14
#    в такой ситуации завершается с exit=2 — проверено). Убийство ушло через
#    API docker, поэтому restart-политика его не аварией считает и контейнер
#    остаётся лежать. Значит, контейнеру, только что поднятому через `up -d`,
#    SIGHUP не шлём: новый конфиг он и так уже прочитал при старте.
# 2) SIGHUP может убить и warmed-up процесс — отправили и разошлись, а сервис
#    мёртв. Проверяем после отправки; если умер — поднимаем тем же
#    `docker compose start` (без пересоздания, история и тома не трогаются).
reload_configs() {
  for svc in prometheus alertmanager; do
    docker compose ps --status running --services 2>/dev/null | grep -qx "$svc" || continue
    local cid started uptime
    cid=$(docker compose ps -q "$svc" | head -n1) || cid=""
    [[ -n "$cid" ]] || continue
    started=$(date -u -d "$(docker inspect -f '{{.State.StartedAt}}' "$cid")" +%s) || continue
    uptime=$(( $(date -u +%s) - started ))
    if (( uptime < 10 )); then
      echo "==> $svc: запущен ${uptime}с назад — конфиг загружен при старте, SIGHUP не нужен"
      continue
    fi
    if docker compose kill -s SIGHUP "$svc" >/dev/null 2>&1; then
      echo "==> $svc: конфиг перечитан (SIGHUP)"
    fi
    if [[ "$(docker inspect -f '{{.State.Status}}' "$cid")" != "running" ]]; then
      docker compose start "$svc" >/dev/null 2>&1 \
        && echo "!! $svc остановился после SIGHUP — снова запущен (без пересоздания)" >&2
    fi
  done
}

# Ждём, пока Prometheus/Alertmanager отвечат на /-/ready. Без этого деплой
# «успешно» проходил и при лежащем Prometheus: CI зелёный, метрики мёртвые.
wait_ready() {
  local name="$1" url="$2" i
  for i in $(seq 1 30); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "==> $name: готов ($url)"
      return 0
    fi
    sleep 1
  done
  echo "!! $name не готов за 30 секунд: $url" >&2
  return 1
}

check_stack() {
  wait_ready Prometheus  http://127.0.0.1:9090/-/ready
  wait_ready Alertmanager http://127.0.0.1:9093/-/ready
}

case "${1:-}" in
  up)      require_compose; ./render.sh; docker compose up -d; reload_configs; check_stack ;;
  down)    require_compose; docker compose down ;;
  restart) require_compose; ./render.sh; docker compose up -d --force-recreate; check_stack ;;
  reload)  require_compose; ./render.sh; reload_configs; check_stack ;;
  status)  status ;;
  logs)    require_compose; docker compose logs -f --tail=100 ;;
  render)  require_compose; ./render.sh ;;
  backup)  backup ;;
  tunnels) status ;;
  ""|-h|--help|help)
    # Печатаем шапку комментария: от второй строки до первой строки кода.
    sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'
    ;;
  *) echo "Неизвестная команда: $1"; exit 1 ;;
esac
