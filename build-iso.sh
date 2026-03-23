#!/usr/bin/env bash
###############################################################################
# build-iso.sh — Arch Linux Zero-Touch Installer Builder
#
# Downloads the latest Arch ISO from OSUOSL, customizes it with archinstall
# configuration, and creates a self-installing ISO.
#
# ISO provided by OSUOSL — https://osuosl.org/donate
# Go Beavs! 🦫
#
# Usage:  ./build-iso.sh [--preferred] [--output <path>]
#
# Flags:
#   --preferred    Skip TUI, use preferred configuration
#   --output PATH  Output ISO path (default: ./arch-autoinstall-<date>.iso)
#   --no-download  Skip ISO download, use cached copy
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
ISO_CACHE="${SCRIPT_DIR}/cache"
OUTPUT_DIR="${SCRIPT_DIR}/out"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# OSUOSL mirror — Go Beavs! 🦫
ISO_MIRROR="https://ftp.osuosl.org/pub/archlinux/iso/latest/"
ISO_FILENAME=""  # detected from mirror

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
ORANGE='\033[38;5;208m'
BOLD='\033[1m'
DIM='\033[2m'
RST='\033[0m'

# Configuration state
ENABLE_LUKS=true
ENABLE_HIBERNATE=true
ENABLE_TPM=true
ENABLE_HYPRLAND=true
ENABLE_GNOME=true
ENABLE_II=true           # illogical-impulse
ENABLE_II_FEATURES=true  # custom feature branches
AUTO_DISK=true
TARGET_DISK=""
HOSTNAME_CFG="archlinux"
USERNAME_CFG=""
TIMEZONE_CFG="US/Pacific"
LOCALE_CFG="en_US"
KB_LAYOUT_CFG="us"
GFX_DRIVER="Intel (open-source)"
USE_PREFERRED=false
SKIP_DOWNLOAD=false
OUTPUT_ISO=""

# ─── Parse arguments ───────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --preferred)   USE_PREFERRED=true ;;
        --no-download) SKIP_DOWNLOAD=true ;;
        --output)      shift; OUTPUT_ISO="$1" ;;
        -h|--help)
            sed -n '2,/^###/p' "$0" | head -n -1 | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

# ─── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo -e "${GREEN}[✓]${RST} $*"; }
warn() { echo -e "${YELLOW}[!]${RST} $*"; }
err()  { echo -e "${RED}[✗]${RST} $*"; }
info() { echo -e "${CYAN}[i]${RST} $*"; }
step() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RST}\n"; }

check_deps() {
    local missing=()
    for cmd in dialog curl xorriso mksquashfs unsquashfs mktemp; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies: ${missing[*]}"
        info "Install with: sudo pacman -S dialog curl libisoburn squashfs-tools"
        exit 1
    fi
}

# ─── OSUOSL Banner ────────────────────────────────────────────────────────────
show_banner() {
    # Orange background (#cc3c09) approximation with ANSI
    local BG='\033[48;2;204;60;9m'
    local FG='\033[38;2;255;255;255m'
    echo ""
    echo -e "${BG}${FG}${BOLD}                                                              ${RST}"
    echo -e "${BG}${FG}${BOLD}     ╔══════════════════════════════════════════════════╗      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║      Arch Linux Zero-Touch Installer Builder     ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║                                                  ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           ┌─────────────────────────┐             ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           │      ▄▄▄▄▄   ▄▄▄▄▄    │             ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           │     ██   ██ ██         │             ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           │     ██   ██  ▀▀▀██    │             ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           │     ██   ██     ██    │             ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           │      ▀▀▀▀▀  ▀▀▀▀▀    │             ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           │   OREGON STATE UNIV.   │             ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ║           └─────────────────────────┘             ║      ${RST}"
    echo -e "${BG}${FG}${DIM}     ║                                                  ║      ${RST}"
    echo -e "${BG}${FG}${DIM}     ║    ISO provided by OSUOSL — osuosl.org/donate    ║      ${RST}"
    echo -e "${BG}${FG}${BOLD}     ╚══════════════════════════════════════════════════╝      ${RST}"
    echo -e "${BG}${FG}${BOLD}                          Go Beavs! 🦫                         ${RST}"
    echo -e "${BG}${FG}${BOLD}                                                              ${RST}"
    echo ""
}

# ─── TUI Functions ─────────────────────────────────────────────────────────────

show_main_menu() {
    local result
    result="$(dialog \
        --title " Arch Autoinstaller — Configuration " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --ok-label "Select" \
        --cancel-label "Build ISO" \
        --menu "\nConfigure your Arch Linux installation.\nSelect an option to modify, or press Build ISO when ready.\n" \
        20 70 10 \
        "P" "★ Use Preferred Setup (recommended)" \
        "1" "Security: LUKS / Hibernate / TPM  [$(security_summary)]" \
        "2" "Desktop: Hyprland / GNOME / illogical-impulse" \
        "3" "Disk: Target disk selection" \
        "4" "System: Hostname, user, locale, timezone" \
        "5" "Graphics: GPU driver selection" \
        "R" "Review configuration" \
        3>&1 1>&2 2>&3)" || return 1
    echo "$result"
}

security_summary() {
    local parts=()
    $ENABLE_LUKS && parts+=("LUKS") || parts+=("no-crypt")
    $ENABLE_HIBERNATE && parts+=("Hibernate")
    $ENABLE_TPM && parts+=("TPM")
    echo "${parts[*]}"
}

