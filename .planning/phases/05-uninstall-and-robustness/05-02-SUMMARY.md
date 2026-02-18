---
phase: 05-uninstall-and-robustness
plan: 02
subsystem: infra
tags: [bash, chisel, systemd, nginx, idempotency, re-run, credentials]

# Dependency graph
requires:
  - phase: 05-uninstall-and-robustness-01
    provides: server.conf written with NGINX_INJECTED flag during install
  - phase: 02-server-core
    provides: server_download_chisel, server_setup_auth, server_create_systemd, server_save_config, server_collect_params functions

provides:
  - Idempotency guards in server_download_chisel (skip if /usr/local/bin/chisel -x exists)
  - Idempotency guards in server_setup_auth (skip if /etc/chisel/auth.json exists)
  - Idempotency guards in server_create_systemd (skip if proxyebator.service is-active)
  - Idempotency guards in server_save_config (skip if /etc/proxyebator/server.conf exists)
  - Re-run awareness in server_collect_params (sources existing server.conf instead of generating new secrets)
  - Re-run bypass in server_show_summary (skips interactive confirmation when server.conf exists)
  - TUNNEL-07 compliance comment documenting --authfile credential hygiene

affects: [06-wstunnel-phase, verify-mode, uninstall-mode]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Existence-guard pattern: check for installed state before executing; log and return early
    - Re-run detection pattern: source existing config at top of param-collection function
    - Credential hygiene via --authfile: AUTH_TOKEN never in cmdline/ps aux

key-files:
  created: []
  modified:
    - proxyebator.sh

key-decisions:
  - "is-active (not is-enabled) for systemd idempotency: enabled-but-stopped service gets recreated (may have stale unit file)"
  - "-x (executable) not -f (exists) for chisel binary check: ensures binary is functional, not just present"
  - "Re-run guard at very top of server_collect_params: before CLI_MODE detection, so no prompts or secret generation occur on re-run"
  - "server_show_summary re-run bypass added: prevents confusing summary display when running on already-configured host"
  - "Defensive /tmp cleanup before download: rm -f /tmp/chisel.gz prevents stale-file interference"

patterns-established:
  - "Idempotency guard pattern: if [[ -condition ]]; then log_info 'already X — skipping'; return; fi at function top"
  - "Config-sourcing re-run detection: source existing conf and return immediately preserves all secrets"

requirements-completed:
  - SCRIPT-04
  - TUNNEL-07

# Metrics
duration: 1min
completed: 2026-02-18
---

# Phase 5 Plan 02: Server Idempotency and Re-Run Safety Summary

**Idempotency guards added to all four server install functions plus re-run-aware server_collect_params that sources existing server.conf to preserve AUTH_TOKEN and SECRET_PATH**

## Performance

- **Duration:** 1 min
- **Started:** 2026-02-18T18:13:04Z
- **Completed:** 2026-02-18T18:14:24Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Four server functions now skip silently if already installed: `server_download_chisel` (-x check), `server_setup_auth` (-f auth.json), `server_create_systemd` (is-active), `server_save_config` (-f server.conf)
- `server_collect_params` detects existing installation via server.conf presence and sources it — no new secrets generated, no interactive prompts, all downstream functions see correct values
- `server_show_summary` bypassed on re-run to prevent confusing confirmation prompt
- TUNNEL-07 compliance documented: `--authfile` pattern ensures AUTH_TOKEN never appears in `ps aux` or `/proc/PID/cmdline`
- Defensive `/tmp/chisel.gz` cleanup before download prevents stale-file interference

## Task Commits

Each task was committed atomically:

1. **Task 1: Idempotency guards for four server install functions** - `32a60ac` (feat)
2. **Task 2: Re-run awareness in server_collect_params and server_show_summary** - `2b4cedd` (feat)

**Plan metadata:** committed with docs commit below

## Files Created/Modified

- `proxyebator.sh` - Added 48 lines of idempotency and re-run logic across 6 functions

## Decisions Made

- Used `is-active` (not `is-enabled`) for systemd idempotency: an enabled-but-stopped service may have a stale unit file and should be recreated
- Used `-x` (executable) not `-f` (file exists) for chisel binary check: ensures binary is functional, not merely present
- Re-run guard placed at very top of `server_collect_params`, before `CLI_MODE` detection: this prevents any prompt or secret generation on re-run
- Added defensive `/tmp` cleanup before chisel download: `rm -f /tmp/chisel.gz /tmp/chisel` prevents stale temp files from a previous failed download from interfering with `gunzip`
- TUNNEL-07 comment placed above the ExecStart critical-notes block in `server_create_systemd`

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Phase 5 (Uninstall and Robustness) is complete: both plans executed
  - 05-01: Uninstall command (6 sub-functions, --yes flag, NGINX_INJECTED)
  - 05-02: Server idempotency + re-run safety
- Ready for Phase 6 (wstunnel backend addition)
- Blockers to track before Phase 6: verify current wstunnel v10+ flag names against live GitHub README

---
*Phase: 05-uninstall-and-robustness*
*Completed: 2026-02-18*
