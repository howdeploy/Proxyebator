# Architecture Patterns

**Domain:** Masked WebSocket proxy tunnel deployment script
**Researched:** 2026-02-18
**Confidence:** HIGH — based on project reference docs (tunnel-reference.md, PROXY-GUIDE.md) containing validated real-world deployment knowledge

---

## Recommended Architecture

### Top-Level Structure: Mode Dispatcher

The script is a single file with a mode dispatcher at the entry point. All logic is organized into functions called by the dispatcher. This is the dominant pattern for multi-mode bash tools (see: certbot, docker-install.sh, openvpn-install.sh).

```
proxyebator.sh [mode] [options]
  ├── server    → server_main
  ├── client    → client_main
  └── uninstall → uninstall_main
```

### Script Section Order

```
1. HEADER           — shebang, set -euo pipefail, constants
2. LIBRARY          — utility functions (log, die, confirm, detect_os)
3. VALIDATION       — root check, dependency check, network check
4. OS DETECTION     — detect_os() → sets PKG_MANAGER, PKG_INSTALL, SVC_MANAGER
5. SECRET GENERATION — gen_secret_path(), gen_auth_token()
6. DEPENDENCY INSTALL — install_deps() per-mode dependencies
7. BINARY DOWNLOAD  — download_chisel() / download_wstunnel()
8. CONFIG GENERATION — write_nginx_conf(), write_systemd_unit(), write_auth_json()
9. SERVICE MANAGEMENT — enable_service(), reload_nginx()
10. VERIFICATION    — verify_server(), verify_client()
11. OUTPUT          — print_connection_params()
12. SERVER MODE     — server_main()
13. CLIENT MODE     — client_main()
14. UNINSTALL MODE  — uninstall_main()
15. ENTRY POINT     — mode dispatcher (last, calls server/client/uninstall)
```

---

## Component Boundaries

| Component | Responsibility | Input | Output |
|-----------|---------------|-------|--------|
| **Entry Point / Dispatcher** | Parse `$1`, route to mode function | `$@` args | Calls mode function |
| **OS Detection** | Identify distro, set pkg manager vars | `/etc/os-release`, `uname` | `$PKG_MANAGER`, `$PKG_INSTALL`, `$OS_FAMILY` |
| **Interactive Prompts** | Ask user: tunnel type, domain, masquerade mode | stdin | Shell vars: `$TUNNEL_TYPE`, `$DOMAIN`, `$MASQUERADE_MODE` |
| **Secret Generator** | Generate random WS path + auth token | `openssl rand` | `$SECRET_PATH`, `$AUTH_TOKEN`, `$AUTH_USER` |
| **Dependency Installer** | Install nginx, certbot, curl per OS | `$PKG_INSTALL`, mode | Packages installed |
| **Binary Downloader** | Fetch latest release from GitHub API, extract | GitHub API, arch detection | Binary at `/usr/local/bin/chisel` or `/usr/local/bin/wstunnel` |
| **Arch Detector** | Map `uname -m` to release filename suffix | `uname -m` | `$ARCH` (`amd64`, `arm64`, `386`) |
| **Auth Config Writer** | Write `/etc/chisel/auth.json` with token | `$AUTH_USER`, `$AUTH_TOKEN` | File on disk, `chmod 600` |
| **Nginx Config Writer** | Emit server block with WS location | `$DOMAIN`, `$SECRET_PATH`, `$TUNNEL_PORT`, `$MASQUERADE_MODE` | `/etc/nginx/sites-available/proxyebator` |
| **TLS Setup** | Run certbot, obtain Let's Encrypt cert | `$DOMAIN`, email (optional) | Certificate in `/etc/letsencrypt/live/$DOMAIN/` |
| **Systemd Unit Writer** | Write service file, daemon-reload, enable | Tunnel binary path, flags, user | `/etc/systemd/system/{chisel,wstunnel}.service` |
| **Service Enabler** | Enable + start service, verify active | Service name | Running service |
| **Nginx Reloader** | Test config, reload nginx | nginx config path | `nginx -t && systemctl reload nginx` |
| **Verification** | Check service active, port on 127.0.0.1 only, nginx 200 | Service name, port, domain | Pass/fail with diagnostic message |
| **Output Printer** | Print connection params in copy-paste format | All `$` vars | Human-readable + GUI-client instructions |
| **Client Mode** | Download binary, generate user-unit, connect | User input: server URL, token | SOCKS5 on localhost:1080 |
| **Uninstall Mode** | Stop+disable services, remove files, optionally purge nginx/certbot | Service names, config paths | Clean system |

