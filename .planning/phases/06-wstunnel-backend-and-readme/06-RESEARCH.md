# Phase 6: wstunnel Backend and README — Research

**Researched:** 2026-02-18
**Domain:** wstunnel v10 CLI integration, bash script extension, Russian technical README
**Confidence:** HIGH (wstunnel flags verified from live GitHub README and release API; binary name verified from actual tarball; nekoray archive status verified from GitHub API; Throne status verified from GitHub API)

---

## Summary

Phase 6 has two independent workstreams: (1) adding wstunnel as a second tunnel backend alongside chisel in proxyebator.sh, and (2) writing a comprehensive Russian README.md. The wstunnel workstream is mostly mechanical extension of existing code patterns — the architecture, nginx integration, and systemd service structure are all proven in phases 2–5. The README workstream is pure documentation work with specific formatting requirements (shields.io badges, `<details>` blocks, GUI client instructions, AI-agent block).

The most important pre-verified fact for the wstunnel backend: wstunnel v10 does **not** have built-in SOCKS5 on the server side. Chisel's `--socks5` flag made the server handle SOCKS5; wstunnel's SOCKS5 is entirely client-side via `-L socks5://127.0.0.1:PORT`. The server just acts as a WebSocket-to-TCP forwarder. This means the nginx location block and systemd unit for wstunnel look similar to chisel's, but the client command is fundamentally different.

The second critical fact: wstunnel authentication. wstunnel has `--restrict-http-upgrade-path-prefix` but this does NOT work behind nginx when nginx uses `proxy_pass` with trailing slash (nginx strips the path before forwarding). The documented solution (from existing PROXY-GUIDE.md in the repo) is to rely on the nginx location block as the access gate — only traffic matching `location /SECRET_PATH/` reaches wstunnel, and wstunnel is bound to 127.0.0.1 anyway. Skip `--restrict-http-upgrade-path-prefix` for the nginx-fronted setup. The proxyebator.sh secret path IS the auth.

For the README: nekoray is archived (confirmed GitHub API, last release 2024-12-12). The active desktop proxy client is Throne (throneproj/Throne, v1.0.13 released 2025-12-30, uses sing-box). The README should document nekoray/nekobox as its last released form (v4.0.1, Linux AppImage + Windows zip) alongside the note that it is archived and Throne is the recommended successor.

**Primary recommendation:** Implement wstunnel as a parallel code path alongside chisel — separate download, auth-setup, systemd, and uninstall functions all named `server_*_wstunnel` — then branch on `TUNNEL_TYPE` in `server_main`. Write README.md in Russian per DOC-01 through DOC-06 requirements.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TUNNEL-04 | wstunnel: run server with correct v10+ flags, detect binary name (wstunnel/wstunnel-cli) | wstunnel API section below: binary is `wstunnel`, server flags fully documented |
| DOC-01 | README in Russian with centered header and shields.io badges | README Structure section below |
| DOC-02 | Parameter tables, variable tables, supported OS table | README Structure section below |
| DOC-03 | Collapsible `<details>` blocks for sections | README Structure section below |
| DOC-04 | GUI client instructions: Throne (Linux), nekoray/nekobox (Linux/Windows), Proxifier (Windows/macOS), Surge (macOS) | GUI Clients section below |
| DOC-05 | "Copy this and send to AI assistant" block with numbered deployment steps | AI Agent Block section below |
| DOC-06 | Troubleshooting section covering known pitfalls | Pitfalls section below |
</phase_requirements>

---

## Standard Stack

### Core (wstunnel backend)

| Component | Version | Purpose | Source |
|-----------|---------|---------|--------|
| wstunnel | v10.5.2 (current) | WebSocket tunnel binary | github.com/erebe/wstunnel, GitHub Releases API |
| bash | existing | Script extension | proxyebator.sh already bash |
| nginx | existing | TLS terminator + access gate | Same role as chisel deployment |
| systemd | existing | Service management | Same role as chisel deployment |

### Binary Naming (TUNNEL-04 blocker, now resolved)

| Context | Binary name | Notes |
|---------|-------------|-------|
| Release tarball | `wstunnel` | Confirmed by extracting `wstunnel_10.5.2_linux_amd64.tar.gz` |
| Docker image CMD | `wstunnel-cli` | Docker entrypoint only — irrelevant for our use case |

**Conclusion:** Binary is always `wstunnel` in the release tarballs. No need to detect `wstunnel-cli`.

