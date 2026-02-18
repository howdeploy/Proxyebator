# Domain Pitfalls: Masked WebSocket Proxy Tunnel Deployment Scripts

**Domain:** Bash deployment scripts for masked WebSocket proxy tunnels (Chisel/wstunnel + nginx + TLS)
**Researched:** 2026-02-18
**Sources:** Project's own tunnel-reference.md and PROXY-GUIDE.md (validated operational experience), domain knowledge

---

## Critical Pitfalls

Mistakes that break the tunnel, expose the server, or require full redeploy.

---

### Pitfall 1: nginx proxy_pass Trailing Slash Omission

**What goes wrong:** WebSocket handshake fails with 404. Tunnel binary reports connected but traffic doesn't flow, or client can't even complete handshake.

**Why it happens:** nginx's behavior with `proxy_pass` differs based on whether a trailing slash is present. Without it, nginx passes the full `/SECRET_PATH/something` URI to the upstream. With it, nginx strips the location prefix and passes only the remainder (effectively `/`). Chisel and wstunnel both expect requests at `/` on their listening port.

**Consequences:** Two failure modes — (1) client gets HTTP 404 and cannot connect at all, (2) client connects but traffic silently drops.

**Prevention:** Always use `proxy_pass http://127.0.0.1:PORT/;` with trailing slash. The script must generate the nginx location block with this exactly. Verify with `nginx -t` plus an integration test, not just syntax check.

**Detection:**
- `curl -v -H "Upgrade: websocket" https://domain/SECRET_PATH/` returns 404 instead of 101 Switching Protocols
- Chisel client logs show `Connected` but `curl --socks5-hostname` hangs

**Phase:** nginx configuration generation phase. Must be tested before marking setup complete.

---

### Pitfall 2: Missing `proxy_buffering off` in nginx Location Block

**What goes wrong:** Tunnel appears connected (chisel logs "Connected") but all traffic through the SOCKS5 proxy hangs or times out. No data actually flows.

**Why it happens:** nginx buffers the proxied response body by default. WebSocket traffic is a continuous binary stream — buffering accumulates data until a buffer fills, then flushes in bursts, or never flushes at all for small packets. The tunnel protocol breaks entirely.

**Consequences:** Tunnel is completely non-functional for browsing even though all status checks appear green. Very hard to debug because systemd status shows active and nginx test passes.

**Prevention:** `proxy_buffering off;` is mandatory in every WebSocket location block. The script template must include it unconditionally, never behind a conditional.

**Detection:** `systemctl status chisel` → active. `ss -tlnp | grep 7777` → correct. `curl --socks5-hostname 127.0.0.1:1080 https://example.com` → hangs after connect.

**Phase:** nginx template generation. Add to post-install checklist as explicit test step.

---

### Pitfall 3: Tunnel Service Binding to 0.0.0.0 Instead of 127.0.0.1

**What goes wrong:** The tunnel port (7777 for Chisel, 8888 for wstunnel) is exposed on the public interface, allowing anyone on the internet to connect directly without going through nginx and without authentication.

**Why it happens:** Chisel's `--host` and `-p` are separate flags. The intuitive `-p 127.0.0.1:7777` syntax does NOT work — Chisel ignores the host part and binds to 0.0.0.0. The script must use `--host 127.0.0.1 -p 7777` as separate arguments.

**Consequences:** Complete security bypass. The secret path and password are irrelevant if the tunnel port is reachable directly from the internet. Active scanners (Shodan, ZoomEye) will find it within hours.

**Prevention:** In the systemd ExecStart, always emit `--host 127.0.0.1` and `-p PORT` as separate tokens. Post-install, the script must verify with `ss -tlnp | grep PORT` that the result shows `127.0.0.1:PORT` not `0.0.0.0:PORT` or `*:PORT`. Fail loudly if wrong.

**Detection:** `ss -tlnp | grep 7777` shows `0.0.0.0:7777` or `*:7777`.

**Phase:** systemd service file generation. Verification must be a mandatory post-install step.

---

### Pitfall 4: Cloudflare Proxy (Orange Cloud) Breaking WebSocket Traffic

