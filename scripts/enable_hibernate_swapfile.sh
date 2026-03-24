#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# enable_hibernate_swapfile.sh — Oneshot hibernation setup for Arch Linux
# Creates a dedicated @swap btrfs subvolume, mounts it at /swap, creates
# a swap file inside it, adds resume= params, and ensures the initramfs
# has the resume hook.  Works on a fresh install.
#
# NOTE: systemd ≥259 requires the swapfile to live on its own subvolume
# (not the root @), otherwise CanHibernate reports "na".
#
# Usage:  sudo ./enable_hibernate_swapfile.sh [SIZE]   (default: RAM + 2G)
# ─────────────────────────────────────────────────────────
set -euo pipefail

SWAP_SUBVOL="@swap"
SWAP_MOUNT="/swap"
SWAPFILE="${SWAP_MOUNT}/swapfile"

# Auto-detect RAM and size swapfile to RAM + 2 GiB (rounded up)
# Override with: sudo ./enable_hibernate_swapfile.sh 32G
if [[ -n "${1:-}" ]]; then
    SWAPSIZE="$1"
else
    RAM_KIB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    RAM_GIB=$(( (RAM_KIB + 1048575) / 1048576 ))   # round up to next GiB
    SWAPSIZE="$(( RAM_GIB + 2 ))G"
    echo "  Auto-detected RAM: ${RAM_GIB}G → swap size: ${SWAPSIZE}"
fi

# ── Prereqs ──────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 [SIZE]"; exit 1; }

command -v btrfs &>/dev/null || { echo "btrfs-progs is required."; exit 1; }

root_fstype="$(findmnt -no FSTYPE /)"
[[ "$root_fstype" == "btrfs" ]] || { echo "Root is $root_fstype, not btrfs — exiting."; exit 1; }

# Detect the underlying block device (e.g. /dev/mapper/root or /dev/sda2)
root_device="$(findmnt -no SOURCE /)"
# Detect the btrfs UUID for fstab
root_uuid="$(findmnt -no UUID /)"

echo "══════════════════════════════════════════════════════"
echo " Hibernate via Swap File  (oneshot — btrfs / Arch)"
echo " Using dedicated @swap subvolume (systemd ≥259 fix)"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Step 1: Create @swap subvolume ───────────────────────
echo "[1/8] Creating @swap btrfs subvolume..."

# Clean up legacy /swapfile on root @ subvolume if present
if [[ -f /swapfile ]] && swapon --show=NAME | grep -qx "/swapfile"; then
    echo "  ⚠ Found old /swapfile on root subvolume — disabling..."
    swapoff /swapfile
fi
if [[ -f /swapfile ]]; then
    rm -f /swapfile
    sed -i '\|[[:space:]]/swapfile[[:space:]]|d' /etc/fstab
    echo "  ✓ Removed legacy /swapfile and fstab entry"
fi

BTRFS_TMPDIR="$(mktemp -d)"
mount -t btrfs -o subvolid=5 "$root_device" "$BTRFS_TMPDIR"
if btrfs subvolume show "${BTRFS_TMPDIR}/${SWAP_SUBVOL}" &>/dev/null; then
    echo "  ✓ @swap subvolume already exists"
else
    btrfs subvolume create "${BTRFS_TMPDIR}/${SWAP_SUBVOL}"
    echo "  ✓ Created @swap subvolume"
fi
umount "$BTRFS_TMPDIR" && rmdir "$BTRFS_TMPDIR"
echo ""

# ── Step 2: Mount @swap at /swap ─────────────────────────
echo "[2/8] Mounting @swap at ${SWAP_MOUNT}..."
install -d -m 0755 "$SWAP_MOUNT"
if findmnt -n "$SWAP_MOUNT" &>/dev/null; then
    echo "  ✓ Already mounted"
else
    mount -t btrfs -o subvol=${SWAP_SUBVOL},nodatacow "$root_device" "$SWAP_MOUNT"
    echo "  ✓ Mounted"
fi
echo ""

# ── Step 3: Create swap file ────────────────────────────
echo "[3/8] Swap file ($SWAPFILE, $SWAPSIZE)..."
if [[ ! -f "$SWAPFILE" ]]; then
    btrfs filesystem mkswapfile --size "$SWAPSIZE" --uuid clear "$SWAPFILE"
    echo "  ✓ Created"
else
    echo "  ✓ Already exists"
fi
chmod 600 "$SWAPFILE"
echo ""

