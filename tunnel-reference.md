# Chisel & wstunnel: референс реализации

> Конфиги, параметры, установка — без личных данных.
> Основано на реальном развёртывании. Используется как база для скриптов.
> Дата: 2026-02-18

---

## Общие требования

- VPS: Debian/Ubuntu
- nginx установлен и запущен
- **Поддомен с Let's Encrypt сертификатом** (НЕ Cloudflare Origin cert!)
- **DNS: серое облако** в Cloudflare (без проксирования через CF)
- Если порт 443 занят другим сервисом (Xray, etc.) — используй порт 2087 или 8443

> **Почему не Cloudflare CDN:** CF блокирует бинарные WebSocket данные обоих инструментов. Нужно прямое соединение с сервером.

---

# ЧАСТЬ 1: CHISEL

**GitHub:** https://github.com/jpillora/chisel

## Как работает

SSH-туннель поверх WebSocket. Клиент поднимает SOCKS5 на localhost, трафик летит через зашифрованный WebSocket к серверу.

## Серверная часть

### Установка

```bash
# Получить актуальную версию
CHISEL_VER=$(curl -s https://api.github.com/repos/jpillora/chisel/releases/latest \
  | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*')

# Скачать и установить
curl -fLo /tmp/chisel.gz \
  "https://github.com/jpillora/chisel/releases/download/${CHISEL_VER}/chisel_${CHISEL_VER#v}_linux_amd64.gz"
gunzip /tmp/chisel.gz
chmod +x /tmp/chisel
sudo mv /tmp/chisel /usr/local/bin/chisel

# Проверка
chisel --version

# Альтернатива — из исходников (нужен Go)
go install github.com/jpillora/chisel@latest
```

### Файл аутентификации

```bash
sudo mkdir -p /etc/chisel

sudo tee /etc/chisel/auth.json << 'EOF'
{
  "LOGIN:PASSWORD": [".*:.*"]
}
EOF

sudo chmod 600 /etc/chisel/auth.json
sudo chown nobody:nogroup /etc/chisel/auth.json
```

**Критичные детали:**
- Значение `[".*:.*"]` — разрешить все remotes. `[""]` (пустая строка) может не работать
- Файл вместо `--auth` флага: пароль в командной строке виден через `ps aux`

### Systemd сервис

Файл `/etc/systemd/system/chisel.service`:

```ini
[Unit]
Description=Chisel Tunnel Server
After=network.target

[Service]
ExecStart=/usr/local/bin/chisel server \
  --host 127.0.0.1 \
  -p 7777 \
  --authfile /etc/chisel/auth.json \
  --socks5
Restart=always
RestartSec=5
User=nobody

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now chisel
```

**Критичные детали:**
- `--host 127.0.0.1` и `-p 7777` — **отдельными флагами**. Chisel не принимает `-p 127.0.0.1:7777`
- Без `--host 127.0.0.1` сервис слушает на `0.0.0.0` — доступен снаружи
- `--reverse` не нужен для SOCKS5 прокси (убирает attack surface)

**Проверка:**
```bash
sudo systemctl status chisel
ss -tlnp | grep 7777
# Должно быть: 127.0.0.1:7777 — не 0.0.0.0!
```

### Nginx location блок

Добавить **перед** первым `location /` в существующий server block:

```nginx
location /SECRET_PATH/ {
    proxy_pass http://127.0.0.1:7777/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

**Критичные детали:**
- `proxy_pass http://127.0.0.1:7777/;` — trailing slash **обязателен**. nginx стрипает `/SECRET_PATH/` и передаёт Chisel чистый путь `/`. Без слеша WebSocket upgrade ломается
- `proxy_buffering off` — **обязателен**. Без него данные буферируются nginx и не текут через WebSocket
- `SECRET_PATH` — случайная строка: `openssl rand -hex 16`

## Клиентская часть

### Установка

**Linux/Mac:**
```bash
# Скачать бинарник (проверить платформу: amd64/arm64/386)
curl -fLo chisel.gz \
  https://github.com/jpillora/chisel/releases/download/v1.11.3/chisel_1.11.3_linux_amd64.gz
gunzip chisel.gz && chmod +x chisel
sudo mv chisel /usr/local/bin/

# Или из исходников
go install github.com/jpillora/chisel@latest
```

**Добавить в PATH (zsh):**
```bash
echo 'export PATH="$PATH:$(go env GOPATH)/bin"' >> ~/.zshrc && source ~/.zshrc
```

### Подключение

```bash
chisel client \
  --auth "LOGIN:PASSWORD" \
  --keepalive 25s \
  https://yourdomain.com:PORT/SECRET_PATH/ \
  socks
```

SOCKS5 прокси запустится на `127.0.0.1:1080`.

**Критичные детали:**
- `socks` — SOCKS5 на клиенте, трафик выходит через сервер ✅
- `R:socks` — SOCKS5 на сервере, трафик выходит через клиента ❌ (не то)
- Trailing slash в URL `/SECRET_PATH/` — **обязательна**. Без неё nginx делает 301 redirect, WebSocket не умеет редиректы
- Если порт 443 занят другим сервисом — указать порт явно: `:2087`
- `--keepalive 25s` — предотвращает таймаут соединения

### Проверка

```bash
# IP должен быть IP сервера, не твой
curl --socks5-hostname 127.0.0.1:1080 https://2ip.ru

# Сайт-прикрытие работает
curl -o /dev/null -w "%{http_code}" https://yourdomain.com/
# → 200

# SECRET_PATH возвращает 404 — это НОРМАЛЬНО
# Chisel отвечает только на WebSocket upgrade
curl -o /dev/null -w "%{http_code}" https://yourdomain.com:PORT/SECRET_PATH/
# → 404
```

