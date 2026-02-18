# Phase 3: Verification Suite - Research

**Researched:** 2026-02-18
**Domain:** Bash verification scripting — systemd, openssl, ss, curl, ufw/iptables, DNS-over-HTTPS
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Структура команды**
- Новый режим `verify` в CLI dispatcher (`./proxyebator.sh verify`)
- Функция `verify_main()` заменяет текущую `server_verify()` — единая логика для post-install и ручного запуска
- Параметры читаются из `/etc/proxyebator/server.conf` (не из CLI-флагов)
- `server_main()` в конце вызывает `verify_main()` вместо `server_verify()`

**Набор проверок (7 штук)**
- **Базовые 4** (уже есть в Phase 2, перенести в verify_main):
  1. systemd service active
  2. Tunnel port bound to 127.0.0.1
  3. Decoy site returns HTTP 200
  4. WebSocket path reachable
- **Новые 3:**
  5. TLS сертификат: срок действия, цепочка доверия, наличие certbot renewal timer
  6. DNS резолвинг: домен резолвится в IP сервера, проверка на Cloudflare orange cloud
  7. Firewall правила: проверить что правило блокировки 7777 существует (ufw status / iptables -L)

**Формат вывода**
- Построчно: каждая проверка на отдельной строке — `[PASS]` или `[FAIL]` + описание
- При FAIL показывать диагностический вывод (ss -tlnp, curl response, ufw status и т.п.)
- Итоговый баннер: зелёный `=== ALL CHECKS PASSED (7/7) ===` или красный `=== X CHECKS FAILED ===`
- Connection block (клиентская команда + SOCKS5 адрес) показывать ТОЛЬКО при ALL PASS

**Поведение при ошибках**
- Продолжать все проверки даже если одна не прошла — показать полную картину
- При FAIL показать подсказку по исправлению (например: `Try: systemctl restart proxyebator`, `Try: certbot renew`)
- `exit 1` при любом FAIL — удобно для автоматизации (AI-agent может проверить exit code)
- `exit 0` только при ALL PASS

### Claude's Discretion
- Точный текст подсказок по исправлению
- Порядок проверок (оптимальный для диагностики)
- Как именно проверять TLS cert validity (openssl s_client или файловая проверка)
- Формат диагностического вывода при FAIL

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| VER-01 | Post-install проверка: `ss -tlnp` что порт на 127.0.0.1, systemd-сервис active | Checks 1+2: `systemctl is-active --quiet` and `ss -tlnp` with grep pattern documented |
| VER-02 | Проверка WebSocket upgrade через curl к секретному пути | Check 4: curl with WS upgrade headers (`-H "Upgrade: websocket"`) — accept 101/200/400, fail on 404/000 |
| VER-03 | Вывод полных параметров подключения и готовой клиентской команды после установки | `server_print_connection_info()` called ONLY on ALL PASS — existing function reused |
</phase_requirements>

---

## Summary

Phase 3 refactors the existing `server_verify()` function (4 checks) into a standalone `verify_main()` function (7 checks) that is also exposed as `./proxyebator.sh verify`. The function reads all parameters from `/etc/proxyebator/server.conf` so it works identically for post-install verification and manual re-runs. Three new checks are added: TLS certificate validity (file-based, `openssl x509 -checkend`), DNS resolution matching server IP (reusing the DoH pattern from `validate_domain()`), and firewall rule existence (`ufw status` or `iptables -L`).

The core bash challenge is that the script uses `set -euo pipefail`, which means all commands in FAIL branches must use `if/else` or `|| true` — naked non-zero exits would kill the script. The verification pattern uses a `fail_count` integer counter (not an `all_ok` boolean) to support the exact `X/7` format in the summary banner. The `local` + assignment separation rule applies throughout.

The recommended check order — systemd, port binding, firewall, nginx cover site, WebSocket path, TLS cert, DNS — maximizes diagnostic value: infrastructure failures explain why subsequent network checks also fail.

**Primary recommendation:** Use `openssl x509 -noout -checkend 2592000 -in "$CERT_PATH"` for TLS cert check (file-based, no network dependency), a `fail_count` integer for the summary banner, and `if/else` throughout for `set -e` safety.

