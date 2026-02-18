# Phase 5: Uninstall and Robustness — Research

**Researched:** 2026-02-18
**Domain:** Bash script lifecycle management — uninstall, idempotency, credential hygiene
**Confidence:** HIGH (findings derived from direct codebase analysis + well-established systemd/bash patterns)

---

## Summary

Phase 5 adds two orthogonal capabilities to proxyebator: (1) a clean uninstall that removes every artifact the installer placed on disk, and (2) idempotency guards that make `./proxyebator.sh server` safe to re-run on an already-configured server.

The current script already has a complete inventory of installed artifacts, because `server_save_config` writes `NGINX_CONF` and other paths into `/etc/proxyebator/server.conf`. The uninstall function can `source` that file and know exactly what to remove — no interactive prompts needed. All removal operations must be guarded with existence checks so they are safe whether or not the artifact is present (supporting partial installs and repeated uninstall runs).

Idempotency is partially implemented already: `server_install_deps` checks `command -v` before installing packages, `check_existing_cert` detects an existing TLS cert, `server_configure_nginx` detects an existing nginx config for the domain, and firewall configuration uses `iptables -C` before `-A`. The remaining gaps are the Chisel binary (always re-downloaded regardless) and the systemd service (always overwritten with `cat >`). These two gaps must be plugged with version-aware or existence-aware guards.

Credential hygiene (TUNNEL-07) is already met by the current `--authfile` design: credentials live in `/etc/chisel/auth.json` at chmod 600, never on the command line, so they cannot appear in `ps aux`. This needs verification documentation but no code change.

**Primary recommendation:** Implement `uninstall_main` with `source /etc/proxyebator/server.conf` at the top, then remove artifacts in reverse-install order (firewall → nginx → certbot timer → systemd → binary → auth file → config dir). Add idempotency guards to `server_download_chisel` and `server_create_systemd`.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DEL-01 | `./proxyebator.sh uninstall` — full removal: binary, systemd unit, nginx config, firewall rules | Uninstall Procedure section |
| DEL-02 | Read `/etc/proxyebator/server.conf` for correct removal without prompts | Config Parsing section |
| SCRIPT-04 | Idempotency — re-running does not break existing installation | Idempotency Patterns section |
| TUNNEL-07 | Credentials stored in file (chmod 600), not in command-line arguments | Credential Hygiene section |
</phase_requirements>

---

## Complete Artifact Inventory

Before researching patterns, here is the exact set of artifacts the installer creates (derived from reading `server_main` call order in the script):

| Artifact | Path | Created by | Notes |
|----------|------|-----------|-------|
| Chisel binary | `/usr/local/bin/chisel` | `server_download_chisel` | |
| Auth file | `/etc/chisel/auth.json` | `server_setup_auth` | chmod 600, owned nobody:nogroup |
| Auth directory | `/etc/chisel/` | `server_setup_auth` | |
| systemd unit | `/etc/systemd/system/proxyebator.service` | `server_create_systemd` | enabled + started |
| nginx config | Value of `NGINX_CONF` in server.conf | `server_configure_nginx` | Debian: sites-available; CentOS/Arch: conf.d |
| nginx symlink | `${NGINX_CONF_LINK}/$(basename NGINX_CONF)` | `server_configure_nginx` | Debian/Ubuntu only; NGINX_CONF_LINK is empty string on CentOS |
| nginx backup | `${NGINX_CONF}.bak.<timestamp>` | `server_configure_nginx` | Only if existing config was found and modified |
| Config dir | `/etc/proxyebator/` | `server_save_config` | |
| Config file | `/etc/proxyebator/server.conf` | `server_save_config` | chmod 600 |
| TLS cert | `/etc/letsencrypt/live/${DOMAIN}/` | `server_obtain_tls` (certbot) | Shared resource — handle carefully |
| certbot renewal timer | `certbot.timer` or `snap.certbot.renew.timer` | `server_obtain_tls` | Shared resource |
| Firewall rules (ufw) | ufw rules for 80, LISTEN_PORT, 7777 | `server_configure_firewall` | |
| Firewall rules (iptables) | iptables INPUT chain entries | `server_configure_firewall` | |
| Temp files | `/tmp/chisel.gz`, `/tmp/chisel` | `server_download_chisel` | Usually deleted by mv, but linger on failure |

**NGINX_CONF is stored in server.conf** — uninstall reads it directly instead of reconstructing the path.

---

## 1. Uninstall Procedure

### 1.1 Config Parsing Pattern

