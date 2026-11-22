# Перенос бэкенда Muzea на новый хост Netpoint

Дата: 2026-11-21  
Новый хост: `176.120.27.77` (`administrator`, Ubuntu 26.04.1 LTS)  
Текущий хост: `168.222.194.206` (`root`, 2 vCPU / 2.9 ГБ / 19 ГБ)  
Мониторинг: `89.104.66.226`

## 1. Цель

Перенести весь бэкенд (makeup, chat, auth, MinIO, PostgreSQL, Redis, nginx,
app-metrics, node_exporter, promtail) с текущего сервера на новый, сохранив
домены, сертификаты, данные и пуш-уведомления. Мониторинг остаётся отдельным
хостом и переключается на новый сервер.

## 2. Новый хост

| Параметр | Значение |
|---|---|
| IP | `176.120.27.77/24` |
| ОС | Ubuntu 26.04.1 LTS, kernel 7.0.0-44 |
| Виртуализация | KVM |
| CPU | 4 vCPU (QEMU) |
| RAM | 7.2 ГиБ |
| Swap | 4 ГиБ |
| Диск | 96 ГиБ (LVM/ext4), свободно ~84 ГиБ |
| Диск (бенчмарк) | seq write ~2.9 ГБ/с, seq read ~12 ГБ/с (кэш); `ROTA=1` — артефакт QEMU, проверить `fio` при нагрузке |
| Сеть | 176.120.27.0/24, gw .1; внешний тест ~50 Мбит/с (Cloudflare), проверить реальный uplink |
| Docker | не установлен; в apt есть `docker.io 29.1.3`, `docker-compose-v2 2.40.3` |
| UFW | выключен |
| Время | UTC, NTP синхронизирован |
| SSH | `administrator` + ключ, passwordless sudo; root-логин не нужен |

Запас: новый хост спокойно вмещает 2 реплики makeup/chat + auth + MinIO + БД
(ориентировочно 4–5 ГБ RAM) и медиа на годы. Мониторинг оставляем отдельно.

## 3. Что переносим

| Компонент | Где сейчас | Куда |
|---|---|---|
| `makeup-backend` + nginx + Postgres + Redis | `/root/makeup-backend` | `~/muzea/makeup-backend` |
| `chat-backend` + nginx + Postgres + Redis | `/root/chat-backend` | `~/muzea/chat-backend` |
| `muzea-auth-service` + nginx + Postgres + Redis | `/root/muzea-auth-service` | `~/muzea/muzea-auth-service` |
| `shared-minio` | `/root/shared-minio` | `~/muzea/shared-minio` |
| Host nginx (TLS vhosts) | `/etc/nginx` | `/etc/nginx` |
| Let's Encrypt | `/etc/letsencrypt` | `/etc/letsencrypt` |
| app-metrics agent | `/opt/app-metrics` | `/opt/app-metrics` |
| node_exporter / promtail | контейнеры | те же контейнеры |
| `.env` приложений | `/root/*/.env` | `~/muzea/*/.env` |
| FCM service account | `chat-backend/src/main/resources/` (untracked) | туда же |
| Auth RSA key | `AUTH_RSA_PRIVATE_KEY` в `.env` | в `.env` |

Мониторинг, Prometheus, Grafana, Loki, Alertmanager и бэкапы остаются на
`89.104.66.226`; меняются только адрес туннеля, таргеты и цель бэкапа.

## 4. DNS

Сейчас (reg.ru):

| Домен | A | TTL |
|---|---|---|
| `api-muzea.su` | 168.222.194.206 | 41857 |
| `chat-muzea.su` | 168.222.194.206 | 85054 |
| `auth.muzea.su` | 168.222.194.206 | 3436 |
| `s3.muzea.su` | 168.222.194.206 | 3600 |
| `muzea.su` / `www` | 31.31.196.115 | — (не трогаем) |

План:

1. **T-48h**: в reg.ru выставить TTL зоны (SOA) и A-записей
   `api/chat/auth/s3` в **1h (3600)** — это минимум панели reg.ru (300 недоступно).
   «Minimum» (негативный TTL) оставить 3h, Refresh/Retry/Expire не трогать.
2. У `chat` старый TTL ~23.6 ч, у `api` ~11.6 ч: после снижения до 1h нужно
   подождать **не меньше 24 ч**, пока старые кэши истекут.
