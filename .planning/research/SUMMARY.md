# Project Research Summary

**Project:** Proxyebator — masked WebSocket proxy tunnel deployment script
**Domain:** Censorship-resistant proxy infrastructure automation (bash deployment tooling)
**Researched:** 2026-02-18
**Confidence:** HIGH

## Executive Summary

Proxyebator fills a genuine gap in the proxy deployment landscape: no existing single-script tool combines WebSocket tunnel deployment (Chisel or wstunnel), nginx website masquerading, and automated TLS into one command. Outline-server is the closest competitor but uses Shadowsocks (detectable by DPI) without any HTTP masquerade. The correct implementation approach is a single bash script with a mode dispatcher (`server | client | uninstall`), granular functions for each concern, and a strict build order driven by infrastructure dependencies: OS detection and validation first, then dependency installation, binary download, TLS acquisition, config generation, service activation, and finally post-install verification. This pattern is proven by tools like openvpn-install.sh and docker-install.sh.

The recommended default tunnel backend is Chisel (built-in auth via authfile, SOCKS5 first-class, simpler security model) with wstunnel as a user-selectable alternative. nginx handles TLS termination and masquerade, certbot provides Let's Encrypt certificates, and systemd manages the tunnel process as an unprivileged `nobody` user. Cloudflare should default to "grey cloud" (DNS-only) to avoid WebSocket corruption; the script must document the orange-cloud requirement for `--keepalive 25s`. The entire stack runs on Debian 12 and Ubuntu 22.04/24.04, using only tools already present on a minimal VPS.

The top risks are all config-generation correctness issues, not architecture issues: the nginx location block must have a trailing slash in `proxy_pass`, must include `proxy_buffering off`, and the Chisel systemd unit must use `--host 127.0.0.1 -p 7777` as separate flags rather than a combined `-p 127.0.0.1:7777`. All three failures produce tunnels that appear functional (systemd reports active) but either expose the tunnel port publicly or pass no data. Post-install verification steps using `ss`, `curl`, and `systemctl` are non-negotiable.

---

## Key Findings

### Recommended Stack

The stack is deliberately minimal: proven system packages (nginx, certbot, systemd) plus two small Go binaries downloaded at deploy time from GitHub releases. No Docker, no interpreted language runtimes, no databases. The script itself is pure bash, using only `curl`, `openssl`, and `grep` for tooling.

**Core technologies:**
- **Chisel** (default) — SSH-over-WebSocket tunnel with SOCKS5 and built-in authfile authentication; credentials never appear in `ps aux`
- **wstunnel** (alternative) — lighter, no SSH layer; security fully delegated to nginx secret path; binary name changed to `wstunnel-cli` in v10+, script must detect this
- **nginx** — TLS termination and WebSocket proxy with three masquerade modes (stub HTML, reverse-proxy to cover URL, static files); nginx config belongs in `sites-available/sites-enabled` on Debian-family, `conf.d/` on RedHat/Arch
- **certbot + Let's Encrypt** — automated TLS; Cloudflare Origin certs must never be used (CF blocks binary WebSocket traffic)
- **systemd** — process supervision as `User=nobody`; `Restart=always` for DPI-induced drops; `--authfile` over `--auth` flag

### Expected Features

**Must have (table stakes):**
- One-command server install with auto-generated secret path and auth token
- Printed copy-paste client connection command after server install
- systemd service with auto-restart (`Restart=always`, `RestartSec=5`)
- TLS via Let's Encrypt with auto-renewal timer verified post-install
- Website masquerading — real-looking HTTPS site on `/`, tunnel only at secret path
- Firewall automation (ufw rule verification, port conflict detection)
- Post-install verification: `ss` port check, `curl` through SOCKS5, external IP confirmation
- Idempotent re-runs (check-before-install for cert, binary, service)
- `uninstall` mode that mirrors install exactly
- README with numbered copy-paste steps and GUI client configuration snippets (nekoray, nekobox, Proxifier, Surge)

**Should have (differentiators):**
- Dual tunnel backend (Chisel default, wstunnel selectable at install time)
- Three masquerade modes: stub, proxy-url, static-path
- `client` mode that downloads binary and optionally creates user-scope systemd autostart
- Arch detection (amd64/arm64) for correct binary download URL
- Cloudflare grey-cloud documentation with `--keepalive 25s` warning for orange-cloud users
- TUN routing loop documentation per GUI client (processName exclusion rules)
- DNS leak documentation (SOCKS5h vs SOCKS5, remote DNS requirement)