The config file at `/etc/proxyebator/server.conf` uses simple `KEY=VALUE` format without quotes. The existing `verify_main` function already demonstrates the correct pattern:

```bash
# Pattern used in verify_main — works reliably for KEY=VALUE format
source /etc/proxyebator/server.conf
```

`source` (or `.`) executes the file as bash. Since `server.conf` uses bare `KEY=VALUE` (no spaces around `=`, no special characters in values except base64 chars which are safe), sourcing is reliable. The file starts with a `# comment` line which bash ignores.

**Alternative: manual parsing** (use if sourcing is considered a security risk):
```bash
# For untrusted files — but server.conf is root-owned chmod 600
DOMAIN=$(grep '^DOMAIN=' /etc/proxyebator/server.conf | cut -d= -f2-)
NGINX_CONF=$(grep '^NGINX_CONF=' /etc/proxyebator/server.conf | cut -d= -f2-)
```

**Recommendation:** Use `source` — it is the same approach used in `verify_main` (consistency, no duplication).

**Guard:** If `server.conf` does not exist, die with a clear message:
```bash
[[ -f /etc/proxyebator/server.conf ]] \
    || die "server.conf not found at /etc/proxyebator/server.conf — nothing to uninstall"
```

### 1.2 Removal Order

Correct reverse-install order prevents leaving broken intermediate states:

```
1. Stop + disable + remove systemd service
2. Remove Chisel binary
3. Remove auth file + auth directory
4. Remove nginx config + symlink (then reload nginx)
5. Remove firewall rules
6. Remove config directory + server.conf   ← LAST (needed until step 5)
```

Firewall removal comes after nginx removal because nginx might be serving legitimate traffic after uninstall (the server could have had pre-existing nginx configuration). Config is removed last because it is needed by all earlier steps.

### 1.3 Systemd Service Removal

Correct three-step sequence for complete service removal:

```bash
# Step 1: Stop (SIGTERM to running process)
systemctl stop proxyebator 2>/dev/null || true

# Step 2: Disable (removes symlink from multi-user.target.wants/)
systemctl disable proxyebator 2>/dev/null || true

# Step 3: Remove unit file
rm -f /etc/systemd/system/proxyebator.service

# Step 4: Reload daemon so systemd forgets the unit
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true   # clears failed state if service crashed
```

`|| true` on stop/disable is intentional: if the service was never started or is already gone, the command exits non-zero but we should continue. `set -euo pipefail` is active in the script, so `|| true` is required.

`systemctl reset-failed` clears the "failed" entry from `systemctl list-units` — without it, a dead service lingers in the failed list, which can confuse re-install.

### 1.4 Binary and Auth File Removal

```bash
rm -f /usr/local/bin/chisel
rm -f /etc/chisel/auth.json
rmdir /etc/chisel 2>/dev/null || true   # rmdir only removes if empty (safe)
```

`rmdir` (not `rm -rf`) is deliberate: if the user placed other files in `/etc/chisel/`, they are preserved. This is the conservative, non-destructive approach.

### 1.5 Nginx Config Removal

The nginx config path is stored in server.conf as `NGINX_CONF`. After sourcing, it is available directly.

```bash
# Remove config file
if [[ -n "${NGINX_CONF:-}" && -f "$NGINX_CONF" ]]; then
    rm -f "$NGINX_CONF"
    log_info "Removed nginx config: ${NGINX_CONF}"
fi

# Remove symlink (Debian/Ubuntu sites-enabled)
# Reconstruct symlink path from NGINX_CONF_LINK (re-detect OS first)
detect_os  # sets NGINX_CONF_LINK
if [[ -n "${NGINX_CONF_LINK:-}" ]]; then
    local symlink="${NGINX_CONF_LINK}/$(basename "${NGINX_CONF}")"
    rm -f "$symlink" 2>/dev/null || true
fi

# Remove backup files (only ours — named *.bak.<unix-timestamp>)
rm -f "${NGINX_CONF}.bak."* 2>/dev/null || true

# Reload nginx to pick up the removal
if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -t 2>/dev/null && systemctl reload nginx || true
fi
```

**Important:** `detect_os` must be called before using `NGINX_CONF_LINK` because that variable is set by `_map_os_id` inside `detect_os`. The uninstall function needs to call it.