# ── Step 4: fstab entries ───────────────────────────────
echo "[4/8] Ensuring fstab entries..."

# @swap mount entry
if ! grep -qE "subvol=${SWAP_SUBVOL}[[:space:],]" /etc/fstab 2>/dev/null && \
   ! grep -qE "[[:space:]]${SWAP_MOUNT}[[:space:]]" /etc/fstab 2>/dev/null; then
    echo "# @swap subvolume for hibernate" >> /etc/fstab
    echo "UUID=${root_uuid} ${SWAP_MOUNT} btrfs subvol=${SWAP_SUBVOL},nodatacow 0 0" >> /etc/fstab
    echo "  ✓ Added @swap mount to /etc/fstab"
else
    echo "  ✓ @swap mount already in fstab"
fi

# Swap file entry
if ! grep -qE "^[^#]*[[:space:]]${SWAPFILE}[[:space:]]" /etc/fstab; then
    echo "${SWAPFILE} none swap defaults,pri=0 0 0" >> /etc/fstab
    echo "  ✓ Added swapfile to /etc/fstab"
else
    echo "  ✓ Swapfile already in fstab"
fi
echo ""

# ── Step 5: Enable swap ─────────────────────────────────
echo "[5/8] Activating swap..."
if ! swapon --show=NAME | grep -qx "$SWAPFILE"; then
    swapon "$SWAPFILE"
    echo "  ✓ Enabled"
else
    echo "  ✓ Already active"
fi
swapon --show
echo ""

# ── Step 6: Compute resume device & offset ──────────────
echo "[6/8] Computing resume parameters..."
resume_dev="$root_device"
resume_offset="$(btrfs inspect-internal map-swapfile -r "$SWAPFILE")"

[[ -n "$resume_offset" ]] || { echo "Failed to get resume_offset"; exit 1; }
echo "  resume=$resume_dev  resume_offset=$resume_offset"

# Update /etc/kernel/cmdline (UKI-based boots)
cmdline_file="/etc/kernel/cmdline"
if [[ -f "$cmdline_file" ]]; then
    cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
    old="$(cat "$cmdline_file")"
    clean="$(echo "$old" \
        | sed -E 's/(^| )resume=[^ ]+//g; s/(^| )resume_offset=[^ ]+//g' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    new="$clean resume=$resume_dev resume_offset=$resume_offset"
    if [[ "$new" != "$old" ]]; then
        printf '%s\n' "$new" > "$cmdline_file"
        echo "  ✓ $cmdline_file updated"
    else
        echo "  ✓ $cmdline_file already correct"
    fi
else
    echo "  ⚠ $cmdline_file not found — update your bootloader params manually:"
    echo "    resume=$resume_dev resume_offset=$resume_offset"
fi
echo ""

# ── Step 7: Ensure resume hook in mkinitcpio ─────────────
echo "[7/8] Checking mkinitcpio resume hook..."
MKINIT="/etc/mkinitcpio.conf"
HOOKS_LINE="$(grep '^HOOKS=' "$MKINIT")"

if ! echo "$HOOKS_LINE" | grep -qw resume; then
    cp "$MKINIT" "${MKINIT}.backup.$(date +%Y%m%d_%H%M%S)"
    # Insert 'resume' before 'filesystems'
    sed -i 's/\bfilesystems\b/resume filesystems/' "$MKINIT"
    echo "  ✓ Added 'resume' hook"
    echo "    $(grep '^HOOKS=' "$MKINIT")"
else
    echo "  ✓ 'resume' hook already present"
fi
echo ""

# Also set HibernateMode=shutdown so the machine powers off cleanly
echo "[8/8] Setting HibernateMode=shutdown..."
install -d -m 0755 /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/99-hibernate-shutdown.conf << 'EOF'
[Sleep]
HibernateMode=shutdown
EOF
echo "  ✓ /etc/systemd/sleep.conf.d/99-hibernate-shutdown.conf"
echo ""

# Rebuild
echo "Rebuilding initramfs / UKI..."
mkinitcpio -P
echo "  ✓ Done"

# ── Summary ──────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " ✓  Hibernation configured"
echo "══════════════════════════════════════════════════════"
echo ""
echo "Swap:    $(swapon --show)"
echo "Cmdline: $(cat "$cmdline_file" 2>/dev/null || echo '(manual)')"
echo ""
echo "Next: reboot, then test with:  systemctl hibernate"
