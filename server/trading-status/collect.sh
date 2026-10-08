#!/usr/bin/env bash
# Собирает статус trading-сервера в формат Prometheus textfile.
#
# Метрики:
#   trading_container_up{name,role,required}          1 — контейнер запущен
#   trading_container_state_code{name,role,required}  0=отсутствует, 1=остановлен, 2=запущен
#   trading_containers_running{role}                  сколько запущено по роли
#   trading_status_scrape_success                     1 — API сессий ответил
#   trading_sessions_running{strategy,broker}         сессии в статусе running
#   trading_sessions_running_total                    всего running
#   trading_session_info{id,strategy,broker,pair}     1 — каждая живая сессия
#   trading_session_age_seconds{...}                  возраст сессии
#
# EXPECTED — контейнеры, про которые обязаны знать даже в отсутствие (up=0):
#            без этого исчезнувший контейнер не виден в метриках вообще.
# CRITICAL  — из EXPECTED те, на чьё отсутствие заводится алерт.
set -euo pipefail

OUT_DIR="${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
OUT="${OUT_DIR}/trading.prom"
API="${TRADING_API:-http://127.0.0.1:8000/api}"

# Инфраструктура compose-проекта — падение критично (TradingContainerDown).
# Live-трейдеры (pairs-energy, pairs-materials, pairs-fin, pairs-consumer и
# прочие с меткой trading.role=trader) намеренно НЕ в CRITICAL: они
# обнаруживаются автоматически как required=false,role=trader и попадают под
# мягкий алерт TradingTraderStopped.
CRITICAL="${CRITICAL:-trading-app-1 trading-caddy-1 trading-collector-1 trading-postgres-1 trading-redis-1}"
EXPECTED="${EXPECTED:-$CRITICAL trades-bot dn bot-api bcs-bot}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-trading}"

esc() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# --- контейнеры ------------------------------------------------------------
declare -A CONT_STATE CONT_ROLE
while IFS=$'\t' read -r name st label_role project; do
  [ -n "$name" ] || continue
  CONT_STATE["$name"]=$st
  if [ -n "$label_role" ]; then
    CONT_ROLE["$name"]=$label_role
  elif [ "$project" = "$COMPOSE_PROJECT" ]; then
    CONT_ROLE["$name"]=compose
  else
    CONT_ROLE["$name"]=other
  fi
done < <(docker ps -a --format \
  '{{.Names}}\t{{.State}}\t{{.Label "trading.role"}}\t{{.Label "com.docker.compose.project"}}')

state_code() {
  case "$1" in
    running) echo 2 ;;
    absent) echo 0 ;;
    *) echo 1 ;;
  esac
}

is_critical() {
  local n
  for n in $CRITICAL; do [ "$n" = "$1" ] && return 0; done
  return 1
}

container_lines() {
  local name st code up required role
  local -A seen=()

  for name in $EXPECTED; do
    seen["$name"]=1
    st=${CONT_STATE[$name]:-absent}
    role=${CONT_ROLE[$name]:-other}
    required=false
    is_critical "$name" && required=true
    code=$(state_code "$st")
    up=$(( code == 2 ? 1 : 0 ))
    printf 'trading_container_up{name="%s",role="%s",required="%s"} %s\n' \
      "$(esc "$name")" "$(esc "$role")" "$required" "$up"
    printf 'trading_container_state_code{name="%s",role="%s",required="%s"} %s\n' \
      "$(esc "$name")" "$(esc "$role")" "$required" "$code"
  done

  # Контейнеры, которых нет в EXPECTED, но они есть — новые боты и прочее.
  for name in "${!CONT_STATE[@]}"; do
    [ -n "${seen[$name]:-}" ] && continue
    role=${CONT_ROLE[$name]:-other}
    [ "$role" = other ] && continue
    st=${CONT_STATE[$name]}
    code=$(state_code "$st")
    up=$(( code == 2 ? 1 : 0 ))
    printf 'trading_container_up{name="%s",role="%s",required="false"} %s\n' \
      "$(esc "$name")" "$(esc "$role")" "$up"
    printf 'trading_container_state_code{name="%s",role="%s",required="false"} %s\n' \
      "$(esc "$name")" "$(esc "$role")" "$code"
  done
}

