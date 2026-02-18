---
phase: 06-wstunnel-backend-and-readme
plan: 01
subsystem: infra
tags: [wstunnel, chisel, bash, systemd, nginx, socks5, websocket]

# Dependency graph
requires:
  - phase: 05-uninstall-and-robustness
    provides: server_collect_params, server_configure_firewall, _uninstall_binary pattern
  - phase: 04-client-mode
    provides: client_collect_params, client_download_chisel, client_run patterns
  - phase: 02-server-core
    provides: generate_tunnel_location_block, server_configure_firewall, server_save_config

provides:
  - wstunnel backend for server and client modes
  - server_download_wstunnel function with .tar.gz extraction
  - server_create_systemd_wstunnel with ws://127.0.0.1:7778
  - client_download_wstunnel and client_run_wstunnel with -L socks5://
  - TUNNEL_PORT variable controlling port in nginx, firewall, uninstall
  - Interactive tunnel type prompt (chisel/wstunnel) in server_collect_params

affects:
  - 06-02 (README phase — documents both chisel and wstunnel backends)
  - 03-verification-suite (verify_main reads TUNNEL_PORT from server.conf — already uses it correctly)

# Tech tracking
tech-stack:
  added: [wstunnel v10+ (erebe/wstunnel GitHub releases)]
  patterns:
    - TUNNEL_PORT variable abstraction: all shared functions (nginx, firewall, uninstall) use TUNNEL_PORT rather than hardcoded port
    - TUNNEL_TYPE branching in server_main and client_main: parallel code paths for each backend
    - Fallback version pattern: WSTUNNEL_FALLBACK_VER="v10.5.2" when GitHub API unavailable

key-files:
  created: []
  modified:
    - proxyebator.sh

key-decisions:
  - "wstunnel systemd unit binds to ws://127.0.0.1:7778 (no --restrict-http-upgrade-path-prefix): nginx location block IS the auth gate; the flag breaks when nginx strips path with trailing-slash proxy_pass"
  - "wstunnel uses .tar.gz (not .gz like chisel): extraction uses tar -xzf, not gunzip"
  - "wstunnel SOCKS5 is client-side only via -L socks5://127.0.0.1:PORT: server is a pure WebSocket relay with no --socks5 flag"
  - "TUNNEL_PORT set in server_main before server_show_summary: ensures summary displays correct port and nginx/firewall/save_config all see correct value"
  - "CLIENT_PASS made optional for wstunnel in client_collect_interactive: path-based auth requires no username/password"
  - "wstunnel binary name is wstunnel (not wstunnel-cli): cli name is Docker entrypoint only, release tarballs always use wstunnel"

patterns-established:
  - "TUNNEL_PORT abstraction: shared functions (nginx, firewall, uninstall) use ${TUNNEL_PORT} or ${TUNNEL_PORT:-7777} — never hardcoded port numbers"
  - "Backend branching pattern: if [[ TUNNEL_TYPE == wstunnel ]]; then ... wstunnel functions; else ... chisel functions; fi"
  - "Download pattern for .tar.gz: curl → tar -xzf → chmod +x → mv (different from chisel's curl → gunzip pattern)"

requirements-completed:
  - TUNNEL-04

# Metrics
duration: 3min
completed: 2026-02-18
---

# Phase 06 Plan 01: wstunnel Backend and README Summary

**wstunnel added as second tunnel backend: download/systemd/nginx/firewall/client all branch on TUNNEL_TYPE with TUNNEL_PORT variable abstraction replacing hardcoded 7777**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-18T18:40:28Z
- **Completed:** 2026-02-18T18:43:53Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Added `server_download_wstunnel` (GitHub API version detection, .tar.gz extraction, fallback v10.5.2)
- Added `server_create_systemd_wstunnel` (unit with `wstunnel server ws://127.0.0.1:7778`, no --restrict-http-upgrade-path-prefix)
- Added `client_download_wstunnel` and `client_run_wstunnel` (exec with `-L socks5://127.0.0.1:PORT`)
- Replaced hardcoded port 7777 with TUNNEL_PORT variable in nginx, firewall, uninstall, and connection info
- `server_collect_params` now prompts for tunnel backend interactively (chisel/wstunnel) in non-CLI mode
- `client_collect_interactive` makes CLIENT_PASS optional for wstunnel (path-based auth)
- `_uninstall_binary` branches on TUNNEL_TYPE to remove correct binary

## Task Commits

Each task was committed atomically:

1. **Task 1: wstunnel server functions and server_main branching** - `b8c6140` (feat)

**Plan metadata:** (to be added after final commit)

## Files Created/Modified

- `proxyebator.sh` — Added wstunnel server/client functions, TUNNEL_PORT abstraction, all branching logic

## Decisions Made

- wstunnel systemd unit binds to `ws://127.0.0.1:7778` — no `--restrict-http-upgrade-path-prefix` because nginx trailing-slash `proxy_pass` strips the path before wstunnel sees it, causing all connections to be rejected
- wstunnel uses `.tar.gz` archives (not `.gz` like chisel) — extraction uses `tar -xzf`, not `gunzip`
- TUNNEL_PORT set in `server_main` before `server_show_summary` to ensure all downstream functions see the correct value
- CLIENT_PASS made optional in `client_collect_interactive` for wstunnel (path-in-URL is the auth mechanism)
- wstunnel binary name is `wstunnel` (not `wstunnel-cli`) — Docker entrypoint uses cli suffix but release tarballs use `wstunnel`

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- wstunnel backend complete and syntax-verified (`bash -n proxyebator.sh` passes)
- Plan 02 (README.md) can proceed — both chisel and wstunnel are now documented in code
- verify_main already reads TUNNEL_PORT from server.conf — no changes needed there

---
*Phase: 06-wstunnel-backend-and-readme*
*Completed: 2026-02-18*
