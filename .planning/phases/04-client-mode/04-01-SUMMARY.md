---
phase: 04-client-mode
plan: 01
subsystem: cli
tags: [bash, chisel, socks5, client, url-parsing, cross-platform]

# Dependency graph
requires:
  - phase: 01-script-foundation
    provides: detect_arch(), while+case CLI parser, log helpers, die()
  - phase: 02-server-core
    provides: flag parser structure, DOMAIN/TUNNEL_TYPE/LISTEN_PORT/MASQUERADE_MODE pattern
provides:
  - CLIENT_HOST, CLIENT_PORT, CLIENT_PATH, CLIENT_PASS, CLIENT_USER, CLIENT_SOCKS_PORT, CLIENT_URL global variables
  - detect_client_os() — Linux vs Darwin detection via uname -s
  - client_parse_url() — pure-bash wss:// URL parsing into 5 components
  - client_collect_interactive() — Russian-language prompts with non-interactive detection
  - client_collect_params() — orchestrates URL / CLI-flags / interactive input modes
  - client_main() stub wired to detect_arch + detect_client_os + client_collect_params
  - Extended CLI parser with --host, --port (mode-aware), --path, --pass, --socks-port
affects:
  - 04-02 (client_download_chisel, client_check_socks_port, client_run consume CLIENT_* vars and CLIENT_OS)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Pure-bash URL parsing using ${var#*prefix} / ${var%%suffix*} (no sed dependency)
    - Mode-aware flag dispatch: --port sets LISTEN_PORT for server, CLIENT_PORT for client
    - Non-interactive stdin detection via [[ ! -t 0 ]] with die + flag hint message
    - Three-priority input mode orchestration: URL > partial-flags+interactive > full-interactive
    - CLIENT_USER defaults to "proxyebator" to match server hardcoded AUTH_USER

key-files:
  created: []
  modified:
    - proxyebator.sh

key-decisions:
  - "Pure-bash string manipulation for URL parsing (not sed -E): ${var#*://} strips scheme, %%:* splits user, etc. — bash 3.2+ compatible, no external dependency"
  - "Mode-aware --port flag: client mode sets CLIENT_PORT, server mode sets LISTEN_PORT — single flag, context-sensitive behavior"
  - "Non-interactive stdin check ([[ ! -t 0 ]]) in client_collect_interactive: prevents read hanging in pipes/CI; dies with --host/--path/--pass usage hint"
  - "CLIENT_USER always defaults to proxyebator: server hardcodes AUTH_USER=proxyebator; interactive mode doesn't ask for user, just password"
  - "client_main() has no check_root(): client mode is intended to run without sudo; binary installs to user-writable path in Plan 02"

patterns-established:
  - "Pattern: URL detection before flag loop — if [[ MODE==client && $1 =~ ^(wss|https):// ]] capture into CLIENT_URL before entering while loop"
  - "Pattern: client_collect_params priority chain — CLIENT_URL set? parse URL. CLIENT_HOST or CLIENT_PASS set? flags mode + fill-interactive. Neither? full interactive"
  - "Pattern: path normalization — [[ CLIENT_PATH == /* ]] || prepend /; [[ CLIENT_PATH == */ ]] || append /"

requirements-completed:
  - CLI-02
  - CLI-03

# Metrics
duration: 2min
completed: 2026-02-18
---

# Phase 04 Plan 01: Client Mode Parameter Collection Summary

**Three-mode client parameter collection (URL / CLI flags / interactive) with pure-bash wss:// URL parsing and cross-platform OS detection**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-18T17:20:01Z
- **Completed:** 2026-02-18T17:22:14Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Extended CLI parser with 5 client-specific flags (--host, --port mode-aware, --path, --pass, --socks-port) and wss:// positional URL capture
- Implemented detect_client_os() for Linux/Darwin cross-platform binary selection (Plan 02 uses CLIENT_OS for Chisel asset URL)
- Built client_parse_url() using pure-bash string operators — no sed dependency, bash 3.2+ compatible for macOS
- Built client_collect_interactive() with Russian-language prompts and non-interactive stdin guard
- Wired client_collect_params() orchestrating all three input modes into client_main() (no root check)

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend CLI parser and add client global variables** - `509f769` (feat)
2. **Task 2: Implement detect_client_os, URL parser, and client_collect_params orchestrator** - `652e096` (feat)

## Files Created/Modified

- `proxyebator.sh` — Added client globals, URL positional capture, mode-aware --port, client flag cases, CLIENT OPTIONS in print_usage(), detect_client_os(), client_parse_url(), client_collect_interactive(), client_collect_params(), updated client_main()

## Decisions Made

- Pure-bash string manipulation for URL parsing (not sed -E): `${var#*://}` strips scheme, `${var%%:*}` extracts user, `${var##*:}` extracts port — bash 3.2+ on macOS compatible, avoids sed dependency in URL parsing context
- Mode-aware --port flag: single flag, context-sensitive behavior (CLIENT_PORT vs LISTEN_PORT)
- Non-interactive stdin guard in client_collect_interactive(): [[ ! -t 0 ]] detects pipe/CI and dies with usage hint
- CLIENT_USER always defaults to "proxyebator" — server hardcodes this; client doesn't need to ask

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All CLIENT_* variables populated correctly from URL, flags, or interactive input
- detect_client_os() provides CLIENT_OS (linux|darwin) for Chisel asset URL construction
- client_main() ready to receive client_download_chisel(), client_check_socks_port(), client_run() from Plan 02
- No blockers

---
*Phase: 04-client-mode*
*Completed: 2026-02-18*

## Self-Check: PASSED

- proxyebator.sh: FOUND
- 04-01-SUMMARY.md: FOUND
- Commit 509f769 (Task 1): FOUND
- Commit 652e096 (Task 2): FOUND
- detect_client_os(): FOUND in proxyebator.sh
- client_parse_url(): FOUND in proxyebator.sh
- client_collect_params(): FOUND in proxyebator.sh
- client_collect_interactive(): FOUND in proxyebator.sh
