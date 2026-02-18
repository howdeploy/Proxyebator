# Technology Stack

**Project:** Proxyebator — masked WebSocket proxy tunnel deployment script
**Researched:** 2026-02-18
**Source basis:** Project's own battle-tested reference docs (tunnel-reference.md, PROXY-GUIDE.md) from real deployments + training knowledge on nginx/certbot/systemd patterns.

---

## Recommended Stack

### Tunnel Tools (user chooses one)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Chisel | v1.11.3 (latest as of project reference) | SSH-over-WebSocket tunnel with SOCKS5 | Built-in auth via authfile, SOCKS5 first-class, reliable, widely deployed. SSH layer adds encryption on top of TLS — belt-and-suspenders. |
| wstunnel | v10.x (latest via API at deploy time) | Raw TCP/UDP-over-WebSocket tunnel | Faster and lighter than Chisel (no SSH layer). No built-in auth — security delegated to nginx secret path. Better for performance-sensitive use. |

**Default recommendation: Chisel** because it has built-in authentication (`--authfile`), making the security model simpler and reducing dependency on nginx path secrecy alone.

### Infrastructure (always present)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| nginx | system package (1.18+ on Ubuntu 22.04, 1.22+ on Debian 12) | TLS termination, WebSocket proxy, cover site | Required for masking — tunnel listens on 127.0.0.1, nginx exposes it at secret path behind HTTPS. Also serves the cover site. |
| certbot | system package (latest via snap or apt) | Automated Let's Encrypt TLS | Free, auto-renews, ACME protocol. Required because Cloudflare Origin certs don't work here (CF blocks binary WebSocket). |
| systemd | system (all target distros) | Process supervision | Already present on Debian/Ubuntu. Handles restart-on-crash, runs as unprivileged user (nobody). |

### Supporting Tools (in the bash script)

| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| curl | system | Download binaries, GitHub API version detection | Always — used to fetch latest release tag and binary |
| openssl | system | Generate SECRET_PATH (`openssl rand -hex 16`) | Always — called once during setup |
| jq | system (or pure grep) | Parse GitHub API JSON for version tag | Optional — the script can use grep fallback if jq absent |
| ufw | system | Verify tunnel port is NOT exposed externally | Verification step only |
| ss | system (iproute2) | Confirm tunnel listening on 127.0.0.1 not 0.0.0.0 | Health check |

---

## Exact CLI Flags

### Chisel Server

```bash
/usr/local/bin/chisel server \
  --host 127.0.0.1 \
  -p 7777 \
  --authfile /etc/chisel/auth.json \
  --socks5
```

**Critical flag notes:**
- `--host 127.0.0.1` and `-p 7777` are SEPARATE flags. Chisel does NOT accept `-p 127.0.0.1:7777` (will fail silently or crash)
- `--socks5` enables SOCKS5 on the server side (required for forward proxy)
- `--reverse` is NOT needed and increases attack surface — omit it
- `--authfile` over `--auth` because `--auth LOGIN:PASS` appears in `ps aux` output

**Auth file format** (`/etc/chisel/auth.json`):
```json
{
  "LOGIN:PASSWORD": [".*:.*"]
}
```
The value `[".*:.*"]` means "allow all remotes". An empty value `[""]` is known to not work.

### Chisel Client

```bash
chisel client \
  --auth "LOGIN:PASSWORD" \
  --keepalive 25s \
  https://yourdomain.com:PORT/SECRET_PATH/ \
  socks
```

**Critical flag notes:**
- `socks` (NOT `R:socks`) — `socks` forwards through server, `R:socks` exposes via client (wrong direction)
- Trailing slash in URL `/SECRET_PATH/` is mandatory — without it nginx issues 301 redirect, WebSocket cannot follow redirects
- `--keepalive 25s` prevents Cloudflare CDN timeout (CF Free plan kills idle WS at ~100s)
- Port must be explicit if 443 is occupied by another service (Xray, etc.)

SOCKS5 appears on `127.0.0.1:1080`.

### wstunnel Server

```bash
/usr/local/bin/wstunnel server \
  ws://127.0.0.1:8888
```

**Critical flag notes:**
- Do NOT use `--restrict-http-upgrade-path-prefix` together with nginx trailing-slash `proxy_pass`. nginx strips the path before forwarding to wstunnel, so wstunnel receives `/` and the restriction never matches → always 404
- Security is provided by the nginx secret path — only requests that reach the `location /SECRET_PATH/` block get forwarded to wstunnel
- In v10+, the binary inside the archive may be named `wstunnel-cli` (not `wstunnel`) — the script must check the archive contents