**Edge case — injected configs:** If the installer injected a tunnel block into a pre-existing nginx config (the `NGINX_EXISTING_CONF` path), the stored `NGINX_CONF` points to that existing file. In that case, deleting the whole file would destroy the user's pre-existing config. The research recommendation: do NOT delete the file in that case — instead strip the tunnel block. Detection: check if the file contains `proxyebator-tunnel-block-start` marker. If it does and there is other content, strip only the block. However, this is complex. A simpler approach: since `server_configure_nginx` stores the backup as `${NGINX_EXISTING_CONF}.bak.<timestamp>`, the uninstall can restore from backup. But the backup path is not stored in `server.conf`.

**Practical recommendation for Phase 5:** If `NGINX_CONF` was written fresh by proxyebator (not an injection into existing config), delete it entirely. The server.conf does not currently record whether injection happened. Add a flag `NGINX_INJECTED=true/false` to `server_save_config` so uninstall can branch correctly. This is a small addition to Phase 2's `server_save_config` that Phase 5 implementation should add.

### 1.6 Firewall Rule Removal

**ufw removal:**

```bash
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow 80/tcp 2>/dev/null || true
    ufw delete allow "${LISTEN_PORT}/tcp" 2>/dev/null || true
    ufw delete deny 7777/tcp 2>/dev/null || true
    log_info "Firewall rules removed (ufw)"
fi
```

`ufw delete allow 80/tcp` removes the rule matching that exact specification. If the rule was added with a comment (`comment "proxyebator HTTP"`), the delete still works by matching the rule type and port — the comment is not part of the match key. This is confirmed by ufw behavior: `ufw delete` matches on action+port, not comment.

**Caution:** Port 80 is commonly opened by other services. A conservative approach: do not remove 80/tcp via ufw — only remove the port that is uniquely ours (`LISTEN_PORT` if not 443, and 7777). If `LISTEN_PORT=443`, removing 443/tcp could break other HTTPS services. However, since port 443 is opened for a specific service that is being uninstalled, removing the ufw rule is correct — other HTTPS services should have their own ufw rules.

**iptables removal:**

```bash
iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport 7777 ! -i lo -j DROP 2>/dev/null || true
```

`iptables -D` (delete) removes the first matching rule. If the rule was not added (e.g., because ufw handled it), `-D` exits non-zero, which `|| true` suppresses.

**Critical:** `iptables -D` with the same arguments as `-A` removes exactly that rule. The `! -i lo` clause must be present in the delete command exactly as it was in the add command.

### 1.7 TLS Certificate — Do NOT Remove

The cert at `/etc/letsencrypt/live/${DOMAIN}/` should NOT be deleted by default for these reasons:

1. Let's Encrypt has rate limits — 5 certificates per domain per week. Deleting and immediately re-installing would consume a slot unnecessarily.
2. The cert might be shared with other services on the same domain.
3. certbot itself manages cert files and their renewal — direct deletion bypasses certbot's state tracking and can leave certbot in a confused state.

**Recommendation:** Do not delete the cert. Do disable the certbot renewal timer only if nothing else will be using it (hard to determine). Conservative choice: leave the renewal timer active.

If users want to remove the cert: `certbot delete --cert-name "${DOMAIN}"` (interactive) or `certbot revoke --cert-path /etc/letsencrypt/live/${DOMAIN}/cert.pem --delete-after-revoke` (scripted). But this is out of scope for Phase 5.

### 1.8 Confirmation Prompt vs. Config-Driven

**DEL-01 requirement:** removal without prompts.
**DEL-02 requirement:** read server.conf for correct removal.

The design is config-driven (no prompts). However, a single `[y/N]` confirmation before destructive operations is standard UX practice for uninstall commands. Recommendation: add one confirmation prompt (interactive mode) but allow `--yes` or `--force` flag for non-interactive/AI-agent usage.

```bash
uninstall_main() {
    check_root
    [[ -f /etc/proxyebator/server.conf ]] || die "..."
    # shellcheck disable=SC1091
    source /etc/proxyebator/server.conf

    # Confirmation (skippable with --yes flag, set via UNINSTALL_YES=true)
    if [[ "${UNINSTALL_YES:-false}" != "true" ]]; then
        printf "${YELLOW}[WARN]${NC} This will remove:\n"
        printf "  - chisel binary and service\n"
        printf "  - nginx config: %s\n" "${NGINX_CONF:-unknown}"
        printf "  - firewall rules for ports 80, %s, 7777\n" "${LISTEN_PORT:-443}"
        printf "${CYAN}[?]${NC} Continue? [y/N]: "
        read -r _confirm
        case "${_confirm:-N}" in
            y|Y|yes|YES) ;;
            *) die "Uninstall aborted" ;;
        esac
    fi
    ...
}
```

For the `--yes` flag, add `--yes` to the CLI parser in the entry point and set `UNINSTALL_YES=true`.

