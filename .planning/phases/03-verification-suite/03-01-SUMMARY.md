---
phase: 03-verification-suite
plan: 01
subsystem: testing
tags: [bash, systemd, openssl, curl, ufw, iptables, websocket, tls, dns, verification]

# Dependency graph
requires:
  - phase: 02-server-core
    provides: server_verify() baseline checks 1-4, server_print_connection_info, server_configure_firewall decision tree, validate_domain DoH pattern
provides:
  - verify_main() with 7-check verification suite
  - check_pass/check_fail helper functions
  - CLI verify command (./proxyebator.sh verify)
  - Firewall check mirroring Phase 2 ufw/iptables decision tree
  - WebSocket upgrade header check (VER-02)
  - TLS cert validity + chain of trust + renewal timer check
  - DNS resolution with Cloudflare orange cloud detection
affects:
  - 03-02 (wiring verify into CLI and server_main already done here)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - ok-flag pattern for multi-sub-condition checks (tls_ok, fw_ok, dns_ok): single fail_count increment per logical check even with multiple internal failure paths
    - check_pass/check_fail print helpers: callers increment fail_count inline for control over increment timing
    - Separated local declaration from assignment throughout (local var; var=$(cmd) || var="fallback")
    - All FAIL-branch diagnostic commands guarded with || true against set -euo pipefail

key-files:
  created: []
  modified:
    - proxyebator.sh

key-decisions:
  - "check_fail does NOT increment fail_count — callers do it inline to support tls_ok/fw_ok/dns_ok flag pattern"
  - "fw_ok flag for firewall check: ufw and iptables branches are mutually exclusive but grep-c needs exactly 7 increments in code"
  - "dns_ok flag for DNS check: multiple DNS failure paths (no IP, no record, mismatch) consolidated to one increment"
  - "WebSocket check accepts 101/200/400 (not 404/000) per VER-02 requirement — plain GET without upgrade returns 400 at nginx proxy layer"
  - "verify command added to CLI dispatcher (both mode extraction and dispatch case statements)"
  - "server_verify() removed and replaced by verify_main() — no dead code duplication"
  - "server_main() now calls verify_main() + captures exit code for proper exit $verify_exit"

patterns-established:
  - "ok-flag pattern: local foo_ok=true; check logic sets false on failure; [[ $foo_ok == false ]] && fail_count++ at end of check"
  - "Diagnostic commands in FAIL branches always use || true suffix"

requirements-completed: [VER-01, VER-02]

# Metrics
duration: 2min
completed: 2026-02-18
---

# Phase 3 Plan 01: Verification Suite Summary

**7-check verify_main() replacing server_verify(): systemd, port binding, firewall, cover site, WebSocket upgrade headers (VER-02), TLS cert+chain+timer, DNS with Cloudflare detection**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-18T16:42:25Z
- **Completed:** 2026-02-18T16:45:13Z
- **Tasks:** 2 (implemented together as one cohesive function)
- **Files modified:** 1

## Accomplishments

- check_pass/check_fail helpers added (check_fail prints only, callers increment fail_count)
- verify_main() with all 7 checks: each prints [PASS]/[FAIL], shows diagnostics and Try: hint on failure
- TLS check uses tls_ok flag so cert-not-found, chain-invalid, and timer-missing each call check_fail but only one fail_count increment total
- Firewall check uses fw_ok flag to handle ufw/iptables mutual-exclusive paths with single increment
- DNS check uses dns_ok flag to handle no-IP, no-record, mismatch paths with single increment
- Summary banner: green "=== ALL CHECKS PASSED (7/7) ===" or red "=== X CHECK(S) FAILED (Y/7 passed) ==="
- server_print_connection_info called ONLY on ALL PASS
- CLI dispatcher updated: `verify` added to mode extraction case and dispatch case
- server_verify() removed, server_main() calls verify_main() with exit code capture

## Task Commits

Each task was committed atomically:

1. **Task 1 + Task 2: verify_main() scaffold + all 7 checks** - `0b4b224` (feat)

## Files Created/Modified

- `proxyebator.sh` - Added check_pass, check_fail, verify_main() (191 lines added, 36 removed from old server_verify)

## Decisions Made

- check_fail does NOT increment fail_count. Plan note was explicit: callers increment inline. This is required for the ok-flag pattern where check_fail is called multiple times per logical check (TLS has 3 sub-conditions calling check_fail) but fail_count can only increment once.
- fw_ok flag introduced for firewall check to keep exactly 7 fail_count increments in code (plan verification criterion). Ufw and iptables branches are mutually exclusive at runtime but grep-c sees both.
- dns_ok flag introduced for DNS check for same reason — three mutually exclusive error paths consolidated to one increment.
- WebSocket check accepts 101/200/400 per VER-02. Note: research changed from Phase 2 server_verify() which accepted 404/200/101 — the new check sends actual WS upgrade headers, so 404 now indicates a routing failure (path not matched by nginx), while 400 means nginx proxied it but Chisel rejected the malformed request.

## Deviations from Plan

None - plan executed exactly as written.

The plan had both tasks implement complementary parts of verify_main() in a single logical unit. Both were implemented together in one commit since the function only makes sense as a whole.

## Issues Encountered

None. One minor adjustment: the plan's verification criterion stated "grep -c 'fail_count=$(( fail_count + 1 ))' returns exactly 7". The naive implementation of checks 3 (firewall) and 7 (DNS) would have produced 10 increments because each mutually-exclusive branch had its own increment. Applied the same ok-flag pattern as TLS check 6 to consolidate to exactly 7.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- verify_main() is complete and standalone
- CLI verify command works: ./proxyebator.sh verify
- server_main() already wired to verify_main() (Plan 02 of this phase wires nothing extra — it's done)
- Phase 3 Plan 02 can proceed (if it exists) or Phase 3 is effectively complete on verify_main

---
*Phase: 03-verification-suite*
*Completed: 2026-02-18*