---

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| `openssl x509` | OpenSSL 3.x (on system) | TLS cert validity + expiry + chain of trust | Standard system tool, no deps, `-checkend` flag gives clean exit code |
| `systemctl is-active --quiet` | systemd (on system) | Service active check | Standard for systemd, `--quiet` suppresses output cleanly |
| `ss -tlnp` | iproute2 6.x (on system) | Port binding check | Already used in Phase 2, faster than `netstat` |
| `curl -sk` | curl (installed in Phase 2) | HTTP/WS endpoint check | Already installed, handles HTTPS, `-w "%{http_code}"` for parsed response |
| `ufw status` / `iptables -L INPUT -n` | ufw/iptables (on system) | Firewall rule presence | Same tools used in Phase 2 firewall setup |
| DNS-over-HTTPS via `dns.google` | curl to HTTPS API | Domain resolution without `dig` | Same pattern already in `validate_domain()` — no new dependency |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `openssl verify` | Chain of trust check against system CA bundle | Within TLS check (check 5), after cert file exists |
| `systemctl list-units --type=timer` | Check certbot renewal timer exists | Within TLS check (check 5) |
| `printf ... >&2` | Diagnostic output goes to stderr | All FAIL branch diagnostic output |

### No New Dependencies
This phase introduces zero new tools. Every command was already installed in Phase 1 or Phase 2:
- `openssl` — installed Phase 2 (dep install)
- `curl` — installed Phase 2 (dep install)
- `ss`, `systemctl`, `iptables`/`ufw` — standard system tools

---

## Architecture Patterns

### verify_main() Structure

```bash
verify_main() {
    # 1. Load server.conf (die if missing)
    [[ -f /etc/proxyebator/server.conf ]] \
        || die "server.conf not found — run: sudo ./proxyebator.sh server"
    # shellcheck disable=SC1091
    source /etc/proxyebator/server.conf

    local fail_count=0
    local total_checks=7

    printf "\n${BOLD}=== Verification Suite ===${NC}\n"

    # Checks 1-7 (see below)
    ...

    # Summary banner
    local pass_count=$(( total_checks - fail_count ))
    if [[ $fail_count -eq 0 ]]; then
        printf "\n${GREEN}${BOLD}=== ALL CHECKS PASSED (${pass_count}/${total_checks}) ===${NC}\n"
        server_print_connection_info
        return 0  # caller handles exit
    else
        printf "\n${RED}${BOLD}=== ${fail_count} CHECK(S) FAILED (${pass_count}/${total_checks} passed) ===${NC}\n" >&2
        return 1
    fi
}
```

### Recommended Check Order (Optimal for Diagnostics)

| # | Check | Rationale |
|---|-------|-----------|
| 1 | systemd service active | If dead, all port/WS checks will also fail — root cause first |
| 2 | Tunnel port 7777 bound to 127.0.0.1 | Confirms service actually listened; security invariant |
| 3 | Firewall blocks 7777 externally | Security check before app checks |
| 4 | Cover site returns HTTP 200 | nginx is up and serving |
| 5 | WebSocket path reachable | Depends on nginx (check 4); tests tunnel routing |
| 6 | TLS cert valid + renewal timer | File-based; catches slow-burn failures (cert expiry) |
| 7 | DNS resolves to server IP | Network-dependent; most likely to be user's CF issue |

### Pattern: check_pass / check_fail Helper Functions

```bash
# Source: pattern verified against set -euo pipefail behavior
check_pass() {
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

check_fail() {
    printf "${RED}[FAIL]${NC} %s\n" "$1" >&2
    fail_count=$(( fail_count + 1 ))
}
```

These are local to `verify_main` scope (either nested functions or inline logic). Using named functions makes each check read cleanly.

**Note:** `fail_count` must be declared as `local fail_count=0` BEFORE the nested functions use it, so they modify the enclosing scope variable. In bash, nested functions share the calling function's locals only if they are defined in the same scope. Alternative: declare `fail_count` at top of `verify_main`, use inline `fail_count=$(( fail_count + 1 ))` without nested functions.

