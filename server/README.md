# Установка агентов на целевые серверы

На каждом сервере приложений крутится **promtail** (сбор логов) и **node_exporter**
(метрики хоста). Оба слушают только loopback — наружу не торчат.

```
целевой сервер                 машина мониторинга
┌───────────────┐   SSH   ┌──────────────────────┐
│ node_exporter │◄──-L────┤ Prometheus           │
│ 127.0.0.1:9100│  :9102  │                      │
│               │         │                      │
│ promtail ─────┼───-R───►│ Loki 127.0.0.1:3100  │
└───────────────┘  :3100  └──────────────────────┘
```

## 1. Ключ для туннелей

Машина мониторинга должна ходить по ключу на каждый сервер приложений:

```bash
# на машине мониторинга
ssh-keygen -y -f /root/.ssh/id_ed25519
```

Результат добавить в `~/.ssh/authorized_keys` на сервере приложений
(в `server/tunnels/*.service` указан конкретный хост).

## 2. Агенты на сервере приложений

Скрипты лежат в этом репозитории; на сервер их можно просто скопировать
(`scp server/install-*.sh root@<host>:/root/`) и запустить там.

```bash
./server/install-node-exporter.sh     # -> 127.0.0.1:9100
./server/install-promtail.sh          # -> логи в Loki через 127.0.0.1:3100
```

`install-promtail.sh` сам создаёт `/opt/promtail/docker-compose.yaml` и
поднимает контейнер. Конфиг promtail — один на все серверы, меняется здесь
(`promtail/promtail.yml`) и раскатывается повторным запуском скрипта.

## 3. Туннели на машине мониторинга

```bash
cp server/tunnels/apps.service /etc/systemd/system/apps-tunnel.service   # сервер приложений
cp server/tunnels/akm.service  /etc/systemd/system/akm-tunnel.service   # akm-сервер
systemctl daemon-reload
systemctl enable --now apps-tunnel akm-tunnel
```

Проверка: `./run.sh status` покажет доступность всех портов node_exporter.

## 4. Если предпочитаешь файрвол вместо SSH-туннеля

Вместо `-L/-R` можно открыть порты напрямую:

```bash
# на сервере приложений: метрики только с хоста мониторинга
ufw allow from <MONITORING_IP> to any port 9100 proto tcp
# на машине мониторинга: Loki только с сервера приложений
ufw allow from <APPS_HOST> to any port 3100 proto tcp
```

Недостаток по сравнению с туннелем: node_exporter и Loki видны из интернета
и живут дольше самого туннеля. Туннель предпочтительнее — он же является
и защитой, и каналом.
