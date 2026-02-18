# Roadmap: Proxyebator

## Overview

Six phases deliver a complete masked WebSocket proxy deployment tool. Phase 1 builds the bash foundation every other phase depends on. Phase 2 delivers the full server installation — the core product value. Phase 3 makes the invisible visible with a post-install verification suite. Phase 4 adds the client mode that connects a user's machine to a running server. Phase 5 rounds out robustness with uninstall, idempotency, and credential hygiene. Phase 6 adds the second tunnel backend (wstunnel) and the README that enables AI-agent-driven deployment.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Script Foundation** - Bash skeleton, OS/arch detection, utility functions, secret generation (completed 2026-02-18)
- [ ] **Phase 2: Server Core** - Full server install: dependencies, binary download, nginx masking, TLS, systemd service
- [ ] **Phase 3: Verification Suite** - Post-install checks that catch silent failures before telling user it works
- [ ] **Phase 4: Client Mode** - Client binary download, SOCKS5 connection, GUI client output
- [ ] **Phase 5: Uninstall and Robustness** - Full uninstall, idempotency guards, credential file hygiene
- [ ] **Phase 6: wstunnel Backend and README** - Second tunnel backend, complete Russian README with AI-agent block

## Phase Details

### Phase 1: Script Foundation
**Goal**: Users have a runnable bash script with working OS/arch detection, colored logging, and generated secrets
**Depends on**: Nothing (first phase)
**Requirements**: SCRIPT-01, SCRIPT-02, SCRIPT-03, SCRIPT-05
**Success Criteria** (what must be TRUE):
  1. Running `./proxyebator.sh` without args prints usage showing `server`, `client`, `uninstall` modes
  2. Script correctly identifies Debian/Ubuntu/CentOS/Fedora/Arch and prints the detected OS and package manager
  3. Script correctly detects amd64 and arm64 architecture and prints it
  4. Colored log messages (info, warn, die) are visible in terminal output during any mode
  5. Running `./proxyebator.sh server` generates and prints a 32-char hex secret path and a 32-char base64 auth token
**Plans**: 2 plans

Plans:
- [ ] 01-01-PLAN.md — Script skeleton: shebang, safety flags, ANSI colors, logging functions, usage, mode stubs, CLI dispatcher
- [ ] 01-02-PLAN.md — Detection + secrets: detect_os, detect_arch, check_root, gen_secret_path, gen_auth_token, server_main wired

### Phase 2: Server Core
**Goal**: Users can run `./proxyebator.sh server` on a fresh Debian/Ubuntu VPS and get a running masked Chisel tunnel with HTTPS and a website decoy
**Depends on**: Phase 1
**Requirements**: SCRIPT-06, TUNNEL-01, TUNNEL-02, TUNNEL-03, TUNNEL-05, TUNNEL-06, MASK-01, MASK-02, MASK-03, MASK-04, MASK-05, MASK-06, SRV-01, SRV-02, SRV-03, SRV-04
**Success Criteria** (what must be TRUE):
  1. After running `server` mode, `systemctl status proxyebator` shows `active (running)` and the service auto-restarts when killed
  2. The tunnel port is bound to `127.0.0.1` only — `ss -tlnp` shows `127.0.0.1:PORT` not `0.0.0.0:PORT`
  3. `curl https://yourdomain.com/` returns HTTP 200 with the decoy website content (stub, proxied URL, or static files — per user choice)
  4. `curl https://yourdomain.com/secret-path` returns a WebSocket upgrade response, not a 404
  5. firewall allows 80/443 and blocks the tunnel port from external access
  6. `/etc/proxyebator/server.conf` exists with domain, port, path, tunnel type, and masquerade mode recorded
**Plans**: 4 plans

