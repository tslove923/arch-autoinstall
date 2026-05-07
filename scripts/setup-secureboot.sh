#!/bin/bash
# ─────────────────────────────────────────────────────────
# setup-secureboot.sh — Oneshot Secure Boot setup for Arch Linux
# Auto-detects boot files and signs everything with sbctl.
# Run once on a fresh install, then reboot and enable Secure Boot.
# ─────────────────────────────────────────────────────────
set -euo pipefail

# ── Prereqs ──────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }

for cmd in sbctl bootctl; do
    command -v "$cmd" &>/dev/null || { echo "Missing: $cmd — install it first."; exit 1; }
done

echo "══════════════════════════════════════════════════════"
echo " Secure Boot Setup  (oneshot — fresh Arch install)"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Step 1: Current status ──────────────────────────────
echo "[1/6] Current Secure Boot status"
sbctl status || true
echo ""

# ── Step 2: Create keys ─────────────────────────────────
echo "[2/6] Creating Secure Boot keys..."
if [[ -d /usr/share/secureboot/keys ]]; then
    echo "  Keys already exist — backing up and regenerating."
    cp -a /usr/share/secureboot "/root/secureboot-backup-$(date +%Y%m%d-%H%M%S)"
    rm -rf /usr/share/secureboot
fi
sbctl create-keys
echo "  ✓ Keys created"
echo ""

# ── Step 3: Auto-discover & sign boot files ─────────────
echo "[3/6] Signing all discoverable boot files..."

sign_if_exists() { [[ -e "$1" ]] && sbctl sign -s "$1" && echo "  ✓ $1"; }

# Detect ESP location: /efi for dual-boot (XBOOTLDR), /boot for standard
if [[ -d /efi/EFI ]]; then
    ESP="/efi"
else
    ESP="/boot"
fi

# systemd-boot EFI binaries
sign_if_exists "$ESP/EFI/BOOT/BOOTX64.EFI"        || true
sign_if_exists "$ESP/EFI/systemd/systemd-bootx64.efi" || true

# Bare vmlinuz (non-UKI installs)
for k in /boot/vmlinuz-*; do
    sign_if_exists "$k" || true
done

# Unified Kernel Images
for u in /boot/EFI/Linux/*.efi; do
    sign_if_exists "$u" || true
done

echo ""
echo "  All signed files:"
sbctl list-files
echo ""

# ── Step 4: Verify ──────────────────────────────────────
echo "[4/6] Verifying signatures..."
sbctl verify
echo ""

# ── Step 5: Enroll keys ─────────────────────────────────
echo "[5/6] Enrolling keys in firmware (with Microsoft compatibility)..."
echo "  This keeps dual-boot and option ROM support working."
echo ""

# Warn about BitLocker if Windows is detected on a dual-boot system
if [[ -d /efi/EFI/Microsoft ]] || [[ -d /boot/EFI/Microsoft ]]; then
    echo "══════════════════════════════════════════════════════"
    echo " ⚠  WARNING: Windows detected — BitLocker recovery"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo "  Enrolling Secure Boot keys changes the firmware key"
    echo "  database (PK/KEK/db), which alters PCR 7. If Windows"
    echo "  has BitLocker enabled and bound to PCR 7 (the default),"
    echo "  it will trigger a BitLocker recovery prompt on next"
    echo "  Windows boot."
    echo ""
    echo "  Before continuing, make sure you have your BitLocker"
    echo "  recovery key. You can find it via:"
    echo "    • Your org's recovery portal (Intune/SCCM/AD)"
    echo "    • manage-bde -protectors -get C:  (admin PowerShell)"
    echo "    • https://aka.ms/myrecoverykey  (Microsoft account)"
    echo ""
    echo "  After entering the recovery key once, BitLocker will"
    echo "  re-seal to the new PCR values automatically."
    echo ""
    read -rp "  Continue with key enrollment? [y/N] " -n1; echo
    [[ ${REPLY,,} == y ]] || { echo "Aborted. Re-run when ready."; exit 0; }
    echo ""
fi

# Remove immutable flag on EFI vars (some firmware sets it)
chattr -i /sys/firmware/efi/efivars/{PK,KEK,db,dbx}* 2>/dev/null || true

sbctl enroll-keys --microsoft
echo "  ✓ Keys enrolled"
echo ""
sbctl status
echo ""

# ── Step 6: Pacman hook ─────────────────────────────────
echo "[6/6] Installing pacman hook for automatic re-signing..."
HOOK="/etc/pacman.d/hooks/99-sbctl.hook"
if [[ -f "$HOOK" ]]; then
    echo "  ✓ Hook already exists: $HOOK"
else
    mkdir -p /etc/pacman.d/hooks
    cat > "$HOOK" << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = boot/vmlinuz-*
Target = usr/lib/modules/*/vmlinuz
Target = boot/EFI/Linux/*.efi
Target = efi/EFI/BOOT/*
Target = efi/EFI/systemd/*

[Action]
Description = Re-signing boot files with sbctl
When = PostTransaction
Exec = /usr/bin/sbctl sign-all
Depends = sbctl
EOF
    echo "  ✓ Created $HOOK"
fi

# ── Done ─────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " ✓  Secure Boot setup complete"
echo "══════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Reboot — system should still boot fine (Audit Mode)."
echo "  2. Enter BIOS (F2) → Security → Secure Boot"
echo "     → set to User Mode or Deployed Mode."
echo "  3. Boot, then verify:  sudo sbctl status"
echo "  4. Once Secure Boot shows Enabled, run:"
echo "     sudo ./setup-tpm-unlock.sh"
echo ""
echo "Fallback: if boot fails, enter BIOS → disable Secure Boot"
echo "  → boot Linux → re-run this script."
echo ""

read -rp "Reboot now? [y/N] " -n1; echo
[[ ${REPLY,,} == y ]] && { echo "Rebooting in 3s..."; sleep 3; systemctl reboot; }
