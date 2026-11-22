# Два инстанса приложений и rolling-деплой

Дата: 2026-11-22  
Хост: `176.120.27.77`  
Сервисы: makeup, chat, auth

## Схема

На одной ноде запущены по два именованных инстанса каждого приложения:

```
host nginx :443
 ├─ 127.0.0.1:8085 → makeup nginx → makeup-app / makeup-app-2
 ├─ 127.0.0.1:8086 → chat nginx   → chat-app / chat-app-2
 └─ 127.0.0.1:8087 → auth nginx   → auth-app / auth-app-2
```

PostgreSQL, Redis и MinIO — по одному экземпляру, общие для обоих инстансов.
Приложения stateless: JWT, Redis-кэш/локи, advisory-locks PostgreSQL для
`@Scheduled`, `SKIP LOCKED` для медиа-задач.

## Почему два именованных сервиса, а не `deploy.replicas`

Docker Compose не умеет rolling-обновление реплик: `up -d --build` пересоздаёт
все контейнеры сервиса. Поэтому в compose явно описаны `app` и `app2`, а
`scripts/rolling-deploy.sh` обновляет их по одному, временно убирая
обновляемый инстанс из upstream nginx.

## Как проходит деплой

1. Собирается образ с тегом `APP_IMAGE`.
2. `app2` убирается из `/etc/nginx/conf.d/upstream.d/upstream.conf`,
   nginx делает graceful reload — весь трафик идёт на `app`.
3. `app2` пересоздаётся, ждём `healthy`.
4. `app2` возвращается в upstream.
5. `app1` убирается из upstream — трафик идёт на новый `app2`.
6. `app1` пересоздаётся, ждём `healthy`.
7. В upstream возвращаются оба инстанса.

Если новый инстанс не стал healthy, скрипт падает, а второй продолжает
обслуживать трафик. Nginx при этом уже указывает только на рабочий инстанс.

## Ручной деплой

```bash
cd ~/muzea/<makeup-backend|chat-backend|muzea-auth-service>
git fetch origin main
git reset --hard origin/main
chmod +x scripts/rolling-deploy.sh
APP_IMAGE="muzea/<makeup|chat|auth>:$(date -u +%Y%m%dT%H%M%SZ)" \
  ./scripts/rolling-deploy.sh
```

## Откат

Перед сборкой скрипт тегирует текущий образ как `muzea/<app>:rollback`:

```bash
SKIP_BUILD=1 APP_IMAGE=muzea/makeup:rollback ./scripts/rolling-deploy.sh
```

## Требования

- `SERVER_SHUTDOWN=graceful` и `stop_grace_period: 30s` — чтобы инстанс
  дорабатывал запросы при остановке.
- Healthcheck `/actuator/health` — по нему скрипт ждёт готовности.
- В nginx: `max_fails=2 fail_timeout=5s` и `proxy_next_upstream`.
- Миграции Flyway должны быть обратно совместимыми: во время деплоя одна
  версия приложения работает со старой схемой, другая — с новой.

## Метрики

`/opt/app-metrics/prometheus.yml` скрейпит оба алиаса каждого приложения
(`*-app` и `*-app-2`). Центральный Prometheus получает их через federation.

## Ограничения

- Это масштабирование и деплой без простоя, но **не** защита от падения ноды:
  PostgreSQL/Redis/MinIO остаются на этой же ноде.
- Вторая нода добавляется позже: её nginx включается во внешний балансировщик,
  приложения остаются stateless.
- GitHub Actions сейчас заблокированы биллингом аккаунта; до исправления
  деплой выполняется вручную командами выше.
