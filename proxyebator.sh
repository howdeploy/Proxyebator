#!/bin/bash
set -euo pipefail

# ── ANSI COLOR CONSTANTS ──────────────────────────────────────────────────────
# Gate colors on terminal detection — suppresses ANSI codes in pipes/logs
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' NC=''
fi
readonly RED YELLOW GREEN CYAN BOLD NC

# ── LOGGING FUNCTIONS ─────────────────────────────────────────────────────────
# Use printf (not echo -e): portable, handles %s escaping correctly
# log_warn and die go to stderr so they're visible when stdout is redirected
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
die()      { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }

# ── USAGE ─────────────────────────────────────────────────────────────────────
print_usage() {
    cat << EOF
${BOLD}proxyebator${NC} — WebSocket proxy tunnel installer

${BOLD}USAGE${NC}
  $(basename "$0") <command> [options]

${BOLD}COMMANDS${NC}
  server      Install and configure proxy server (nginx + Chisel/wstunnel + TLS)
  client      Install tunnel client binary and configure SOCKS5
  uninstall   Remove all installed components

${BOLD}OPTIONS${NC}
  --help, -h          Show this help
  --domain DOMAIN     Server domain name (skips interactive prompt)
  --tunnel TYPE       Tunnel backend: chisel (default) or wstunnel
  --port PORT         Listen port (default: 443)
  --masquerade MODE   Cover site mode: stub | proxy | static (default: stub)

${BOLD}EXAMPLES${NC}
  # Interactive install
  sudo $(basename "$0") server

  # Non-interactive install (AI-agent friendly)
  sudo $(basename "$0") server --domain example.com --tunnel chisel

  # Connect client
  sudo $(basename "$0") client

  # Uninstall
  sudo $(basename "$0") uninstall
EOF
}

# ── ROOT CHECK ────────────────────────────────────────────────────────────────
check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $(basename "$0") $*"
    fi
}

# ── OS DETECTION ──────────────────────────────────────────────────────────────
detect_os() {
    [[ -f /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found"
    # shellcheck disable=SC1091
    source /etc/os-release

    _map_os_id() {
        case "$1" in
            debian|ubuntu|raspbian)
                PKG_UPDATE="apt-get update -qq"
                PKG_INSTALL="apt-get install -y -qq"
                NGINX_CONF_DIR="/etc/nginx/sites-available"
                NGINX_CONF_LINK="/etc/nginx/sites-enabled"
                ;;
            centos|rhel|almalinux|rocky)
                PKG_UPDATE="dnf check-update || true"
                PKG_INSTALL="dnf install -y"
                NGINX_CONF_DIR="/etc/nginx/conf.d"
                NGINX_CONF_LINK=""
                ;;
            fedora)
                PKG_UPDATE="dnf check-update || true"
                PKG_INSTALL="dnf install -y"
                NGINX_CONF_DIR="/etc/nginx/conf.d"
                NGINX_CONF_LINK=""
                ;;
            arch|manjaro)
                PKG_UPDATE="pacman -Sy --noconfirm"
                PKG_INSTALL="pacman -S --needed --noconfirm"
                NGINX_CONF_DIR="/etc/nginx/sites-available"
                NGINX_CONF_LINK="/etc/nginx/sites-enabled"
                ;;
            *) return 1 ;;
        esac
        return 0
    }

    OS="$ID"
    if ! _map_os_id "$ID"; then
        # Fallback: check ID_LIKE for derivative distros (Mint, Pop!_OS, etc.)
        local like_id
        like_id=$(printf '%s' "${ID_LIKE:-}" | awk '{print $1}')
        OS="$like_id"
        if ! _map_os_id "$like_id"; then
            die "Unsupported OS: ${PRETTY_NAME:-$ID}. Supported: Debian, Ubuntu, CentOS, Fedora, Arch"
        fi
    fi

    log_info "Detected OS: ${PRETTY_NAME:-$ID} | Package manager: $(printf '%s' "$PKG_INSTALL" | awk '{print $1}')"
}

