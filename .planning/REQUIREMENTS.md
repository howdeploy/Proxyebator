# Requirements: Proxyebator

**Defined:** 2026-02-18
**Core Value:** Человек или AI-агент запускает один скрипт, отвечает на вопросы — и получает работающий замаскированный туннель с SOCKS5 на localhost

## v1 Requirements

### Скрипт и структура

- [ ] **SCRIPT-01**: Единый bash-скрипт `proxyebator.sh` с режимами `server`, `client`, `uninstall`
- [ ] **SCRIPT-02**: Автоматическая детекция ОС и пакетного менеджера (Debian/Ubuntu/CentOS/Fedora/Arch)
- [ ] **SCRIPT-03**: Детекция архитектуры процессора (amd64/arm64) для скачивания правильного бинарника
- [ ] **SCRIPT-04**: Идемпотентность — повторный запуск не ломает существующую установку
- [ ] **SCRIPT-05**: Информативные сообщения о каждом шаге установки с цветным выводом
- [ ] **SCRIPT-06**: Проверка зависимостей и автоустановка недостающих (curl, jq, openssl, nginx, certbot)

### Туннели

- [ ] **TUNNEL-01**: Выбор бэкенда при установке: Chisel или wstunnel
- [ ] **TUNNEL-02**: Скачивание бинарника из GitHub releases (latest) с автодетекцией ОС/архитектуры
- [ ] **TUNNEL-03**: Chisel: запуск сервера с раздельными `--host 127.0.0.1` и `-p PORT`, SOCKS5 через `--socks5`
- [ ] **TUNNEL-04**: wstunnel: запуск сервера с корректными v10+ флагами, определение имени бинарника (wstunnel/wstunnel-cli)
- [ ] **TUNNEL-05**: Генерация рандомного секретного WS-пути (16+ символов) при установке
- [ ] **TUNNEL-06**: Генерация рандомного пароля/токена для аутентификации
- [ ] **TUNNEL-07**: Хранение креденшлов в файле (chmod 600), а не в аргументах командной строки

### Маскировка и TLS

- [ ] **MASK-01**: Два режима маскировки на выбор: реверс-прокси с сайтом-обманкой или только HTTPS
- [ ] **MASK-02**: nginx реверс-прокси: реальный контент на `/`, WebSocket-проксирование на секретном пути
- [ ] **MASK-03**: Обязательный `proxy_buffering off` и trailing slash в `proxy_pass` для корректной работы WebSocket
- [ ] **MASK-04**: Сайт-обманка на выбор: встроенная заглушка, проксирование внешнего URL, или свой путь к статике
- [ ] **MASK-05**: Автоматическое получение TLS-сертификата через certbot при наличии домена
- [ ] **MASK-06**: Режим «только HTTPS» без nginx для случаев, когда сайт-обманка не нужна

### Серверная инфраструктура

- [ ] **SRV-01**: Создание systemd unit-файла для туннеля с автозапуском и рестартом при падении
- [ ] **SRV-02**: Автоматическая настройка firewall (ufw если установлен, иначе iptables): открыть 80/443, закрыть порт туннеля извне
- [ ] **SRV-03**: Сохранение конфигурации в `/etc/proxyebator/server.conf` для uninstall и status
- [ ] **SRV-04**: Проверка что порт туннеля слушает на 127.0.0.1, а не на 0.0.0.0

### Клиентский режим

- [ ] **CLI-01**: `./proxyebator.sh client` — скачивает бинарник, подключается к серверу, поднимает SOCKS5 на localhost:1080
- [ ] **CLI-02**: Запрос параметров подключения: хост, порт, секретный путь, пароль
- [ ] **CLI-03**: Поддержка клиента на Linux, macOS, Windows (WSL)
- [ ] **CLI-04**: Вывод параметров подключения для GUI-клиентов после успешного подключения

### Верификация

- [ ] **VER-01**: Post-install проверка: `ss -tlnp` что порт на 127.0.0.1, systemd-сервис active
- [ ] **VER-02**: Проверка WebSocket upgrade через curl к секретному пути
- [ ] **VER-03**: Вывод полных параметров подключения и готовой клиентской команды после установки

### Деинсталляция

- [ ] **DEL-01**: `./proxyebator.sh uninstall` — полное удаление: бинарник, systemd unit, nginx конфиг, firewall правила
- [ ] **DEL-02**: Чтение `/etc/proxyebator/server.conf` для корректного удаления без вопросов

### README и документация

