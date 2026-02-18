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
  verify      Run 7-check verification suite (reads /etc/proxyebator/server.conf)

${BOLD}OPTIONS${NC}
  --help, -h          Show this help
  --domain DOMAIN     Server domain name (skips interactive prompt)
  --tunnel TYPE       Tunnel backend: chisel (default) or wstunnel
  --port PORT         Listen port (default: 443)
  --masquerade MODE   Cover site mode: stub | proxy | static (default: stub)

${BOLD}CLIENT OPTIONS${NC}
  --host HOST         Server hostname
  --port PORT         Server port (default: 443)
  --path PATH         Secret tunnel path
  --pass PASSWORD     Auth password/token
  --socks-port PORT   Local SOCKS5 port (default: 1080)

${BOLD}EXAMPLES${NC}
  # Interactive install
  sudo $(basename "$0") server

  # Non-interactive install (AI-agent friendly)
  sudo $(basename "$0") server --domain example.com --tunnel chisel

  # Connect client (URL mode — copy from server output)
  $(basename "$0") client wss://proxyebator:TOKEN@example.com:443/SECRET/

  # Connect client (flag mode)
  $(basename "$0") client --host example.com --port 443 --path /SECRET/ --pass TOKEN

  # Uninstall
  sudo $(basename "$0") uninstall

  # Non-interactive uninstall
  sudo $(basename "$0") uninstall --yes
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

# ── CLIENT OS DETECTION ───────────────────────────────────────────────────────

detect_client_os() {
    local kernel
    kernel="$(uname -s)"
    case "$kernel" in
        Linux)  CLIENT_OS="linux"  ;;
        Darwin) CLIENT_OS="darwin" ;;
        *)      die "Unsupported client OS: ${kernel}. Supported: Linux (including WSL), macOS (Darwin)" ;;
    esac
    log_info "Client OS: ${CLIENT_OS}"
}

# ── CLIENT PARAMETER COLLECTION ───────────────────────────────────────────────

client_parse_url() {
    local url="$1"
    # Strip scheme (wss://, ws://, https://, http://)
    local stripped
    stripped="${url#*://}"

    # user:pass@host:port/path
    CLIENT_USER="${stripped%%:*}"
    local after_user="${stripped#*:}"
    CLIENT_PASS="${after_user%%@*}"
    local after_at="${after_user#*@}"
    # host:port/path or host/path
    local host_port_path="$after_at"
    local host_port="${host_port_path%%/*}"
    CLIENT_PATH="/${host_port_path#*/}"

    if [[ "$host_port" == *:* ]]; then
        CLIENT_HOST="${host_port%%:*}"
        CLIENT_PORT="${host_port##*:}"
    else
        CLIENT_HOST="$host_port"
        CLIENT_PORT="443"
    fi

    # Normalize trailing slash
    [[ "$CLIENT_PATH" == */ ]] || CLIENT_PATH="${CLIENT_PATH}/"

    # Validate
    [[ -n "$CLIENT_USER" ]] || die "Could not parse user from URL: $url"
    [[ -n "$CLIENT_PASS" ]] || die "Could not parse password from URL: $url"
    [[ -n "$CLIENT_HOST" ]] || die "Could not parse host from URL: $url"
    [[ -n "$CLIENT_PATH" && "$CLIENT_PATH" != "/" ]] || die "Could not parse path from URL: $url"

    log_info "URL parsed: host=${CLIENT_HOST} port=${CLIENT_PORT} path=${CLIENT_PATH} user=${CLIENT_USER}"
}