---

## Data Flow: User Input to Running Tunnel

### Server Mode

```
User runs: bash proxyebator.sh server
    │
    ▼
[1. VALIDATION]
    check_root()          → exit if not root
    check_deps_minimal()  → curl/wget present?
    │
    ▼
[2. OS DETECTION]
    detect_os()
    → /etc/os-release → $OS_ID, $OS_FAMILY
    → sets $PKG_INSTALL (apt-get/dnf/pacman)
    → sets $SVC_CMD (systemctl)
    │
    ▼
[3. INTERACTIVE PROMPTS]
    prompt_tunnel_type()    → $TUNNEL_TYPE (chisel|wstunnel)
    prompt_domain()         → $DOMAIN
    prompt_port()           → $NGINX_PORT (443|2087|8443)
    prompt_masquerade()     → $MASQUERADE_MODE (stub|proxy-url|static-path)
    [if proxy-url] prompt_cover_url() → $COVER_URL
    [if static-path] prompt_static_path() → $STATIC_PATH
    │
    ▼
[4. SECRET GENERATION]
    SECRET_PATH=$(openssl rand -hex 16)   → /abc123def456.../
    AUTH_USER="user"
    AUTH_TOKEN=$(openssl rand -base64 24) → random password
    TUNNEL_PORT=7777  (chisel) | 8888  (wstunnel)
    │
    ▼
[5. DEPENDENCY INSTALL]
    $PKG_INSTALL nginx certbot python3-certbot-nginx curl
    │
    ▼
[6. BINARY DOWNLOAD]
    detect_arch()           → $ARCH (amd64|arm64)
    fetch_latest_version()  → GitHub API → $VERSION
    download_and_install()  → /usr/local/bin/chisel or /usr/local/bin/wstunnel
    │
    ▼
[7. TLS SETUP]
    certbot --nginx -d $DOMAIN  → /etc/letsencrypt/live/$DOMAIN/
    │
    ▼
[8. AUTH CONFIG]  (chisel only)
    mkdir /etc/chisel
    write /etc/chisel/auth.json  → {"$AUTH_USER:$AUTH_TOKEN": [".*:.*"]}
    chmod 600 /etc/chisel/auth.json
    chown nobody:nogroup /etc/chisel/auth.json
    │
    ▼
[9. NGINX CONFIG]
    write_nginx_conf()
    → /etc/nginx/sites-available/proxyebator
    → server block with:
        location /$SECRET_PATH/ { proxy_pass 127.0.0.1:$TUNNEL_PORT/; WS headers; proxy_buffering off; }
        location / { masquerade handler }
    nginx -t && systemctl reload nginx
    │
    ▼
[10. SYSTEMD UNIT]
    write_systemd_unit()
    → /etc/systemd/system/chisel.service (or wstunnel.service)
    → ExecStart: --host 127.0.0.1 -p $TUNNEL_PORT [chisel-specific flags]
    systemctl daemon-reload
    systemctl enable --now chisel (or wstunnel)
    │
    ▼
[11. VERIFICATION]
    check_service_active()   → systemctl is-active chisel
    check_port_localhost()   → ss -tlnp | grep $TUNNEL_PORT → must be 127.0.0.1
    check_nginx_cover()      → curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/ == 200
    check_ws_path_404()      → curl https://$DOMAIN/$SECRET_PATH/ == 404 (correct: no WS upgrade)
    │
    ▼
[12. OUTPUT]
    print_connection_params()
    → Server: $DOMAIN:$NGINX_PORT
    → WS Path: /$SECRET_PATH/
    → Auth: $AUTH_USER:$AUTH_TOKEN (chisel) | none (wstunnel)
    → SOCKS5: 127.0.0.1:1080
    → Client command (copy-paste ready)
    → GUI client instructions (Proxifier, nekoray, Throne)
```

