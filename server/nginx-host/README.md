# Edge-nginx на хосте приложений

Копии файлов из `/etc/nginx/sites-enabled/` на `176.120.27.77`. Хранятся в git,
чтобы изменения edge-конфигурации не терялись при переустановке хоста.

| Файл | Домен | Upstream |
|---|---|---|
| `nginx-muzea-api.conf` | `api-muzea.su` | `127.0.0.1:8085` (makeup nginx) |
| `nginx-muzea-auth.conf` | `auth.muzea.su` | `127.0.0.1:8087` (auth nginx) |
| `nginx-muzea-chat.conf` | `chat-muzea.su` | `127.0.0.1:8086` (chat nginx) |

## Что важно в этих конфигах

- `client_max_body_size` по умолчанию маленький (1–25 МБ). Большие тела
  разрешены только для конкретных загрузчиков: `/api/news` (25 МБ),
  `/api/videos/upload` (2000 МБ), `/api/attachments/upload` (220 МБ).
  Иначе анонимный POST с гигабайтным телом буферизуется на диск до проверки
  авторизации.
- `X-Forwarded-For` **перезаписывается** адресом TCP-соединения
  (`$remote_addr`), а не дополняется клиентским заголовком. Приложение берёт
  первый элемент цепочки, поэтому иначе IP rate-limit обходится подменой
  заголовка. CDN перед nginx нет; при его появлении нужен `real_ip` с
  доверенными адресами.
- Для загрузок и legacy-стриминга отключена буферизация и увеличены таймауты.
- `limit_req` на edge: auth 10 r/s (burst 30), api 50 r/s (burst 100),
  chat 100 r/s (burst 200); загрузки — 3 r/s. Превышение отдаёт 429.
  Это второй эшелон к per-user лимитам в приложениях.

## Применение

```bash
sudo cp nginx-muzea-api.conf /etc/nginx/sites-enabled/nginx-muzea-api.conf
sudo cp nginx-muzea-auth.conf /etc/nginx/sites-enabled/nginx-muzea-auth.conf
sudo cp nginx-muzea-chat.conf /etc/nginx/sites-enabled/nginx-muzea-chat.conf
sudo nginx -t && sudo systemctl reload nginx
```

Перед изменением делайте бэкап текущих файлов. Блоки `# managed by Certbot`
не редактировать вручную: сертификаты обновляет certbot.
