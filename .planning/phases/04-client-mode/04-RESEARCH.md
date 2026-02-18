# Phase 04: Client Mode - Research

**Researched:** 2026-02-18
**Domain:** Bash client-side installation — Chisel binary download (Linux/macOS/WSL), URL/flag/interactive parameter collection, SOCKS5 connection management, GUI client output
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Parameter collection — three input modes (priority order):**
- URL-mode: `./proxyebator.sh client wss://user:pass@host:port/path/` — all params in one string
- CLI-flags: `--host`, `--port`, `--path`, `--pass` — each param separately
- Interactive: if neither URL nor flags provided — prompt each param in turn
- `--socks-port` flag: default 1080, overrides if port occupied

**Operating mode:**
- Foreground only — Chisel runs in the terminal, Ctrl+C stops it
- No background mode, no PID files, no stop command

**GUI instructions after connection:**
- Clients: Throne (Linux), Proxifier (Win/Mac), nekoray (Linux/Win), Firefox/Chrome SOCKS5, Surge (macOS)
- Format: 1-2 lines per client
- Language: Russian
- Verification command: `curl --socks5-hostname localhost:PORT https://ifconfig.me`

**Specific notes:**
- Server already prints client command after install — client must accept that URL format
- SOCKS5 address always 127.0.0.1:PORT (not 0.0.0.0)

### Claude's Discretion

- Order of questions in interactive mode
- URL parsing approach (regex vs built-in bash tools)
- Error handling for failed connection (timeouts, wrong password, server unreachable)
- Port 1080 availability check before launching

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CLI-01 | `./proxyebator.sh client` — downloads binary, connects to server, raises SOCKS5 on localhost:1080 | Chisel client download pattern (same .gz format as server, but OS varies); detect_client_os() needed for darwin vs linux; install to user-writable location without root |
| CLI-02 | Collect connection params: host, port, secret path, password | Three input modes (URL parse, CLI flags, interactive prompts); URL regex verified in bash; flag parsing extends existing while loop |
| CLI-03 | Client support on Linux, macOS, Windows (WSL) | Chisel provides darwin_amd64/arm64 and linux_* assets; WSL = Linux; macOS requires xattr quarantine removal; port check: ss (Linux/WSL) vs lsof (macOS) |
| CLI-04 | Print GUI client setup instructions after successful connection | After chisel daemonizes, print Russian-language SOCKS5 setup for Throne, Proxifier, nekoray, Firefox/Chrome, Surge; include curl verification command |
</phase_requirements>

---

## Summary

Phase 4 implements `client_main()` — the user-facing side of the tunnel. It runs on the user's desktop (Linux, macOS, WSL), not the server. The core workflow is: detect OS/arch, download Chisel client binary (or reuse existing), parse connection params (from URL, CLI flags, or interactive prompts), check the SOCKS5 port is free, launch Chisel in the foreground, and print GUI setup instructions.

The most important difference from server mode is that client mode does NOT require root. This changes where the binary is installed (user-writable path) and how the port check works. The cross-platform requirement (Linux/macOS/WSL) introduces the need for OS-specific download URL construction and a macOS Gatekeeper workaround. Everything else follows patterns already established in the codebase.

The URL parsing decision is the most technically interesting: the server prints `./proxyebator.sh client wss://user:pass@host:port/path/` after install. The client must parse this wss:// URL into components and then convert `wss://` to `https://` when calling the chisel binary (chisel accepts https:// scheme, not wss://).

**Primary recommendation:** Implement `client_main()` as a linear sequence — `detect_arch()` + `detect_client_os()` → `client_collect_params()` → `client_download_chisel()` → `client_check_socks_port()` → `client_run()` → `client_print_gui_instructions()`. Each function is independently testable and mirrors the server_main() pattern already in the codebase.

---

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Chisel | v1.11.3 (current, verified 2026-02-18) | WebSocket tunnel client with SOCKS5 output | Same binary as server; cross-platform .gz releases for linux and darwin |
| bash | system (3.2+ for macOS compatibility) | Script execution | Already the script language; macOS ships bash 3.2 by default |
| curl | system | Binary download from GitHub; ifconfig.me check | Already required by script; present on all target platforms |
| gunzip | system | Decompress Chisel .gz binary | Built into macOS and all Linux distros |