3. **Cutover**: сменить A на `176.120.27.77`. Из-за минимума 1h полное
   переключение занимает до часа — на это время старый nginx работает
   временным прокси на новый хост (см. 4.1), чтобы не было split-brain.
4. После стабилизации (1–2 недели) TTL можно вернуть на 1d.

### 4.1. Старый nginx как временный прокси на cutover

Из-за TTL 1h часть клиентов ещё час будет ходить на старый IP. Чтобы они не
попали в остановленный бэкенд и не было двух независимых БД:

1. Остановить приложения/БД/MinIO на старом хосте после финального копира.
2. Сохранить конфиги: `cp -a /etc/nginx /root/nginx-pre-cutover`.
3. В vhost'ах `api/chat/auth` заменить `proxy_pass http://127.0.0.1:8085`
   (8086/8087) на `proxy_pass https://176.120.27.77;` и добавить:
   ```nginx
   proxy_ssl_server_name on;
   proxy_ssl_name $host;
   proxy_set_header Host $host;
   proxy_set_header X-Real-IP $remote_addr;
   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   proxy_set_header X-Forwarded-Proto $scheme;
   ```
   В `s3` vhost — `proxy_pass https://176.120.27.77;` с теми же `Host`/SNI,
   `proxy_request_buffering off`, `client_max_body_size 0`.
4. `nginx -t && systemctl reload nginx` на старом хосте.
5. Переключить DNS на новый IP. Клиенты со старым DNS идут
   старый nginx → новый хост; клиенты с новым DNS — напрямую на новый.
6. Через 1–2 часа (после истечения TTL) остановить nginx на старом хосте.

Проверить, что приложение доверяет `X-Forwarded-For`
(`APP_TRUST_PROXY_HEADERS`), иначе rate limit по IP будет видеть старый прокси.
Для presigned URL `Host` должен остаться `s3.muzea.su` — иначе SigV4 не сойдётся.

## 5. Подготовка нового хоста

```bash
# с рабочей машины
ssh-copy-id -i ~/.ssh/deploy_ci_ed25519.pub administrator@176.120.27.77
ssh-copy-id -i ~/.ssh/id_ed25519_newserver.pub administrator@176.120.27.77
ssh administrator@176.120.27.77
```

На новом хосте:

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 nginx certbot python3-certbot-nginx git rsync ufw
sudo usermod -aG docker administrator
sudo systemctl enable --now docker nginx
# дефолтный сайт Ubuntu не должен перехватывать 80/443
sudo rm -f /etc/nginx/sites-enabled/default

# лог-ротация Docker, чтобы не забить диск
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker

# firewall: наружу только SSH/HTTP/HTTPS
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
```

Проверить, что провайдерский firewall тоже пропускает 80/443.

### Ключи для мониторинга и CI

С хоста мониторинга добавить его публичный ключ в
`administrator@176.120.27.77:~/.ssh/authorized_keys`:

```bash
ssh root@89.104.66.226 'cat /root/.ssh/id_ed25519.pub'
# полученную строку добавить на новом хосте в ~/.ssh/authorized_keys
```

CI-ключ (`deploy_ci_ed25519`) добавить туда же; приватный ключ положить в
GitHub Secrets `DEPLOY_SSH_KEY` (см. раздел 9).

## 6. Секреты и конфиги

Скопировать **не через git**, с правами `600`. Команды ниже удобнее выполнять
**с рабочей машины**, у которой есть SSH-доступ и к старому (`root@...`), и к
новому (`administrator@...`) хосту:

```bash
# с рабочей машины
rsync -a root@168.222.194.206:/root/makeup-backend/.env          ~/muzea/makeup-backend/.env
rsync -a root@168.222.194.206:/root/chat-backend/.env            ~/muzea/chat-backend/.env
rsync -a root@168.222.194.206:/root/muzea-auth-service/.env      ~/muzea/muzea-auth-service/.env
rsync -a root@168.222.194.206:/root/shared-minio/.env            ~/muzea/shared-minio/.env

# FCM: файл untracked, без него chat не стартует при FCM_ENABLED=true
scp root@168.222.194.206:/root/chat-backend/src/main/resources/firebase-service-account.json \
    ~/muzea/chat-backend/src/main/resources/firebase-service-account.json