client_collect_interactive() {
    # Non-interactive stdin detection
    if [[ ! -t 0 ]]; then
        if [[ -z "${CLIENT_HOST:-}" || -z "${CLIENT_PATH:-}" || -z "${CLIENT_PASS:-}" ]]; then
            die "Non-interactive mode: missing required params. Use: ./proxyebator.sh client --host HOST --path PATH --pass PASS [--port PORT]"
        fi
    fi

    if [[ -z "${CLIENT_HOST:-}" ]]; then
        printf "${CYAN}[?]${NC} Хост сервера (например: example.com): "
        read -r CLIENT_HOST
        [[ -n "$CLIENT_HOST" ]] || die "Хост обязателен"
    fi

    if [[ -z "${CLIENT_PORT:-}" ]]; then
        printf "${CYAN}[?]${NC} Порт сервера [443]: "
        read -r CLIENT_PORT
        CLIENT_PORT="${CLIENT_PORT:-443}"
    fi

    if [[ -z "${CLIENT_PATH:-}" ]]; then
        printf "${CYAN}[?]${NC} Секретный путь (например: /abc123/): "
        read -r CLIENT_PATH
        [[ -n "$CLIENT_PATH" ]] || die "Путь обязателен"
        # Normalize: ensure leading and trailing slashes
        [[ "$CLIENT_PATH" == /* ]] || CLIENT_PATH="/${CLIENT_PATH}"
        [[ "$CLIENT_PATH" == */ ]] || CLIENT_PATH="${CLIENT_PATH}/"
    fi

    if [[ -z "${CLIENT_PASS:-}" ]]; then
        printf "${CYAN}[?]${NC} Пароль (токен авторизации): "
        read -r CLIENT_PASS
        [[ -n "$CLIENT_PASS" ]] || die "Пароль обязателен"
    fi

    # Default user to "proxyebator" (server always uses this)
    CLIENT_USER="${CLIENT_USER:-proxyebator}"
}

client_collect_params() {
    if [[ -n "${CLIENT_URL:-}" ]]; then
        # Mode 1: URL string (highest priority)
        client_parse_url "$CLIENT_URL"
    elif [[ -n "${CLIENT_HOST:-}" || -n "${CLIENT_PASS:-}" ]]; then
        # Mode 2: CLI flags (at least one flag set)
        CLIENT_PORT="${CLIENT_PORT:-443}"
        CLIENT_USER="${CLIENT_USER:-proxyebator}"
        # Fill in any missing params via interactive
        client_collect_interactive
    else
        # Mode 3: Full interactive
        client_collect_interactive
    fi

    log_info "Connection params: host=${CLIENT_HOST} port=${CLIENT_PORT} path=${CLIENT_PATH}"
}

# ── CLIENT BINARY DOWNLOAD ────────────────────────────────────────────────────

client_download_chisel() {
    local install_dir

    # Reuse existing binary if already in PATH
    if command -v chisel &>/dev/null; then
        log_info "chisel already installed: $(chisel --version 2>&1 | head -1)"
        CHISEL_BIN="$(command -v chisel)"
        return
    fi

    # Determine install location (user-writable, no root needed)
    if [[ -w "/usr/local/bin" ]]; then
        install_dir="/usr/local/bin"
    else
        install_dir="${HOME}/.local/bin"
        mkdir -p "$install_dir"
        # Warn if not in PATH
        case ":${PATH}:" in
            *":${install_dir}:"*) ;;
            *) log_warn "${install_dir} is not in PATH — add: export PATH=\"\$PATH:${install_dir}\"" ;;
        esac
    fi

    local CHISEL_FALLBACK_VER="v1.11.3"
    local CHISEL_VER
    CHISEL_VER=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/jpillora/chisel/releases/latest" \
        | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*') \
        || CHISEL_VER=""

    if [[ -z "$CHISEL_VER" ]]; then
        log_warn "GitHub API unavailable — using fallback version ${CHISEL_FALLBACK_VER}"
        CHISEL_VER="$CHISEL_FALLBACK_VER"
    fi

    # Asset: chisel_X.Y.Z_{linux|darwin}_{amd64|arm64}.gz
    local download_url="https://github.com/jpillora/chisel/releases/download/${CHISEL_VER}/chisel_${CHISEL_VER#v}_${CLIENT_OS}_${ARCH}.gz"
    log_info "Downloading Chisel ${CHISEL_VER} for ${CLIENT_OS}/${ARCH}..."

    curl -fLo /tmp/chisel_client.gz "$download_url" \
        || die "Failed to download Chisel from ${download_url}"

    gunzip -f /tmp/chisel_client.gz
    chmod +x /tmp/chisel_client

    # macOS Gatekeeper: remove quarantine attribute (downloaded binaries are quarantined)
    if [[ "${CLIENT_OS}" == "darwin" ]]; then
        xattr -d com.apple.quarantine /tmp/chisel_client 2>/dev/null || true
        log_info "macOS: quarantine attribute removed from binary"
    fi

    mv /tmp/chisel_client "${install_dir}/chisel"

    # Verify
    "${install_dir}/chisel" --version \
        || die "Chisel binary not working after install"
    log_info "Chisel installed at ${install_dir}/chisel: $("${install_dir}/chisel" --version 2>&1 | head -1)"

    CHISEL_BIN="${install_dir}/chisel"
}