configure_security() {
    local -a args=()
    args+=(1 "LUKS full-disk encryption" "$($ENABLE_LUKS && echo on || echo off)")
    args+=(2 "Hibernate support (btrfs @swap subvolume)" "$($ENABLE_HIBERNATE && echo on || echo off)")
    args+=(3 "TPM2 auto-unlock (requires Secure Boot)" "$($ENABLE_TPM && echo on || echo off)")

    local result
    result="$(dialog \
        --title " Security Options " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --checklist "\nSelect security features.\nHibernate requires LUKS+btrfs. TPM requires LUKS.\n" \
        14 65 3 \
        "${args[@]}" \
        3>&1 1>&2 2>&3)" || return 0

    ENABLE_LUKS=false; ENABLE_HIBERNATE=false; ENABLE_TPM=false
    for item in $result; do
        item="${item//\"/}"
        case "$item" in
            1) ENABLE_LUKS=true ;;
            2) ENABLE_HIBERNATE=true ;;
            3) ENABLE_TPM=true ;;
        esac
    done

    # Enforce dependencies
    if $ENABLE_HIBERNATE && ! $ENABLE_LUKS; then
        ENABLE_LUKS=true
        dialog --msgbox "LUKS auto-enabled (required for hibernate resume device detection)." 7 55
    fi
    if $ENABLE_TPM && ! $ENABLE_LUKS; then
        ENABLE_LUKS=true
        dialog --msgbox "LUKS auto-enabled (required for TPM auto-unlock)." 7 55
    fi
}

configure_desktop() {
    local -a args=()
    args+=(1 "Hyprland (tiling Wayland compositor)" "$($ENABLE_HYPRLAND && echo on || echo off)")
    args+=(2 "GNOME (full desktop environment)" "$($ENABLE_GNOME && echo on || echo off)")

    local result
    result="$(dialog \
        --title " Desktop Environment " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --checklist "\nSelect desktop environments to install.\n" \
        12 60 2 \
        "${args[@]}" \
        3>&1 1>&2 2>&3)" || return 0

    ENABLE_HYPRLAND=false; ENABLE_GNOME=false
    for item in $result; do
        item="${item//\"/}"
        case "$item" in
            1) ENABLE_HYPRLAND=true ;;
            2) ENABLE_GNOME=true ;;
        esac
    done

    # If Hyprland selected, offer illogical-impulse
    if $ENABLE_HYPRLAND; then
        configure_illogical_impulse
    else
        ENABLE_II=false
        ENABLE_II_FEATURES=false
    fi
}

configure_illogical_impulse() {
    local result
    result="$(dialog \
        --title " Hyprland Customization " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --radiolist "\nSelect Hyprland rice level:\n" \
        14 65 3 \
        1 "Vanilla Hyprland (no rice)" "$([[ $ENABLE_II == false ]] && echo on || echo off)" \
        2 "illogical-impulse (end-4 rice)" "$([[ $ENABLE_II == true && $ENABLE_II_FEATURES == false ]] && echo on || echo off)" \
        3 "illogical-impulse + custom features (recommended)" "$($ENABLE_II_FEATURES && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        1) ENABLE_II=false; ENABLE_II_FEATURES=false ;;
        2) ENABLE_II=true;  ENABLE_II_FEATURES=false ;;
        3) ENABLE_II=true; ENABLE_II_FEATURES=true
           # Offer the feature picker from dots-hyprland-dev
           dialog --msgbox "After first boot, run apply-features.sh to select\nwhich illogical-impulse features to enable.\n\nThe feature picker TUI will be installed at:\n  ~/projects/dots-hyprland-dev/apply-features.sh" 10 58
           ;;
    esac
}

configure_disk() {
    local result
    result="$(dialog \
        --title " Disk Selection " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --radiolist "\nHow should the installer select the target disk?\n" \
        12 65 2 \
        1 "Automatic (largest available disk)" "$($AUTO_DISK && echo on || echo off)" \
        2 "Interactive (choose during install)" "$(! $AUTO_DISK && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        1) AUTO_DISK=true ;;
        2) AUTO_DISK=false ;;
    esac
}

configure_system() {
    local result
    result="$(dialog \
        --title " System Configuration " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --form "\nSet system parameters:\n" \
        16 60 5 \
        "Hostname:"  1 1 "$HOSTNAME_CFG"  1 15 30 60 \
        "Username:"  2 1 "$USERNAME_CFG"  2 15 30 30 \
        "Timezone:"  3 1 "$TIMEZONE_CFG"  3 15 30 40 \
        "Locale:"    4 1 "$LOCALE_CFG"    4 15 30 10 \
        "KB Layout:" 5 1 "$KB_LAYOUT_CFG" 5 15 30 10 \
        3>&1 1>&2 2>&3)" || return 0

    # Parse form output (one value per line)
    local -a vals
    mapfile -t vals <<< "$result"
    [[ -n "${vals[0]:-}" ]] && HOSTNAME_CFG="${vals[0]}"
    [[ -n "${vals[1]:-}" ]] && USERNAME_CFG="${vals[1]}"
    [[ -n "${vals[2]:-}" ]] && TIMEZONE_CFG="${vals[2]}"
    [[ -n "${vals[3]:-}" ]] && LOCALE_CFG="${vals[3]}"
    [[ -n "${vals[4]:-}" ]] && KB_LAYOUT_CFG="${vals[4]}"
}