### wstunnel Client

```bash
wstunnel client \
  -L socks5://127.0.0.1:1082 \
  wss://yourdomain.com:PORT/SECRET_PATH/
```

**Critical flag notes:**
- `-L socks5://BIND_ADDR:PORT` creates the local SOCKS5 listener
- Trailing slash is mandatory (same reason as Chisel)
- `--tls-skip-verify` does NOT exist in v10 — use `--tls-sni-override DOMAIN` for direct-IP connections
- Docker mode: do NOT quote arguments — they are passed literally as strings (Docker entrypoint issue)

SOCKS5 appears on `127.0.0.1:1082`.

---

## Binary Download Pattern

Both tools follow the same pattern — always fetch latest at deploy time:

```bash
# Chisel
CHISEL_VER=$(curl -s https://api.github.com/repos/jpillora/chisel/releases/latest \
  | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*')
curl -fLo /tmp/chisel.gz \
  "https://github.com/jpillora/chisel/releases/download/${CHISEL_VER}/chisel_${CHISEL_VER#v}_linux_amd64.gz"
gunzip /tmp/chisel.gz
chmod +x /tmp/chisel
sudo mv /tmp/chisel /usr/local/bin/chisel

# wstunnel (v10+ uses tar.gz)
WSTUNNEL_VER=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest \
  | grep -o '"tag_name": "[^"]*"' | grep -o 'v[0-9.]*')
curl -fLo /tmp/wstunnel.tar.gz \
  "https://github.com/erebe/wstunnel/releases/download/${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER#v}_linux_amd64.tar.gz"
tar -xzf /tmp/wstunnel.tar.gz -C /tmp/
# Binary may be wstunnel or wstunnel-cli depending on version — check:
if [ -f /tmp/wstunnel-cli ]; then
  sudo mv /tmp/wstunnel-cli /usr/local/bin/wstunnel
else
  sudo mv /tmp/wstunnel /usr/local/bin/wstunnel
fi
chmod +x /usr/local/bin/wstunnel
```

Use `grep` (not `jq`) for version parsing to minimize dependencies in a bare bash script.

---

## nginx WebSocket Proxy Config

### Location Block (insert BEFORE `location /` in existing server block)

```nginx
location /SECRET_PATH/ {
    proxy_pass http://127.0.0.1:7777/;   # 7777 Chisel, 8888 wstunnel
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
```

**Non-negotiable directives:**

| Directive | Why Critical |
|-----------|-------------|
| `proxy_pass http://127.0.0.1:7777/;` | Trailing slash on proxy_pass URL is mandatory — nginx strips the location prefix from the forwarded path. Without it, nginx passes `/SECRET_PATH/...` to the tunnel process which doesn't understand the path, breaking WebSocket upgrade |
| `proxy_http_version 1.1;` | WebSocket requires HTTP/1.1 (not the default 1.0) |
| `proxy_set_header Upgrade $http_upgrade;` + `Connection "upgrade"` | WebSocket upgrade handshake headers — without these nginx strips them and WebSocket fails |
| `proxy_buffering off;` | Without this nginx buffers the proxied response in memory, preventing real-time WebSocket data flow. Tunnel connects but no data flows through |
| `proxy_read_timeout 3600s;` | Long-lived WebSocket connections get killed by the default 60s timeout |

**How to apply to existing config (script must be idempotent):**

```bash
# Generate secret path
SECRET=$(openssl rand -hex 16)

# Inject location block before first location / in the site config
# Use a marker line approach — inject only if marker absent
SITE_CONF="/etc/nginx/sites-enabled/yourdomain.conf"
if ! grep -q "# proxyebator-tunnel" "$SITE_CONF"; then
  # Find line number of first 'location /' and insert before it
  sed -i "/location \// { /# proxyebator-tunnel/! { i\\    # proxyebator-tunnel\n    location /${SECRET}/ {\n        proxy_pass http://127.0.0.1:7777/;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade \$http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host \$host;\n        proxy_read_timeout 3600s;\n        proxy_send_timeout 3600s;\n        proxy_buffering off;\n    }\n\n } }" "$SITE_CONF"
fi
nginx -t && systemctl reload nginx
```

(The script should write the location block to a snippet file and include it, which is cleaner than inline sed.)