---

## 2. Idempotency Patterns

### 2.1 What Is Already Idempotent

Reading the code, these install steps are already idempotent:

| Step | How it is already idempotent |
|------|------------------------------|
| Package install (`server_install_deps`) | `command -v pkg` check before `$PKG_INSTALL` |
| TLS certificate (`server_obtain_tls`) | `check_existing_cert` returns early if cert exists |
| nginx config (new domain) | `detect_existing_nginx` branches on existing config for the domain |
| nginx tunnel block injection | `grep -q "proxyebator-tunnel-block-start"` guard before injection |
| Firewall rules (iptables) | `iptables -C` check before `iptables -A` |

### 2.2 What Is NOT Idempotent — Gaps to Fix

**Gap 1: Chisel binary (`server_download_chisel`)**

Current code:
```bash
server_download_chisel() {
    # ... fetches CHISEL_VER, downloads, gunzips, moves to /usr/local/bin/chisel
    # NO check for existing binary
}
```

The function unconditionally downloads and overwrites `/usr/local/bin/chisel`. On re-run:
- Downloads the binary again (slow, wastes bandwidth)
- Overwrites a running binary — this could cause `systemctl restart proxyebator` to fail with "text file busy" if the service is running

**Fix pattern:**
```bash
server_download_chisel() {
    if [[ -x /usr/local/bin/chisel ]]; then
        local current_ver
        current_ver=$(/usr/local/bin/chisel --version 2>&1 | grep -o 'v[0-9.]*' | head -1) || current_ver=""
        log_info "Chisel already installed: ${current_ver} — skipping download"
        return
    fi
    # ... rest of download logic unchanged
}
```

This is the skip-if-exists pattern (do not attempt version upgrade in Phase 5 — that is a v2 UPD-01 requirement).

**Gap 2: systemd unit (`server_create_systemd`)**

Current code:
```bash
server_create_systemd() {
    cat > /etc/systemd/system/proxyebator.service << 'UNIT'
    ...
    UNIT
    systemctl daemon-reload
    systemctl enable --now proxyebator || die "..."
}
```

On re-run: overwrites the unit file, reloads daemon, and calls `enable --now`. If the service is already active, `enable --now` is effectively a no-op (systemctl enables an already-enabled service silently, and starts an already-running service silently). So the overwrite is the main risk — it is benign if the unit content has not changed, but it forces a daemon-reload regardless.

**Fix pattern:**
```bash
server_create_systemd() {
    if systemctl is-active --quiet proxyebator 2>/dev/null; then
        log_info "proxyebator.service is already active — skipping service creation"
        return
    fi
    # ... rest of systemd setup unchanged
}
```

Alternative: always write unit but check if it changed before reloading:
```bash
server_create_systemd() {
    local unit_path="/etc/systemd/system/proxyebator.service"
    local new_unit
    new_unit=$(cat << 'UNIT'
[Unit]
...
UNIT
)
    if [[ -f "$unit_path" ]] && [[ "$(cat "$unit_path")" == "$new_unit" ]]; then
        # Unit unchanged — just ensure it is running
        systemctl enable --now proxyebator 2>/dev/null || true
        log_info "proxyebator.service unchanged and active"
        return
    fi
    printf '%s\n' "$new_unit" > "$unit_path"
    systemctl daemon-reload
    systemctl enable --now proxyebator || die "Failed to start proxyebator.service"
}
```

**Recommendation:** Use the simpler `is-active` check (first pattern). If the service is running, it means a previous install succeeded and the unit file is valid. Skip re-creation entirely.

**Gap 3: Auth file (`server_setup_auth`)**

Current code always overwrites `/etc/chisel/auth.json` with newly generated tokens. On re-run this would regenerate the auth token, which would break existing client connections.

**Fix pattern:**
```bash
server_setup_auth() {
    if [[ -f /etc/chisel/auth.json ]]; then
        log_info "Auth file already exists at /etc/chisel/auth.json — skipping generation"
        # Read existing token from server.conf for use in connection info display
        if [[ -f /etc/proxyebator/server.conf ]]; then
            source /etc/proxyebator/server.conf 2>/dev/null || true
        fi
        return
    fi
    # ... rest of auth setup unchanged
}
```

**Gap 4: ufw firewall rules**

Current code:
```bash
ufw allow 80/tcp comment "proxyebator HTTP" 2>/dev/null || true
```

`ufw allow` is idempotent by itself (ufw silently skips if rule already exists), so this is not a bug. But the log message "Firewall configured via ufw" prints every run even if nothing changed. This is a minor UX issue, not a correctness issue.

