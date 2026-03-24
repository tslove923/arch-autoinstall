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
# Usage:  ./build-iso.sh [--preferred] [--config <path>] [--creds <path>]
#
# Flags:
#   --preferred    Skip TUI, use preferred configuration
#   --config PATH  Load config from JSON (skip TUI for settings)
#   --creds PATH   Load credentials from JSON (plaintext or .gpg)
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
USER_PASSWORD=""       # set in TUI, or prompted during install
LUKS_PASSWORD=""       # set in TUI, or prompted during install
TIMEZONE_CFG="US/Pacific"
LOCALE_CFG="en_US"
KB_LAYOUT_CFG="us"
GFX_DRIVERS=("Intel (open-source)")   # array of selected GPU drivers
USE_PREFERRED=false
SKIP_DOWNLOAD=false
OUTPUT_ISO=""
LOAD_CONFIG=""        # --config <path>
LOAD_CREDS=""         # --creds <path>

# Sleep / Power management
SUSPEND_MODE="deep"              # deep (S3) or s2idle (S0ix)
SLEEP_ACTION="suspend-then-hibernate"  # suspend | hibernate | suspend-then-hibernate | hybrid-sleep
HIBERNATE_DELAY="120min"         # for suspend-then-hibernate: time before hibernate
LID_ACTION="suspend-then-hibernate"    # suspend | hibernate | suspend-then-hibernate | lock | ignore
IDLE_ACTION="suspend-then-hibernate"   # suspend | hibernate | suspend-then-hibernate | ignore
IDLE_TIMEOUT_SEC=900             # seconds before idle action (15 min default)
ENABLE_HIBERNATE_GUARD=true      # hibernate-guard disk-space watchdog

# WiFi
WIFI_SSID=""                     # pre-configure WiFi SSID
WIFI_PASSWORD=""                 # WiFi password (WPA)
ENABLE_WIFI=false                # embed WiFi config in ISO

# Offline installer
OFFLINE_MODE=false               # bundle all packages in ISO (no internet needed)

# Desktop: omarchy
ENABLE_OMARCHY=false             # omarchy Hyprland rice (alternative to ii)

# Optional packages
INSTALL_YAY=true                 # install yay AUR helper
EXTRA_PACKAGES=""               # space-separated extra pacman packages
AUR_PACKAGES=""                 # space-separated AUR packages (requires yay)

# ─── illogical-impulse feature catalog ─────────────────────────────────────────
# Mirrors the catalog in dots-hyprland-dev/apply-features.sh
II_FEATURE_BRANCHES=(
    "fix/wifi-reconnect-after-password"
    "feature/mpris-active-player-fix-main"
    "feature/copilot-integration"
    "feature/custom-configs"
    "feature/us-clock-view-worldclocks"
    "feature/homeassistant-integration"
    "feature/gpu-npu-monitoring"
    "feature/vpn-indicator"
)
II_FEATURE_LABELS=(
    "WiFi Reconnect Fix"
    "MPRIS Active Player Fix"
    "Copilot Integration"
    "Custom Configs & Keybinds"
    "US Date & World Clocks"
    "Home Assistant Panel"
    "GPU/NPU Monitoring"
    "VPN Status Indicator"
)
II_FEATURE_DESCS=(
    "Auto-reconnect WiFi after entering saved password"
    "Fix media controls to target the active player"
    "GitHub Copilot AI panel in sidebar"
    "Custom keybinds, scripts, xwayland, Docker/VPN/proxy toggles"
    "US date format in sidebar + configurable world clocks"
    "Home Assistant smart home panel in bar"
    "Intel GPU + NPU utilization indicators in resource bar"
    "WireGuard/OpenVPN status icon with toggle in bar"
)
# Dependencies: index of required branch, or -1 for none
II_FEATURE_DEPS=( -1 -1 -1 -1 3 3 -1 -1 )
# Track selected features (1=on, 0=off) — all on by default
II_FEATURE_SELECTED=( 1 1 1 1 1 1 1 1 )

# ─── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preferred)   USE_PREFERRED=true ;;
        --no-download) SKIP_DOWNLOAD=true ;;
        --output)      shift; OUTPUT_ISO="$1" ;;
        --config)      shift; LOAD_CONFIG="$1" ;;
        --creds)       shift; LOAD_CREDS="$1" ;;
        -h|--help)
            sed -n '2,/^###/p' "$0" | head -n -1 | sed 's/^# \?//'
            exit 0
            ;;
    esac
    shift
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

# ─── Config JSON save/load ─────────────────────────────────────────────────────

# Build a JSON string from current config state (no credentials)
config_to_json() {
    local ii_sel_json="["
    local first=true
    for i in "${!II_FEATURE_SELECTED[@]}"; do
        $first || ii_sel_json+=","
        ii_sel_json+="${II_FEATURE_SELECTED[$i]}"
        first=false
    done
    ii_sel_json+="]"

    cat << CFGJSON
{
    "_comment": "arch-autoinstall config — generated $(date -Iseconds)",
    "enable_luks": $ENABLE_LUKS,
    "enable_hibernate": $ENABLE_HIBERNATE,
    "enable_tpm": $ENABLE_TPM,
    "enable_hyprland": $ENABLE_HYPRLAND,
    "enable_gnome": $ENABLE_GNOME,
    "enable_ii": $ENABLE_II,
    "enable_ii_features": $ENABLE_II_FEATURES,
    "ii_feature_selected": $ii_sel_json,
    "auto_disk": $AUTO_DISK,
    "hostname": "$HOSTNAME_CFG",
    "username": "$USERNAME_CFG",
    "timezone": "$TIMEZONE_CFG",
    "locale": "$LOCALE_CFG",
    "kb_layout": "$KB_LAYOUT_CFG",
    "gfx_drivers": "${GFX_DRIVERS[*]}",
    "suspend_mode": "$SUSPEND_MODE",
    "sleep_action": "$SLEEP_ACTION",
    "hibernate_delay": "$HIBERNATE_DELAY",
    "lid_action": "$LID_ACTION",
    "idle_action": "$IDLE_ACTION",
    "idle_timeout_sec": $IDLE_TIMEOUT_SEC,
    "enable_hibernate_guard": $ENABLE_HIBERNATE_GUARD,
    "enable_wifi": $ENABLE_WIFI,
    "wifi_ssid": "$WIFI_SSID",
    "offline_mode": $OFFLINE_MODE,
    "enable_omarchy": $ENABLE_OMARCHY,
    "install_yay": $INSTALL_YAY,
    "extra_packages": "$EXTRA_PACKAGES",
    "aur_packages": "$AUR_PACKAGES"
}
CFGJSON
}

save_config_json() {
    local path="$1"
    config_to_json > "$path"
    log "Config saved to: $path"
}

