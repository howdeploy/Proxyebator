# Feature Landscape

**Domain:** Masked WebSocket proxy tunnel deployment scripts (chisel/wstunnel)
**Researched:** 2026-02-18
**Overall confidence:** MEDIUM-HIGH (based on deep domain knowledge of chisel, wstunnel, outline-server, streisand, algo, netch, nekobox, nekoray, Proxifier, Surge; training data through Aug 2025; no live fetch available in this session)

---

## Table Stakes

Features users expect from proxy tunnel deployment scripts. Missing = product feels broken or untrustworthy.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **One-command server install** | Every comparable tool (outline-server, algo, streisand) does it; users demand zero-ops setup | Low | `curl ... | bash` or `wget ... | bash` idiom; installs binary + creates systemd unit |
| **One-command client setup** | Corresponding client config must be equally frictionless | Low | Download binary + print single command to run |
| **SOCKS5 output on localhost** | All mainstream GUI clients (Proxifier, Surge, nekoray, nekobox) consume SOCKS5 natively; users know this interface | Low | Chisel: `--socks5`; wstunnel: `--socks5-reverse`; bind `127.0.0.1:1080` by default |
| **TLS/HTTPS transport (wss://)** | Unencrypted WS is trivially detected and blocked; users in censored environments need TLS | Medium | Use system certs via Let's Encrypt or self-signed with fingerprint pinning |
| **Shared secret / password auth** | Prevent open relay abuse; chisel `--auth user:pass`, wstunnel has `--restrict-to` | Low | Must be auto-generated and printed; user shouldn't need to invent it |
| **Systemd service on server** | Server must survive reboots and crashes without user intervention | Low | `systemctl enable --now proxyebator` pattern; write unit file during install |
| **Firewall rule automation** | ufw/iptables rules must be set; forgot-firewall is #1 support complaint | Low | Open only the needed port (443 or 80 or custom); close everything else by default |
| **Status / health check command** | Users need to verify the tunnel is live; `proxyebator status` equivalent | Low | Check systemd service state + curl through SOCKS5 + print external IP |
| **Printed client connection string** | After server install, output the exact command the client must run; no manual assembly | Low | Critical UX: print `wstunnel client wss://user:pass@host:443 --socks5 127.0.0.1:1080` |
| **README with copy-paste instructions** | Users share scripts; README must be self-contained for non-technical recipients | Low | Explicitly AI-agent-friendly phrasing; step-by-step numbered list |
| **Idempotent re-runs** | Script run twice must not break the server or duplicate systemd units | Medium | Check-before-install pattern; `systemctl is-active` guard |
| **Basic logging** | Users must be able to see what the tunnel is doing when something goes wrong | Low | Systemd journal by default; `journalctl -u proxyebator -f` in README |

---

## Differentiators

Features that distinguish proxyebator from raw binary usage or generic scripts.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Website masquerading (reverse proxy behind real site)** | Core pitch — traffic looks like HTTPS to a legitimate website; DPI cannot distinguish | High | Nginx/Caddy in front; upgrade `/ws` path only; serve real content on `/`; requires domain + DNS |
| **Domain fronting or CDN routing** | Routes traffic through CDN (Cloudflare); origin IP is hidden from observer | High | Cloudflare Worker or plain CF proxy; wstunnel header rewrite (`--http-upgrade-path-prefix`) |
| **Automatic Let's Encrypt cert** | No manual cert management; Caddy handles renewal transparently | Medium | `caddy reverse-proxy` or `certbot --nginx`; prerequisite: valid domain pointing to server |
| **Dual binary support (chisel + wstunnel)** | Different censorship environments prefer different tools; wstunnel has better obfuscation, chisel has better ecosystem | Medium | Detect or let user choose at install time; both produce same SOCKS5 output |
| **Connection keep-alive + auto-reconnect on client** | Long-lived tunnels drop; client must reconnect silently without user action | Low | wstunnel `--nb-retry-attempt 0` (infinite); chisel built-in reconnect |
| **Multi-hop / relay support** | Chained servers hide server origin further | High | wstunnel supports stdin/stdout chaining; chisel server-to-server; defer to Phase 2+ |
| **Split tunneling config snippets** | Print Proxifier/Surge rule examples that route only blocked domains through SOCKS5 | Low | Text output; no code needed; high user value |
| **AI-agent-friendly README format** | README structured so AI agents (Claude, GPT) can parse and execute instructions autonomously | Low | Numbered steps, explicit commands in fenced code blocks, no ambiguous prose |
| **Uninstall command** | Clean removal without orphaned systemd units, firewall rules, or binaries | Low | Mirror of install; `proxyebator uninstall` |
| **Update command** | Pull latest binary release without re-running full setup | Low | `proxyebator update` — fetch latest GitHub release tag, replace binary, restart service |
| **Multiple users / keys** | Server can serve multiple clients with different credentials | Medium | chisel: comma-separated `user:pass` in config; wstunnel: multiple `--restrict-to` |
| **Config file persistence** | Store server URL, credentials, port in `~/.config/proxyebator/config` so client command is short | Low | `proxyebator connect` instead of long flags |

---

## Anti-Features

Features to explicitly NOT build in v1.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **GUI dashboard (web UI)** | Adds attack surface, maintenance burden, dependency; target users are technical; outline-server's web UI is its weakest part | Keep CLI-only; print status to stdout |
| **Custom protocol implementation** | Reimplementing transport protocol is months of work and security risk; chisel/wstunnel are battle-tested | Wrap existing binaries; don't fork them |
| **VPN mode (full traffic redirect)** | Kernel-level routing (tun/tap) is OS-specific, fragile, requires root; scope creep | SOCKS5 is sufficient; let GUI clients handle routing policy |
| **Windows server support** | Target is VPS (Linux); Windows server adds separate install paths, service management, firewall commands | Document Linux-only clearly; client docs cover Windows usage |
| **Docker-only deployment** | Adds Docker dependency; many cheap VPS don't have Docker; systemd is universal on modern Linux | Use systemd directly; optionally mention Docker as alternative |
| **Automatic domain purchase/DNS** | API integrations with registrars are complex, cost money, add credentials to manage | Require user to have a domain; script validates it resolves to server IP |
| **GUI client bundling** | Clients exist on all platforms; bundling them would require maintaining binaries for 3+ OSes | Link to downloads; provide configuration snippets |
| **Traffic analytics / logging of content** | Privacy violation; builds trust deficit with exact audience (privacy-conscious users) | Log only connection events, never payload |
| **Mobile client support** | iOS/Android proxy configuration varies widely; out of scope for v1 | Document that SOCKS5 works with mobile apps that support proxy settings |

---

## Feature Dependencies

```
Domain + DNS record → Let's Encrypt cert → HTTPS masquerade → website masquerading
VPS Linux server → systemd service → auto-restart on crash
systemd service → status command (queries service state)
server install → printed client command string → client setup
binary install (server) → firewall rules → SOCKS5 available
SOCKS5 on localhost → GUI client configuration (Proxifier / Surge / nekoray / nekobox)
shared secret → multi-user support (extends secret list)
config file → short `proxyebator connect` command
```

---

## GUI Client Configuration Details

### Linux — nekobox (sing-box frontend)

- Supports SOCKS5 inbound natively via "add proxy" → SOCKS5
- Set host: `127.0.0.1`, port: `1080`
- Enable "system proxy" toggle or use per-app routing
- Recommended for Linux; actively maintained as of 2024; succeeds nekoray on Linux
- Complexity to configure: **Low** (GUI form)

### Linux — nekoray (Qt GUI, sing-box/v2ray core)

- SOCKS5 proxy: Settings → Preferences → Add Socks5 inbound
- Routing rules select which traffic goes through the proxy
- Still available but development shifted to nekobox; both work
- Complexity: **Low**

### Linux — Proxychains / Proxychains-ng (CLI alternative)

- `proxychains4 -f /etc/proxychains4.conf curl https://example.com`
- Config: `socks5 127.0.0.1 1080` in `[ProxyList]`
- No GUI; useful for wrapping CLI tools
- Complexity: **Low**

### Windows — nekoray (Qt GUI, sing-box/v2ray core)

- Windows build available; SOCKS5 inbound same as Linux
- TUN mode available for system-wide routing (requires WinTun driver)
- Complexity: **Low**

### Windows — Proxifier

- Commercial ($39.95 one-time); industry standard for Windows per-app proxying
- Add proxy: Profile → Proxy Servers → Add → SOCKS Version 5, `127.0.0.1:1080`
- Proxification rules by application or domain
- Widely used by power users; no free tier
- Complexity: **Low** (well-documented UI)

### Windows — Clash Verge / Clash Meta GUI

- Free; uses Mihomo (Clash Meta) core
- Add SOCKS5 as external proxy or configure as system proxy pass-through
- Complexity: **Medium** (requires understanding of Clash config YAML)

### macOS — Surge

- Premium ($49.99 + subscription for updates); most powerful macOS proxy tool
- Add SOCKS5: Proxy → Add → SOCKS5 Proxy, `127.0.0.1:1080`
- Supports per-app, per-domain, and system-wide routing rules
- Complexity: **Low** (polished UI)

### macOS — Proxifier

- Same Windows version available for macOS; same pricing
- Identical SOCKS5 configuration
- Complexity: **Low**

### macOS — ClashX / ClashX Meta

- Free; Clash config with SOCKS5 external proxy or Mihomo as TUN
- Complexity: **Medium**

### macOS — Proxyman (HTTP/HTTPS proxy focus)

- Primarily for HTTP interception/debugging; SOCKS5 support limited
- Not recommended for this use case
- Complexity: **High** (wrong tool)

---

## What Existing Tools Do (Reference Landscape)

| Tool | Install Method | Transport | Masquerade | Output | Status |
|------|---------------|-----------|------------|--------|--------|
| outline-server | Docker + web API | Shadowsocks | No (bare SS) | SOCKS5 via client | Active |
| streisand | Ansible playbook | Multi (WG, OpenVPN, Shadowsocks, SSH) | Partial (stunnel) | Various | Unmaintained (archived 2021) |
| algo VPN | Ansible playbook | WireGuard + IPsec | No | WireGuard interface | Active |
| netch | Windows GUI client | Various (SS, V2Ray, Trojan) | Client-side only | TUN / system proxy | Active (client only, not deploy script) |
| chisel deploy scripts | Shell one-liners | WebSocket over TCP | None (raw WS) | SOCKS5 | Community; no standard |
| wstunnel deploy scripts | Shell one-liners | WebSocket over TLS | None standard | SOCKS5 | Community; no standard |

**Gap proxyebator fills:** No existing tool combines (1) WebSocket tunnel + (2) website masquerading + (3) one-command deploy into a single bash script. outline-server is closest but uses Shadowsocks (fingerprintable) with no HTTP masquerade.

---

## MVP Recommendation

Prioritize for v1:

1. One-command server install (chisel OR wstunnel, user choice)
2. Shared secret auto-generation + printed client command
3. Systemd service with auto-restart
4. TLS via Let's Encrypt (Caddy as reverse proxy — zero-config HTTPS)
5. Website masquerading: Caddy serves real HTML on `/`, upgrades `/tunnel` path to WebSocket
6. Firewall rule automation (ufw preferred; iptables fallback)
7. Status / health check command
8. SOCKS5 on `127.0.0.1:1080`
9. README with AI-agent-friendly numbered instructions + GUI client config snippets (nekoray, nekobox, Proxifier, Surge)

Defer to v2:

- Multi-user support: adds complexity, not needed for personal use case
- CDN/domain fronting routing: significant setup complexity; document as manual option
- Config file persistence: nice-to-have; v1 can print full command
- Update command: manual binary replacement is acceptable for v1
- wstunnel as second backend: add after chisel path is proven

---

## Sources

- Domain knowledge: chisel v1.x README (jpillora/chisel), wstunnel README (erebe/wstunnel), outline-server docs (Jigsaw-Code), algo VPN README (trailofbits/algo), streisand archived docs
- GUI clients: nekobox/nekoray GitHub READMEs, Proxifier manual, Surge documentation, ClashX/Clash Verge community docs
- Confidence: MEDIUM (training data through Aug 2025; no live fetch confirmed; core features of chisel/wstunnel/outline/algo are stable and well-known; GUI client feature sets verified against multiple independent sources)
- Flag: Verify current wstunnel v7+ flag names (API changed significantly between v3 and v7); check nekobox current status (project renamed/moved in 2024-2025 timeframe)
