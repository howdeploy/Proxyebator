---
phase: 02-server-core
plan: 02
subsystem: infra
tags: [bash, chisel, systemd, github-api, socks5, auth]

# Dependency graph
requires:
  - phase: 02-server-core
    plan: 01
    provides: "server_install_deps (curl/openssl/nginx/certbot installed), detect_arch ($ARCH var), server_collect_params (AUTH_USER/AUTH_TOKEN/SECRET_PATH vars), PKG_INSTALL"
provides:
  - "server_download_chisel(): fetches latest Chisel from GitHub API (v1.11.3 fallback), downloads .gz asset using $ARCH, installs to /usr/local/bin/chisel"
  - "server_setup_auth(): creates /etc/chisel/auth.json with [\".*:.*\"] pattern, chmod 600, chown nobody:nogroup"
  - "server_create_systemd(): writes /etc/systemd/system/proxyebator.service with --host 127.0.0.1 -p 7777 --authfile --socks5, enables+starts service"
  - "server_main() updated: full call chain through systemd creation"
affects: [02-03, 02-04, future-client-phase]

# Tech tracking
tech-stack:
  added: [chisel-binary, systemd-unit]
  patterns:
    - "GitHub API version detection: curl api.github.com/repos/.../releases/latest + grep tag_name with non-empty fallback"
    - ".gz asset download: gunzip not tar (Chisel uses .gz not .tar.gz)"
    - "Auth file not CLI args: --authfile flag keeps credentials out of ps aux"
    - "UNIT heredoc with single quotes: prevents variable expansion in systemd template"

key-files:
  created: []
  modified:
    - "proxyebator.sh"

key-decisions:
  - "GitHub API version detection with hardcoded v1.11.3 fallback: keeps install working even when API is unreachable"
  - "Chisel asset is .gz not .tar.gz — use gunzip, not tar: avoids confusing extraction failure on deploy"
  - "--authfile over --auth flag: credentials stored in 600-permission file, invisible in ps aux / /proc/*/cmdline"
  - "User=nobody over DynamicUser=yes: DynamicUser changes UID on restart which breaks /etc/chisel/auth.json ownership"
  - "--reverse omitted: not needed for SOCKS5 server mode, omitting reduces attack surface"

patterns-established:
  - "Auth stored in file with 600 perms chowned to service user: applied to all future service credentials"
  - "Systemd UNIT heredoc with 'UNIT' (quoted): prevents inadvertent variable expansion in service file"
  - "Binary verify after install: /usr/local/bin/chisel --version run immediately after mv, fail fast if broken"

requirements-completed: [TUNNEL-02, TUNNEL-03, TUNNEL-07, SRV-01]

# Metrics
duration: 1min
completed: 2026-02-18
---

# Phase 2 Plan 02: Chisel Binary Download, Auth Setup, and systemd Service Summary

**Chisel binary auto-downloaded from GitHub releases with arch-aware .gz extraction, auth stored in chmod-600 authfile, systemd service binding to 127.0.0.1:7777 with SOCKS5 and nobody user**

## Performance

- **Duration:** ~1 min
- **Started:** 2026-02-18T14:36:13Z
- **Completed:** 2026-02-18T14:37:31Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Chisel version detection via GitHub API with v1.11.3 fallback; .gz asset downloaded using $ARCH variable (never hardcoded amd64)
- Auth credentials written to /etc/chisel/auth.json with [".*:.*"] remote pattern, chmod 600, chown nobody:nogroup — not visible in process list
- systemd unit uses --host 127.0.0.1 and -p 7777 as separate flags (Chisel ignores combined form); --authfile not --auth; no --reverse
- server_main() fully wired: check_root -> detect_os -> detect_arch -> collect -> summary -> deps -> download_chisel -> setup_auth -> create_systemd

## Task Commits

Both tasks committed as a single atomic commit (tightly coupled — systemd service references auth file created in Task 1):

1. **Task 1 + Task 2: Chisel download, auth setup, systemd service, server_main rewire** - `f874d32` (feat)

**Plan metadata:** (pending — created in this summary step)

## Files Created/Modified

- `/home/kosya/vibecoding/proxyebator/proxyebator.sh` - Added 3 new functions (84 lines), updated server_main call chain

## Decisions Made

- GitHub API version detection with v1.11.3 fallback: keeps installs working when GitHub API is rate-limited or unreachable
- Chisel releases .gz not .tar.gz: gunzip directly, not tar — avoids silent extraction failure on minimal systems missing tar flags
- --authfile over CLI --auth: credentials stay out of `ps aux` and `/proc/*/cmdline`, satisfying security requirement from TUNNEL-03
- User=nobody not DynamicUser=yes: DynamicUser rotates UID on every restart, which breaks /etc/chisel/auth.json ownership without complex ACL workarounds
- --reverse omitted: SOCKS5 server mode doesn't require reverse tunneling; including it would expose bidirectional tunnel capability unnecessarily

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Chisel binary available at /usr/local/bin/chisel
- /etc/chisel/auth.json exists with correct format, permissions, and ownership
- proxyebator.service systemd unit defined and will start after systemctl daemon-reload + enable
- AUTH_USER, AUTH_TOKEN, SECRET_PATH available in server_main scope for Plan 03 (nginx config)
- Plan 03 can immediately use SECRET_PATH to configure nginx WebSocket location block

## Self-Check: PASSED

- [x] proxyebator.sh exists and passes `bash -n` syntax check
- [x] Commit f874d32 confirmed in git log
- [x] server_download_chisel(): CHISEL_FALLBACK_VER, GitHub API curl, gunzip, /usr/local/bin/chisel install confirmed
- [x] server_setup_auth(): /etc/chisel/auth.json with [".*:.*"] pattern, chmod 600, chown nobody:nogroup confirmed
- [x] server_create_systemd(): --host 127.0.0.1 and -p 7777 separate flags confirmed
- [x] --authfile (not --auth) in ExecStart confirmed
- [x] --socks5 present, --reverse absent confirmed
- [x] User=nobody Group=nogroup confirmed
- [x] server_main() order: server_install_deps -> server_download_chisel -> server_setup_auth -> server_create_systemd confirmed

---
*Phase: 02-server-core*
*Completed: 2026-02-18*