**Gap 5: Config file (`server_save_config`)**

Current code always overwrites `/etc/proxyebator/server.conf` with freshly generated values. On re-run with new tokens, this would make the stored config inconsistent with the running auth.json.

**Fix pattern:** Skip save if config already exists — handled by the auth file guard (if auth file exists, tokens are preserved, so config file is also preserved from previous install).

```bash
server_save_config() {
    if [[ -f /etc/proxyebator/server.conf ]]; then
        log_info "Config already exists at /etc/proxyebator/server.conf — skipping"
        return
    fi
    # ... rest unchanged
}
```

### 2.3 Idempotency for nginx (Existing Installation)

The current `server_configure_nginx` already handles this via `detect_existing_nginx` and the tunnel-block marker check. However: if the user runs `server` again on an already-configured server, `NGINX_CONF_PATH` is set but never saved to `server.conf` in the re-run path (because `server_save_config` is called after nginx config). If we skip config save (gap 5 fix), then `NGINX_CONF` in `server.conf` still points to the original config. This is correct.

### 2.4 Summary of Idempotency Changes

| Function | Current Behavior | Required Change |
|----------|-----------------|-----------------|
| `server_download_chisel` | Always downloads | Skip if `/usr/local/bin/chisel` exists |
| `server_setup_auth` | Always overwrites auth.json | Skip if `/etc/chisel/auth.json` exists |
| `server_create_systemd` | Always writes unit + reload | Skip if service is already active |
| `server_save_config` | Always overwrites server.conf | Skip if `/etc/proxyebator/server.conf` exists |
| `server_configure_nginx` | Already idempotent | No change needed |
| `server_obtain_tls` | Already idempotent | No change needed |
| `server_configure_firewall` | Already idempotent | No change needed |
| `server_install_deps` | Already idempotent | No change needed |

---

## 3. Credential Hygiene (TUNNEL-07)

### 3.1 Current Design Analysis

The current auth setup in `server_setup_auth`:
```bash
cat > /etc/chisel/auth.json << EOF
{
  "${AUTH_USER}:${AUTH_TOKEN}": [".*:.*"]
}
EOF
chmod 600 /etc/chisel/auth.json
chown nobody:nogroup /etc/chisel/auth.json
```

The systemd unit uses `--authfile`:
```
ExecStart=/usr/local/bin/chisel server \
  --host 127.0.0.1 \
  -p 7777 \
  --authfile /etc/chisel/auth.json \
  --socks5
```

### 3.2 Verification of ps aux Invisibility

With `--authfile`, chisel reads credentials from the file at startup and uses them internally. The credentials do NOT appear in the process command line. Verification:

```bash
ps aux | grep chisel
# Shows: /usr/local/bin/chisel server --host 127.0.0.1 -p 7777 --authfile /etc/chisel/auth.json --socks5
# AUTH_TOKEN is NOT visible
```

The `/proc/PID/cmdline` (which `ps aux` reads) contains only the literal flags passed to `exec()`. Since the flag is `--authfile /path` and not `--auth user:token`, the credential is never in the process argument list.

**Confidence: HIGH** — this is how `--authfile` is designed to work.

### 3.3 /proc Leakage Check

The `/proc/PID/environ` file could potentially expose credentials if they were passed via environment variable. In the current setup, chisel is launched by systemd with no `Environment=AUTH_TOKEN=...` directive in the unit file. The auth token exists only in `/etc/chisel/auth.json` (chmod 600, owned nobody:nogroup). The nobody user (which runs chisel) can read its own auth file.

`/proc/PID/environ` is readable only by the process owner and root. Since chisel runs as `nobody`, a normal user cannot read `/proc/PID/environ` for the chisel process.

**Conclusion:** TUNNEL-07 is already satisfied by the current design. No code changes needed — only verification documentation.

### 3.4 server.conf Credential Storage

`/etc/proxyebator/server.conf` contains `AUTH_TOKEN=...` in plain text, chmod 600. This is appropriate: the file is root-readable only, and it needs to store the token for the `verify` command and for the connection info printout. The token in `server.conf` is separate from the `--authfile` mechanism.

One potential issue: `AUTH_TOKEN` in server.conf is printed by `server_print_connection_info` to stdout. This is intentional (users need to copy it for client setup), but if stdout is redirected to a log file, the token could end up in logs. This is acceptable for a v1 design.

---

## 4. Cleanup Edge Cases

### 4.1 Temporary Files