**Defer (v2+):**
- Multi-user support (multiple auth entries, user management subcommand)
- CDN domain fronting / Cloudflare Worker routing
- `rotate` subcommand for secret/token rotation without full reinstall
- `update` subcommand for binary-only refresh
- Config file persistence for short `proxyebator connect` command
- wstunnel second backend polishing (v1 proves the path with Chisel first)

### Architecture Approach

The script is a single file organized as: shebang + `set -euo pipefail`, library functions, validation, OS detection, secret generation, dependency installation, binary download, config generation (nginx + systemd + auth), service activation, post-install verification, output printer, then mode-specific `server_main()`, `client_main()`, `uninstall_main()`, and a mode dispatcher at the very bottom. Functions are granular (one concern each) to allow retry of failed steps and clean mirroring in uninstall. State is persisted to `/etc/proxyebator/server.conf` (key=value) so uninstall can clean exactly what was installed.

**Major components:**
1. **Entry Point / Dispatcher** — parses `$1`, routes to mode function; emits usage if no args
2. **OS Detection** — sources `/etc/os-release`, maps `$ID` to `$PKG_INSTALL`, `$OS_FAMILY`, nginx config path
3. **Interactive Prompts** — collects tunnel type, domain, port, masquerade mode; sets `$TUNNEL_TYPE`, `$DOMAIN`, `$MASQUERADE_MODE`
4. **Secret Generator** — `openssl rand -hex 16` for path (128-bit entropy), `openssl rand -base64 24` for auth token
5. **Binary Downloader** — GitHub API version query (grep, no jq dependency), arch detection, extract with binary name detection for wstunnel v10+
6. **TLS Setup** — certbot with cert-existence check before invocation; renewal timer explicitly enabled and verified
7. **Config Writers** — nginx heredoc (variables interpolated, `$http_upgrade` escaped), systemd unit heredoc, auth.json; written to correct distro-specific paths
8. **Service Activator** — `nginx -t && systemctl reload nginx`; `systemctl daemon-reload && systemctl enable --now`
9. **Verification Suite** — `ss -tlnp` port check, `curl` HTTPS cover site (200), `curl --socks5-hostname` external IP; explicit pass/fail output
10. **Output Printer** — full copy-paste client command, SOCKS5 coordinates, GUI client instructions, TUN exclusion rules, DNS leak warning

### Critical Pitfalls

1. **nginx proxy_pass missing trailing slash** — WebSocket handshake fails with 404 or tunnel connects but data never flows. Always use `proxy_pass http://127.0.0.1:PORT/;` and verify with a curl WebSocket upgrade test after configuration.

2. **Missing `proxy_buffering off` in nginx location** — tunnel reports connected, SOCKS5 port is open, but all requests hang. Include unconditionally in every WebSocket location block; there is no scenario where buffering is correct for this use case.

3. **Chisel binding to 0.0.0.0 due to `-p 127.0.0.1:7777` format** — complete security bypass; tunnel port is publicly reachable without authentication. Always emit `--host 127.0.0.1` and `-p 7777` as separate systemd ExecStart tokens. Verify with `ss -tlnp` post-install and fail loudly if wrong.

4. **wstunnel v10+ binary renamed to `wstunnel-cli`** — script reports installed but service never starts. After tar extraction, detect actual binary name before moving to `/usr/local/bin/wstunnel`.

5. **Certbot rate limit from repeated invocations** — user locked out of TLS for up to 7 days. Check `/etc/letsencrypt/live/$DOMAIN/` existence and validity before any certbot call; use `--staging` during development.

6. **Cloudflare orange cloud breaking binary WebSocket** — drops every ~100 seconds or binary corruption. Default to grey cloud; document keepalive requirement for orange cloud mode prominently in README.

7. **Chisel `socks` vs `R:socks` in client instructions** — silent failure: SOCKS5 works but traffic exits from client IP. Hardcode `socks` (no prefix) in generated commands; add explicit IP verification step.

---

## Implications for Roadmap

Based on the dependency graph in ARCHITECTURE.md, the implementation must follow strict sequencing. The infrastructure dependency chain is: OS detection → system dependencies → binary download → TLS → config generation → service start → verification → output. These cannot be reordered. Feature groups follow naturally from this chain.

### Phase 1: Script Foundation and OS Detection

**Rationale:** Everything else depends on knowing the OS family, having utility functions, and having validated the environment. This is the scaffolding before any real work. Matches the "Phase 1: Foundation" dependency group in ARCHITECTURE.md.