# host nginx + сертификаты (важно для пиннинга в приложении)
rsync -a root@168.222.194.206:/etc/nginx/ /tmp/nginx-new/
rsync -a root@168.222.194.206:/etc/letsencrypt/ /tmp/le-new/
rsync -a /tmp/nginx-new/ administrator@176.120.27.77:/tmp/nginx-new/
rsync -a /tmp/le-new/ administrator@176.120.27.77:/tmp/le-new/
ssh administrator@176.120.27.77 'sudo rsync -a /tmp/nginx-new/ /etc/nginx/ && sudo rsync -a /tmp/le-new/ /etc/letsencrypt/'

# auth RSA key уже в .env; /root/muzea-auth-service-key.pem — на всякий случай
scp root@168.222.194.206:/root/muzea-auth-service-key.pem administrator@176.120.27.77:/home/administrator/muzea/muzea-auth-service-key.pem
ssh administrator@176.120.27.77 'chmod 600 ~/muzea/*/.env ~/muzea/chat-backend/src/main/resources/firebase-service-account.json ~/muzea/muzea-auth-service-key.pem'
```

Проверить, что в `.env` нет старого IP; все адреса — доменные
(`MINIO_URL=http://minio:9000`, `MINIO_PUBLIC_URL=https://s3.muzea.su` и т.п.).

### Важно: пиннинг сертификатов

Приложение пинит промежуточный CA Let's Encrypt (**YE1**) и корень
(ISRG Root YE) для `api/chat/auth`, а для `s3` — только корень. Поэтому:

- **копируем текущие сертификаты** (`/etc/letsencrypt`), а не выпускаем новые
  до cutover;
- после переноса проверяем цепочку:

```bash
openssl s_client -connect 176.120.27.77:443 -servername api-muzea.su -showcerts </dev/null \
  | openssl x509 -noout -issuer -subject
```

- при будущем `certbot renew` Let's Encrypt может выдать **другой
  промежуточный** CA — старые версии приложения перестанут подключаться.
  До следующего продления нужно добавить новые пины в приложение или
  перейти на пиннинг только корня. Это отдельная задача после переезда.
- после cutover **отключить `certbot.timer` на старом хосте**, чтобы продление
  не уходило на уже неактивный IP; на новом хосте включить таймер и проверить
  `certbot renew --dry-run`.

## 7. Приложения и данные

### 7.1. Клонирование

```bash
mkdir -p ~/muzea && cd ~/muzea
git clone git@github.com:dabuldakov/makeup.git makeup-backend
git clone git@github.com:dabuldakov/chat.git chat-backend
git clone git@github.com:dabuldakov/muzea-auth-service.git muzea-auth-service
git clone git@github.com:dabuldakov/shared-minio.git shared-minio

# зафиксировать те же коммиты, что в проде (или разрешить Flyway накатить новые)
cd ~/muzea && for d in makeup-backend chat-backend muzea-auth-service shared-minio; do
  echo "$d: $(git -C $d rev-parse --short HEAD)"
done
```

### 7.2. Сети и MinIO

```bash
docker network create shared-minio || true
cd ~/muzea/shared-minio && docker compose up -d
```

Первичный перенос данных MinIO (том `shared-minio-data`, ~1.8 ГБ). На старом
хосте остановить MinIO, чтобы получить консистентную копию:

```bash
# старый хост
cd /root/shared-minio && docker compose stop minio
docker run --rm -v shared-minio-data:/from -v /tmp:/to alpine \
  tar -C /from -cf /to/minio-data.tar .
# скопировать /tmp/minio-data.tar на новый хост

# новый хост
docker volume create shared-minio-data 2>/dev/null || true
docker run --rm -v shared-minio-data:/to -v /tmp:/from alpine \
  tar -C /to -xf /from/minio-data.tar
cd ~/muzea/shared-minio && docker compose up -d
```

Том хранит не только объекты, но и IAM (пользователи/политики), поэтому
`makeup`/`chat`/`backup` и их политики переезжают вместе с данными.

Альтернатива: `mc mirror` и повторное создание пользователей/политик по
`shared-minio/policies/*.json`.

### 7.3. PostgreSQL

Для каждой БД — остановить контейнер, скопировать том, поднять на новом
хосте (образ `postgres:17` тот же):