`/tmp/chisel.gz` and `/tmp/chisel` are created during install. `mv /tmp/chisel /usr/local/bin/chisel` removes `/tmp/chisel`. The `.gz` file is removed by `gunzip -f /tmp/chisel.gz`. On a failed install these may linger. The uninstall does not need to clean `/tmp` — these are transient files that the OS will clean on reboot. However, a defensive `rm -f /tmp/chisel.gz /tmp/chisel` at the start of `server_download_chisel` prevents stale artifacts from affecting download behavior.

### 4.2 Log Files

Chisel (via systemd/journald) writes to the system journal. `journalctl -u proxyebator` shows these logs. When the service is removed, its past journal entries remain in the journal. This is standard behavior — uninstall does not purge journal entries. If needed: `journalctl --rotate --vacuum-time=1s` (but this affects the whole journal). No action required.

nginx access/error logs in `/var/log/nginx/` may contain request paths including the secret path. These are not proxyebator-specific and are not removed. No action required for Phase 5.

### 4.3 certbot Renewal Cron/Timer

certbot may have installed itself as:
- `certbot.timer` (systemd timer)
- `snap.certbot.renew.timer` (snap-installed certbot)
- A cron entry in `/etc/cron.d/certbot` or `/etc/cron.weekly/certbot`

When proxyebator is uninstalled, the certbot renewal timer/cron should be left active IF the server has other TLS certs managed by certbot. Disabling certbot renewal globally as part of uninstall would be destructive.

**Recommendation:** Leave certbot renewal timer untouched during uninstall. Document in log output that the TLS certificate is preserved and certbot renewal remains active.

### 4.4 Backup Files

`server_configure_nginx` creates backups named `${NGINX_EXISTING_CONF}.bak.<timestamp>`. These should be cleaned up by uninstall. Since the exact timestamp is not stored in server.conf, use a glob:

```bash
# Only remove backups for our specific conf file
if [[ -n "${NGINX_CONF:-}" ]]; then
    rm -f "${NGINX_CONF}.bak."* 2>/dev/null || true
fi
```

### 4.5 User Data in Static Mode

If masquerade mode was `static`, the static files directory (stored conceptually as `STATIC_PATH`) was not copied — nginx only pointed to it. No user data to clean up.

### 4.6 Post-Uninstall State Verification

After uninstall, the system should be in a clean state. A post-uninstall check function is useful for debugging but is not required by the Phase 5 requirements. The `log_info` messages throughout uninstall serve as the audit trail.

---

## 5. Architecture Patterns for Implementation

### 5.1 Recommended `uninstall_main` Structure

```bash
uninstall_main() {
    check_root
    detect_os   # needed for NGINX_CONF_LINK

    # 1. Load config
    [[ -f /etc/proxyebator/server.conf ]] \
        || die "No installation found at /etc/proxyebator/server.conf"
    # shellcheck disable=SC1091
    source /etc/proxyebator/server.conf

    # 2. Confirm (unless --yes flag)
    _uninstall_confirm

    # 3. Remove in reverse-install order
    _uninstall_service        # stop, disable, remove unit, daemon-reload
    _uninstall_binary         # rm chisel, rm auth.json, rmdir /etc/chisel
    _uninstall_nginx          # rm conf, rm symlink, reload nginx
    _uninstall_firewall       # ufw delete or iptables -D
    _uninstall_config         # rm server.conf, rmdir /etc/proxyebator

    log_info "Uninstall complete."
    log_info "TLS certificate preserved at: /etc/letsencrypt/live/${DOMAIN}/"
    log_info "To remove the certificate: certbot delete --cert-name ${DOMAIN}"
}
```

Using sub-functions keeps each removal step focused and testable.

### 5.2 Guard Pattern for Every Removal Step

Every removal step MUST be guarded so uninstall is idempotent (safe to run twice):

```bash
_uninstall_service() {
    if systemctl is-active --quiet proxyebator 2>/dev/null \
        || systemctl is-enabled --quiet proxyebator 2>/dev/null; then
        systemctl stop proxyebator 2>/dev/null || true
        systemctl disable proxyebator 2>/dev/null || true
    fi
    if [[ -f /etc/systemd/system/proxyebator.service ]]; then
        rm -f /etc/systemd/system/proxyebator.service
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null || true
        log_info "Removed proxyebator.service"
    else
        log_info "proxyebator.service: not found, skipping"
    fi
}
```

This pattern ensures each step logs what it did and does not fail if the artifact is already gone.

### 5.3 set -euo pipefail Compatibility

