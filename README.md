<div align="center">

# proxyebator

**Один скрипт. Один домен. Замаскированный SOCKS5-туннель через WebSocket.**

nginx + Chisel/wstunnel + TLS = трафик выглядит как обычный HTTPS

[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/erebe/wstunnel)
[![Shell](https://img.shields.io/badge/shell-bash-89e051)](https://github.com/jpillora/chisel)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Chisel](https://img.shields.io/badge/backend-chisel-orange)](https://github.com/jpillora/chisel)
[![wstunnel](https://img.shields.io/badge/backend-wstunnel-blueviolet)](https://github.com/erebe/wstunnel)

</div>

---

## Что это такое

proxyebator — это bash-скрипт, который за несколько минут разворачивает на VPS замаскированный SOCKS5-прокси. Туннель упакован в WebSocket-соединение, которое снаружи неотличимо от обычного HTTPS-трафика.

Поддерживаются два бэкенда: **Chisel** (SOCKS5 на стороне сервера, авторизация через authfile) и **wstunnel** (SOCKS5 на стороне клиента, авторизация через секретный путь nginx). Оба варианта работают за одним nginx с TLS-сертификатом Let's Encrypt.

После установки достаточно запустить клиентскую часть скрипта на своём компьютере и направить трафик приложений на `127.0.0.1:1080` (SOCKS5).

---

## Что нужно перед установкой

1. **VPS-сервер** — любой Linux VPS (Debian, Ubuntu, CentOS и др.) с root-доступом и открытыми портами 80 и 443
2. **Домен** — купить можно на [Namecheap](https://www.namecheap.com/), [Porkbun](https://porkbun.com/), [reg.ru](https://www.reg.ru/) или любом другом регистраторе. Подойдёт самый дешёвый домен — цена от $1-2/год
3. **DNS A-запись** — в панели управления доменом создать A-запись, указывающую на IP-адрес сервера. Если домен за Cloudflare — **обязательно серое облако** (DNS only), не оранжевое

> **Домен обязателен.** Без него certbot не выдаст TLS-сертификат, а без TLS маскировка трафика не работает — DPI увидит голый WebSocket.

---

## Как это работает

1. nginx слушает порт 443 и отдаёт подставной сайт на HTTPS — для внешнего наблюдателя это обычный веб-сервер.
2. Секретный путь (например `/abc123ef/`) проксируется через WebSocket к Chisel или wstunnel на loopback-интерфейсе сервера.
3. Клиент подключается к серверу, поднимает локальный SOCKS5 на порту 1080, и весь трафик уходит с IP-адреса сервера.

Сервисный процесс запускается от пользователя `nobody` через systemd. Бэкенд привязан к `127.0.0.1` и недоступен напрямую снаружи.

---

## Установка через AI-ассистента

### Этап 1: Сервер — отправь AI-ассистенту

> Скопируй блок ниже и отправь Claude, ChatGPT или другому AI-ассистенту с SSH-доступом к твоему VPS.
> Все команды выполняются **на сервере** — скрипт ставит nginx, TLS, туннель и файрвол прямо на VPS.

```
Задача: развернуть proxyebator — маскирующий WebSocket-прокси — на моём Linux VPS.

Все команды выполняются НА СЕРВЕРЕ через SSH.

Шаги:
1. Подключись к серверу по SSH как root (или через sudo)
2. Скачай скрипт:
   curl -fLO https://raw.githubusercontent.com/howdeploy/Proxyebator/main/proxyebator.sh
   chmod +x proxyebator.sh
3. Запусти установку:
   sudo ./proxyebator.sh server --domain МОЙДОМЕН.COM --tunnel chisel
4. Дождись строки "=== ALL CHECKS PASSED ===" — это значит всё работает
5. Скопируй команду для клиента из вывода скрипта и передай её мне (пользователю)

Требования к серверу:
- Debian 12+, Ubuntu 22.04+, CentOS 8+, AlmaLinux 8+, Rocky Linux 8+, Fedora 38+, или Arch Linux
- Открытые порты: 80/tcp (для certbot) и 443/tcp (для туннеля)
- Домен с A-записью, указывающей на IP сервера (серое облако Cloudflare, не оранжевое!)
- Root-доступ

Что НЕ делать:
- Не включать оранжевое облако Cloudflare — WebSocket будет рваться каждые ~100 секунд
- Не запускать без домена — TLS-сертификат нужен для маскировки
- Не менять порт туннеля вручную — скрипт назначает порты автоматически
```

### Этап 2: Клиент — запусти на своём компьютере

После того как AI-ассистент развернул сервер, он выдаст команду для подключения. Запусти её на **своей локальной машине** (Linux, macOS, Windows через WSL):

```bash
# Скачай скрипт
curl -fLO https://raw.githubusercontent.com/howdeploy/Proxyebator/main/proxyebator.sh
chmod +x proxyebator.sh

# Вставь команду из вывода сервера, например:
./proxyebator.sh client wss://proxyebator:TOKEN@example.com:443/SECRET/

# Или запусти интерактивно — скрипт спросит хост, путь и пароль:
./proxyebator.sh client
```

Проверка что всё работает:

```bash
curl --socks5-hostname localhost:1080 https://ifconfig.me
# Должен вернуть IP сервера, а не твой домашний IP
```

---

## Поддерживаемые операционные системы

| ОС | Версия | Пакетный менеджер |
|----|--------|-------------------|
| Debian | 11+ | apt |
| Ubuntu | 20.04+ | apt |
| CentOS | 8+ | dnf |
| AlmaLinux | 8+ | dnf |
| Rocky Linux | 8+ | dnf |
| Fedora | 38+ | dnf |
| Arch Linux | Rolling | pacman |

Архитектуры: **amd64** (x86\_64) и **arm64** (aarch64).

---

## Флаги командной строки

| Флаг | Режим | Описание | По умолчанию |
|------|-------|----------|--------------|
| `--domain DOMAIN` | server | Доменное имя сервера | интерактивный запрос |
| `--tunnel TYPE` | server / client | Бэкенд туннеля: `chisel` или `wstunnel` | `chisel` |
| `--port PORT` | server / client | Порт сервера (server: слушать, client: подключиться) | `443` |
| `--masquerade MODE` | server | Режим подставного сайта: `stub`, `proxy`, `static` | `stub` |
| `--host HOST` | client | Хост сервера | интерактивный запрос |
| `--path PATH` | client | Секретный путь туннеля (с ведущим и завершающим `/`) | интерактивный запрос |
| `--pass PASSWORD` | client | Пароль / токен авторизации (только chisel) | интерактивный запрос |
| `--socks-port PORT` | client | Локальный порт SOCKS5 | `1080` |
| `--yes` | uninstall | Пропустить запрос подтверждения | интерактивный запрос |

---

## Переменные конфигурации (server.conf)

После установки настройки сохраняются в `/etc/proxyebator/server.conf`. Эти переменные используются командами `verify`, `uninstall` и повторным запуском `server`.

| Переменная | Описание |
|-----------|----------|
| `DOMAIN` | Доменное имя |
| `LISTEN_PORT` | Порт nginx (обычно 443) |
| `SECRET_PATH` | Секретный путь WebSocket (без слэшей) |
| `TUNNEL_TYPE` | `chisel` или `wstunnel` |
| `TUNNEL_PORT` | Внутренний порт бэкенда (7777 для chisel, 7778 для wstunnel) |
| `MASQUERADE_MODE` | Режим подставного сайта (`stub`, `proxy`, `static`) |
| `AUTH_USER` | Имя пользователя (только chisel; всегда `proxyebator`) |
| `AUTH_TOKEN` | Токен авторизации (только chisel) |
| `NGINX_CONF` | Путь к конфигурационному файлу nginx |
| `NGINX_INJECTED` | `true`, если блок встроен в существующий конфиг nginx |

---

<details>
<summary><b>Установка сервера — подробно</b></summary>

### Требования к серверу

- Linux VPS (см. таблицу поддерживаемых ОС выше)
- Root-доступ или sudo
- Открытые порты: `80/tcp` (для certbot) и `443/tcp` (для туннеля)
- Домен с A-записью, указывающей на IP сервера (**серое облако Cloudflare — не оранжевое!**)

### Режим 1: Интерактивная установка

```bash
sudo ./proxyebator.sh server
```

Скрипт спросит: домен, тип туннеля, режим маскировки, порт. Подходит для первого знакомства.

### Режим 2: Без вопросов (для AI-агентов и скриптов)

```bash
# Chisel backend
sudo ./proxyebator.sh server --domain example.com --tunnel chisel

# wstunnel backend
sudo ./proxyebator.sh server --domain example.com --tunnel wstunnel

# Другой порт
sudo ./proxyebator.sh server --domain example.com --port 8443
```

Когда все параметры переданы через флаги, скрипт не задаёт вопросов — удобно для автоматизации.

### Режим 3: Повторный запуск (re-run / idempotency)

Если `server.conf` уже существует, скрипт читает из него сохранённые значения (в том числе `AUTH_TOKEN` и `SECRET_PATH`) и пропускает шаги, которые уже выполнены: не перезаписывает systemd-юнит если сервис уже запущен, не перезапрашивает сертификат если он есть.

### Что делает установка

1. Определяет ОС и архитектуру
2. Устанавливает зависимости: nginx, certbot, curl
3. Скачивает бинарник туннеля (Chisel или wstunnel) с GitHub Releases
4. Настраивает systemd-сервис (`proxyebator.service`)
5. Создаёт конфиг nginx: сначала HTTP-only для ACME, затем полный SSL
6. Получает TLS-сертификат Let's Encrypt
7. Настраивает правила файрвола (ufw или iptables — блокирует прямой доступ к порту туннеля)
8. Запускает проверку из 7 шагов (`verify`)
9. Выводит готовую команду для клиента

</details>

---

<details>
<summary><b>Подключение клиента</b></summary>

Клиентская часть не требует root. Клиент скачивает нужный бинарник в `~/.local/bin` и запускает его.

### Режим 1: URL (скопировать из вывода сервера)

```bash
./proxyebator.sh client wss://proxyebator:TOKEN@example.com:443/SECRET/
```

### Режим 2: Флаги

```bash
# Chisel client
./proxyebator.sh client \
    --host example.com \
    --port 443 \
    --path /SECRET/ \
    --pass TOKEN \
    --socks-port 1080

# wstunnel client
./proxyebator.sh client \
    --host example.com \
    --port 443 \
    --path /SECRET/ \
    --tunnel wstunnel \
    --socks-port 1080
```

### Режим 3: Интерактивный

```bash
./proxyebator.sh client
```

Скрипт запросит хост, порт, путь и пароль.

### Проверка подключения

```bash
curl --socks5-hostname localhost:1080 https://ifconfig.me
```

Команда должна вернуть IP-адрес сервера, а не ваш домашний IP.

### Остановка клиента

Ctrl+C — клиент запущен на переднем плане и завершается сигналом SIGINT.

</details>

---

## Настройка SOCKS5 в GUI-клиентах

Все клиенты используют одни параметры SOCKS5:

- **Протокол:** SOCKS5
- **Хост:** `127.0.0.1`
- **Порт:** `1080` (или другой, если задан `--socks-port`)
- **Авторизация:** нет

---

### Throne (Linux, Windows, macOS) — рекомендуется

Throne — активно разрабатываемый прокси-клиент на базе sing-box (v1.0.13, декабрь 2025). Поддерживает TUN-режим для маршрутизации всего трафика.

Репозиторий: [github.com/throneproj/Throne](https://github.com/throneproj/Throne)

**Настройка SOCKS5:**

1. Запустить Throne
2. Добавить сервер: Servers → Add → Type: SOCKS5 → Host: `127.0.0.1` → Port: `1080` → без авторизации
3. Подключиться
4. Выбрать режим: System Proxy (для браузеров) или TUN (весь трафик)

**Режим TUN — правила против петли маршрутизации (обязательно):**

В TUN-режиме Throne перехватывает весь трафик, включая трафик самого туннельного клиента — это приводит к бесконечному циклу переподключений. До включения TUN добавить правила прямого выхода:

```
processName = chisel      → outbound: direct
processName = wstunnel    → outbound: direct
domain_suffix = YOURDOMAIN.COM → outbound: direct
ip_cidr = 127.0.0.1/32   → outbound: direct
```

Без этих правил TUN перехватит соединение Chisel/wstunnel → клиент туннеля будет уходить через себя → бесконечный reconnect.

---

### nekoray / nekobox (Linux, Windows) — АРХИВИРОВАН

**Внимание:** репозиторий [MatsuriDayo/nekoray](https://github.com/MatsuriDayo/nekoray) заархивирован с начала 2025 года. Последний релиз: v4.0.1 (12 декабря 2024), исполняемый файл в 4.x переименован в `nekobox.exe`. Новых обновлений не будет. Рекомендуется использовать **Throne** как активную замену.

Если нужно использовать nekoray/nekobox:

1. Скачать последний релиз с GitHub (Linux AppImage, Windows zip или Debian .deb)
2. Запустить nekobox
3. Добавить сервер: Servers → Add → Type: SOCKS5 → Address: `127.0.0.1` → Port: `1080`
4. Выбрать сервер → Connect

---

### Proxifier (Windows, macOS) — коммерческий

[proxifier.com](https://www.proxifier.com) — платный инструмент для маршрутизации трафика отдельных приложений через прокси. Proxifier поддерживает SOCKS5 и позволяет гибко настраивать правила: весь трафик или только отдельные программы.

**Настройка Proxifier:**

1. Profile → Proxy Servers → Add
2. Address: `127.0.0.1` → Port: `1080` → Protocol: SOCKS Version 5 → без авторизации → OK
3. Profile → Proxification Rules → Add
4. Applications: Any → Target hosts: Any → Action: Proxy SOCKS5 `127.0.0.1` → OK

Для выборочной маршрутизации (только нужные приложения) создать отдельные правила с конкретными именами процессов.

---

### Surge (macOS, iOS) — коммерческий

[nssurge.com](https://nssurge.com) — платный прокси-клиент с гибкими правилами маршрутизации.

**Настройка SOCKS5-политики:**

```ini
[Proxy]
proxyebator = socks5, 127.0.0.1, 1080

[Proxy Group]
Proxy = select, proxyebator, DIRECT

[Rule]
FINAL, Proxy
```

Добавить политику `proxyebator` в нужную группу или назначить как финальное правило.

---

### Firefox (любая ОС)

1. Настройки → Основное → Настройки сети → Настроить
2. Ручная настройка прокси
3. SOCKS-узел: `127.0.0.1` → Порт: `1080` → SOCKS v5
4. **Обязательно** поставить галочку "Использовать DNS через SOCKS v5" — иначе DNS-запросы не будут проходить через туннель (утечка DNS)
5. OK

---

<details>
<summary><b>Удаление</b></summary>

```bash
# С подтверждением
sudo ./proxyebator.sh uninstall

# Без подтверждения (для скриптов)
sudo ./proxyebator.sh uninstall --yes
```

**Что удаляется:**

- Systemd-юнит `proxyebator.service`
- Бинарник туннеля (`/usr/local/bin/chisel` или `/usr/local/bin/wstunnel`)
- Конфиг nginx (`/etc/nginx/sites-available/proxyebator` или блок в существующем конфиге)
- Конфигурационный каталог `/etc/proxyebator/`
- Authfile `/etc/chisel/auth.json` (только chisel)

**Что НЕ удаляется:**

- TLS-сертификат Let's Encrypt (`/etc/letsencrypt/`) — из-за лимитов Let's Encrypt (5 сертификатов на домен в неделю) сертификат сохраняется. Для ручного удаления: `certbot delete --cert-name DOMAIN`
- Сам nginx (мог быть установлен до proxyebator)

</details>

---

## Chisel vs wstunnel

| | Chisel | wstunnel |
|---|--------|---------|
| SOCKS5 | Серверная сторона (`--socks5`) | Клиентская сторона (`-L socks5://`) |
| Авторизация | authfile (`user:pass` в JSON) | Секретный путь nginx (path = auth) |
| Внутренний порт | 7777 | 7778 |
| Архив | `.gz` (gunzip) | `.tar.gz` (tar xzf) |
| Версия | Последняя с GitHub API | v10+ (последняя с GitHub API) |
| Рекомендуется | Для большинства случаев | Если нужен другой подход к auth |

---

<details>
<summary><b>Решение проблем</b></summary>

| Проблема | Причина | Решение |
|----------|---------|---------|
| Cloudflare оранжевое облако — соединение рвётся каждые ~100 сек | Cloudflare CDN буферирует WebSocket и обрывает долгие соединения | Переключить A-запись домена на серое облако (DNS only) в CF Dashboard |
| DNS утечка — провайдер видит запрашиваемые домены | SOCKS5 резолвит DNS локально, а не через туннель | Firefox: `about:config` → `network.proxy.socks_remote_dns = true`; Throne: TUN-режим |
| TUN-режим: бесконечный reconnect — клиент не может подключиться | TUN перехватывает трафик самого клиента туннеля (Chisel/wstunnel), создавая петлю | Добавить правила прямого выхода: `processName chisel → direct`, `processName wstunnel → direct` |
| WebSocket 404 — curl возвращает 404 на секретный путь | Нет trailing slash в URL запроса | URL должен заканчиваться на `/SECRET/` (с закрывающим слэшем) |
| Туннель Connected, но curl зависает | nginx буферирует ответ вместо потоковой передачи | Убедиться что в nginx location block есть `proxy_buffering off`; переустановить скрипт |
| Порт 7777 или 7778 виден снаружи | Бэкенд слушает `0.0.0.0` вместо `127.0.0.1` | Переустановить скрипт — он привязывает бэкенд к `127.0.0.1` |
| verify: DNS resolves to Cloudflare IP | A-запись идёт через оранжевое облако CF | Переключить на серое облако в CF Dashboard, дождаться TTL |
| certbot: challenge failed | Порт 80 занят другим процессом, или DNS ещё не обновился | Проверить: `curl http://DOMAIN` с другой машины; освободить порт 80; подождать распространения DNS |
| Туннель работает, но некоторые сайты не открываются | SOCKS5 без remote DNS: браузер резолвит домены локально | Включить remote DNS (Firefox) или использовать TUN-режим (Throne) |

**Диагностические команды:**

```bash
# Проверить статус сервиса
systemctl status proxyebator

# Посмотреть логи сервиса
journalctl -u proxyebator -n 50

# Запустить полную проверку
sudo ./proxyebator.sh verify

# Проверить что бэкенд слушает только loopback
ss -tlnp | grep -E '7777|7778'

# Проверить nginx конфиг
nginx -t

# Проверить сертификат
openssl s_client -connect DOMAIN:443 -servername DOMAIN </dev/null 2>/dev/null | openssl x509 -noout -dates
```

</details>

---

## Лицензия

MIT — делай что хочешь, на свой риск.