# ── CLIENT SOCKS PORT CHECK ───────────────────────────────────────────────────

client_check_socks_port() {
    SOCKS_PORT="${CLIENT_SOCKS_PORT:-1080}"

    _port_in_use() {
        local p="$1"
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":${p} "
        elif command -v lsof &>/dev/null; then
            lsof -i ":${p}" 2>/dev/null | grep -q LISTEN
        else
            return 1  # Can't check, assume free
        fi
    }

    if _port_in_use "$SOCKS_PORT"; then
        log_warn "Port ${SOCKS_PORT} is already in use"
        printf "${CYAN}[?]${NC} Введите другой порт для SOCKS5 [1081]: "
        read -r SOCKS_PORT
        SOCKS_PORT="${SOCKS_PORT:-1081}"
        if _port_in_use "$SOCKS_PORT"; then
            die "Порт ${SOCKS_PORT} тоже занят. Укажите свободный порт через --socks-port"
        fi
    fi

    log_info "SOCKS5 будет на 127.0.0.1:${SOCKS_PORT}"
}

# ── CLIENT GUI INSTRUCTIONS ───────────────────────────────────────────────────

client_print_gui_instructions() {
    printf "\n${BOLD}=== Параметры SOCKS5 ===${NC}\n"
    printf "  Адрес:    ${CYAN}127.0.0.1${NC}\n"
    printf "  Порт:     ${CYAN}%s${NC}\n" "${SOCKS_PORT}"
    printf "  Протокол: ${CYAN}SOCKS5${NC}\n"
    printf "  DNS:      ${CYAN}через прокси${NC} (SOCKS5 remote DNS)\n"
    printf "\n"
    printf "${BOLD}=== Настройка клиентов ===${NC}\n"
    printf "  ${BOLD}Throne (Linux):${NC}            Профиль → SOCKS → 127.0.0.1:%s\n" "${SOCKS_PORT}"
    printf "  ${BOLD}nekoray (Linux/Windows):${NC}   Server → Add → SOCKS5 → 127.0.0.1:%s\n" "${SOCKS_PORT}"
    printf "  ${BOLD}Proxifier (Win/Mac):${NC}        Proxy Servers → Add → SOCKS Version 5 → 127.0.0.1:%s\n" "${SOCKS_PORT}"
    printf "  ${BOLD}Surge (macOS):${NC}             Proxy → Add → SOCKS5 → 127.0.0.1:%s\n" "${SOCKS_PORT}"
    printf "  ${BOLD}Firefox:${NC}                   Настройки → Прокси → SOCKS v5 → 127.0.0.1:%s → ☑ Proxy DNS\n" "${SOCKS_PORT}"
    printf "  ${BOLD}Chrome (SwitchyOmega):${NC}     Profile → SOCKS5 → 127.0.0.1:%s\n" "${SOCKS_PORT}"
    printf "\n"
    printf "${BOLD}=== Проверка ===${NC}\n"
    printf "  ${CYAN}curl --socks5-hostname localhost:%s https://ifconfig.me${NC}\n" "${SOCKS_PORT}"
    printf "  (должен вернуть IP сервера, не ваш)\n"
    printf "\n"
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
    # Re-run detection: if server.conf already exists, source it to preserve
    # existing secrets (SECRET_PATH, AUTH_TOKEN) and parameters.
    # This prevents generating new credentials that would mismatch the
    # running auth.json and the existing nginx tunnel block.
    if [[ -f /etc/proxyebator/server.conf ]]; then
        log_info "Existing installation detected — loading saved configuration"
        # shellcheck disable=SC1091
        source /etc/proxyebator/server.conf
        # Set variables that server.conf uses different names for
        NGINX_CONF_PATH="${NGINX_CONF:-}"
        log_info "Re-run mode: domain=${DOMAIN:-} port=${LISTEN_PORT:-} tunnel=${TUNNEL_TYPE:-}"
        return
    fi

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

    # Tunnel type: validate CLI flag or default to chisel
    if [[ -z "$TUNNEL_TYPE" ]]; then
        TUNNEL_TYPE="chisel"
    elif [[ "$TUNNEL_TYPE" != "chisel" ]]; then
        die "Tunnel type '${TUNNEL_TYPE}' is not yet supported. Only 'chisel' is available (wstunnel coming in Phase 6)."
    fi

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

    # Re-run mode: skip confirmation if config already exists
    if [[ -f /etc/proxyebator/server.conf ]]; then
        log_info "Re-run mode: skipping installation summary"
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
    if [[ -x /usr/local/bin/chisel ]]; then
        log_info "Chisel already installed: $(/usr/local/bin/chisel --version 2>&1 | head -1)"
        return
    fi

    # Clean up stale temp files from a previous failed download
    rm -f /tmp/chisel.gz /tmp/chisel 2>/dev/null || true

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
    if [[ -f /etc/chisel/auth.json ]]; then
        log_info "Auth file already exists at /etc/chisel/auth.json — skipping generation"
        return
    fi

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
    if systemctl is-active --quiet proxyebator 2>/dev/null; then
        log_info "proxyebator.service is already active — skipping service creation"
        return
    fi

    # TUNNEL-07 compliance: credentials are passed via --authfile, NOT --auth.
    # This ensures AUTH_TOKEN never appears in /proc/PID/cmdline or ps aux output.
    # The auth file /etc/chisel/auth.json is chmod 600, owned by nobody:nogroup.
    # Verification: ps aux | grep chisel shows --authfile path, not credentials.

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
        NGINX_INJECTED="true"
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
        NGINX_INJECTED="false"
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
    if [[ -f /etc/proxyebator/server.conf ]]; then
        log_info "Config already exists at /etc/proxyebator/server.conf — skipping"
        return
    fi

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
NGINX_INJECTED=${NGINX_INJECTED:-false}
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
    printf "  ${BOLD}Команда для клиентской машины:${NC}\n"
    printf "  ${CYAN}./proxyebator.sh client wss://%s:%s@%s:%s/%s/${NC}\n" \
        "${AUTH_USER}" "${AUTH_TOKEN}" "${DOMAIN}" "${LISTEN_PORT}" "${SECRET_PATH}"
    printf "\n"
    printf "  ${BOLD}SOCKS5 proxy will be available at:${NC} 127.0.0.1:1080\n"
    printf "\n"
    printf "  ${BOLD}Server config file:${NC} /etc/proxyebator/server.conf\n"
    printf "\n"
    printf "  ${YELLOW}Note: Use 'socks' (not 'R:socks') --- 'socks' means traffic exits via server.${NC}\n"
    printf "  ${YELLOW}Note: The trailing slash in the URL is required.${NC}\n"
}