The script uses `set -euo pipefail` at the top. All uninstall steps that may legitimately fail (e.g., removing a non-existent file) MUST use `|| true` or `2>/dev/null || true`. Do not use bare `rm` without `|| true` or `[[ -f ]] &&` guards.

### 5.4 CLI Flag for Non-Interactive Uninstall

Add `--yes` flag to the CLI parser for uninstall mode:

```bash
# In the flag parsing while loop:
--yes) UNINSTALL_YES="true" ;;
```

This enables AI-agent-driven usage: `sudo ./proxyebator.sh uninstall --yes`.

---

## 6. Common Pitfalls

### Pitfall 1: Sourcing server.conf Without set -euo Awareness
**What goes wrong:** If server.conf has a line like `PROXY_URL=` (empty value) and the script uses `${PROXY_URL}` (without `:-` default), set -u causes "unbound variable" on reference.
**How to avoid:** Always use `${VAR:-}` when referencing sourced config values that may be empty (e.g., PROXY_URL is only set for masquerade_mode=proxy).

### Pitfall 2: NGINX_CONF_LINK Not Set Before nginx Removal
**What goes wrong:** `detect_os` sets `NGINX_CONF_LINK`, but if uninstall does not call `detect_os`, the variable is unset. On Debian/Ubuntu, the symlink in `sites-enabled/` is never removed, nginx reloads fine but the dead symlink causes a warning.
**How to avoid:** Always call `detect_os` at the top of `uninstall_main`.

### Pitfall 3: Removing iptables Rule That Was Never Added
**What goes wrong:** If ufw was active during install (ufw path taken), iptables rules were not added. If uninstall tries `iptables -D` anyway, it logs non-fatal errors. With `|| true` this is safe, but without `|| true` it exits.
**How to avoid:** Mirror the install logic: check if ufw is active before attempting iptables deletion.

### Pitfall 4: `systemctl enable --now` on Re-run Creates Duplicate Timer Units
**What goes wrong:** Not directly a risk with proxyebator.service, but relevant if the implementation accidentally calls enable twice.
**How to avoid:** The `is-active` guard in `server_create_systemd` prevents this.

### Pitfall 5: Config Written Before Auth File on Re-run
**What goes wrong:** If `server_setup_auth` skips (auth file exists) but `server_save_config` does NOT skip, the config gets a new generated `AUTH_TOKEN` that does not match the actual `/etc/chisel/auth.json`. Client connections break.
**How to avoid:** If auth file exists, also skip config save (or re-source the existing config to get the real token). The cleanest solution: if auth file exists, source existing server.conf to populate `AUTH_TOKEN`, `SECRET_PATH`, etc., then skip all generation steps.

### Pitfall 6: `rmdir` Fails When /etc/chisel Has Other Files
**What goes wrong:** `rmdir /etc/chisel` exits non-zero if the directory is not empty. With `set -euo pipefail`, this kills the script.
**How to avoid:** Always `rmdir /etc/chisel 2>/dev/null || true`.

### Pitfall 7: nginx reload After Config Removal Fails When nginx Is Not Running
**What goes wrong:** `systemctl reload nginx` fails if nginx is not active. This exits the uninstall script early (with `set -euo pipefail`).
**How to avoid:** Guard with `systemctl is-active --quiet nginx && systemctl reload nginx || true`.

---

## 7. Code Examples (Verified Against Current Codebase)

### Pattern: Source server.conf (from existing verify_main)
```bash
# Source: proxyebator.sh lines 1013-1015 (verify_main)
[[ -f /etc/proxyebator/server.conf ]] \
    || die "server.conf not found --- run: sudo ./proxyebator.sh server"
# shellcheck disable=SC1091
source /etc/proxyebator/server.conf
```

### Pattern: systemctl idempotent check (from verify_main)
```bash
# Source: proxyebator.sh lines 1022-1030 (verify_main check 1)
if systemctl is-active --quiet proxyebator 2>/dev/null; then
    # service is running
fi
```

### Pattern: iptables -C before -A (from server_configure_firewall)
```bash
# Source: proxyebator.sh lines 923-929
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
```

### Pattern: nginx symlink creation with existence check (from write_nginx_ssl_config)
```bash
# Source: proxyebator.sh lines 861-864
if [[ -n "${NGINX_CONF_LINK:-}" ]]; then
    local symlink_path="${NGINX_CONF_LINK}/$(basename "$NGINX_CONF_PATH")"
    if [[ ! -L "$symlink_path" ]]; then
        ln -sf "$NGINX_CONF_PATH" "$symlink_path"
    fi
fi
```

