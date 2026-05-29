---
name: deploy-arch-iso
description: Build and HTTP-serve a custom Arch Linux autoinstall ISO for PXE deployment. Use when the user asks to build an ISO, deploy a system, set up PXE boot, or provision an Arch machine. Accepts optional args: config name (e.g. "archnuc") and/or "--serve-only" to skip rebuild.
---

# Deploy Arch Autoinstall ISO

Build a configured Arch Linux ISO and serve it over HTTP for PXE boot.

## Context

This project lives at the current working directory. Key files:
- `build-iso.sh` — main builder, run WITHOUT sudo (prompts internally)
- `configs/*.json` — named machine configs (archnuc, alongside-tslove, archbee, etc.)
- `configs/credentials.json` — passwords (gitignored, not committed)
- `out/` — built ISOs land here
- The script rejects `sudo` at the top level — always run as the regular user

## Step 1: Resolve config

Parse any args the user passed (e.g. `/deploy-arch-iso archnuc` or `/deploy-arch-iso --serve-only`).

If a config name was given, check `configs/<name>.json` exists. If not, list available configs:
```bash
ls configs/*.json
```

If no config was specified, ask the user which config to use, showing the available options.

If `--serve-only` was passed, skip to Step 4.

## Step 2: Check credentials

Check that `configs/credentials.json` exists and has non-empty `user_password`:
```bash
cat configs/credentials.json
```

If missing or empty, tell the user — the build will prompt interactively for passwords which won't work non-interactively. Ask them to set it before proceeding.

## Step 3: Build the ISO

Run the build (no sudo — the script handles that internally):
```bash
./build-iso.sh --config configs/<name>.json --creds configs/credentials.json
```

This is interactive — it shows a review dialog and asks for confirmation before downloading and building. Inform the user it may take 5–15 minutes depending on internet speed and squashfs compression.

After the build completes, confirm the new ISO exists:
```bash
ls -lh out/arch-autoinstall-*.iso | tail -3
```

## Step 4: Serve for PXE

Find the most recently built ISO:
```bash
ls -t out/arch-autoinstall-*.iso | head -1
```

Start an HTTP server from the `out/` directory. Use port 8080 (or try 8090/8000 if occupied):
```bash
# Check if port 8080 is in use
ss -tlnp | grep 8080
```

If free, serve it:
```bash
python3 -m http.server 8080 --directory out/
```

Run this in the background and capture the PID so it can be stopped later.

Get the machine's LAN IP:
```bash
ip -4 addr show | awk '/inet / && !/127.0.0/ {print $2}' | cut -d/ -f1 | head -1
```

## Step 5: Report

Tell the user:
- The ISO filename and size
- The HTTP URL: `http://<LAN_IP>:8080/<iso-filename>`
- That their existing PXE infra should point to this URL
- The server PID so they can kill it when done: `kill <PID>`

Example output format:
```
ISO ready: arch-autoinstall-20260529-143012.iso (1.8 GiB)

HTTP server running on:
  http://10.X.X.X:8080/arch-autoinstall-20260529-143012.iso

Point your PXE config at that URL.
Stop the server when done: kill <PID>
```

## Notes

- The build script shows a dialog review before building — the user must interact with it
- Credentials must be set in configs/credentials.json before a non-interactive build is possible
- For alongside-Windows installs, Secure Boot must be in Setup Mode before running post-install
- After install, the 3-reboot sequence is: (1) run post-install.sh → setup-secureboot, (2) enable Secure Boot in BIOS, (3) run setup-tpm-unlock.sh
