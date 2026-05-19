# Android 11 x86_64 VM — Build & Profile System

Bootable Android 11 x86_64 QEMU/KVM image with pre-integrated GApps, ARM translation (`libndk_translation`), and a deterministic pre-boot profile patcher that produces per-identity image artifacts with zero runtime spoofing dependencies.

---

## Quick Start

```bash
# One-liner from anywhere — installs deps, downloads base image, applies default profile
curl -fsSL https://raw.githubusercontent.com/Chr0mX/androidVM/main/install.sh | bash

# With options via env vars (required when piping through curl):
curl -fsSL https://raw.githubusercontent.com/Chr0mX/androidVM/main/install.sh \
  | ANDROID_VM_PROFILE=pixel7-ap1a ANDROID_VM_BOOT=1 bash

# Cloned locally with flags:
bash install.sh --profile samsung-s23-eu --boot

# After install — use the unified CLI:
android-vm start                              # start with defaults
android-vm start pixel7-ap1a --vm-profile performance
android-vm doctor                             # verify everything is set up
```

## android-vm CLI

The unified `android-vm` command is installed to `/usr/local/bin` by the installer.

```bash
android-vm start [device-profile] [--vm-profile <name>]
    # Start the VM. Defaults come from config/defaults.json.

android-vm stop [device-profile]
    # Stop a running VM (SIGTERM → SIGKILL after 10 s).

android-vm status [device-profile]
    # Show running state, PID, uptime, ADB port, and image sizes.
    # Checks all profiles when no argument is given.

android-vm reset [device-profile]
    # Factory-reset userdata (delete + recreate the userdata volume).

android-vm update
    # git pull the repo and refresh the intermediate image.

android-vm doctor
    # Check all dependencies, KVM, images, disk space, and RAM.

android-vm profiles
    # List available device profiles and VM hardware profiles.
```

**Global flag:** `--debug` enables `bash -x` trace mode on any subcommand.

## VM Hardware Profiles

VM hardware profiles control QEMU resource allocation and are independent of device identity profiles. Profiles live in `config/vm-profiles/*.json`.

| Profile | RAM | Cores | GPU | Use case |
|---|---|---|---|---|
| `performance` | 6144 MB | 6 | virtio-vga-gl | 8+ GB RAM, host OpenGL required |
| `balanced` | 4096 MB | 4 | virtio-vga | 6+ GB RAM, recommended default |
| `compatibility` | 2048 MB | 2 | VGA (std) | Older hardware, no OpenGL/KVM needed |
| `lowram` | 2048 MB | 2 | virtio-vga | Systems with ≤ 4 GB total RAM |

```bash
android-vm start pixel6a-bp1a --vm-profile compatibility
# or via boot.sh directly:
bash scripts/boot.sh pixel6a-bp1a --vm-profile performance
```

## SPICE Remote Display

Run the VM headlessly and stream the display to a SPICE client:

```bash
bash scripts/boot.sh pixel6a-bp1a --spice
# then connect from another terminal or machine:
remote-viewer spice://localhost:5900
```

Install a SPICE client: `sudo apt install virt-viewer` (provides `remote-viewer`).

## VNC Remote Display

VNC is a simpler alternative to SPICE — any VNC viewer works, no special client needed:

```bash
# Display :0 → port 5900 (default)
bash scripts/boot.sh pixel6a-bp1a --vnc

# Display :1 → port 5901
bash scripts/boot.sh pixel6a-bp1a --vnc 1

# Then connect:
vncviewer localhost:5900
```

VNC uses software rendering (no OpenGL required) and works well over SSH tunnels:

```bash
# Forward VNC over SSH from a remote machine:
ssh -L 5900:localhost:5900 user@host
vncviewer localhost:5900
```

Install a VNC client: `sudo apt install tigervnc-viewer` or use Remmina, RealVNC, or any VNC-compatible client.

| Method | Flag | Port | Client | Best for |
|---|---|---|---|---|
| SPICE | `--spice` | 5900 | `virt-viewer` / `remote-viewer` | Performance, clipboard sharing |
| VNC | `--vnc [n]` | 5900+n | Any VNC viewer | Maximum compatibility, SSH tunnels |

### Env var overrides (for the curl pipe case)

| Env var | Flag equivalent | Description |
|---|---|---|
| `ANDROID_VM_PROFILE` | `--profile` | Profile name to apply |
| `ANDROID_VM_DIR` | `--dir` | Workspace directory |
| `ANDROID_VM_REPO` | `--repo` | Git repo URL to clone |
| `ANDROID_VM_BOOT` | `--boot` | Set to any value to launch VM after build |
| `ANDROID_VM_NO_DL` | `--no-download` | Build intermediate locally |
| `ANDROID_VM_SKIP_VFY` | `--skip-verify` | Skip ADB verification |

