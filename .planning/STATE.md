# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-18)

**Core value:** Human or AI agent runs one script, answers questions, gets a working masked SOCKS5 tunnel
**Current focus:** Phase 3 - Verification Suite

## Current Position

Phase: 3 of 6 (Verification Suite)
Plan: 1 of 2 in current phase
Status: In progress
Last activity: 2026-02-18 — Phase 3 Plan 1 complete (verify_main 7-check suite)

Progress: [████░░░░░░] 40%

## Performance Metrics

**Velocity:**
- Total plans completed: 6
- Average duration: 1.5 min
- Total execution time: 0.14 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-script-foundation | 2 | 3 min | 1.5 min |
| 02-server-core | 4 | 6 min | 1.5 min |
| 03-verification-suite | 1 | 2 min | 2 min |

**Recent Trend:**
- Last 5 plans: 02-01 (2 min), 02-02 (1 min), 02-03 (1 min), 02-04 (2 min), 03-01 (2 min)
- Trend: stable at ~1-2 min/plan

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Bash over Python/Go for maximum portability on any VPS
- Chisel as default backend (built-in SOCKS5 + authfile), wstunnel as Phase 6 addition
- nginx + certbot for TLS and masquerade (most documented stack)
- SOCKS5 only, no HTTP CONNECT proxy
- Use #!/bin/bash not #!/usr/bin/env bash: target is standard VPS /bin/bash, no indirection needed
- ANSI gate via [[ -t 1 ]]: authoritative terminal check; $TERM is unreliable
- printf not echo -e: portable across bash versions, handles %s format strings correctly
- log_warn and die send to stderr (>&2): visible even when stdout is redirected
- readonly on color constants: prevents accidental mutation in downstream functions
- Entry point (CLI parser) at bottom: bash requires functions to be defined before invocation
- while+case parser: handles long options without external getopt
- [Phase 01-script-foundation]: Nested _map_os_id() helper in detect_os: same case-dispatch for ID and ID_LIKE without code duplication
- [Phase 01-script-foundation]: NGINX_CONF_LINK empty string for conf.d distros: Phase 2 uses [[ -n NGINX_CONF_LINK ]] guard before symlinking
- [Phase 01-script-foundation]: tr -d newline mandatory in gen_auth_token: openssl adds trailing newline making token 33 chars without strip
- [Phase 02-server-core plan 01]: DNS-over-HTTPS via dns.google/resolve: eliminates dig/host dependency on stripped VPS images
- [Phase 02-server-core plan 01]: CLI_MODE flag pattern: read DOMAIN before prompts, set true if pre-populated — single flag drives all non-interactive bypasses
- [Phase 02-server-core plan 01]: Cloudflare detection warns but does not abort — operator may use grey-cloud after install
- [Phase 02-server-core plan 01]: snap-first certbot with PKG_INSTALL fallback: snap gives latest certbot on any distro
- [Phase 02-server-core plan 02]: GitHub API version detection with v1.11.3 fallback: install works when API is rate-limited or unreachable
- [Phase 02-server-core plan 02]: Chisel releases .gz not .tar.gz — gunzip directly, not tar
- [Phase 02-server-core plan 02]: --authfile over CLI --auth: credentials stay out of ps aux and /proc/*/cmdline
- [Phase 02-server-core plan 02]: User=nobody not DynamicUser=yes: DynamicUser rotates UID on restart, breaks authfile ownership
- [Phase 02-server-core plan 02]: --reverse omitted from Chisel ExecStart: SOCKS5 doesn't need it, reduces attack surface
- [Phase 02-server-core]: Two-pass nginx: HTTP-only first for ACME, full SSL overwrite after cert obtained
- [Phase 02-server-core]: certbot certonly --nginx not bare --nginx: certonly never modifies nginx config
- [Phase 02-server-core]: MASK-06 removed by design: nginx always used, all three masquerade modes go through nginx
- [Phase 02-server-core plan 04]: ufw active-only guard: only use ufw if Status: active — ufw installed but inactive falls through to iptables
- [Phase 02-server-core plan 04]: Never run ufw enable: activating ufw without pre-configured rules can lock out SSH if default policy is DROP
- [Phase 02-server-core plan 04]: iptables -C idempotency: check-before-add (-C || -A) prevents duplicate rules on script re-run
- [Phase 02-server-core plan 04]: ! -i lo on 7777 DROP rule: nginx proxies to 127.0.0.1:7777 via loopback; only external access blocked
- [Phase 02-server-core plan 04]: WebSocket path accepts 404/200/101: plain HTTP GET returns 404 without upgrade headers — normal and acceptable
- [Phase 03-verification-suite plan 01]: check_fail does NOT increment fail_count — callers do it inline; required for tls_ok/fw_ok/dns_ok ok-flag pattern (one increment per logical check)
- [Phase 03-verification-suite plan 01]: ok-flag pattern: local foo_ok=true; sub-conditions set false on failure; [[ $foo_ok == false ]] && fail_count++ at end — enables exactly 7 fail_count increments in code matching 7 logical checks
- [Phase 03-verification-suite plan 01]: WebSocket check accepts 101/200/400 (not 404) — with proper upgrade headers, 404 means nginx routing failure, 400 means nginx proxied but Chisel rejected; 404 is now a FAIL

### Pending Todos

None yet.

### Blockers/Concerns

- [Research] wstunnel current flag names (v10+ API) should be verified against live GitHub README before Phase 6 implementation
- [Research] nekobox/nekoray may have been renamed or reorganized; verify current repo URLs before writing README

## Session Continuity

Last session: 2026-02-18
Stopped at: Completed 03-verification-suite 03-01-PLAN.md (verify_main 7-check suite)
Resume file: None