# ── VERIFICATION HELPERS ──────────────────────────────────────────────────────
# check_fail does NOT increment fail_count — callers do that inline.
# This is required for TLS check 6's tls_ok sub-condition logic:
# TLS has multiple sub-failures but must only increment fail_count ONCE at the end.

check_pass() {
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

check_fail() {
    printf "${RED}[FAIL]${NC} %s\n" "$1" >&2
}

# ── VERIFICATION MAIN ─────────────────────────────────────────────────────────

verify_main() {
    check_root

    [[ -f /etc/proxyebator/server.conf ]] \
        || die "server.conf not found --- run: sudo ./proxyebator.sh server"
    # shellcheck disable=SC1091
    source /etc/proxyebator/server.conf

    local fail_count=0
    local total_checks=7

    printf "\n${BOLD}=== Verification Suite ===${NC}\n"

    # ── Check 1: systemd service active ───────────────────────────────────────
    if systemctl is-active --quiet proxyebator 2>/dev/null; then
        check_pass "proxyebator.service is active"
    else
        check_fail "proxyebator.service is NOT active"
        systemctl status proxyebator --no-pager --lines=5 >&2 2>/dev/null || true
        printf "  Try: systemctl restart proxyebator\n" >&2
        fail_count=$(( fail_count + 1 ))
    fi

    # ── Check 2: Tunnel port bound to 127.0.0.1 ───────────────────────────────
    if ss -tlnp 2>/dev/null | grep ":${TUNNEL_PORT} " | grep -q '127\.0\.0\.1'; then
        check_pass "Tunnel port ${TUNNEL_PORT} bound to 127.0.0.1"
    else
        check_fail "Tunnel port ${TUNNEL_PORT} NOT bound to 127.0.0.1 — SECURITY RISK"
        ss -tlnp 2>/dev/null | grep ":${TUNNEL_PORT} " >&2 || true
        printf "  Try: systemctl restart proxyebator\n" >&2
        fail_count=$(( fail_count + 1 ))
    fi

    # ── Check 3: Firewall blocks tunnel port ──────────────────────────────────
    # ONE fail_count increment — fw_ok flag aggregates ufw and iptables paths
    local fw_ok=true
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status 2>/dev/null | grep "${TUNNEL_PORT}" | grep -qi "DENY"; then
            check_pass "Firewall: port ${TUNNEL_PORT} DENY rule exists (ufw)"
        else
            check_fail "Firewall: no DENY rule for port ${TUNNEL_PORT} in ufw"
            ufw status 2>/dev/null >&2 || true
            printf "  Try: ufw deny %s/tcp\n" "${TUNNEL_PORT}" >&2
            fw_ok=false
        fi
    else
        if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:${TUNNEL_PORT}"; then
            check_pass "Firewall: port ${TUNNEL_PORT} DROP rule exists (iptables)"
        else
            check_fail "Firewall: no DROP rule for port ${TUNNEL_PORT} in iptables"
            iptables -L INPUT -n 2>/dev/null | head -20 >&2 || true
            printf "  Try: iptables -A INPUT -p tcp --dport %s ! -i lo -j DROP\n" "${TUNNEL_PORT}" >&2
            fw_ok=false
        fi
    fi
    [[ "$fw_ok" == "false" ]] && fail_count=$(( fail_count + 1 ))

    # ── Check 4: Cover site returns HTTP 200 ──────────────────────────────────
    local http_code
    http_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        "https://${DOMAIN}/" 2>/dev/null) || http_code="000"
    if [[ "$http_code" == "200" ]]; then
        check_pass "Cover site https://${DOMAIN}/ returns HTTP 200"
    else
        check_fail "Cover site returned HTTP ${http_code} (expected 200)"
        curl -sk --max-time 10 -v "https://${DOMAIN}/" >/dev/null 2>&1 | head -20 >&2 || true
        printf "  Try: nginx -t && systemctl reload nginx\n" >&2
        fail_count=$(( fail_count + 1 ))
    fi

    # ── Check 5: WebSocket path reachable (VER-02) ────────────────────────────
    # Accept 101 (upgrade ok), 200 (chisel responds), 400 (chisel rejected — proxied OK)
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
        fail_count=$(( fail_count + 1 ))
    fi

    # ── Check 6: TLS certificate validity + chain + renewal timer ─────────────
    # ONE fail_count increment max — tls_ok flag aggregates all sub-conditions
    local tls_ok=true

    if [[ ! -f "${CERT_PATH}" ]]; then
        check_fail "TLS cert file not found: ${CERT_PATH}"
        printf "  Try: certbot certonly --nginx -d %s\n" "${DOMAIN}" >&2
        tls_ok=false
    else
        # checkend semantics: exit 0 = cert valid for 30+ days (PASS); exit 1 = expires soon (FAIL)
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
                # Check renewal timer (handles both certbot.timer and snap.certbot.renew.timer)
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

    # ── Check 7: DNS resolves to server IP ────────────────────────────────────
    # ONE fail_count increment — dns_ok flag aggregates all DNS sub-conditions
    local dns_ok=true
    local server_ip domain_ip dns_resp first_octet
    server_ip=""
    domain_ip=""
    dns_resp=""
    first_octet=""

    server_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) \
        || server_ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null) \
        || server_ip=""

    if [[ -z "$server_ip" ]]; then
        check_fail "Could not determine server public IP — check internet connectivity"
        dns_ok=false
    else
        dns_resp=$(curl -sf --max-time 10 \
            "https://dns.google/resolve?name=${DOMAIN}&type=A" 2>/dev/null) || dns_resp=""
        domain_ip=$(printf '%s' "$dns_resp" \
            | grep -oP '"data"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1) || domain_ip=""

        if [[ -z "$domain_ip" ]]; then
            check_fail "DNS: could not resolve ${DOMAIN} — check DNS A-record"
            dns_ok=false
        elif [[ "$domain_ip" != "$server_ip" ]]; then
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
            dns_ok=false
        else
            check_pass "DNS: ${DOMAIN} resolves to ${server_ip} (correct)"
        fi
    fi
    [[ "$dns_ok" == "false" ]] && fail_count=$(( fail_count + 1 ))

    # ── Summary banner ────────────────────────────────────────────────────────
    local pass_count
    pass_count=$(( total_checks - fail_count ))
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
    verify_main
    local verify_exit=$?
    exit $verify_exit
}