configure_graphics() {
    local result
    result="$(dialog \
        --title " Graphics Driver " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --radiolist "\nSelect GPU driver:\n" \
        14 55 5 \
        1 "Intel (open-source)" "$([[ "$GFX_DRIVER" == "Intel (open-source)" ]] && echo on || echo off)" \
        2 "Nvidia (proprietary)" "$([[ "$GFX_DRIVER" == "Nvidia (proprietary)" ]] && echo on || echo off)" \
        3 "Nvidia (open-source)" "$([[ "$GFX_DRIVER" == "Nvidia (open-source nouveau)" ]] && echo on || echo off)" \
        4 "AMD / ATI (open-source)" "$([[ "$GFX_DRIVER" == "AMD / ATI (open-source)" ]] && echo on || echo off)" \
        5 "VMware / VirtualBox" "$([[ "$GFX_DRIVER" == "VMware / VirtualBox (open-source)" ]] && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        1) GFX_DRIVER="Intel (open-source)" ;;
        2) GFX_DRIVER="Nvidia (proprietary)" ;;
        3) GFX_DRIVER="Nvidia (open-source nouveau)" ;;
        4) GFX_DRIVER="AMD / ATI (open-source)" ;;
        5) GFX_DRIVER="VMware / VirtualBox (open-source)" ;;
    esac
}

show_review() {
    local luks_str="Disabled"; $ENABLE_LUKS && luks_str="Enabled"
    local hib_str="Disabled";  $ENABLE_HIBERNATE && hib_str="Enabled"
    local tpm_str="Disabled";  $ENABLE_TPM && tpm_str="Enabled"
    local disk_str="Automatic (largest)"; $AUTO_DISK || disk_str="Interactive"
    local de_list=""
    $ENABLE_HYPRLAND && de_list+="Hyprland "
    $ENABLE_GNOME && de_list+="GNOME "
    [[ -z "$de_list" ]] && de_list="(none)"
    local ii_str="No"
    $ENABLE_II && ii_str="Yes"
    $ENABLE_II_FEATURES && ii_str="Yes + custom features"

    dialog \
        --title " Configuration Review " \
        --backtitle "ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs!" \
        --msgbox "
╔══════════════════════════════════════════╗
║         INSTALLATION CONFIGURATION       ║
╠══════════════════════════════════════════╣
║                                          ║
║  Security                                ║
║    LUKS encryption:  $luks_str
║    Hibernate:        $hib_str
║    TPM auto-unlock:  $tpm_str
║                                          ║
║  Desktop                                 ║
║    Environments:     $de_list
║    illogical-impulse: $ii_str
║                                          ║
║  System                                  ║
║    Hostname:    $HOSTNAME_CFG
║    Username:    ${USERNAME_CFG:-(set during install)}
║    Timezone:    $TIMEZONE_CFG
║    GPU driver:  $GFX_DRIVER
║    Disk mode:   $disk_str
║                                          ║
║  Post-Install (first boot):              ║
║    • Secure Boot setup (if TPM enabled)  ║
║    • TPM enrollment (after Secure Boot)  ║
║    • Hibernate configuration             ║
║    • illogical-impulse (if selected)     ║
║                                          ║
╚══════════════════════════════════════════╝
" 32 50
}

apply_preferred() {
    ENABLE_LUKS=true
    ENABLE_HIBERNATE=true
    ENABLE_TPM=true
    ENABLE_HYPRLAND=true
    ENABLE_GNOME=true
    ENABLE_II=true
    ENABLE_II_FEATURES=true
    AUTO_DISK=true
    HOSTNAME_CFG="archlinux"
    TIMEZONE_CFG="US/Pacific"
    LOCALE_CFG="en_US"
    KB_LAYOUT_CFG="us"
    GFX_DRIVER="Intel (open-source)"
}

# ─── TUI Main Loop ────────────────────────────────────────────────────────────

run_tui() {
    while true; do
        local choice
        choice="$(show_main_menu)" || break  # "Build ISO" = cancel = break

        case "$choice" in
            P) apply_preferred
               dialog --msgbox "Preferred configuration applied!\n\n• LUKS + Hibernate + TPM\n• Hyprland + GNOME\n• illogical-impulse + features\n• Auto disk, US/Pacific, Intel GPU" 12 50
               ;;
            1) configure_security ;;
            2) configure_desktop ;;
            3) configure_disk ;;
            4) configure_system ;;
            5) configure_graphics ;;
            R) show_review ;;
        esac
    done
    clear
}

# ─── Generate archinstall config ──────────────────────────────────────────────

