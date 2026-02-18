---
phase: 02-server-core
plan: 03
subsystem: infra
tags: [bash, nginx, certbot, tls, websocket, masquerade, letsencrypt]

# Dependency graph
requires:
  - phase: 02-server-core
    plan: 02
    provides: "server_create_systemd (Chisel on 127.0.0.1:7777), SECRET_PATH var, DOMAIN var, MASQUERADE_MODE var, LISTEN_PORT var, NGINX_CONF_DIR/NGINX_CONF_LINK vars"
provides:
  - "server_configure_nginx(): detects existing nginx config for domain, injects tunnel block with backup, or writes new HTTP-only config for ACME challenge"
  - "server_obtain_tls(): checks existing cert (LE path + nginx ssl_certificate), runs certbot certonly --nginx only if needed, enables renewal timer"
  - "write_nginx_ssl_config(): writes full server{} block with TLS, WebSocket tunnel location, and masquerade cover site"
  - "generate_tunnel_location_block(): hardcoded WebSocket proxy block with mandatory trailing slash and proxy_buffering off"
  - "generate_masquerade_block(): three modes — stub (inline HTML), proxy (reverse-proxy URL), static (root + try_files)"
  - "check_existing_cert(): checks LE path and existing nginx config ssl_certificate directive"
  - "detect_existing_nginx(): searches /etc/nginx/ for domain config file"
affects: [02-04, future-client-phase, future-uninstall-phase]

# Tech tracking
tech-stack:
  added: [nginx-reverse-proxy, certbot-letsencrypt, websocket-proxy]
  patterns:
    - "Two-pass nginx config: HTTP-only first for ACME, full SSL overwrite after cert obtained"
    - "Tunnel block injection with backup: awk inserts before first location / in existing config"
    - "Masquerade block as shell function: case statement returns different nginx location blocks"
    - "certbot certonly --nginx not bare --nginx: certonly never modifies nginx config"
    - "Cert existence check gates certbot: avoids Let's Encrypt rate-limit exhaustion"
    - "Renewal timer detection: snap.certbot.renew.timer vs certbot.timer for distro compatibility"

key-files:
  created: []
  modified:
    - "proxyebator.sh"

key-decisions:
  - "Two-pass nginx approach: write HTTP-only config for ACME, then overwrite with full SSL after cert — avoids nginx refusing to start with missing cert paths"
  - "certbot certonly --nginx not certbot --nginx: certonly obtains cert without modifying nginx config, keeping our config authoritative"
  - "--register-unsafely-without-email: automation-friendly, no email prompt during unattended install"
  - "write_nginx_ssl_config() skips for existing configs (NGINX_EXISTING_CONF set): existing server already has SSL, only the tunnel block was injected"
  - "awk-based injection before first location /: preserves all existing server block directives while inserting tunnel block"
  - "MASK-06 (HTTPS-only without nginx) removed by design: nginx is always used, all three modes go through nginx"

patterns-established:
  - "Hardcoded non-configurable directives: proxy_pass trailing slash and proxy_buffering off are MANDATORY and documented as such in comments"
  - "Backup before mutation: cp .bak.$(date +%s) before any modification of existing nginx config"
  - "Cert reuse guard: check_existing_cert() runs before certbot to protect against LE rate limits"

requirements-completed: [MASK-02, MASK-03, MASK-04, MASK-05, MASK-06]

# Metrics
duration: 1min
completed: 2026-02-18
---

# Phase 2 Plan 03: nginx Reverse Proxy with WebSocket Tunneling and TLS Summary

**nginx configured as WebSocket reverse proxy with three masquerade modes (stub/proxy/static), certbot certonly TLS acquisition with rate-limit-safe cert reuse, and two-pass config (HTTP-only for ACME, full SSL after cert)**

## Performance

- **Duration:** ~1 min
- **Started:** 2026-02-18T14:39:55Z
- **Completed:** 2026-02-18T14:41:00Z
- **Tasks:** 2 (implemented together as tightly coupled unit)
- **Files modified:** 1