**Delivers:** Working bash script skeleton with `set -euo pipefail`, mode dispatcher, `log()`/`die()`/`confirm()` utilities, root check, `detect_os()`, `detect_arch()`, distro abort guard for non-Debian/Ubuntu, and `gen_secret_path()`/`gen_auth_token()`.

**Addresses:** One-command install (precondition), idempotency foundation
**Avoids:** Multi-distro package name pitfalls (Pitfall 13), no-jq dependency requirement

### Phase 2: Server Mode — Infrastructure Setup

**Rationale:** The server install is the core product. All other modes (client, uninstall) depend on it having run first. Within server mode, the strict dependency order is: install packages → download binary → certbot (requires nginx present) → write configs → start service.

**Delivers:** Full `server_main()` flow: `install_deps()` (nginx, certbot, curl), `download_chisel()` (GitHub API + arch detection), `run_certbot()` with cert-existence guard, `write_nginx_conf()` with all three masquerade modes, `write_auth_json()`, `write_systemd_unit()` (Chisel only), `enable_tunnel_service()`, `reload_nginx()`, state file at `/etc/proxyebator/server.conf`.

**Addresses:** One-command install, systemd auto-restart, TLS + Let's Encrypt, website masquerading, firewall verification, printed client command
**Avoids:** Trailing slash pitfall (Pitfall 1), buffering pitfall (Pitfall 2), 0.0.0.0 binding pitfall (Pitfall 3), certbot rate limit (Pitfall 6), root service pitfall (Pitfall 16), credentials in ps aux (Pitfall 17), certbot timer not enabled (Pitfall 15)

### Phase 3: Post-Install Verification Suite