load_config_json() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        err "Config file not found: $path"
        exit 1
    fi
    info "Loading config from: $path"

    # Parse JSON with sed/grep — no jq dependency required
    _json_bool()  { grep -oP "\"$1\"\\s*:\\s*\\K(true|false)" "$path" | head -1; }
    _json_str()   { grep -oP "\"$1\"\\s*:\\s*\"\\K[^\"]*" "$path" | head -1; }
    _json_array() { grep -oP "\"$1\"\\s*:\\s*\\[\\K[^]]*" "$path" | head -1; }

    local v
    v="$(_json_bool enable_luks)";         [[ -n "$v" ]] && ENABLE_LUKS=$v
    v="$(_json_bool enable_hibernate)";    [[ -n "$v" ]] && ENABLE_HIBERNATE=$v
    v="$(_json_bool enable_tpm)";          [[ -n "$v" ]] && ENABLE_TPM=$v
    v="$(_json_bool enable_hyprland)";     [[ -n "$v" ]] && ENABLE_HYPRLAND=$v
    v="$(_json_bool enable_gnome)";        [[ -n "$v" ]] && ENABLE_GNOME=$v
    v="$(_json_bool enable_ii)";           [[ -n "$v" ]] && ENABLE_II=$v
    v="$(_json_bool enable_ii_features)";  [[ -n "$v" ]] && ENABLE_II_FEATURES=$v
    v="$(_json_str suspend_mode)";         [[ -n "$v" ]] && SUSPEND_MODE="$v"
    v="$(_json_str sleep_action)";         [[ -n "$v" ]] && SLEEP_ACTION="$v"
    v="$(_json_str hibernate_delay)";      [[ -n "$v" ]] && HIBERNATE_DELAY="$v"
    v="$(_json_str lid_action)";           [[ -n "$v" ]] && LID_ACTION="$v"
    v="$(_json_str idle_action)";          [[ -n "$v" ]] && IDLE_ACTION="$v"
    v="$(grep -oP '"idle_timeout_sec"\s*:\s*\K[0-9]+' "$path" | head -1)"
    [[ -n "$v" ]] && IDLE_TIMEOUT_SEC=$v
    v="$(_json_bool enable_hibernate_guard)"; [[ -n "$v" ]] && ENABLE_HIBERNATE_GUARD=$v
    v="$(_json_bool auto_disk)";           [[ -n "$v" ]] && AUTO_DISK=$v
    v="$(_json_str hostname)";             [[ -n "$v" ]] && HOSTNAME_CFG="$v"
    v="$(_json_str username)";             [[ -n "$v" ]] && USERNAME_CFG="$v"
    v="$(_json_str timezone)";             [[ -n "$v" ]] && TIMEZONE_CFG="$v"
    v="$(_json_str locale)";               [[ -n "$v" ]] && LOCALE_CFG="$v"
    v="$(_json_str kb_layout)";            [[ -n "$v" ]] && KB_LAYOUT_CFG="$v"
    v="$(_json_str gfx_drivers)";          [[ -n "$v" ]] && IFS=' ' read -ra GFX_DRIVERS <<< "$v"
    v="$(_json_bool enable_wifi)";         [[ -n "$v" ]] && ENABLE_WIFI=$v
    v="$(_json_str wifi_ssid)";            [[ -n "$v" ]] && WIFI_SSID="$v"
    v="$(_json_bool offline_mode)";        [[ -n "$v" ]] && OFFLINE_MODE=$v
    v="$(_json_bool enable_omarchy)";      [[ -n "$v" ]] && ENABLE_OMARCHY=$v
    v="$(_json_bool install_yay)";         [[ -n "$v" ]] && INSTALL_YAY=$v
    v="$(_json_str extra_packages)";       [[ -n "$v" ]] && EXTRA_PACKAGES="$v"
    v="$(_json_str aur_packages)";         [[ -n "$v" ]] && AUR_PACKAGES="$v"

    # Parse ii_feature_selected array: [1,0,1,1,...]
    v="$(_json_array ii_feature_selected)"
    if [[ -n "$v" ]]; then
        IFS=',' read -ra _sel <<< "$v"
        for i in "${!_sel[@]}"; do
            local s="${_sel[$i]// /}"  # trim spaces
            [[ "$s" =~ ^[01]$ ]] && II_FEATURE_SELECTED[$i]=$s
        done
    fi

    log "Config loaded"
}

# ─── Credentials JSON save/load ───────────────────────────────────────────────

# Build a JSON string with credentials
creds_to_json() {
    local esc_user esc_luks
    esc_user="$(printf '%s' "$USER_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    esc_luks="$(printf '%s' "$LUKS_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    cat << CREDJSON
{
    "_comment": "arch-autoinstall credentials — generated $(date -Iseconds)",
    "user_password": "$esc_user",
    "luks_password": "$esc_luks"
}
CREDJSON
}

save_credentials_json() {
    local path="$1"
    local mode="$2"   # "plain" or "gpg"

    if [[ "$mode" == "gpg" ]]; then
        if ! command -v gpg &>/dev/null; then
            err "gpg not found — install gnupg to use encrypted credentials"
            return 1
        fi
        creds_to_json | gpg --symmetric --cipher-algo AES256 --batch --yes -o "${path}.gpg"
        log "Encrypted credentials saved to: ${path}.gpg"
        info "Decrypt with: gpg -d ${path}.gpg"
    else
        creds_to_json > "$path"
        chmod 600 "$path"
        log "Credentials saved to: $path (plaintext, mode 600)"
        warn "This file contains passwords in cleartext!"
    fi
}

load_credentials_json() {
    local path="$1"
    local json_content

    if [[ "$path" == *.gpg ]]; then
        if ! command -v gpg &>/dev/null; then
            err "gpg not found — install gnupg to decrypt credentials"
            exit 1
        fi
        info "Decrypting credentials from: $path"
        json_content="$(gpg -d --batch "$path" 2>/dev/null)" || {
            err "Failed to decrypt $path"
            exit 1
        }
    elif [[ -f "$path" ]]; then
        json_content="$(cat "$path")"
    else
        err "Credentials file not found: $path"
        exit 1
    fi

    local v
    v="$(echo "$json_content" | grep -oP '"user_password"\s*:\s*"\K[^"]*' | head -1)"
    [[ -n "$v" ]] && USER_PASSWORD="$v"
    v="$(echo "$json_content" | grep -oP '"luks_password"\s*:\s*"\K[^"]*' | head -1)"
    [[ -n "$v" ]] && LUKS_PASSWORD="$v"

    log "Credentials loaded from: $path"
}

# TUI: prompt user to save credentials
prompt_save_credentials() {
    if [[ -z "$USER_PASSWORD" && -z "$LUKS_PASSWORD" ]]; then
        return 0  # nothing to save
    fi

    local result
    result="$(run_dialog \
        --title " Save Credentials " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nSave passwords for future builds?\n\nEncrypted uses GPG (AES-256 symmetric).\nPlaintext is chmod 600 but visible on disk.\n" \
        15 62 3 \
        1 "Don't save credentials" on \
        2 "Save as GPG-encrypted JSON (.gpg)" off \
        3 "Save as plaintext JSON (chmod 600)" off \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        2)
            local cred_path="${SCRIPT_DIR}/configs/credentials.json"
            save_credentials_json "$cred_path" "gpg"
            run_dialog --msgbox "Encrypted credentials saved to:\n\n  configs/credentials.json.gpg\n\nLoad with: ./build-iso.sh --creds configs/credentials.json.gpg" 10 60
            ;;
        3)
            local cred_path="${SCRIPT_DIR}/configs/credentials.json"
            save_credentials_json "$cred_path" "plain"
            run_dialog --msgbox "Plaintext credentials saved to:\n\n  configs/credentials.json\n\nLoad with: ./build-iso.sh --creds configs/credentials.json\n\n⚠ Contains passwords in cleartext!" 11 60
            ;;
    esac
}