# ── ARCHITECTURE DETECTION ────────────────────────────────────────────────────
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv6l) ARCH="arm"   ;;
        *)
            die "Unsupported architecture: $machine. Supported: amd64 (x86_64), arm64 (aarch64)"
            ;;
    esac
    log_info "Detected architecture: $ARCH"
}

# ── SECRET GENERATION ─────────────────────────────────────────────────────────
gen_secret_path() {
    # 32 hex chars = 128 bits entropy
    # openssl rand -hex 16 produces exactly 32 hex characters
    openssl rand -hex 16
}

gen_auth_token() {
    # openssl rand -base64 24 = 24 bytes → 32 base64 chars
    # tr -d '\n' removes trailing newline (pitfall #5 — always strip newline)
    openssl rand -base64 24 | tr -d '\n'
}

# ── SERVER PARAMETER COLLECTION ───────────────────────────────────────────────

prompt_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        log_info "Domain set via CLI flag: ${DOMAIN}"
        return
    fi
    printf "${CYAN}[?]${NC} Enter your domain name (e.g. example.com): "
    read -r DOMAIN
    [[ -n "$DOMAIN" ]] || die "Domain is required"
}

validate_domain() {
    # Format check
    printf '%s' "$DOMAIN" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' \
        || die "Invalid domain format: ${DOMAIN}"

    # Get server public IP
    local server_ip=""
    server_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) \
        || server_ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null) \
        || die "Could not determine server public IP — check internet connectivity"

    # Resolve domain A-record via DNS-over-HTTPS (no dig/host dependency)
    local dns_resp domain_ip
    dns_resp=$(curl -sf --max-time 10 "https://dns.google/resolve?name=${DOMAIN}&type=A" 2>/dev/null) \
        || die "DNS resolution request failed — check internet connectivity"
    domain_ip=$(printf '%s' "$dns_resp" | grep -oP '"data"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    [[ -n "$domain_ip" ]] \
        || die "Could not resolve domain — check DNS A-record for ${DOMAIN}"

    # Cloudflare detection: check first octet against known CF ranges
    local first_octet
    first_octet=$(printf '%s' "$domain_ip" | cut -d. -f1)
    case "$first_octet" in
        103|104|108|141|162|172|173|188|190|197|198)
            log_warn "Domain resolves to a Cloudflare IP (${domain_ip}) — orange cloud detected."
            log_warn "WebSocket connections through Cloudflare proxy may timeout."
            log_warn "Recommended: switch to grey cloud (DNS-only) in Cloudflare dashboard for this record."
            ;;
    esac

    # Compare domain IP to server IP
    [[ "$domain_ip" == "$server_ip" ]] \
        || die "Domain ${DOMAIN} resolves to ${domain_ip} but server IP is ${server_ip} — update your DNS A-record"

    log_info "Domain ${DOMAIN} resolves to server IP ${server_ip} — OK"
}

prompt_masquerade_mode() {
    if [[ -n "${MASQUERADE_MODE:-}" ]]; then
        case "$MASQUERADE_MODE" in
            stub|proxy|static) ;;
            *) die "Invalid masquerade mode '${MASQUERADE_MODE}'. Must be: stub, proxy, or static" ;;
        esac
        log_info "Masquerade mode set via CLI flag: ${MASQUERADE_MODE}"
        return
    fi

    printf "\n${CYAN}[?]${NC} Choose masquerade mode for the cover site:\n"
    printf "  1) stub   — Minimal HTML page (\"Under construction\")\n"
    printf "  2) proxy  — Reverse-proxy an external website (e.g. a blog)\n"
    printf "  3) static — Serve your own static files from a local folder\n"
    printf "Choice [1]: "
    read -r _mode_choice

    case "${_mode_choice:-1}" in
        1|stub|"")   MASQUERADE_MODE="stub" ;;
        2|proxy)     MASQUERADE_MODE="proxy" ;;
        3|static)    MASQUERADE_MODE="static" ;;
        *) die "Invalid choice: ${_mode_choice}" ;;
    esac

    if [[ "$MASQUERADE_MODE" == "proxy" ]]; then
        printf "${CYAN}[?]${NC} Enter URL to proxy (e.g. https://example.blog): "
        read -r PROXY_URL
        [[ -n "$PROXY_URL" ]] || die "Proxy URL is required for proxy masquerade mode"
    fi

    if [[ "$MASQUERADE_MODE" == "static" ]]; then
        printf "${CYAN}[?]${NC} Enter path to static files directory: "
        read -r STATIC_PATH
        [[ -n "$STATIC_PATH" ]] || die "Static path is required for static masquerade mode"
        [[ -d "$STATIC_PATH" ]] || die "Static path '${STATIC_PATH}' is not a directory or does not exist"
    fi
}

