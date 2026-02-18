# Phase 02: Server Core - Research

**Researched:** 2026-02-18
**Domain:** Bash server setup — Chisel binary install, nginx WebSocket proxy, certbot TLS, systemd service, ufw/iptables firewall, interactive question flow
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Interactive flow:**
- Step-by-step with visible progress: ask domain → install deps → ask tunnel → download binary → ask masquerade → configure nginx → etc.
- Summary before installation: "Domain: X, Tunnel: Y, Masquerade: Z. Continue? [y/N]"
- Non-interactive mode via CLI flags from Phase 1 (`--domain`, `--tunnel`, `--port`, `--masquerade`) skips all prompts and summary

**Domain validation:**
- Format check + DNS A-record check: domain must resolve to the current server's IP
- Domain is mandatory — IP-only mode not supported
- Cloudflare orange cloud detection: if domain resolves to a CF IP, warn that WebSocket may timeout

**Masquerade modes (three, nginx always used):**
- **stub** — minimal HTML page, looks like a new site ("Welcome", little text)
- **proxy** — user enters a URL, nginx reverse-proxies it to `/`
- **static** — user provides local folder path, nginx serves it as root

**Tunnel and port:**
- Chisel only in Phase 2 (wstunnel is Phase 6)
- Chisel internal port: fixed 7777, bound to 127.0.0.1
- External port: auto-detect — if 443 is occupied show who, offer 2087/8443/custom

**Firewall:**
- ufw priority; iptables fallback if ufw not installed
- Open 80 and 443 (or alternate port); block tunnel port from external access