### Pattern: set -euo pipefail Safety in FAIL Branches

The script has `set -euo pipefail`. Every command in a FAIL branch that might return non-zero MUST be guarded:

```bash
# Source: verified against bash set -e semantics
# SAFE: condition in `if` is exempt from set -e
if systemctl is-active --quiet proxyebator 2>/dev/null; then
    check_pass "proxyebator.service is active"
else
    check_fail "proxyebator.service is NOT active"
    # Diagnostic output: guard with || true so set -e doesn't kill us
    systemctl status proxyebator --no-pager --lines=5 >&2 2>/dev/null || true
    printf "  Try: systemctl restart proxyebator\n" >&2
fi
```

### Pattern: local Variable Assignment with set -e

```bash
# BAD — local always returns 0, hiding command failure:
local result=$(failing_command)

# GOOD — separate declaration and assignment:
local result
result=$(failing_command) || result="fallback_value"
```

This applies to ALL local variables assigned from command substitution in verify_main.

### Pattern: sourcing server.conf

```bash
# Source server.conf (root-owned chmod 600, written by us — trusted)
# shellcheck disable=SC1091
source /etc/proxyebator/server.conf
```

`source` is correct here because:
- File is root-owned, chmod 600
- We wrote it during install — contents are trusted
- Simpler than a key=value parser
- Variables match exactly what verify_main needs (DOMAIN, LISTEN_PORT, SECRET_PATH, TUNNEL_PORT, CERT_PATH)

### Anti-Patterns to Avoid

- **Calling `die` in a check FAIL branch:** `die` calls `exit 1` immediately — this violates "continue all checks" invariant. Use `check_fail` + `return` for early-exit within a check, never `die`.
- **`all_ok=true` boolean:** Loses the count needed for "X CHECKS FAILED" banner. Use `fail_count` integer instead.
- **Naked commands in FAIL branches with set -e:** `systemctl status proxyebator` in an else branch will kill the script if systemd is unhappy. Always `|| true`.
- **`local result=$(cmd)` combined declaration+assignment:** Hides command failures under `set -e`. Separate declaration and assignment.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| TLS cert expiry check | Date math from `openssl x509 -dates` output | `openssl x509 -noout -checkend 2592000` | `-checkend` returns clean exit code; date math requires parsing locale-dependent strings |
| DNS resolution | Custom HTTP parser | Existing `dns.google/resolve` + `grep -oP` pattern from `validate_domain()` | Already validated in Phase 2; copy pattern directly |
| Public IP detection | New service | Existing `curl https://api.ipify.org` + `https://ifconfig.me` fallback from `validate_domain()` | Same pattern, copy directly |
| Firewall check | `iptables -C` (check) | `iptables -L INPUT -n` + grep | `-C` checks if exact rule exists (fragile to flag order); `-L` lists all rules for grep |

**Key insight:** Phase 3 has zero novel algorithms. Every check reuses a command already present in Phase 2. The value is combining them into a cohesive, non-fatal loop with structured output.

---

## Common Pitfalls

### Pitfall 1: set -e Kills FAIL Diagnostic Output
**What goes wrong:** `systemctl status proxyebator` inside an `else` branch returns non-zero, killing the script mid-verification. User sees partial output with no summary banner.
**Why it happens:** `set -e` exits on any non-zero return, including status commands for failed services.
**How to avoid:** Always append `|| true` to diagnostic commands in FAIL branches. Pattern: `cmd >&2 2>/dev/null || true`.
**Warning signs:** Script exits before printing "=== X CHECKS FAILED ===" banner.

### Pitfall 2: local + Assignment Hides Failures
**What goes wrong:** `local http_code=$(curl ...)` — if curl fails with network error, `local` returns 0 regardless, and `http_code` is empty. Check incorrectly passes or gives wrong result.
**Why it happens:** `local` keyword always returns exit code 0 in bash, masking the substitution failure.
**How to avoid:** `local http_code; http_code=$(curl ...) || http_code="000"`. The `|| http_code="000"` fallback gives a detectable failure value.
**Warning signs:** Check 4 (WS path) passes with 000 response code.