client_run() {
    # Convert wss:// scheme to https:// for chisel (chisel expects https://)
    local chisel_url="https://${CLIENT_HOST}:${CLIENT_PORT}${CLIENT_PATH}"

    # Build SOCKS tunnel argument
    local socks_arg
    if [[ "${SOCKS_PORT}" == "1080" ]]; then
        socks_arg="socks"
    else
        socks_arg="${SOCKS_PORT}:socks"
    fi

    # Print GUI instructions before launching (user sees them even if chisel crashes)
    client_print_gui_instructions

    log_info "Запуск Chisel клиента... (Ctrl+C для остановки)"
    printf "\n"

    # Exec chisel in foreground — replaces shell process; Ctrl+C sends SIGINT to chisel
    local chisel_bin="${CHISEL_BIN:-chisel}"
    exec "${chisel_bin}" client \
        --auth "${CLIENT_USER}:${CLIENT_PASS}" \
        --keepalive 25s \
        "${chisel_url}" \
        "${socks_arg}"
}

client_main() {
    detect_arch
    detect_client_os
    client_collect_params
    client_download_chisel
    client_check_socks_port
    client_run
    # Note: client_run() uses exec — this line never executes
}

# ── UNINSTALL SUB-FUNCTIONS ───────────────────────────────────────────────────