# ─── dialog color theme ────────────────────────────────────────────────────────
# Black background, white text, orange (#cc3c09) accents.
# dialog only supports 8 named colors (BLACK RED GREEN YELLOW BLUE MAGENTA
# CYAN WHITE) mapped to ANSI colors 0-7.  Many modern terminal themes render
# ANSI 1 (RED) as purple/magenta instead of red.  To get true OSUOSL orange
# we use OSC 4 to temporarily remap ANSI color 1 to #cc3c09.
setup_dialog_colors() {
    # Remap ANSI color 1 ("RED") → OSUOSL orange (#cc3c09)
    # shellcheck disable=SC1003
    printf '\033]4;1;rgb:cc/3c/09\033\\'

    # Restore original ANSI red on exit / interrupt
    trap 'printf '"'"'\033]4;1;rgb:cc/00/00\033\\'"'"'' EXIT

    export DIALOGRC="$(mktemp)"
    cat > "$DIALOGRC" << 'DLGEOF'
# Arch Autoinstall — Black + White + Orange theme
use_shadow = OFF
use_colors = ON
screen_color = (WHITE,BLACK,ON)
title_color = (WHITE,BLACK,ON)
border_color = (WHITE,BLACK,ON)
border2_color = (RED,BLACK,ON)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (WHITE,BLACK,OFF)
button_active_color = (WHITE,RED,ON)
button_inactive_color = (BLACK,WHITE,OFF)
button_key_inactive_color = (RED,WHITE,OFF)
button_key_active_color = (WHITE,RED,ON)
button_label_active_color = (WHITE,RED,ON)
button_label_inactive_color = (BLACK,WHITE,ON)
form_active_text_color = (WHITE,RED,ON)
form_text_color = (WHITE,BLACK,OFF)
form_item_readonly_color = (CYAN,BLACK,ON)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (WHITE,BLACK,ON)
inputbox_border2_color = (RED,BLACK,ON)
searchbox_color = (WHITE,BLACK,OFF)
searchbox_title_color = (WHITE,BLACK,ON)
searchbox_border_color = (WHITE,BLACK,ON)
searchbox_border2_color = (RED,BLACK,ON)
position_indicator_color = (RED,BLACK,ON)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (WHITE,BLACK,ON)
menubox_border2_color = (RED,BLACK,ON)
item_color = (WHITE,BLACK,OFF)
item_selected_color = (WHITE,RED,ON)
tag_color = (RED,BLACK,ON)
tag_selected_color = (WHITE,RED,ON)
tag_key_color = (RED,BLACK,ON)
tag_key_selected_color = (WHITE,RED,ON)
check_color = (WHITE,BLACK,OFF)
check_selected_color = (WHITE,RED,ON)
uarrow_color = (RED,BLACK,ON)
darrow_color = (RED,BLACK,ON)
itemhelp_color = (WHITE,BLACK,OFF)
gauge_color = (WHITE,RED,ON)
DLGEOF
}