## Accomplishments

- WebSocket tunnel location block generated with hardcoded mandatory directives: `proxy_pass http://127.0.0.1:7777/` (trailing slash), `proxy_buffering off`, `proxy_http_version 1.1`, full Upgrade/Connection headers, 3600s timeouts
- Three masquerade modes: stub returns inline "Under construction" HTML; proxy reverse-proxies user URL with Host header extracted via sed; static serves local directory with try_files
- Existing nginx config detection: searches /etc/nginx/ for domain, injects tunnel block before first `location /` with awk, creates timestamped backup
- Two-pass TLS: HTTP-only config written first for certbot ACME challenge, then write_nginx_ssl_config() overwrites with full SSL block after cert obtained
- certbot certonly --nginx with cert existence check (LE path + existing nginx ssl_certificate directive) guards against rate-limit exhaustion

## Task Commits

Tasks 1 and 2 were implemented as a single atomic commit (tightly coupled — nginx config functions call write_nginx_ssl_config which is Task 2, and two-pass logic requires both functions present together):

1. **Task 1 + Task 2: nginx config, masquerade modes, TLS acquisition, server_main wiring** - `c0c0028` (feat)

**Plan metadata:** (pending — created in this summary step)

## Files Created/Modified

- `/home/kosya/vibecoding/proxyebator/proxyebator.sh` - Added 7 new functions (246 lines), updated server_main call chain

## Decisions Made

- Two-pass nginx approach (HTTP-only first, SSL after cert): nginx refuses to start if ssl_certificate path doesn't exist; writing HTTP-only first lets certbot's ACME challenge complete cleanly via port 80
- `certbot certonly --nginx` not `certbot --nginx`: `certonly` never modifies nginx config — keeps our generated config authoritative; bare `--nginx` would overwrite our file
- `--register-unsafely-without-email`: avoids interactive email prompt during unattended server setup (documented in certbot docs as automation-appropriate flag)
- `write_nginx_ssl_config()` skips when `NGINX_EXISTING_CONF` is set: existing server already manages its own TLS, we only inject the tunnel block — no need to overwrite their SSL config
- MASK-06 (HTTPS-only without nginx) removed by design: all three masquerade modes require nginx to serve cover content; the original MASK-06 concept added no value over nginx+stub

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- server_configure_nginx() and server_obtain_tls() wired into server_main() in correct order
- nginx config written to /etc/nginx/sites-available/proxyebator-${DOMAIN}.conf after TLS
- SECRET_PATH embedded in nginx location block as tunnel entry point
- CERT_PATH and CERT_KEY_PATH variables available for Plan 04 if needed
- Plan 04 can immediately add server_configure_firewall, server_save_config, server_verify

## Self-Check: PASSED

- [x] proxyebator.sh exists and passes `bash -n` syntax check
- [x] Commit c0c0028 confirmed in git log
- [x] `proxy_pass http://127.0.0.1:7777/;` with trailing slash confirmed
- [x] `proxy_buffering off;` confirmed
- [x] `proxy_http_version 1.1;` confirmed
- [x] `Upgrade $http_upgrade` header confirmed
- [x] `Connection "upgrade"` header confirmed
- [x] `proxy_read_timeout 3600s;` and `proxy_send_timeout 3600s;` confirmed
- [x] Three masquerade modes (stub/proxy/static) in case statement confirmed
- [x] `detect_existing_nginx()` with grep -rl confirmed
- [x] Backup with `.bak.$(date +%s)` confirmed
- [x] awk injection before first `location /` confirmed
- [x] `certbot certonly --nginx` (not bare --nginx) confirmed
- [x] `check_existing_cert()` checks `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` confirmed
- [x] `MASK-06` comment in generate_masquerade_block() confirmed
- [x] server_main() includes server_configure_nginx and server_obtain_tls in correct order confirmed

---
*Phase: 02-server-core*
*Completed: 2026-02-18*
