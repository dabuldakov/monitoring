# app-metrics: per-replica метрики приложений

Prometheus-агент на сервере приложений. Запускается рядом с `makeup`/`chat`/`auth`
и сам находит все реплики через Docker DNS:

- `makeup-app` → все контейнеры сервиса `app` проекта makeup;
- `chat-app` → chat;
- `auth-app` → auth (уникальный alias в auth-compose).

Центральный Prometheus скрейпит `127.0.0.1:9190/federate` через `apps-tunnel`
и сохраняет `job`/`app`/`instance` каждого контейнера (`honor_labels: true`).
Так при `--scale app=3` в Grafana и алертах видна каждая реплика отдельно.

## Установка на сервер приложений

```bash
mkdir -p /opt/app-metrics
scp server/app-metrics/prometheus.yml server/app-metrics/docker-compose.yaml \
    root@<apps-host>:/opt/app-metrics/
ssh root@<apps-host>
cd /opt/app-metrics
docker compose up -d
```

Проверка:

```bash
curl -s http://127.0.0.1:9190/-/ready
curl -s 'http://127.0.0.1:9190/api/v1/targets?state=active' | grep -o '"health":"[^"]*"'
```

На машине мониторинга в `apps-tunnel` должен быть проброс `9190`, а в
`prometheus.yml` — job `app-federate`.