```bash
# старый хост
for v in makeup-backend_postgres_data chat-backend_postgres_data muzea-auth-service_postgres_data; do
  docker run --rm -v "$v":/from -v /tmp:/to alpine tar -C /from -cf "/to/$v.tar" .
done
# скопировать *.tar на новый хост

# новый хост: создать тома с теми же именами и распаковать
for v in makeup-backend_postgres_data chat-backend_postgres_data muzea-auth-service_postgres_data; do
  docker volume create "$v" 2>/dev/null || true
  docker run --rm -v "$v":/to -v /tmp:/from alpine tar -C /to -xf "/from/$v.tar"
done
```

Проверить владельца файлов (postgres UID 999) и что контейнеры стартуют без
инициализации пустой БД. Альтернатива — `pg_dump -Fc` + `pg_restore`; тома
проще и сохраняют роли/расширения.

### 7.4. Приложения

```bash
cd ~/muzea/makeup-backend && docker compose up -d --build
cd ~/muzea/chat-backend && docker compose up -d --build
cd ~/muzea/muzea-auth-service && docker compose up -d --build
```

Проверить health каждого (`/actuator/health`), логи на Flyway/ошибки.
Redis поднимается пустым — это нормально (rate limit/presence сбросятся).

### 7.5. Host nginx

Конфиги и сертификаты уже скопированы. Проверить:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Порты контейнеров `8085/8086/8087` сейчас публикуются на `0.0.0.0`.
На новом хосте **обязательно** привязать их к loopback (Docker обходит UFW):
в `docker-compose.yaml` каждого приложения заменить
`"8085:80"` → `"127.0.0.1:8085:80"` (аналогично 8086/8087), закоммитить и
передеплоить. Иначе приложения останутся доступны напрямую по IP.

**Связанное изменение в мониторинге:** blackbox сейчас проверяет health по
`${APPS_HOST}:8085/8086/8087`. После привязки к loopback эти проверки
сломаются — перевести их на публичные домены:
`https://api-muzea.su/actuator/health`,
`https://chat-muzea.su/actuator/health`,
`https://auth.muzea.su/actuator/health` (модуль `http_2xx`).

## 8. Тестирование до DNS

Использовать `--resolve`, чтобы проверить новый хост под нужным доменом:

```bash
for d in api-muzea.su chat-muzea.su auth.muzea.su s3.muzea.su; do
  echo "=== $d ==="
  curl -sk --resolve "$d:443:176.120.27.77" "https://$d/" -o /dev/null -w "%{http_code}\n"
done

curl -s --resolve api-muzea.su:443:176.120.27.77 https://api-muzea.su/actuator/health
curl -s --resolve chat-muzea.su:443:176.120.27.77 https://chat-muzea.su/actuator/health
curl -s --resolve auth.muzea.su:443:176.120.27.77 https://auth.muzea.su/actuator/health
curl -s --resolve s3.muzea.su:443:176.120.27.77 https://s3.muzea.su/minio/health/ready
```

Проверить цепочку сертификатов и совпадение с пинами приложения.

## 9. Cutover

1. Объявить окно (ночью, 30–60 минут).
2. Остановить приложения на старом хосте:
   ```bash
   cd /root/makeup-backend && docker compose stop app nginx
   cd /root/chat-backend && docker compose stop app nginx
   cd /root/muzea-auth-service && docker compose stop app nginx
   ```
   Подождать 15 минут (истечение presigned URL), затем остановить БД и MinIO
   для финальной консистентной копии.
3. Финальный перенос БД и MinIO (повторить п. 7.2–7.3, заменив тома).
4. Сменить A-записи `api/chat/auth/s3` на `176.120.27.77`.
5. Проверить `dig`, `curl --resolve`, затем обычный `curl` через DNS.
6. Запустить smoke-тесты (раздел 10).

Если что-то пошло не так — вернуть A-записи на старый IP; старый хост
остаётся с данными на момент cutover.

## 10. Что проверить после cutover

- [ ] `api/chat/auth/s3` health 200, TLS-цепочка та же.
- [ ] Вход по email/OTP (auth), refresh-токены.
- [ ] Chat: список чатов, отправка текста, вложение фото/видео через
      presigned, скачивание, пуш на Android/iOS.
- [ ] Makeup: лента, загрузка видео через presigned, проигрывание с Range,
      превью, новости с картинкой.