detect_listen_port() {
    if [[ -n "${LISTEN_PORT:-}" ]]; then
        log_info "Listen port set via CLI flag: ${LISTEN_PORT}"
        return
    fi

    if ss -tlnp 2>/dev/null | grep -q ':443 '; then
        local occupant
        occupant=$(ss -tlnp 2>/dev/null | grep ':443 ' | grep -oP 'users:\(\(".*?"\)' | head -1 || echo "unknown process")
        log_warn "Port 443 is in use (${occupant})."
        log_warn "Alternative ports: 2087, 8443"
        printf "${CYAN}[?]${NC} Enter listen port [2087]: "
        read -r LISTEN_PORT
        LISTEN_PORT="${LISTEN_PORT:-2087}"
    else
        LISTEN_PORT=443
        log_info "Port 443 is available — using 443"
    fi
}

server_collect_params() {
    # Detect non-interactive mode: domain already set before any prompts
    if [[ -n "${DOMAIN:-}" ]]; then
        CLI_MODE="true"
    else
        CLI_MODE="false"
    fi

    prompt_domain
    validate_domain
    prompt_masquerade_mode
    detect_listen_port

    # Tunnel type: hardcoded to chisel for Phase 2 (wstunnel added in Phase 6)
    TUNNEL_TYPE="chisel"

    # Generate secrets
    SECRET_PATH=$(gen_secret_path)
    AUTH_USER="proxyebator"
    AUTH_TOKEN=$(gen_auth_token)

    log_info "Parameters collected successfully"
}

# ── PRE-INSTALL SUMMARY & DEPENDENCY INSTALLATION ─────────────────────────────

server_show_summary() {
    # Non-interactive bypass: if all params came from CLI flags, skip confirmation
    if [[ "${CLI_MODE:-false}" == "true" ]]; then
        log_info "Non-interactive mode: skipping confirmation"
        return
    fi

    printf "\n${BOLD}=== Installation Summary ===${NC}\n"
    printf "  Domain:       %s\n" "$DOMAIN"
    printf "  Listen port:  %s\n" "$LISTEN_PORT"
    printf "  Tunnel:       Chisel (port 7777, bound to 127.0.0.1)\n"
    printf "  Secret path:  /%s/\n" "$SECRET_PATH"
    printf "  Masquerade:   %s\n" "$MASQUERADE_MODE"
    if [[ "${MASQUERADE_MODE:-}" == "proxy" ]]; then
        printf "  Proxy URL:    %s\n" "${PROXY_URL:-}"
    fi
    if [[ "${MASQUERADE_MODE:-}" == "static" ]]; then
        printf "  Static path:  %s\n" "${STATIC_PATH:-}"
    fi
    printf "\n"

    printf "${CYAN}[?]${NC} Continue with installation? [y/N]: "
    read -r _confirm
    case "${_confirm:-N}" in
        y|Y|yes|YES) ;;
        *) die "Installation aborted by user" ;;
    esac
}

