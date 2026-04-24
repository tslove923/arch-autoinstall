# Arch Autoinstall

**Zero-touch Arch Linux installer builder with TUI configuration.**

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
4. Output a modified ISO named `arch-autoinstall-<timestamp>.iso`

## Flashing to USB

```bash
sudo dd if=out/arch-autoinstall-*.iso of=/dev/sdX bs=4M status=progress
```

Replace `/dev/sdX` with your USB drive. The output filename always contains
`autoinstall` to distinguish it from the upstream Arch ISO.

## What Gets Installed

### Base System
- Arch Linux with systemd-boot (UKI)
- btrfs with subvolumes: `@`, `@home`, `@log`, `@pkg`, `@.snapshots`, `@swap`
- PipeWire audio, NetworkManager
- Essential packages: git, base-devel, vim, htop, fish, sbctl, tpm2-tools

### Desktop (configurable)
- **Hyprland** — tiling Wayland compositor with polkit
- **GNOME** — full desktop environment
- **illogical-impulse** — comprehensive Hyprland rice with per-feature selection

### Security (configurable)
- **LUKS** — full-disk encryption (required for hibernate & TPM)
- **Hibernate** — btrfs `@swap` subvolume with 40G swapfile
- **TPM2** — auto-unlock bound to Secure Boot state (PCR 0+7)

### illogical-impulse Feature Picker

When selecting "illogical-impulse + custom features", the TUI presents a
built-in feature picker with the same catalog as `apply-features.sh`:

| Feature | Description |
|---------|-------------|
| WiFi Reconnect Fix | Auto-reconnect WiFi after entering saved password |
| MPRIS Active Player Fix | Fix media controls to target the active player |
| Copilot Integration | GitHub Copilot AI panel in sidebar |
| Custom Configs & Keybinds | Custom keybinds, xwayland, Docker/VPN/proxy toggles |
| US Date & World Clocks | US date format + configurable world clocks |
| Home Assistant Panel | Home Assistant smart home panel in bar |
| GPU/NPU Monitoring | Intel GPU + NPU utilization indicators in bar |
| VPN Status Indicator | WireGuard/OpenVPN status icon with toggle |

Dependencies are auto-resolved (e.g. selecting Home Assistant auto-enables
Custom Configs). Selected features are baked into the ISO and applied
automatically during post-install.

## Post-Install Flow

After the automated install completes and you reboot:

1. **First boot** — A reminder banner shows the post-install script location
2. Scripts are in `~/post-install/` (user copy) and `/root/arch-autoinstall/` (root copy)
3. **Run** `sudo ~/post-install/post-install.sh`
4. The script handles (in order):
   - Hibernate setup (swapfile, resume params, mkinitcpio)
   - Secure Boot key creation and enrollment (if firmware is in Setup Mode)
   - Reboot prompt to enable Secure Boot in BIOS
   - TPM enrollment (after Secure Boot is active)
   - illogical-impulse clone, setup, and feature branch deployment

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
│   ├── setup-proxy.sh                # Corporate proxy configuration
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
| illogical-impulse | ✅ On | Hyprland rice with per-feature picker |
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

## Corporate Proxy Support

For networks that require an HTTP proxy (e.g. Intel), enable the proxy option
in the TUI or use `--preferred`. When enabled, `scripts/setup-proxy.sh` is
bundled into the ISO and automatically applied to the installed system.

The proxy script configures:
- `/etc/environment` — `http_proxy`, `https_proxy`, `ftp_proxy`, `no_proxy`
- `/etc/sudoers.d/proxy` — preserves proxy env vars through sudo
- `/etc/pacman.conf` — XferCommand with proxy-aware curl
- `/etc/resolv.conf` — corporate DNS servers
- `/etc/gnupg/dirmngr.conf` — GPG keyserver proxy
- `/etc/systemd/timesyncd.conf` — corporate NTP + fallback
- `/etc/xdg/reflector/reflector.conf` — mirror refresh with `--url` flag

Proxy is applied during install (via `arch-chroot`) so the installed system
has network access on first boot. The script is also available at
`~/post-install/setup-proxy.sh` for re-running or updating.

## Notes

- The archinstall config uses `luks` encryption type (not `luks_on_lvm`)
  which is required for hibernate `resume=` to work with a direct block device
- The `@swap` subvolume is necessary for systemd ≥259 hibernate support
- The output ISO is always named `arch-autoinstall-<timestamp>.iso` and has
  volume ID `ARCH_AUTOINSTALL` to clearly indicate it's been modified
- The ISO auto-launches the installer on boot; press `n` to drop to a shell

---

## Credits & Acknowledgments

- Hyprland rice: [end-4/dots-hyprland (illogical-impulse)](https://github.com/end-4/dots-hyprland)
- Arch Linux: [archlinux.org](https://archlinux.org)

### ISO Hosting

ISO downloads provided by the **Oregon State University Open Source Lab**.

<p align="center">
  <a href="https://osuosl.org/donate">
    <img src="https://osuosl.org/images/OSU_newlogo.png" alt="Oregon State University Open Source Lab" width="300">
  </a>
</p>

<p align="center">
  <a href="https://osuosl.org/donate">osuosl.org/donate</a><br>
  <strong>Go Beavs! 🦫</strong>
</p>