### Release Asset Pattern

```
wstunnel_{VERSION_WITHOUT_V}_linux_amd64.tar.gz
wstunnel_{VERSION_WITHOUT_V}_linux_arm64.tar.gz
wstunnel_{VERSION_WITHOUT_V}_linux_armv7.tar.gz
```

Format: `.tar.gz` (NOT `.gz` like chisel). Must use `tar -xzf`, not `gunzip`.

**Installation:**
```bash
WSTUNNEL_VER=$(curl -sf --max-time 10 \
    "https://api.github.com/repos/erebe/wstunnel/releases/latest" \
    | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*') \
    || WSTUNNEL_VER=""
# Asset: wstunnel_X.Y.Z_linux_{amd64|arm64}.tar.gz
local download_url="https://github.com/erebe/wstunnel/releases/download/${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER#v}_linux_${ARCH}.tar.gz"
curl -fLo /tmp/wstunnel.tar.gz "$download_url"
tar -xzf /tmp/wstunnel.tar.gz -C /tmp/ wstunnel
chmod +x /tmp/wstunnel
mv /tmp/wstunnel /usr/local/bin/wstunnel
```

---

## Architecture Patterns

### wstunnel vs Chisel: Key Differences

| Aspect | Chisel | wstunnel |
|--------|--------|---------|
| Server SOCKS5 | Built-in (`--socks5` flag) | None — server is pure WebSocket relay |
| Client SOCKS5 | `socks` tunnel arg | `-L socks5://127.0.0.1:PORT` |
| Auth | `--authfile /etc/chisel/auth.json` (JSON file) | Path-based (nginx location = gatekeeper; no file) |
| Internal port | 7777 | 7778 (use different port to avoid conflict) |
| Binary compression | `.gz` (gunzip) | `.tar.gz` (tar xzf) |
| Server bind flag | `--host 127.0.0.1 -p 7777` | `ws://127.0.0.1:7778` (positional arg) |

### wstunnel Server: Complete Command (v10+)

```bash
# Source: https://raw.githubusercontent.com/erebe/wstunnel/master/README.md
wstunnel server ws://127.0.0.1:7778
```

**Flags NOT used** (and why):
- `--restrict-http-upgrade-path-prefix SECRET` — nginx with trailing slash `proxy_pass` strips the path before wstunnel sees it, so the restriction check sees `/` instead of `/SECRET/` and rejects every connection. Security is provided by nginx location block gating instead.
- `--tls-certificate` / `--tls-private-key` — nginx handles TLS.

### wstunnel Server systemd Unit

```ini
[Unit]
Description=wstunnel Server (proxyebator)
After=network.target

[Service]
ExecStart=/usr/local/bin/wstunnel server ws://127.0.0.1:7778
Restart=always
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
```

### nginx Location Block for wstunnel

Identical to chisel block — same headers, same timeouts. **The only change is the backend port** and trailing slash is still used (stripping the path is correct — wstunnel does not need to see the path):

```nginx
location /${SECRET_PATH}/ {
    proxy_pass http://127.0.0.1:7778/;   # wstunnel port, trailing slash strips prefix
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

**Security model:** nginx location `/${SECRET_PATH}/` is the access gate. Only requests to that exact path reach wstunnel. wstunnel is bound to 127.0.0.1 — unreachable from outside. This is equivalent to chisel's auth file; the secret path substitutes for a username/password.

### wstunnel Client Command

```bash
# Source: https://raw.githubusercontent.com/erebe/wstunnel/master/README.md
wstunnel client \
    -L socks5://127.0.0.1:1080 \
    --connection-min-idle 5 \
    wss://example.com:443/SECRET_PATH/