### Pattern: command -v idempotency guard (from server_install_deps)
```bash
# Source: proxyebator.sh lines 552-561
for pkg in curl openssl nginx; do
    if command -v "$pkg" &>/dev/null; then
        log_info "${pkg}: already installed"
    else
        log_info "Installing ${pkg}..."
        eval "$PKG_INSTALL $pkg"
    fi
done
```

### Pattern: Binary existence check for client (from client_download_chisel)
```bash
# Source: proxyebator.sh lines 258-261
if command -v chisel &>/dev/null; then
    log_info "chisel already installed: $(chisel --version 2>&1 | head -1)"
    CHISEL_BIN="$(command -v chisel)"
    return
fi
```

This exact pattern should be replicated in `server_download_chisel` for idempotency, checking `/usr/local/bin/chisel` directly.

---

## 8. Implementation Plan Guidance

Phase 5 naturally splits into two plans:

**Plan 05-01: Uninstall**
- Implement `_uninstall_confirm`, `_uninstall_service`, `_uninstall_binary`, `_uninstall_nginx`, `_uninstall_firewall`, `_uninstall_config`
- Wire them into `uninstall_main`
- Add `--yes` flag to CLI parser
- Add `NGINX_INJECTED` field to `server_save_config` (small addition to server_main path)

**Plan 05-02: Idempotency + Credential Hygiene**
- Add existence guard to `server_download_chisel`
- Add existence guard to `server_setup_auth`
- Add `is-active` guard to `server_create_systemd`
- Add existence guard to `server_save_config`
- Add idempotency to re-run: if server.conf exists, source it and skip param collection for already-set values
- Verify TUNNEL-07 compliance (no code change, add assertion in verify or comments)

---

## Open Questions

1. **NGINX injection tracking:** The current `server_save_config` does not record whether nginx config was freshly created or injected into an existing one. Should we add `NGINX_INJECTED=true` to `server.conf`?
   - What we know: `server_configure_nginx` uses `NGINX_EXISTING_CONF` variable, but that is not saved
   - What is unclear: Whether Phase 5 scope includes modifying server_save_config
   - Recommendation: Yes, add it — it costs one line in `server_save_config` and makes uninstall safe for both cases

2. **Re-run credential preservation:** When server.conf already exists and install is re-run, should the script present the existing connection info (from server.conf) rather than generating new secrets?
   - What we know: Generating new secrets breaks existing clients
   - What is unclear: Whether re-run should also regenerate (update) credentials or strictly preserve
   - Recommendation: Strictly preserve — use `source /etc/proxyebator/server.conf` at the top of `server_collect_params` if the file exists, then skip `gen_secret_path` and `gen_auth_token`

3. **Partial uninstall state:** If uninstall fails midway (e.g., nginx reload fails), the system is in a partially-uninstalled state and server.conf is still present. Should the script be re-runnable after partial failure?
   - Recommendation: Yes — every removal step must be guarded with existence checks, making uninstall itself idempotent

---

## Sources

### Primary (HIGH confidence — direct codebase analysis)
- `/home/kosya/vibecoding/proxyebator/proxyebator.sh` — full script read, all install functions analyzed
- `/home/kosya/vibecoding/proxyebator/.planning/REQUIREMENTS.md` — DEL-01, DEL-02, SCRIPT-04, TUNNEL-07 specs
- `/home/kosya/vibecoding/proxyebator/.planning/ROADMAP.md` — Phase 5 success criteria

### Secondary (HIGH confidence — established systemd/bash knowledge)
- systemd documentation: `systemctl stop/disable/daemon-reload/reset-failed` sequence for service removal
- iptables semantics: `-D` (delete) mirrors `-A` (add) argument list exactly
- ufw behavior: `ufw delete allow PORT/proto` matches by action+port, not comment
- bash `source` behavior with `KEY=VALUE` format files
- Let's Encrypt rate limits: 5 certs/domain/week — reason to preserve certs on uninstall

---

## Metadata

**Confidence breakdown:**
- Artifact inventory: HIGH — derived from direct code analysis of install functions
- Uninstall ordering: HIGH — reverse of install order, standard practice
- Idempotency gaps: HIGH — derived from reading each install function
- Credential hygiene: HIGH — `--authfile` behavior is well-documented in chisel docs
- Edge cases: MEDIUM — some (nginx injection, partial uninstall) require design decisions not fully specified in requirements

**Research date:** 2026-02-18
**Valid until:** 2026-06-01 (stable bash/systemd patterns, no fast-moving dependencies)