**Rationale:** Research identified that multiple critical failures are invisible to normal status checks (systemd reports active, nginx -t passes, but data doesn't flow). A dedicated verification step is not optional — it's the only way to catch Pitfalls 2 and 3. This phase must run before the output printer.

**Delivers:** `verify_server()` suite: `verify_service_active()`, `verify_port_localhost()` with `ss -tlnp` asserting `127.0.0.1:PORT` not `0.0.0.0`, `verify_nginx_cover_site()` (HTTP 200 on `/`), `verify_socks_proxy()` (`curl --socks5-hostname` through tunnel to external IP check), explicit pass/fail output for each check.

**Addresses:** Status/health check command, debugging capability
**Avoids:** Silent buffering failure (Pitfall 2), silent 0.0.0.0 binding (Pitfall 3)

### Phase 4: Client Mode and Output

**Rationale:** With server mode working and verified, the client experience can be built. Client mode is structurally simpler (download binary, optionally create user systemd unit, connect and verify). The output printer for both modes belongs here since it depends on all config vars being set.

**Delivers:** `client_main()` flow (binary download, optional `~/.config/systemd/user/` autostart unit, foreground connect, SOCKS5 verification), `print_connection_params()` with full copy-paste command, GUI client instructions (nekoray, nekobox, Proxifier, Surge), TUN mode routing exclusion rules per client, DNS leak warning, Cloudflare orange-cloud keepalive note.

**Addresses:** One-command client setup, SOCKS5 on localhost:1080, split tunneling snippets, AI-agent-friendly README format
**Avoids:** `R:socks` vs `socks` confusion (Pitfall 9), TUN routing loop (Pitfall 10), DNS leaks (Pitfall 11)

### Phase 5: Uninstall Mode and Robustness

**Rationale:** Uninstall mirrors install. With the install structure finalized in Phases 2-4, uninstall can be written as an exact reverse. Robustness features (signal traps, idempotency guards) also belong here since they require the full install flow to be known.

**Delivers:** `uninstall_main()` (stop+disable services, remove binaries, remove configs, reload nginx, optional cert revocation, optional package purge), `trap INT TERM EXIT cleanup`, idempotency guards (check-before-install for cert, binary, service, nginx config), GitHub API fallback hardcoded version constant, port conflict detection with 2087/8443 fallback offer.

**Addresses:** Uninstall command, idempotent re-runs
**Avoids:** Partial state on Ctrl+C (Pitfall 12), certbot rate limit from re-runs (Pitfall 6), port 443 conflict (Pitfall 5), GitHub rate limit (Pitfall 18)

### Phase 6: wstunnel Backend and Polish

**Rationale:** Chisel path should be proven end-to-end before adding the second backend. wstunnel has its own quirks (v10+ binary naming, no built-in auth, `--restrict-http-upgrade-path-prefix` incompatibility with nginx trailing slash). Adding it after Chisel is stable reduces debugging surface area.

**Delivers:** `download_wstunnel()` with binary name detection (`wstunnel-cli` vs `wstunnel`), `write_wstunnel_systemd_unit()` (no authfile, no `--restrict-http-upgrade-path-prefix`), user-selectable tunnel type at install prompt, wstunnel client instructions (wss:// URL format, `-L socks5://` flag), port strategy (1082 for wstunnel vs 1080 for Chisel).

**Addresses:** Dual backend support differentiator
**Avoids:** wstunnel binary name pitfall (Pitfall 7), `--restrict-http-upgrade-path-prefix` conflict (Pitfall 8)

### Phase Ordering Rationale

- Phases 1-2 ordered by hard infrastructure dependency (can't install without OS detection, can't configure without nginx installed)
- Phase 3 inserted before user-facing output because silent failures must be caught before telling the user "it worked"
- Phase 4 deferred until server is verified end-to-end — client mode is useless without a working server
- Phase 5 deferred until install structure is final — uninstall must mirror exactly what was installed
- Phase 6 last because it adds complexity on top of a proven pattern, not a new pattern

### Research Flags

Phases with well-documented patterns (skip deeper research):
- **Phase 1:** Standard bash script patterns; thoroughly documented in project's own reference docs
- **Phase 2:** All nginx, certbot, and systemd patterns are validated in project's tunnel-reference.md from real deployments
- **Phase 3:** `ss`, `curl`, `systemctl` commands are standard; specific flags documented in ARCHITECTURE.md
- **Phase 5:** Uninstall pattern is straightforward reverse of install

Phases that may benefit from validation during implementation:
- **Phase 4 (client TUN rules):** Per-client routing exclusion rules for nekoray/nekobox/Throne may have changed with application updates; verify against current client versions
- **Phase 6 (wstunnel):** wstunnel v10+ API changes are documented but should be verified against live GitHub release to confirm current binary name and flag names before finalizing

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Core technology choices (nginx, certbot, systemd, Chisel, wstunnel) validated from project's own tunnel-reference.md from real production deployments. Only Chisel version number is MEDIUM (referenced as v1.11.3 but not verified against live GitHub API) |
| Features | MEDIUM-HIGH | Table stakes and differentiators well-understood from domain knowledge and comparable tools; GUI client configuration details verified against multiple sources but may drift as apps update |
| Architecture | HIGH | Script structure, function boundaries, data flow, and build order validated from project's PROXY-GUIDE.md and tunnel-reference.md. Anti-patterns documented from actual debugging sessions |
| Pitfalls | HIGH | All critical pitfalls documented from real operational experience in project reference docs. "Discovered through debugging" attribution means these are not theoretical — they were actually hit |

**Overall confidence:** HIGH

### Gaps to Address

- **wstunnel current flag names:** wstunnel changed API significantly between v3 and v10. Reference docs cover the current behavior but should be verified against live GitHub README before Phase 6 implementation to catch any further changes.
- **nekobox/nekoray current status:** Project may have been renamed or reorganized in 2024-2025. README client instructions should link to current repository URLs, verified at implementation time.
- **Cloudflare CDN compatibility boundary:** The research establishes grey cloud as safe and orange cloud as risky-but-workable-with-keepalive. The exact CF plans and policies may have changed; README should note this is based on operational experience and may drift.
- **Certbot package path on RHEL-family:** The primary target is Debian/Ubuntu (the script aborts on other distros), so this is low priority for v1 but worth noting for future expansion.

---

## Sources

### Primary (HIGH confidence)
- `/home/kosya/vibecoding/proxyebator/tunnel-reference.md` — Real-deployment reference with validated CLI flags, nginx config, and debugging notes (2026-02-18)
- `/home/kosya/vibecoding/proxyebator/PROXY-GUIDE.md` — Full architecture reference, threat model, and operational "grablii" (gotchas) from production use

### Secondary (MEDIUM confidence)
- Domain knowledge: chisel v1.x README (jpillora/chisel), wstunnel README (erebe/wstunnel), outline-server docs, algo VPN, streisand archived docs, training data through August 2025
- Community bash patterns: openvpn-install.sh, angristan/wireguard-install (multi-distro single-script deployment model)
- GUI client docs: nekobox/nekoray GitHub READMEs, Proxifier manual, Surge documentation, ClashX/Clash Verge community docs

### Reference URLs
- Chisel: https://github.com/jpillora/chisel
- wstunnel: https://github.com/erebe/wstunnel
- nginx WebSocket proxying: https://nginx.org/en/docs/http/websocket.html
- certbot: https://certbot.eff.org/

---
*Research completed: 2026-02-18*
*Ready for roadmap: yes*
