# Phase 03: Verification Suite — Plan Check

**Checked:** 2026-02-18
**Checker:** gsd-plan-checker
**Plans verified:** 03-01-PLAN.md, 03-02-PLAN.md
**Overall status:** ISSUES FOUND

---

## Summary

| Plan | Tasks | Wave | Req Coverage | Status |
|------|-------|------|-------------|--------|
| 03-01 | 2 | 1 | VER-01, VER-02 | 1 BLOCKER, 1 WARNING |
| 03-02 | 1 | 2 | VER-03 | 1 WARNING |

**Issues:** 1 blocker, 2 warnings

---

## Dimension 1: Goal Coverage — PASS

The phase goal is: "Every silent failure mode is caught and reported explicitly before the user is told installation succeeded."

Plans 01+02 together achieve this:
- Plan 01 builds the 7-check engine that catches all silent failures (dead service, exposed port, broken firewall, broken nginx, broken WebSocket routing, expiring TLS, DNS drift)
- Plan 02 wires it into the install flow so the user never sees "installation complete" before checks run
- Connection block only prints on ALL PASS (enforced in verify_main scaffold)

Goal coverage: PASS.

---

## Dimension 2: Requirement Coverage — PASS

| Requirement | Description | Covered By |
|-------------|-------------|------------|
| VER-01 | Post-install verification: ss -tlnp, systemd, port | Plan 01 Tasks 1+2 (checks 1+2), Plan 02 wires into server_main |
| VER-02 | WebSocket upgrade verification with proper headers | Plan 01 Task 2 (check 5) — explicitly lists Connection: Upgrade, Upgrade: websocket, Sec-WebSocket-Key, Sec-WebSocket-Version: 13 |
| VER-03 | Connection info printed only after ALL checks pass | Plan 01 Task 1 scaffold (summary banner logic), Plan 02 Task 1 (CLI dispatch + server_main wiring) |

All three requirements are covered. PASS.

---

## Dimension 3: Success Criteria — PASS

| Criterion | Plan Coverage |
|-----------|--------------|
| Script prints PASS/FAIL for each check: systemd active, port binding, nginx cover site, WebSocket upgrade | Plan 01 Task 2 implements all four as checks 1, 2, 4, 5 |
| Tunnel port bound to 0.0.0.0 triggers FAIL and exits non-zero before "installation complete" | Plan 01 Task 2 check 2 flags 0.0.0.0 explicitly with "SECURITY RISK"; Plan 02 Task 1 wires verify_main as last step in server_main with `|| exit 1` |
| After all checks pass: host, port, secret path, auth token, copy-paste client command | server_print_connection_info() exists at line 738-754 and contains all required fields; called only in fail_count==0 branch |

All success criteria covered. PASS.

---

## Dimension 4: Internal Consistency — ISSUES FOUND

### BLOCKER: check_fail() design contradicted between Plan 01 and RESEARCH.md

**What the plan says (03-01-PLAN.md Task 1, line 71):**
> "NOTE: Does NOT increment fail_count — callers do that inline because fail_count is local to verify_main"

**What the research shows (03-RESEARCH.md lines 155-158):**
```bash
check_fail() {
    printf "${RED}[FAIL]${NC} %s\n" "$1" >&2
    fail_count=$(( fail_count + 1 ))
}
```

The executor reads both files (both are listed in Plan 01 `<context>`). These two sources directly contradict each other on the single most critical behavioral question: does check_fail increment fail_count or not?

**Why this matters:** The TLS check (check 6) in RESEARCH.md calls check_fail() multiple times for sub-conditions (cert missing, chain invalid, near-expiry, timer missing — lines 364, 378, 386, 395) and then increments fail_count separately at the end:
```bash
[[ "$tls_ok" == "false" ]] && fail_count=$(( fail_count + 1 ))
```
If the executor implements check_fail to increment fail_count (following research), the TLS check would increment fail_count up to 4 times instead of once — breaking the 7-count invariant and the X/7 banner.

If the executor implements check_fail to NOT increment fail_count (following plan), then the other 6 checks need explicit `fail_count=$(( fail_count + 1 ))` calls inline after check_fail — the plan says this but the verify step in Task 2 says "Count occurrences of `fail_count=$(( fail_count + 1 ))` — should appear exactly 7 times", which would be violated if check_fail internally increments.

**The plan's verify step is self-consistent with the "no increment in check_fail" design.** But the research contradicts it. An executor will encounter the research code example first (it's more concrete) and likely follow it.