generate_archinstall_config() {
    local config_dir="$1"
    mkdir -p "$config_dir"

    # Build profile details
    local profile_details=()
    $ENABLE_HYPRLAND && profile_details+=("Hyprland")
    $ENABLE_GNOME && profile_details+=("Gnome")

    local profile_json="\"profile\": { \"main\": \"Desktop\", \"details\": ["
    local first=true
    for p in "${profile_details[@]}"; do
        $first || profile_json+=","
        profile_json+="\"$p\""
        first=false
    done
    profile_json+="]"

    # Custom settings for Hyprland
    local custom_settings="{}"
    if $ENABLE_HYPRLAND; then
        custom_settings='{"Hyprland": {"seat_access": "polkit"}}'
    fi
    profile_json+=", \"custom_settings\": $custom_settings }"

    # Greeter
    local greeter="gdm"
    if ! $ENABLE_GNOME && $ENABLE_HYPRLAND; then
        greeter="sddm"
    fi

    # Disk encryption section
    local encryption_json="null"
    if $ENABLE_LUKS; then
        encryption_json='{
        "encryption_type": "luks",
        "partitions": ["__ROOT_PART_UUID__"]
    }'
    fi

    # Btrfs subvolumes — always include @swap if hibernate enabled
    local btrfs_subvols='[
                {"name": "@",          "mountpoint": "/"},
                {"name": "@home",      "mountpoint": "/home"},
                {"name": "@log",       "mountpoint": "/var/log"},
                {"name": "@pkg",       "mountpoint": "/var/cache/pacman/pkg"},
                {"name": "@.snapshots","mountpoint": "/.snapshots"}'
    if $ENABLE_HIBERNATE; then
        btrfs_subvols+=',
                {"name": "@swap",      "mountpoint": "/swap"}'
    fi
    btrfs_subvols+='
            ]'

    # Build the user_configuration.json
    # NOTE: disk_config uses "default_layout" — archinstall will auto-detect
    # the target disk. The __DISK_DEVICE__ placeholder is replaced at install time.
    cat > "$config_dir/user_configuration.json" << JSONEOF
{
    "additional-repositories": [],
    "archinstall-language": "English",
    "audio_config": {
        "audio": "pipewire"
    },
    "bootloader": "Systemd-boot",
    "config_version": "3.0.1",
    "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "__DISK_DEVICE__",
                "partitions": [
                    {
                        "btrfs": [],
                        "dev_path": null,
                        "flags": ["boot", "esp"],
                        "fs_type": "fat32",
                        "mount_options": [],
                        "mountpoint": "/boot",
                        "obj_id": "efi-part-0001",
                        "size": {"sector_size": {"unit": "B", "value": 512}, "unit": "GiB", "value": 1},
                        "start": {"sector_size": {"unit": "B", "value": 512}, "unit": "MiB", "value": 1},
                        "status": "create",
                        "type": "primary"
                    },
                    {
                        "btrfs": $btrfs_subvols,
                        "dev_path": null,
                        "flags": [],
                        "fs_type": "btrfs",
                        "mount_options": ["compress=zstd"],
                        "mountpoint": null,
                        "obj_id": "root-part-0002",
                        "size": {"sector_size": {"unit": "B", "value": 512}, "unit": "Percentage", "value": 100},
                        "start": {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": 1074790400},
                        "status": "create",
                        "type": "primary"
                    }
                ],
                "wipe": true
            }
        ]
    },
    "disk_encryption": $encryption_json,
    "hostname": "$HOSTNAME_CFG",
    "kernels": ["linux"],
    "locale_config": {
        "kb_layout": "$KB_LAYOUT_CFG",
        "sys_enc": "UTF-8",
        "sys_lang": "$LOCALE_CFG"
    },
    "mirror_config": {
        "mirror_regions": {
            "United States": [
                "https://ftp.osuosl.org/pub/archlinux/\$repo/os/\$arch"
            ]
        }
    },
    "network_config": {"type": "nm"},
    "ntp": true,
    "packages": [
        "git", "base-devel", "vim", "htop", "sbctl", "tpm2-tools",
        "dialog", "fish", "networkmanager"
    ],
    "parallel downloads": 5,
    "profile_config": {
        "gfx_driver": "$GFX_DRIVER",
        "greeter": "$greeter",
        $profile_json
    },
    "swap": true,
    "timezone": "$TIMEZONE_CFG",
    "uki": true,
    "version": "3.0.1"
}
JSONEOF

    # User credentials — will prompt during install if not set
    if [[ -n "$USERNAME_CFG" ]]; then
        cat > "$config_dir/user_credentials.json" << CREDEOF
{
    "!users": [
        {
            "!password": "",
            "sudo": true,
            "username": "$USERNAME_CFG"
        }
    ]
}
CREDEOF
    fi

    log "Generated archinstall config at: $config_dir"
}

# ─── Generate post-install script ─────────────────────────────────────────────

generate_post_install() {
    local target="$1"

    cat > "$target" << 'POSTEOF'
#!/usr/bin/env bash
###############################################################################
# post-install.sh — First-boot setup for Arch autoinstall
# Runs automatically or manually after first login.
# Handles: Hibernate, Secure Boot, TPM, illogical-impulse
#
# ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs! 🦫
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RST='\033[0m'

log()  { echo -e "${GREEN}[✓]${RST} $*"; }
warn() { echo -e "${YELLOW}[!]${RST} $*"; }
err()  { echo -e "${RED}[✗]${RST} $*"; }
info() { echo -e "${CYAN}[i]${RST} $*"; }
step() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RST}\n"; }

# Read embedded flags (set by build-iso.sh)
ENABLE_HIBERNATE="__ENABLE_HIBERNATE__"
ENABLE_TPM="__ENABLE_TPM__"
ENABLE_II="__ENABLE_II__"
ENABLE_II_FEATURES="__ENABLE_II_FEATURES__"

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${BOLD}${CYAN}║      Arch Linux Post-Install Configuration          ║${RST}"
echo -e "${BOLD}${CYAN}║      ISO provided by OSUOSL — Go Beavs! 🦫          ║${RST}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""

