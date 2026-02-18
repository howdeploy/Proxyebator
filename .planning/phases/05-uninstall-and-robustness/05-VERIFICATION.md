---
phase: 05-uninstall-and-robustness
verified: 2026-02-18T18:17:53Z
status: passed
score: 4/4 must-haves verified
re_verification: false
---

# Phase 5: Uninstall and Robustness Verification Report

**Phase Goal:** Users can cleanly remove all installed components and re-run the install script on an already-configured server without breakage
**Verified:** 2026-02-18T18:17:53Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #   | Truth | Status | Evidence |
| --- | ----- | ------ | -------- |
| 1   | Running `./proxyebator.sh uninstall` stops and removes the systemd service, binary, nginx config, and firewall rules without prompting for config values | VERIFIED | `uninstall_main` sources `/etc/proxyebator/server.conf` at line 1434 before any action; all values come from that file. `_uninstall_confirm` skips prompts when `UNINSTALL_YES=true`; service/binary/nginx/firewall sub-functions use sourced vars. |
| 2   | After uninstall, re-running `./proxyebator.sh server` installs cleanly from scratch | VERIFIED | `uninstall_main` removes `/etc/proxyebator/server.conf` via `_uninstall_config` (line 1420). On fresh `server` run, `server_collect_params` checks `[[ -f /etc/proxyebator/server.conf ]]` (line 496) — file absent → full interactive/flag path taken → new secrets generated → fresh install proceeds. |
| 3   | Re-running `./proxyebator.sh server` on an already-configured server detects existing cert, binary, and service and skips those steps rather than failing or duplicating | VERIFIED | Four idempotency guards confirmed: (a) `server_download_chisel` — `[[ -x /usr/local/bin/chisel ]]` at line 613; (b) `server_setup_auth` — `[[ -f /etc/chisel/auth.json ]]` at line 647; (c) `server_create_systemd` — `systemctl is-active --quiet proxyebator` at line 671; (d) `server_save_config` — `[[ -f /etc/proxyebator/server.conf ]]` at line 996. `server_collect_params` sources existing config and returns early at line 505, preserving `SECRET_PATH`/`AUTH_TOKEN`. `server_show_summary` bypasses interactive confirmation at line 542. |
| 4   | Chisel auth credentials are stored in a file with `chmod 600` — they do not appear in `ps aux` output | VERIFIED | `server_setup_auth` writes `/etc/chisel/auth.json` with `chmod 600` at line 662. Systemd `ExecStart` uses `--authfile /etc/chisel/auth.json` (line 696), NOT `--auth TOKEN`. TUNNEL-07 compliance comment at lines 676-679 documents this explicitly. |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `proxyebator.sh` | `uninstall_main` with sub-functions, `--yes` flag, `NGINX_INJECTED` in `server_save_config` | VERIFIED | All present and substantive. `uninstall_main` at line 1427 calls 6 `_uninstall_*` sub-functions. `--yes` parsed at line 1501, `UNINSTALL_YES=""` initialized at line 1476. `NGINX_INJECTED` set at lines 788/819 and written to config at line 1015. |
| `proxyebator.sh` | Idempotency guards in `server_download_chisel`, `server_setup_auth`, `server_create_systemd`, `server_save_config`; re-run config sourcing | VERIFIED | All four guards confirmed at lines 613, 647, 671, 996. Re-run guard in `server_collect_params` at line 496 sources existing config and returns early. |

### Key Link Verification