**What goes wrong:** Tunnel works for a few seconds then drops. Or drops every ~100 seconds. Or fails to upgrade at all. Or binary data is corrupted.

**Why it happens:** Two separate Cloudflare issues:
- Cloudflare Free plan terminates WebSocket connections after ~100 seconds of inactivity
- Cloudflare CDN on some plans intercepts and inspects WebSocket frames, which corrupts binary tunnel protocols

**Consequences:** Intermittent drops that look like network issues but are actually infrastructure. Impossible to diagnose without knowing the CF involvement.

**Prevention:** Require "grey cloud" (DNS-only, no proxy) in Cloudflare for the tunnel domain. The script should detect if the DNS A record is behind a Cloudflare proxy IP and warn. Alternatively, use `--keepalive 25s` on the client side to prevent the 100-second timeout (but this does not fix binary corruption).

**Detection:** Tunnel drops exactly every ~100 seconds. `nslookup domain.com` returns a Cloudflare IP (104.x.x.x, 172.x.x.x) rather than the VPS IP. Client works fine when connecting directly to VPS IP.

**Phase:** DNS configuration documentation/validation. Must be in the README and ideally checked by the script at runtime.

---

### Pitfall 5: Port 443 Already Occupied by Another Service

**What goes wrong:** TLS handshake fails with `x509: certificate valid for api.something.com` or connection refused, because nginx on 443 conflicts with Xray, V2Ray, or another service already on that port.

**Why it happens:** Many VPS users already have another proxy protocol running on port 443. The script naively tries to configure nginx on 443 without checking.

**Consequences:** nginx fails to start or both services conflict. The script produces a "working" installation that immediately fails on first connection.

**Prevention:** Before configuring nginx, check if port 443 is in use (`ss -tlnp | grep :443`). If occupied, offer alternative ports: 2087, 8443, or 2096 (Cloudflare-compatible non-standard HTTPS ports). The script must handle this case explicitly, not assume 443 is free.

**Detection:** `systemctl status nginx` shows bind failure. `ss -tlnp | grep :443` returns a non-nginx process. Client gets wrong certificate.

**Phase:** Pre-flight checks phase. Must run before any configuration is written.

---

### Pitfall 6: Certbot Rate Limits Hit During Testing or Retry

**What goes wrong:** `certbot certonly` fails with "too many certificates already issued" error. Let's Encrypt enforces 5 duplicate certificates per domain per week.

**Why it happens:** During script development or when users re-run the setup script after a failed attempt, certbot is called repeatedly for the same domain.

**Consequences:** User is locked out of getting a valid TLS certificate for up to 7 days. The tunnel cannot function without TLS. The user may not understand why.

**Prevention:**
- Check if a valid certificate already exists before calling certbot: `certbot certificates` or check `/etc/letsencrypt/live/DOMAIN/`
- Use `--staging` flag during development and testing
- Skip certbot call if certificate exists and is valid (not expired)
- Show the user clear error messages that mention the 7-day wait if rate limit is hit

**Detection:** `certbot certonly` returns error code with "too many certificates" or "rate limit exceeded" in output.

**Phase:** TLS setup phase. Certificate existence check must be the first step before any certbot invocation.

---

### Pitfall 7: wstunnel Binary Name Changed in v10+

**What goes wrong:** `wstunnel: command not found` or Docker container errors with "No such file or directory" even though the binary was successfully downloaded and placed in PATH.

**Why it happens:** Starting from wstunnel v10, the binary inside the release archive is named `wstunnel-cli` instead of `wstunnel`. Scripts that assume the old name break silently after a version bump.

**Consequences:** Entire wstunnel setup fails. The script reports "installed" but the service never starts.

**Prevention:** After downloading and extracting, detect the actual binary name inside the archive. Do not hardcode `wstunnel` — use `ls /tmp/wstunnel_extract/` to find what was extracted. The systemd ExecStart and PATH installation must use the actual binary name, not an assumed one.

**Detection:** `wstunnel --version` returns command not found. `ls /usr/local/bin/wstunnel*` shows nothing.

**Phase:** Binary installation phase for wstunnel. Needs explicit binary name detection logic.

---

### Pitfall 8: wstunnel `--restrict-http-upgrade-path-prefix` Conflicts with nginx Trailing Slash