_uninstall_confirm() {
    if [[ "${UNINSTALL_YES:-}" == "true" ]]; then
        return
    fi

    printf "\n${YELLOW}The following will be removed:${NC}\n"
    printf "  ${CYAN}Chisel binary:${NC}    /usr/local/bin/chisel\n"
    printf "  ${CYAN}Auth file:${NC}        /etc/chisel/auth.json\n"
    printf "  ${CYAN}Systemd service:${NC}  /etc/systemd/system/proxyebator.service\n"
    printf "  ${CYAN}Nginx config:${NC}     %s\n" "${NGINX_CONF:-unknown}"
    printf "  ${CYAN}Firewall rules:${NC}   80/tcp ALLOW, %s/tcp ALLOW, 7777/tcp DENY\n" "${LISTEN_PORT:-443}"
    printf "  ${CYAN}Config dir:${NC}       /etc/proxyebator/\n"
    printf "\n${YELLOW}TLS certificate will NOT be removed (Let's Encrypt rate limits).${NC}\n"
    printf "\n"
    printf "${CYAN}[?]${NC} Proceed with uninstall? [y/N]: "
    read -r _confirm
    case "${_confirm:-N}" in
        y|Y|yes|YES) ;;
        *) die "Uninstall aborted by user" ;;
    esac
}

_uninstall_service() {
    if systemctl is-active --quiet proxyebator 2>/dev/null; then
        systemctl stop proxyebator 2>/dev/null || true
        log_info "Stopped proxyebator.service"
    fi
    if systemctl is-enabled --quiet proxyebator 2>/dev/null; then
        systemctl disable proxyebator 2>/dev/null || true
    fi
    if [[ -f /etc/systemd/system/proxyebator.service ]]; then
        rm -f /etc/systemd/system/proxyebator.service
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null || true
        log_info "Removed proxyebator.service"
    else
        log_info "proxyebator.service: not found, skipping"
    fi
}

_uninstall_binary() {
    if [[ -f /usr/local/bin/chisel ]]; then
        rm -f /usr/local/bin/chisel
        log_info "Removed /usr/local/bin/chisel"
    else
        log_info "Chisel binary: not found, skipping"
    fi
    if [[ -f /etc/chisel/auth.json ]]; then
        rm -f /etc/chisel/auth.json
        log_info "Removed /etc/chisel/auth.json"
    fi
    rmdir /etc/chisel 2>/dev/null || true
}