## Prerequisites

```bash
# Ubuntu / Debian
sudo apt install qemu-system-x86 qemu-utils qemu-kvm android-tools-adb \
                 simg2img python3 python3-pip jq curl rsync ovmf p7zip-full
pip3 install jsonschema
```

## Workspace Layout

```
workspace/
├── android-vm              # Unified CLI (symlinked to /usr/local/bin)
├── install.sh              # One-liner installer
├── base/                   # Master read-only image — never boot directly
├── intermediate/           # GApps + ARM trans baked in, still read-only
├── builds/                 # Final per-profile artifacts  ← boot these
├── userdata/               # Per-profile userdata volumes (8 GB each)
├── run/                    # Runtime PID files (gitignored)
├── cache/                  # Download cache for split archives (gitignored)
├── config/
│   ├── defaults.json           # Default VM and port settings
│   ├── device-spoof.json       # Device identity spoofing settings
│   └── vm-profiles/
│       ├── performance.json    # 6 GB RAM, 6 cores, virtio-vga-gl
│       ├── balanced.json       # 4 GB RAM, 4 cores, virtio-vga  (default)
│       ├── compatibility.json  # 2 GB RAM, 2 cores, VGA (no OpenGL)
│       └── lowram.json         # 2 GB RAM, 2 cores, virtio-vga (no OpenGL)
├── profiles/               # JSON device identity profiles
│   ├── schema.json
│   ├── pixel6a-bp1a.json
│   ├── pixel7-ap1a.json
│   └── samsung-s23-eu.json
├── scripts/
│   ├── build-intermediate.sh   # Build intermediate layer (run once)
│   ├── set-profile.sh          # Create per-profile build
│   ├── boot.sh                 # Launch VM in QEMU/KVM
│   ├── verify.sh               # ADB-based verification
│   └── lib/
│       ├── detect-hardware.sh      # CPU/RAM/KVM detection helpers
│       ├── fetch-release.sh        # GitHub API downloader (split-archive aware)
│       ├── patch-props.py          # Deterministic build.prop patcher
│       ├── profile-validator.py    # JSON schema + consistency checks
│       ├── inject-gapps.sh         # GApps offline injection
│       ├── inject-arm-trans.sh     # ARM translation lib injection
│       └── fetch-arm-trans.sh      # Download libndk_translation
├── gapps/              # Place MindTheGapps-11.0.0-x86_64-*.zip here
├── arm-trans/          # libndk_translation (auto-fetched if absent)
└── logs/
```

## Image Strategy

Three-layer qcow2 backing chain — only the final layer stores diffs per profile:

```
android11-base.qcow2           (raw source, never modified)
       ↓ backing-file
blissos14-gapps-arm.qcow2      (+ GApps + ARM trans, built once)
       ↓ backing-file
android11-<profile>.qcow2      (+ identity props, one per profile)
```

## Profile System

Each profile is a JSON file defining device identity props for `system` and `vendor` partitions. The patcher replaces matching keys in `build.prop` and appends any that are absent.

```bash
# Validate a profile
python3 scripts/lib/profile-validator.py profiles/pixel6a-bp1a.json

# Apply a profile and boot
bash scripts/set-profile.sh pixel6a-bp1a --rebuild --boot --check
```

See `profiles/schema.json` for the full schema and prohibited key list.

## ARM Translation

`libndk_translation` enables ARM apps on the x86_64 VM. Required vendor props:

```
ro.dalvik.vm.native.bridge=libndk_translation.so
ro.enable.native.bridge.exec=1
ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
```

## Common Commands

```bash
# Build intermediate image from scratch (30–90 min, run once)
bash scripts/build-intermediate.sh

# Build a profile image
bash scripts/set-profile.sh pixel6a-bp1a

# Boot it
bash scripts/boot.sh pixel6a-bp1a

# Connect ADB
adb connect localhost:5555

# Verify identity props, ARM bridge, and no emulator leaks
bash scripts/verify.sh profiles/pixel6a-bp1a.json

# Switch profile
bash scripts/set-profile.sh pixel7-ap1a --rebuild --boot --check

# Reset userdata (factory wipe without rebuilding image)
qemu-img create -f qcow2 userdata/userdata-pixel6a-bp1a.qcow2 8G
```

## CI

`.github/workflows/build-base.yml` builds the intermediate image and publishes it as a GitHub Release. Requires a self-hosted runner with KVM access tagged `self-hosted, linux, kvm`.

See the workflow for cache key design and smoke-test details.

## Known Limitations

- **Play Integrity**: `BASIC_INTEGRITY` at best. Hardware attestation (KeyMint) cannot be satisfied in a VM.
- **Widevine**: L3 only on x86 VMs. Streaming apps may downgrade video quality.
- **Google sign-in**: Requires network access on first boot.