**Cleaner pattern — use nginx include:**

```nginx
# In main server block:
include /etc/nginx/proxyebator.d/*.conf;
```

The script writes `/etc/nginx/proxyebator.d/tunnel.conf` with just the location block. Idempotent — overwrite the file, test, reload.

---

## certbot TLS Setup

### Installation (Debian/Ubuntu)

```bash
# Preferred: snap (always latest certbot)
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# Alternative: apt (older but fine for Let's Encrypt)
apt-get install -y certbot python3-certbot-nginx
```

### Obtain Certificate (nginx plugin — recommended)

```bash
certbot --nginx -d yourdomain.com --non-interactive --agree-tos -m admin@yourdomain.com
```

The `--nginx` plugin automatically edits the nginx config and handles renewal hooks.

### Standalone (if nginx not yet configured)

```bash
# Stop nginx temporarily
systemctl stop nginx
certbot certonly --standalone -d yourdomain.com
systemctl start nginx
```

### Auto-renewal

certbot installs a systemd timer automatically (snap version) or a cron job (apt version). Verify:

```bash
systemctl status snap.certbot.renew.timer  # snap
systemctl status certbot.timer              # apt snap alternative
# Or test dry run:
certbot renew --dry-run
```

### Why Not Cloudflare Origin Cert

Cloudflare Origin certificates are valid only when traffic passes through Cloudflare CDN (orange cloud). In direct mode (grey cloud DNS-only), browsers reject them. More critically: CF CDN blocks binary WebSocket data from Chisel and wstunnel, causing connection drops. The deployment script must use Let's Encrypt, not CF Origin certs.

---

## Systemd Unit Files

### Chisel Server (`/etc/systemd/system/chisel.service`)

```ini
[Unit]
Description=Chisel Tunnel Server
After=network.target

[Service]
ExecStart=/usr/local/bin/chisel server \
  --host 127.0.0.1 \
  -p 7777 \
  --authfile /etc/chisel/auth.json \
  --socks5
Restart=always
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
```

### wstunnel Server (`/etc/systemd/system/wstunnel.service`)

```ini
[Unit]
Description=wstunnel Server
After=network.target

[Service]
ExecStart=/usr/local/bin/wstunnel server \
  ws://127.0.0.1:8888
Restart=always
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
```

### Chisel Client Autostart (user-level, optional)

```ini
# ~/.config/systemd/user/chisel-client.service
[Unit]
Description=Chisel Client
After=network-online.target

[Service]
ExecStart=/usr/local/bin/chisel client \
  --auth "LOGIN:PASSWORD" \
  --keepalive 25s \
  https://yourdomain.com:PORT/SECRET_PATH/ \
  socks
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

**Security notes for systemd units:**
- `User=nobody` and `Group=nogroup` — run as unprivileged system user. Both Chisel and wstunnel only need network access, no filesystem writes after startup
- Do NOT use `DynamicUser=yes` — it changes the UID on restarts, which can cause permission issues if the authfile is owned by a specific user
- `Restart=always` + `RestartSec=5` — essential for self-healing; provider drops connections under DPI pressure
- The authfile (`/etc/chisel/auth.json`) must be owned by `root` and readable only by `nobody`: `chown nobody:nogroup /etc/chisel/auth.json && chmod 600 /etc/chisel/auth.json`

### Enable and start

```bash
systemctl daemon-reload
systemctl enable --now chisel   # or wstunnel
```

---

## Target OS

| OS | Version | Status |
|----|---------|--------|
| Debian | 12 (Bookworm) | Primary target |
| Ubuntu | 22.04 LTS | Primary target |
| Ubuntu | 24.04 LTS | Supported |
| Debian | 11 (Bullseye) | Should work, not verified |
| CentOS/RHEL | any | Not supported — different package manager, nginx config paths differ |

The bash script should detect the distro and abort early if not Debian/Ubuntu:

```bash
. /etc/os-release
case "$ID" in
  debian|ubuntu) : ;;
  *) echo "Error: only Debian/Ubuntu supported" >&2; exit 1 ;;