**Existing infrastructure:**
- If nginx already has a server block for the domain — inject WebSocket location block, leave the rest alone
- If TLS cert already exists (Let's Encrypt or other) — reuse it, don't call certbot again

### Claude's Discretion

- Exact install sequence within each step
- How to detect existing nginx config and TLS certificate
- Format of the pre-install summary
- How to detect if Cloudflare is proxying the domain
- Size and content of the stub HTML page

### Deferred Ideas (OUT OF SCOPE)

- wstunnel as real alternative — Phase 6
- Cloudflare CDN routing (domain fronting) — v2 (CDN-01)
- Binary auto-update — v2 (UPD-01)
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SCRIPT-06 | Dependency check and auto-install (curl, jq, openssl, nginx, certbot) | `apt-get install` pattern with per-package idempotent checks; `command -v` or `dpkg -l` before installing |
| TUNNEL-01 | Choose backend at install: Chisel or wstunnel | Phase 2 installs Chisel only; `TUNNEL_TYPE` from CLI flag or interactive prompt |
| TUNNEL-02 | Download binary from GitHub releases (latest) with auto OS/arch detection | GitHub API `releases/latest` + `grep` version parsing; `.gz` for Chisel, `.tar.gz` for wstunnel; arch from `$ARCH` var already set by Phase 1 |
| TUNNEL-03 | Chisel: start server with separate `--host 127.0.0.1` and `-p PORT`, SOCKS5 via `--socks5` | systemd ExecStart documented; `--host` and `-p` MUST be separate tokens — Chisel ignores host part of `-p 127.0.0.1:7777` |
| TUNNEL-05 | Generate random secret WS path (16+ chars) at install time | `gen_secret_path()` from Phase 1 (already exists); path stored in `/etc/proxyebator/server.conf` |
| TUNNEL-06 | Generate random password/token for authentication | `gen_auth_token()` from Phase 1 (already exists); stored in `/etc/chisel/auth.json` with `chmod 600` |
| MASK-01 | Two masquerade modes: reverse proxy with cover site, or HTTPS-only | Context decision: nginx always used; three sub-modes (stub/proxy/static); MASK-06 is removed |
| MASK-02 | nginx reverse proxy: real content at `/`, WebSocket on secret path | Location block template with all mandatory directives |
| MASK-03 | Mandatory `proxy_buffering off` and trailing slash in `proxy_pass` | Non-negotiable; missing either causes silent tunnel failure |
| MASK-04 | Cover site on choice: built-in stub, proxy external URL, or own static folder | Three nginx template variants documented |
| MASK-05 | Auto-obtain TLS cert via certbot when domain is available | `certbot certonly --nginx -d DOMAIN` approach; cert existence check before calling certbot |
| MASK-06 | HTTPS-only mode without nginx (REMOVED by context decision) | Nginx is always used — this requirement is superseded |
| SRV-01 | Create systemd unit file for tunnel with autostart and restart on crash | `chisel.service` template; `User=nobody`, `Restart=always`, `RestartSec=5` |
| SRV-02 | Auto-configure firewall (ufw/iptables): open 80/443, block tunnel port | ufw detection via `command -v ufw`; fallback to iptables; idempotent rule application |
| SRV-03 | Save config to `/etc/proxyebator/server.conf` | Key=value format; used by uninstall (Phase 5) and status |
| SRV-04 | Verify tunnel port listens on 127.0.0.1, not 0.0.0.0 | `ss -tlnp \| grep 7777` — must show `127.0.0.1:7777`; fail loudly if wrong |
</phase_requirements>

---

## Summary

Phase 2 is the bulk of server-side work. It wires together five distinct subsystems: dependency installation, Chisel binary download, nginx configuration (with the correct WebSocket proxy template), certbot TLS acquisition, and systemd service management — all orchestrated by an interactive question flow with a pre-install summary.

The most important finding from the reference material is that every subsystem has one or two non-negotiable "gotcha" points that silently break the tunnel without obvious error messages. The trailing slash in `proxy_pass`, the `proxy_buffering off` directive, and the separation of `--host` and `-p` as distinct flags are all production-validated pitfalls that must be hardcoded into the templates. The script must never offer these as configurable options — they are always correct and always required.

The interactive flow should follow a "collect then act" pattern: ask all questions (domain, masquerade mode, port), show the summary, wait for confirmation, then execute each step with visible progress. This approach allows the non-interactive mode to trivially bypass all questions by checking for non-empty CLI variables before prompting. Existing infrastructure detection (nginx config for domain, existing TLS cert) must happen in the pre-execution phase so it can be reflected in the summary.

**Primary recommendation:** Write `server_main()` in proxyebator.sh as a linear sequence of function calls — `server_collect_params()` → `server_show_summary()` → `server_install_deps()` → `server_download_chisel()` → `server_setup_auth()` → `server_configure_nginx()` → `server_obtain_tls()` → `server_create_systemd()` → `server_configure_firewall()` → `server_save_config()` → `server_verify()`. Each function is independently testable and the failure of any one stops the script cleanly via `die()`.

---

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Chisel | v1.11.3 (confirmed live via GitHub API 2026-02-18) | SSH-over-WebSocket tunnel with SOCKS5 and authfile | Built-in auth, SOCKS5 first-class, widely deployed, documented in project reference |
| nginx | system package (1.18+ Ubuntu 22.04, 1.22+ Debian 12) | TLS termination, WebSocket proxy, cover site | Required for masking; handles WebSocket upgrade + TLS without extra config |
| certbot | system snap or apt package | Auto-obtain Let's Encrypt TLS certificate | Free, auto-renews via systemd timer; Let's Encrypt required (CF Origin certs fail with direct WebSocket) |
| systemd | system | Process supervision for Chisel | Already on all target distros; handles restart, unprivileged user |

### Supporting (no install)

| Tool | Purpose | Notes |
|------|---------|-------|
| `ss` (iproute2) | Verify tunnel port binding | Always on Debian/Ubuntu; used for `ss -tlnp \| grep 7777` |
| `openssl` | Secret path and token generation (from Phase 1) | Already established |
| `curl` | GitHub API version detection + binary download | Must be installed in SCRIPT-06 step |
| `ufw` | Firewall management (primary) | May not be installed; check before use |
| `iptables` | Firewall management (fallback) | Always available on Linux |

### Package Names Per Distro (SCRIPT-06)

| Package | Debian/Ubuntu (`apt-get`) | Notes |
|---------|---------------------------|-------|
| curl | `curl` | Usually pre-installed |
| openssl | `openssl` | Usually pre-installed |
| nginx | `nginx` | Standard |
| certbot | `certbot python3-certbot-nginx` | apt approach; OR `snap install --classic certbot` |
| jq | `jq` | For JSON parsing (GitHub API fallback) |

**Confidence:** HIGH — confirmed from project reference; Phase 2 targets Debian/Ubuntu only (per STACK.md and project requirements).

---

## Architecture Patterns

### Recommended server_main() Structure

```
server_main()
├── check_root()                     (already in Phase 1)
├── detect_os()                      (already in Phase 1)
├── detect_arch()                    (already in Phase 1)
├── server_collect_params()          (interactive or from CLI flags)
│   ├── prompt_domain()              (or use $DOMAIN if set)
│   ├── validate_domain()            (format + DNS A-record check + CF detection)
│   ├── prompt_masquerade_mode()     (or use $MASQUERADE_MODE)
│   └── detect_listen_port()         (auto-detect 443; offer fallback if occupied)
├── server_show_summary()            (print all params; ask [y/N]; skip if non-interactive)
├── server_install_deps()            (curl, openssl, nginx, certbot)
├── server_download_chisel()         (GitHub API latest; verify binary)
├── server_setup_auth()              (generate or use existing creds; write auth.json)
├── server_configure_nginx()         (detect existing config; write location block)
├── server_obtain_tls()              (check cert exists; call certbot if not)
├── server_create_systemd()          (write chisel.service; daemon-reload; enable --now)
├── server_configure_firewall()      (ufw or iptables; open 80/LISTEN_PORT; block 7777)
├── server_save_config()             (write /etc/proxyebator/server.conf)
└── server_verify()                  (ss check; systemctl status; curl decoy; print connection info)
```

### Pattern 1: Interactive Parameter Collection with Non-Interactive Bypass

**What:** Check CLI variable first, prompt only if empty
**When to use:** Every interactive prompt in server_main

```bash
# Source: Phase 1 established DOMAIN, TUNNEL_TYPE, LISTEN_PORT, MASQUERADE_MODE globals
prompt_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        log_info "Using domain from CLI flag: $DOMAIN"
        return
    fi
    printf "${CYAN}[STEP]${NC} Enter your domain name (e.g. example.com): "
    read -r DOMAIN
    [[ -n "$DOMAIN" ]] || die "Domain is required"
}
```

**Why this pattern:** Phase 1 already sets up the CLI flags as global variables. The prompt functions just check them first. Zero special-casing needed for non-interactive mode — the variables are either set (skip prompt) or empty (prompt).

**Confidence:** HIGH — follows established Phase 1 pattern.

### Pattern 2: Domain Validation — Format + DNS + CF Detection

**What:** Validate domain format, confirm DNS A-record matches server IP, warn if CF IP
**When to use:** After collecting domain, before anything is installed

```bash
validate_domain() {
    # Format check — basic sanity
    if ! printf '%s' "$DOMAIN" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        die "Invalid domain format: $DOMAIN"
    fi

    # Get server's own public IP (two fallbacks)
    local server_ip
    server_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
              || curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
              || die "Could not detect server public IP")

    # Resolve domain A-record via DNS-over-HTTPS (no dig/host needed)
    local domain_ip
    domain_ip=$(curl -sf --max-time 10 \
        "https://dns.google/resolve?name=${DOMAIN}&type=A" 2>/dev/null \
        | grep -o '"data":"[^"]*"' | head -1 | grep -o '[0-9.]*')

    if [[ -z "$domain_ip" ]]; then
        die "Could not resolve domain $DOMAIN — check DNS A-record is set"
    fi

    # Cloudflare detection: CF published IPv4 ranges
    # Key CF CIDR blocks (from https://www.cloudflare.com/ips-v4/):
    # 103.21.244.0/22, 103.22.200.0/22, 103.31.4.0/22, 104.16.0.0/13, 104.24.0.0/14
    # 108.162.192.0/18, 141.101.64.0/18, 162.158.0.0/15, 172.64.0.0/13
    # 173.245.48.0/20, 188.114.96.0/20, 190.93.240.0/20, 197.234.240.0/22, 198.41.128.0/17
    # Quick check: first octet 104 or 172 (most CF), or known CF ranges
    local first_octet
    first_octet=$(printf '%s' "$domain_ip" | cut -d. -f1)
    if [[ "$first_octet" =~ ^(103|104|108|141|162|172|173|188|190|197|198)$ ]]; then
        log_warn "WARNING: $DOMAIN resolves to $domain_ip which appears to be a Cloudflare IP"
        log_warn "Cloudflare CDN (orange cloud) may drop WebSocket connections after ~100 seconds"
        log_warn "For stable operation, set DNS to 'grey cloud' (DNS only, not proxied)"
        # Do not abort — let user proceed with warning
    fi

    if [[ "$domain_ip" != "$server_ip" ]]; then
        die "Domain $DOMAIN resolves to $domain_ip but server IP is $server_ip. Update A-record first."
    fi

    log_info "Domain $DOMAIN resolves to $server_ip — OK"
}
```

**CF detection notes:**
- Using first-octet heuristic covers most CF IPs; not a CIDR match but good enough for a warning
- Proper CIDR matching requires bitwise arithmetic in bash which is complex and error-prone; heuristic is sufficient for a warning (not a hard block)
- DNS-over-HTTPS to `dns.google` works without `dig`/`host` (uses `curl` which is always installed)

**Confidence:** MEDIUM — the `dig`-free approach (curl to dns.google) is verified to work. The CF IP heuristic is simplified but adequate for a warning.

### Pattern 3: Port Conflict Detection and Fallback

**What:** Check if 443 is in use; if yes, show who is using it and propose alternatives
**When to use:** During param collection phase

```bash
detect_listen_port() {
    if [[ -n "${LISTEN_PORT:-}" ]]; then
        log_info "Using port from CLI flag: $LISTEN_PORT"
        return
    fi

    if ss -tlnp | grep -q ':443 '; then
        local occupant
        occupant=$(ss -tlnp | grep ':443 ' | grep -o 'users:(([^)]*))' | head -1 || echo "unknown process")
        log_warn "Port 443 is occupied by: $occupant"
        log_warn "Alternative HTTPS ports (Cloudflare-compatible): 2087, 8443"
        printf "${CYAN}[STEP]${NC} Enter alternate port [2087]: "
        read -r LISTEN_PORT
        LISTEN_PORT="${LISTEN_PORT:-2087}"
    else
        LISTEN_PORT="443"
        log_info "Port 443 is available — will use it"
    fi
}
```

**Confidence:** HIGH — `ss -tlnp | grep ':443 '` is standard; well-established pattern.

### Pattern 4: Chisel Binary Download (verified format)

**What:** Download latest Chisel from GitHub, handle version detection and gz format
**When to use:** After dependency installation

```bash
server_download_chisel() {
    # Fallback version in case GitHub API is rate-limited (60 req/hr unauthenticated)
    local CHISEL_FALLBACK_VER="v1.11.3"

    log_info "Fetching Chisel latest version..."
    local CHISEL_VER
    CHISEL_VER=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/jpillora/chisel/releases/latest" \
        | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*' \
        || echo "$CHISEL_FALLBACK_VER")

    if [[ -z "$CHISEL_VER" ]]; then
        log_warn "Could not detect Chisel version, using fallback: $CHISEL_FALLBACK_VER"
        CHISEL_VER="$CHISEL_FALLBACK_VER"
    fi

    log_info "Downloading Chisel ${CHISEL_VER} for linux/${ARCH}..."
    # Asset format confirmed: chisel_{version_without_v}_linux_{arch}.gz
    local download_url="https://github.com/jpillora/chisel/releases/download/${CHISEL_VER}/chisel_${CHISEL_VER#v}_linux_${ARCH}.gz"

    curl -fLo /tmp/chisel.gz "$download_url" \
        || die "Failed to download Chisel from $download_url"

    gunzip -f /tmp/chisel.gz
    chmod +x /tmp/chisel
    mv /tmp/chisel /usr/local/bin/chisel

    # Verify
    /usr/local/bin/chisel --version \
        || die "Chisel binary not working after install"
    log_info "Chisel installed: $(/usr/local/bin/chisel --version 2>&1 | head -1)"
}
```

**Verified:** Chisel v1.11.3 is current as of 2026-02-18 (live GitHub API check). Asset naming is `chisel_1.11.3_linux_amd64.gz` (confirmed). Gzip single file, no tar required.

**Confidence:** HIGH — verified against live GitHub API.

### Pattern 5: Auth File Setup

**What:** Generate credentials; write auth.json with correct format and permissions
**When to use:** After Chisel download, before nginx/systemd setup

```bash
server_setup_auth() {
    mkdir -p /etc/chisel
    mkdir -p /etc/proxyebator

    # Generate secrets using Phase 1 functions (already available)
    local secret_path auth_token auth_user
    secret_path="$(gen_secret_path)"
    auth_token="$(gen_auth_token)"
    auth_user="proxyebator"

    # Write auth file — MUST use file not --auth flag (--auth visible in ps aux)
    # Value [".*:.*"] = allow all remotes. [""] is known to NOT work.
    cat > /etc/chisel/auth.json << EOF
{
  "${auth_user}:${auth_token}": [".*:.*"]
}
EOF
    chmod 600 /etc/chisel/auth.json
    chown nobody:nogroup /etc/chisel/auth.json

    # Export for use by other functions
    SECRET_PATH="$secret_path"
    AUTH_USER="$auth_user"
    AUTH_TOKEN="$auth_token"
}
```

**Critical:** Auth user:password format in JSON key. `[".*:.*"]` allows all remotes. `[""]` does not work. `chmod 600` is mandatory. `chown nobody:nogroup` matches the systemd `User=nobody` service.

**Confidence:** HIGH — documented in project reference from production deployment.

### Pattern 6: Nginx Configuration — Three Masquerade Modes

**What:** Write nginx server block with WebSocket location plus masquerade mode
**When to use:** After TLS cert is obtained

The nginx config is written to `/etc/nginx/sites-available/proxyebator-DOMAIN.conf` and symlinked to `sites-enabled`. For existing config detection, the script searches for server_name matching $DOMAIN.

**Template — Full server block (new config):**

```nginx
# /etc/nginx/sites-available/proxyebator-DOMAIN.conf
server {
    listen 80;
    server_name DOMAIN;
    return 301 https://$host$request_uri;
}

server {
    listen LISTEN_PORT ssl http2;
    server_name DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # WebSocket tunnel — MUST be before location /
    # proxyebator-tunnel-block-start
    location /SECRET_PATH/ {
        proxy_pass http://127.0.0.1:7777/;   # trailing slash MANDATORY
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;                  # MANDATORY — without this no data flows
    }
    # proxyebator-tunnel-block-end

    # Cover site content — varies by masquerade mode:
    #   stub:   return inline HTML
    #   proxy:  proxy_pass to PROXY_URL
    #   static: root /path/to/static
    MASQUERADE_BLOCK
}
```

**Masquerade blocks:**

```nginx
# stub mode — minimal HTML, looks like new/empty site
location / {
    return 200 '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome</h1><p>This site is under construction.</p></body></html>';
    add_header Content-Type text/html;
}

# proxy mode — nginx proxies an external URL
location / {
    proxy_pass PROXY_URL;
    proxy_set_header Host PROXY_HOST;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_ssl_server_name on;
}

# static mode — serve local files
root /PATH/TO/STATIC;
location / {
    try_files $uri $uri/ =404;
}
```

**Existing config detection:**

```bash
detect_existing_nginx() {
    # Check if any existing nginx config references our domain
    local existing
    existing=$(grep -rl "server_name.*${DOMAIN}" /etc/nginx/ 2>/dev/null | head -1 || true)
    if [[ -n "$existing" ]]; then
        NGINX_EXISTING_CONF="$existing"
        log_warn "Found existing nginx config for $DOMAIN: $existing"
        log_warn "Will inject WebSocket location block only (leaving rest intact)"
    else
        NGINX_EXISTING_CONF=""
    fi
}

inject_into_existing_nginx() {
    # Check if already injected (idempotent)
    if grep -q "# proxyebator-tunnel-block-start" "$NGINX_EXISTING_CONF"; then
        log_info "WebSocket block already present in $NGINX_EXISTING_CONF — skipping"
        return
    fi
    # Inject before first 'location /' in the server block
    # Uses sed to insert before first location / line
    local tunnel_block
    tunnel_block=$(generate_tunnel_location_block)
    # Write to temp file, then use sed to insert at the right place
    local tmpconf
    tmpconf=$(mktemp)
    sed "/location \// { /# proxyebator-tunnel-block-start/! { 0,/location \// { /location \// i\\${tunnel_block}
} } }" "$NGINX_EXISTING_CONF" > "$tmpconf"
    mv "$tmpconf" "$NGINX_EXISTING_CONF"
}
```

**Simpler injection approach (recommended):** Use nginx `include` directive. Add `include /etc/nginx/proxyebator.d/*.conf;` to the existing server block, then write the location block to `/etc/nginx/proxyebator.d/tunnel.conf`. Idempotent — just overwrite the file. Requires checking if `include proxyebator.d` is already present in the existing config.

**Confidence:** HIGH — nginx config format from project reference (production-validated). Masquerade mode templates are straightforward nginx.

### Pattern 7: Certbot TLS Acquisition

**What:** Check cert existence, obtain if needed, enable renewal timer
**When to use:** After nginx config is written (nginx plugin needs nginx running)

```bash
server_obtain_tls() {
    local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

    # Check if valid cert already exists — CRITICAL to avoid rate limit (5 certs/domain/week)
    if [[ -f "$cert_path" ]]; then
        log_info "TLS certificate already exists for $DOMAIN — reusing"
        return
    fi

    # Ensure port 80 is open for certbot ACME challenge
    log_info "Obtaining TLS certificate for $DOMAIN via Let's Encrypt..."

    # Use --nginx plugin: handles webroot setup automatically
    # --non-interactive: no prompts
    # --agree-tos: accept LE ToS
    # -m: contact email (use proxyebator@DOMAIN as placeholder or prompt)
    certbot certonly \
        --nginx \
        --non-interactive \
        --agree-tos \
        --email "admin@${DOMAIN}" \
        -d "$DOMAIN" \
        || die "certbot failed to obtain TLS certificate for $DOMAIN. Check DNS and port 80."

    # Ensure renewal timer is active
    # snap certbot uses snap.certbot.renew.timer; apt certbot uses certbot.timer
    if systemctl list-units --type=timer 2>/dev/null | grep -q "snap.certbot"; then
        systemctl enable --now snap.certbot.renew.timer 2>/dev/null || true
    else
        systemctl enable --now certbot.timer 2>/dev/null || true
    fi

    # Dry-run renewal test to confirm setup
    certbot renew --dry-run --quiet 2>/dev/null \
        && log_info "Certbot renewal dry-run: OK" \
        || log_warn "Certbot renewal dry-run failed — check certbot configuration"
}
```

**Cert existence check for other CAs:** If the cert is not at the certbot path, check nginx config for `ssl_certificate` directive:

```bash
check_existing_cert() {
    local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    if [[ -f "$cert_path" ]]; then
        CERT_PATH="$cert_path"
        CERT_KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        log_info "Found Let's Encrypt cert: $cert_path"
        return 0
    fi
    # Check if existing nginx config already has ssl_certificate for domain
    if [[ -n "${NGINX_EXISTING_CONF:-}" ]]; then
        local existing_cert
        existing_cert=$(grep -o 'ssl_certificate [^;]*' "$NGINX_EXISTING_CONF" | awk '{print $2}' | head -1)
        if [[ -n "$existing_cert" && -f "$existing_cert" ]]; then
            CERT_PATH="$existing_cert"
            CERT_KEY_PATH=$(grep -o 'ssl_certificate_key [^;]*' "$NGINX_EXISTING_CONF" | awk '{print $2}' | head -1)
            log_info "Found existing TLS cert: $existing_cert — reusing"
            return 0
        fi
    fi
    return 1  # No cert found; proceed to certbot
}
```

**Confidence:** HIGH — certbot `certonly --nginx` is the standard approach; cert existence check at standard Let's Encrypt path is verified.

### Pattern 8: Systemd Unit for Chisel

**What:** Write chisel.service; daemon-reload; enable and start
**When to use:** After nginx configuration and TLS setup

```ini
# /etc/systemd/system/chisel.service
[Unit]
Description=Chisel Tunnel Server (proxyebator)
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
Group=nogroup

[Install]
WantedBy=multi-user.target
```

**Critical flags:**
- `--host 127.0.0.1` and `-p 7777` are SEPARATE arguments. Chisel does NOT accept `-p 127.0.0.1:7777`
- `--socks5` is required — enables SOCKS5 on the tunnel
- `--reverse` is NOT included — not needed for SOCKS5, increases attack surface
- `User=nobody Group=nogroup` — always run unprivileged; authfile must be `chown nobody:nogroup`
- Do NOT use `DynamicUser=yes` — changes UID on restarts, breaks authfile ownership

```bash
server_create_systemd() {
    cat > /etc/systemd/system/chisel.service << EOF
[Unit]
Description=Chisel Tunnel Server (proxyebator)
After=network.target

[Service]
ExecStart=/usr/local/bin/chisel server \\
  --host 127.0.0.1 \\
  -p 7777 \\
  --authfile /etc/chisel/auth.json \\
  --socks5
Restart=always
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now chisel \
        || die "Failed to start chisel.service"

    log_info "Chisel systemd service: $(systemctl is-active chisel)"
}
```

**Confidence:** HIGH — verified template from project reference (production deployment).

### Pattern 9: Firewall Configuration (ufw/iptables)

**What:** Detect ufw or iptables; open HTTP/HTTPS; block tunnel port from external
**When to use:** After service is running

```bash
server_configure_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        # ufw is active — use it
        log_info "Configuring firewall via ufw..."
        ufw allow 80/tcp   comment "proxyebator HTTP" 2>/dev/null || true
        ufw allow "${LISTEN_PORT}/tcp" comment "proxyebator HTTPS" 2>/dev/null || true
        # Tunnel port 7777 is on 127.0.0.1 so ufw won't see external traffic to it
        # But explicitly deny in case of misconfiguration:
        ufw deny 7777/tcp  comment "proxyebator tunnel internal" 2>/dev/null || true
        ufw status verbose | grep -E "7777|80|${LISTEN_PORT}" | while read -r line; do
            log_info "UFW: $line"
        done
    elif command -v ufw &>/dev/null; then
        # ufw installed but not active — install-and-enable approach is risky
        # (could lock out SSH). Just use iptables instead.
        log_warn "ufw installed but not active — using iptables"
        _configure_iptables
    else
        log_info "ufw not found — configuring firewall via iptables..."
        _configure_iptables
    fi
}

_configure_iptables() {
    # Idempotent: check before adding rules
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT
    # Drop external access to tunnel port (bound to 127.0.0.1, so this is a safety measure)
    iptables -C INPUT -p tcp --dport 7777 ! -i lo -j DROP 2>/dev/null \
        || iptables -A INPUT -p tcp --dport 7777 ! -i lo -j DROP
    log_info "iptables rules added for ports 80, ${LISTEN_PORT}"
}
```

**Note on ufw activation:** The script must NOT run `ufw enable` if ufw is inactive — this could disrupt SSH. If ufw is not active, fall through to iptables. Document this in the summary output.

**Confidence:** HIGH — ufw/iptables pattern is standard; check before add is the idempotent approach.

### Pattern 10: Configuration File

**What:** Save all parameters to `/etc/proxyebator/server.conf` for uninstall/status
**When to use:** After everything is set up successfully

```bash
server_save_config() {
    mkdir -p /etc/proxyebator
    cat > /etc/proxyebator/server.conf << EOF
# proxyebator server configuration
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
DOMAIN=${DOMAIN}
LISTEN_PORT=${LISTEN_PORT}
SECRET_PATH=${SECRET_PATH}
TUNNEL_TYPE=chisel
TUNNEL_PORT=7777
MASQUERADE_MODE=${MASQUERADE_MODE}
AUTH_USER=${AUTH_USER}
AUTH_TOKEN=${AUTH_TOKEN}
NGINX_CONF=${NGINX_CONF_PATH}
CERT_PATH=${CERT_PATH}
EOF
    chmod 600 /etc/proxyebator/server.conf
    log_info "Config saved: /etc/proxyebator/server.conf"
}
```

**Confidence:** HIGH — simple key=value format; standard pattern for installer scripts.

### Pattern 11: Pre-install Summary

**What:** Print collected params; ask for [y/N] confirmation
**When to use:** After all params collected, before any installation begins

```bash
server_show_summary() {
    # In non-interactive mode (all CLI flags set), skip summary
    if [[ -n "${DOMAIN:-}" && -n "${MASQUERADE_MODE:-}" ]]; then
        local all_from_cli=true
        # If all critical params came from CLI, skip summary unless explicitly --confirm
        # (simple heuristic: if DOMAIN was set via CLI, assume non-interactive)
        log_info "Non-interactive mode: proceeding without confirmation"
        return
    fi

    printf "\n${BOLD}=== Installation Summary ===${NC}\n"
    printf "  Domain:       %s\n" "$DOMAIN"
    printf "  Listen port:  %s\n" "$LISTEN_PORT"
    printf "  Tunnel:       Chisel (port 7777 → 127.0.0.1)\n"
    printf "  Secret path:  /%s/\n" "$SECRET_PATH"
    printf "  Masquerade:   %s\n" "$MASQUERADE_MODE"
    if [[ "$MASQUERADE_MODE" == "proxy" ]]; then
        printf "  Proxy URL:    %s\n" "${PROXY_URL:-<not set>}"
    elif [[ "$MASQUERADE_MODE" == "static" ]]; then
        printf "  Static path:  %s\n" "${STATIC_PATH:-<not set>}"
    fi
    printf "\n"

    printf "${CYAN}Continue with installation? [y/N]: ${NC}"
    read -r confirm
    case "${confirm,,}" in
        y|yes) log_info "Proceeding..." ;;
        *)     log_info "Aborted by user"; exit 0 ;;
    esac
}
```

**Confidence:** MEDIUM — the exact non-interactive detection heuristic (check DOMAIN from CLI) needs refinement. Alternative: use a dedicated `$NONINTERACTIVE` boolean flag.

### Pattern 12: Post-install Verification

**What:** Verify all success criteria before printing connection info
**When to use:** Last step of server_main()

```bash
server_verify() {
    local all_ok=true

    # 1. Service is active
    if systemctl is-active --quiet chisel; then
        log_info "[OK] chisel.service is active"
    else
        log_warn "[FAIL] chisel.service is NOT active"
        systemctl status chisel --no-pager >&2
        all_ok=false
    fi

    # 2. Port bound to 127.0.0.1 only (SRV-04)
    if ss -tlnp | grep ':7777 ' | grep -q '127.0.0.1'; then
        log_info "[OK] Tunnel port 7777 bound to 127.0.0.1"
    else
        log_warn "[FAIL] Tunnel port 7777 NOT bound to 127.0.0.1 — SECURITY RISK"
        ss -tlnp | grep ':7777 ' >&2 || true
        all_ok=false
    fi

    # 3. Decoy site returns 200
    local http_code
    http_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        log_info "[OK] Decoy site https://${DOMAIN}/ returns HTTP 200"
    else
        log_warn "[FAIL] Decoy site returned HTTP $http_code (expected 200)"
        all_ok=false
    fi

    # 4. WebSocket path responds (404 without WS upgrade is expected/normal)
    local ws_code
    ws_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        "https://${DOMAIN}:${LISTEN_PORT}/${SECRET_PATH}/" 2>/dev/null || echo "000")
    # 404 = nginx received request but no WS upgrade. Normal. 502 = chisel not running.
    if [[ "$ws_code" == "404" || "$ws_code" == "200" ]]; then
        log_info "[OK] WebSocket path /${SECRET_PATH}/ is reachable (HTTP $ws_code — WS upgrade needed to connect)"
    else
        log_warn "[FAIL] WebSocket path returned HTTP $ws_code (expected 404)"
        all_ok=false
    fi

    if [[ "$all_ok" == "true" ]]; then
        server_print_connection_info
    else
        log_warn "Some verification checks failed — review above warnings"
        server_print_connection_info  # Print anyway — partial success is useful
    fi
}

server_print_connection_info() {
    printf "\n${BOLD}=== Connection Information ===${NC}\n"
    printf "${GREEN}Server setup complete!${NC}\n\n"
    printf "  Client command:\n"
    printf "  ${CYAN}chisel client \\\\\n"
    printf "    --auth \"%s:%s\" \\\\\n" "$AUTH_USER" "$AUTH_TOKEN"
    printf "    --keepalive 25s \\\\\n"
    printf "    https://%s:%s/%s/ \\\\\n" "$DOMAIN" "$LISTEN_PORT" "$SECRET_PATH"
    printf "    socks${NC}\n\n"
    printf "  SOCKS5 proxy will start on: 127.0.0.1:1080\n"
    printf "  Config file: /etc/proxyebator/server.conf\n\n"
    printf "${YELLOW}Note: Use 'socks' (not 'R:socks') — socks = exit via server${NC}\n"
}
```

**Confidence:** HIGH — success criteria directly from phase requirements and project reference checklists.

### Anti-Patterns to Avoid

- **Using `--auth user:pass` in Chisel ExecStart:** Credentials visible in `ps aux` — always use `--authfile`
- **`proxy_pass` without trailing slash:** WebSocket upgrade fails silently — always `proxy_pass http://127.0.0.1:7777/;`
- **Omitting `proxy_buffering off`:** Tunnel "connects" but no data flows — include unconditionally
- **Using `-p 127.0.0.1:7777` (single Chisel flag):** Chisel ignores the host part and binds to 0.0.0.0 — always split: `--host 127.0.0.1 -p 7777`
- **Calling certbot without checking cert existence:** Hits Let's Encrypt rate limit (5 certs/domain/week) on re-runs
- **`[""]` in Chisel auth.json:** Known to not work — use `[".*:.*"]`
- **`systemctl enable ufw && ufw enable` in script:** Can lock out SSH if called before allowing SSH port
- **Using `sed` to inject into existing nginx config:** Fragile and error-prone; prefer the nginx `include` snippet approach
- **Hardcoding `amd64` in download URL:** Must use `$ARCH` from `detect_arch()` (Phase 1)
- **`--reverse` flag in Chisel server:** Not needed for SOCKS5, increases attack surface — omit it

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| TLS certificate | Self-signed cert generation | certbot + Let's Encrypt | Browser-trusted, auto-renews, clients don't need cert import |
| WebSocket proxy | Custom TCP forwarder | nginx with location block | nginx handles TLS termination, connection upgrade, buffering — battle-tested |
| Process supervision | `nohup chisel &` or custom daemon | systemd | Handles restart, logging, boot startup, user context — already present |
| Authentication | Custom token check in bash | Chisel `--authfile` | Built-in, constant-time comparison, credentials not in process list |
| Firewall rules | Direct `/proc/net/iptables` manipulation | `ufw` or `iptables` CLI | Standard interfaces; idempotent patterns exist |
| CF IP detection | Downloading CF IP list and parsing CIDR | First-octet heuristic + known ranges | Full CIDR matching in bash requires bitwise arithmetic; heuristic is sufficient for a warning |

**Key insight:** Every component in this stack (nginx, certbot, systemd, chisel) is specifically designed for this use case. The script's job is orchestration, not reimplementation.

---

## Common Pitfalls

### Pitfall 1: Trailing Slash Missing in nginx proxy_pass

**What goes wrong:** WebSocket handshake returns 404. Chisel client logs "Connected" but all traffic through SOCKS5 hangs.
**Why it happens:** Without trailing slash, nginx passes the full `/SECRET_PATH/...` URI to Chisel. Chisel expects requests at `/` on its port.
**How to avoid:** Always generate `proxy_pass http://127.0.0.1:7777/;` with trailing slash. Never make this configurable.
**Warning signs:** `curl -v -H "Upgrade: websocket" https://DOMAIN/SECRET_PATH/` returns 404. Chisel client shows "Connected" but curl via socks hangs.

### Pitfall 2: Missing `proxy_buffering off`

**What goes wrong:** Tunnel appears fully connected (systemctl active, ss shows 127.0.0.1:7777) but data does not flow.
**Why it happens:** nginx buffers the proxied response; WebSocket is a stream — buffering breaks it.
**How to avoid:** `proxy_buffering off;` in every WebSocket location block. Never omit, never behind a condition.
**Warning signs:** `systemctl status chisel` shows active. `ss -tlnp | grep 7777` shows 127.0.0.1. But `curl --socks5-hostname 127.0.0.1:1080 https://example.com` hangs.

### Pitfall 3: Chisel Port Binding to 0.0.0.0

**What goes wrong:** Tunnel port 7777 is accessible from the public internet — security bypass.
**Why it happens:** Using `-p 127.0.0.1:7777` (combined) — Chisel ignores the host part. Must be separate: `--host 127.0.0.1 -p 7777`.
**How to avoid:** Verify with `ss -tlnp | grep ':7777'` after starting. Fail loudly if shows `0.0.0.0:7777` or `*:7777`.
**Warning signs:** `ss -tlnp | grep 7777` shows anything other than `127.0.0.1:7777`.

### Pitfall 4: Certbot Rate Limit on Re-runs

**What goes wrong:** `certbot certonly` fails with "too many certificates already issued" after repeated install attempts.
**Why it happens:** Let's Encrypt enforces 5 duplicate certs per domain per week. Script called certbot without checking.
**How to avoid:** Always check `/etc/letsencrypt/live/DOMAIN/fullchain.pem` before calling certbot.
**Warning signs:** certbot error output mentions "rate limit" or "too many certificates".

### Pitfall 5: Cloudflare Orange Cloud Dropping WebSocket

**What goes wrong:** Tunnel drops every ~100 seconds, or binary data is corrupted, or fails to upgrade.
**Why it happens:** CF Free plan kills idle WebSocket at ~100s. CF CDN can corrupt binary WebSocket data.
**How to avoid:** Detect CF IP (domain resolves to CF range) and warn loudly. Document grey cloud requirement.
**Warning signs:** Tunnel drops exactly every ~100s. `nslookup DOMAIN` returns CF IP (104.x, 172.x range).

### Pitfall 6: Chisel `[""]` in Auth JSON

**What goes wrong:** Chisel starts but refuses all WebSocket connections, returning authentication failures.
**Why it happens:** Empty string `[""]` in the allowed remotes list is known to not work correctly.
**How to avoid:** Always use `[".*:.*"]` — allows all remotes. The script template must hardcode this.
**Warning signs:** Chisel server logs show auth rejections even with correct credentials.

### Pitfall 7: Port 443 Already in Use

**What goes wrong:** nginx fails to bind, or clients get wrong TLS certificate from Xray/another service.
**Why it happens:** Script attempts to configure nginx on 443 without checking.
**How to avoid:** `ss -tlnp | grep ':443 '` before configuring. Offer 2087/8443 alternatives.
**Warning signs:** `systemctl status nginx` shows bind failure. Client receives unexpected certificate.

### Pitfall 8: GitHub API Rate Limit During Version Detection

**What goes wrong:** Version detection returns empty string, download URL is malformed, `curl` fails.
**Why it happens:** GitHub unauthenticated API: 60 req/hour per IP. Shared VPS IPs can hit this.
**How to avoid:** Validate version string; fall back to hardcoded `CHISEL_FALLBACK_VER="v1.11.3"`.
**Warning signs:** `curl` to GitHub API returns 403 with rate limit message. Version var is empty.

### Pitfall 9: Running Chisel as Root

**What goes wrong:** Vulnerability in Chisel gives attacker full root access.
**Why it happens:** Missing `User=nobody` in systemd unit.
**How to avoid:** Always include `User=nobody Group=nogroup` in chisel.service. Verify with `ps aux | grep chisel`.
**Warning signs:** `ps aux | grep chisel` shows `root` in the first column.

### Pitfall 10: certbot Modifying nginx Config Unexpectedly

**What goes wrong:** `certbot --nginx` rewrites the nginx server block, potentially removing the WebSocket location block or changing `listen` directives.
**Why it happens:** `certbot --nginx` (without `certonly`) auto-modifies the config.
**How to avoid:** Use `certbot certonly --nginx -d DOMAIN` — gets the cert but does NOT modify nginx config. The script manages nginx config entirely.
**Warning signs:** After certbot runs, nginx location block for WebSocket is gone. nginx config has certbot-added lines.

---

## Code Examples

### Complete Server Binary Download

```bash
# Source: tunnel-reference.md (verified 2026-02-18) + live GitHub API check
# Confirmed asset format: chisel_1.11.3_linux_amd64.gz (no tar, just gzip)

CHISEL_FALLBACK_VER="v1.11.3"
CHISEL_VER=$(curl -sf --max-time 10 \
    "https://api.github.com/repos/jpillora/chisel/releases/latest" \
    | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*') \
    || CHISEL_VER="$CHISEL_FALLBACK_VER"
[[ -n "$CHISEL_VER" ]] || CHISEL_VER="$CHISEL_FALLBACK_VER"

curl -fLo /tmp/chisel.gz \
    "https://github.com/jpillora/chisel/releases/download/${CHISEL_VER}/chisel_${CHISEL_VER#v}_linux_${ARCH}.gz"
gunzip -f /tmp/chisel.gz
chmod +x /tmp/chisel
mv /tmp/chisel /usr/local/bin/chisel
chisel --version
```

### Complete nginx WebSocket Location Block

```nginx
# Source: tunnel-reference.md (production-validated)
# CRITICAL: proxy_pass trailing slash and proxy_buffering off are non-negotiable

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

### Auth File Creation

```bash
# Source: tunnel-reference.md (production-validated)
# [".*:.*"] = allow all remotes. [""] is known to NOT work.

mkdir -p /etc/chisel
cat > /etc/chisel/auth.json << EOF
{
  "${AUTH_USER}:${AUTH_TOKEN}": [".*:.*"]
}
EOF
chmod 600 /etc/chisel/auth.json
chown nobody:nogroup /etc/chisel/auth.json
```

### Systemd Unit (complete)

```bash
# Source: tunnel-reference.md (production-validated)
# CRITICAL: --host 127.0.0.1 and -p 7777 MUST be separate arguments

cat > /etc/systemd/system/chisel.service << 'EOF'
[Unit]
Description=Chisel Tunnel Server (proxyebator)
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
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now chisel
```

### Binding Verification

```bash
# Source: tunnel-reference.md + SRV-04 requirement
# Must show 127.0.0.1:7777 — NOT 0.0.0.0:7777 or *:7777

if ss -tlnp | grep ':7777 ' | grep -q '127.0.0.1'; then
    echo "OK: tunnel port bound to 127.0.0.1"
else
    echo "SECURITY FAIL: tunnel port not restricted to localhost"
    ss -tlnp | grep ':7777 '
    exit 1
fi
```

### Dependency Installation (Debian/Ubuntu)

```bash
# Idempotent: apt-get install is idempotent for already-installed packages
apt-get update -qq
apt-get install -y -qq curl openssl nginx

# certbot: check snap first (official recommended path), then apt
if command -v snap &>/dev/null; then
    snap install --classic certbot 2>/dev/null || true
    ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
else
    apt-get install -y -qq certbot python3-certbot-nginx
fi

# Verify certbot is available
command -v certbot || die "certbot installation failed"
```

---

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|------------------|-------|
| certbot via apt | certbot via snap | Official certbot.eff.org recommends snap since 2021; snap version is always latest and auto-updates |
| nginx `proxy_read_timeout 60s` | `proxy_read_timeout 3600s` | Long-lived WebSocket connections need 1-hour timeout |
| Running tunnel as root | `User=nobody` in systemd | Security standard; tunnel only needs network access |
| `--auth user:pass` in ExecStart | `--authfile /path/to/file` | Prevents credentials appearing in `ps aux` |
| Detecting CF via IP parsing | Checking first octet heuristic | Full CIDR checking in bash is fragile; heuristic is sufficient for a warning |

---

## Open Questions

1. **Non-interactive mode detection heuristic**
   - What we know: CLI flags `$DOMAIN`, `$TUNNEL_TYPE`, `$LISTEN_PORT`, `$MASQUERADE_MODE` are set from Phase 1 parser
   - What's unclear: Should ALL four being set trigger non-interactive, or just DOMAIN? What if user provides --domain but not --masquerade?
   - Recommendation: Track a separate `$NONINTERACTIVE` boolean. Set it to `true` if any required flag is explicitly passed. Or: prompt for missing required values even in partial non-interactive mode. The cleanest solution is prompting for each value individually, checking the CLI var first — then the user can pass any combination of flags.

2. **certbot email address**
   - What we know: certbot `--non-interactive` requires `--agree-tos --email EMAIL`
   - What's unclear: Should script prompt for email? Use a placeholder like `admin@DOMAIN`? Let certbot skip email with a flag?
   - Recommendation: Use `--register-unsafely-without-email` flag to skip email requirement. This is a valid certbot flag for automation. Alternatively, prompt for email during param collection and include in summary.

3. **Existing nginx config injection method**
   - What we know: `sed` injection is fragile for arbitrary nginx configs. Include-snippet approach is cleaner.
   - What's unclear: Can the script reliably add `include /etc/nginx/proxyebator.d/*.conf;` to an existing server block? Only if the block structure is known.
   - Recommendation: Use a two-tier approach: (a) if no existing config for domain — write a full new config file; (b) if existing config detected — warn user and provide the location block as text they can manually add, OR attempt injection with a clear marker and backup.

4. **certbot `--nginx` vs `--webroot` vs `--standalone` plugin**
   - What we know: `certbot certonly --nginx` works when nginx is running and can serve `.well-known/acme-challenge/`. Standalone requires nginx to be stopped.
   - What's unclear: Is nginx guaranteed to be running and serving port 80 when certbot is called?
   - Recommendation: Use `certbot certonly --nginx` for the common case (nginx is running, no cert yet). The script writes the nginx config before calling certbot so nginx is serving port 80. If nginx isn't running, `certonly --standalone` with a temporary stop is the fallback.

---

## Sources

### Primary (HIGH confidence)

- `/home/kosya/vibecoding/proxyebator/tunnel-reference.md` — Production deployment reference with validated CLI flags, nginx location block, systemd unit, auth file format (2026-02-18)
- `/home/kosya/vibecoding/proxyebator/PROXY-GUIDE.md` — Architecture guide with troubleshooting table, "грабли" section (2026-02-18)
- Live GitHub API — Chisel v1.11.3 confirmed current; asset format `chisel_1.11.3_linux_amd64.gz` confirmed (2026-02-18)
- Live GitHub API — wstunnel v10.5.2 current (for reference; Phase 6 scope)
- Cloudflare IPv4 published ranges — https://www.cloudflare.com/ips-v4/ confirmed (2026-02-18)

### Secondary (MEDIUM confidence)

- `.planning/research/STACK.md` — Technology stack analysis with CLI flags, port strategy, certbot approaches
- `.planning/research/PITFALLS.md` — Phase-specific pitfall catalogue (20 pitfalls documented)
- `.planning/phases/01-script-foundation/01-RESEARCH.md` — Established Phase 1 patterns (gen_secret_path, gen_auth_token, detect_os, detect_arch, CLI flag variables)

### Tertiary (LOW confidence)

- dns.google DoH API for CF-free domain resolution — tested locally, behavior expected to be stable but external dependency

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Chisel version confirmed via live API; nginx/certbot/systemd patterns from production reference
- Architecture patterns: HIGH — all templates from tunnel-reference.md (production-validated); Pattern 2 (CF detection) is MEDIUM due to simplified IP heuristic
- Pitfalls: HIGH — documented from real production debugging in PITFALLS.md; all cross-verified with tunnel-reference.md

**Research date:** 2026-02-18
**Valid until:** 2026-08-18 (Chisel release format stable; nginx patterns stable; certbot stable — re-verify Chisel version fallback constant if planning after 6 months)