- [ ] S3: presigned PUT/GET, `MINIO_PUBLIC_URL`, бакеты/политики.
- [ ] Push FCM (Android/iOS) — доставка и переход по тапу.
- [ ] Мобильные приложения: старый APK/IPA (пиннинг) и новая сборка.
- [ ] Prometheus: `up` для node, minio, app-federate, per-replica app.
- [ ] Grafana/Loki/Alertmanager; алерты не горят.
- [ ] Бэкап: `backup-muzea.sh` вручную; дампы и `mc mirror` успешны.
- [ ] GitHub Actions: тестовый деплой одного репозитория.

## 11. Мониторинг, бэкапы и CI

### Monitoring host (`89.104.66.226`)

```bash
cd /opt/monitoring
# .env
APPS_HOST=176.120.27.77
APPS_SSH_TARGET=administrator@176.120.27.77
# APPS_SSH_KEY=/root/.ssh/id_ed25519 (публичный ключ уже на новом хосте)

# /etc/systemd/system/apps-tunnel.service
# заменить root@168.222.194.206 на administrator@176.120.27.77
sudo systemctl daemon-reload
sudo systemctl restart apps-tunnel

# перерендерить prometheus/alertmanager
./run.sh render
docker compose restart prometheus alertmanager
```

Проверить `127.0.0.1:9102` (node), `9103`/`9000` (MinIO), `9190` (app-metrics).

### Blackbox health

В `prometheus.yml.tmpl` заменить таргеты health с портов приложений на
публичные HTTPS-домены (см. раздел 7.5), иначе после привязки портов к
loopback три проверки станут `down`.

### Бэкапы

`server/backups/backup-muzea.sh` использует `APPS_SSH_TARGET` и
`MC_HOST_muzea` через туннель. После обновления `.env` и туннеля:
- запустить вручную, проверить `postgres` и `minio`;
- на monitoring-хосте свободно ~3.9 ГБ, а зеркало MinIO уже ~1.8 ГБ.
  Второе зеркало/рост медиа заполнит диск — нужно расширить диск monitoring
  или вынести бэкапы в облако/на отдельный диск. Это отдельная задача,
  но проверить до первого бэкапа нового хоста.

### GitHub Actions

В каждом из репозиториев `makeup`, `chat`, `muzea-auth-service`,
`shared-minio` обновить Secrets:

| Secret | Новое значение |
|---|---|
| `DEPLOY_HOST` | `176.120.27.77` |
| `DEPLOY_USER` | `administrator` |
| `DEPLOY_SSH_KEY` | приватный `deploy_ci_ed25519` |
| `DEPLOY_PATH` | `/home/administrator/muzea/<repo>` |

Публичный ключ добавить на новый хост. Проверить workflow вручную
(`workflow_dispatch`), затем обычный push.

## 12. app-metrics и node_exporter

```bash
# скопировать /opt/app-metrics со старого хоста
scp -r root@168.222.194.206:/opt/app-metrics administrator@176.120.27.77:/tmp/app-metrics
sudo mv /tmp/app-metrics /opt/app-metrics
cd /opt/app-metrics && docker compose up -d --build
```

Агент подключается к внешним сетям `makeup-backend_makeup-network`,
`chat-backend_chat-network`, `muzea-auth-service_auth-network` — они появятся
после старта приложений (имена проектов совпадают, если каталоги называются
так же: `makeup-backend`, `chat-backend`, `muzea-auth-service`).

`node_exporter` и `promtail`:

```bash
scp root@168.222.194.206:/root/install-node-exporter.sh ~/
scp root@168.222.194.206:/root/install-promtail.sh ~/
scp root@168.222.194.206:/root/promtail.yml ~/
# выполнить скрипты/поднять контейнеры; promtail смотрит в 127.0.0.1:3100
```

## 13. Откат

- Старый хост не выключать 1–2 недели; приложения на нём остановлены, БД и
  MinIO — снимок на момент cutover.
- При проблеме: вернуть A-записи на `168.222.194.206`, поднять приложения на
  старом хосте, проверить health.
- Если на новом хосте уже были записи — экспортировать БД/MinIO до отката;
  иначе они будут потеряны. Поэтому окно cutover делаем коротким и без
  активных пользователей.

## 14. После переезда

- Через 1–2 недели стабильной работы: остановить старый хост, сохранить
  финальные бэкапы, затем удалить.
