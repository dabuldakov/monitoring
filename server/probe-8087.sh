#!/usr/bin/env bash
# Проверяем, реально ли akm-прогон ходит на 8087 снаружи.
set -euo pipefail

A="ssh -p 2222 -i /root/.ssh/id_ed25519 -o BatchMode=yes dmitry_buldakov@90.188.89.63"

echo "=== с akm: доступ к бэкенду wcm снаружи ==="
$A "curl -s -m 6 -o /dev/null -w '  /actuator/health -> %{http_code}\n' http://89.104.66.226:8087/actuator/health"
$A "curl -s -m 6 -o /dev/null -w '  /api/wcm/v0/country/all -> %{http_code}\n' http://89.104.66.226:8087/api/wcm/v0/country/all"

echo "=== с akm: контрольная проверка, что порт вообще фильтруется ==="
$A "curl -s -m 6 -o /dev/null -w '  9090 (Prometheus снаружи) -> %{http_code}\n' http://89.104.66.226:9090/actuator/health || echo '  9090 снаружи недоступен — фильтр работает'"

echo "=== какими адресами ходит k6 ==="
$A "grep -E '^(WCM_BASE_URL|K6_PROMETHEUS)' ~/loadtest/.env | sed 's/^/  /'"