server_install_deps() {
    log_info "Updating package index..."
    eval "$PKG_UPDATE" || true

    local pkg
    for pkg in curl openssl nginx; do
        if command -v "$pkg" &>/dev/null; then
            log_info "${pkg}: already installed"
        else
            log_info "Installing ${pkg}..."
            eval "$PKG_INSTALL $pkg"
            log_info "Installed: ${pkg}"
        fi
    done

    # certbot: prefer snap, fallback to package manager
    if command -v certbot &>/dev/null; then
        log_info "certbot: already installed"
    else
        log_info "Installing certbot..."
        if command -v snap &>/dev/null && snap install --classic certbot 2>/dev/null; then
            ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
            log_info "Installed: certbot (via snap)"
        else
            eval "$PKG_INSTALL certbot python3-certbot-nginx" || true
        fi
        command -v certbot &>/dev/null || die "certbot installation failed — install manually and retry"
        log_info "Installed: certbot"
    fi

    # jq: needed for JSON config operations
    if command -v jq &>/dev/null; then
        log_info "jq: already installed"
    else
        log_info "Installing jq..."
        eval "$PKG_INSTALL jq"
        log_info "Installed: jq"
    fi
}

# ── CHISEL DOWNLOAD AND AUTH SETUP ────────────────────────────────────────────

server_download_chisel() {
    local CHISEL_FALLBACK_VER="v1.11.3"
    local CHISEL_VER
    CHISEL_VER=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/jpillora/chisel/releases/latest" \
        | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*') \
        || CHISEL_VER=""

    if [[ -z "$CHISEL_VER" ]]; then
        log_warn "Could not fetch latest Chisel version from GitHub API — using fallback ${CHISEL_FALLBACK_VER}"
        CHISEL_VER="$CHISEL_FALLBACK_VER"
    fi

    # Asset format: chisel_X.Y.Z_linux_ARCH.gz (not .tar.gz — use gunzip)
    local download_url="https://github.com/jpillora/chisel/releases/download/${CHISEL_VER}/chisel_${CHISEL_VER#v}_linux_${ARCH}.gz"
    log_info "Downloading Chisel ${CHISEL_VER} for ${ARCH} from GitHub..."

    curl -fLo /tmp/chisel.gz "$download_url" || die "Failed to download Chisel from $download_url"
    gunzip -f /tmp/chisel.gz
    chmod +x /tmp/chisel
    mv /tmp/chisel /usr/local/bin/chisel

    /usr/local/bin/chisel --version || die "Chisel binary not working after install"
    log_info "Chisel installed: $(/usr/local/bin/chisel --version 2>&1 | head -1)"
}

server_setup_auth() {
    mkdir -p /etc/chisel
    mkdir -p /etc/proxyebator

    # Write auth.json with correct remote pattern [".*:.*"] — NOT [""] (empty fails)
    cat > /etc/chisel/auth.json << EOF
{
  "${AUTH_USER}:${AUTH_TOKEN}": [".*:.*"]
}
EOF

    chmod 600 /etc/chisel/auth.json
    # Ownership must match systemd User=nobody so Chisel can read the file
    chown nobody:nogroup /etc/chisel/auth.json
    log_info "Auth file created: /etc/chisel/auth.json (chmod 600)"
}

# ── SYSTEMD SERVICE CREATION ───────────────────────────────────────────────────

server_create_systemd() {
    # Write systemd unit file
    # CRITICAL: --host and -p are SEPARATE flags (combined form ignored by Chisel)
    # CRITICAL: --authfile not --auth (credentials not exposed in ps aux)
    # CRITICAL: --socks5 required for SOCKS5 mode
    # CRITICAL: --reverse NOT included (not needed for SOCKS5, increases attack surface)
    # CRITICAL: User=nobody NOT DynamicUser=yes (DynamicUser changes UID on restart, breaks authfile ownership)
    cat > /etc/systemd/system/proxyebator.service << 'UNIT'
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
UNIT

    systemctl daemon-reload
    systemctl enable --now proxyebator || die "Failed to start proxyebator.service"
    log_info "Chisel systemd service: $(systemctl is-active proxyebator 2>/dev/null || echo 'unknown')"
}