### Client Mode

```
User runs: bash proxyebator.sh client
    │
    ▼
[1. OS DETECTION + VALIDATION]
    detect_os() → sets PKG_INSTALL
    check_deps_minimal()
    │
    ▼
[2. PROMPTS]
    prompt_tunnel_type()    → $TUNNEL_TYPE
    prompt_server_url()     → $SERVER_URL (https://domain:port/SECRET_PATH/)
    [if chisel] prompt_auth() → $AUTH_USER, $AUTH_TOKEN
    prompt_socks_port()     → $SOCKS_PORT (default 1080)
    │
    ▼
[3. BINARY DOWNLOAD]
    detect_arch()
    download_and_install() → /usr/local/bin/chisel or /usr/local/bin/wstunnel
    │
    ▼
[4. OPTIONAL: USER SYSTEMD UNIT]
    offer_autostart()  (yes/no)
    → ~/.config/systemd/user/chisel-client.service
    → systemctl --user enable --now chisel-client
    │
    ▼
[5. CONNECT + VERIFY]
    run_client_foreground()  (or background with autostart)
    verify_socks()  → curl --socks5-hostname 127.0.0.1:$SOCKS_PORT https://2ip.io
    │
    ▼
[6. OUTPUT]
    print_client_params()
    → SOCKS5: 127.0.0.1:$SOCKS_PORT
    → GUI client instructions
    → TUN mode routing rules for Throne (chisel/wstunnel processName → direct)
```

### Uninstall Mode

```
User runs: bash proxyebator.sh uninstall
    │
    ▼
confirm("This will remove tunnel, configs, and certs. Continue?")
    │
    ▼
stop_and_disable_services()   → systemctl stop/disable chisel wstunnel
remove_binaries()             → rm /usr/local/bin/chisel /usr/local/bin/wstunnel
remove_configs()              → rm -rf /etc/chisel /etc/systemd/system/chisel.service ...
remove_nginx_conf()           → rm /etc/nginx/sites-{available,enabled}/proxyebator
                              → systemctl reload nginx
[optional] revoke_cert()      → certbot delete --cert-name $DOMAIN
[optional] purge_packages()   → ask user: remove nginx/certbot?
```

---

## Config File Locations and Formats

### Server-side files written by script

| File | Format | Purpose |
|------|--------|---------|
| `/etc/chisel/auth.json` | JSON | Chisel authentication: `{"user:pass": [".*:.*"]}` |
| `/etc/systemd/system/chisel.service` | INI | Systemd unit: `ExecStart`, `User=nobody`, `Restart=always` |
| `/etc/systemd/system/wstunnel.service` | INI | Systemd unit for wstunnel |
| `/etc/nginx/sites-available/proxyebator` | nginx | Server block: WS location + masquerade location |
| `/etc/nginx/sites-enabled/proxyebator` | symlink | Activated nginx config |
| `/etc/proxyebator/server.conf` | key=value | Script state (domain, tunnel type, secret path, token) for uninstall |

### Client-side files written by script

| File | Format | Purpose |
|------|--------|---------|
| `~/.config/systemd/user/chisel-client.service` | INI | User-scope autostart unit |
| `~/.config/systemd/user/wstunnel-client.service` | INI | User-scope autostart for wstunnel |
| `~/.local/share/proxyebator/client.conf` | key=value | Saved connection params for reuse |