- [ ] **DOC-01**: README на русском языке с центрированным заголовком и shields.io бейджами
- [ ] **DOC-02**: Таблицы с параметрами, переменными, поддерживаемыми ОС
- [ ] **DOC-03**: Разворачиваемые `<details>` блоки для разделов
- [ ] **DOC-04**: Инструкции для GUI-клиентов: Throne (Linux), nekoray/nekobox (Linux/Windows), Proxifier (Windows/macOS), Surge (macOS) — какие настройки, какие галочки
- [ ] **DOC-05**: Блок «Скопируй это и отправь AI-ассистенту» с пошаговой инструкцией для развёртывания
- [ ] **DOC-06**: Раздел troubleshooting с типичными проблемами и решениями

## v2 Requirements

### Расширение функционала

- **MULTI-01**: Поддержка нескольких пользователей с разными креденшлами
- **UPD-01**: Команда `proxyebator.sh update` — обновление бинарника без переустановки
- **CDN-01**: Маршрутизация через Cloudflare CDN (domain fronting)
- **CONF-01**: Хранение клиентского конфига в `~/.config/proxyebator/` для короткой команды подключения
- **SPLIT-01**: Примеры split-tunneling конфигов для Proxifier и Surge
- **STATUS-01**: Команда `proxyebator.sh status` — проверка здоровья туннеля и вывод внешнего IP

## Out of Scope

| Feature | Reason |
|---------|--------|
| Web UI / дашборд | Добавляет attack surface; CLI достаточно для целевой аудитории |
| VPN-режим (полное перенаправление трафика) | Требует TUN/TAP, root, OS-специфичная логика — пусть GUI-клиенты решают |
| Docker-контейнеры | Прямая установка на хост проще; Docker — лишняя зависимость на дешёвых VPS |
| Мобильные клиенты (Android/iOS) | Слишком разнообразная экосистема; v1 — только десктоп |
| Кастомный протокол | Chisel/wstunnel проверены временем; писать свой — месяцы работы и риск |
| Автоматическая покупка домена/DNS | Сложная API-интеграция; юзер должен иметь домен заранее |
| HTTP CONNECT прокси | SOCKS5 поддерживается всеми GUI-клиентами — лишняя сложность |
| Скриншоты в README | Только текст и markdown-разметка |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| SCRIPT-01 | Phase 1 | Pending |
| SCRIPT-02 | Phase 1 | Pending |
| SCRIPT-03 | Phase 1 | Pending |
| SCRIPT-04 | Phase 5 | Pending |
| SCRIPT-05 | Phase 1 | Pending |
| SCRIPT-06 | Phase 2 | Pending |
| TUNNEL-01 | Phase 2 | Pending |
| TUNNEL-02 | Phase 2 | Pending |
| TUNNEL-03 | Phase 2 | Pending |
| TUNNEL-04 | Phase 6 | Pending |
| TUNNEL-05 | Phase 2 | Pending |
| TUNNEL-06 | Phase 2 | Pending |
| TUNNEL-07 | Phase 5 | Pending |
| MASK-01 | Phase 2 | Pending |
| MASK-02 | Phase 2 | Pending |
| MASK-03 | Phase 2 | Pending |
| MASK-04 | Phase 2 | Pending |
| MASK-05 | Phase 2 | Pending |
| MASK-06 | Phase 2 | Pending |
| SRV-01 | Phase 2 | Pending |
| SRV-02 | Phase 2 | Pending |
| SRV-03 | Phase 2 | Pending |
| SRV-04 | Phase 2 | Pending |
| CLI-01 | Phase 4 | Pending |
| CLI-02 | Phase 4 | Pending |
| CLI-03 | Phase 4 | Pending |
| CLI-04 | Phase 4 | Pending |
| VER-01 | Phase 3 | Pending |
| VER-02 | Phase 3 | Pending |
| VER-03 | Phase 3 | Pending |
| DEL-01 | Phase 5 | Pending |
| DEL-02 | Phase 5 | Pending |
| DOC-01 | Phase 6 | Pending |
| DOC-02 | Phase 6 | Pending |
| DOC-03 | Phase 6 | Pending |
| DOC-04 | Phase 6 | Pending |
| DOC-05 | Phase 6 | Pending |
| DOC-06 | Phase 6 | Pending |

**Coverage:**
- v1 requirements: 38 total
- Mapped to phases: 38
- Unmapped: 0

---
*Requirements defined: 2026-02-18*
*Last updated: 2026-02-18 after roadmap creation — all 38 requirements mapped*
