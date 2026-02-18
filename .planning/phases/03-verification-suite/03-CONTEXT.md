# Phase 3: Verification Suite - Context

**Gathered:** 2026-02-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Отдельная команда `./proxyebator.sh verify` — расширенная верификация после установки. Читает параметры из `/etc/proxyebator/server.conf`. Запускается автоматически из server_main (вместо текущей server_verify), а также вручную в любое время. Ловит все «тихие» сбои до того, как пользователю скажут «всё работает».

</domain>

<decisions>
## Implementation Decisions

### Структура команды
- Новый режим `verify` в CLI dispatcher (`./proxyebator.sh verify`)
- Функция `verify_main()` заменяет текущую `server_verify()` — единая логика для post-install и ручного запуска
- Параметры читаются из `/etc/proxyebator/server.conf` (не из CLI-флагов)
- `server_main()` в конце вызывает `verify_main()` вместо `server_verify()`

### Набор проверок (7 штук)
- **Базовые 4** (уже есть в Phase 2, перенести в verify_main):
  1. systemd service active
  2. Tunnel port bound to 127.0.0.1
  3. Decoy site returns HTTP 200
  4. WebSocket path reachable
- **Новые 3:**
  5. TLS сертификат: срок действия, цепочка доверия, наличие certbot renewal timer
  6. DNS резолвинг: домен резолвится в IP сервера, проверка на Cloudflare orange cloud
  7. Firewall правила: проверить что правило блокировки 7777 существует (ufw status / iptables -L)

### Формат вывода
- Построчно: каждая проверка на отдельной строке — `[PASS]` или `[FAIL]` + описание
- При FAIL показывать диагностический вывод (ss -tlnp, curl response, ufw status и т.п.)
- Итоговый баннер: зелёный `=== ALL CHECKS PASSED (7/7) ===` или красный `=== X CHECKS FAILED ===`
- Connection block (клиентская команда + SOCKS5 адрес) показывать ТОЛЬКО при ALL PASS

### Поведение при ошибках
- Продолжать все проверки даже если одна не прошла — показать полную картину
- При FAIL показать подсказку по исправлению (например: `Try: systemctl restart proxyebator`, `Try: certbot renew`)
- `exit 1` при любом FAIL — удобно для автоматизации (AI-agent может проверить exit code)
- `exit 0` только при ALL PASS

### Claude's Discretion
- Точный текст подсказок по исправлению
- Порядок проверок (оптимальный для диагностики)
- Как именно проверять TLS cert validity (openssl s_client или файловая проверка)
- Формат диагностического вывода при FAIL

</decisions>

<specifics>
## Specific Ideas

- Текущая `server_verify()` в Phase 2 (4 проверки + server_print_connection_info) должна быть заменена на вызов `verify_main()` — не дублировать логику
- server_print_connection_info() остаётся, но вызывается только из verify_main при ALL PASS
- Проверка firewall через правила (ufw status / iptables -L), не через активную попытку подключения

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 03-verification-suite*
*Context gathered: 2026-02-18*