---

# ЧАСТЬ 2: WSTUNNEL

**GitHub:** https://github.com/erebe/wstunnel

## Как работает

Оборачивает TCP/UDP напрямую в WebSocket без SSH-слоя. Легче и быстрее Chisel. Тот же принцип сокрытия.

## Серверная часть

### Установка

```bash
# Актуальная версия
WSTUNNEL_VER=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest \
  | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*')

# Скачать (бинарник называется wstunnel-cli начиная с v10)
curl -fLo /tmp/wstunnel.tar.gz \
  "https://github.com/erebe/wstunnel/releases/download/${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER#v}_linux_amd64.tar.gz"
tar -xzf /tmp/wstunnel.tar.gz -C /tmp/
chmod +x /tmp/wstunnel
sudo mv /tmp/wstunnel /usr/local/bin/wstunnel

# Проверка (в v10+ бинарник может называться wstunnel-cli)
wstunnel --version
```

**Через Docker (сервер на VPS):**
```bash
docker run -d \
  --name wstunnel-server \
  --restart always \
  --network host \
  ghcr.io/erebe/wstunnel \
  wstunnel-cli server \
  ws://127.0.0.1:8888
```

### Systemd сервис

Файл `/etc/systemd/system/wstunnel.service`:

```ini
[Unit]
Description=wstunnel Server
After=network.target

[Service]
ExecStart=/usr/local/bin/wstunnel server \
  ws://127.0.0.1:8888
Restart=always
RestartSec=5
User=nobody

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wstunnel
```

**Проверка:**
```bash
sudo systemctl status wstunnel
ss -tlnp | grep 8888
# Должно быть: 127.0.0.1:8888
```

**Критичная деталь:**
- `--restrict-http-upgrade-path-prefix` **не использовать** совместно с nginx trailing slash proxy_pass. nginx стрипает путь → wstunnel получает `/` → restriction не совпадает → 404. Безопасность обеспечивает nginx (только secret path доходит до wstunnel).

### Nginx location блок

Такой же как для Chisel, только порт 8888:

```nginx
location /SECRET_PATH/ {
    proxy_pass http://127.0.0.1:8888/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
```

## Клиентская часть

### Установка

```bash
# Скачать бинарник для своей ОС/архитектуры
# https://github.com/erebe/wstunnel/releases
# В v10+ бинарник называется wstunnel или wstunnel-cli (проверить в архиве)

# Добавить в PATH
echo 'export PATH="$PATH:/path/to/wstunnel/dir"' >> ~/.zshrc && source ~/.zshrc
```

**Docker клиент:**
```bash
docker run -d \
  --name wstunnel-client \
  --restart always \
  --network host \
  ghcr.io/erebe/wstunnel \
  wstunnel-cli client \
  -L socks5://127.0.0.1:1082 \
  wss://yourdomain.com:PORT/SECRET_PATH/
```

> В Docker НЕ использовать кавычки вокруг аргументов — они передаются буквально.

### Подключение

```bash
wstunnel client \
  -L socks5://127.0.0.1:1082 \
  wss://yourdomain.com:PORT/SECRET_PATH/
```

SOCKS5 прокси на `127.0.0.1:1082`.

**Критичные детали:**
- Trailing slash в URL `/SECRET_PATH/` — **обязательна**
- `--tls-skip-verify` не существует в v10, используй `--tls-sni-override DOMAIN` для прямого IP подключения
- Если порт 443 занят — указывать порт явно

### Проверка

```bash
curl --socks5-hostname 127.0.0.1:1082 https://2ip.ru
# → IP сервера
```

---

# ЧАСТЬ 3: ОБЩЕЕ

## Throne / sing-box + TUN режим

При включённом TUN TUN перехватывает ВСЁ включая соединение самого туннель-клиента → петля → бесконечный reconnect.

**Обязательные правила маршрутизации:**

| Тип | Значение | Исходящий |
|-----|----------|-----------|
| processName | `chisel` (или `wstunnel`) | direct |
| ip | `127.0.0.1` | direct |
| domain_suffix | `yourdomain.com` | direct |

## Чек-лист

**Сервер:**
- [ ] Chisel/wstunnel: `systemctl is-active` → active
- [ ] `ss -tlnp | grep PORT` → `127.0.0.1:PORT` (не `0.0.0.0`)
- [ ] nginx: `proxy_buffering off` и trailing slash в `proxy_pass`
- [ ] Сертификат: Let's Encrypt (не Cloudflare Origin)
- [ ] DNS: прямое подключение (серое облако, не Cloudflare CDN)

**Клиент:**
- [ ] Trailing slash в URL подключения
- [ ] Порт указан явно если 443 занят
- [ ] `curl --socks5-hostname 127.0.0.1:PORT https://2ip.ru` → IP сервера

## Частые ошибки

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `x509: certificate valid for api-maps.yandex.ru` | Порт 443 занят Xray/другим | Указать порт явно: `:2087` |
| Chisel `Connected` но curl зависает | Нет `proxy_buffering off` | Добавить в nginx location |
| WebSocket handshake 404 | Нет trailing slash в URL | `https://domain.com/SECRET/` |
| Chisel не стартует, status=1 | `-p 127.0.0.1:7777` неверно | Разделить: `--host 127.0.0.1 -p 7777` |
| `wstunnel: No such file or directory` (Docker) | Не указан `wstunnel-cli` | `docker run ... wstunnel-cli client ...` |
| TUN: бесконечный reconnect | TUN ловит трафик клиента | Добавить processName в direct |

---

#chisel #wstunnel #tunnel #socks5 #nginx #proxy