# ─── Terminal footer ───────────────────────────────────────────────────────────
# Paint "osuosl.org/donate — Go Beavs! 🦫" on the last line, right-justified.
# Called before every dialog invocation so it persists across redraws.
paint_footer() {
    local msg="osuosl.org/donate — Go Beavs! 🦫"
    local cols rows
    cols="$(tput cols 2>/dev/null || echo 80)"
    rows="$(tput lines 2>/dev/null || echo 24)"
    local pad=$(( cols - ${#msg} - 1 ))
    (( pad < 0 )) && pad=0
    # Save cursor, move to last row, print right-justified, restore cursor
    tput sc
    tput cup $(( rows - 1 )) "$pad"
    printf '\033[38;5;208m%s\033[0m' "$msg"    # orange
    tput rc
}

# Wrapper: paint footer then exec dialog
run_dialog() {
    paint_footer
    dialog "$@"
}

# ─── TUI Functions ─────────────────────────────────────────────────────────────

show_main_menu() {
    local ii_count=0 ii_total=${#II_FEATURE_BRANCHES[@]}
    for s in "${II_FEATURE_SELECTED[@]}"; do (( s )) && (( ii_count++ )); done
    local ii_summary="off"
    $ENABLE_II_FEATURES && ii_summary="${ii_count}/${ii_total} features"
    $ENABLE_II && [[ $ENABLE_II_FEATURES == false ]] && ii_summary="base only"

    local result
    result="$(run_dialog \
        --title " Main Menu " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --begin 2 3 \
        --ok-label "Select" \
        --cancel-label "Build ISO" \
        --menu "\nConfigure your Arch Linux installation.\nSelect an option to modify, or press Build ISO when ready.\n" \
        28 74 17 \
        "P" "★ Use Preferred Setup (recommended)" \
        "1" "Security: LUKS / Hibernate / TPM  [$(security_summary)]" \
        "2" "Desktop: Hyprland / GNOME / ii / omarchy  [$(desktop_summary)]" \
        "3" "illogical-impulse features  [$ii_summary]" \
        "4" "Disk: Target disk selection" \
        "5" "System: Hostname, user, locale, timezone" \
        "6" "Graphics: GPU driver selection" \
        "7" "Passwords: User & LUKS encryption  [$(password_summary)]" \
        "8" "Sleep & Power: suspend / hibernate / hybrid  [$(sleep_summary)]" \
        "9" "WiFi: pre-configure wireless  [$(wifi_summary)]" \
        "A" "Packages: yay, extra pacman & AUR  [$(packages_summary)]" \
        "O" "Offline installer  [$($OFFLINE_MODE && echo ON || echo off)]" \
        "S" "Save / Load config" \
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
    result="$(run_dialog \
        --title " Security Options " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
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
        run_dialog --msgbox "LUKS auto-enabled (required for hibernate resume device detection)." 7 55
    fi
    if $ENABLE_TPM && ! $ENABLE_LUKS; then
        ENABLE_LUKS=true
        run_dialog --msgbox "LUKS auto-enabled (required for TPM auto-unlock)." 7 55
    fi
}

configure_desktop() {
    local -a args=()
    args+=(1 "Hyprland (tiling Wayland compositor)" "$($ENABLE_HYPRLAND && echo on || echo off)")
    args+=(2 "GNOME (full desktop environment)" "$($ENABLE_GNOME && echo on || echo off)")

    local result
    result="$(run_dialog \
        --title " Desktop Environment " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
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

    # If Hyprland selected, offer rice options
    if $ENABLE_HYPRLAND; then
        configure_hyprland_rice
    else
        ENABLE_II=false
        ENABLE_II_FEATURES=false
        ENABLE_OMARCHY=false
    fi
}

configure_hyprland_rice() {
    local result
    result="$(run_dialog \
        --title " Hyprland Customization " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nSelect Hyprland rice level:\n" \
        16 70 4 \
        1 "Vanilla Hyprland (no rice)" "$([[ $ENABLE_II == false && $ENABLE_OMARCHY == false ]] && echo on || echo off)" \
        2 "illogical-impulse (end-4 rice)" "$([[ $ENABLE_II == true && $ENABLE_II_FEATURES == false ]] && echo on || echo off)" \
        3 "illogical-impulse + custom features (recommended)" "$($ENABLE_II_FEATURES && echo on || echo off)" \
        4 "omarchy (omakub-inspired Hyprland rice)" "$($ENABLE_OMARCHY && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        1) ENABLE_II=false; ENABLE_II_FEATURES=false; ENABLE_OMARCHY=false ;;
        2) ENABLE_II=true;  ENABLE_II_FEATURES=false; ENABLE_OMARCHY=false ;;
        3) ENABLE_II=true;  ENABLE_II_FEATURES=true;  ENABLE_OMARCHY=false
           configure_ii_features
           ;;
        4) ENABLE_II=false; ENABLE_II_FEATURES=false; ENABLE_OMARCHY=true ;;
    esac
}

configure_ii_features() {
    if ! $ENABLE_II || ! $ENABLE_II_FEATURES; then
        run_dialog \
            --title " illogical-impulse Features " \
            --backtitle "Arch Linux Autoinstaller Configuration" \
            --msgbox "\nillogical-impulse + custom features must be enabled first.\nGo to Desktop → Hyprland Customization and select option 3." 9 62
        return 0
    fi

    # Build checklist from the feature catalog
    local -a args=()
    local i
    for i in "${!II_FEATURE_BRANCHES[@]}"; do
        local dep=${II_FEATURE_DEPS[$i]}
        local dep_note=""
        if (( dep >= 0 )); then
            dep_note=" [requires: ${II_FEATURE_LABELS[$dep]}]"
        fi
        local state="off"
        (( II_FEATURE_SELECTED[i] )) && state="on"
        args+=( "$i" "${II_FEATURE_LABELS[$i]}  —  ${II_FEATURE_DESCS[$i]}${dep_note}" "$state" )
    done

    local result
    result="$(run_dialog \
        --title " illogical-impulse Feature Picker " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --checklist "\nSelect which custom feature branches to include.\nDependencies will be auto-enabled.\n" \
        22 78 ${#II_FEATURE_BRANCHES[@]} \
        "${args[@]}" \
        3>&1 1>&2 2>&3)" || return 0

    # Reset all to 0, then enable selected
    for i in "${!II_FEATURE_SELECTED[@]}"; do
        II_FEATURE_SELECTED[$i]=0
    done
    for item in $result; do
        item="${item//\"/}"
        II_FEATURE_SELECTED[$item]=1
    done

    # Auto-enable dependencies
    local changed=true
    while $changed; do
        changed=false
        for i in "${!II_FEATURE_SELECTED[@]}"; do
            if (( II_FEATURE_SELECTED[i] )); then
                local dep=${II_FEATURE_DEPS[$i]}
                if (( dep >= 0 )) && (( ! II_FEATURE_SELECTED[dep] )); then
                    II_FEATURE_SELECTED[$dep]=1
                    changed=true
                fi
            fi
        done
    done

    # Show what was auto-enabled
    local auto_msg=""
    for i in "${!II_FEATURE_SELECTED[@]}"; do
        if (( II_FEATURE_SELECTED[i] )); then
            local was_in_result=false
            for item in $result; do
                item="${item//\"/}"
                [[ "$item" == "$i" ]] && was_in_result=true
            done
            if ! $was_in_result; then
                auto_msg+="\n  • ${II_FEATURE_LABELS[$i]} (dependency)"
            fi
        fi
    done
    if [[ -n "$auto_msg" ]]; then
        run_dialog \
            --title " Auto-enabled Dependencies " \
            --backtitle "Arch Linux Autoinstaller Configuration" \
            --msgbox "\nThe following features were auto-enabled as dependencies:${auto_msg}" 12 60
    fi
}

configure_disk() {
    local result
    result="$(run_dialog \
        --title " Disk Selection " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
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
    result="$(run_dialog \
        --title " System Configuration " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
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

_gfx_is_selected() { local d; for d in "${GFX_DRIVERS[@]}"; do [[ "$d" == "$1" ]] && return 0; done; return 1; }

configure_graphics() {
    local result
    result="$(run_dialog \
        --title " Graphics Drivers " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --checklist "\nSelect one or more GPU drivers (space to toggle):\n" \
        16 60 5 \
        1 "Intel (open-source)"           "$(_gfx_is_selected 'Intel (open-source)' && echo on || echo off)" \
        2 "Nvidia (proprietary)"          "$(_gfx_is_selected 'Nvidia (proprietary)' && echo on || echo off)" \
        3 "Nvidia (open-source nouveau)"  "$(_gfx_is_selected 'Nvidia (open-source nouveau)' && echo on || echo off)" \
        4 "AMD / ATI (open-source)"       "$(_gfx_is_selected 'AMD / ATI (open-source)' && echo on || echo off)" \
        5 "VMware / VirtualBox"           "$(_gfx_is_selected 'VMware / VirtualBox (open-source)' && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    GFX_DRIVERS=()
    for tag in $result; do
        case "$tag" in
            1) GFX_DRIVERS+=("Intel (open-source)") ;;
            2) GFX_DRIVERS+=("Nvidia (proprietary)") ;;
            3) GFX_DRIVERS+=("Nvidia (open-source nouveau)") ;;
            4) GFX_DRIVERS+=("AMD / ATI (open-source)") ;;
            5) GFX_DRIVERS+=("VMware / VirtualBox (open-source)") ;;
        esac
    done
    [[ ${#GFX_DRIVERS[@]} -eq 0 ]] && GFX_DRIVERS=("Intel (open-source)")
}

password_summary() {
    local parts=()
    [[ -n "$USER_PASSWORD" ]] && parts+=("user:set") || parts+=("user:prompt")
    if $ENABLE_LUKS; then
        [[ -n "$LUKS_PASSWORD" ]] && parts+=("LUKS:set") || parts+=("LUKS:prompt")
    fi
    echo "${parts[*]}"
}

configure_passwords() {
    # ── User password ──
    local pw1 pw2
    pw1="$(run_dialog \
        --title " User Password " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --insecure \
        --passwordbox "\nEnter password for user '${USERNAME_CFG:-<username>}'.\nLeave blank to be prompted during install.\n" \
        10 55 \
        3>&1 1>&2 2>&3)" || return 0

    if [[ -n "$pw1" ]]; then
        pw2="$(run_dialog \
            --title " Confirm User Password " \
            --backtitle "Arch Linux Autoinstaller Configuration" \
            --insecure \
            --passwordbox "\nConfirm password:" \
            9 55 \
            3>&1 1>&2 2>&3)" || return 0

        if [[ "$pw1" != "$pw2" ]]; then
            dialog --title " Error " --msgbox "\nPasswords do not match. Try again." 7 45
            return 0
        fi
        USER_PASSWORD="$pw1"
        dialog --title " ✓ " --msgbox "\nUser password set." 7 30
    else
        USER_PASSWORD=""
        dialog --title " Info " --msgbox "\nUser password cleared.\nYou will be prompted during install." 8 48
    fi

    # ── LUKS encryption password ──
    if $ENABLE_LUKS; then
        pw1="$(run_dialog \
            --title " LUKS Encryption Password " \
            --backtitle "Arch Linux Autoinstaller Configuration" \
            --insecure \
            --passwordbox "\nEnter disk encryption (LUKS) password.\nLeave blank to be prompted during install.\n\nThis is the password you type at every boot\n(until TPM auto-unlock is configured).\n" \
            13 58 \
            3>&1 1>&2 2>&3)" || return 0

        if [[ -n "$pw1" ]]; then
            pw2="$(run_dialog \
                --title " Confirm LUKS Password " \
                --backtitle "Arch Linux Autoinstaller Configuration" \
                --insecure \
                --passwordbox "\nConfirm LUKS password:" \
                9 55 \
                3>&1 1>&2 2>&3)" || return 0

            if [[ "$pw1" != "$pw2" ]]; then
                dialog --title " Error " --msgbox "\nPasswords do not match. Try again." 7 45
                return 0
            fi
            LUKS_PASSWORD="$pw1"
            dialog --title " ✓ " --msgbox "\nLUKS encryption password set." 7 38
        else
            LUKS_PASSWORD=""
            dialog --title " Info " --msgbox "\nLUKS password cleared.\nYou will be prompted during install." 8 48
        fi
    fi
}

sleep_summary() {
    local parts=()
    parts+=("$SLEEP_ACTION")
    [[ "$SLEEP_ACTION" == "suspend-then-hibernate" ]] && parts+=("${HIBERNATE_DELAY}")
    $ENABLE_HIBERNATE_GUARD && parts+=("guard")
    echo "${parts[*]}"
}

configure_sleep() {
    if ! $ENABLE_HIBERNATE; then
        run_dialog \
            --title " Sleep & Power " \
            --backtitle "Arch Linux Autoinstaller Configuration" \
            --msgbox "\nHibernate is disabled in Security settings.\n\nEnable it first (menu item 1) to configure\nsuspend-then-hibernate and hybrid-sleep." 10 58
        return 0
    fi

    local result
    result="$(run_dialog \
        --title " Sleep & Power Configuration " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --menu "\nConfigure sleep, hibernate, and power behavior.\n" \
        20 68 7 \
        1 "Sleep action: $SLEEP_ACTION" \
        2 "Suspend mode: $SUSPEND_MODE" \
        3 "Hibernate delay: $HIBERNATE_DELAY  (suspend-then-hibernate)" \
        4 "Lid close action: $LID_ACTION" \
        5 "Idle action: $IDLE_ACTION" \
        6 "Idle timeout: ${IDLE_TIMEOUT_SEC}s  ($(( IDLE_TIMEOUT_SEC / 60 )) min)" \
        7 "Hibernate guard (disk space watchdog): $($ENABLE_HIBERNATE_GUARD && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        1) _configure_sleep_action ;;
        2) _configure_suspend_mode ;;
        3) _configure_hibernate_delay ;;
        4) _configure_lid_action ;;
        5) _configure_idle_action ;;
        6) _configure_idle_timeout ;;
        7) ENABLE_HIBERNATE_GUARD=$(! $ENABLE_HIBERNATE_GUARD && echo true || echo false)
           local state_str="enabled"; $ENABLE_HIBERNATE_GUARD && state_str="enabled" || state_str="disabled"
           dialog --title " Hibernate Guard " --msgbox "\nHibernate guard watchdog: ${state_str}\n\nWhen enabled, a systemd timer checks disk/swap usage\nevery 5 min and disables hibernate if space is too low." 10 62
           ;;
    esac
}

