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

# Step by step after install:
bash scripts/set-profile.sh pixel6a-bp1a --rebuild --boot --check
```

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
├── base/               # Master read-only image — never boot directly
├── intermediate/       # GApps + ARM trans baked in, still read-only
├── builds/             # Final per-profile artifacts  ← boot these
├── userdata/           # Per-profile userdata volumes (8 GB each)
├── profiles/           # JSON device identity profiles
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
android11-gapps-arm.qcow2      (+ GApps + ARM trans, built once)
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