### Pitfall 3: TLS check_end Semantics Are Inverted
**What goes wrong:** `openssl x509 -noout -checkend 2592000 -in cert.pem` — developers read "check if cert expires in 30 days" and expect non-zero = expires soon. But exit code 0 means cert is VALID for 30+ more days, exit 1 means it expires within that window.
**Why it happens:** `-checkend` semantics: "check that cert does NOT expire within N seconds." 0 = safe.
**How to avoid:** `if openssl x509 -noout -checkend 2592000 ...; then check_pass else check_fail fi` — the `if` branch is the PASS case.
**Warning signs:** TLS check reports FAIL immediately after fresh certbot issue.

### Pitfall 4: Firewall Check Differs by Active Tool
**What goes wrong:** Script only checks `ufw status` but system uses iptables (ufw inactive). Or script checks iptables but ufw is active and has the rule — finding nothing and falsely reporting FAIL.
**Why it happens:** Phase 2 uses ufw IF active, else iptables. Verify must follow the same decision tree.
**How to avoid:** Mirror Phase 2 logic exactly: `if ufw active → check ufw; else → check iptables`. The `ufw status | grep "Status: active"` test comes first.
**Warning signs:** Firewall check always FAILs on iptables-only servers.

### Pitfall 5: Certbot Timer Has Two Names
**What goes wrong:** Timer check looks for `certbot.timer` but certbot was installed via snap, which creates `snap.certbot.renew.timer`.
**Why it happens:** snap packages create their own systemd units. Phase 2 handles both in `server_obtain_tls`.
**How to avoid:** `systemctl list-units --type=timer | grep -qE "certbot\.timer|snap\.certbot\.renew"` — grep for both names.
**Warning signs:** Renewal timer FAIL on servers with snap certbot.

### Pitfall 6: verify mode in CLI Dispatcher Missing
**What goes wrong:** Adding `verify_main()` but forgetting to add `verify` to the `case "$MODE"` dispatcher and `case "$1"` mode extraction. User runs `./proxyebator.sh verify` and gets "Unknown command: verify".
**Why it happens:** The CLI dispatcher has TWO case statements — one for mode extraction (line ~849) and one for dispatch (line ~872). Both must be updated.
**Warning signs:** `./proxyebator.sh verify` prints usage error.

---

## Code Examples

### Check 1: systemd service active
```bash
# Source: Phase 2 server_verify(), verified against systemd docs
if systemctl is-active --quiet proxyebator 2>/dev/null; then
    check_pass "proxyebator.service is active"
else
    check_fail "proxyebator.service is NOT active"
    systemctl status proxyebator --no-pager --lines=5 >&2 2>/dev/null || true
    printf "  Try: systemctl restart proxyebator\n" >&2
fi
```

### Check 2: Tunnel port bound to 127.0.0.1
```bash
# Source: Phase 2 server_verify(), TUNNEL_PORT from server.conf
if ss -tlnp 2>/dev/null | grep ":${TUNNEL_PORT} " | grep -q '127\.0\.0\.1'; then
    check_pass "Tunnel port ${TUNNEL_PORT} bound to 127.0.0.1"
else
    check_fail "Tunnel port ${TUNNEL_PORT} NOT bound to 127.0.0.1 — SECURITY RISK"
    ss -tlnp 2>/dev/null | grep ":${TUNNEL_PORT} " >&2 || true
    printf "  Try: systemctl restart proxyebator\n" >&2
fi
```