_configure_sleep_action() {
    local result
    result="$(run_dialog \
        --title " Sleep Action " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nDefault action when the system sleeps (e.g. power button):\n" \
        16 68 4 \
        "suspend"                   "Suspend to RAM (fast resume, uses battery)"             "$([[ "$SLEEP_ACTION" == "suspend" ]] && echo on || echo off)" \
        "hibernate"                 "Hibernate to disk (slow, zero power use)"               "$([[ "$SLEEP_ACTION" == "hibernate" ]] && echo on || echo off)" \
        "suspend-then-hibernate"    "Suspend first, hibernate after delay (recommended)"     "$([[ "$SLEEP_ACTION" == "suspend-then-hibernate" ]] && echo on || echo off)" \
        "hybrid-sleep"              "Suspend + hibernate simultaneously (safest)"            "$([[ "$SLEEP_ACTION" == "hybrid-sleep" ]] && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0
    result="${result//\"/}"
    [[ -n "$result" ]] && SLEEP_ACTION="$result"
}

_configure_suspend_mode() {
    local result
    result="$(run_dialog \
        --title " Suspend Mode " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nHardware suspend mode (mem_sleep):\n" \
        12 68 2 \
        "deep"    "S3 — traditional suspend (lower power, most compatible)"      "$([[ "$SUSPEND_MODE" == "deep" ]] && echo on || echo off)" \
        "s2idle"  "S0ix — modern standby (faster wake, Intel recommended)"       "$([[ "$SUSPEND_MODE" == "s2idle" ]] && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0
    result="${result//\"/}"
    [[ -n "$result" ]] && SUSPEND_MODE="$result"
}

_configure_hibernate_delay() {
    local result
    result="$(run_dialog \
        --title " Hibernate Delay " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nTime in suspend before hibernating (suspend-then-hibernate):\n" \
        16 68 5 \
        "30min"   "30 minutes"    "$([[ "$HIBERNATE_DELAY" == "30min" ]] && echo on || echo off)" \
        "60min"   "1 hour"        "$([[ "$HIBERNATE_DELAY" == "60min" ]] && echo on || echo off)" \
        "120min"  "2 hours (recommended)"  "$([[ "$HIBERNATE_DELAY" == "120min" ]] && echo on || echo off)" \
        "240min"  "4 hours"       "$([[ "$HIBERNATE_DELAY" == "240min" ]] && echo on || echo off)" \
        "480min"  "8 hours"       "$([[ "$HIBERNATE_DELAY" == "480min" ]] && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0
    result="${result//\"/}"
    [[ -n "$result" ]] && HIBERNATE_DELAY="$result"
}

_configure_lid_action() {
    local result
    result="$(run_dialog \
        --title " Lid Close Action " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nAction when the laptop lid is closed:\n" \
        16 68 5 \
        "suspend"                   "Suspend to RAM"                                  "$([[ "$LID_ACTION" == "suspend" ]] && echo on || echo off)" \
        "hibernate"                 "Hibernate to disk"                               "$([[ "$LID_ACTION" == "hibernate" ]] && echo on || echo off)" \
        "suspend-then-hibernate"    "Suspend, then hibernate after delay"             "$([[ "$LID_ACTION" == "suspend-then-hibernate" ]] && echo on || echo off)" \
        "lock"                      "Lock screen only"                                "$([[ "$LID_ACTION" == "lock" ]] && echo on || echo off)" \
        "ignore"                    "Do nothing"                                      "$([[ "$LID_ACTION" == "ignore" ]] && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0
    result="${result//\"/}"
    [[ -n "$result" ]] && LID_ACTION="$result"
}

_configure_idle_action() {
    local result
    result="$(run_dialog \
        --title " Idle Action " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nAction after system is idle for the configured timeout:\n" \
        14 68 4 \
        "suspend"                   "Suspend to RAM"                                  "$([[ "$IDLE_ACTION" == "suspend" ]] && echo on || echo off)" \
        "hibernate"                 "Hibernate to disk"                               "$([[ "$IDLE_ACTION" == "hibernate" ]] && echo on || echo off)" \
        "suspend-then-hibernate"    "Suspend, then hibernate after delay"             "$([[ "$IDLE_ACTION" == "suspend-then-hibernate" ]] && echo on || echo off)" \
        "ignore"                    "Do nothing"                                      "$([[ "$IDLE_ACTION" == "ignore" ]] && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0
    result="${result//\"/}"
    [[ -n "$result" ]] && IDLE_ACTION="$result"
}

_configure_idle_timeout() {
    local result
    result="$(run_dialog \
        --title " Idle Timeout " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nTime of inactivity before idle action triggers:\n" \
        16 68 5 \
        "300"   " 5 minutes"   "$([[ "$IDLE_TIMEOUT_SEC" == "300" ]]  && echo on || echo off)" \
        "600"   "10 minutes"   "$([[ "$IDLE_TIMEOUT_SEC" == "600" ]]  && echo on || echo off)" \
        "900"   "15 minutes (recommended)"  "$([[ "$IDLE_TIMEOUT_SEC" == "900" ]]  && echo on || echo off)" \
        "1800"  "30 minutes"   "$([[ "$IDLE_TIMEOUT_SEC" == "1800" ]] && echo on || echo off)" \
        "3600"  "60 minutes"   "$([[ "$IDLE_TIMEOUT_SEC" == "3600" ]] && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0
    result="${result//\"/}"
    [[ -n "$result" ]] && IDLE_TIMEOUT_SEC="$result"
}