Plans:
- [ ] 02-01-PLAN.md — Interactive param collection (domain, masquerade, port), pre-install summary, dependency auto-install
- [ ] 02-02-PLAN.md — Chisel binary download from GitHub, auth file creation, systemd service
- [ ] 02-03-PLAN.md — nginx configuration with three masquerade modes, TLS via certbot
- [ ] 02-04-PLAN.md — Firewall (ufw/iptables), config save, post-install verification, connection info

### Phase 3: Verification Suite
**Goal**: Every silent failure mode is caught and reported explicitly before the user is told installation succeeded
**Depends on**: Phase 2
**Requirements**: VER-01, VER-02, VER-03
**Success Criteria** (what must be TRUE):
  1. After server install, the script prints PASS/FAIL for each check: systemd active, port binding, nginx cover site, WebSocket upgrade
  2. If the tunnel port is bound to 0.0.0.0 instead of 127.0.0.1, the script prints a FAIL and exits non-zero before printing "installation complete"
  3. After all checks pass, the script prints a complete connection block: host, port, secret path, auth token, and a copy-paste client command
**Plans**: TBD

### Phase 4: Client Mode
**Goal**: Users can run `./proxyebator.sh client` on Linux, macOS, or Windows (WSL) and get a working SOCKS5 proxy on localhost:1080
**Depends on**: Phase 3
**Requirements**: CLI-01, CLI-02, CLI-03, CLI-04
**Success Criteria** (what must be TRUE):
  1. Running `./proxyebator.sh client` prompts for host, port, secret path, and password then connects and shows Chisel client output
  2. After connecting, `curl --socks5-hostname localhost:1080 https://ifconfig.me` returns the server's external IP (not the client's)
  3. Client mode works on Linux, macOS, and Windows via WSL without code changes
  4. After connection, the script prints SOCKS5 address (`127.0.0.1:1080`) and per-client GUI setup instructions (Throne, Proxifier, nekoray)
**Plans**: TBD

### Phase 5: Uninstall and Robustness
**Goal**: Users can cleanly remove all installed components and re-run the install script on an already-configured server without breakage
**Depends on**: Phase 4
**Requirements**: DEL-01, DEL-02, SCRIPT-04, TUNNEL-07
**Success Criteria** (what must be TRUE):
  1. Running `./proxyebator.sh uninstall` stops and removes the systemd service, binary, nginx config, and firewall rules without prompting for config values
  2. After uninstall, re-running `./proxyebator.sh server` installs cleanly from scratch
  3. Re-running `./proxyebator.sh server` on an already-configured server detects existing cert, binary, and service and skips those steps rather than failing or duplicating
  4. Chisel auth credentials are stored in a file with `chmod 600` — they do not appear in `ps aux` output
**Plans**: TBD

### Phase 6: wstunnel Backend and README
**Goal**: Users can choose wstunnel as an alternative to Chisel at install time, and any human or AI agent can deploy the full stack by following the README
**Depends on**: Phase 5
**Requirements**: TUNNEL-04, DOC-01, DOC-02, DOC-03, DOC-04, DOC-05, DOC-06
**Success Criteria** (what must be TRUE):
  1. Running `./proxyebator.sh server` and selecting wstunnel produces a working masked tunnel with the same verification suite passing as Chisel
  2. The README contains a shields.io badge header, parameter tables, and `<details>` collapsible sections
  3. The README contains copy-paste SOCKS5 setup instructions for Throne (Linux), nekoray/nekobox (Linux/Windows), and Proxifier (Windows/macOS)
  4. The README contains a "Copy this and send to your AI assistant" block with numbered deployment steps that an AI agent can follow without additional context
  5. The README contains a troubleshooting section covering the known pitfalls: Cloudflare orange cloud, DNS leaks, TUN routing loops
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Script Foundation | 0/2 | Complete    | 2026-02-18 |
| 2. Server Core | 0/4 | Planned | - |
| 3. Verification Suite | 0/? | Not started | - |
| 4. Client Mode | 0/? | Not started | - |
| 5. Uninstall and Robustness | 0/? | Not started | - |
| 6. wstunnel Backend and README | 0/? | Not started | - |