### Check 3: Firewall blocks port 7777
```bash
# Source: mirrors Phase 2 server_configure_firewall() decision tree
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    # ufw active path
    if ufw status 2>/dev/null | grep "${TUNNEL_PORT}" | grep -qi "DENY"; then
        check_pass "Firewall: port ${TUNNEL_PORT} DENY rule exists (ufw)"
    else
        check_fail "Firewall: no DENY rule for port ${TUNNEL_PORT} in ufw"
        ufw status 2>/dev/null >&2 || true
        printf "  Try: ufw deny %s/tcp\n" "${TUNNEL_PORT}" >&2
    fi
else
    # iptables path
    if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:${TUNNEL_PORT}"; then
        check_pass "Firewall: port ${TUNNEL_PORT} DROP rule exists (iptables)"
    else
        check_fail "Firewall: no DROP rule for port ${TUNNEL_PORT} in iptables"
        iptables -L INPUT -n 2>/dev/null | head -20 >&2 || true
        printf "  Try: iptables -A INPUT -p tcp --dport %s ! -i lo -j DROP\n" "${TUNNEL_PORT}" >&2
    fi
fi
```

### Check 4: Cover site returns HTTP 200
```bash
# Source: Phase 2 server_verify()
local http_code
http_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
    "https://${DOMAIN}/" 2>/dev/null) || http_code="000"
if [[ "$http_code" == "200" ]]; then
    check_pass "Cover site https://${DOMAIN}/ returns HTTP 200"
else
    check_fail "Cover site returned HTTP ${http_code} (expected 200)"
    curl -sk --max-time 10 -v "https://${DOMAIN}/" >/dev/null 2>&1 | head -20 >&2 || true
    printf "  Try: nginx -t && systemctl reload nginx\n" >&2
fi
```

### Check 5: WebSocket path reachable
```bash
# Source: Phase 2 server_verify() with WS upgrade headers added per VER-02
# Accept 101 (upgrade ok), 200 (chisel responds, auth needed), 400 (nginx proxied, chisel rejected)
# Fail on 404 (path not routed) and 000 (connection refused)
local ws_code
ws_code=$(curl -sk --max-time 10 \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    -o /dev/null -w "%{http_code}" \
    "https://${DOMAIN}:${LISTEN_PORT}/${SECRET_PATH}/" 2>/dev/null) || ws_code="000"
if [[ "$ws_code" == "101" || "$ws_code" == "200" || "$ws_code" == "400" ]]; then
    check_pass "WebSocket path /${SECRET_PATH}/ reachable (HTTP ${ws_code})"
else
    check_fail "WebSocket path returned HTTP ${ws_code} (expected 101/200/400)"
    printf "  Check nginx tunnel block for /%s/\n" "${SECRET_PATH}" >&2
    printf "  Try: nginx -t && systemctl reload nginx\n" >&2
fi
```

### Check 6: TLS certificate validity + chain + renewal timer
```bash
# Source: openssl x509 -checkend semantics verified (exit 0 = cert valid for N+ seconds)
# 2592000 = 30 days in seconds
local tls_ok=true

if [[ ! -f "${CERT_PATH}" ]]; then
    check_fail "TLS cert file not found: ${CERT_PATH}"
    printf "  Try: certbot certonly --nginx -d %s\n" "${DOMAIN}" >&2
    tls_ok=false
else
    # Check cert expires in 30+ days
    if openssl x509 -noout -checkend 2592000 -in "${CERT_PATH}" 2>/dev/null; then
        local expiry
        expiry=$(openssl x509 -noout -enddate -in "${CERT_PATH}" 2>/dev/null | cut -d= -f2) || expiry="unknown"
        # Check chain of trust against system CA bundle
        local ca_bundle=""
        for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
            [[ -f "$f" ]] && { ca_bundle="$f"; break; }
        done
        if [[ -n "$ca_bundle" ]] && ! openssl verify -CAfile "$ca_bundle" "${CERT_PATH}" &>/dev/null; then
            check_fail "TLS cert chain of trust invalid (expires: ${expiry})"
            printf "  Try: certbot certonly --nginx -d %s --force-renewal\n" "${DOMAIN}" >&2
            tls_ok=false
        else
            # Check renewal timer
            if systemctl list-units --type=timer 2>/dev/null | grep -qE "certbot\.timer|snap\.certbot\.renew"; then
                check_pass "TLS cert valid (expires: ${expiry}), renewal timer active"
            else
                check_fail "TLS cert valid (expires: ${expiry}) but renewal timer missing"
                printf "  Try: systemctl enable --now certbot.timer\n" >&2
                printf "  Or:  systemctl enable --now snap.certbot.renew.timer\n" >&2
                tls_ok=false
            fi
        fi
    else
        local expiry
        expiry=$(openssl x509 -noout -enddate -in "${CERT_PATH}" 2>/dev/null | cut -d= -f2) || expiry="unknown"
        check_fail "TLS cert expires within 30 days: ${expiry}"
        printf "  Try: certbot renew\n" >&2
        tls_ok=false
    fi
fi

[[ "$tls_ok" == "false" ]] && fail_count=$(( fail_count + 1 ))
```