```

Note: The URL path `/SECRET_PATH/` is part of the wss:// URL. wstunnel uses it as the HTTP Upgrade path (equivalent to `--http-upgrade-path-prefix SECRET_PATH`).

### server_main Branching Pattern

```bash
server_main() {
    check_root
    detect_os
    detect_arch
    server_collect_params   # prompts for TUNNEL_TYPE (chisel|wstunnel)
    server_show_summary
    server_install_deps
    if [[ "${TUNNEL_TYPE}" == "wstunnel" ]]; then
        server_download_wstunnel
        server_create_systemd_wstunnel
    else
        server_download_chisel
        server_setup_auth
        server_create_systemd
    fi
    server_configure_nginx  # same for both (TUNNEL_PORT variable controls port)
    server_obtain_tls
    server_configure_firewall   # same for both (TUNNEL_PORT variable controls deny rule)
    server_save_config
    verify_main
}
```

### server.conf Changes for wstunnel

```bash
TUNNEL_TYPE=wstunnel
TUNNEL_PORT=7778   # was 7777 for chisel
```

The verify_main, firewall, and uninstall functions already use `TUNNEL_PORT` from server.conf — they will work without modification once TUNNEL_PORT is set correctly.

### Uninstall Changes for wstunnel

The `_uninstall_binary` function needs to branch on TUNNEL_TYPE:
```bash
_uninstall_binary() {
    if [[ "${TUNNEL_TYPE:-chisel}" == "wstunnel" ]]; then
        rm -f /usr/local/bin/wstunnel
    else
        rm -f /usr/local/bin/chisel
        rm -f /etc/chisel/auth.json
        rmdir /etc/chisel 2>/dev/null || true
    fi
}
```

### Tunnel Type Selection in server_collect_params

```bash
# Currently (phase 5 code):
if [[ -z "$TUNNEL_TYPE" ]]; then
    TUNNEL_TYPE="chisel"
elif [[ "$TUNNEL_TYPE" != "chisel" ]]; then
    die "Tunnel type '${TUNNEL_TYPE}' is not yet supported. Only 'chisel' is available (wstunnel coming in Phase 6)."
fi

# Phase 6 replacement:
if [[ -z "$TUNNEL_TYPE" ]]; then
    printf "${CYAN}[?]${NC} Tunnel backend [chisel/wstunnel] (default: chisel): "
    read -r TUNNEL_TYPE
    TUNNEL_TYPE="${TUNNEL_TYPE:-chisel}"
fi
case "${TUNNEL_TYPE}" in
    chisel|wstunnel) ;;
    *) die "Unknown tunnel type '${TUNNEL_TYPE}'. Use 'chisel' or 'wstunnel'." ;;
esac
```

### Anti-Patterns to Avoid

- **Using `--restrict-http-upgrade-path-prefix` with nginx**: nginx strips the path prefix before forwarding (trailing slash in `proxy_pass`), so wstunnel sees `/` not `/SECRET/`, and all connections are rejected. The nginx location block is the security gate.
- **Using `--tls-verify-certificate` on the client side**: cert is Let's Encrypt (valid), but the flag is off by default anyway — no action needed.
- **Using `wstunnel-cli` as binary name**: In the release tarballs, the binary is named `wstunnel`. `wstunnel-cli` appears only as the Docker entrypoint.
- **Using `.gz` decompression for wstunnel**: wstunnel uses `.tar.gz` (unlike chisel which uses `.gz`). Use `tar -xzf`, not `gunzip`.

---

## README Structure (DOC-01 through DOC-06)

### DOC-01: Centered Header and Shields.io Badges

```markdown
<div align="center">

# proxyebator

Маскирует трафик под обычный HTTPS — nginx + Chisel/wstunnel + WebSocket

