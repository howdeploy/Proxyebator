---
phase: 02-server-core
plan: 01
subsystem: infra
tags: [bash, nginx, certbot, chisel, dns, cloudflare, interactive-cli]

# Dependency graph
requires:
  - phase: 01-script-foundation
    provides: "detect_os (PKG_UPDATE/PKG_INSTALL vars), detect_arch, gen_auth_token, gen_secret_path, check_root, ANSI logging, CLI flag parser (DOMAIN/TUNNEL_TYPE/LISTEN_PORT/MASQUERADE_MODE)"
provides:
  - "server_collect_params(): orchestrated interactive param collection with CLI bypass"
  - "prompt_domain() + validate_domain(): DNS-over-HTTPS A-record check, Cloudflare detection, server IP match"
  - "prompt_masquerade_mode(): stub/proxy/static with sub-prompts, CLI validation"
  - "detect_listen_port(): port 443 conflict auto-detection, alternative port prompt"
  - "server_show_summary(): pre-install summary box with y/N confirmation, CLI_MODE bypass"
  - "server_install_deps(): idempotent curl/openssl/nginx/certbot/jq install, snap-first certbot"
  - "server_main() rewired: check_root -> detect_os -> detect_arch -> collect -> summary -> deps"
affects: [02-02, 02-03, 02-04, future-client-phase]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CLI_MODE flag: set in server_collect_params if DOMAIN pre-populated before prompts; propagated to server_show_summary for non-interactive bypass"
    - "DNS-over-HTTPS validation: curl https://dns.google/resolve?name=&type=A — no dig/host dependency"
    - "Idempotent dep install: command -v check before each package; snap-first certbot with PKG_INSTALL fallback"
    - "Cloudflare first-octet heuristic: case on first IP octet against known CF ranges (warn, not abort)"

key-files:
  created: []
  modified:
    - "proxyebator.sh"

key-decisions:
  - "DNS-over-HTTPS via dns.google/resolve: eliminates dig/host/nslookup dependency on minimal VPS images"
  - "CLI_MODE flag pattern: read DOMAIN before prompts, set CLI_MODE=true if already populated — single flag drives all non-interactive bypasses including summary skip"
  - "Cloudflare detection warns but does not abort: operator may intentionally use grey-cloud later; hard fail would break valid setups"
  - "snap-first certbot with PKG_INSTALL fallback: snap gives latest certbot on any distro; fallback handles snap-less environments"
  - "TUNNEL_TYPE=chisel hardcoded in server_collect_params for Phase 2; wstunnel path deferred to Phase 6"

patterns-established:
  - "Prompt functions check CLI variable first, return early if set — non-interactive bypass is implicit"
  - "All prompt validation dies with descriptive error; no silent defaults for required fields"
  - "log_info for success/skip, log_warn for recoverable issues (Cloudflare), die for fatal errors"

requirements-completed: [SCRIPT-06, TUNNEL-01, TUNNEL-05, TUNNEL-06, MASK-01]

# Metrics
duration: 2min
completed: 2026-02-18
---

# Phase 2 Plan 01: Server Parameter Collection and Dependency Installation Summary

**Interactive domain/masquerade/port collection with DNS-over-HTTPS validation, Cloudflare detection, pre-install confirmation, and idempotent dependency installation wired into server_main()**

## Performance

- **Duration:** ~2 min
- **Started:** 2026-02-18T14:32:18Z
- **Completed:** 2026-02-18T14:33:51Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Domain validation without dig/host: uses `curl https://dns.google/resolve` (DNS-over-HTTPS) to resolve A-record and compare against server public IP from ipify.org/ifconfig.me
- Non-interactive mode fully implicit: all prompt functions check CLI variable before prompting; CLI_MODE flag propagates to server_show_summary for confirmation bypass
- Cloudflare orange-cloud heuristic warns operators about WebSocket timeout risk without aborting (correct behavior — user may fix CF config after install)
- Idempotent dep install: curl/openssl/nginx/certbot/jq each checked via `command -v` before installing; snap-first certbot with package manager fallback
- server_main() fully rewired from Phase 1 skeleton to real collect->summary->deps sequence with Phase 2 Plan 02+ hooks documented in comments

## Task Commits

Each task was committed atomically:

1. **Task 1 + Task 2: param collection, summary, dep install, server_main rewire** - `68e35ac` (feat)

**Plan metadata:** (pending — created in this summary step)

## Files Created/Modified

- `/home/kosya/vibecoding/proxyebator/proxyebator.sh` - Added 7 new functions (210 lines), replaced Phase 1 server_main stub

## Decisions Made

- DNS-over-HTTPS via dns.google: eliminates dig/host/nslookup from required deps on stripped VPS images
- CLI_MODE flag: single variable checked in server_show_summary; set by reading DOMAIN *before* first prompt call in server_collect_params
- Cloudflare detection warns but doesn't abort — operator likely intends to use grey-cloud after installation
- snap-first certbot: snap gives latest certbot on any distro; `$PKG_INSTALL certbot python3-certbot-nginx` fallback for environments without snapd
- TUNNEL_TYPE hardcoded to chisel: wstunnel is Phase 6; hardcoding avoids broken prompt that offers wstunnel before it's supported

## Deviations from Plan

None - plan executed exactly as written. Tasks 1 and 2 were committed as a single atomic commit because they are tightly coupled (server_show_summary and server_install_deps required server_collect_params variables to be present before the commit was meaningful).

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- server_collect_params(), server_show_summary(), server_install_deps() ready for Plan 02 to build on
- DOMAIN, LISTEN_PORT, MASQUERADE_MODE, TUNNEL_TYPE, SECRET_PATH, AUTH_USER, AUTH_TOKEN all set after server_collect_params() runs
- PKG_UPDATE, PKG_INSTALL, NGINX_CONF_DIR, NGINX_CONF_LINK, ARCH all available after detect_os/detect_arch
- Plan 02 can immediately add server_download_chisel() after server_install_deps()

## Self-Check: PASSED

- [x] proxyebator.sh exists and passes `bash -n` syntax check
- [x] Commit 68e35ac confirmed in git log
- [x] All 7 functions (prompt_domain, validate_domain, prompt_masquerade_mode, detect_listen_port, server_collect_params, server_show_summary, server_install_deps) confirmed present
- [x] server_main() verified: check_root -> detect_os -> detect_arch -> server_collect_params -> server_show_summary -> server_install_deps
- [x] dns.google/resolve usage confirmed
- [x] Cloudflare first-octet heuristic confirmed

---
*Phase: 02-server-core*
*Completed: 2026-02-18*