**Fix required:** The plan must explicitly resolve this contradiction. Add a note in Task 1 action: "The RESEARCH.md helper pattern (check_fail incrementing fail_count) is NOT used here. Instead, check_fail only prints; callers increment fail_count inline. This is required because TLS check 6 uses an internal `tls_ok` flag and must increment fail_count only once regardless of how many sub-conditions fail." Remove or annotate the conflicting research pattern.

---

### WARNING: Plan 02 server_main example shows verify_main exit handling differently than RESEARCH.md

**Plan 02 Task 1 action shows:**
```bash
verify_main || exit 1
```

**RESEARCH.md shows:**
```bash
verify_main  # was: server_verify
local verify_exit=$?
exit $verify_exit
```

Both achieve the same result but `verify_main || exit 1` is cleaner. The discrepancy is not a blocker since both work, but an executor seeing both may produce one or the other. The plan version (`|| exit 1`) is the definitive authority here since it's in the plan, and it is safer under `set -euo pipefail` (bare `verify_main` returning 1 would be caught by set -e anyway, but `|| exit 1` is clearer intent). This is a minor inconsistency, not a blocker.

---

### PASS: Line number references in Plan 02

Plan 02 references "around line 848-852" for the first case statement and "around line 872-876" for the dispatch case. Actual script has these at lines 848-852 and 872-876 respectively — exact match. Line number references are accurate.

---

### PASS: server_print_connection_info preservation

Plan 02 Task 1 action explicitly states: "IMPORTANT: server_print_connection_info() function itself MUST be preserved — it is called by verify_main." This is correct — the function exists at lines 738-754 and must not be deleted.

---

## Dimension 5: Context Alignment — PASS WITH NOTES

| Decision | Plan Compliance |
|----------|----------------|
| New `verify` mode in CLI dispatcher | Plan 02 Task 1 adds verify to both case statements — COMPLIANT |
| verify_main() replaces server_verify() | Plan 02 Task 1 explicitly deletes server_verify() — COMPLIANT |
| Parameters from /etc/proxyebator/server.conf | Plan 01 Task 1 sources server.conf at verify_main() start — COMPLIANT |
| 7 checks (systemd, port, firewall, cover site, WebSocket, TLS cert, DNS) | Plan 01 Task 2 implements all 7 — COMPLIANT |
| PASS/FAIL per line with diagnostics on FAIL | Plan 01 Tasks 1+2 — COMPLIANT |
| Banner: ALL CHECKS PASSED or X CHECKS FAILED | Plan 01 Task 1 scaffold — COMPLIANT |
| Connection block ONLY on ALL PASS | Plan 01 Task 1: server_print_connection_info called only in fail_count==0 branch — COMPLIANT |
| Continue all checks even if one fails | Plan 01: no die calls, fail_count pattern — COMPLIANT |
| exit 1 on any FAIL, exit 0 only on ALL PASS | Plan 01 return values + Plan 02 exit $? propagation — COMPLIANT |
| Fix hints (Try: ...) on failures | Plan 01 Task 2: every check failure includes printf "  Try: ..." — COMPLIANT |