- Вернуть DNS TTL 3600.
- Обновить `README`/`STORAGE.md` (новый хост, пути, бэкапы).
- Закрыть задачу с пиннингом: добавить новые промежуточные CA в приложение
  или перейти на пиннинг корня до следующего `certbot renew`.
- Рассмотреть второй app-хост/ingress и отдельный storage-хост — новый хост
  пока закрывает и приложения, и MinIO.

## 15. Риски

| Риск | Мера |
|---|---|
| Пиннинг сертификата: новый intermediate после renew | Копировать текущие серты; проверить цепочку; обновить пины до renew |
| FCM-файл untracked | Скопировать `firebase-service-account.json` до сборки chat |
| Auth RSA key только в `.env` | Скопировать `.env` с правами 600; проверить вход/refresh |
| Порты 8085–8087 на `0.0.0.0` | Привязать к 127.0.0.1 в compose; Docker обходит UFW |
| Высокий DNS TTL (chat ~24 ч) | Снизить до 300 за 48 ч |
| Бэкап-диск monitoring 3.9 ГБ | Расширить/вынести бэкап до первого запуска |
| Потеря данных при cutover | Остановить приложения, финальный консистентный копир, бэкап |
| Несовместимость Ubuntu 26.04/Docker 29 | Тестовый стенд, pin версий, `docker compose config` |
| Мониторинг не видит новый хост | Ключи, tunnel, `.env`, `run.sh render` |
| Presigned URL в полёте | Пауза 15 мин после остановки приложений |
| Старый хост заполнен (3.8 ГБ) | Не делать большие дампы на нём; копировать через новый хост/мониторинг |

## 16. Порядок и оценка

1. **T-48h** — TTL, бэкап, снапшот старого хоста: 1 ч.
2. **T-24h** — новый хост: Docker/nginx/ключи/firewall, клоны, конфиги: 2–3 ч.
3. **T-4h** — стенд: MinIO + БД + приложения + nginx, тесты `--resolve`: 2–4 ч.
4. **Cutover** — остановка, финальный копир, DNS, smoke: 1–2 ч + TTL.
5. **После** — мониторинг/бэкап/CI, мобильные тесты: 2–3 ч.
6. **1–2 недели** — наблюдение и откат-окно, затем decommission.

## 17. Статус cutover (2026-11-22)

Выполнено:

- SSH: парольный вход на новом хосте отключён (`PasswordAuthentication no`);
  работают ключи администратора, CI и мониторинга.
- Данные: финальные дампы PostgreSQL сняты в `06:36 UTC`, MinIO докачан
  (`rsync`), restore выполнен. Построчная сверка всех таблиц старого и нового
  хостов совпала.
- Стек на новом хосте поднят: makeup/chat/auth healthy, MinIO ready;
  публичные API, медиа, Range и S3 проверены через `--resolve`.
- Порты приложений привязаны к `127.0.0.1` и закоммичены
  (`40d6d21`, `2e45415`, `7e4b571`).
- Старый nginx переключён в прокси на `https://176.120.27.77`
  (`06:38 UTC`); публичный трафик уже обслуживает новый хост.
- Мониторинг: `apps-tunnel` переведён на `administrator@176.120.27.77`,
  blackbox-таргеты — на публичные HTTPS-домены, Prometheus перерендерен,
  promtail на новом хосте пишет в Loki.
- Бэкап `muzea-backup.service` вручную: 3 дампа + `mc mirror` успешны.
- На старом хосте отключён `certbot.timer`, остановлены приложения, БД,
  Redis, MinIO, promtail и app-metrics. Работают только host-nginx и
  node_exporter.

Осталось:

- [ ] Переключить A-записи `api/chat/auth/s3` на `176.120.27.77` в reg.ru
      (делает владелец в панели; TTL уже 3600).
- [ ] После DNS: `certbot renew --dry-run` на новом хосте, включить
      `certbot.timer`.
- [ ] Обновить GitHub Secrets `DEPLOY_*` в четырёх репозиториях
      (нужен токен с доступом к приватным репозиториям).
- [ ] Мобильные smoke-тесты: вход, чат, вложения, пуш, пиннинг сертификата.
- [ ] Через 1–2 недели остановить старый хост; расширить диск мониторинга
      (свободно ~3.6 ГБ при зеркале MinIO 2.0 ГБ).
