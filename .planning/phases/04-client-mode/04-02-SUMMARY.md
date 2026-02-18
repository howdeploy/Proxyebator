---
phase: 04-client-mode
plan: 02
subsystem: cli
tags: [bash, chisel, socks5, client, cross-platform, macos, download]

# Dependency graph
requires:
  - phase: 04-client-mode/04-01
    provides: CLIENT_HOST, CLIENT_PORT, CLIENT_PATH, CLIENT_USER, CLIENT_PASS, CLIENT_SOCKS_PORT globals; detect_arch(); detect_client_os(); client_collect_params()
  - phase: 02-server-core
    provides: server_print_connection_info() (updated here with wss:// URL)
provides:
  - client_download_chisel() — cross-platform Chisel binary download to user-writable path, sets CHISEL_BIN
  - client_check_socks_port() — cross-platform SOCKS5 port availability check (ss/lsof)
  - client_print_gui_instructions() — Russian-language SOCKS5 setup for 6 GUI clients
  - client_run() — foreground chisel launch via exec with https:// URL
  - Full client_main() pipeline wired end-to-end
  - server_print_connection_info() updated with wss:// URL for copy-paste
affects:
  - 05-uninstall (uninstall_main stub, no client impact)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Install-location priority: /usr/local/bin (if writable) else ~/.local/bin — no root needed
    - CHISEL_BIN global: avoids PATH issues after installing to ~/.local/bin
    - xattr -d com.apple.quarantine pattern for macOS Gatekeeper bypass
    - exec replaces shell with chisel — foreground-only mode, no PID files
    - socks_arg: "socks" for port 1080, "PORT:socks" for custom port
    - wss:// -> https:// scheme conversion before passing to chisel
    - Nested _port_in_use() helper: ss (Linux/WSL) / lsof (macOS) cross-platform

key-files:
  created: []
  modified:
    - proxyebator.sh

key-decisions:
  - "client_download_chisel() sets CHISEL_BIN global (not PATH manipulation): avoids Pitfall 5 — ~/.local/bin may not be in PATH; CHISEL_BIN ensures client_run() uses exact binary path"
  - "exec in client_run() replaces shell with chisel: foreground-only mode per CONTEXT.md decision; no background, no PID file, Ctrl+C goes directly to chisel"
  - "wss:// -> https:// conversion in client_run(): chisel canonical scheme is https://; conversion is done at exec time, not during URL parsing — user-facing URLs keep wss:// for clarity"
  - "client_print_gui_instructions() called before exec: user sees setup instructions even if chisel fails immediately after launch"

patterns-established:
  - "Pattern: print instructions before exec — GUI setup is visible regardless of chisel exit code"
  - "Pattern: CHISEL_BIN set in download function, used in run function — decouples install location from launch"
  - "Pattern: server_print_connection_info wss:// URL format matches client_parse_url() input — server output is valid client input"

requirements-completed:
  - CLI-01
  - CLI-03
  - CLI-04

# Metrics
duration: 2min
completed: 2026-02-18
---

# Phase 04 Plan 02: Client Binary Download, Port Check, and Tunnel Launch Summary

**Cross-platform Chisel client download to user-writable path with macOS Gatekeeper bypass, foreground tunnel launch via exec, and Russian-language GUI setup instructions for 6 clients**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-18T17:24:59Z
- **Completed:** 2026-02-18T17:27:01Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Implemented client_download_chisel() with cross-platform OS/arch-aware Chisel binary download (linux_amd64, linux_arm64, darwin_amd64, darwin_arm64), install to user-writable location without root, and macOS Gatekeeper quarantine removal
- Implemented client_check_socks_port() with cross-platform port availability check (ss on Linux/WSL, lsof on macOS) and interactive fallback to port 1081 if 1080 is occupied
- Implemented client_print_gui_instructions() with Russian-language SOCKS5 setup for 6 GUI clients: Throne, nekoray, Proxifier, Surge, Firefox, Chrome (SwitchyOmega), plus curl verification command
- Implemented client_run() that converts wss:// to https://, builds socks_arg, prints instructions before exec, and launches chisel in foreground via exec (no background mode)
- Wired client_main() as complete pipeline: detect_arch -> detect_client_os -> client_collect_params -> client_download_chisel -> client_check_socks_port -> client_run (no check_root)
- Updated server_print_connection_info() to print wss:// URL for copy-paste to client machine

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement client_download_chisel, client_check_socks_port, client_print_gui_instructions** - `475ac0b` (feat)
2. **Task 2: Implement client_run, wire client_main, update server wss:// URL** - `bcc1e61` (feat)

## Files Created/Modified

- `proxyebator.sh` — Added client_download_chisel(), client_check_socks_port(), client_print_gui_instructions(), client_run(); replaced client_main() stub with full pipeline; updated server_print_connection_info() with wss:// URL line

## Decisions Made

- client_download_chisel() sets CHISEL_BIN global (not PATH manipulation): avoids PATH issues when installing to ~/.local/bin; client_run() uses CHISEL_BIN directly
- exec in client_run() replaces shell with chisel: foreground-only mode per CONTEXT.md; no background, no PID file, Ctrl+C goes directly to chisel process
- wss:// -> https:// conversion done at exec time in client_run(): user-facing URLs keep wss:// for clarity; chisel gets https:// canonical scheme
- client_print_gui_instructions() called before exec: setup instructions visible regardless of chisel exit outcome

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Phase 4 Completion

Phase 04 (Client Mode) is now complete:
- Plan 01: Parameter collection (URL parsing, CLI flags, interactive prompts, OS detection)
- Plan 02: Binary download, port check, GUI instructions, foreground tunnel launch

`./proxyebator.sh client wss://user:pass@host:443/path/` is now fully functional.

---
*Phase: 04-client-mode*
*Completed: 2026-02-18*

## Self-Check: PASSED

- proxyebator.sh: FOUND
- 04-02-SUMMARY.md: FOUND
- Commit 475ac0b (Task 1): FOUND
- Commit bcc1e61 (Task 2): FOUND
- client_download_chisel(): FOUND in proxyebator.sh
- client_check_socks_port(): FOUND in proxyebator.sh
- client_print_gui_instructions(): FOUND in proxyebator.sh
- client_run(): FOUND in proxyebator.sh
- wss:// URL in server_print_connection_info(): FOUND