# ── Hibernate ────────────────────────────────────────────
if [[ "$ENABLE_HIBERNATE" == "true" ]]; then
    step "Hibernate Setup"

    if command -v btrfs &>/dev/null && [[ "$(findmnt -no FSTYPE /)" == "btrfs" ]]; then
        if findmnt -n /swap &>/dev/null; then
            info "@swap subvolume already mounted"
        else
            warn "@swap subvolume not mounted — running hibernate setup"
        fi

        if [[ -f "$SCRIPT_DIR/enable_hibernate_swapfile.sh" ]]; then
            info "Running hibernate setup script..."
            sudo bash "$SCRIPT_DIR/enable_hibernate_swapfile.sh"
            log "Hibernate configured"
        else
            err "enable_hibernate_swapfile.sh not found"
            info "Download from your install media or repo and run manually."
        fi
    else
        warn "Not on btrfs — skipping hibernate setup"
    fi
fi

# ── Secure Boot ──────────────────────────────────────────
if [[ "$ENABLE_TPM" == "true" ]]; then
    step "Secure Boot Setup"

    # Check if we're in Setup Mode
    if command -v sbctl &>/dev/null; then
        SB_STATUS="$(sbctl status 2>/dev/null || true)"
        if echo "$SB_STATUS" | grep -q "Setup Mode:.*Enabled"; then
            info "Firmware is in Setup Mode — enrolling Secure Boot keys"
            if [[ -f "$SCRIPT_DIR/setup-secureboot.sh" ]]; then
                sudo bash "$SCRIPT_DIR/setup-secureboot.sh"
                log "Secure Boot configured"
                echo ""
                warn "╔══════════════════════════════════════════════════════╗"
                warn "║  IMPORTANT: Reboot now, then enter BIOS and enable  ║"
                warn "║  Secure Boot (User Mode or Deployed Mode).          ║"
                warn "║                                                     ║"
                warn "║  After enabling Secure Boot, run this script again  ║"
                warn "║  to complete TPM enrollment.                        ║"
                warn "╚══════════════════════════════════════════════════════╝"
                echo ""
                read -rp "Reboot now to enable Secure Boot? [y/N] " -n1; echo
                if [[ ${REPLY,,} == y ]]; then
                    systemctl reboot
                    exit 0
                fi
            else
                err "setup-secureboot.sh not found"
            fi
        elif echo "$SB_STATUS" | grep -q "Secure Boot:.*Enabled"; then
            info "Secure Boot is already enabled"

            # Now do TPM enrollment
            step "TPM2 Auto-Unlock Enrollment"
            if [[ -f "$SCRIPT_DIR/setup-tpm-unlock.sh" ]]; then
                sudo bash "$SCRIPT_DIR/setup-tpm-unlock.sh"
                log "TPM auto-unlock configured"
            else
                err "setup-tpm-unlock.sh not found"
            fi
        else
            warn "Secure Boot is not enabled and firmware is not in Setup Mode."
            echo ""
            info "To set up TPM auto-unlock:"
            info "  1. Reboot → Enter BIOS → Put Secure Boot in Setup Mode"
            info "  2. Boot Linux → Run: sudo $SCRIPT_DIR/setup-secureboot.sh"
            info "  3. Reboot → BIOS → Enable Secure Boot (User/Deployed Mode)"
            info "  4. Boot Linux → Run: sudo $SCRIPT_DIR/setup-tpm-unlock.sh"
            echo ""
        fi
    else
        warn "sbctl not installed — install with: sudo pacman -S sbctl"
    fi
fi

# ── illogical-impulse ────────────────────────────────────
if [[ "$ENABLE_II" == "true" ]]; then
    step "illogical-impulse Setup"

    if [[ -d ~/projects/dots-hyprland-dev ]]; then
        info "dots-hyprland-dev already cloned"
    else
        info "Cloning illogical-impulse (end-4 dots-hyprland)..."
        mkdir -p ~/projects
        git clone https://github.com/tslove923/dots-hyprland.git ~/projects/dots-hyprland-dev
        log "Cloned to ~/projects/dots-hyprland-dev"
    fi

    cd ~/projects/dots-hyprland-dev
    git checkout main

    info "Running illogical-impulse setup..."
    if [[ -f setup ]]; then
        ./setup install
        log "illogical-impulse base installed"
    else
        err "setup script not found in dots-hyprland-dev"
    fi

    if [[ "$ENABLE_II_FEATURES" == "true" ]]; then
        info "Custom features will be available via apply-features.sh"
        info "Run: cd ~/projects/dots-hyprland-dev && ./apply-features.sh"
        
        # Fetch all feature branches
        git fetch origin --all
        for branch in $(git branch -r | grep 'origin/feature/' | sed 's|origin/||'); do
            git branch "$branch" "origin/$branch" 2>/dev/null || true
        done
        log "Feature branches fetched — run apply-features.sh to select and install"
    fi
fi

# ── Done ─────────────────────────────────────────────────
step "Post-Install Complete"
echo -e "
${GREEN}${BOLD}First-boot configuration finished!${RST}

${CYAN}What was configured:${RST}"
[[ "$ENABLE_HIBERNATE" == "true" ]] && echo "  ✓ Hibernate (btrfs @swap subvolume)"
[[ "$ENABLE_TPM" == "true" ]]       && echo "  ✓ Secure Boot / TPM (check status above)"
[[ "$ENABLE_II" == "true" ]]        && echo "  ✓ illogical-impulse rice"

echo -e "
${YELLOW}If TPM is not yet enrolled:${RST}
  1. Ensure Secure Boot is enabled in BIOS
  2. Run: sudo $SCRIPT_DIR/setup-tpm-unlock.sh