### Cross-Platform Asset Naming (VERIFIED via GitHub API 2026-02-18)

| Platform | uname -s | uname -m | Chisel asset suffix |
|----------|----------|----------|---------------------|
| Linux amd64 | Linux | x86_64 | `linux_amd64.gz` |
| Linux arm64 | Linux | aarch64 | `linux_arm64.gz` |
| macOS Intel | Darwin | x86_64 | `darwin_amd64.gz` |
| macOS Apple Silicon | Darwin | arm64 | `darwin_arm64.gz` |
| WSL (any) | Linux | x86_64 or aarch64 | same as Linux |

**Key insight:** WSL reports `uname -s = Linux` — it is treated identically to native Linux. No WSL detection needed.

**Windows native** (not WSL): `.zip` assets exist but bash is not available natively. WSL covers the Windows use case.

### Chisel Client Command Syntax (VERIFIED from tunnel-reference.md)

```bash
# Basic connection (SOCKS5 on default port 1080)
chisel client \
  --auth "USER:PASS" \
  --keepalive 25s \
  https://HOST:PORT/SECRET_PATH/ \
  socks

# Custom SOCKS5 port
chisel client \
  --auth "USER:PASS" \
  --keepalive 25s \
  https://HOST:PORT/SECRET_PATH/ \
  1080:socks     # or: 127.0.0.1:1080:socks
```