esac
```

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Tunnel | Chisel (default) / wstunnel | Xray VLESS+WS | Xray is dramatically more complex to configure — requires JSON config files, more dependencies. Out of scope for a bash script targeting simplicity |
| Tunnel | Chisel (default) / wstunnel | cloudflared | Vendor lock-in (Cloudflare dependency), closed-source, doesn't work without CF account |
| Tunnel | Chisel (default) / wstunnel | SSH SOCKS (`ssh -D`) | Requires SSH access to the server from client at all times, no easy masking via nginx path |
| TLS | certbot + Let's Encrypt | Cloudflare Origin Cert | CF blocks binary WebSocket traffic — proven to fail for both Chisel and wstunnel |
| TLS | certbot + Let's Encrypt | Self-signed cert | Clients reject it; breaks TLS chain |
| Web server | nginx | Caddy | nginx is already present on most VPS setups. Caddy's auto-HTTPS conflicts with certbot |
| Web server | nginx | Apache | nginx WebSocket proxy is simpler and better documented for this use case |
| Process supervisor | systemd | supervisor / pm2 | systemd is already on the target OS, no extra dependencies |

---

## Cloudflare Mode Decision Tree

The script should ask or detect:

```
Do you want to hide your server IP?
  YES → Orange cloud (CF CDN proxied)
       Enable WebSockets in CF dashboard: Network → WebSockets → On
       SSL/TLS mode: Full (Strict)
       WARNING: CF Free plan drops idle WS at ~100s → client must use --keepalive 25s
  NO  → Grey cloud (DNS only, direct)
       Simpler, no WS timeouts, IP visible in DNS
       Default recommendation for initial setup
```

CF CDN with binary WebSocket **does** work if:
1. WebSockets explicitly enabled in CF dashboard
2. keepalive is set (`--keepalive 25s` for Chisel)
3. Traffic is within CF's acceptable use (personal use — fine)

CF CDN with binary WebSocket **fails** when:
- WebSockets not enabled (default)
- Using CF Origin cert without orange cloud active

---

## Port Strategy

| Port | Use | Notes |
|------|-----|-------|
| 443 | Primary (HTTPS) | Default — use if port is free |
| 2087 | Alternate | CF-proxied compatible port — use if 443 occupied by Xray/other |
| 8443 | Alternate | Another CF-compatible port |
| 7777 | Chisel internal | Never exposed externally — 127.0.0.1 only |
| 8888 | wstunnel internal | Never exposed externally — 127.0.0.1 only |
| 1080 | Chisel client SOCKS5 | On localhost, consumed by GUI clients |
| 1082 | wstunnel client SOCKS5 | On localhost |

The script should detect port 443 availability and offer 2087 as fallback:

```bash
if ss -tlnp | grep -q ':443 '; then
  echo "Port 443 is occupied. Using port 2087."
  TUNNEL_PORT=2087
else
  TUNNEL_PORT=443
fi
```

---

## Confidence Assessment

| Component | Confidence | Source |
|-----------|------------|--------|
| Chisel CLI flags (`--host`, `-p`, `--authfile`, `--socks5`) | HIGH | Project's own tunnel-reference.md from real deployment |
| wstunnel CLI flags (`-L socks5://`, `ws://127.0.0.1:PORT`) | HIGH | Project's own tunnel-reference.md from real deployment |
| nginx WebSocket proxy config (trailing slash, proxy_buffering off) | HIGH | Project's own tunnel-reference.md, verified in production |
| `--restrict-http-upgrade-path-prefix` incompatibility with nginx | HIGH | Project's own tunnel-reference.md, discovered through debugging |
| Chisel v1.11.3 as current version | MEDIUM | Referenced in tunnel-reference.md (2026-02-18); could not verify against live GitHub API (no HTTP tools available in this session) |
| wstunnel v10+ binary naming change (`wstunnel-cli`) | HIGH | Documented in project reference from real debugging |
| certbot `--nginx` plugin approach | HIGH | Standard certbot documentation pattern, widely used |
| systemd unit structure | HIGH | Standard systemd patterns, confirmed in project reference |
| CF Free plan WS timeout ~100s | HIGH | Documented pitfall in project reference (real experience) |

---

## Sources

- `/home/kosya/vibecoding/proxyebator/tunnel-reference.md` — Real deployment reference, 2026-02-18 (HIGH confidence: first-hand)
- `/home/kosya/vibecoding/proxyebator/PROXY-GUIDE.md` — Architecture and ТЗ, 2026-02-18 (HIGH confidence: first-hand)
- Chisel GitHub: https://github.com/jpillora/chisel
- wstunnel GitHub: https://github.com/erebe/wstunnel
- nginx WebSocket proxying: https://nginx.org/en/docs/http/websocket.html
- certbot documentation: https://certbot.eff.org/