**What goes wrong:** All WebSocket connections return 404 from wstunnel even though nginx is correctly configured and forwarding requests.

**Why it happens:** nginx strips the location prefix when using trailing slash proxy_pass. wstunnel receives requests at `/` on its port. If `--restrict-http-upgrade-path-prefix /SECRET_PATH/` is set on wstunnel, it rejects requests that arrive at `/` because the path no longer matches.

**Consequences:** The tunnel never accepts any WebSocket upgrades. Looks identical to a nginx misconfiguration, very confusing to debug.

**Prevention:** Do not use `--restrict-http-upgrade-path-prefix` on wstunnel when nginx is the upstream proxy with trailing slash. Security is provided by nginx: only requests that match the nginx location for SECRET_PATH ever reach wstunnel. The wstunnel restriction is redundant and harmful in this architecture.

**Detection:** wstunnel logs show requests arriving at `/` being rejected. nginx access logs show 404 responses coming from upstream (wstunnel), not from nginx itself.

**Phase:** wstunnel configuration generation phase.

---

### Pitfall 9: Chisel `socks` vs `R:socks` Confusion in Client Instructions

**What goes wrong:** The SOCKS5 proxy is created on the client machine but traffic exits from the client's IP, not the server's IP. The proxy appears to work but provides no circumvention.

**Why it happens:** `socks` creates a SOCKS5 server on the client, with traffic exiting on the server side. `R:socks` creates a SOCKS5 server on the remote (VPS), with traffic exiting through the client. They do the opposite of what the name suggests to a non-expert reader.

**Consequences:** User believes tunnel is working (SOCKS5 port responds) but their real IP is not hidden and blocked resources remain inaccessible. The failure is silent — no error messages, connection appears successful.

**Prevention:** The client instructions generated by the script must use `socks` (no prefix). Add a verification step in the output: `curl --socks5-hostname 127.0.0.1:1080 https://2ip.ru` and explain the expected output (server IP, not client IP).

**Detection:** `curl --socks5-hostname 127.0.0.1:1080 https://2ip.ru` returns the client's own IP address.

**Phase:** Client configuration output / README generation phase.

---

### Pitfall 10: TUN Mode Routing Loop (Throne/sing-box)

**What goes wrong:** After enabling TUN mode in the client-side proxy manager (Throne, sing-box, nekoray), the tunnel itself enters an infinite reconnect loop. Connection drops every few seconds.

**Why it happens:** TUN mode intercepts ALL traffic from ALL processes on the machine, including the tunnel client process itself. The tunnel client's WebSocket connection to the server gets intercepted by TUN, routed back through the tunnel, which is then intercepted again — creating a loop.

**Consequences:** The tunnel is completely unusable in TUN mode without explicit exclusion rules.

**Prevention:** The README must document exact routing rules needed for each GUI client:
- Add `processName: chisel` or `processName: wstunnel` → outbound: direct
- Add server domain → outbound: direct
- Add `127.0.0.1` → outbound: direct

**Detection:** Tunnel connects, immediately shows "reconnecting" in client logs. CPU spikes on tunnel reconnect. Works fine in non-TUN (manual proxy) mode.

**Phase:** README/client instructions generation phase. Must be documented per client.

---

### Pitfall 11: DNS Leaks Through SOCKS5

**What goes wrong:** DNS queries bypass the tunnel and go to the ISP's resolver directly, revealing the list of sites being visited even when traffic content is encrypted.

**Why it happens:** Standard SOCKS5 proxies do not proxy DNS by default. Applications resolve hostnames locally using the system resolver, then connect via SOCKS5. The hostname itself is never sent through the tunnel.

**Consequences:** DNS queries from the user's machine are visible to ISP/DPI even with tunnel active. In a censorship context, DNS-based blocking still applies.

**Prevention:** The README must document: (1) Use `SOCKS5h` (SOCKS5 with remote hostname resolution) in applications that support it. (2) In Throne/sing-box, enable remote DNS or TUN mode with fake-IP. (3) Add `dnsleaktest.com` check to post-setup verification steps.