[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/...)
[![Shell](https://img.shields.io/badge/shell-bash-89e051)](https://github.com/...)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Chisel](https://img.shields.io/badge/backend-chisel-orange)](https://github.com/jpillora/chisel)
[![wstunnel](https://img.shields.io/badge/backend-wstunnel-purple)](https://github.com/erebe/wstunnel)

</div>
```

Shields.io badge URL format: `https://img.shields.io/badge/LABEL-MESSAGE-COLOR`
Color options: blue, green, red, orange, purple, yellow, lightgrey, brightgreen

### DOC-02: Parameter Tables

Required tables per requirements:
1. **CLI flags table** — `--domain`, `--tunnel`, `--port`, `--masquerade`, client flags
2. **Environment/variables table** — what server.conf stores
3. **Supported OS table** — Debian/Ubuntu/CentOS/RHEL/AlmaLinux/Rocky/Arch/Fedora

### DOC-03: Collapsible `<details>` Blocks

HTML `<details>`/`<summary>` syntax for collapsible sections:
```html
<details>
<summary>Установка на сервер (разворачивает инструкцию)</summary>

Контент внутри.

</details>
```

GitHub Markdown renders these natively. Use for: installation steps, client configurations, troubleshooting.

### DOC-04: GUI Client Instructions

#### Client Status Summary (verified 2026-02-18)

| Client | Platform | Status | Latest |
|--------|----------|--------|--------|
| **Throne** | Linux, Windows, macOS | Active | v1.0.13 (2025-12-30) |
| **nekoray/nekobox** | Linux, Windows | ARCHIVED | v4.0.1 (2024-12-12) |
| **Proxifier** | Windows, macOS | Active commercial | 4.x (check proxifier.com) |
| **Surge** | macOS, iOS | Active commercial | 5.x (check surge.run) |

#### Throne (Linux) — SOCKS5 Setup

Throne uses sing-box backend and can act as SOCKS5 client directly:
1. Add server → Type: SOCKS5 → Host: 127.0.0.1 → Port: 1080 → No auth
2. Enable System Proxy mode (HTTP/HTTPS) for browser traffic
3. TUN mode for all-traffic routing (requires root/sudo)

**TUN routing loop prevention** (critical for Throne + Chisel/wstunnel):
```
Rule: processName = chisel → outbound: direct
Rule: processName = wstunnel → outbound: direct
Rule: ip_cidr = 127.0.0.1/32 → outbound: direct
Rule: domain_suffix = YOURDOMAIN.COM → outbound: direct
```

Without these rules, TUN captures the tunnel client's own traffic → infinite reconnect loop.

#### nekoray/nekobox (Linux/Windows)

- Repository: MatsuriDayo/nekoray — **ARCHIVED** since early 2025
- Last release: 4.0.1 (2024-12-12), executable renamed to `nekobox.exe` in 4.x
- Assets: Linux AppImage, Windows zip, Debian .deb
- Setup: Add server → Type: SOCKS5 → Address: 127.0.0.1 → Port: 1080

The README should note archive status and recommend Throne as active replacement.

#### Proxifier (Windows/macOS)

- Commercial software, proxy rules engine
- Add proxy server: 127.0.0.1:1080, SOCKS5, no auth
- Add proxification rule: Any → proxy server
- Or use per-application rules for selective routing

#### Surge (macOS)

- Commercial proxy client
- Add SOCKS5 policy: `proxy = socks5, 127.0.0.1, 1080`
- Route traffic via policy group or rules

### DOC-05: AI-Agent Block

The block must be copy-pasteable and give a complete deployment context without external references:

```markdown
## Скопируй это и отправь AI-ассистенту

> Отправь этот блок Claude, ChatGPT или другому AI — он развернёт сервер без дополнительных вопросов

**Задача:** развернуть proxyebator — маскирующий WebSocket-прокси — на моём Linux VPS.

**Что нужно сделать (по порядку):**

1. Подключись к серверу по SSH как root или через sudo
2. Убедись что установлен curl: `curl --version`
3. Скачай скрипт: `curl -fLO https://raw.githubusercontent.com/USER/REPO/main/proxyebator.sh`
4. Сделай исполняемым: `chmod +x proxyebator.sh`
5. Запусти: `sudo ./proxyebator.sh server --domain МОЙДОМЕН.COM --tunnel chisel`
6. Дождись вывода "=== ALL CHECKS PASSED ===" — это значит всё работает
7. Сохрани вывод с командой для клиента (строка с ./proxyebator.sh client ...)

**Требования к серверу:**
- Debian 12+, Ubuntu 22.04+, CentOS 8+, AlmaLinux 8+, или Arch Linux
- Открытые порты: 80/tcp (для certbot), 443/tcp (или другой через --port)
- Домен с A-записью, указывающей на IP этого сервера (серое облако Cloudflare!)
- Root доступ или sudo

**Что НЕ делать:**
- Не включать оранжевое облако Cloudflare — WebSocket не пройдёт через CDN
- Не запускать без домена — TLS сертификат нужен для маскировки
```

### DOC-06: Troubleshooting Section

Based on verified pitfalls from existing PROXY-GUIDE.md and phase research:

| Проблема | Причина | Решение |
|----------|---------|---------|
| Cloudflare оранжевое облако | CF CDN буферирует WebSocket, таймаут ~100 сек | Переключить DNS запись на серое облако (DNS only) |
| DNS утечка | SOCKS5 не проксирует DNS-запросы | `socks_remote_dns=true` в Firefox; TUN режим в Throne |
| TUN: бесконечный reconnect | TUN перехватывает трафик самого клиента туннеля | Добавить правило: processName chisel/wstunnel → direct |
| WebSocket 404 | Нет trailing slash в URL клиента | Убедиться что URL оканчивается на `/SECRET/` |
| Тоннель Connected, curl зависает | Нет `proxy_buffering off` в nginx | Добавить директиву в location block |
| Порт 7777/7778 виден снаружи | Chisel/wstunnel слушает 0.0.0.0 | Переустановить: `--host 127.0.0.1` или `ws://127.0.0.1:PORT` |
| verify: DNS resolves to Cloudflare IP | DNS A-запись указывает на CF IP (оранжевое) | Переключить на серое облако в CF Dashboard |

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Credentials out of `ps aux` | Custom credential-hiding scheme | Existing chisel authfile pattern (already in code) | Already solved in phase 2/5 |
| wstunnel authentication | Custom auth layer | nginx location block as gatekeeper | The path IS the auth; wstunnel is 127.0.0.1-only |
| README formatting | Custom HTML | GitHub-flavored Markdown + `<details>` HTML | GitHub renders both natively |
| Shields.io badges | SVG generation | shields.io CDN URL | Canonical pattern for GitHub READMEs |

---

## Common Pitfalls

### Pitfall 1: wstunnel `--restrict-http-upgrade-path-prefix` with nginx

**What goes wrong:** Developer adds `--restrict-http-upgrade-path-prefix SECRET` to wstunnel server systemd unit, thinking it adds authentication. All wstunnel connections fail with connection refused.

**Why it happens:** nginx `proxy_pass http://127.0.0.1:7778/;` with trailing slash strips the location prefix before forwarding. wstunnel server receives `GET / HTTP/1.1`, not `GET /SECRET/ HTTP/1.1`. The restriction check for `SECRET` never matches `/`.

**How to avoid:** Do not use `--restrict-http-upgrade-path-prefix` when wstunnel is behind nginx with trailing-slash `proxy_pass`. Rely on nginx location block gating instead.

**Warning signs:** All wstunnel connections fail immediately; server log shows no path match.

### Pitfall 2: tar.gz vs .gz for wstunnel download

**What goes wrong:** Script uses `gunzip` on wstunnel archive (same as chisel), gets corrupted binary.

**Why it happens:** chisel uses `.gz` (gunzip directly to binary), wstunnel uses `.tar.gz` (tarball). Wrong extraction command.

**How to avoid:** Use `tar -xzf /tmp/wstunnel.tar.gz -C /tmp/ wstunnel` with explicit member extraction.

### Pitfall 3: Cloudflare Orange Cloud Breaks WebSocket

**What goes wrong:** User enables Cloudflare proxying (orange cloud) for the domain. Chisel connects but traffic drops every ~100 seconds, or wstunnel fails entirely.

**Why it happens:** Cloudflare Free plan has a 100-second WebSocket timeout for proxied connections. Binary WebSocket data (non-HTTP) may also be filtered by CF's WAF.

**How to avoid:** Keep DNS record as grey cloud (DNS only) in Cloudflare dashboard. If IP hiding is needed, use Cloudflare Tunnel (cloudflared) instead.

**Warning signs:** verify_main check 7 fails with "DNS: resolves to Cloudflare IP XX.XXX.XXX.XX (orange cloud)".

### Pitfall 4: DNS Leaks

**What goes wrong:** User connects SOCKS5 proxy but DNS queries bypass the tunnel. ISP can see domain names being resolved.

**Why it happens:** Most SOCKS5 clients resolve DNS locally before connecting. The IP connects through SOCKS5 but the DNS query went to the local resolver.

**How to avoid:**
- Firefox: `about:config` → `network.proxy.socks_remote_dns = true`
- Throne TUN mode: routes all traffic including DNS
- Verify: `curl --socks5-hostname 127.0.0.1:1080 https://dnsleaktest.com`

### Pitfall 5: TUN Mode Routing Loop

**What goes wrong:** TUN mode enabled in Throne/sing-box. Chisel or wstunnel client can't connect; constant reconnect loop.

**Why it happens:** TUN intercepts ALL traffic including the tunnel client's own outbound connections. Client connects to server → TUN captures it → routes to proxy → proxy routes to client → loop.

**How to avoid:** Add direct-route rules in Throne before enabling TUN:
```
processName: chisel → direct
processName: wstunnel → direct
domain_suffix: YOURDOMAIN.COM → direct
```

---

## Code Examples

### wstunnel Download Function (server-side)

```bash
# Source: verified against GitHub releases API and actual tarball contents
server_download_wstunnel() {
    if [[ -x /usr/local/bin/wstunnel ]]; then
        log_info "wstunnel already installed: $(/usr/local/bin/wstunnel --version 2>&1 | head -1)"
        return
    fi

    rm -f /tmp/wstunnel.tar.gz /tmp/wstunnel 2>/dev/null || true

    local WSTUNNEL_FALLBACK_VER="v10.5.2"
    local WSTUNNEL_VER
    WSTUNNEL_VER=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/erebe/wstunnel/releases/latest" \
        | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*') \
        || WSTUNNEL_VER=""

    if [[ -z "$WSTUNNEL_VER" ]]; then
        log_warn "Could not fetch latest wstunnel version — using fallback ${WSTUNNEL_FALLBACK_VER}"
        WSTUNNEL_VER="$WSTUNNEL_FALLBACK_VER"
    fi

    # Asset: wstunnel_X.Y.Z_linux_{amd64|arm64}.tar.gz (tar.gz not .gz)
    local download_url="https://github.com/erebe/wstunnel/releases/download/${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER#v}_linux_${ARCH}.tar.gz"

    curl -fLo /tmp/wstunnel.tar.gz "$download_url" \
        || die "Failed to download wstunnel from $download_url"
    tar -xzf /tmp/wstunnel.tar.gz -C /tmp/ wstunnel \
        || die "Failed to extract wstunnel binary from tarball"
    rm -f /tmp/wstunnel.tar.gz
    chmod +x /tmp/wstunnel
    mv /tmp/wstunnel /usr/local/bin/wstunnel

    /usr/local/bin/wstunnel --version \
        || die "wstunnel binary not working after install"
    log_info "wstunnel installed: $(/usr/local/bin/wstunnel --version 2>&1 | head -1)"
}
```

### wstunnel systemd Unit Creation

```bash
# Source: pattern mirrors server_create_systemd for chisel (Phase 2)
server_create_systemd_wstunnel() {
    if systemctl is-active --quiet proxyebator 2>/dev/null; then
        log_info "proxyebator.service is already active — skipping service creation"
        return
    fi

    # TUNNEL_PORT for wstunnel is 7778 (7777 reserved for chisel)
    cat > /etc/systemd/system/proxyebator.service << 'UNIT'
[Unit]
Description=wstunnel Server (proxyebator)
After=network.target

[Service]
ExecStart=/usr/local/bin/wstunnel server ws://127.0.0.1:7778
Restart=always
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now proxyebator || die "Failed to start proxyebator.service"
    log_info "wstunnel systemd service: $(systemctl is-active proxyebator 2>/dev/null || echo 'unknown')"
}
```

### wstunnel Client Command (for server_print_connection_info)

```bash
# wstunnel client SOCKS5 — SOCKS5 is client-side, server is a pure relay
printf "  ${CYAN}wstunnel client \\\\${NC}\n"
printf "  ${CYAN}  -L socks5://127.0.0.1:${SOCKS_PORT:-1080} \\\\${NC}\n"
printf "  ${CYAN}  --connection-min-idle 5 \\\\${NC}\n"
printf "  ${CYAN}  wss://%s:%s/%s/${NC}\n" "${DOMAIN}" "${LISTEN_PORT}" "${SECRET_PATH}"
```

### server.conf TUNNEL_PORT for wstunnel

```bash
# In server_save_config, add TUNNEL_TYPE branching:
local tunnel_port=7777
[[ "${TUNNEL_TYPE}" == "wstunnel" ]] && tunnel_port=7778

cat > /etc/proxyebator/server.conf << EOF
DOMAIN=${DOMAIN}
LISTEN_PORT=${LISTEN_PORT}
SECRET_PATH=${SECRET_PATH}
TUNNEL_TYPE=${TUNNEL_TYPE}
TUNNEL_PORT=${tunnel_port}
...
EOF
```

### README shields.io Badge Format

```markdown
<!-- Source: shields.io documentation, standard GitHub README pattern -->
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/USER/REPO)
[![Shell](https://img.shields.io/badge/shell-bash-89e051)](https://github.com/USER/REPO)
[![Chisel](https://img.shields.io/badge/backend-chisel-orange)](https://github.com/jpillora/chisel)
[![wstunnel](https://img.shields.io/badge/backend-wstunnel-blueviolet)](https://github.com/erebe/wstunnel)
```

### README `<details>` Block Pattern

```html
<!-- GitHub renders <details>/<summary> natively in Markdown files -->
<details>
<summary><b>Установка (сервер)</b></summary>

```bash
sudo ./proxyebator.sh server --domain example.com
```

</details>
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|-----------------|--------------|--------|
| wstunnel Haskell (v6) | wstunnel Rust (v7+) | v7.0.0 | Not compatible, new CLI |
| wstunnel `wstunnel-cli` in Docker | `wstunnel` in release tarballs | v10 | Binary name depends on context |
| nekoray (active) | nekoray ARCHIVED, Throne active | 2025 | README must note archive status |

**Deprecated/outdated:**
- nekoray: ARCHIVED, no longer maintained. Last release 4.0.1 (2024-12-12). Executable renamed to nekobox.exe in 4.x.
- wstunnel pre-v7 Haskell API: completely replaced, all flags changed.

---

## Open Questions

1. **nginx location block path stripping with wstunnel client URL**
   - What we know: wstunnel client uses `wss://domain:443/SECRET_PATH/` as URL; the path appears in the HTTP Upgrade request; nginx matches `location /SECRET_PATH/` and strips it before forwarding to wstunnel
   - What's unclear: Does wstunnel client send the path as a query param or in the URL path? If in the URL path, does stripping cause any issue?
   - Recommendation: The existing PROXY-GUIDE.md in the repo (authored by the user) documents this exact setup working. Trust that and use trailing slash. Connection info should show `wss://domain:PORT/SECRET_PATH/` as the full URL.

2. **Surge macOS SOCKS5 configuration specifics**
   - What we know: Surge is a commercial proxy client for macOS/iOS using policy groups and rules
   - What's unclear: Current Surge config syntax (it changes between v4 and v5)
   - Recommendation: Document the general approach (SOCKS5 policy pointing to 127.0.0.1:1080) and link to Surge docs for current syntax. Mark as LOW confidence.

3. **Proxifier Windows/macOS current version and UI**
   - What we know: Proxifier is commercial, well-established, configures per-application SOCKS5 rules
   - What's unclear: Current version and exact UI labels (changes between versions)
   - Recommendation: Document the conceptual steps (add proxy server → add proxification rule) without depending on exact UI. Mark as MEDIUM confidence.

---

## Sources

### Primary (HIGH confidence)
- Live GitHub Releases API: `https://api.github.com/repos/erebe/wstunnel/releases/latest` — confirmed v10.5.2, asset naming, tarball format
- wstunnel README (raw): `https://raw.githubusercontent.com/erebe/wstunnel/master/README.md` — all server/client flags, authentication options, SOCKS5 syntax
- wstunnel tarball extraction: confirmed binary name is `wstunnel` (not `wstunnel-cli`)
- wstunnel restrictions.yaml: `https://raw.githubusercontent.com/erebe/wstunnel/main/restrictions.yaml` — confirmed server auth options
- GitHub API: MatsuriDayo/nekoray — confirmed `archived: true`, last release 4.0.1 (2024-12-12)
- GitHub API: throneproj/Throne — confirmed `archived: false`, v1.0.13 (2025-12-30)
- Existing `/home/kosya/vibecoding/proxyebator/PROXY-GUIDE.md` — user's own documented working configuration, confirms nginx+wstunnel integration patterns
- Existing `/home/kosya/vibecoding/proxyebator/tunnel-reference.md` — confirms binary naming, tarball format, port choices

### Secondary (MEDIUM confidence)
- Shields.io badge format: standard GitHub README convention, widely verified
- `<details>/<summary>` GitHub Markdown: documented GitHub behavior, stable

### Tertiary (LOW confidence)
- Proxifier SOCKS5 setup steps: general knowledge, UI may differ by version
- Surge macOS config syntax: general knowledge, syntax varies between v4/v5

---

## Metadata

**Confidence breakdown:**
- wstunnel binary name: HIGH — verified from actual tarball extraction
- wstunnel v10 server flags: HIGH — verified from live official README
- wstunnel authentication model: HIGH — verified from README + existing PROXY-GUIDE.md
- nekoray archive status: HIGH — verified from GitHub API
- Throne active status: HIGH — verified from GitHub API (v1.0.13, 2025-12-30)
- README structure patterns: HIGH — shields.io and `<details>` are standard
- Proxifier/Surge config details: LOW — general knowledge, verify in client docs

**Research date:** 2026-02-18
**Valid until:** 2026-03-18 (30 days for stable software; wstunnel is actively maintained but API is stable at v10)
