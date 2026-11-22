# Оптимизация monitoring-хоста (2026-11-22)

Хост: `89.104.66.226` — **1 vCPU / 2 ГБ RAM / 19 ГБ диск**, без swap.
На нём же живёт `world-country-monitoring` (frontend + backend + PostgreSQL).

## Симптомы до оптимизации

- load average **8.1** при 1 vCPU;
- CPU: **84.6% system**, kswapd0 — 19%;
- доступно RAM **394 МБ**, swap отсутствовал;
- PSI: CPU 74%, memory 56% (full 27%), IO 83%;
- Grafana/Prometheus-запросы заметно тормозили.

## Что изменено

| Что | Было | Стало |
|---|---|---|
| Swap | нет | 2 ГБ `/swapfile`, `vm.swappiness=10` |
| Journal | 1.5 ГБ | 158 МБ (`journalctl --vacuum-size=200M`) |
| Prometheus retention | 30d | 7d |
| Prometheus scrape/eval | 15s | 30s |
| Prometheus query limits | по умолчанию | timeout 30s, concurrency 4, samples 10M |
| Prometheus memory | без лимита | `mem_limit: 512m`, `GOMEMLIMIT=400MiB` |
| Loki retention | 14d | 7d |
| Grafana memory | без лимита | `mem_limit: 512m`, `GOMEMLIMIT=400MiB` |
| Alertmanager / blackbox | без лимитов | 96m / 64m |
| WCM backend / postgres / frontend | без лимитов | 512m / 256m / 640m |
| ModemManager | запущен | отключён (на VPS не нужен) |

## Результат сразу после изменений

- load average: **8.1 → 2.3** (1 мин), дальше снижается;
- system CPU: **84.6% → 8.3%**;
- доступно RAM: **394 МБ → 1.08 ГБ**;
- swap: 2 ГБ, занято ~0.6 ГБ;
- PSI CPU: **74% → 10%**; memory: **56% → 1.9%**; IO: **83% → 4.2%**;
- запрос Prometheus `up`: **3 мс**, максимальный scrape — 0.48 с.

## Важно

Это компенсация, а не решение: **1 vCPU / 2 ГБ** всё ещё мало для
Prometheus + Grafana + Loki + WCM. Для стабильной работы нужен как минимум
**2 vCPU / 4 ГБ RAM**, лучше 4 vCPU / 8 ГБ, диск 40+ ГБ. WCM лучше вынести
на отдельный хост.

## Откат

Резервные копии конфигов на хосте:
`*.bak-20261122T114818Z`. Изменения также в git.
