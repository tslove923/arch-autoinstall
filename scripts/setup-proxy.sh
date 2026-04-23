#!/usr/bin/env bash
###############################################################################
# setup-proxy.sh — Configure corporate proxy for Arch Linux live environment
# Run before archinstall on networks that require a proxy.
#
# Usage: source setup-proxy.sh          (to export vars into current shell)
#    or: bash setup-proxy.sh            (standalone — writes /etc/environment)
#
# Proxy settings are also applied to:
#   - pacman (via environment)
#   - dirmngr (PGP key fetching)
#   - reflector (mirrorlist updates)
#   - curl / wget
#   - systemd-timesyncd
###############################################################################
# Note: no set -euo pipefail here — this script is sourced by autorun.sh
# which already has strict mode. Failures are handled explicitly.

PROXY="${PROXY_URL:?PROXY_URL must be set}"
SOCKS_PROXY="${SOCKS_PROXY_URL:-}"
NO_PROXY_LIST="${NO_PROXY:-10.0.0.0/8,192.168.0.0/16,localhost,.local,127.0.0.0/8,172.16.0.0/12}"

log()  { echo -e "\033[0;32m[✓]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[0;31m[✗]\033[0m $*"; }
info() { echo -e "\033[0;36m[i]\033[0m $*"; }

info "Configuring proxy: $PROXY"

# ── 1. Export environment variables ──────────────────────
export http_proxy="$PROXY"
export https_proxy="$PROXY"
export ftp_proxy="$PROXY"
export socks_proxy="$SOCKS_PROXY"
export no_proxy="$NO_PROXY_LIST"
export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export FTP_PROXY="$PROXY"
export SOCKS_PROXY="$SOCKS_PROXY"
export NO_PROXY="$NO_PROXY_LIST"
log "Environment variables set"

# ── 2. Persist to /etc/environment ───────────────────────
cat > /etc/environment << EOF
http_proxy=$PROXY
https_proxy=$PROXY
ftp_proxy=$PROXY
socks_proxy=$SOCKS_PROXY
no_proxy=$NO_PROXY_LIST
HTTP_PROXY=$PROXY
HTTPS_PROXY=$PROXY
FTP_PROXY=$PROXY
SOCKS_PROXY=$SOCKS_PROXY
NO_PROXY=$NO_PROXY_LIST
EOF
log "Proxy persisted to /etc/environment"

# ── 3. Sudo: preserve proxy vars ────────────────────────
cat > /etc/sudoers.d/proxy << 'EOF'
Defaults env_keep += "http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY socks_proxy SOCKS_PROXY"
EOF
chmod 0440 /etc/sudoers.d/proxy
log "Sudo configured to preserve proxy"

# ── 4. DNS — add custom nameservers ─────────────────────
DNS_SERVERS="${PROXY_DNS:-}"
if [[ -n "$DNS_SERVERS" ]]; then
    if ! grep -q "${DNS_SERVERS%% *}" /etc/resolv.conf 2>/dev/null; then
        cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true
        for ns in $DNS_SERVERS; do
            echo "nameserver $ns" >> /etc/resolv.conf
        done
        log "Custom DNS servers added"
    else
        log "Custom DNS already configured"
    fi
fi

# ── 5. dirmngr (PGP key fetching via proxy) ─────────────
mkdir -p /etc/pacman.d/gnupg
cat > /etc/pacman.d/gnupg/dirmngr.conf << EOF
honor-http-proxy
http-proxy $PROXY
EOF

mkdir -p /etc/systemd/system/dirmngr@etc-pacman.d-gnupg.service.d
cat > /etc/systemd/system/dirmngr@etc-pacman.d-gnupg.service.d/override.conf << EOF
[Service]
Environment="http_proxy=$PROXY"
Environment="https_proxy=$PROXY"
Environment="no_proxy=$NO_PROXY_LIST"
EOF
pkill dirmngr 2>/dev/null || true
log "dirmngr configured for proxy"

# ── 6. NTP — proxy-aware time sync ───────────────────────
NTP_SERVERS="${PROXY_NTP:-0.arch.pool.ntp.org 1.arch.pool.ntp.org}"
cat > /etc/systemd/timesyncd.conf << EOF
[Time]
NTP=$NTP_SERVERS
FallbackNTP=2.arch.pool.ntp.org 3.arch.pool.ntp.org
EOF

mkdir -p /etc/systemd/system/systemd-timesyncd.service.d
cat > /etc/systemd/system/systemd-timesyncd.service.d/proxy.conf << EOF
[Service]
Environment="http_proxy=$PROXY"
Environment="https_proxy=$PROXY"
Environment="no_proxy=$NO_PROXY_LIST"
EOF

systemctl daemon-reload
systemctl restart systemd-timesyncd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true
log "NTP configured"

# ── 7. reflector proxy ──────────────────────────────────
mkdir -p /etc/systemd/system/reflector.service.d
cat > /etc/systemd/system/reflector.service.d/proxy.conf << EOF
[Service]
Environment="http_proxy=$PROXY"
Environment="https_proxy=$PROXY"
Environment="no_proxy=$NO_PROXY_LIST"
EOF
log "Reflector configured for proxy"

# ── 8. curl / wget defaults ─────────────────────────────
cat > /root/.curlrc << EOF
proxy = $PROXY
EOF
cat > /root/.wgetrc << EOF
http_proxy = $PROXY
https_proxy = $PROXY
ftp_proxy = $PROXY
use_proxy = on
EOF
log "curl/wget configured"

# ── 9. Pacman keyring init if needed ────────────────────
if [[ ! -f /etc/pacman.d/gnupg/trustdb.gpg ]]; then
    info "Initializing pacman keyring..."
    pacman-key --init
    pacman-key --populate archlinux
    log "Pacman keyring initialized"
fi

# ── 10. Test connectivity ────────────────────────────────
info "Testing proxy connectivity..."
if curl -s --max-time 10 -I https://archlinux.org >/dev/null 2>&1; then
    log "Proxy connectivity verified"
elif curl --proxy "$PROXY" -s --max-time 10 -I https://archlinux.org >/dev/null 2>&1; then
    log "Proxy connectivity verified (explicit proxy)"
else
    warn "Proxy connectivity test failed — archinstall may have issues"
fi

# ── 11. Update mirrorlist via reflector ──────────────────
info "Updating mirrorlist..."
if reflector --country US --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    log "Mirrorlist updated via reflector"
else
    warn "Reflector failed, using fallback mirrors"
    cat > /etc/pacman.d/mirrorlist << 'EOF'
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://ftp.osuosl.org/pub/archlinux/$repo/os/$arch
EOF
fi

log "Proxy setup complete"
