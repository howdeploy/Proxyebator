---
phase: 01-script-foundation
plan: 01
subsystem: infra
tags: [bash, ansi, logging, cli-parser, dispatcher]

# Dependency graph
requires: []
provides:
  - "proxyebator.sh: executable bash skeleton with shebang, safety flags, ANSI color logging, CLI dispatcher"
  - "log_info / log_warn / die logging functions using printf with colored prefixes"
  - "Terminal-gated ANSI color constants (readonly) suppressed when not a tty"
  - "print_usage showing server / client / uninstall commands"
  - "server_main / client_main / uninstall_main stub functions"
  - "CLI parser: positional mode dispatch + while+case flag parser for --domain, --tunnel, --port, --masquerade"
affects:
  - 01-script-foundation
  - 02-os-detection
  - all subsequent phases (script skeleton is the single entry point)

# Tech tracking
tech-stack:
  added: [bash, openssl (future use)]
  patterns:
    - "Entry-point-at-bottom: all functions defined before the case dispatcher"
    - "ANSI color gating via [[ -t 1 ]] not $TERM"
    - "printf-not-echo-e for all user-facing output"
    - "readonly on all ANSI constants to prevent accidental mutation"
    - "log_warn and die write to stderr (>&2)"
    - "while+case CLI parser for long option support without getopts"

key-files:
  created:
    - proxyebator.sh
  modified: []

key-decisions:
  - "Use #!/bin/bash not #!/usr/bin/env bash: target is standard VPS /bin/bash, no indirection needed"
  - "ANSI gate via [[ -t 1 ]]: authoritative terminal check; $TERM is unreliable"
  - "printf not echo -e: portable across bash versions, handles %s escaping correctly"
  - "log_warn and die send to stderr: visible even when stdout is redirected to file"
  - "readonly on color constants: prevents accidental mutation in downstream functions"
  - "Entry point (CLI parser) at bottom: bash requires functions to be defined before invocation"
  - "while+case parser: handles long options (--domain, --tunnel) without external getopt"

patterns-established:
  - "Pattern: all future mode functions (server_main etc.) defined above entry point, never below"
  - "Pattern: any new log-level function follows log_info / log_warn / die signature"
  - "Pattern: new CLI flags added to the while+case block in the entry point section"
  - "Pattern: color constants used via ${GREEN} / ${RED} etc., never hardcoded ANSI strings"

requirements-completed: [SCRIPT-01, SCRIPT-05]

# Metrics
duration: 1min
completed: 2026-02-18
---

# Phase 1 Plan 01: Script Foundation Summary

**Executable bash skeleton with ANSI-gated colored logging, while+case CLI dispatcher, and mode stubs — foundation for all subsequent phases**

## Performance

- **Duration:** 1 min
- **Started:** 2026-02-18T13:37:21Z
- **Completed:** 2026-02-18T13:38:38Z
- **Tasks:** 1 of 1
- **Files modified:** 1

## Accomplishments

- Created proxyebator.sh (113 lines) with shebang, set -euo pipefail, ANSI color constants with terminal detection, log_info/log_warn/die logging, print_usage, server_main/client_main/uninstall_main stubs, and while+case CLI parser
- Established entry-point-at-bottom pattern: all functions above the dispatcher, ensuring functions are defined before invocation
- ANSI colors suppressed correctly when stdout is not a terminal (verified: 0 raw escape codes in piped output)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create script skeleton with logging infrastructure** - `27b7330` (feat)

## Files Created/Modified

- `proxyebator.sh` - Executable bash script skeleton, 113 lines; shebang + safety flags, ANSI color constants with -t 1 gating, log_info/log_warn/die via printf, print_usage with full usage text, server_main/client_main/uninstall_main stubs, while+case CLI parser at entry point bottom

## Decisions Made

- Used `#!/bin/bash` (not `#!/usr/bin/env bash`): target is standard VPS installs where bash is always at /bin/bash; no need for env indirection
- ANSI gate uses `[[ -t 1 ]]`: authoritative check on file descriptor 1 being a terminal; `$TERM` is unreliable and can be set incorrectly
- All user-facing output uses `printf`: portable across bash versions, handles `%s` format strings correctly; `echo -e` behavior varies
- `log_warn` and `die` write to stderr (`>&2`): errors remain visible when stdout is redirected
- `readonly RED YELLOW GREEN CYAN BOLD NC`: prevents any function from accidentally mutating color constants
- Entry point (CLI parser + dispatch) placed at the very bottom: bash executes top-to-bottom, functions must be defined before invocation
- `while [[ $# -gt 0 ]]; do case "$1"` pattern chosen over `getopts`: `getopts` only handles single-char flags; long options (`--domain`, `--tunnel`) require manual `while+case` parsing

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

The plan's verification command `grep -q 'echo -e' proxyebator.sh` produced a false positive because the comment text includes "not echo -e" as an anti-pattern note. Actual code uses only `printf` — no `echo -e` in any executable line. The check was manually verified by inspecting grep output with line numbers.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- proxyebator.sh skeleton is ready; all subsequent phases can add functions above the entry point and extend the while+case parser with new flags
- server_main / client_main / uninstall_main stubs ready to receive OS detection, secret generation, and installation logic
- No blockers

---
*Phase: 01-script-foundation*
*Completed: 2026-02-18*

## Self-Check: PASSED

- FOUND: proxyebator.sh (113 lines, executable)
- FOUND: .planning/phases/01-script-foundation/01-01-SUMMARY.md
- FOUND: commit 27b7330 (feat(01-01): create proxyebator.sh script skeleton)