# ── NGINX CONFIGURATION ───────────────────────────────────────────────────────

detect_existing_nginx() {
    local existing
    existing=$(grep -rl "server_name.*${DOMAIN}" /etc/nginx/ 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
        NGINX_EXISTING_CONF="$existing"
        log_warn "Found existing nginx config for ${DOMAIN}: ${NGINX_EXISTING_CONF}"
    else
        NGINX_EXISTING_CONF=""
    fi
}

generate_masquerade_block() {
    # MASK-06 (HTTPS-only without nginx) removed by design --- nginx is always used.
    # All three modes (stub/proxy/static) go through nginx.
    case "${MASQUERADE_MODE:-stub}" in
        stub)
            cat << 'NGINX_STUB'
    location / {
        return 200 '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Welcome</title><style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f5f5}div{text-align:center;color:#333}</style></head><body><div><h1>Welcome</h1><p>This site is under construction.</p></div></body></html>';
        add_header Content-Type text/html;
    }
NGINX_STUB
            ;;
        proxy)
            local proxy_host
            proxy_host=$(printf '%s' "${PROXY_URL:-}" | sed 's|https\?://||;s|/.*||')
            cat << NGINX_PROXY
    location / {
        proxy_pass ${PROXY_URL:-};
        proxy_set_header Host ${proxy_host};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_ssl_server_name on;
    }
NGINX_PROXY
            ;;
        static)
            cat << NGINX_STATIC
    root ${STATIC_PATH:-/var/www/html};
    location / {
        try_files \$uri \$uri/ =404;
    }
NGINX_STATIC
            ;;
    esac
}

generate_tunnel_location_block() {
    # CRITICAL: proxy_pass trailing slash is MANDATORY — strips /SECRET_PATH/ prefix
    # CRITICAL: proxy_buffering off is MANDATORY — without it WebSocket data is buffered silently
    # Neither directive is configurable.
    cat << TUNNEL_BLOCK
    # proxyebator-tunnel-block-start
    location /${SECRET_PATH}/ {
        proxy_pass http://127.0.0.1:7777/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
    # proxyebator-tunnel-block-end
TUNNEL_BLOCK
}

server_configure_nginx() {
    detect_existing_nginx

    if [[ -n "${NGINX_EXISTING_CONF:-}" ]]; then
        # Existing config found --- inject tunnel block, do not replace
        if grep -q "proxyebator-tunnel-block-start" "$NGINX_EXISTING_CONF" 2>/dev/null; then
            log_info "Tunnel block already present in ${NGINX_EXISTING_CONF} --- skipping injection"
        else
            # Backup the existing config before modifying
            cp "$NGINX_EXISTING_CONF" "${NGINX_EXISTING_CONF}.bak.$(date +%s)"
            log_info "Backed up existing nginx config"

            local tunnel_block tmpconf
            tunnel_block=$(generate_tunnel_location_block)
            tmpconf=$(mktemp)
            # Insert tunnel block before first 'location /' line
            awk -v block="$tunnel_block" '/location \/ \{/ && !inserted {print block; inserted=1} {print}' \
                "$NGINX_EXISTING_CONF" > "$tmpconf"
            mv "$tmpconf" "$NGINX_EXISTING_CONF"
            log_info "Tunnel location block injected into existing nginx config"
        fi
        NGINX_CONF_PATH="$NGINX_EXISTING_CONF"

        # Cert already exists --- write full SSL config now
        if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
            CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
            CERT_KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            nginx -t || die "nginx configuration test failed after injection"
            systemctl reload nginx || die "Failed to reload nginx"
        else
            nginx -t || die "nginx configuration test failed after injection"
            systemctl reload nginx || die "Failed to reload nginx"
        fi
    else
        # New setup --- write fresh config
        NGINX_CONF_PATH="${NGINX_CONF_DIR}/proxyebator-${DOMAIN}.conf"

        if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
            # Cert exists --- write full SSL config directly
            CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
            CERT_KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            write_nginx_ssl_config
        else
            # No cert yet --- write minimal HTTP-only config for certbot ACME challenge
            log_info "Writing temporary HTTP-only nginx config for certbot ACME challenge..."
            cat > "$NGINX_CONF_PATH" << NGINX_HTTP
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        return 200 'Preparing TLS...';
        add_header Content-Type text/plain;
    }
}
NGINX_HTTP

            # Create symlink for Debian/Ubuntu (sites-enabled)
            if [[ -n "${NGINX_CONF_LINK:-}" ]]; then
                ln -sf "$NGINX_CONF_PATH" "${NGINX_CONF_LINK}/$(basename "$NGINX_CONF_PATH")"
                log_info "Created symlink: ${NGINX_CONF_LINK}/$(basename "$NGINX_CONF_PATH")"
            fi

            nginx -t || die "nginx configuration test failed"
            systemctl reload nginx || die "Failed to reload nginx"
            log_info "Temporary HTTP nginx config active — certbot ACME will use port 80"
        fi
    fi
}

