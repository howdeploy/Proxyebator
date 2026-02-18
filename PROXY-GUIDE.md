# Устойчивый скрытый прокси для личного пользования

> Техническое задание и обзор на основе рабочей конфигурации
> Дата: 2026-02-18

---

## Оглавление

1. [Зачем это нужно](#1-зачем-это-нужно)
2. [Принцип работы](#2-принцип-работы)
3. [Стек технологий](#3-стек-технологий)
4. [Архитектура](#4-архитектура)
5. [Серверная часть — ТЗ](#5-серверная-часть--тз)
6. [Клиентская часть — ТЗ](#6-клиентская-часть--тз)
7. [Критичные детали (грабли)](#7-критичные-детали-грабли)
8. [Модель угроз](#8-модель-угроз)
9. [Чек-листы](#9-чек-листы)
10. [Альтернативные инструменты](#10-альтернативные-инструменты)

---

## 1. Зачем это нужно

**Задача:** обеспечить доступ к заблокированным ресурсам из РФ так, чтобы:
- Провайдер (ТСПУ/DPI) не видел факт использования прокси/VPN
- Сервер не светил свой IP напрямую
- Трафик выглядел как обычное HTTPS-соединение с легитимным сайтом
- Работало стабильно без постоянного внимания

**Ключевой принцип:** прокси-трафик маскируется под обычный HTTPS WebSocket внутри легитимного сайта. Ни DPI, ни active probing не могут отличить прокси от обычного веб-сервиса.

---

## 2. Принцип работы

### Почему не обычный VPN/SOCKS5

| Протокол | Блокируется DPI? | Почему |
|----------|-----------------|--------|
| OpenVPN | Да | Характерный handshake, легко детектируется |
| WireGuard | Да | UDP трафик с узнаваемым паттерном |
| Shadowsocks | Частично | Рандомный трафик выделяется на фоне обычного HTTPS |
| VLESS/VMess напрямую | Частично | Active probing определяет нестандартный сервис |
| **WebSocket через HTTPS** | **Нет** | **Неотличим от обычного веб-трафика** |

### Как работает маскировка

```
Что видит ТСПУ:

  Клиент ──HTTPS──> Cloudflare IP (SNI: chat.example.com)

Это выглядит как обычный визит на сайт. Внутри HTTPS:

  [TLS шифрование]
    [WebSocket upgrade на /секретный-путь/]
      [SSH-туннель (Chisel) или TCP-обёртка (wstunnel)]
        [SOCKS5 трафик — существует ТОЛЬКО на localhost]
```

**SOCKS5 хендшейк (`0x05`) нигде не появляется в открытом виде** — он существует только между приложением и локальным портом. Весь трафик наружу уже обёрнут в WebSocket внутри TLS.

### Сайт-прикрытие (cover site)

На том же домене и порту работает настоящий сайт (например, XMPP чат). Если кто-то зайдёт на `https://chat.example.com` — увидит реальный сайт. Прокси доступен только по секретному пути, который отвечает на WebSocket upgrade, а на обычный GET возвращает 404.

---

## 3. Стек технологий

### Основной вариант: Chisel

| Компонент | Что | Зачем |
|-----------|-----|-------|
| **Chisel** | SSH-туннель поверх WebSocket | Шифрованный туннель, auth, SOCKS5 |
| **nginx** | Reverse proxy | WebSocket proxy, TLS termination, сайт-прикрытие |
| **Let's Encrypt** | TLS сертификат | Валидный HTTPS |
| **Cloudflare** | CDN (опционально) | Скрытие IP сервера, дополнительный слой |
| **Throne** | GUI прокси-клиент (sing-box) | TUN режим, маршрутизация per-app |

### Альтернативный вариант: wstunnel

| Компонент | Отличие от Chisel |
|-----------|-------------------|
| **wstunnel** | TCP/UDP напрямую в WebSocket, без SSH-слоя. Легче, быстрее |

Оба варианта работают через ту же инфраструктуру (nginx + TLS + Cloudflare).

---

## 4. Архитектура

### Схема прохождения трафика

```
┌─────────────────────────────────────────────────┐
│  КЛИЕНТ                                         │
│                                                  │
│  Приложение (Firefox, Telegram...)               │
│       │                                          │
│       ▼                                          │
│  Throne (sing-box) ← TUN/System Proxy            │
│       │                                          │
│       ▼                                          │
│  Chisel client ← SOCKS5 на 127.0.0.1:1080       │
│       │ WSS к chat.example.com/SECRET_PATH/      │
└───────┼──────────────────────────────────────────┘
        │ HTTPS (TLS 1.3)
        ▼
┌───────────────────┐
│  Cloudflare CDN   │  ← ТСПУ видит только это
│  (SNI: chat...)   │     Обычный HTTPS к CF
└───────┼───────────┘
        │ HTTPS
        ▼
┌─────────────────────────────────────────────────┐
│  СЕРВЕР (VPS)                                   │
│                                                  │
│  nginx :443 (или :2087)                          │
│    ├─ /           → сайт-прикрытие (XMPP и т.д.)│
│    └─ /SECRET/    → proxy_pass 127.0.0.1:7777   │
│                         │                        │
│                         ▼                        │
│                   Chisel server                   │
│                   127.0.0.1:7777                  │
│                         │                        │
│                         ▼                        │
│                   Интернет                        │
└─────────────────────────────────────────────────┘
```

### Два режима Cloudflare

| Режим | DNS облако | Плюсы | Минусы |
|-------|------------|-------|--------|
| **Через CF CDN** | Оранжевое (proxied) | IP сервера скрыт | WS timeout ~100 сек на Free плане |
| **Напрямую** | Серое (DNS only) | Нет таймаутов, стабильнее | IP сервера виден в DNS |

**Рекомендация:** начать с серого облака (стабильнее), переключить на оранжевое если нужно скрыть IP.

---

## 5. Серверная часть — ТЗ

### 5.1 Требования к VPS

- **ОС:** Debian 12+ или Ubuntu 22.04+
- **Локация:** НЕ Россия. Рекомендуется: Нидерланды, Германия, Финляндия
- **Порты:** 443 (или 2087/8443 если 443 занят)
- **nginx** установлен и работает
- **Домен** с Let's Encrypt сертификатом (НЕ Cloudflare Origin cert)

### 5.2 Chisel server

**Установка:**
```bash
CHISEL_VER=$(curl -s https://api.github.com/repos/jpillora/chisel/releases/latest \
  | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*')
curl -fLo /tmp/chisel.gz \
  "https://github.com/jpillora/chisel/releases/download/${CHISEL_VER}/chisel_${CHISEL_VER#v}_linux_amd64.gz"
gunzip /tmp/chisel.gz
chmod +x /tmp/chisel
sudo mv /tmp/chisel /usr/local/bin/chisel
```

**Аутентификация (файл, не CLI):**
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

> Почему файл а не `--auth`: пароль в командной строке виден через `ps aux`.
> Значение `[".*:.*"]` — разрешить все remotes. `[""]` может не работать.

**Systemd сервис** `/etc/systemd/system/chisel.service`:
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

> `--host 127.0.0.1` и `-p 7777` — ОТДЕЛЬНЫМИ флагами. Chisel не принимает `-p 127.0.0.1:7777`.
> Без `--host 127.0.0.1` сервис слушает на `0.0.0.0` — доступен снаружи!
> `--reverse` НЕ нужен. Убирает attack surface.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now chisel
```

### 5.3 wstunnel server (альтернатива)

**Установка:**
```bash
WSTUNNEL_VER=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest \
  | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*')
curl -fLo /tmp/wstunnel.tar.gz \
  "https://github.com/erebe/wstunnel/releases/download/${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER#v}_linux_amd64.tar.gz"
tar -xzf /tmp/wstunnel.tar.gz -C /tmp/
chmod +x /tmp/wstunnel
sudo mv /tmp/wstunnel /usr/local/bin/wstunnel
```

**Systemd сервис** `/etc/systemd/system/wstunnel.service`:
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

> НЕ использовать `--restrict-http-upgrade-path-prefix` совместно с nginx trailing slash proxy_pass — nginx стрипает путь, wstunnel получает `/`, restriction не совпадает → 404.

### 5.4 Nginx — WebSocket proxy

Добавить **перед** первым `location /` в server block:

```nginx
location /SECRET_PATH/ {
    proxy_pass http://127.0.0.1:7777/;   # 7777 для Chisel, 8888 для wstunnel
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

**Критично:**
- `proxy_pass http://127.0.0.1:7777/;` — trailing slash **ОБЯЗАТЕЛЕН**. Без него WebSocket upgrade ломается
- `proxy_buffering off` — **ОБЯЗАТЕЛЕН**. Без него данные буферируются и не текут
- `SECRET_PATH` — сгенерировать: `openssl rand -hex 16`

```bash
sudo nginx -t && sudo systemctl reload nginx
```

### 5.5 Cloudflare (если используется)

1. **Network** → WebSockets: **On**
2. **SSL/TLS** → режим **Full (Strict)**
3. DNS запись → IP сервера, облако по необходимости

### 5.6 Firewall

Порт Chisel/wstunnel (7777/8888) **НЕ должен быть** доступен снаружи:
```bash
sudo ufw status               # порт НЕ в списке разрешённых
ss -tlnp | grep 7777          # должен быть 127.0.0.1:7777, НЕ 0.0.0.0
```

---

## 6. Клиентская часть — ТЗ

### 6.1 Chisel client

```bash
chisel client \
  --auth "LOGIN:PASSWORD" \
  --keepalive 25s \
  https://yourdomain.com:PORT/SECRET_PATH/ \
  socks
```

→ SOCKS5 на `127.0.0.1:1080`

**Критично:**
- `socks` (НЕ `R:socks`!) — `socks` = выход через сервер, `R:socks` = выход через клиента
- Trailing slash в URL — **ОБЯЗАТЕЛЬНА**
- Если порт 443 занят — указать явно: `:2087`
- `--keepalive 25s` — против таймаутов Cloudflare

### 6.2 wstunnel client (альтернатива)

```bash
wstunnel client \
  -L socks5://127.0.0.1:1082 \
  wss://yourdomain.com:PORT/SECRET_PATH/
```

→ SOCKS5 на `127.0.0.1:1082`

### 6.3 Throne (sing-box GUI) — рекомендуемый клиент

**Что:** Throne (бывший Nekoray) — кроссплатформенный GUI на базе sing-box.
**Скачать:** [github.com/throneproj/Throne/releases](https://github.com/throneproj/Throne/releases)

**Настройка профиля:**
1. Server → New profile → Type: SOCKS
2. Address: `127.0.0.1`, Port: `1080`
3. Username/Password: пусто (auth на уровне Chisel)

**Режимы работы:**

| Режим | Охват | Когда использовать |
|-------|-------|--------------------|
| System Proxy | HTTP/HTTPS приложения | Браузер, curl — да. Telegram, Discord — могут игнорировать |
| **TUN Mode** | **ВЕСЬ трафик** (TCP+UDP) | Полноценная замена VPN. Все приложения без исключений |

> TUN = виртуальный сетевой интерфейс. Перехватывает ВСЁ. Эквивалент VPN.

**TUN + Chisel — защита от петли:**

При включённом TUN он перехватывает трафик самого Chisel → бесконечный reconnect. Обязательные правила routing в Throne:

| Тип | Значение | Outbound |
|-----|----------|----------|
| processName | `chisel` | direct |
| ip | `127.0.0.1` | direct |
| domain_suffix | `yourdomain.com` | direct |

### 6.4 Раздельная маршрутизация (для РФ)

```
Default outbound: proxy  (всё через туннель)

Исключения (direct):
  - domain_suffix: .ru
  - domain_suffix: .рф
  - geoip: ru
  - geosite: category-gov-ru
  - domain_suffix: yandex.net
  - domain_suffix: vk.com
  - domain_suffix: mail.ru
```

**Зачем:** российские сайты напрямую = быстрее + не создаёт паттерн «трафик из РФ → VPS → обратно в РФ».

### 6.5 DNS leak prevention

По умолчанию SOCKS5 может не проксировать DNS-запросы. Провайдер увидит какие домены ты резолвишь.

**Решения:**
- **Firefox:** `about:config` → `network.proxy.socks_remote_dns` = `true`
- **TUN mode в Throne:** DNS автоматически проксируется
- **Системно (Linux):**
  ```ini
  # /etc/systemd/resolved.conf
  [Resolve]
  DNS=1.1.1.1#cloudflare-dns.com
  DNSOverTLS=yes
  ```

### 6.6 Автозапуск клиента (Linux)

```bash
mkdir -p ~/.config/systemd/user/

cat > ~/.config/systemd/user/chisel-client.service << 'EOF'
[Unit]
Description=Chisel Client
After=network-online.target

[Service]
ExecStart=/usr/local/bin/chisel client \
  --auth "LOGIN:PASSWORD" \
  --keepalive 25s \
  https://yourdomain.com:PORT/SECRET_PATH/ \
  socks
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now chisel-client
```

---

## 7. Критичные детали (грабли)

Собранные по опыту эксплуатации — каждый пункт стоил времени на дебаг.

| Проблема | Причина | Решение |
|----------|---------|---------|
| WebSocket handshake 404 | Нет trailing slash в URL | `/SECRET_PATH/` — слеш обязателен |
| Chisel `Connected` но curl зависает | Нет `proxy_buffering off` в nginx | Добавить директиву |
| Chisel не стартует, status=1 | `-p 127.0.0.1:7777` одним аргументом | Разделить: `--host 127.0.0.1 -p 7777` |
| Порт 7777 виден снаружи | Chisel на 0.0.0.0 | Добавить `--host 127.0.0.1` |
| `x509: certificate valid for...` | Порт 443 занят другим сервисом (Xray) | Использовать порт 2087 или 8443 |
| Обрывы каждые ~100 сек | CF WebSocket timeout (Free план) | `--keepalive 25s` или серое облако |
| DNS утекает | SOCKS5 не проксирует DNS | `socks_remote_dns=true` или TUN mode |
| TUN: бесконечный reconnect | TUN ловит трафик самого Chisel | processName `chisel` → direct |
| `R:socks` вместо `socks` | Трафик идёт через клиента, не сервер | Использовать `socks` без `R:` |
| wstunnel 404 с `--restrict-path` | nginx стрипает путь → wstunnel получает `/` | Не использовать `--restrict-path` с nginx |
| wstunnel `No such file` в Docker | Бинарник переименован в v10 | Использовать `wstunnel-cli` |

---

## 8. Модель угроз

### Что защищает эта схема

| Угроза | Защита | Уровень |
|--------|--------|---------|
| DPI / ТСПУ видит прокси-протокол | WebSocket внутри TLS = обычный HTTPS | Высокий |
| Active probing секретного пути | Без WS upgrade возвращает 404 | Высокий |
| Active probing корня сайта | Отдаёт реальный сайт-прикрытие | Высокий |
| Определение IP сервера | Cloudflare CDN (оранжевое облако) | Средний |
| Анализ SNI | SNI = легитимный домен за Cloudflare | Высокий |
| DNS leak | TUN mode или remote DNS | Высокий (при настройке) |

### Чего НЕ защищает

| Угроза | Почему | Митигация |
|--------|--------|-----------|
| IP сервера засвечен | Заблокируют по IP, CF не поможет | Новый VPS, никогда не светить IP |
| Cloudflare видит трафик | TLS терминируется на CF | Для обычного использования ОК |
| Паттерн длинного WS-соединения | Нетипично для обычного сайта | Пока не анализируют, но теоретически могут |
| Объём трафика выделяется | Много данных к одному домену | Использовать для целевых задач, не для всего |
| Компрометация VPS | Полный доступ к трафику | Шифрование E2E где возможно (HTTPS сайтов) |

### OPSEC правила

1. **Никогда** не запускать VPN/SS/VLESS напрямую на сервере — только через WebSocket+nginx
2. **Никогда** не открывать порты Chisel/wstunnel наружу — только 127.0.0.1
3. Российские сайты — только напрямую, не через туннель
4. Не раздавать SECRET_PATH — каждому пользователю свой path
5. Регулярно обновлять Chisel/wstunnel
6. Минимизировать или отключить логи на сервере

---

## 9. Чек-листы

### Сервер — после установки

- [ ] `chisel --version` или `wstunnel --version` работает
- [ ] `systemctl status chisel` → active (running)
- [ ] `ss -tlnp | grep 7777` → `127.0.0.1:7777` (НЕ `0.0.0.0`)
- [ ] `nginx -t` → syntax ok
- [ ] Сертификат Let's Encrypt (не CF Origin)
- [ ] `curl https://yourdomain.com` → показывает сайт-прикрытие
- [ ] `curl https://yourdomain.com/SECRET_PATH/` → 404 (это нормально, Chisel отвечает только на WS upgrade)
- [ ] Порт 7777/8888 НЕ доступен снаружи
- [ ] DNS: облако настроено правильно (серое или оранжевое)

### Клиент — после подключения

- [ ] Chisel client подключается без ошибок
- [ ] `curl --socks5-hostname 127.0.0.1:1080 https://2ip.ru` → IP сервера
- [ ] В Throne TUN mode — весь трафик через туннель
- [ ] DNS не утекает (проверить на `dnsleaktest.com` через прокси)
- [ ] Российские сайты работают напрямую (если настроен split routing)

### Частая проверка работоспособности

```bash
# Быстрая проверка IP
curl --socks5-hostname 127.0.0.1:1080 https://2ip.ru

# Проверка что сайт-прикрытие живой
curl -o /dev/null -w "%{http_code}" https://yourdomain.com/
# → 200

# Проверка WebSocket (должен быть 404 без upgrade)
curl -o /dev/null -w "%{http_code}" https://yourdomain.com:PORT/SECRET_PATH/
# → 404
```

---

## 10. Альтернативные инструменты

### Транспорт (замена Chisel/wstunnel)

| Инструмент | Принцип | Плюсы | Минусы |
|------------|---------|-------|--------|
| **Chisel** | SSH over WebSocket | Auth, надёжный, проверенный | Чуть тяжелее из-за SSH-слоя |
| **wstunnel** | TCP/UDP в WebSocket напрямую | Легче, быстрее | Нет встроенной auth |
| **Xray VLESS+WS** | VLESS протокол через WebSocket | Популярен, много клиентов | Сложнее настройка, больше зависимостей |
| **cloudflared** | Cloudflare Tunnel | Нет проблем с WS таймаутами | Зависимость от CF, закрытый код |

### Клиенты (замена Throne)

| Клиент | Платформы | Особенности |
|--------|-----------|-------------|
| **Throne** (Nekoray) | Linux, Windows, macOS | GUI, TUN, routing per app |
| **sing-box** (CLI) | Все | Максимальная гибкость, нужен JSON конфиг |
| **Hiddify** | Android, iOS, Windows | Удобный мобильный клиент |
| **v2rayN** | Windows | Популярный, много протоколов |

### Полные решения (если Chisel не подходит)

| Решение | Когда использовать |
|---------|-------------------|
| **Xray + REALITY** | Максимальная маскировка, имитирует TLS чужого сайта |
| **Cloudflare WARP** | Простой обход, без своего сервера |
| **Tor + obfs4** | Максимальная анонимность, медленно |
| **SSH SOCKS** | Уже есть SSH доступ к серверу, минимум настройки |

---

## Итого: минимально жизнеспособная конфигурация

Для запуска нужно:

1. **VPS** с Debian/Ubuntu за пределами РФ (~$5/мес)
2. **Домен** (любой дешёвый, можно .xyz за $1/год)
3. **Let's Encrypt** сертификат (бесплатно, certbot)
4. **nginx** с сайтом-прикрытием + WebSocket location
5. **Chisel server** как systemd сервис на 127.0.0.1
6. **Chisel client** + **Throne** на локальной машине

Время развёртывания с нуля: ~30 минут.
Время обслуживания: ~0 (systemd перезапускает всё автоматически).
Стоимость: $5-7/мес за VPS + $1/год за домен.
