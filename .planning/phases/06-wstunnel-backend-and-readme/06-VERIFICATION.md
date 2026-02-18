---
phase: 06-wstunnel-backend-and-readme
verified: 2026-02-18T19:10:00Z
status: passed
score: 5/5 success criteria verified
re_verification: false
---

# Phase 6: wstunnel Backend and README Verification Report

**Phase Goal:** Users can choose wstunnel as an alternative to Chisel at install time, and any human or AI agent can deploy the full stack by following the README
**Verified:** 2026-02-18T19:10:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Running `./proxyebator.sh server` and selecting wstunnel produces a working masked tunnel with the same verification suite passing as Chisel | VERIFIED | `server_main` branches on `TUNNEL_TYPE==wstunnel`: calls `server_download_wstunnel` + `server_create_systemd_wstunnel`; then runs `verify_main` which reads `TUNNEL_PORT` from `server.conf`; all 7 checks use `${TUNNEL_PORT}` — no hardcoded 7777 |
| 2 | The README contains a shields.io badge header, parameter tables, and `<details>` collapsible sections | VERIFIED | `div align="center"` at line 1; 5 shields.io badges (Platform, Shell, License, Chisel, wstunnel); 3 tables (OS, CLI flags, server.conf vars); 6 `<details>` blocks |
| 3 | The README contains copy-paste SOCKS5 setup instructions for Throne (Linux), nekoray/nekobox (Linux/Windows), and Proxifier (Windows/macOS) | VERIFIED | Throne: 8 occurrences with TUN loop rules; nekoray/nekobox: 4 occurrences with archive notice; Proxifier: 3 occurrences with step-by-step instructions — all inside single `<details>` block |
| 4 | The README contains a "Copy this and send to your AI assistant" block with numbered deployment steps that an AI agent can follow without additional context | VERIFIED | Section "Скопируй это и отправь AI-ассистенту" at line 369; numbered steps 1–7 including SSH, curl download, chmod, `./proxyebator.sh server --domain ... --tunnel chisel`, "ALL CHECKS PASSED" confirmation; requirements and anti-patterns listed |
| 5 | The README contains a troubleshooting section covering the known pitfalls: Cloudflare orange cloud, DNS leaks, TUN routing loops | VERIFIED | Lines 409-418: Cloudflare orange cloud (CDN WebSocket buffering + solution), DNS leak (SOCKS remote DNS + Throne TUN), TUN routing loop (`processName chisel/wstunnel -> direct` rules) |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `proxyebator.sh` | wstunnel backend alongside chisel, contains `server_download_wstunnel` | VERIFIED | 1729 lines; bash -n passes; 85 occurrences of "wstunnel"; all 4 new functions present (server_download_wstunnel, server_create_systemd_wstunnel, client_download_wstunnel, client_run_wstunnel) |
| `README.md` | Complete project documentation in Russian, min 300 lines, contains shields.io | VERIFIED | 447 lines; Russian throughout; 5 shields.io badges; 6 `<details>` blocks; 3 parameter tables |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `server_collect_params` | `TUNNEL_TYPE` variable | Interactive prompt or `--tunnel` flag | VERIFIED | Lines 528-538: `if [[ -z "$TUNNEL_TYPE" ]]; then ... read -r TUNNEL_TYPE; fi; TUNNEL_TYPE="${TUNNEL_TYPE:-chisel}"; case: chisel\|wstunnel` |
| `server_main` | `server_download_wstunnel / server_create_systemd_wstunnel` | `if TUNNEL_TYPE == wstunnel` branch | VERIFIED | Lines 1374-1381: explicit branch on `TUNNEL_TYPE`, dispatches to correct function pair for each backend |
| `generate_tunnel_location_block` | `TUNNEL_PORT` | Variable interpolation in `proxy_pass` | VERIFIED | Line 854: `proxy_pass http://127.0.0.1:${TUNNEL_PORT:-7777}/;` — dynamic, not hardcoded |
| `server_save_config` | `TUNNEL_PORT` | Conditional port assignment | VERIFIED | Lines 1096-1097: `TUNNEL_TYPE=${TUNNEL_TYPE}` and `TUNNEL_PORT=${TUNNEL_PORT}` written dynamically to `server.conf` |
| `README.md` | `proxyebator.sh` | Documented CLI commands and flags | VERIFIED | 19 occurrences of `proxyebator.sh` in README; all commands reference actual script flags |
| `README.md AI block` | `server mode` | Copy-paste deployment steps | VERIFIED | Line 382: `sudo ./proxyebator.sh server --domain МОЙДОМЕН.COM --tunnel chisel` with numbered steps |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| TUNNEL-04 | 06-01-PLAN.md | wstunnel: запуск сервера с корректными v10+ флагами | SATISFIED | `server_create_systemd_wstunnel` creates unit with `ExecStart=/usr/local/bin/wstunnel server ws://127.0.0.1:7778`; `server_download_wstunnel` uses `.tar.gz` extraction; fallback version `v10.5.2`; binary name `wstunnel` (not `wstunnel-cli`) |
| DOC-01 | 06-02-PLAN.md | README с центрированным заголовком и shields.io бейджами | SATISFIED | `<div align="center">` at line 1; 5 shields.io badge URLs |
| DOC-02 | 06-02-PLAN.md | Таблицы с параметрами, переменными, поддерживаемыми ОС | SATISFIED | OS table (line 41), CLI flags table (line 86), server.conf vars table (line 104) |
| DOC-03 | 06-02-PLAN.md | Разворачиваемые `<details>` блоки | SATISFIED | 6 `<details>` blocks: Quick start, Server details, Client, GUI clients, Uninstall, Troubleshooting |
| DOC-04 | 06-02-PLAN.md | Инструкции для GUI-клиентов: Throne, nekoray/nekobox, Proxifier, Surge | SATISFIED | All four documented inside `<details>` block; Throne with TUN loop prevention rules; nekoray with archive notice; Proxifier with step-by-step; Surge with ini config example |
| DOC-05 | 06-02-PLAN.md | Блок «Скопируй это и отправь AI-ассистенту» с пошаговой инструкцией | SATISFIED | Lines 369-400: section header, blockquote intro, fenced code block with 7-step deployment, requirements, anti-patterns list |
| DOC-06 | 06-02-PLAN.md | Раздел troubleshooting с типичными проблемами | SATISFIED | Lines 404-441: `<details>` block with 9-row table covering Cloudflare, DNS leaks, TUN loop, trailing slash, buffering, port exposure, certbot failure + diagnostic commands |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `proxyebator.sh` | 776 | Comment mentioning `--restrict-http-upgrade-path-prefix` | Info | Comment only — documents why the flag is NOT used; the flag does not appear in any ExecStart or function call |

