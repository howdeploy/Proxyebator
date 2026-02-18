# Phase 4: Client Mode - Context

**Gathered:** 2026-02-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Client mode: пользователь запускает `./proxyebator.sh client` на своей машине (Linux/macOS/WSL), скрипт скачивает бинарник Chisel, подключается к серверу и поднимает SOCKS5 на localhost. После подключения — выводит адрес прокси, curl-команду для проверки и компактные инструкции для GUI-клиентов.

</domain>

<decisions>
## Implementation Decisions

### Сбор параметров подключения
- Три способа ввода (приоритет): URL-строка, CLI-флаги, интерактивный промпт
- URL-режим: `./proxyebator.sh client wss://user:pass@host/path` — одной строкой, сервер печатает готовую команду после установки
- CLI-флаги: --host, --port, --path, --pass — каждый параметр отдельно
- Интерактив: если параметры не переданы ни через URL, ни через флаги — скрипт спрашивает по очереди
- --socks-port флаг: по умолчанию 1080, можно переопределить если порт занят

### Режим работы
- Foreground только: Chisel работает в терминале, Ctrl+C останавливает
- Никакого background-режима, PID-файлов, команды stop

### GUI-инструкции после подключения
- Расширенный набор клиентов: Throne (Linux), Proxifier (Win/Mac), nekoray (Linux/Win), Firefox/Chrome SOCKS5, Surge (macOS)
- Компактный формат: 1-2 строки на клиент (клиент: адрес, порт, протокол)
- Язык вывода: русский
- curl-команда для проверки: `curl --socks5-hostname localhost:PORT https://ifconfig.me`

### Claude's Discretion
- Порядок вопросов в интерактивном режиме
- Формат парсинга URL (regex vs встроенные средства bash)
- Обработка ошибок подключения (таймауты, неверный пароль, недоступный сервер)
- Проверка доступности порта 1080 перед запуском

</decisions>

<specifics>
## Specific Ideas

- Сервер уже печатает готовую команду `./proxyebator.sh client wss://...` после установки (через server_print_connection_info) — клиент должен принимать этот формат как есть
- SOCKS5 адрес всегда 127.0.0.1:PORT (не 0.0.0.0)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 04-client-mode*
*Context gathered: 2026-02-18*