Check order: CONTEXT.md lists check order as systemd, port, cover site, WebSocket, TLS, DNS, firewall. Plans use order: systemd, port, firewall, cover site, WebSocket, TLS, DNS. This reordering is explicitly allowed ("Порядок проверок (оптимальный для диагностики)" is listed under Claude's Discretion). COMPLIANT.

---

### WARNING: server_verify() uses log_warn/log_info for [PASS]/[FAIL] — Plan switches to check_pass/check_fail format

The existing server_verify() at lines 756-811 uses `log_info "[PASS]..."` and `log_warn "[FAIL]..."` which go through those functions. The new verify_main() uses dedicated check_pass/check_fail helpers that print GREEN [PASS] or RED [FAIL] directly.

This is the correct approach per CONTEXT.md requirements (colored PASS/FAIL per line) and no conflict exists. However, the executor deletes server_verify and replaces it — the executor must not try to reuse the old function signatures. The plan handles this correctly by building verify_main from scratch.

This is informational only — no action needed.

---

## Dimension 6: Dependency Safety — PASS

```
03-01 (wave 1, depends_on: []) → 03-02 (wave 2, depends_on: [03-01])
```

- No circular dependencies
- 03-02 correctly lists 03-01 as dependency (needs verify_main() to exist before wiring it)
- 03-02 correctly reads 03-01-SUMMARY.md as context to understand what was built
- Wave numbers consistent with dependency graph

PASS.

---

## Dimension 7: Executability — PASS WITH NOTES

**Plan 01 executability:**
- Task 1 action is specific: exact function signatures, placement instruction ("ABOVE server_main()"), bash safety rules enumerated
- Task 2 action is specific: each check has named code pattern from research, TUNNEL_PORT substitution noted
- Verify steps are runnable grep commands with expected values
- Done criteria are concrete and checkable

**Plan 02 executability:**
- Single task with 5 concrete sub-changes enumerated (two case statements, server_main update, print_usage update, delete server_verify)
- Each change shows the exact bash code to produce
- Verify steps use grep with expected match patterns
- The `check_root` before verify_main in standalone path is specified (line 80: "check_root; verify_main; exit $?")

**Concern (non-blocking):** Plan 02 Task 1 says "Delete server_verify() function (lines ~756-811 in current script)." The `~` indicates approximate lines. The actual function is at lines 756-811 (exact). The executor should confirm line numbers before editing rather than blindly deleting that range — but this is standard practice for script editing agents.

---

## Dimension Scores

| Dimension | Score | Severity |
|-----------|-------|----------|
| 1. Goal Coverage | PASS | — |
| 2. Requirement Coverage | PASS | — |
| 3. Success Criteria | PASS | — |
| 4. Internal Consistency | ISSUES | 1 BLOCKER, 1 WARNING |
| 5. Context Alignment | PASS | 1 INFO |
| 6. Dependency Safety | PASS | — |
| 7. Executability | PASS | 1 WARNING |

---

## Issues

```yaml
issues:

  - plan: "03-01"
    dimension: "internal_consistency"
    severity: "blocker"
    description: >
      check_fail() design contradicted between Plan 01 Task 1 action and RESEARCH.md.
      Plan says check_fail does NOT increment fail_count (callers do it inline).
      RESEARCH.md code example at lines 155-158 shows check_fail() incrementing fail_count
      directly. Both files are in the executor's context. An executor following the research
      pattern would cause TLS check 6 to increment fail_count up to 4 times instead of
      once, breaking the 7-count invariant and the X/7 banner.
    fix_hint: >
      Add explicit override note in Plan 01 Task 1 action:
      "IMPORTANT: Do not implement the check_fail pattern from RESEARCH.md lines 147-163
      (which shows fail_count incremented inside check_fail). The correct design here is:
      check_fail prints only, callers increment fail_count inline. This keeps TLS check 6's
      tls_ok sub-condition logic from inflating the counter beyond 1."
      The plan's verify criteria (exactly 7 occurrences of fail_count=$(( fail_count + 1 )))
      are already consistent with this design — just needs the contradiction called out.

  - plan: "03-02"
    dimension: "internal_consistency"
    severity: "warning"
    description: >
      Plan 02 Task 1 action shows server_main ending with `verify_main || exit 1`.
      RESEARCH.md (which is also in executor context) shows a different pattern:
      `local verify_exit=$?; exit $verify_exit`. These achieve the same outcome but
      the discrepancy may confuse an executor that reads research before plan.
    fix_hint: >
      Add a single sentence to Plan 02 Task 1 action: "Use `verify_main || exit 1`
      (not the local verify_exit pattern in RESEARCH.md — that variant is equivalent
      but the || exit 1 form is preferred for clarity)."

  - plan: "03-01"
    dimension: "task_completeness"
    severity: "warning"
    description: >
      Task 2 verify step says: "Count occurrences of check_pass in verify_main —
      should be 7 (one per check on success path)." However, DNS check 7 has three
      possible FAIL paths and zero early exits, so check_pass is called exactly once
      on the success path. TLS check 6 also has multiple FAIL branches but one PASS
      path. The "should be 7" assertion holds, but the verify instruction should also
      clarify that multiple check_fail calls per check are acceptable — the count of
      7 for check_pass is what matters, not the count of check_fail.
    fix_hint: >
      Adjust verify step to: "Count check_pass calls — should be exactly 7. Count
      check_fail calls — should be >= 7 (TLS and DNS have multiple fail paths). This
      is correct behavior."
```

---

## Recommendation

**1 blocker must be fixed before execution.**

The blocker is purely a documentation/instruction ambiguity, not a design flaw. The plan's intended design (check_fail does not increment fail_count, callers do) is the correct and self-consistent design. The research code example conflicts with it. A single clarifying sentence in Plan 01 Task 1 resolves this.

The two warnings are low-risk quality improvements.

**Suggested minimal fix for Plan 01 Task 1 action** — add after the check_fail() specification:

```
OVERRIDE NOTE: The RESEARCH.md pattern (lines 147-163) shows check_fail() incrementing
fail_count internally. DO NOT follow that pattern. check_fail() here only prints.
Callers increment fail_count inline with `fail_count=$(( fail_count + 1 ))`.
This is required for TLS check 6, which uses internal tls_ok logic and must
increment fail_count exactly once regardless of which sub-condition triggered.
```

After this fix, execution can proceed.

---

*Plan check complete: 2026-02-18*