### State file format (`/etc/proxyebator/server.conf`)

```bash
# Written at install time, read by uninstall
TUNNEL_TYPE=chisel
DOMAIN=example.com
NGINX_PORT=443
SECRET_PATH=abc123def456
AUTH_USER=user
AUTH_TOKEN=s3cr3t
TUNNEL_PORT=7777
MASQUERADE_MODE=stub
INSTALL_DATE=2026-02-18
```

---

## Patterns to Follow

### Pattern 1: OS Detection via /etc/os-release

**What:** Source `/etc/os-release` to get `$ID` and `$ID_LIKE`, map to package manager.

**When:** Always, first thing after root check.

```bash
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop)
            PKG_INSTALL="apt-get install -y"
            PKG_UPDATE="apt-get update -qq"
            OS_FAMILY="debian"
            ;;
        centos|rhel|almalinux|rocky)
            PKG_INSTALL="yum install -y"
            PKG_UPDATE=""
            OS_FAMILY="rhel"
            ;;
        fedora)
            PKG_INSTALL="dnf install -y"
            OS_FAMILY="fedora"
            ;;
        arch|manjaro|endeavouros)
            PKG_INSTALL="pacman -S --noconfirm"
            PKG_UPDATE="pacman -Sy"
            OS_FAMILY="arch"
            ;;
        *)
            # Fallback: check ID_LIKE
            case "$OS_LIKE" in
                *debian*) PKG_INSTALL="apt-get install -y" ; OS_FAMILY="debian" ;;
                *rhel*)   PKG_INSTALL="yum install -y" ; OS_FAMILY="rhel" ;;
                *) die "Unsupported OS: $OS_ID" ;;
            esac
            ;;
    esac
}
```

### Pattern 2: GitHub Releases API for Latest Version

**What:** Query GitHub API, extract tag_name, construct download URL.

**When:** Binary download for chisel and wstunnel.

```bash
fetch_latest_chisel_version() {
    curl -fsSL "https://api.github.com/repos/jpillora/chisel/releases/latest" \
      | grep -o '"tag_name": "[^"]*"' \
      | grep -o 'v[0-9.]*'
}

download_chisel() {
    local ver arch url
    ver=$(fetch_latest_chisel_version)
    arch=$(detect_arch)
    # chisel uses .gz for linux
    url="https://github.com/jpillora/chisel/releases/download/${ver}/chisel_${ver#v}_linux_${arch}.gz"
    curl -fLo /tmp/chisel.gz "$url"
    gunzip -f /tmp/chisel.gz
    chmod +x /tmp/chisel
    mv /tmp/chisel /usr/local/bin/chisel
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm7" ;;
        i386|i686) echo "386" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}
```

### Pattern 3: Heredoc for Config File Generation

**What:** Use heredoc with variable interpolation for nginx and systemd configs.

**When:** All config file writing — avoids escaping hell of echo chains.

```bash
write_nginx_conf() {
    cat > /etc/nginx/sites-available/proxyebator << EOF
server {
    listen ${NGINX_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location /${SECRET_PATH}/ {
        proxy_pass http://127.0.0.1:${TUNNEL_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        $(masquerade_location_block)
    }
}
EOF
    ln -sf /etc/nginx/sites-available/proxyebator \
           /etc/nginx/sites-enabled/proxyebator
}
```

Note: `\$http_upgrade` — nginx variables must be escaped inside bash heredoc.

### Pattern 4: Verification with Diagnostic Output

**What:** Each verification step reports pass/fail explicitly. No silent failures.

**When:** After every major installation step.