_uninstall_nginx() {
    local nginx_conf="${NGINX_CONF:-}"
    if [[ -z "$nginx_conf" ]]; then
        log_info "NGINX_CONF not set in server.conf — skipping nginx cleanup"
        return
    fi

    if [[ "${NGINX_INJECTED:-false}" == "true" ]]; then
        # Injected into pre-existing config — remove only the tunnel block, not the file
        if [[ -f "$nginx_conf" ]] && grep -q "proxyebator-tunnel-block-start" "$nginx_conf" 2>/dev/null; then
            sed -i '/# proxyebator-tunnel-block-start/,/# proxyebator-tunnel-block-end/d' "$nginx_conf"
            log_info "Removed tunnel block from existing nginx config: ${nginx_conf}"
        else
            log_info "Tunnel block not found in ${nginx_conf} — already removed or never injected"
        fi
    else
        # proxyebator created this config — delete the file and symlink
        if [[ -f "$nginx_conf" ]]; then
            rm -f "$nginx_conf"
            log_info "Removed nginx config: ${nginx_conf}"
        else
            log_info "Nginx config not found: ${nginx_conf} — skipping"
        fi
        # Remove symlink if NGINX_CONF_LINK is set (Debian/Ubuntu)
        if [[ -n "${NGINX_CONF_LINK:-}" ]]; then
            rm -f "${NGINX_CONF_LINK}/$(basename "${nginx_conf}")" 2>/dev/null || true
        fi
        # Remove timestamped backup files
        rm -f "${nginx_conf}.bak."* 2>/dev/null || true
    fi

    # Reload nginx if it is running
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t 2>/dev/null && systemctl reload nginx || true
    fi
}

_uninstall_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow "${LISTEN_PORT:-443}/tcp" 2>/dev/null || true
        ufw delete deny 7777/tcp 2>/dev/null || true
        log_info "Firewall rules removed via ufw"
    else
        iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p tcp --dport "${LISTEN_PORT:-443}" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 7777 ! -i lo -j DROP 2>/dev/null || true
        log_info "Firewall rules removed via iptables"
    fi
}

_uninstall_config() {
    rm -f /etc/proxyebator/server.conf
    rmdir /etc/proxyebator 2>/dev/null || true
    log_info "Removed /etc/proxyebator/"
}

# ── UNINSTALL MAIN ────────────────────────────────────────────────────────────

uninstall_main() {
    check_root
    detect_os   # needed for NGINX_CONF_LINK

    [[ -f /etc/proxyebator/server.conf ]] \
        || die "No installation found at /etc/proxyebator/server.conf"
    # shellcheck disable=SC1091
    source /etc/proxyebator/server.conf

    _uninstall_confirm
    _uninstall_service
    _uninstall_binary
    _uninstall_nginx
    _uninstall_firewall
    _uninstall_config

    log_info "Uninstall complete"
    log_info "TLS certificate preserved at: /etc/letsencrypt/live/${DOMAIN:-unknown}/"
    log_info "To remove certificate: certbot delete --cert-name ${DOMAIN:-unknown}"
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
    server|client|uninstall|verify) MODE="$1"; shift ;;
    --help|-h) print_usage; exit 0 ;;
    *) print_usage; die "Unknown command: $1" ;;
esac

# Parse remaining flags (non-interactive mode support — values used by Phase 2+)
DOMAIN=""
TUNNEL_TYPE=""
LISTEN_PORT=""
MASQUERADE_MODE=""
CLIENT_HOST=""
CLIENT_PORT=""
CLIENT_PATH=""
CLIENT_PASS=""
CLIENT_USER=""
CLIENT_SOCKS_PORT=""
CLIENT_URL=""
UNINSTALL_YES=""

# Capture positional wss:// URL for client mode (before flag parsing)
if [[ "$MODE" == "client" && $# -gt 0 && "$1" =~ ^(wss|https):// ]]; then
    CLIENT_URL="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    print_usage; exit 0 ;;
        --domain)     DOMAIN="${2:-}"; shift 2 ;;
        --tunnel)     TUNNEL_TYPE="${2:-}"; shift 2 ;;
        --port)
            if [[ "$MODE" == "client" ]]; then
                CLIENT_PORT="${2:-}"
            else
                LISTEN_PORT="${2:-}"
            fi
            shift 2 ;;
        --masquerade) MASQUERADE_MODE="${2:-}"; shift 2 ;;
        --host)       CLIENT_HOST="${2:-}"; shift 2 ;;
        --path)       CLIENT_PATH="${2:-}"; shift 2 ;;
        --pass)       CLIENT_PASS="${2:-}"; shift 2 ;;
        --socks-port) CLIENT_SOCKS_PORT="${2:-}"; shift 2 ;;
        --yes)        UNINSTALL_YES="true"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Dispatch to mode function
case "$MODE" in
    server)    server_main ;;
    client)    client_main ;;
    uninstall) uninstall_main ;;
    verify)    check_root; verify_main; exit $? ;;
esac
