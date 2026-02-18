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

# ── MODE STUBS ────────────────────────────────────────────────────────────────
# Filled in by later phases/plans

server_main() {
    log_info "server_main: not yet implemented"
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