```bash
verify_tunnel_bound_locally() {
    local port="$1"
    if ss -tlnp | grep -q "127.0.0.1:${port}"; then
        log_ok "Tunnel port ${port} bound to 127.0.0.1 (not exposed externally)"
    else
        log_warn "Tunnel port ${port} not found on 127.0.0.1 — check service status"
        ss -tlnp | grep "${port}" || true
    fi
}
```

### Pattern 5: Mode Dispatcher at Script Bottom

**What:** Main logic at the bottom, all functions defined above it.

**When:** Always — bash requires functions declared before call.

```bash
# --- ENTRY POINT ---
MODE="${1:-}"
case "$MODE" in
    server)    server_main ;;
    client)    client_main ;;
    uninstall) uninstall_main ;;
    "")        usage; exit 1 ;;
    *)         die "Unknown mode: $MODE. Use: server | client | uninstall" ;;
esac
```

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Chisel Port as Combined Argument

**What:** `-p 127.0.0.1:7777` as single flag to chisel server.

**Why bad:** Chisel does not accept this format. Service fails silently at start, status=1.

**Instead:** Always split: `--host 127.0.0.1 -p 7777` as separate flags.

### Anti-Pattern 2: Missing Trailing Slash in nginx proxy_pass

**What:** `proxy_pass http://127.0.0.1:7777;` (no trailing slash).

**Why bad:** nginx does not strip the location prefix. Chisel/wstunnel receive `/SECRET_PATH/` instead of `/`. WebSocket handshake fails with 404.

**Instead:** Always `proxy_pass http://127.0.0.1:7777/;` with trailing slash.

### Anti-Pattern 3: Missing proxy_buffering off

**What:** Omitting `proxy_buffering off;` in nginx WebSocket location.

**Why bad:** nginx buffers the WebSocket stream. Chisel "Connected" but curl hangs — data never flows.

**Instead:** Always include `proxy_buffering off;` in every WebSocket location block.

### Anti-Pattern 4: Auth Token in systemd ExecStart

**What:** `ExecStart=/usr/local/bin/chisel server --auth user:password`.

**Why bad:** Token visible in `ps aux` to any local user. Also visible in `systemctl status` output.

**Instead:** Use `--authfile /etc/chisel/auth.json` with `chmod 600`. File format: `{"user:pass": [".*:.*"]}`.

### Anti-Pattern 5: wstunnel --restrict-http-upgrade-path-prefix with nginx

**What:** Adding `--restrict-http-upgrade-path-prefix /SECRET_PATH` to wstunnel server ExecStart when behind nginx.

**Why bad:** nginx strips the prefix before proxying (because of trailing slash in proxy_pass), so wstunnel receives `/`. The restriction never matches → every connection gets 404.

**Instead:** Let nginx enforce the secret path. wstunnel listens on `ws://127.0.0.1:8888` without path restrictions.

### Anti-Pattern 6: Using --reverse in Chisel for SOCKS5

**What:** Adding `--reverse` flag to chisel server.

**Why bad:** Expands attack surface. Required only for reverse tunnels, not for SOCKS5 proxy use case.

**Instead:** No `--reverse` flag. `--socks5` on server side is sufficient.

### Anti-Pattern 7: Monolithic install() Function

**What:** One massive function that does OS detection + download + config + service.

**Why bad:** Cannot test individual components. Cannot retry failed steps. Cannot support uninstall that mirrors install structure.

**Instead:** Granular functions, each doing one thing. Mode functions call them in order.

---

## Nginx Config: Masquerade Modes

Three masquerade modes affect only the `location /` block:

| Mode | nginx Config | When to Use |
|------|-------------|-------------|
| `stub` | `return 200 "OK";` with minimal HTML | No real site, just placeholder |
| `proxy-url` | `proxy_pass $COVER_URL;` with `proxy_set_header Host ...` | Mirror an external site |
| `static-path` | `root $STATIC_PATH; index index.html;` | Serve user's own static files |

The WS location block (`/$SECRET_PATH/`) is identical across all three modes.

---