# ── TLS CERTIFICATE ACQUISITION ───────────────────────────────────────────────

check_existing_cert() {
    # Check Let's Encrypt standard path first
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        CERT_KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        return 0
    fi

    # Check existing nginx config for ssl_certificate directive (non-LE certs)
    if [[ -n "${NGINX_EXISTING_CONF:-}" ]]; then
        local existing_cert
        existing_cert=$(grep -o 'ssl_certificate [^;]*' "$NGINX_EXISTING_CONF" 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$existing_cert" && -f "$existing_cert" ]]; then
            CERT_PATH="$existing_cert"
            CERT_KEY_PATH=$(grep -o 'ssl_certificate_key [^;]*' "$NGINX_EXISTING_CONF" 2>/dev/null | awk '{print $2}' | head -1)
            return 0
        fi
    fi

    return 1
}

write_nginx_ssl_config() {
    # Only for NEW configs — existing configs already have SSL, we only injected the tunnel block
    [[ -n "${NGINX_EXISTING_CONF:-}" ]] && return 0

    local tunnel_block masquerade_block
    tunnel_block=$(generate_tunnel_location_block)
    masquerade_block=$(generate_masquerade_block)

    cat > "$NGINX_CONF_PATH" << NGINX_SSL
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${LISTEN_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${CERT_KEY_PATH};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

${tunnel_block}
${masquerade_block}
}
NGINX_SSL

    # Create symlink for Debian/Ubuntu (sites-enabled) if not already present
    if [[ -n "${NGINX_CONF_LINK:-}" ]]; then
        local symlink_path="${NGINX_CONF_LINK}/$(basename "$NGINX_CONF_PATH")"
        if [[ ! -L "$symlink_path" ]]; then
            ln -sf "$NGINX_CONF_PATH" "$symlink_path"
            log_info "Created symlink: $symlink_path"
        fi
    fi

    nginx -t || die "nginx configuration test failed"
    systemctl reload nginx || die "Failed to reload nginx"
    log_info "nginx configured with TLS and masquerade mode: ${MASQUERADE_MODE}"
}

server_obtain_tls() {
    if check_existing_cert; then
        log_info "TLS cert already exists --- reusing (${CERT_PATH})"
        # If this is a new config (not existing), write full SSL config now
        write_nginx_ssl_config
    else
        # Ensure nginx is running for --nginx plugin
        systemctl start nginx 2>/dev/null || true

        log_info "Obtaining TLS certificate via certbot for ${DOMAIN}..."
        certbot certonly \
            --nginx \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email \
            -d "$DOMAIN" \
            || die "certbot failed to obtain TLS certificate for $DOMAIN. Check DNS and port 80 access."

        CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        CERT_KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

        # Write full SSL config (replaces the temporary HTTP-only config)
        write_nginx_ssl_config
    fi

    # Enable certbot renewal timer
    if systemctl list-units --type=timer 2>/dev/null | grep -q "snap.certbot"; then
        systemctl enable --now snap.certbot.renew.timer 2>/dev/null || true
    else
        systemctl enable --now certbot.timer 2>/dev/null || true
    fi

    log_info "TLS certificate active for ${DOMAIN}"
}

# ── FIREWALL CONFIGURATION ────────────────────────────────────────────────────

server_configure_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        # ufw is installed AND active --- use ufw
        ufw allow 80/tcp comment "proxyebator HTTP" 2>/dev/null || true
        ufw allow "${LISTEN_PORT}/tcp" comment "proxyebator HTTPS" 2>/dev/null || true
        ufw deny 7777/tcp comment "proxyebator tunnel internal" 2>/dev/null || true
        log_info "Firewall configured via ufw: 80/tcp ALLOW, ${LISTEN_PORT}/tcp ALLOW, 7777/tcp DENY"
    elif command -v ufw &>/dev/null; then
        # ufw installed but NOT active --- log and fall through to iptables
        # CRITICAL: Never activate ufw here --- enabling it can lock out SSH
        log_warn "ufw installed but not active --- using iptables instead"
        # Fall through to iptables
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -C INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT
        # ! -i lo: block external access to tunnel port but allow localhost (nginx→chisel)
        iptables -C INPUT -p tcp --dport 7777 ! -i lo -j DROP 2>/dev/null \
            || iptables -A INPUT -p tcp --dport 7777 ! -i lo -j DROP
        log_info "Firewall configured via iptables: 80 ALLOW, ${LISTEN_PORT} ALLOW, 7777 DROP (non-lo)"
    else
        # ufw not found --- configure via iptables
        log_info "ufw not found --- configuring via iptables"
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -C INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT
        # ! -i lo: block external access to tunnel port but allow localhost (nginx→chisel)
        iptables -C INPUT -p tcp --dport 7777 ! -i lo -j DROP 2>/dev/null \
            || iptables -A INPUT -p tcp --dport 7777 ! -i lo -j DROP
        log_info "Firewall configured via iptables: 80 ALLOW, ${LISTEN_PORT} ALLOW, 7777 DROP (non-lo)"
    fi
}