running_by_role() {
  local name st role
  declare -A cnt=()
  for name in "${!CONT_STATE[@]}"; do
    st=${CONT_STATE[$name]}
    [ "$st" = running ] || continue
    role=${CONT_ROLE[$name]:-other}
    cnt["$role"]=$(( ${cnt[$role]:-0} + 1 ))
  done
  for role in "${!cnt[@]}"; do
    printf 'trading_containers_running{role="%s"} %s\n' "$(esc "$role")" "${cnt[$role]}"
  done
}

# --- сессии ---------------------------------------------------------------
session_lines() {
  local body id strategy broker sector pair started age
  declare -A per_strategy=()
  local total=0

  if ! body=$(curl -sf --max-time 10 "$API/sessions?limit=1000"); then
    echo "trading_sessions_running_total 0"
    echo "trading_status_scrape_success 0"
    return 0
  fi

  while IFS=$'\t' read -r id strategy broker sector pair started; do
    [ -n "$id" ] || continue
    age=$(( $(date -u +%s) - $(date -u -d "$started" +%s) ))
    [ "$age" -lt 0 ] && age=0
    printf 'trading_session_info{id="%s",strategy="%s",broker="%s",sector="%s",pair="%s"} 1\n' \
      "$(esc "$id")" "$(esc "$strategy")" "$(esc "$broker")" "$(esc "$sector")" "$(esc "$pair")"
    printf 'trading_session_age_seconds{id="%s",strategy="%s",broker="%s",sector="%s",pair="%s"} %s\n' \
      "$(esc "$id")" "$(esc "$strategy")" "$(esc "$broker")" "$(esc "$sector")" "$(esc "$pair")" "$age"
    key="$strategy"$'\t'"$broker"$'\t'"$sector"
    per_strategy["$key"]=$(( ${per_strategy[$key]:-0} + 1 ))
    total=$(( total + 1 ))
  done < <(jq -r '.sessions[]
                 | select(.status == "running")
                 | [(.id | tostring), .strategy, .broker,
                    (.sector // "-"), (.params.pair // "-"), .started_at]
                 | @tsv' <<<"$body" 2>/dev/null)

  for key in "${!per_strategy[@]}"; do
    strategy=${key%%$'\t'*}
    rest=${key#*$'\t'}
    broker=${rest%%$'\t'*}
    sector=${rest#*$'\t'}
    printf 'trading_sessions_running{strategy="%s",broker="%s",sector="%s"} %s\n' \
      "$(esc "$strategy")" "$(esc "$broker")" "$(esc "$sector")" "${per_strategy[$key]}"
  done
  echo "trading_sessions_running_total $total"
  echo "trading_status_scrape_success 1"
}

tmp=$(mktemp "$OUT_DIR/.trading.prom.XXXXXX")
{
  echo "# HELP trading_status_scrape_success 1 если API сессий ответил при последнем сборе."
  echo "# TYPE trading_status_scrape_success gauge"
  echo "# HELP trading_container_up 1 если ожидаемый контейнер запущен."
  echo "# TYPE trading_container_up gauge"
  echo "# HELP trading_container_state_code 0=отсутствует, 1=остановлен, 2=запущен."
  echo "# TYPE trading_container_state_code gauge"
  echo "# HELP trading_containers_running Сколько контейнеров запущено по роли."
  echo "# TYPE trading_containers_running gauge"
  echo "# HELP trading_sessions_running Сессии в статусе running по стратегии и брокеру."
  echo "# TYPE trading_sessions_running gauge"
  echo "# HELP trading_sessions_running_total Всего сессий в статусе running."
  echo "# TYPE trading_sessions_running_total gauge"
  echo "# HELP trading_session_info 1 для каждой живой сессии."
  echo "# TYPE trading_session_info gauge"
  echo "# HELP trading_session_age_seconds Возраст живой сессии в секундах."
  echo "# TYPE trading_session_age_seconds gauge"

  container_lines
  running_by_role
  session_lines
} >"$tmp"

chmod 644 "$tmp"
mv -f "$tmp" "$OUT"