**Note:** Check 6 is ONE counter increment (one item in the 7-count), but has multiple internal sub-conditions. The `tls_ok` local tracks whether any sub-condition failed, and `fail_count` is incremented only once at the end.

### Check 7: DNS resolves to server IP
```bash
# Source: validate_domain() pattern from Phase 2, adapted to non-fatal
local server_ip domain_ip dns_resp first_octet

server_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) \
    || server_ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null) \
    || server_ip=""

if [[ -z "$server_ip" ]]; then
    check_fail "Could not determine server public IP — check internet connectivity"
else
    dns_resp=$(curl -sf --max-time 10 \
        "https://dns.google/resolve?name=${DOMAIN}&type=A" 2>/dev/null) || dns_resp=""
    domain_ip=$(printf '%s' "$dns_resp" \
        | grep -oP '"data"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1) || domain_ip=""

    if [[ -z "$domain_ip" ]]; then
        check_fail "DNS: could not resolve ${DOMAIN} — check DNS A-record"
    elif [[ "$domain_ip" != "$server_ip" ]]; then
        # Cloudflare orange cloud detection
        first_octet=$(printf '%s' "$domain_ip" | cut -d. -f1)
        case "$first_octet" in
            103|104|108|141|162|172|173|188|190|197|198)
                check_fail "DNS: ${DOMAIN} resolves to Cloudflare IP ${domain_ip} (orange cloud)"
                printf "  Switch to grey cloud (DNS-only) in Cloudflare dashboard\n" >&2
                ;;
            *)
                check_fail "DNS: ${DOMAIN} resolves to ${domain_ip}, expected ${server_ip}"
                printf "  Update DNS A-record for %s to point to %s\n" "${DOMAIN}" "${server_ip}" >&2
                ;;
        esac
    else
        check_pass "DNS: ${DOMAIN} resolves to ${server_ip} (correct)"
    fi
fi
```

### CLI Dispatcher Changes
```bash
# Source: existing proxyebator.sh structure — both case statements must be updated

# Statement 1: mode extraction (around line 849)
case "$1" in
    server|client|uninstall|verify) MODE="$1"; shift ;;  # ADD verify HERE
    --help|-h) print_usage; exit 0 ;;
    *) print_usage; die "Unknown command: $1" ;;
esac

# Statement 2: dispatch (around line 872)
case "$MODE" in
    server)    server_main ;;
    client)    client_main ;;
    uninstall) uninstall_main ;;
    verify)    check_root; verify_main; exit $? ;;  # ADD verify HERE
esac

# server_main() update: call verify_main instead of server_verify
server_main() {
    ...
    server_save_config
    verify_main  # was: server_verify
    local verify_exit=$?
    exit $verify_exit
}
```

