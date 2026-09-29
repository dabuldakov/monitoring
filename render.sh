#!/usr/bin/env bash
# Рендерит конфиги из шаблонов + .env. Запускается автоматически
# в командах up/restart/reload, можно вручную: ./run.sh render
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo "!! нет .env — скопируй .env.example в .env"; exit 1; }
set -a; . ./.env; set +a

render() {
  local tpl="$1" out="$2"
  [[ -f "$tpl" ]] || return 0
  if command -v envsubst >/dev/null 2>&1; then
    envsubst < "$tpl" > "$out"
  else
    python3 - "$tpl" "$out" <<'PY'
import os, re, sys
tpl, out = sys.argv[1], sys.argv[2]
s = open(tpl).read()
s = re.sub(r'\$\{(\w+)\}', lambda m: os.environ.get(m.group(1), ''), s)
open(out, 'w').write(s)
PY
  fi
  echo "==> $(basename "$out") обновлён"
}

render prometheus/prometheus.yml.tmpl prometheus/prometheus.local.yml
render alertmanager/alertmanager.yml.tmpl alertmanager/alertmanager.local.yml

# Страховка от молчаливых забытых переменных: в .local-файлах не должно
# остаться незаполненных ${...}.
for f in prometheus/prometheus.local.yml alertmanager/alertmanager.local.yml; do
  if grep -qE '\$\{[A-Z_]+\}' "$f"; then
    echo "!! в $f остались неподставленные переменные — проверь .env:" >&2
    grep -oE '\$\{[A-Z_]+\}' "$f" | sort -u >&2
    exit 1
  fi
done

# Валидация: Prometheus и Alertmanager умеют проверять конфиг.
docker compose run --rm --no-deps --entrypoint /bin/promtool prometheus \
  check config /etc/prometheus/prometheus.yml >/dev/null \
  && echo "==> prometheus.yml валиден" \
  || { echo "!! prometheus.yml невалиден" >&2; exit 1; }
