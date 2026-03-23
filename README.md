# Arch Autoinstall

**Zero-touch Arch Linux installer builder with TUI configuration.**

ISO provided by [OSUOSL](https://osuosl.org/donate) — Go Beavs! 🦫

## Overview

This project builds a customized Arch Linux ISO that performs automated
installation with your chosen configuration. It bundles:

- **LUKS full-disk encryption** (btrfs on LUKS)
- **Hibernate support** via dedicated `@swap` btrfs subvolume (systemd ≥259 fix)
- **TPM2 auto-unlock** with Secure Boot enrollment
- **Hyprland** with optional [illogical-impulse](https://github.com/end-4/dots-hyprland) rice
- **GNOME** as an alternative/additional desktop
- Post-install automation for Secure Boot + TPM enrollment

## Quick Start

```bash
# Install dependencies
sudo pacman -S dialog curl libisoburn squashfs-tools

# Run the builder (interactive TUI)
./build-iso.sh

# Or use the preferred configuration directly
./build-iso.sh --preferred
```

The builder will:
1. Present a TUI to configure your installation
2. Download the latest Arch ISO from [OSUOSL](https://ftp.osuosl.org/pub/archlinux/iso/latest/)
3. Customize the ISO with your archinstall configuration
4. Output a self-installing ISO ready to flash to USB

## Flashing to USB

```bash
sudo dd if=out/arch-autoinstall-*.iso of=/dev/sdX bs=4M status=progress
```

Replace `/dev/sdX` with your USB drive.

## What Gets Installed

### Base System
- Arch Linux with systemd-boot (UKI)
- btrfs with subvolumes: `@`, `@home`, `@log`, `@pkg`, `@.snapshots`, `@swap`
- PipeWire audio, NetworkManager
- Essential packages: git, base-devel, vim, htop, fish, sbctl, tpm2-tools

### Desktop (configurable)
- **Hyprland** — tiling Wayland compositor with polkit
- **GNOME** — full desktop environment
- **illogical-impulse** — comprehensive Hyprland rice (optional)

### Security (configurable)
- **LUKS** — full-disk encryption (required for hibernate & TPM)
- **Hibernate** — btrfs `@swap` subvolume with 40G swapfile
- **TPM2** — auto-unlock bound to Secure Boot state (PCR 0+7)

## Post-Install Flow

After the automated install completes and you reboot:

1. **First boot** — A reminder banner shows the post-install script location
2. **Run** `/root/arch-autoinstall/post-install.sh`
3. The script handles (in order):
   - Hibernate setup (swapfile, resume params, mkinitcpio)
   - Secure Boot key creation and enrollment (if firmware is in Setup Mode)
   - Reboot prompt to enable Secure Boot in BIOS
   - TPM enrollment (after Secure Boot is active)
   - illogical-impulse clone and setup

### Secure Boot + TPM Workflow

TPM auto-unlock requires Secure Boot to be active first. The post-install
script guides you through this multi-boot process:

```
Boot 1:  post-install.sh → creates Secure Boot keys → reboot
         ↓ BIOS: enable Secure Boot (User/Deployed Mode)
Boot 2:  post-install.sh → enrolls TPM2 → reboot
Boot 3:  auto-unlocks with TPM — no password needed! 🎉
```

## Project Structure

```
arch-autoinstall/
├── build-iso.sh                    # Main builder with TUI
├── README.md
├── scripts/
│   ├── enable_hibernate_swapfile.sh  # Hibernate setup (8 steps)
│   ├── setup-secureboot.sh           # Secure Boot with sbctl (6 steps)
│   └── setup-tpm-unlock.sh           # TPM2 auto-unlock (6 steps)
├── configs/                          # Generated archinstall configs
├── assets/                           # Branding assets
├── hooks/                            # Pacman hooks
├── cache/                            # Downloaded ISOs (gitignored)
├── work/                             # Build working directory (gitignored)
└── out/                              # Output ISOs (gitignored)
```

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| LUKS encryption | ✅ On | Full-disk encryption with LUKS |
| Hibernate | ✅ On | btrfs @swap subvolume + swapfile |
| TPM auto-unlock | ✅ On | Bound to Secure Boot state |
| Hyprland | ✅ On | Tiling Wayland compositor |
| GNOME | ✅ On | Full desktop environment |
| illogical-impulse | ✅ On | Hyprland rice with custom features |
| Disk selection | Auto | Largest non-removable disk |
| GPU driver | Intel | Open-source Intel drivers |
| Timezone | US/Pacific | — |
| Locale | en_US | UTF-8 |

## Dependencies

- `dialog` — TUI dialogs
- `curl` — ISO download
- `xorriso` (`libisoburn`) — ISO manipulation
- `squashfs-tools` — Root filesystem modification
- Root privileges for ISO customization

## Notes

- The archinstall config uses `luks` encryption type (not `luks_on_lvm`)
  which is required for hibernate `resume=` to work with a direct block device
- The `@swap` subvolume is necessary for systemd ≥259 hibernate support
- OSUOSL mirror is hardcoded — it's fast and reliable for Oregon-based installs
- The ISO auto-launches the installer on boot; press `n` to drop to a shell

## Credits

- ISO hosting: [Oregon State University Open Source Lab](https://osuosl.org/donate)
- Hyprland rice: [end-4/dots-hyprland (illogical-impulse)](https://github.com/end-4/dots-hyprland)
- Arch Linux: [archlinux.org](https://archlinux.org)

---

*Go Beavs! 🦫*