# ── SERVER CONFIG SAVE ────────────────────────────────────────────────────────

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
CERT_PATH=${CERT_PATH:-/etc/letsencrypt/live/${DOMAIN}/fullchain.pem}
CERT_KEY_PATH=${CERT_KEY_PATH:-/etc/letsencrypt/live/${DOMAIN}/privkey.pem}
EOF

    chmod 600 /etc/proxyebator/server.conf
    log_info "Config saved: /etc/proxyebator/server.conf"
}

# ── POST-INSTALL VERIFICATION ─────────────────────────────────────────────────

server_print_connection_info() {
    printf "\n${BOLD}=== Connection Information ===${NC}\n"
    printf "${GREEN}Server setup complete!${NC}\n\n"
    printf "  ${BOLD}Client command:${NC}\n"
    printf "  ${CYAN}chisel client \\\\${NC}\n"
    printf "  ${CYAN}  --auth \"%s:%s\" \\\\${NC}\n" "${AUTH_USER}" "${AUTH_TOKEN}"
    printf "  ${CYAN}  --keepalive 25s \\\\${NC}\n"
    printf "  ${CYAN}  https://%s:%s/%s/ \\\\${NC}\n" "${DOMAIN}" "${LISTEN_PORT}" "${SECRET_PATH}"
    printf "  ${CYAN}  socks${NC}\n"
    printf "\n"
    printf "  ${BOLD}SOCKS5 proxy will be available at:${NC} 127.0.0.1:1080\n"
    printf "\n"
    printf "  ${BOLD}Server config file:${NC} /etc/proxyebator/server.conf\n"
    printf "\n"
    printf "  ${YELLOW}Note: Use 'socks' (not 'R:socks') --- 'socks' means traffic exits via server.${NC}\n"
    printf "  ${YELLOW}Note: The trailing slash in the URL is required.${NC}\n"
}

