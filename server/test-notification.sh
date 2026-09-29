#!/usr/bin/env bash
# Проверка email-уведомлений Alertmanager.
#
# Зачем это нужно: ошибки в шаблонах писем (например, вызов функции, которой
# нет в Alertmanager) НЕ видны при загрузке конфига и при amtool
# check-config — они возникают в момент отправки. То есть о плохой теме
# письма можно узнать только тогда, когда что-то уже упало. Этот скрипт
# отправляет синтетический алерт и сразу смотрит логи на ошибку.
#
# Запуск на машине мониторинга: ./server/test-notification.sh [имя-сервера]
set -euo pipefail
cd "$(dirname "$0")/.."

SERVER="${1:-Muzea}"
AM=http://127.0.0.1:9093

[[ -f .env ]] || { echo "!! нет .env"; exit 1; }
set -a; . ./.env; set +a

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "==> отправляю тестовый алерт ServerHostDown для «$SERVER»"
curl -s -XPOST "$AM/api/v2/alerts" -H 'Content-Type: application/json' -d "[{
  \"labels\": {
    \"alertname\": \"TestNotification\",
    \"server\": \"$SERVER\",
    \"severity\": \"critical\",
    \"instance\": \"127.0.0.1\"
  },
  \"annotations\": {
    \"summary\": \"Тестовое уведомление для сервера $SERVER\",
    \"description\": \"Это тест, письмо можно удалить.\"
  },
  \"startsAt\": \"$now\",
  \"endsAt\": \"$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)\"
}]"

# Ждём group_wait/цикл отправки.
sleep 20

# Позитивная проверка: алерт должен появиться в API Alertmanager.
# Без неё скрипт «проходил» бы и тогда, когда уведомление вообще не
# пыталось отправить (Alertmanager не логирует успешные отправки, а
# grep по ошибкам молчит в таком случае).
echo "==> проверяю, что алерт принят Alertmanager"
if ! curl -s "$AM/api/v2/alerts" | grep -q TestNotification; then
  echo "!! Alertmanager не принял тестовый алерт — проверь, что он запущен:" >&2
  echo "   docker compose ps alertmanager" >&2
  exit 1
fi
echo "    алерт в Alertmanager, шаблон отработал"

echo "==> проверяю логи Alertmanager на ошибки шаблона/SMTP"
if docker compose logs --since 2m alertmanager 2>&1 \
     | grep -iE 'notify.*fail|function .* not defined|template:|smtp.*error'; then
  echo
  echo "!! уведомления НЕ отправились — см. ошибку выше." >&2
  echo "!! Проверь шаблон Subject в alertmanager/alertmanager.yml.tmpl." >&2
  exit 1
fi

echo "==> ошибок нет, письмо должно прийти на ${ALERT_EMAIL_TO}"
echo "    Проверь тему: [CRITICAL] $SERVER: TestNotification"
echo "    Если тема пришла с IP вместо имени — в .env не задана"
echo "    переменная *_SERVER_NAME для этого сервера."