### Summary Banner Pattern
```bash
# Source: derived from user CONTEXT.md output format requirements
local pass_count=$(( total_checks - fail_count ))
if [[ $fail_count -eq 0 ]]; then
    printf "\n${GREEN}${BOLD}=== ALL CHECKS PASSED (%d/%d) ===${NC}\n" \
        "$pass_count" "$total_checks"
    server_print_connection_info
    return 0
else
    printf "\n${RED}${BOLD}=== %d CHECK(S) FAILED (%d/%d passed) ===${NC}\n" \
        "$fail_count" "$pass_count" "$total_checks" >&2
    return 1
fi
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| `all_ok=true` boolean (Phase 2) | `fail_count` integer | Enables "X/7" banner format, exact failure count |
| `server_verify()` (post-install only) | `verify_main()` (standalone + post-install) | Same function for both use cases, no logic duplication |
| `server_print_connection_info` always printed | Connection block only on ALL PASS | Prevents false "everything is fine" signal when checks failed |
| 4 checks in Phase 2 | 7 checks in Phase 3 | Catches TLS expiry, DNS drift, firewall regression |

**Deprecated:**
- `server_verify()` function: fully replaced by `verify_main()`. The old function body should be deleted (not kept as dead code).

---

## Open Questions

1. **TLS check: count renewal timer as separate FAIL or sub-condition of check 6?**
   - What we know: CONTEXT.md lists TLS cert as ONE of the 7 checks, not two
   - What's unclear: If cert valid but timer missing, should that count as 1 FAIL or 0.5?
   - Recommendation: Count as ONE FAIL (the whole TLS check fails). `tls_ok` internal flag aggregates cert + chain + timer. Rationale: timer failure alone on a fresh cert is a "warning-level" issue but the check is still marked FAIL to force the user to fix it.

2. **Cloudflare orange cloud: FAIL or WARN?**
   - What we know: CF orange cloud breaks WebSocket tunnels (from Phase 2 `validate_domain` logic)
   - What's unclear: DNS check passes domain-to-server-IP, but CF orange cloud means domain_ip != server_ip anyway — it would already show as a different FAIL
   - Recommendation: If domain_ip is CF range AND domain_ip != server_ip → FAIL with CF-specific message. If domain_ip IS server_ip despite being in a CF range (unusual, edge case) → treat as PASS since tunnel connectivity is the actual test.

3. **verify_main and check_root: when called from server_main?**
   - What we know: `server_main()` already calls `check_root` at start. `verify_main()` as standalone must also check root.
   - Recommendation: `verify_main()` should call `check_root` itself at its start. When called from `server_main`, the double `check_root` call is harmless (idempotent). When called standalone via CLI dispatcher (`./proxyebator.sh verify`), root is properly required.

---

## Sources

### Primary (HIGH confidence)
- Existing `proxyebator.sh` lines 756-811 (`server_verify`) — baseline for check patterns 1-4
- Existing `proxyebator.sh` lines 159-193 (`validate_domain`) — DNS-over-HTTPS and Cloudflare detection reused verbatim
- Existing `proxyebator.sh` lines 677-708 (`server_configure_firewall`) — firewall decision tree mirrored for check 7
- OpenSSL 3.x `x509 -checkend` behavior — verified via `openssl x509 --help` on the target system (OpenSSL 3.5.3)
- bash `set -euo pipefail` semantics — verified via testing (if conditions, local assignment, || true)

### Secondary (MEDIUM confidence)
- Certbot timer naming (`certbot.timer` vs `snap.certbot.renew.timer`) — derived from Phase 2 `server_obtain_tls()` which already handles both; `systemctl list-units` grep for both confirmed as correct approach
- Chisel WS response codes (200 on unauthorized connection, 101 on valid upgrade) — inferred from Phase 2 check accepting 200 as valid; consistent with Chisel being a Go HTTP server that responds 200 to unauthenticated requests

### Tertiary (LOW confidence)
- Cloudflare first-octet IP ranges (103, 104, 108, 141, 162, 172, 173, 188, 190, 197, 198) — copied from existing `validate_domain()` which was researched in Phase 2. May not be exhaustive.

---

## Metadata

**Confidence breakdown:**
- Check implementations (1-4): HIGH — direct port from existing server_verify()
- Check 5 (TLS): HIGH — openssl flags verified on system
- Check 6 (DNS): HIGH — direct port from existing validate_domain()
- Check 7 (Firewall): HIGH — mirrors exact Phase 2 firewall logic
- Check ordering: HIGH — logical dependency analysis
- Bash set -e safety patterns: HIGH — verified against bash specification
- WS upgrade response codes: MEDIUM — inferred from Phase 2 + Chisel behavior

**Research date:** 2026-02-18
**Valid until:** 2026-04-18 (stable domain — bash + openssl + systemd APIs are stable)
