---
name: deploy-arch-iso
description: >
  Build and HTTP-serve a custom Arch Linux autoinstall ISO for PXE deployment.
  Use when user asks to build an ISO, provision a machine, deploy Arch, or set
  up PXE boot. Accepts a config name as arg (e.g. "archnuc", "alongside-tslove",
  "archbee"). Optional flag: "--serve-only" to skip rebuild and just serve the
  latest ISO. Trigger keywords: build iso, provision, deploy arch, pxe, archnuc.
metadata:
  {
    "openclaw": {
      "emoji": "🐧",
      "requires": {
        "bins": ["python3"],
        "files": ["/home/tslove/projects/arch-autoinstall/build-iso.sh"]
      }
    }
  }
---

# Deploy Arch Autoinstall ISO

Build a configured Arch Linux ISO and serve it over HTTP for PXE boot.

## Project location

```
/home/tslove/projects/arch-autoinstall/
```

Key files:
- `build-iso.sh` — main builder, run WITHOUT sudo (handles sudo internally)
- `configs/*.json` — named machine configs
- `configs/credentials.json` — passwords (gitignored)
- `out/` — built ISOs land here

## Step 1: Parse args and resolve config

Parse any args (e.g. "archnuc", "alongside-tslove", "--serve-only").

Check the config exists:
```bash
ls /home/tslove/projects/arch-autoinstall/configs/*.json
```

If no config specified or not found, list available ones and ask the user.

If `--serve-only` was passed, skip to Step 4.

## Step 2: Check credentials

```bash
cat /home/tslove/projects/arch-autoinstall/configs/credentials.json
```

Verify `user_password` is non-empty. If empty, tell the user to set it before proceeding.

## Step 3: Build ISO

Start the build in a background PTY session (needs PTY for the dialog review UI and sudo fingerprint auth):

```bash
bash pty:true workdir:/home/tslove/projects/arch-autoinstall background:true command:"./build-iso.sh --config configs/<name>.json --creds configs/credentials.json"
```

Immediately tell the user:
> "Build started — you'll need to interact with it: (1) press **Enter** to confirm the review dialog, (2) press **y** then **Enter** at the 'Build custom ISO?' prompt, (3) authenticate sudo with your **fingerprint** when prompted. I'll monitor progress and notify you when it's done."

Then monitor in a loop using:
```
process action:log sessionId:XXX limit:20
process action:poll sessionId:XXX
```

Only update the user when something notable happens (build started downloading, squashfs repacking, build complete, or error). Don't spam updates.

Build is done when the log contains `"Custom ISO created:"`. A full build takes 5–15 minutes depending on download speed and squashfs compression.

If the session exits with a non-zero code, show the last 30 lines of log output and tell the user what failed.

## Step 4: Serve for PXE

Find the latest ISO:
```bash
ls -t /home/tslove/projects/arch-autoinstall/out/arch-autoinstall-*.iso | head -1
```

Check if port 8080 is free:
```bash
ss -tlnp | grep 8080
```

Start the HTTP server in background:
```bash
bash background:true command:"python3 -m http.server 8080 --directory /home/tslove/projects/arch-autoinstall/out/"
```

Get the LAN IP:
```bash
ip -4 addr show | awk '/inet / && !/127.0.0/ {print $2}' | cut -d/ -f1 | head -1
```

## Step 5: Report

Tell the user:
- ISO filename and size
- Full HTTP URL: `http://<LAN_IP>:8080/<iso-filename>`
- Server PID to kill when done: `kill <PID>`

Example:
```
✓ ISO ready: arch-autoinstall-20260529-143012.iso (1.8 GiB)

HTTP server running:
  http://10.X.X.X:8080/arch-autoinstall-20260529-143012.iso

Point your PXE config at that URL.
Stop the server when done:  kill <PID>
```

## Post-install reminder

For alongside-Windows installs, remind the user of the 3-boot sequence:
1. Boot Arch → run `sudo ~/post-install/post-install.sh` → setup-secureboot creates keys, signs UKIs, prompts reboot
2. Enter BIOS → enable Secure Boot (User/Deployed Mode) → boot Arch → run `setup-tpm-unlock.sh`
3. TPM auto-unlocks from here on; Windows still boots via shared ESP