**Detection:** `curl --socks5-hostname` works correctly (uses remote DNS), but browser traffic may still leak DNS. Test at `dnsleaktest.com` through the proxy.

**Phase:** README/client instructions phase. Also relevant to threat model documentation.

---

## Moderate Pitfalls

### Pitfall 12: Bash Signal Handling and Trap Cleanup

**What goes wrong:** If the deployment script is interrupted (Ctrl+C, SIGTERM) mid-way through setup, it leaves partial state: half-written nginx configs, downloaded binaries without systemd units, certbot certificates without corresponding nginx blocks. Re-running the script fails or creates duplicate configurations.

**Prevention:**
- Use `trap 'cleanup_function' INT TERM EXIT` at the top of the script
- The cleanup function should remove any temporary files written during the current run
- Distinguish between "installed state" (existing, valid, keep) and "partial state" (current run, remove on interrupt)
- Before writing any config, check if it already exists and skip if valid

**Phase:** Script infrastructure / error handling phase.

---

### Pitfall 13: Multi-Distro Package Name Differences

**What goes wrong:** `apt-get install nginx certbot python3-certbot-nginx` works on Debian/Ubuntu but fails on CentOS (nginx package name OK, but certbot is via `snap` or EPEL), Fedora (uses `dnf`, certbot is `python3-certbot-nginx`), or Arch (uses `pacman`, certbot is `certbot-nginx`).

**Prevention:**
- Maintain an explicit package name mapping per distro family
- Detect distro via `/etc/os-release` (read `ID` and `ID_LIKE` fields)
- For CentOS/RHEL, certbot via snap is the officially supported path since 2021
- Test nginx conf path differences: `/etc/nginx/sites-available/` (Debian) vs `/etc/nginx/conf.d/` (RedHat)
- nginx reload command may differ (`nginx -s reload` vs `systemctl reload nginx`)

**Phase:** OS detection and dependency installation phase.

---

### Pitfall 14: Certbot nginx Plugin vs Standalone Mode

**What goes wrong:** `certbot --nginx` modifies the nginx config automatically, potentially conflicting with the script's own generated config. Or `certbot --standalone` fails because port 80 is already in use by nginx.

**Prevention:**
- Use `certbot certonly --nginx` to get the certificate without nginx config modification, then manually configure the TLS block. This gives the script full control over the nginx configuration.
- Alternatively, use `certbot certonly --webroot` with a dedicated webroot directory for the decoy site
- Never use bare `certbot --nginx` which rewrites nginx config in unpredictable ways

**Phase:** TLS acquisition phase.

---

### Pitfall 15: Let's Encrypt Certificate Not Renewed (Certbot Timer)

**What goes wrong:** 90 days after initial setup, the TLS certificate expires. nginx starts returning TLS errors. The tunnel stops working.

**Why it happens:** Certbot installs a systemd timer or cron job, but on some distros or in some install modes, the timer is not enabled automatically.

**Prevention:**
- After certbot installation, explicitly enable the timer: `systemctl enable certbot.timer` (or the distro equivalent)
- The post-install checklist must verify: `systemctl status certbot.timer` (or `systemctl status snap.certbot.renew.timer`)
- Test renewal with `certbot renew --dry-run` during setup

**Phase:** TLS setup phase.

---

### Pitfall 16: Running Tunnel Service as Root

**What goes wrong:** The tunnel service runs as root (no `User=` in systemd unit), meaning a vulnerability in Chisel or wstunnel gives an attacker full root access to the VPS.

**Prevention:**
- Always include `User=nobody` (or a dedicated `User=chisel`) in the systemd service file
- The auth file must be chowned to match: `sudo chown nobody:nogroup /etc/chisel/auth.json`
- Verify: `ps aux | grep chisel` should show `nobody` not `root`

**Phase:** systemd service file generation phase.

---

### Pitfall 17: Auth Credentials Visible via `ps aux`

**What goes wrong:** Using `--auth user:password` as a command-line flag exposes credentials to any user who can run `ps aux` on the server.

**Prevention:**
- Always use `--authfile /etc/chisel/auth.json` instead of `--auth` flag
- The auth file must have `chmod 600` permissions
- The systemd ExecStart must reference the file, not embed credentials inline

