#!/usr/bin/env bash
###############################################################################
# hibernate-guard.sh — Disable hibernate when disk/swap space is too low
#
# Run by hibernate-guard.timer (every 5 min by default).
# Masks hibernate.target + suspend-then-hibernate.target when:
#   1. Swap usage exceeds SWAP_THRESHOLD (default 85%)
#   2. Root filesystem usage exceeds ROOT_THRESHOLD (default 90%)
# Unmasks them when both conditions clear.
#
# Configuration: /etc/conf.d/hibernate-guard (optional)
###############################################################################
set -euo pipefail

# Defaults — override via /etc/conf.d/hibernate-guard
SWAP_THRESHOLD=85       # percent
ROOT_THRESHOLD=90       # percent
LOG_TAG="hibernate-guard"

# Load overrides if present
[[ -f /etc/conf.d/hibernate-guard ]] && source /etc/conf.d/hibernate-guard

log()  { logger -t "$LOG_TAG" "$*"; }

# ── Check swap usage ────────────────────────────────────
check_swap() {
    local total used pct
    read -r total used _ <<< "$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t, t-f}' /proc/meminfo)"
    if (( total == 0 )); then
        echo 0  # no swap → no problem
        return
    fi
    pct=$(( used * 100 / total ))
    echo "$pct"
}

# ── Check root filesystem usage ─────────────────────────
check_root() {
    df --output=pcent / | tail -1 | tr -dc '0-9'
}

# ── Main ─────────────────────────────────────────────────
swap_pct="$(check_swap)"
root_pct="$(check_root)"

hibernate_masked=false
if systemctl is-enabled hibernate.target &>/dev/null; then
    hibernate_masked=false
else
    # Check if masked (not just disabled)
    if [[ "$(systemctl is-enabled hibernate.target 2>/dev/null)" == "masked" ]]; then
        hibernate_masked=true
    fi
fi

should_mask=false
reason=""

if (( swap_pct >= SWAP_THRESHOLD )); then
    should_mask=true
    reason+="swap ${swap_pct}% >= ${SWAP_THRESHOLD}%; "
fi
if (( root_pct >= ROOT_THRESHOLD )); then
    should_mask=true
    reason+="root ${root_pct}% >= ${ROOT_THRESHOLD}%; "
fi

if $should_mask && ! $hibernate_masked; then
    log "DISABLING hibernate: ${reason}"
    systemctl mask --runtime hibernate.target suspend-then-hibernate.target 2>/dev/null || true
    # Write state file so we know we did the masking (vs user-initiated mask)
    echo "masked by hibernate-guard at $(date -Iseconds): ${reason}" > /run/hibernate-guard.masked
elif ! $should_mask && $hibernate_masked && [[ -f /run/hibernate-guard.masked ]]; then
    # Only unmask if WE masked it (state file exists)
    log "RE-ENABLING hibernate: swap ${swap_pct}%, root ${root_pct}% — both below threshold"
    systemctl unmask --runtime hibernate.target suspend-then-hibernate.target 2>/dev/null || true
    rm -f /run/hibernate-guard.masked
fi