${CYAN}ISO provided by OSUOSL — osuosl.org/donate${RST}
${BOLD}Go Beavs! 🦫${RST}
"
POSTEOF

    chmod +x "$target"

    # Replace flags
    sed -i "s|__ENABLE_HIBERNATE__|$ENABLE_HIBERNATE|g" "$target"
    sed -i "s|__ENABLE_TPM__|$ENABLE_TPM|g" "$target"
    sed -i "s|__ENABLE_II__|$ENABLE_II|g" "$target"
    sed -i "s|__ENABLE_II_FEATURES__|$ENABLE_II_FEATURES|g" "$target"

    log "Generated post-install script: $target"
}

# ─── Generate autorun script (runs inside live ISO) ──────────────────────────

generate_autorun() {
    local target="$1"
    local config_dir="$2"

    cat > "$target" << 'AUTOEOF'
#!/usr/bin/env bash
###############################################################################
# autorun.sh — Runs inside the live ISO to perform automated installation
# ISO provided by OSUOSL — osuosl.org/donate  |  Go Beavs! 🦫
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
AUTO_DISK="__AUTO_DISK__"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RST='\033[0m'
BG_ORANGE='\033[48;2;204;60;9m'; FG_WHITE='\033[38;2;255;255;255m'

echo ""
echo -e "${BG_ORANGE}${FG_WHITE}${BOLD}                                                        ${RST}"
echo -e "${BG_ORANGE}${FG_WHITE}${BOLD}    Arch Linux Zero-Touch Installer                      ${RST}"
echo -e "${BG_ORANGE}${FG_WHITE}${BOLD}    ISO provided by OSUOSL — osuosl.org/donate           ${RST}"
echo -e "${BG_ORANGE}${FG_WHITE}${BOLD}                              Go Beavs! 🦫                ${RST}"
echo -e "${BG_ORANGE}${FG_WHITE}${BOLD}                                                        ${RST}"
echo ""

# Wait for network
echo -e "${CYAN}[i]${RST} Waiting for network..."
for i in $(seq 1 30); do
    if ping -c1 -W1 archlinux.org &>/dev/null; then
        echo -e "${GREEN}[✓]${RST} Network online"
        break
    fi
    sleep 1
done

# Detect or select target disk
detect_disk() {
    # Find the largest non-USB, non-removable disk
    local best_disk="" best_size=0
    while IFS= read -r line; do
        local name size rm type
        name="$(echo "$line" | awk '{print $1}')"
        size="$(echo "$line" | awk '{print $2}')"
        rm="$(echo "$line" | awk '{print $3}')"
        type="$(echo "$line" | awk '{print $4}')"
        [[ "$type" == "disk" && "$rm" == "0" ]] || continue
        # Convert size to bytes for comparison
        local bytes
        bytes="$(lsblk -bno SIZE "/dev/$name" 2>/dev/null | head -1)"
        if (( bytes > best_size )); then
            best_size=$bytes
            best_disk="/dev/$name"
        fi
    done < <(lsblk -ndo NAME,SIZE,RM,TYPE 2>/dev/null)
    echo "$best_disk"
}

if [[ "$AUTO_DISK" == "true" ]]; then
    TARGET_DISK="$(detect_disk)"
    if [[ -z "$TARGET_DISK" ]]; then
        echo -e "${RED}[✗]${RST} No suitable disk found. Falling back to interactive."
        AUTO_DISK=false
    else
        echo -e "${GREEN}[✓]${RST} Auto-selected disk: ${BOLD}$TARGET_DISK${RST} ($(lsblk -ndo SIZE "$TARGET_DISK"))"
        echo ""
        echo -e "${YELLOW}[!] WARNING: ALL DATA on $TARGET_DISK will be erased!${RST}"
        echo ""
        read -rp "Continue with $TARGET_DISK? [y/N] " -n1; echo
        if [[ ${REPLY,,} != y ]]; then
            AUTO_DISK=false
        fi
    fi
fi

if [[ "$AUTO_DISK" != "true" ]]; then
    echo ""
    echo "Available disks:"
    lsblk -do NAME,SIZE,MODEL,RM,TYPE | grep "disk"
    echo ""
    read -rp "Enter target disk (e.g. /dev/sda, /dev/nvme0n1): " TARGET_DISK
    if [[ ! -b "$TARGET_DISK" ]]; then
        echo -e "${RED}[✗]${RST} Invalid disk: $TARGET_DISK"
        exit 1
    fi
fi

# Update config with actual disk
RESOLVED_CONFIG="$(mktemp -d)/config"
cp -r "$CONFIG_DIR" "$RESOLVED_CONFIG" 2>/dev/null || cp -r "${CONFIG_DIR}/"* "$RESOLVED_CONFIG/" 2>/dev/null
mkdir -p "$RESOLVED_CONFIG"
sed -i "s|__DISK_DEVICE__|${TARGET_DISK}|g" "$RESOLVED_CONFIG/user_configuration.json"

# Also fix the partition UUID placeholder for LUKS
ROOT_UUID="root-part-0002"
sed -i "s|__ROOT_PART_UUID__|${ROOT_UUID}|g" "$RESOLVED_CONFIG/user_configuration.json"

echo ""
echo -e "${CYAN}[i]${RST} Starting archinstall with configuration..."
echo -e "${CYAN}[i]${RST} Config: $RESOLVED_CONFIG/user_configuration.json"
echo ""

# Run archinstall
archinstall --config "$RESOLVED_CONFIG/user_configuration.json" \
    ${RESOLVED_CONFIG}/user_credentials.json && \
    echo "" || true

# Copy post-install scripts to the new system
MOUNT_POINT="/mnt/archinstall"
if [[ -d "$MOUNT_POINT" ]]; then
    POST_DIR="$MOUNT_POINT/root/arch-autoinstall"
    mkdir -p "$POST_DIR"
    cp "$SCRIPT_DIR"/scripts/*.sh "$POST_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/post-install.sh" "$POST_DIR/" 2>/dev/null || true
    chmod +x "$POST_DIR"/*.sh 2>/dev/null || true

    # Create a first-boot reminder
    mkdir -p "$MOUNT_POINT/etc/profile.d"
    cat > "$MOUNT_POINT/etc/profile.d/99-post-install-reminder.sh" << 'REMINDEREOF'
#!/bin/bash
if [[ -f /root/arch-autoinstall/post-install.sh && ! -f /root/.post-install-done ]]; then
    echo ""
    echo -e "\033[1;33m╔══════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;33m║  Post-install scripts available at:                      ║\033[0m"
    echo -e "\033[1;33m║    /root/arch-autoinstall/post-install.sh                ║\033[0m"
    echo -e "\033[1;33m║                                                          ║\033[0m"
    echo -e "\033[1;33m║  Run as root to configure hibernate, Secure Boot, TPM,   ║\033[0m"
    echo -e "\033[1;33m║  and illogical-impulse.                                  ║\033[0m"
    echo -e "\033[1;33m╚══════════════════════════════════════════════════════════╝\033[0m"
    echo ""
fi
REMINDEREOF
    chmod +x "$MOUNT_POINT/etc/profile.d/99-post-install-reminder.sh"

    echo -e "${GREEN}[✓]${RST} Post-install scripts copied to new system"
fi

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${RST}"
echo ""
echo -e "${CYAN}Post-install steps after rebooting:${RST}"
echo "  1. Log in as root or your user"
echo "  2. Run: /root/arch-autoinstall/post-install.sh"
echo "  3. Follow the on-screen instructions for Secure Boot + TPM"
echo ""
echo -e "${BOLD}ISO provided by OSUOSL — osuosl.org/donate${RST}"
echo -e "${BOLD}Go Beavs! 🦫${RST}"
echo ""
read -rp "Reboot now? [y/N] " -n1; echo
[[ ${REPLY,,} == y ]] && systemctl reboot
AUTOEOF

    chmod +x "$target"
    sed -i "s|__AUTO_DISK__|$AUTO_DISK|g" "$target"

    log "Generated autorun script: $target"
}

# ─── Download ISO ─────────────────────────────────────────────────────────────

download_iso() {
    mkdir -p "$ISO_CACHE"

    step "Downloading Arch ISO from OSUOSL"
    info "Mirror: $ISO_MIRROR"
    info "ISO provided by OSUOSL — https://osuosl.org/donate"
    info "Go Beavs! 🦫"
    echo ""

    # Detect the latest ISO filename
    ISO_FILENAME="$(curl -sL "$ISO_MIRROR" | grep -oP 'archlinux-\d{4}\.\d{2}\.\d{2}-x86_64\.iso' | head -1)"
    if [[ -z "$ISO_FILENAME" ]]; then
        err "Could not detect ISO filename from OSUOSL mirror"
        exit 1
    fi
    info "Latest ISO: $ISO_FILENAME"

    local iso_path="$ISO_CACHE/$ISO_FILENAME"
    if [[ -f "$iso_path" ]]; then
        log "ISO already cached: $iso_path"
    else
        info "Downloading $ISO_FILENAME..."
        curl -L --progress-bar -o "$iso_path" "${ISO_MIRROR}${ISO_FILENAME}"
        log "Downloaded: $iso_path"
    fi

    # Verify checksum
    local sha_file="$ISO_CACHE/sha256sums.txt"
    curl -sL -o "$sha_file" "${ISO_MIRROR}sha256sums.txt"
    if grep -q "$ISO_FILENAME" "$sha_file"; then
        cd "$ISO_CACHE"
        if sha256sum -c <(grep "$ISO_FILENAME" "$sha_file") 2>/dev/null; then
            log "SHA256 checksum verified"
        else
            err "Checksum mismatch! Re-download the ISO."
            rm -f "$iso_path"
            exit 1
        fi
        cd "$SCRIPT_DIR"
    else
        warn "Could not verify checksum (file not in sha256sums.txt)"
    fi

    echo "$iso_path"
}

# ─── Customize ISO ───────────────────────────────────────────────────────────

customize_iso() {
    local source_iso="$1"
    local output_iso="$2"

    step "Customizing ISO"
    info "This requires root privileges to modify the ISO filesystem"
    echo ""

    # Create working directories
    local work="$WORK_DIR/$TIMESTAMP"
    mkdir -p "$work"/{iso_mount,iso_extract,squashfs_mount,squashfs_extract,new_iso}

    # Mount the source ISO
    info "Extracting ISO..."
    sudo mount -o loop,ro "$source_iso" "$work/iso_mount"
    cp -a "$work/iso_mount/"* "$work/new_iso/"
    sudo umount "$work/iso_mount"

    # Find and extract the squashfs
    local squashfs_path="$work/new_iso/arch/x86_64/airootfs.sfs"
    if [[ ! -f "$squashfs_path" ]]; then
        err "airootfs.sfs not found in ISO"
        exit 1
    fi

    info "Extracting root filesystem..."
    sudo unsquashfs -d "$work/squashfs_extract" "$squashfs_path"

    # Create the autoinstall directory inside the squashfs
    local install_dir="$work/squashfs_extract/root/arch-autoinstall"
    sudo mkdir -p "$install_dir"/{config,scripts}

    # Copy configuration
    local config_stage="$work/config_stage"
    mkdir -p "$config_stage"
    generate_archinstall_config "$config_stage"
    sudo cp -r "$config_stage/"* "$install_dir/config/"

    # Copy scripts
    for script in enable_hibernate_swapfile.sh setup-secureboot.sh setup-tpm-unlock.sh; do
        if [[ -f "$SCRIPT_DIR/scripts/$script" ]]; then
            sudo cp "$SCRIPT_DIR/scripts/$script" "$install_dir/scripts/"
        fi
    done

    # Generate and copy post-install and autorun
    generate_post_install "$work/post-install.sh"
    sudo cp "$work/post-install.sh" "$install_dir/"

    generate_autorun "$work/autorun.sh" "$install_dir/config"
    sudo cp "$work/autorun.sh" "$install_dir/"

    # Add auto-start hook to run on boot
    sudo mkdir -p "$work/squashfs_extract/etc/profile.d"
    sudo tee "$work/squashfs_extract/etc/profile.d/99-autoinstall.sh" > /dev/null << 'HOOKEOF'
#!/bin/bash
# Auto-launch installer on first login — Go Beavs! 🦫
if [[ -f /root/arch-autoinstall/autorun.sh && ! -f /tmp/.autoinstall-started ]]; then
    touch /tmp/.autoinstall-started
    echo ""
    echo -e "\033[48;2;204;60;9m\033[38;2;255;255;255m\033[1m                                              \033[0m"
    echo -e "\033[48;2;204;60;9m\033[38;2;255;255;255m\033[1m   Arch Autoinstaller — OSUOSL  Go Beavs! 🦫  \033[0m"
    echo -e "\033[48;2;204;60;9m\033[38;2;255;255;255m\033[1m                                              \033[0m"
    echo ""
    read -rp "Start automated installation? [Y/n] " -n1; echo
    if [[ ${REPLY,,} != n ]]; then
        bash /root/arch-autoinstall/autorun.sh
    else
        echo "Skipped. Run manually: bash /root/arch-autoinstall/autorun.sh"
    fi
fi
HOOKEOF
    sudo chmod +x "$work/squashfs_extract/etc/profile.d/99-autoinstall.sh"

    # Repack squashfs
    info "Repacking root filesystem..."
    sudo rm -f "$squashfs_path"
    sudo mksquashfs "$work/squashfs_extract" "$squashfs_path" -comp zstd -Xcompression-level 15

    # Regenerate checksum
    local sfs_size
    sfs_size="$(stat -c %s "$squashfs_path")"
    sudo sha256sum "$squashfs_path" | awk '{print $1}' | sudo tee "$work/new_iso/arch/x86_64/airootfs.sha256" > /dev/null

    # Build new ISO
    info "Building custom ISO..."
    mkdir -p "$OUTPUT_DIR"

    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ARCH_AUTOINSTALL" \
        -eltorito-boot syslinux/isolinux.bin \
        -eltorito-catalog syslinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "$work/new_iso/syslinux/isohdpfx.bin" \
        -eltorito-alt-boot \
        -e EFI/archiso/efiboot.img \
        -no-emul-boot -isohybrid-gpt-basdat \
        -output "$output_iso" \
        "$work/new_iso" 2>/dev/null

    log "Custom ISO created: $output_iso"

    # Cleanup
    sudo rm -rf "$work"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

check_deps

show_banner

if $USE_PREFERRED; then
    apply_preferred
    info "Using preferred configuration"
else
    run_tui
fi

# Show final review
show_review

# Confirm build
echo ""
read -rp "Build custom ISO with this configuration? [Y/n] " -n1; echo
if [[ ${REPLY,,} == n ]]; then
    info "Cancelled."
    exit 0
fi

# Download ISO
if $SKIP_DOWNLOAD; then
    # Find cached ISO
    ISO_PATH="$(ls -t "$ISO_CACHE"/archlinux-*.iso 2>/dev/null | head -1)"
    if [[ -z "$ISO_PATH" ]]; then
        err "No cached ISO found. Run without --no-download."
        exit 1
    fi
    log "Using cached ISO: $ISO_PATH"
else
    ISO_PATH="$(download_iso)"
fi

# Set output path
if [[ -z "$OUTPUT_ISO" ]]; then
    OUTPUT_ISO="$OUTPUT_DIR/arch-autoinstall-${TIMESTAMP}.iso"
fi

# Build customized ISO
customize_iso "$ISO_PATH" "$OUTPUT_ISO"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${GREEN}${BOLD}║           ISO Build Complete!                        ║${RST}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════╣${RST}"
echo -e "${GREEN}${BOLD}║                                                      ║${RST}"
echo -e "║  Output: ${CYAN}${OUTPUT_ISO}${RST}"
echo -e "║  Size:   ${CYAN}$(du -h "$OUTPUT_ISO" | cut -f1)${RST}"
echo -e "${GREEN}${BOLD}║                                                      ║${RST}"
echo -e "║  ${YELLOW}Flash to USB:${RST}"
echo -e "║    sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo -e "║    ${DIM}(replace /dev/sdX with your USB drive)${RST}"
echo -e "${GREEN}${BOLD}║                                                      ║${RST}"
echo -e "${GREEN}${BOLD}║  ISO provided by OSUOSL — osuosl.org/donate          ║${RST}"
echo -e "${GREEN}${BOLD}║                    Go Beavs! 🦫                       ║${RST}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RST}"
echo ""