**Phase:** systemd service file generation and auth setup phase.

---

## Minor Pitfalls

### Pitfall 18: GitHub API Rate Limit During Binary Download

**What goes wrong:** `curl https://api.github.com/repos/jpillora/chisel/releases/latest` fails or returns error when the unauthenticated rate limit (60 requests/hour per IP) is exhausted. The version detection returns empty string, and the subsequent download URL is malformed.

**Prevention:**
- Validate the version string before using it: `[ -z "$VERSION" ] && echo "ERROR: Could not fetch version" && exit 1`
- Provide a fallback hardcoded version as a constant in the script
- Consider using the GitHub releases page HTML as a fallback (no rate limit for web requests)

**Phase:** Binary download phase.

---

### Pitfall 19: Secret Path Entropy Too Low

**What goes wrong:** The SECRET_PATH is generated with insufficient randomness (e.g., timestamp-based, short string), making it discoverable by an active prober scanning common paths.

**Prevention:**
- Use `openssl rand -hex 16` (128 bits of entropy, 32 hex chars). Never use `$RANDOM`, date-based values, or short strings
- The path should look like a realistic web path, not clearly random: consider prefixing with a realistic-looking directory like `/api/` or `/ws/`

**Phase:** Secret generation phase.

---

### Pitfall 20: nginx Config Placed in Wrong Directory by Distro

**What goes wrong:** Script writes nginx config to `/etc/nginx/sites-available/` and symlinks to `sites-enabled/` (Debian convention), but on CentOS/Arch, nginx uses `/etc/nginx/conf.d/*.conf` and has no `sites-*` directories. nginx silently ignores the config.

**Prevention:**
- Detect nginx config directory from distro family, or detect it dynamically from `nginx -V` output (`--conf-path`)
- Write to `conf.d/` for RedHat-family and Arch; use `sites-available/sites-enabled` pattern only for Debian-family

**Phase:** nginx configuration phase.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| OS detection | Package names differ per distro | Map packages per distro family; certbot via snap on RHEL |
| nginx config generation | Missing trailing slash in proxy_pass | Test template with curl WebSocket upgrade check |
| nginx config generation | Missing `proxy_buffering off` | Include unconditionally in template; no conditional logic |
| Binary download (Chisel) | `--host` and `-p` must be separate flags | Generate systemd unit with explicit separate args |
| Binary download (wstunnel) | Binary name changed to `wstunnel-cli` in v10 | Detect actual binary name after extraction |
| TLS / certbot | Rate limit on repeated runs | Check cert existence before invoking certbot |
| TLS / certbot | Timer not enabled | Explicitly enable and verify certbot renewal timer |
| Port conflict detection | Port 443 occupied by Xray/other | Pre-flight check; offer 2087/8443 fallback |
| systemd service generation | Service binding to 0.0.0.0 | Verify with ss -tlnp after start; fail loudly |
| systemd service generation | Running as root | Always include User=nobody |
| Signal handling | Partial state on Ctrl+C | trap INT TERM EXIT with cleanup |
| Client instructions output | `R:socks` vs `socks` confusion | Hardcode correct form; add IP verification step |
| Client instructions output | TUN routing loop | Document processName exclusion rules per client |
| Client instructions output | DNS leaks | Document SOCKS5h and remote DNS requirement |
| README generation | Cloudflare orange cloud breaks WS | Prominently document grey cloud requirement |
| Post-install verification | Auth credentials in ps aux | Use authfile not --auth flag |
| Secret generation | Low entropy paths | Use openssl rand -hex 16 minimum |

---

## Sources

- `/home/kosya/vibecoding/proxyebator/tunnel-reference.md` — Operational deployment reference with validated pitfalls from real experience (HIGH confidence — documented from actual debugging)
- `/home/kosya/vibecoding/proxyebator/PROXY-GUIDE.md` — Full technical guide with threat model and "грабли" section (HIGH confidence — same operational source)
- Domain knowledge: nginx WebSocket proxy behavior, Let's Encrypt rate limits, Cloudflare WebSocket policies, systemd hardening practices, multi-distro Linux packaging (MEDIUM confidence — well-established but verify current certbot paths for RHEL)
