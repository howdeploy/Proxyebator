---
phase: 05-uninstall-and-robustness
plan: 01
subsystem: infra
tags: [bash, uninstall, idempotency, nginx, systemd, firewall]

# Dependency graph
requires:
  - phase: 02-server-core
    provides: server_save_config, server_configure_nginx, server_configure_firewall patterns
  - phase: 01-script-foundation
    provides: detect_os, NGINX_CONF_LINK, CLI parser structure

provides:
  - uninstall_main with 6 idempotent sub-functions
  - --yes flag for non-interactive uninstall
  - NGINX_INJECTED flag written to server.conf during install
  - Clean removal of chisel binary, auth file, systemd service, nginx config, firewall rules

affects: [05-02-idempotency-guards]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Private sub-function prefix (_uninstall_*) for encapsulated removal steps
    - Source server.conf at top of uninstall_main — all vars available to all sub-functions
    - [[ -f ]] guard before every rm -f — idempotent removal under set -euo pipefail
    - NGINX_INJECTED flag distinguishes injected vs created nginx configs

key-files:
  created: []
  modified:
    - proxyebator.sh

key-decisions:
  - "NGINX_INJECTED written to server.conf during install: enables uninstall to decide between sed-remove-block vs full file delete"
  - "Source server.conf at top of uninstall_main: all 6 sub-functions share config vars without re-reading the file"
  - "rmdir not rm -rf for /etc/chisel and /etc/proxyebator: preserves user files; only removes dir if empty"
  - "TLS cert explicitly NOT removed: Let's Encrypt rate limits make cert deletion a manual post-uninstall step"
  - "_uninstall_config last: server.conf already sourced at top, so config vars remain valid through all prior steps"

patterns-established:
  - "Private _uninstall_* prefix: encapsulates each removal step, mirrors _uninstall_confirm/_uninstall_service naming"
  - "Idempotency via [[ -f ]] guards: every rm inside conditional so second uninstall run logs 'not found' rather than erroring"
  - "|| true on all external commands that might fail: set -euo pipefail friendly"

requirements-completed: [DEL-01, DEL-02]

# Metrics
duration: 2min
completed: 2026-02-18
---

# Phase 5 Plan 01: Uninstall Command Summary

**Complete `uninstall` command with 6 idempotent sub-functions reads server.conf and removes systemd service, chisel binary, nginx config, and firewall rules without touching TLS certificate**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-18T18:08:24Z
- **Completed:** 2026-02-18T18:10:56Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- `uninstall_main()` with 6 sub-functions replaces stub: confirm, service, binary, nginx, firewall, config
- `--yes` flag parsed in CLI and honored by `_uninstall_confirm` for non-interactive usage
- `NGINX_INJECTED` flag set in `server_configure_nginx` and written to `server.conf` so uninstall knows whether to delete the nginx file or just remove the tunnel block
- All removal steps guarded with `[[ -f ]]` checks and `|| true` — safe to run twice

## Task Commits

Each task was committed atomically:

1. **Task 1: Add NGINX_INJECTED flag and --yes CLI option** - `7af26a4` (feat)
2. **Task 2: Implement uninstall_main with all sub-functions** - `a5e4d09` (feat)

## Files Created/Modified
- `/home/kosya/vibecoding/proxyebator/proxyebator.sh` - Added NGINX_INJECTED to nginx config function and server_save_config; added UNINSTALL_YES init and --yes parser case; added 6 _uninstall_* sub-functions and full uninstall_main

## Decisions Made
- NGINX_INJECTED flag written to server.conf during install (not derived at uninstall time) — server_configure_nginx already knows which branch it took, so recording at write-time is authoritative
- Source server.conf once at top of uninstall_main — all six sub-functions share the same variable scope, no repeated file reads
- `rmdir` not `rm -rf` for `/etc/chisel` and `/etc/proxyebator` — preserves any user-added files; fails silently if directory non-empty
- TLS certificate explicitly NOT removed — Let's Encrypt rate limits; instructions printed to stderr after uninstall

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `uninstall_main` is fully functional and ready for integration testing in Phase 5 Plan 02
- NGINX_INJECTED flag is now written during server install — Phase 5 Plan 02 can validate idempotency of server install path
- No blockers for 05-02