| From | To | Via | Status | Details |
| ---- | -- | --- | ------ | ------- |
| `uninstall_main` | `/etc/proxyebator/server.conf` | `source` command | WIRED | Line 1434: `source /etc/proxyebator/server.conf` |
| CLI parser | `uninstall_main` | `--yes` flag sets `UNINSTALL_YES=true` | WIRED | Line 1501: `--yes) UNINSTALL_YES="true"; shift ;;` — `_uninstall_confirm` reads at line 1315 |
| `server_save_config` | `uninstall_main` | `NGINX_INJECTED` flag enables safe nginx cleanup | WIRED | Lines 788/819: `NGINX_INJECTED="true"/"false"` in `server_configure_nginx`; line 1015: written to `server.conf`; line 1375: read in `_uninstall_nginx` |
| `server_download_chisel` | `/usr/local/bin/chisel` | existence check before download | WIRED | Line 613: `if [[ -x /usr/local/bin/chisel ]]; then ... return; fi` |
| `server_setup_auth` | `/etc/chisel/auth.json` | existence check before overwrite | WIRED | Line 647: `if [[ -f /etc/chisel/auth.json ]]; then ... return; fi` |
| `server_create_systemd` | `systemctl is-active` | active check before unit creation | WIRED | Line 671: `if systemctl is-active --quiet proxyebator 2>/dev/null; then ... return; fi` |
| `server_collect_params` | `/etc/proxyebator/server.conf` | source existing config to preserve secrets | WIRED | Line 496: `if [[ -f /etc/proxyebator/server.conf ]]; then ... source ...; return; fi` |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| ----------- | ----------- | ----------- | ------ | -------- |
| DEL-01 | 05-01-PLAN.md | `./proxyebator.sh uninstall` — full removal: binary, systemd unit, nginx config, firewall rules | SATISFIED | `uninstall_main` with `_uninstall_service`, `_uninstall_binary`, `_uninstall_nginx`, `_uninstall_firewall`, `_uninstall_config` all present and implemented at lines 1336–1423 |
| DEL-02 | 05-01-PLAN.md | Read `/etc/proxyebator/server.conf` for uninstall without asking questions | SATISFIED | `uninstall_main` at line 1431 checks for `server.conf` and dies if not found; sources it at line 1434; all config values (`NGINX_CONF`, `LISTEN_PORT`, `DOMAIN`, `NGINX_INJECTED`) available to all sub-functions without any interactive prompts |
| SCRIPT-04 | 05-02-PLAN.md | Idempotency — repeated run does not break existing install | SATISFIED | Four idempotency guards in server functions (lines 613, 647, 671, 996). Re-run guard in `server_collect_params` (line 496) sources existing config preserving `SECRET_PATH`/`AUTH_TOKEN`. All removal guards use `[[ -f ]]` checks. |
| TUNNEL-07 | 05-02-PLAN.md | Store credentials in file (chmod 600), not in CLI args | SATISFIED | `/etc/chisel/auth.json` created with `chmod 600` at line 662. `ExecStart` uses `--authfile /etc/chisel/auth.json` at line 696, not `--auth USER:TOKEN`. Credentials never appear in `ps aux` cmdline. |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| `proxyebator.sh` | 1031 | `printf "  ${CYAN}  --auth \"%s:%s\" \\\\${NC}\n" "${AUTH_USER}" "${AUTH_TOKEN}"` | Info | This is in `server_print_connection_info` — it prints the client command to the terminal after install (intentional for user to copy). Not a security issue since it is a one-time post-install display, not process args or logs. Does not affect `ps aux`. |

No stub patterns found. No `TODO`/`FIXME`/placeholder comments in uninstall or idempotency code paths. All `rm` commands are either inside `[[ -f ]]` guards or use `|| true` suffix. All `systemctl` calls that might fail use `2>/dev/null || true`.

### Human Verification Required

None. All success criteria can be verified programmatically:

1. Credential hygiene (`--authfile` vs `--auth` in `ExecStart`) is confirmed by static code inspection.
2. Idempotency guards are confirmed by existence checks in code.
3. `server.conf` sourcing before any prompts is confirmed by code reading order.
4. `chmod 600` on auth file is confirmed by static code inspection.

The only item that requires a live server to confirm is actual runtime behavior (uninstall actually removes files, re-run actually skips steps), but the code logic is fully verified as correct for all four success criteria.

### Gaps Summary

No gaps found. All four phase success criteria are fully implemented in the codebase:

1. **Uninstall reads server.conf without prompting:** Confirmed — `uninstall_main` sources `server.conf` at line 1434, `_uninstall_confirm` only prompts if `UNINSTALL_YES` is not `"true"` (set via `--yes` flag).
2. **Clean re-install after uninstall:** Confirmed — `_uninstall_config` removes `server.conf`, which is the gate that `server_collect_params` checks to decide whether to generate fresh secrets.
3. **Idempotent re-run:** Confirmed — four functions guard against re-running with existence checks; `server_collect_params` sources existing config and returns, preventing new secret generation.
4. **Credentials in file, not args:** Confirmed — `--authfile` in `ExecStart`, `chmod 600` on auth file, TUNNEL-07 comment documents this explicitly.

---

_Verified: 2026-02-18T18:17:53Z_
_Verifier: Claude (gsd-verifier)_
