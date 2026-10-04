# Мониторинг сервисов

Постоянный стек наблюдаемости: **метрики, логи, алерты, Grafana**.
Живёт на отдельной машине и не связан с нагрузочными прогонами — они живут
в отдельном репозитории `loadtest` и пишут метрики сюда через remote-write.

## Что внутри

| Компонент | Роль | Наружу |
|---|---|---|
| Prometheus | метрики всех серверов и приложений, Правила алертов | нет (`127.0.0.1:9090`) |
| Alertmanager | рассылка алертов на email | нет (`127.0.0.1:9093`) |
| blackbox_exporter | живость приложений (`/actuator/health`), TCP, ICMP | нет (`127.0.0.1:9115`) |
| Loki | хранилище логов всех контейнеров, ретеншн 14 дней | нет (`127.0.0.1:3100`) |
| Grafana | дашборды: k6, node_exporter, availability, логи | да, адрес из `.env` |

Агенты на целевых серверах (`server/`): **node_exporter** (метрики хоста)
и **promtail** (сбор docker-логов в Loki). Оба слушают только loopback,
доступны через SSH-туннели — подробности в [server/README.md](server/README.md).

## Быстрый старт

```bash
git clone <repo> /opt/monitoring && cd /opt/monitoring
cp .env.example .env && nano .env     # хосты, порты, пароль Grafana, SMTP
./run.sh up
./run.sh status
```

`./run.sh up` рендерит конфиги из шаблонов и `.env` в `*.local.yml`
(в git не коммитятся), проверяет их через `promtool` и поднимает стек.

## Где что настраивается

**Все таргеты — только в `.env`.** В `prometheus/prometheus.yml.tmpl` нет ни
одного зашитого IP, конфиг генерируется из шаблона. Чтобы добавить сервер,
достаточно дописать переменные в `.env`.

Шаблоны, которые рендерятся (`./run.sh render`):

| Шаблон | Результат | Подставляется |
|---|---|---|
| `prometheus/prometheus.yml.tmpl` | `prometheus/prometheus.local.yml` | хосты, порты приложений, порты туннелей |
| `alertmanager/alertmanager.yml.tmpl` | `alertmanager/alertmanager.local.yml` | SMTP и адреса получателей |

## Команды

```
./run.sh up / down / restart / reload   — жизненный цикл
./run.sh status                          — контейнеры + доступность туннелей
./run.sh logs                            — логи стека
./run.sh render                          — перегенерировать конфиги из .env
./run.sh backup                          — дамп правил Alertmanager и datasource'ов
```

## Данные

Docker volume'ы: `prometheus_data`, `alertmanager_data`, `loki_data`, `grafana_data`.
`./run.sh down` их сохраняет; `docker compose down -v` удалит — сносит всю
историю метрик и логов.

## Логи

Promtail на каждом сервере приложений шлёт логи в Loki; лейблы:

```
{app="chat"}                     логи chat
{app="makeup"}                   логи makeup
{app="minio"}                    логи общего MinIO (проект shared-minio)
{app="wcm"}                      логи world-country-monitoring
{app=~"chat|makeup"} |="ERROR"   ошибки
{app="chat"} | json | user="42"  логи конкретного пользователя
```

Дашборд `Logs / Backend Logs` уже настроен на эти лейблы.