## Systemd: Server vs Client Unit Differences

| Aspect | Server Unit (`/etc/systemd/system/`) | Client Unit (`~/.config/systemd/user/`) |
|--------|--------------------------------------|------------------------------------------|
| Scope | System-wide | Per-user |
| Requires root | Yes | No |
| User directive | `User=nobody` | Not needed (runs as current user) |
| After | `After=network.target` | `After=network-online.target` |
| Enable command | `systemctl enable --now` | `systemctl --user enable --now` |
| Start on boot | Yes | Yes (on user login) |

---

## Build Order (What Depends on What)

```
Phase 1: Foundation (no dependencies)
  detect_os()
  detect_arch()
  gen_secret_path()
  gen_auth_token()
  utility functions: log(), die(), confirm(), check_root()

Phase 2: User Choices (depends on Phase 1)
  prompt_tunnel_type()      → sets $TUNNEL_TYPE
  prompt_domain()           → sets $DOMAIN
  prompt_masquerade_mode()  → sets $MASQUERADE_MODE, $COVER_URL/$STATIC_PATH

Phase 3: System Preparation (depends on Phase 1+2)
  install_deps()            → depends on $PKG_INSTALL from detect_os()
  download_binary()         → depends on $TUNNEL_TYPE, $ARCH

Phase 4: TLS (depends on Phase 3 — nginx must be installed)
  run_certbot()             → depends on $DOMAIN, nginx present

Phase 5: Config Generation (depends on Phase 2+4 — needs $DOMAIN, $SECRET_PATH, cert path)
  write_auth_json()         → depends on $AUTH_USER, $AUTH_TOKEN
  write_nginx_conf()        → depends on $DOMAIN, $SECRET_PATH, $TUNNEL_PORT, $NGINX_PORT
  write_systemd_unit()      → depends on $TUNNEL_TYPE binary path, $TUNNEL_PORT

Phase 6: Service Activation (depends on Phase 5 — configs must exist)
  enable_nginx_site()       → symlink + nginx -t + reload
  enable_tunnel_service()   → daemon-reload + enable + start

Phase 7: Verification (depends on Phase 6 — services must be running)
  verify_service_active()
  verify_port_localhost()
  verify_nginx_cover_site()

Phase 8: Output (depends on Phase 2+5 — needs all config vars)
  print_connection_params()
```

Critical dependency: **TLS before nginx config writing** — certbot modifies the nginx config or requires the server block to exist. Strategy: write nginx config first with HTTP-only, run certbot with `--nginx` (it adds SSL directives), then reload.

---

## Scalability Considerations

This is a single-user/single-server deployment tool. Scalability concerns are:

| Concern | At 1 server (MVP) | At 10 servers | At 100 servers |
|---------|-------------------|---------------|----------------|
| Config management | Vars in script state file | Still fine | Need separate config dir or Ansible |
| Multi-user per server | Single auth token | Multi-entry auth.json manually | Needs user management subcommand |
| Binary updates | Re-run script | Re-run script per server | Wrapper loop or Ansible |
| Secret rotation | Uninstall + reinstall | Same | Same |

**Conclusion:** The script architecture is correct for its scope (single server). Adding a `rotate` mode for secret/token rotation would be a natural extension without architectural changes.

---

## Sources

- `/home/kosya/vibecoding/proxyebator/tunnel-reference.md` — Validated real-world Chisel and wstunnel deployment patterns (HIGH confidence, battle-tested)
- `/home/kosya/vibecoding/proxyebator/PROXY-GUIDE.md` — Full architecture reference with threat model and gotchas (HIGH confidence)
- `/home/kosya/vibecoding/proxyebator/.planning/PROJECT.md` — Authoritative project requirements and constraints (HIGH confidence)
- Community bash script patterns from openvpn-install.sh, angristan/wireguard-install — multi-distro single-script deployment reference model (MEDIUM confidence — pattern well-established)