desktop_summary() {
    local parts=()
    $ENABLE_HYPRLAND && parts+=("Hyprland")
    $ENABLE_GNOME && parts+=("GNOME")
    $ENABLE_II && parts+=("ii")
    $ENABLE_OMARCHY && parts+=("omarchy")
    [[ ${#parts[@]} -eq 0 ]] && echo "(none)" && return
    echo "${parts[*]}"
}

wifi_summary() {
    if $ENABLE_WIFI && [[ -n "$WIFI_SSID" ]]; then
        echo "$WIFI_SSID"
    elif $ENABLE_WIFI; then
        echo "on (no SSID)"
    else
        echo "off"
    fi
}

packages_summary() {
    local parts=()
    $INSTALL_YAY && parts+=("yay")
    [[ -n "$EXTRA_PACKAGES" ]] && parts+=("pkg")
    [[ -n "$AUR_PACKAGES" ]] && parts+=("aur")
    [[ ${#parts[@]} -eq 0 ]] && echo "defaults" && return
    echo "${parts[*]}"
}

# ─── WiFi Configuration ───────────────────────────────────────────────────────

configure_wifi() {
    # Auto-detect current WiFi SSID as default
    local current_ssid=""
    if command -v nmcli &>/dev/null; then
        current_ssid="$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d: -f2 | head -1)"
    elif command -v iwctl &>/dev/null; then
        current_ssid="$(iwctl station wlan0 show 2>/dev/null | awk '/Connected network/{print $NF}')"
    fi

    # Toggle WiFi on/off with spacebar
    local result
    result="$(run_dialog \
        --title " WiFi Configuration " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --checklist "\nToggle WiFi pre-configuration (space to toggle).\nSSID auto-detected from current connection.\n" \
        11 65 1 \
        1 "Enable WiFi on installed system" "$($ENABLE_WIFI && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    if [[ "$result" == *"1"* ]]; then
        ENABLE_WIFI=true
    else
        ENABLE_WIFI=false
        return 0
    fi

    # If enabled, prompt for SSID and password
    result="$(run_dialog \
        --title " WiFi Details " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --form "\nEnter WiFi credentials:\n" \
        12 65 2 \
        "SSID:"     1 1 "${WIFI_SSID:-$current_ssid}" 1 12 45 64 \
        "Password:" 2 1 "$WIFI_PASSWORD"               2 12 45 64 \
        3>&1 1>&2 2>&3)" || return 0

    local -a vals
    mapfile -t vals <<< "$result"
    [[ -n "${vals[0]:-}" ]] && WIFI_SSID="${vals[0]}"
    [[ -n "${vals[1]:-}" ]] && WIFI_PASSWORD="${vals[1]}"

    if $ENABLE_WIFI && [[ -z "$WIFI_SSID" ]]; then
        run_dialog --msgbox "\n⚠ WiFi enabled but no SSID set.\nThe installer will attempt DHCP on ethernet." 8 55
    fi
}

# ─── Offline Installer ────────────────────────────────────────────────────────

configure_offline() {
    local result
    result="$(run_dialog \
        --title " Offline Installer " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --radiolist "\nBundle all packages into the ISO for offline installation.\nThis increases ISO size significantly (~2-4 GB).\n" \
        13 68 2 \
        1 "Online install (download packages during install)"  "$(! $OFFLINE_MODE && echo on || echo off)" \
        2 "Offline install (all packages bundled in ISO)"      "$($OFFLINE_MODE && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        1) OFFLINE_MODE=false ;;
        2) OFFLINE_MODE=true
           run_dialog --msgbox "\nOffline mode enabled.\n\nThe ISO will be significantly larger.\nAll selected packages will be pre-downloaded\nand bundled into the squashfs image." 10 58
           ;;
    esac
}

# ─── Packages Configuration ───────────────────────────────────────────────────

configure_packages() {
    # Toggle yay on/off with spacebar
    local result
    result="$(run_dialog \
        --title " Package Configuration " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --checklist "\nToggle yay AUR helper (space to toggle).\nyay enables installing packages from the AUR.\n" \
        11 65 1 \
        1 "Install yay (AUR helper)" "$($INSTALL_YAY && echo on || echo off)" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    [[ "$result" == *"1"* ]] && INSTALL_YAY=true || INSTALL_YAY=false

    # Additional packages form
    result="$(run_dialog \
        --title " Additional Packages " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --form "\nSpace-separated package names.\nAUR packages require yay (auto-enabled if needed).\n" \
        14 72 2 \
        "Extra pacman pkgs:" 1 1 "$EXTRA_PACKAGES" 1 22 45 256 \
        "AUR packages:"      2 1 "$AUR_PACKAGES"   2 22 45 256 \
        3>&1 1>&2 2>&3)" || return 0

    local -a vals
    mapfile -t vals <<< "$result"
    EXTRA_PACKAGES="${vals[0]:-}"
    AUR_PACKAGES="${vals[1]:-}"

    if [[ -n "$AUR_PACKAGES" ]] && ! $INSTALL_YAY; then
        INSTALL_YAY=true
        run_dialog --msgbox "\nyay auto-enabled (required for AUR packages)." 7 52
    fi
}

configure_save_load() {
    local result
    result="$(run_dialog \
        --title " Save / Load Configuration " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --menu "\nSave current config or load a previous one.\nCredentials are saved separately.\n" \
        16 65 5 \
        1 "Save config to JSON" \
        2 "Load config from JSON" \
        3 "Save credentials (GPG-encrypted)" \
        4 "Save credentials (plaintext)" \
        5 "Load credentials from JSON / .gpg" \
        3>&1 1>&2 2>&3)" || return 0

    result="${result//\"/}"
    case "$result" in
        1)  # Save config
            local save_path
            save_path="$(run_dialog \
                --title " Save Config " \
                --backtitle "Arch Linux Autoinstaller Configuration" \
                --inputbox "\nSave config JSON to:" \
                9 60 "${SCRIPT_DIR}/configs/my-config.json" \
                3>&1 1>&2 2>&3)" || return 0
            if [[ -n "$save_path" ]]; then
                mkdir -p "$(dirname "$save_path")"
                save_config_json "$save_path"
                run_dialog --msgbox "Config saved to:\n\n  $save_path\n\nReuse with: ./build-iso.sh --config $save_path" 10 60
            fi
            ;;
        2)  # Load config
            local load_path
            load_path="$(run_dialog \
                --title " Load Config " \
                --backtitle "Arch Linux Autoinstaller Configuration" \
                --inputbox "\nLoad config JSON from:" \
                9 60 "${SCRIPT_DIR}/configs/last-config.json" \
                3>&1 1>&2 2>&3)" || return 0
            if [[ -n "$load_path" && -f "$load_path" ]]; then
                load_config_json "$load_path"
                run_dialog --msgbox "Config loaded from:\n\n  $load_path" 8 55
            elif [[ -n "$load_path" ]]; then
                run_dialog --msgbox "File not found:\n\n  $load_path" 8 55
            fi
            ;;
        3)  # Save creds encrypted
            local cred_path="${SCRIPT_DIR}/configs/credentials.json"
            save_credentials_json "$cred_path" "gpg" && \
                run_dialog --msgbox "Encrypted credentials saved:\n\n  ${cred_path}.gpg" 8 55
            ;;
        4)  # Save creds plaintext
            local cred_path="${SCRIPT_DIR}/configs/credentials.json"
            save_credentials_json "$cred_path" "plain" && \
                run_dialog --msgbox "Plaintext credentials saved:\n\n  ${cred_path}\n\n⚠ Contains passwords in cleartext!" 10 55
            ;;
        5)  # Load creds
            local load_path
            load_path="$(run_dialog \
                --title " Load Credentials " \
                --backtitle "Arch Linux Autoinstaller Configuration" \
                --inputbox "\nLoad credentials from (.json or .json.gpg):" \
                9 60 "${SCRIPT_DIR}/configs/credentials.json.gpg" \
                3>&1 1>&2 2>&3)" || return 0
            if [[ -n "$load_path" ]] && [[ -f "$load_path" ]]; then
                load_credentials_json "$load_path"
                run_dialog --msgbox "Credentials loaded from:\n\n  $load_path" 8 55
            elif [[ -n "$load_path" ]]; then
                run_dialog --msgbox "File not found:\n\n  $load_path" 8 55
            fi
            ;;
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
    local omarchy_str="No"; $ENABLE_OMARCHY && omarchy_str="Yes"
    local pw_user="prompt at install"; [[ -n "$USER_PASSWORD" ]] && pw_user="set (••••)"
    local pw_luks="N/A"
    if $ENABLE_LUKS; then
        pw_luks="prompt at install"; [[ -n "$LUKS_PASSWORD" ]] && pw_luks="set (••••)"
    fi

    # Sleep/power summary
    local sleep_str="$SLEEP_ACTION"
    [[ "$SLEEP_ACTION" == "suspend-then-hibernate" ]] && sleep_str+=" (${HIBERNATE_DELAY})"
    local guard_str="Disabled"; $ENABLE_HIBERNATE_GUARD && guard_str="Enabled"

    # WiFi summary
    local wifi_str="Disabled"
    $ENABLE_WIFI && wifi_str="Enabled — ${WIFI_SSID:-<not set>}"

    # Offline summary
    local offline_str="Online (download packages)"
    $OFFLINE_MODE && offline_str="Offline (bundled packages)"

    # Packages summary
    local yay_str="No"; $INSTALL_YAY && yay_str="Yes"
    local extra_str="${EXTRA_PACKAGES:-(none)}"
    local aur_str="${AUR_PACKAGES:-(none)}"

    run_dialog \
        --title " Configuration Review " \
        --backtitle "Arch Linux Autoinstaller Configuration" \
        --msgbox "
╔══════════════════════════════════════════════════╗
║           INSTALLATION CONFIGURATION             ║
╠══════════════════════════════════════════════════╣
║                                                  ║
║  Security                                        ║
║    LUKS encryption:  $luks_str
║    Hibernate:        $hib_str
║    TPM auto-unlock:  $tpm_str
║                                                  ║
║  Desktop                                         ║
║    Environments:      $de_list
║    illogical-impulse: $ii_str
║    omarchy:           $omarchy_str
║                                                  ║
║  Networking                                      ║
║    WiFi:     $wifi_str
║    Install:  $offline_str
║                                                  ║
║  Packages                                        ║
║    Install yay (AUR): $yay_str
║    Extra pacman:      $extra_str
║    AUR packages:      $aur_str
║                                                  ║
║  System                                          ║
║    Hostname:    $HOSTNAME_CFG
║    Username:    ${USERNAME_CFG:-(set during install)}
║    Timezone:    $TIMEZONE_CFG
║    GPU drivers: ${GFX_DRIVERS[*]}
║    Disk mode:   $disk_str
║                                                  ║
║  Passwords                                       ║
║    User password:  $pw_user
║    LUKS password:  $pw_luks
║                                                  ║
║  Sleep & Power                                   ║
║    Sleep action:     $sleep_str
║    Suspend mode:     $SUSPEND_MODE
║    Lid close:        $LID_ACTION
║    Idle action:      $IDLE_ACTION (${IDLE_TIMEOUT_SEC}s)
║    Hibernate guard:  $guard_str
║                                                  ║
║  Post-Install (first boot):                      ║
║    • Secure Boot setup (if TPM enabled)          ║
║    • TPM enrollment (after Secure Boot)          ║
║    • Hibernate + sleep configuration             ║
║    • Hibernate guard service (if enabled)        ║
║    • illogical-impulse / omarchy (if selected)   ║
║    • WiFi auto-connect (if configured)           ║
║    • yay + AUR packages (if selected)            ║
║                                                  ║
╚══════════════════════════════════════════════════╝
" 50 62
}

apply_preferred() {
    ENABLE_LUKS=true
    ENABLE_HIBERNATE=true
    ENABLE_TPM=true
    ENABLE_HYPRLAND=true
    ENABLE_GNOME=true
    ENABLE_II=true
    ENABLE_II_FEATURES=true
    ENABLE_OMARCHY=false
    AUTO_DISK=true
    HOSTNAME_CFG="archlinux"
    TIMEZONE_CFG="US/Pacific"
    LOCALE_CFG="en_US"
    KB_LAYOUT_CFG="us"
    GFX_DRIVERS=("Intel (open-source)")
    SUSPEND_MODE="deep"
    SLEEP_ACTION="suspend-then-hibernate"
    HIBERNATE_DELAY="120min"
    LID_ACTION="suspend-then-hibernate"
    IDLE_ACTION="suspend-then-hibernate"
    IDLE_TIMEOUT_SEC=900
    ENABLE_HIBERNATE_GUARD=true
    INSTALL_YAY=true
    OFFLINE_MODE=false
    # Auto-detect WiFi
    if command -v nmcli &>/dev/null; then
        local ssid
        ssid="$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2 | head -1)"
        if [[ -n "$ssid" ]]; then
            ENABLE_WIFI=true
            WIFI_SSID="$ssid"
        fi
    fi
}

# ─── TUI Main Loop ────────────────────────────────────────────────────────────

run_tui() {
    while true; do
        local choice
        choice="$(show_main_menu)" || break  # "Build ISO" = cancel = break

        case "$choice" in
            P) apply_preferred
               run_dialog --msgbox "Preferred configuration applied!\n\n• LUKS + Hibernate + TPM\n• Hyprland + GNOME\n• illogical-impulse + all features\n• Auto disk, US/Pacific, Intel GPU\n• yay + suspend-then-hibernate" 14 52
               ;;
            1) configure_security ;;
            2) configure_desktop ;;
            3) configure_ii_features ;;
            4) configure_disk ;;
            5) configure_system ;;
            6) configure_graphics ;;
            7) configure_passwords ;;
            8) configure_sleep ;;
            9) configure_wifi ;;
            A) configure_packages ;;
            O) configure_offline ;;
            S) configure_save_load ;;
            R) show_review ;;
        esac
    done

    # Auto-save config after TUI
    mkdir -p "${SCRIPT_DIR}/configs"
    save_config_json "${SCRIPT_DIR}/configs/last-config.json"

    # Offer to save credentials
    prompt_save_credentials

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
        # archinstall: !encryption-password in disk_encryption triggers LUKS setup
        # If empty, archinstall will prompt interactively
        local luks_pw_json='""'
        if [[ -n "$LUKS_PASSWORD" ]]; then
            # Escape special JSON characters
            local escaped_luks
            escaped_luks="$(printf '%s' "$LUKS_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            luks_pw_json="\"${escaped_luks}\""
        fi
        encryption_json="{
        \"encryption_type\": \"luks\",
        \"!encryption-password\": ${luks_pw_json},
        \"partitions\": [\"__ROOT_PART_UUID__\"]
    }"
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
        "gfx_driver": "${GFX_DRIVERS[0]}",
        "greeter": "$greeter",
        $profile_json
    },
    "swap": true,
    "timezone": "$TIMEZONE_CFG",
    "uki": true,
    "version": "3.0.1"
}
JSONEOF

    # User credentials — password empty => archinstall prompts interactively
    if [[ -n "$USERNAME_CFG" ]]; then
        local escaped_user_pw=""
        if [[ -n "$USER_PASSWORD" ]]; then
            escaped_user_pw="$(printf '%s' "$USER_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        fi
        cat > "$config_dir/user_credentials.json" << CREDEOF
{
    "!users": [
        {
            "!password": "$escaped_user_pw",
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
# ISO provided by OSUOSL — osuosl.org/donate  |
# Sleep & Power
SUSPEND_MODE="__SUSPEND_MODE__"
SLEEP_ACTION="__SLEEP_ACTION__"
HIBERNATE_DELAY="__HIBERNATE_DELAY__"
LID_ACTION="__LID_ACTION__"
IDLE_ACTION="__IDLE_ACTION__"
IDLE_TIMEOUT_SEC="__IDLE_TIMEOUT_SEC__"
ENABLE_HIBERNATE_GUARD="__ENABLE_HIBERNATE_GUARD__"  Go Beavs! 🦫
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
# Selected feature branches (set by build-iso.sh feature picker)
II_SELECTED_BRANCHES="__II_SELECTED_BRANCHES__"

echo ""

    # ── Sleep & Power Configuration ──────────────────────────
    step "Sleep & Power Configuration"

    # Configure suspend mode (deep = S3, s2idle = S0ix)
    info "Setting suspend mode: $SUSPEND_MODE"
    sudo install -d -m 0755 /etc/systemd/sleep.conf.d
    cat << SLEEPEOF | sudo tee /etc/systemd/sleep.conf.d/10-sleep-config.conf > /dev/null
[Sleep]
HibernateMode=shutdown
SuspendState=mem
HibernateDelaySec=$HIBERNATE_DELAY
SLEEPEOF
    log "sleep.conf.d/10-sleep-config.conf written"

    # Set mem_sleep default via kernel param or sysfs
    echo "$SUSPEND_MODE" | sudo tee /sys/power/mem_sleep > /dev/null 2>&1 || true
    # Make persistent via tmpfiles
    cat << TMPEOF | sudo tee /etc/tmpfiles.d/suspend-mode.conf > /dev/null
w /sys/power/mem_sleep - - - - $SUSPEND_MODE
TMPEOF
    log "Suspend mode set to: $SUSPEND_MODE"

    # Configure logind (lid close, idle action)
    info "Configuring logind: lid=$LID_ACTION, idle=$IDLE_ACTION (${IDLE_TIMEOUT_SEC}s)"
    sudo install -d -m 0755 /etc/systemd/logind.conf.d
    cat << LOGINDEOF | sudo tee /etc/systemd/logind.conf.d/10-power-config.conf > /dev/null
[Login]
HandleLidSwitch=$LID_ACTION
HandleLidSwitchExternalPower=$LID_ACTION
HandleLidSwitchDocked=ignore
IdleAction=$IDLE_ACTION
IdleActionSec=${IDLE_TIMEOUT_SEC}
LOGINDEOF
    log "logind.conf.d/10-power-config.conf written"

    # Set default sleep target
    if [[ "$SLEEP_ACTION" == "suspend-then-hibernate" ]]; then
        sudo systemctl enable suspend-then-hibernate.target 2>/dev/null || true
    elif [[ "$SLEEP_ACTION" == "hybrid-sleep" ]]; then
        sudo systemctl enable hybrid-sleep.target 2>/dev/null || true
    fi
    log "Default sleep action: $SLEEP_ACTION"
fi

# ── Hibernate Guard ──────────────────────────────────────
if [[ "$ENABLE_HIBERNATE_GUARD" == "true" && "$ENABLE_HIBERNATE" == "true" ]]; then
    step "Hibernate Guard (disk space watchdog)"

    if [[ -f "$SCRIPT_DIR/hibernate-guard.sh" ]]; then
        sudo install -m 0755 "$SCRIPT_DIR/hibernate-guard.sh" /usr/local/bin/hibernate-guard.sh
        sudo install -m 0644 "$SCRIPT_DIR/hibernate-guard.service" /etc/systemd/system/hibernate-guard.service
        sudo install -m 0644 "$SCRIPT_DIR/hibernate-guard.timer" /etc/systemd/system/hibernate-guard.timer
        [[ -f "$SCRIPT_DIR/hibernate-guard.conf" ]] && \
            sudo install -m 0644 "$SCRIPT_DIR/hibernate-guard.conf" /etc/conf.d/hibernate-guard
        sudo systemctl daemon-reload
        sudo systemctl enable --now hibernate-guard.timer
        log "hibernate-guard.timer enabled (checks every 5 min)"
    else
        warn "hibernate-guard.sh not found — skipping"
    fi
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
            fi, auto-sized to RAM)"
[[ "$ENABLE_HIBERNATE" == "true" ]] && echo "  ✓ Sleep: ${SLEEP_ACTION} (suspend=${SUSPEND_MODE}, lid=${LID_ACTION})"
[[ "$ENABLE_HIBERNATE_GUARD" == "true" && "$ENABLE_HIBERNATE" == "true" ]] && echo "  ✓ Hibernate guard (disk space watchdog
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
    sed -i "s|__SUSPEND_MODE__|$SUSPEND_MODE|g" "$target"
    sed -i "s|__SLEEP_ACTION__|$SLEEP_ACTION|g" "$target"
    sed -i "s|__HIBERNATE_DELAY__|$HIBERNATE_DELAY|g" "$target"
    sed -i "s|__LID_ACTION__|$LID_ACTION|g" "$target"
    sed -i "s|__IDLE_ACTION__|$IDLE_ACTION|g" "$target"
    sed -i "s|__IDLE_TIMEOUT_SEC__|$IDLE_TIMEOUT_SEC|g" "$target"
    sed -i "s|__ENABLE_HIBERNATE_GUARD__|$ENABLE_HIBERNATE_GUARD|g" "$target"

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

    if [[ "$ENABLE_II_FEATURES" == "true" && -n "$II_SELECTED_BRANCHES" ]]; then
        info "Applying selected custom feature branches..."
        info "Branches: $II_SELECTED_BRANCHES"
        
        # Fetch all feature branches
        git fetch origin --all
        for branch in $(echo "$II_SELECTED_BRANCHES" | tr ',' '\n'); do
            git branch "$branch" "origin/$branch" 2>/dev/null || true
        done

        if [[ -f apply-features.sh ]]; then
            # Run apply-features.sh with the pre-selected branches
            info "Running apply-features.sh --all to deploy selected features..."
            chmod +x apply-features.sh
            ./apply-features.sh --all
            log "Custom features applied"
        else
            log "Feature branches fetched — run apply-features.sh manually to deploy"
        fi
    elif [[ "$ENABLE_II_FEATURES" == "true" ]]; then
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

    # Build comma-separated list of selected ii branches
    local ii_branch_list=""
    for i in "${!II_FEATURE_SELECTED[@]}"; do
        if (( II_FEATURE_SELECTED[i] )); then
            [[ -n "$ii_branch_list" ]] && ii_branch_list+=","
            ii_branch_list+="${II_FEATURE_BRANCHES[$i]}"
        fi
    done
    sed -i "s|__II_SELECTED_BRANCHES__|${ii_branch_list}|g" "$target"

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
    cp "$SCRIPT_DIR"/scripts/*.service "$POST_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR"/scripts/*.timer "$POST_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR"/scripts/*.conf "$POST_DIR/" 2>/dev/null || true
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
    for script in enable_hibernate_swapfile.sh setup-secureboot.sh setup-tpm-unlock.sh hibernate-guard.sh; do
        if [[ -f "$SCRIPT_DIR/scripts/$script" ]]; then
            sudo cp "$SCRIPT_DIR/scripts/$script" "$install_dir/scripts/"
        fi
    done
    # Copy hibernate-guard systemd units and config
    for f in hibernate-guard.service hibernate-guard.timer hibernate-guard.conf; do
        if [[ -f "$SCRIPT_DIR/scripts/$f" ]]; then
            sudo cp "$SCRIPT_DIR/scripts/$f" "$install_dir/scripts/"
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
setup_dialog_colors

# Load config/creds from CLI flags if provided
if [[ -n "$LOAD_CONFIG" ]]; then
    load_config_json "$LOAD_CONFIG"
fi
if [[ -n "$LOAD_CREDS" ]]; then
    load_credentials_json "$LOAD_CREDS"
fi

if [[ -n "$LOAD_CONFIG" ]]; then
    # Config loaded from file — skip TUI, just show what was loaded
    info "Configuration loaded from: $LOAD_CONFIG"
    [[ -n "$LOAD_CREDS" ]] && info "Credentials loaded from: $LOAD_CREDS"
elif $USE_PREFERRED; then
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