**Critical flag notes:**
- `socks` tunnel arg → SOCKS5 on 127.0.0.1:1080
- `PORT:socks` → SOCKS5 on 127.0.0.1:PORT (custom port)
- `--auth "USER:PASS"` in quotes — mandatory
- `--keepalive 25s` — prevents Cloudflare CDN 100s timeout
- Trailing slash in URL — mandatory (nginx redirects without it; chisel cannot follow 301)
- `https://` scheme (not `wss://` — chisel internally treats them equivalently but https:// is the canonical form per all documentation)

**Confidence:** HIGH — verified from tunnel-reference.md (production-validated) and PROXY-GUIDE.md.

---

## Architecture Patterns

### Recommended client_main() Structure

```
client_main()
├── detect_arch()                      (already exists in Phase 1)
├── detect_client_os()                 (NEW — returns "linux" or "darwin")
├── client_collect_params()            (NEW — URL/flags/interactive)
│   ├── client_parse_url()             (if positional arg is wss:// URL)
│   ├── client_collect_via_flags()     (if --host/--pass/etc set)
│   └── client_collect_interactive()   (prompts for each param)
├── client_download_chisel()           (NEW — adapts server download for client OS)
├── client_check_socks_port()          (NEW — checks port, prompts if occupied)
├── client_run()                       (NEW — execs chisel in foreground)
└── client_print_gui_instructions()    (NEW — prints GUI setup after Ctrl+C or error)
```

### Pattern 1: OS Detection for Client (NEW — not in server path)

**What:** Detect Linux vs Darwin for correct Chisel asset naming
**When to use:** Before downloading binary; servers are always Linux, clients may be Darwin

```bash
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
```

**Confidence:** HIGH — uname -s is POSIX; Linux/Darwin are the only two targets per requirements.

### Pattern 2: URL Parsing — wss:// Scheme

**What:** Parse `wss://USER:PASS@HOST:PORT/PATH/` into individual components
**When to use:** When first positional arg after `client` matches `wss://` or `https://`

```bash
client_parse_url() {
    local url="$1"

    # Extract user (before first colon after scheme)
    CLIENT_USER=$(printf '%s' "$url" | sed -E 's|wss?://([^:@]*).*|\1|')

    # Extract password (between first colon after user and @)
    CLIENT_PASS=$(printf '%s' "$url" | sed -E 's|wss?://[^:@]*:([^@]*)@.*|\1|')

    # Extract host (between @ and : or /)
    CLIENT_HOST=$(printf '%s' "$url" | sed -E 's|wss?://[^@]*@([^:/]+).*|\1|')

    # Extract port (optional — default to 443 if not present)
    if printf '%s' "$url" | grep -qE 'wss?://[^@]*@[^:]+:[0-9]+'; then
        CLIENT_PORT=$(printf '%s' "$url" | sed -E 's|wss?://[^@]*@[^:]*:([0-9]+)/.*|\1|')
    else
        CLIENT_PORT=443
    fi

    # Extract path (everything after host:port or host, normalized with trailing slash)
    CLIENT_PATH=$(printf '%s' "$url" | sed -E 's|wss?://[^@]*@[^/]*(/.*)|\1|')
    # Ensure trailing slash
    [[ "$CLIENT_PATH" == */ ]] || CLIENT_PATH="${CLIENT_PATH}/"

    # Validate all components extracted
    [[ -n "$CLIENT_USER" ]] || die "Could not parse user from URL: $url"
    [[ -n "$CLIENT_PASS" ]] || die "Could not parse password from URL: $url"
    [[ -n "$CLIENT_HOST" ]] || die "Could not parse host from URL: $url"
    [[ -n "$CLIENT_PATH" ]] || die "Could not parse path from URL: $url"

    log_info "URL parsed: host=${CLIENT_HOST} port=${CLIENT_PORT} path=${CLIENT_PATH} user=${CLIENT_USER}"
}
```

**Verified:** Tested with `wss://proxyebator:mytoken@example.com:443/abcdef1234567890/` and `wss://proxyebator:mytoken@example.com/secretpath/` (no-port case) — both parse correctly. Uses `sed -E` which is POSIX-extended available on Linux and macOS.

**Confidence:** HIGH — tested in bash on Linux.

### Pattern 3: CLI Flag Collection for Client

**What:** Collect params from `--host`, `--port`, `--path`, `--pass`, `--socks-port` flags
**When to use:** When flags are present but no URL argument

Phase 4 must add new global variables and extend the CLI flag parser. The existing parser ends with `*) die "Unknown option: $1"` — this must be extended before Phase 4 to accept client-mode flags, or handled in client_main() before the main dispatch loop runs.

**New globals to initialize:**
```bash
# At top of flag initialization section (alongside DOMAIN, TUNNEL_TYPE, etc.)
CLIENT_HOST=""
CLIENT_PORT=""
CLIENT_PATH=""
CLIENT_PASS=""
CLIENT_USER=""
CLIENT_SOCKS_PORT=""
CLIENT_URL=""        # positional wss:// arg if provided
```

**Extended flag parser:**
```bash
# Add to existing while loop:
--host)       CLIENT_HOST="${2:-}";       shift 2 ;;
--port)       CLIENT_PORT="${2:-}";       shift 2 ;;
--path)       CLIENT_PATH="${2:-}";       shift 2 ;;
--pass)       CLIENT_PASS="${2:-}";       shift 2 ;;
--socks-port) CLIENT_SOCKS_PORT="${2:-}"; shift 2 ;;
```

**Positional URL detection:** Add before the flag loop, after extracting MODE:
```bash
# If first remaining arg looks like a URL, capture it
if [[ $# -gt 0 && "$1" =~ ^wss?:// ]]; then
    CLIENT_URL="$1"
    shift
fi
```

**Confidence:** HIGH — follows existing flag-parsing pattern exactly.

### Pattern 4: Interactive Parameter Collection

**What:** Prompt for each connection parameter in turn
**When to use:** When no URL and no CLI flags provided

**Recommended question order:**
1. Host (required, no default)
2. Port (default: 443)
3. Secret path (required, no default)
4. Password (required, no default)

```bash
client_collect_interactive() {
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
        # Normalize: ensure leading/trailing slashes
        [[ "$CLIENT_PATH" == /* ]] || CLIENT_PATH="/${CLIENT_PATH}"
        [[ "$CLIENT_PATH" == */ ]] || CLIENT_PATH="${CLIENT_PATH}/"
    fi

    if [[ -z "${CLIENT_PASS:-}" ]]; then
        printf "${CYAN}[?]${NC} Пароль (токен авторизации): "
        read -r CLIENT_PASS
        [[ -n "$CLIENT_PASS" ]] || die "Пароль обязателен"
    fi

    # AUTH_USER defaults to "proxyebator" if not set (server always uses this)
    CLIENT_USER="${CLIENT_USER:-proxyebator}"
}
```

**Confidence:** HIGH — follows established prompt pattern from server mode.

### Pattern 5: Client Binary Download (Cross-Platform)

**What:** Download Chisel for client OS/arch; reuse existing binary if present
**When to use:** In client_download_chisel(), after detect_arch() and detect_client_os()

```bash
client_download_chisel() {
    local install_dir

    # Reuse existing binary if already in PATH
    if command -v chisel &>/dev/null; then
        log_info "chisel already installed: $(chisel --version 2>&1 | head -1)"
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
```

**Confidence:** HIGH — asset naming verified from live GitHub API (darwin_amd64.gz, darwin_arm64.gz confirmed). xattr approach is standard macOS development pattern.

### Pattern 6: SOCKS Port Availability Check

**What:** Check if SOCKS_PORT is free before launching chisel; prompt or auto-select if occupied
**When to use:** After params collected, before client_run()

```bash
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
```

**Confidence:** HIGH — `ss` on Linux/WSL; `lsof` on macOS; both are standard and always present.

### Pattern 7: Launch Chisel in Foreground

**What:** Build chisel command and exec it in foreground; print instructions before exec
**When to use:** After all params collected and port is free

```bash
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
```

**Note on exec:** Using `exec` replaces the shell with chisel — this is the correct pattern for foreground-only mode. The shell exits when chisel exits. Ctrl+C goes directly to chisel's process group.

**Confidence:** HIGH — exec pattern is established bash idiom for foreground daemon replacement.

### Pattern 8: GUI Client Instructions Output

**What:** Print compact SOCKS5 setup for major GUI clients; in Russian
**When to use:** After port is verified but before launching chisel (user needs this info)

```bash
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
```

**Confidence:** HIGH — client list matches CONTEXT.md locked decisions.

### Pattern 9: Update server_print_connection_info to Print wss:// URL

**What:** Server must print the proxyebator.sh client URL format after install
**When to use:** In server_print_connection_info() (already exists in proxyebator.sh)
**Why:** CONTEXT says "сервер печатает готовую команду" — currently it prints raw chisel command

```bash
# Add to server_print_connection_info(), after the chisel command block:
printf "  ${BOLD}Команда для клиентской машины:${NC}\n"
printf "  ${CYAN}./proxyebator.sh client wss://%s:%s@%s:%s/%s/${NC}\n" \
    "${AUTH_USER}" "${AUTH_TOKEN}" "${DOMAIN}" "${LISTEN_PORT}" "${SECRET_PATH}"
printf "\n"
```

**Confidence:** HIGH — format matches CONTEXT.md URL-mode spec.

### Anti-Patterns to Avoid

- **Running client mode as root:** Client doesn't need root; binary installs to ~/.local/bin if /usr/local/bin is not writable. No `check_root()` call in client_main().
- **Hardcoding `linux` in download URL:** Must detect `uname -s` for darwin vs linux. Server hardcodes linux (VPS), client must detect (desktop).
- **Using `wss://` scheme when calling chisel:** Chisel documentation uses `https://`. Always convert internally.
- **Omitting trailing slash in chisel URL:** Nginx returns 301 redirect; chisel client cannot follow HTTP redirects.
- **Backgrounding chisel with `&`:** CONTEXT decision is foreground-only. No `&`, no nohup, no PID file.
- **Not removing macOS quarantine:** Chisel binary downloaded from GitHub is quarantined on macOS 12+. Without `xattr -d com.apple.quarantine`, macOS refuses to execute it.
- **Using `-r` flag with `read` for passwords on macOS:** macOS bash 3.2 supports `read -r` but not `read -s` (silent). If password masking is desired, note the bash version limitation.
- **Not normalizing path with trailing slash:** User may omit trailing slash in interactive mode. Always normalize before building chisel URL.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SOCKS5 proxy | Custom SOCKS5 daemon | Chisel `socks` tunnel arg | Chisel handles all SOCKS5 framing, auth, DNS proxying |
| URL parsing | Full RFC 3986 parser in bash | sed -E regex extraction | Structured URL with fixed schema; regex is sufficient and portable |
| Port availability | Custom TCP socket check | `ss -tlnp` / `lsof -i` | System tools, already present, no dependencies |
| macOS binary signing | Re-signing the binary | `xattr -d com.apple.quarantine` | Removes quarantine; Gatekeeper only requires signing for App Store distribution |
| Interactive password masking | stty -echo dance | Accept visible input or skip masking | bash 3.2 (macOS default) lacks `read -s`; masking is optional for a CLI tool |

---

## Common Pitfalls

### Pitfall 1: macOS Gatekeeper Blocks Downloaded Binary

**What goes wrong:** On macOS 12+ (Monterey and later), `chisel` fails to execute with: "cannot be opened because the developer cannot be verified" or similar Gatekeeper error.
**Why it happens:** Binaries downloaded from the internet receive a quarantine extended attribute (`com.apple.quarantine`). macOS refuses to run quarantined unsigned binaries.
**How to avoid:** After downloading and before `chmod +x`, run: `xattr -d com.apple.quarantine /tmp/chisel_client 2>/dev/null || true`. The `|| true` is needed because the attribute may not be present on Linux/WSL where xattr is not available.
**Warning signs:** Script runs successfully but chisel exits immediately with a Gatekeeper error dialog. `xattr -l /path/to/chisel` shows `com.apple.quarantine` attribute.

**Confidence:** HIGH — documented macOS behavior for unsigned downloaded binaries since macOS 10.15.

### Pitfall 2: wss:// Scheme Not Converted to https:// for Chisel

**What goes wrong:** Chisel client errors out with protocol error or silently uses wrong connection type.
**Why it happens:** The proxyebator wss:// URL format is user-friendly but chisel's canonical scheme is https:// for TLS WebSocket connections.
**How to avoid:** Always build `chisel_url="https://${CLIENT_HOST}:${CLIENT_PORT}${CLIENT_PATH}"` regardless of whether user provided wss:// or https:// in the URL argument.
**Warning signs:** Chisel client logs show connection error or protocol negotiation failure.

**Confidence:** MEDIUM — chisel documentation uses https://; both may work internally but https:// is the safe canonical form.

### Pitfall 3: Trailing Slash Missing from Chisel URL

**What goes wrong:** nginx returns HTTP 301 redirect to the path with trailing slash. Chisel client cannot follow HTTP redirects (WebSocket upgrade cannot redirect).
**Why it happens:** nginx's `location /SECRET/` block triggers a 301 for requests to `/SECRET` (without trailing slash).
**How to avoid:** Always normalize `CLIENT_PATH` to have a trailing slash. Check in both URL parser and interactive prompt.
**Warning signs:** Chisel logs show HTTP 301 response. Connection immediately fails.

**Confidence:** HIGH — documented in tunnel-reference.md and PROXY-GUIDE.md (production-validated).

### Pitfall 4: Port 1080 Already in Use

**What goes wrong:** Chisel exits immediately with "address already in use" error.
**Why it happens:** Another SOCKS proxy (shadowsocks, another chisel instance, etc.) is already on port 1080.
**How to avoid:** Check before launching; offer alternative port (1081, 1082, etc.) or prompt for `--socks-port`.
**Warning signs:** Chisel exits with "bind: address already in use". `ss -tlnp | grep :1080` shows existing listener.

**Confidence:** HIGH — standard port conflict pattern.

### Pitfall 5: PATH Not Updated After Installing to ~/.local/bin

**What goes wrong:** After client_download_chisel() installs to ~/.local/bin, the `chisel` command is not found because ~/.local/bin is not in PATH.
**Why it happens:** ~/.local/bin is the XDG standard location but not automatically in PATH on all distros or fresh macOS installs.
**How to avoid:** (a) Set CHISEL_BIN to the full path in client_download_chisel() and use that variable instead of bare `chisel` in client_run(). (b) Log a warning if PATH doesn't include the install dir.
**Warning signs:** `command -v chisel` returns empty after install. client_run() fails with "chisel: command not found".

**Confidence:** HIGH — CHISEL_BIN variable pattern avoids this entirely.

### Pitfall 6: Interactive Prompt Blocks in Non-Interactive Mode

**What goes wrong:** When run from a script or CI (e.g., AI agent mode), `read` hangs waiting for input that never comes.
**Why it happens:** `read -r` on a non-interactive stdin waits forever.
**How to avoid:** Check `[[ -t 0 ]]` to detect non-interactive stdin. If stdin is not a terminal AND params are missing, `die` with a helpful message listing required flags.
**Warning signs:** Script hangs with no output after "Запуск в интерактивном режиме".

**Confidence:** MEDIUM — pattern from server mode; bash behavior on non-tty stdin is well-established.

### Pitfall 7: Client Mode Accidentally Requires Root

**What goes wrong:** User runs `./proxyebator.sh client` without sudo and the script fails because client_main() tries to write to /usr/local/bin (which requires root on most Linux distros).
**Why it happens:** Reusing server's install path without checking write permission.
**How to avoid:** In client_download_chisel(), check `[[ -w "/usr/local/bin" ]]` before trying to write there. Fall back to `~/.local/bin` if not writable. Never call `check_root()` from client_main().
**Warning signs:** "Permission denied" when moving binary to /usr/local/bin.

**Confidence:** HIGH — root check pattern exists in codebase; client must explicitly skip it.

---

## Code Examples

### Complete client_main() Scaffold

```bash
# Source: Phase 4 design based on server_main() pattern
client_main() {
    detect_arch          # already exists — sets $ARCH
    detect_client_os     # NEW — sets $CLIENT_OS (linux|darwin)
    client_collect_params   # NEW — URL/flags/interactive
    client_download_chisel  # NEW — downloads if needed, sets $CHISEL_BIN
    client_check_socks_port # NEW — validates $SOCKS_PORT
    client_run              # NEW — prints instructions then exec chisel
    # Note: client_run() does exec — code after this line never runs
}
```

### URL Parsing (Tested)

```bash
# Source: tested in bash 2026-02-18
# Handles: wss://user:pass@host:443/path/ and wss://user:pass@host/path/
URL="wss://proxyebator:mytoken123@example.com:2087/abcdef1234567890/"

CLIENT_USER=$(printf '%s' "$URL" | sed -E 's|wss?://([^:@]*).*|\1|')
CLIENT_PASS=$(printf '%s' "$URL" | sed -E 's|wss?://[^:@]*:([^@]*)@.*|\1|')
CLIENT_HOST=$(printf '%s' "$URL" | sed -E 's|wss?://[^@]*@([^:/]+).*|\1|')

if printf '%s' "$URL" | grep -qE 'wss?://[^@]*@[^:]+:[0-9]+'; then
    CLIENT_PORT=$(printf '%s' "$URL" | sed -E 's|wss?://[^@]*@[^:]*:([0-9]+)/.*|\1|')
else
    CLIENT_PORT=443
fi

CLIENT_PATH=$(printf '%s' "$URL" | sed -E 's|wss?://[^@]*@[^/]*(/.*)|\1|')
[[ "$CLIENT_PATH" == */ ]] || CLIENT_PATH="${CLIENT_PATH}/"

# Result: user=proxyebator pass=mytoken123 host=example.com port=2087 path=/abcdef1234567890/
```

### macOS Gatekeeper Removal

```bash
# Source: macOS developer documentation pattern
# Run on macOS only; safe no-op on Linux (xattr may not exist)
if [[ "${CLIENT_OS}" == "darwin" ]]; then
    xattr -d com.apple.quarantine /tmp/chisel_client 2>/dev/null || true
fi
```

### SOCKS Port Check (Cross-Platform)

```bash
# Source: ss (Linux/WSL) + lsof (macOS) cross-platform pattern
_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v lsof &>/dev/null; then
        lsof -i ":${port}" 2>/dev/null | grep -q LISTEN
    else
        return 1  # Cannot check; assume free
    fi
}
```

### Chisel Client URL Construction

```bash
# Source: tunnel-reference.md + tested pattern
# Input params: CLIENT_HOST, CLIENT_PORT, CLIENT_PATH, CLIENT_USER, CLIENT_PASS, SOCKS_PORT

chisel_url="https://${CLIENT_HOST}:${CLIENT_PORT}${CLIENT_PATH}"

# SOCKS arg: "socks" for 1080, "PORT:socks" for custom
if [[ "${SOCKS_PORT}" == "1080" ]]; then
    socks_arg="socks"
else
    socks_arg="${SOCKS_PORT}:socks"
fi

# Launch:
exec "${CHISEL_BIN:-chisel}" client \
    --auth "${CLIENT_USER}:${CLIENT_PASS}" \
    --keepalive 25s \
    "${chisel_url}" \
    "${socks_arg}"
```

---

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|------------------|-------|
| Install binary to /usr/local/bin (requires root) | Check writability; fall back to ~/.local/bin | Client mode must work without sudo |
| Darwin binary required manual download + PATH setup | Script downloads and installs automatically | Darwin assets available since Chisel v1.x |
| No Gatekeeper handling | xattr -d com.apple.quarantine after download | macOS 12+ requirement; safe no-op elsewhere |
| Raw chisel command printed after server install | wss:// URL format for proxyebator.sh client | User-friendly; one command to copy-paste |

---

## Open Questions

1. **Client_user default: always "proxyebator"?**
   - What we know: server hardcodes `AUTH_USER="proxyebator"` in server_setup_auth()
   - What's unclear: Should client default to "proxyebator" when user field is not set (interactive mode only asks for password, not user)?
   - Recommendation: Default `CLIENT_USER="proxyebator"` in client_collect_interactive(). Advanced users using custom auth setups can use URL mode or `--user` flag (v2). For v1, always default to "proxyebator" to match server output.

2. **What happens when exec fails (chisel can't connect)?**
   - What we know: `exec chisel client ...` replaces the shell; if chisel exits with error, shell also exits
   - What's unclear: Should we print GUI instructions before exec (user can see them) or after (too late)?
   - Recommendation: Print GUI instructions BEFORE exec — user can see them while chisel is running. If chisel fails immediately, they've already seen the instructions.

3. **Should server_print_connection_info be updated in Phase 4?**
   - What we know: CONTEXT says "сервер печатает готовую команду ./proxyebator.sh client wss://..." — currently not the case
   - What's unclear: Is this a Phase 4 task (server_print_connection_info update) or already handled?
   - Recommendation: Yes — Phase 4 should update server_print_connection_info() to add the wss:// URL line. This makes the client mode discoverable from the server output. Low-risk change, high user-experience value.

4. **Non-interactive detection on the client side**
   - What we know: Server uses `CLI_MODE` boolean; client should do same
   - What's unclear: What if user provides --host and --pass but not --path via CLI? Should script prompt for the missing value or fail?
   - Recommendation: Prompt for each missing value individually, regardless of whether other values came from CLI. Same "check CLI var first, prompt only if empty" pattern used throughout server mode.

---

## Sources

### Primary (HIGH confidence)

- `/home/kosya/vibecoding/proxyebator/tunnel-reference.md` — Production deployment reference: client command syntax, macOS install steps, asset format (2026-02-18)
- `/home/kosya/vibecoding/proxyebator/PROXY-GUIDE.md` — Architecture guide with client checklist, Throne/Proxifier/nekoray instructions, SOCKS5 pitfalls (2026-02-18)
- Live GitHub API `jpillora/chisel` releases — v1.11.3 current; darwin_amd64.gz and darwin_arm64.gz confirmed; linux_* confirmed (2026-02-18)
- `/home/kosya/vibecoding/proxyebator/proxyebator.sh` — Existing detect_arch(), flag parser, server_print_connection_info() patterns (verified)
- Bash URL parsing — sed -E regex tested live in bash on Linux (2026-02-18)

### Secondary (MEDIUM confidence)

- `/home/kosya/vibecoding/proxyebator/.planning/research/PITFALLS.md` — Pitfall catalogue (server-focused but some client pitfalls documented)
- `/home/kosya/vibecoding/proxyebator/.planning/research/STACK.md` — Client command syntax, autostart service example
- macOS Gatekeeper behavior — xattr -d com.apple.quarantine pattern is standard macOS developer practice; confirmed from system documentation

### Tertiary (LOW confidence)

- Chisel SOCKS custom port syntax (`PORT:socks`) — From tunnel-reference.md (production usage), not verified against chisel `--help` output; verify before implementing

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Chisel assets verified via live GitHub API; darwin assets confirmed; bash patterns from existing codebase
- Architecture patterns: HIGH — URL parsing tested in bash; cross-platform port check uses system tools; follows existing server_main() structure exactly
- Pitfalls: HIGH/MEDIUM — macOS Gatekeeper (HIGH, documented behavior); wss:// conversion (MEDIUM, both may work); others HIGH from production reference

**Research date:** 2026-02-18
**Valid until:** 2026-08-18 (Chisel release format stable; darwin assets stable; re-verify Gatekeeper behavior if targeting macOS 15+)