server_verify() {
    local all_ok=true

    printf "\n${BOLD}=== Post-Install Verification ===${NC}\n"

    # Check 1: proxyebator.service active (SRV-01)
    if systemctl is-active --quiet proxyebator 2>/dev/null; then
        log_info "[PASS] proxyebator.service is active"
    else
        log_warn "[FAIL] proxyebator.service is NOT active"
        systemctl status proxyebator --no-pager >&2 2>/dev/null || true
        all_ok=false
    fi

    # Check 2: Tunnel port bound to 127.0.0.1 only (SRV-04)
    if ss -tlnp 2>/dev/null | grep ':7777 ' | grep -q '127.0.0.1'; then
        log_info "[PASS] Tunnel port 7777 bound to 127.0.0.1"
    else
        log_warn "[FAIL] Tunnel port 7777 NOT bound to 127.0.0.1 --- SECURITY RISK"
        ss -tlnp 2>/dev/null | grep ':7777 ' >&2 || true
        all_ok=false
    fi

    # Check 3: Decoy site returns HTTP 200
    local http_code
    http_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        log_info "[PASS] Cover site https://${DOMAIN}/ returns HTTP 200"
    else
        log_warn "[FAIL] Cover site returned HTTP $http_code (expected 200)"
        all_ok=false
    fi

    # Check 4: WebSocket path reachable (404/200/101 all acceptable)
    # 404 is normal without WebSocket upgrade headers; 101 means upgrade succeeded
    local ws_code
    ws_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        "https://${DOMAIN}:${LISTEN_PORT}/${SECRET_PATH}/" 2>/dev/null || echo "000")
    if [[ "$ws_code" == "404" || "$ws_code" == "200" || "$ws_code" == "101" ]]; then
        log_info "[PASS] WebSocket path /${SECRET_PATH}/ is reachable (HTTP $ws_code)"
    else
        log_warn "[FAIL] WebSocket path returned HTTP $ws_code"
        all_ok=false
    fi

    # Summary banner
    if [[ "$all_ok" == "true" ]]; then
        printf "\n${GREEN}${BOLD}All checks passed.${NC}\n"
    else
        printf "\n${YELLOW}${BOLD}Some checks failed — review warnings above.${NC}\n"
        printf "${YELLOW}Connection info is still provided below for manual debugging.${NC}\n"
    fi

    # Always print connection info (partial success is still useful)
    server_print_connection_info
}

server_main() {
    check_root
    detect_os
    detect_arch
    server_collect_params
    server_show_summary
    server_install_deps
    server_download_chisel
    server_setup_auth
    server_create_systemd
    server_configure_nginx
    server_obtain_tls
    server_configure_firewall
    server_save_config
    server_verify
}

client_main() {
    log_info "client_main: not yet implemented"
}

uninstall_main() {
    log_info "uninstall_main: not yet implemented"
}

# ── ENTRY POINT ───────────────────────────────────────────────────────────────
MODE=""

# No args: print usage and exit cleanly
if [[ $# -eq 0 ]]; then
    print_usage
    exit 0
fi

# Extract positional mode (first arg)
case "$1" in
    server|client|uninstall) MODE="$1"; shift ;;
    --help|-h) print_usage; exit 0 ;;
    *) print_usage; die "Unknown command: $1" ;;
esac

# Parse remaining flags (non-interactive mode support — values used by Phase 2+)
DOMAIN=""
TUNNEL_TYPE=""
LISTEN_PORT=""
MASQUERADE_MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    print_usage; exit 0 ;;
        --domain)     DOMAIN="${2:-}"; shift 2 ;;
        --tunnel)     TUNNEL_TYPE="${2:-}"; shift 2 ;;
        --port)       LISTEN_PORT="${2:-}"; shift 2 ;;
        --masquerade) MASQUERADE_MODE="${2:-}"; shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Dispatch to mode function
case "$MODE" in
    server)    server_main ;;
    client)    client_main ;;
    uninstall) uninstall_main ;;
esac