No blockers or warnings found. The one comment is explicitly a documentation of a pitfall avoided, not anti-pattern usage.

### Human Verification Required

#### 1. wstunnel Server End-to-End Tunnel

**Test:** On a real Linux VPS: `sudo ./proxyebator.sh server --domain example.com --tunnel wstunnel` then run `./proxyebator.sh verify`
**Expected:** All 7 checks PASS including tunnel port bound to 127.0.0.1:7778, WebSocket path reachable, TLS valid
**Why human:** Cannot run systemd, nginx, certbot, or network operations in static analysis environment

#### 2. wstunnel Client SOCKS5 Connectivity

**Test:** After server install with wstunnel, run `./proxyebator.sh client --host DOMAIN --port 443 --path /SECRET/ --tunnel wstunnel` then `curl --socks5-hostname localhost:1080 https://ifconfig.me`
**Expected:** Returns server's public IP (not client's)
**Why human:** Requires live wstunnel server and network connection to verify SOCKS5 tunnel function

#### 3. README Rendering on GitHub

**Test:** Push README.md to a GitHub repository and view it in browser
**Expected:** `<details>` blocks expand/collapse correctly; shields.io badges render as images; centered header renders properly; no broken Markdown
**Why human:** GitHub Markdown rendering differs from local preview; `<details>` blocks require blank lines after `<summary>` tag which cannot be visually confirmed without a browser

### Gaps Summary

No gaps found. All 5 success criteria are verified against the actual codebase. All 7 requirement IDs (TUNNEL-04, DOC-01 through DOC-06) have implementation evidence. The wstunnel backend is fully integrated: download function, systemd service, nginx TUNNEL_PORT variable, firewall, uninstall branching, client mode, connection info output, and all verification suite checks use the dynamic TUNNEL_PORT read from server.conf. The README is substantive (447 lines), structured per specification, and self-contained for both human and AI-agent deployment.

---

_Verified: 2026-02-18T19:10:00Z_
_Verifier: Claude (gsd-verifier)_
