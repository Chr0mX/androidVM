# Android VM — Multi-Instance Manager

Bootable Android x86_64 QEMU/KVM system with a multi-instance manager, Flask web GUI, and a deterministic pre-boot profile patcher. The VM boots via GRUB EFI (OVMF) on a 3-partition GPT disk — no direct-kernel-boot, no sidecar files.

---

## Quick Start

```bash
# One-liner from anywhere — installs deps, downloads base image, sets up workspace
curl -fsSL https://raw.githubusercontent.com/Chr0mX/androidVM/main/install.sh | bash

# With options via env vars (required when piping through curl):
curl -fsSL https://raw.githubusercontent.com/Chr0mX/androidVM/main/install.sh \
  | ANDROID_VM_PROFILE=pixel7-ap1a ANDROID_VM_BOOT=1 bash

# Cloned locally with flags:
bash install.sh --profile samsung-s23-eu --boot

# After install — create your first instance:
android-vm instance create my-android \
  --profile pixel6a-bp1a --vm-profile balanced --distro bliss14
bash scripts/set-profile.sh my-android   # build the disk
android-vm instance start my-android     # launch VM

# Or open the web UI to manage everything graphically:
android-vm gui   # opens http://127.0.0.1:8080/

android-vm doctor   # verify all dependencies are set up
```

## Updating to New CI Images

When CI publishes a new base image (tagged `bliss14-base-YYYYMMDD-HHMM` or `sakura-base-YYYYMMDD-HHMM`), update your local setup in three steps:

```bash
# 1. Pull latest scripts and configs
git pull

# 2. Download new intermediate image(s) from GitHub Releases
android-vm update
# Iterates every distro in androiddistro/ and downloads its latest CI release.
# Warns (does not fail) if a distro has no release yet.

# 3. Rebuild each instance disk to link against the fresh intermediate
bash scripts/set-profile.sh my-pixel
bash scripts/set-profile.sh my-work    # repeat for each instance you have
```

> **Why rebuild?** Each instance disk is a thin qcow2 overlay that points to the intermediate via a backing-file chain. `android-vm update` replaces the intermediate file, but existing overlays still reference the old content until you rebuild them.

Check what you currently have:
```bash
android-vm doctor      # reports intermediate + instance disk sizes, KVM, disk space
android-vm profiles    # lists available device profiles, VM profiles, and distros
```

---

## android-vm CLI

The unified `android-vm` command is installed to `/usr/local/bin` by the installer.

### Instance management (primary interface)

```bash
android-vm instance create <name> --profile <device> --vm-profile <hw> --distro <distro>
    # Create a new named instance. Allocates ADB and SPICE ports automatically.
    # After creating, run: bash scripts/set-profile.sh <name>   to build the disk.

android-vm instance list
    # Show all instances with state, ports, distro, and VM profile.

android-vm instance show <name>
    # Print full instance config JSON (includes allocated ports).

android-vm instance start  <name>
    # Boot the instance in headless mode. PID tracked in run/<name>.pid.

android-vm instance stop   <name>
    # Graceful shutdown (SIGTERM → SIGKILL after 10 s).

android-vm instance restart <name>
    # Stop then start.

android-vm instance reset  <name>
    # Factory-reset Userdata partition (wipes app data; Android system untouched).

android-vm instance expand <name> <size> [--apply]
    # Grow the Userdata partition. VM must be stopped.
    # <size>: +4G or +512M (delta) or 16G or 8192M (absolute). No shrinking.
    # Without --apply: dry-run — prints current → new size plan, makes no changes.
    # With    --apply: resizes the qcow2, expands the GPT partition, grows the filesystem.

android-vm instance delete <name>
    # Delete instance config and disk. Cannot be undone.
```

### Web GUI

```bash
android-vm gui [--port <n>] [--bind <addr>] [--no-open]
    # Launch the Flask web UI (default: http://127.0.0.1:8080/).
    # --port N     listen on port N (default: 8080)
    # --bind addr  bind address (default: 127.0.0.1)
    # --no-open    don't auto-open a browser tab
```

The GUI provides a live instance table with 3-second auto-refresh, start/stop/restart/reset/delete actions, disk expansion form, and serial log tail on each instance's detail page.

### Utility commands

```bash
android-vm update
    # git pull + download latest intermediate images from GitHub Releases.

android-vm doctor
    # Check all dependencies, KVM access, intermediate images, disk space, and RAM.

android-vm profiles
    # List available device profiles, VM hardware profiles, and distros.

android-vm status [instance-or-profile]
    # Show running state, PID, uptime, ADB port, and image sizes.

android-vm virt-manager [device-profile] [--define] [--start] [...]
    # Generate a libvirt XML domain definition (see virt-manager section below).
```

**Legacy shortcuts** — these still work and resolve to the default instance or auto-create one:

```bash
android-vm start [profile]     # equivalent to instance start
android-vm stop  [profile]     # equivalent to instance stop
android-vm reset [profile]     # equivalent to instance reset
```

**Global flag:** `--debug` enables `bash -x` trace mode on any subcommand.

---

## Typical Workflow

```bash
# 1. Create an instance
android-vm instance create work-phone \
  --profile pixel6a-bp1a --vm-profile balanced --distro bliss14

# 2. Build its disk (downloads ISO if needed; ~5–30 min on first run)
bash scripts/set-profile.sh work-phone

# 3. Start the VM
android-vm instance start work-phone

# 4. Connect ADB (port shown in instance show output)
android-vm instance show work-phone   # → adb_port: 5555
adb connect localhost:5555

# 5. Or manage everything via the web UI
android-vm gui   # http://127.0.0.1:8080/

# 6. Need more storage? Expand the Userdata partition
android-vm instance stop work-phone
android-vm instance expand work-phone +8G          # shows plan: 8.0 GiB → 16.0 GiB
android-vm instance expand work-phone +8G --apply  # performs the expansion

# 7. Cleanup
android-vm instance stop work-phone
android-vm instance delete work-phone
```

---

## Instance System

Each **named instance** is an independent Android VM with its own disk and network ports.

**Instance config** — `instances/<name>.json`:
```json
{
  "name": "work-phone",
  "device_profile": "pixel6a-bp1a",
  "vm_profile": "balanced",
  "distro": "bliss14",
  "adb_port": 5555,
  "spice_port": 5900,
  "created_at": "2025-01-01T00:00:00Z"
}
```

**Instance disk** — `instances/<name>/disk.qcow2`: a thin qcow2 overlay over the distro intermediate image.

**Port allocation**: ADB ports start at 5555, SPICE ports at 5900. Each new instance gets the next free port not bound by another process or already claimed by an existing instance. Multiple instances can run concurrently.

**Runtime files** (in `run/`):
- `<name>.pid` — QEMU process PID
- `<name>.qmp.sock` — QMP control socket
- `<name>-serial.log` — serial console output

---

## Web GUI

`android-vm gui` starts a local [Flask](https://flask.palletsprojects.com/) server.

| URL | Description |
|---|---|
| `http://127.0.0.1:8080/` | Instance list (live state, start/stop/restart actions) |
| `http://127.0.0.1:8080/instances/new` | Create new instance form |
| `http://127.0.0.1:8080/instances/<name>` | Instance detail: config, actions, serial log, expand form |

The instance list auto-refreshes every 3 seconds. The detail page shows the serial log tail (last 8 KB) and auto-refreshes while the instance is running.

Requires Python 3 + Flask — both installed by `install.sh`.

---

## VM Hardware Profiles

VM hardware profiles control QEMU resource allocation and are independent of device identity profiles. Profiles live in `config/vm-profiles/*.json`.

All profiles use **virtio-vga-gl** with `gtk,gl=on,show-cursor=on` — host OpenGL is required.

| Profile | RAM | Cores | Use case |
|---|---|---|---|
| `performance` | 6144 MB | 6 | 8+ GB RAM; best for heavy app usage |
| `balanced` | 4096 MB | 4 | 6+ GB RAM; recommended default |
| `compatibility` | 2048 MB | 2 | Lighter workloads; still needs host GL |
| `lowram` | 2048 MB | 2 | Systems with ≤ 4 GB total RAM |

> **No host OpenGL?** Edit the relevant profile JSON: set `"gpu": "std"` and `"display": "sdl"` (or `"vnc"`) to fall back to software rendering. Performance will be lower.

---

## Boot Architecture

The VM boots via **GRUB EFI** using OVMF firmware:

1. QEMU loads OVMF from the host (`/usr/share/OVMF/OVMF_CODE.fd` or equivalent).
2. OVMF finds `EFI/BOOT/BOOTX64.EFI` on p1 (ESP, FAT32, 256 MiB).
3. The GRUB stub searches for a disk labeled "BlissOS" and loads `/grub/grub.cfg` from p2.
4. grub.cfg boots Android from `p2/android/kernel` + `p2/android/initrd.img` with `SRC=android DATA=Userdata`.

`fetch-distro.sh` and `set-profile.sh` build this disk from the distro ISO using `grub-mkstandalone` (standalone EFI binary with all required modules embedded). No sidecar kernel/initrd files live outside the qcow2.

**grub.cfg menu entries** (generated at disk-build time):
- **BlissOS** — normal boot, silent (no console output to framebuffer)
- **BlissOS (debug)** — adds `DEBUG=2 console=tty0 console=ttyS0,115200n8`; both framebuffer and serial active

---

## SPICE Remote Display

Each instance has a dedicated SPICE port (shown in `instance show` output and in the web GUI). Connect from a SPICE client:

```bash
android-vm instance show my-android   # → spice_port: 5900
remote-viewer spice://localhost:5900
```

Install a SPICE client: `sudo apt install virt-viewer` (provides `remote-viewer`).

## VNC Remote Display

VNC works via an offset from the instance's SPICE port. Use it when SPICE is unavailable or for SSH tunnelling:

```bash
# VNC port = spice_port (e.g. 5900 → VNC display :0)
vncviewer localhost:5900

# Forward over SSH:
ssh -L 5900:localhost:5900 user@host
vncviewer localhost:5900
```

Install a VNC client: `sudo apt install tigervnc-viewer` or use Remmina, RealVNC, or any VNC-compatible client.

| Method | Port | Client | Best for |
|---|---|---|---|
| SPICE | `spice_port` | `virt-viewer` / `remote-viewer` | Performance, clipboard |
| VNC | `spice_port` | Any VNC viewer | Maximum compatibility, SSH tunnels |

---

## virt-manager / libvirt

Generate a libvirt XML domain definition:

```bash
# Generate XML (no virsh required)
android-vm virt-manager

# Generate and immediately register with libvirt
android-vm virt-manager --define

# Generate, register, and start
android-vm virt-manager pixel6a-bp1a --vm-profile performance --define --start

# Override hardware settings
android-vm virt-manager --ram 6144 --cores 4 --no-spice

# Direct script usage with custom output path
bash scripts/gen-libvirt-xml.sh pixel6a-bp1a --vm-profile balanced --output /tmp/android.xml
```

The XML is written to `run/<profile>.xml`. To import manually:

```bash
virsh define run/pixel6a-bp1a.xml
virsh start android-pixel6a-bp1a
# OR: open virt-manager → File → New VM → Import existing disk image
```

Install libvirt tools: `sudo apt install virt-manager libvirt-clients`.

---

## Prerequisites

```bash
# Ubuntu / Debian
sudo apt install qemu-system-x86 qemu-utils qemu-kvm android-tools-adb \
                 e2fsprogs parted grub-efi-amd64-bin \
                 simg2img python3 python3-pip jq curl rsync p7zip-full
pip3 install jsonschema flask
```

### Env var overrides (for the curl pipe case)

| Env var | Flag equivalent | Description |
|---|---|---|
| `ANDROID_VM_PROFILE` | `--profile` | Profile name to apply |
| `ANDROID_VM_DIR` | `--dir` | Workspace directory |
| `ANDROID_VM_REPO` | `--repo` | Git repo URL to clone |
| `ANDROID_VM_BOOT` | `--boot` | Set to any value to launch VM after build |
| `ANDROID_VM_NO_DL` | `--no-download` | Build intermediate locally instead of downloading |
| `ANDROID_VM_SKIP_VFY` | `--skip-verify` | Skip ADB verification step |

---

## Workspace Layout

```
workspace/
├── android-vm              # Unified CLI (symlinked to /usr/local/bin)
├── install.sh              # One-liner installer
├── androiddistro/          # Per-distro build configs (bliss14.json, sakura.json, …)
├── intermediate/           # Per-distro base images (built by CI or fetch-distro.sh)
├── builds/                 # Legacy per-profile artifacts
├── instances/              # Per-instance configs + disks  ← primary runtime state
│   ├── <name>.json             # Instance config (ports, profiles, distro, timestamps)
│   └── <name>/disk.qcow2       # Instance disk (qcow2 overlay over intermediate)
├── gui/                    # Flask web UI
│   ├── app.py
│   ├── templates/          # Jinja2 templates (base, index, new, detail)
│   └── static/             # CSS
├── run/                    # Runtime PID files, QMP sockets, serial logs
├── cache/                  # Download cache (ISOs, split archive parts — gitignored)
├── config/
│   ├── defaults.json           # Default profiles, ports, and GUI settings
│   ├── device-spoof.json       # Device identity spoofing settings
│   └── vm-profiles/
│       ├── performance.json    # 6 GB RAM, 6 cores, virtio-vga-gl
│       ├── balanced.json       # 4 GB RAM, 4 cores, virtio-vga-gl (default)
│       ├── compatibility.json  # 2 GB RAM, 2 cores, virtio-vga-gl
│       └── lowram.json         # 2 GB RAM, 2 cores, virtio-vga-gl
├── profiles/               # JSON device identity profiles
│   ├── schema.json
│   ├── generic.json
│   ├── pixel6a-bp1a.json
│   ├── pixel7-ap1a.json
│   └── samsung-s23-eu.json
├── scripts/
│   ├── set-profile.sh          # Create per-instance disk (calls fetch-distro.sh)
│   ├── boot.sh                 # Launch VM in QEMU/KVM
│   ├── verify.sh               # ADB-based identity verification
│   ├── gen-libvirt-xml.sh      # Generate libvirt domain XML
│   └── lib/
│       ├── alloc-nbd.sh        # Serialised /dev/nbdN allocator (flock-protected)
│       ├── alloc-port.sh       # Free TCP port finder (Python socket bind)
│       ├── instance.sh         # Instance config helpers (create/delete/list/…)
│       ├── fetch-distro.sh     # Download ISO + build intermediate qcow2
│       ├── fetch-release.sh    # GitHub API downloader (split-archive aware)
│       ├── patch-props.py      # Deterministic build.prop patcher
│       ├── profile-validator.py# JSON schema + consistency checks
│       ├── inject-gapps.sh     # GApps offline injection
│       ├── inject-arm-trans.sh # ARM translation lib injection
│       └── fetch-arm-trans.sh  # Download libndk_translation
├── gapps/              # Place MindTheGapps-11.0.0-x86_64-*.zip here
├── arm-trans/          # libndk_translation (auto-fetched if absent)
└── logs/
```

---

## Image Strategy

**qcow2 backing chain** — only the per-instance layer stores diffs:

```
intermediate/<distro>-base.qcow2      (built from the distro ISO by fetch-distro.sh)
         ↓ backing-file
instances/<name>/disk.qcow2           (+ identity props; one per instance)
```

Each disk uses a **3-partition GPT layout**:

| Partition | Label | FS | Size | Contents |
|---|---|---|---|---|
| p1 (ESP) | — | FAT32 | 256 MiB | `EFI/BOOT/BOOTX64.EFI` (GRUB EFI stub) |
| p2 | BlissOS | ext4 | ISO content + overhead | `android/` (kernel, initrd, system.sfs, …) + `grub/grub.cfg` |
| p3 | Userdata | ext4 | 8 GiB default | Android userdata (expandable via `instance expand`) |

---

## Profile System

Each device profile is a JSON file defining identity props for `system` and `vendor` partitions. The patcher replaces matching keys in `build.prop` and appends any that are absent.

```bash
# Validate a profile
python3 scripts/lib/profile-validator.py profiles/pixel6a-bp1a.json

# Apply a profile and verify
bash scripts/set-profile.sh my-instance --rebuild --check
```

See `profiles/schema.json` for the full schema and prohibited key list.

---

## ARM Translation

`libndk_translation` enables ARM apps on the x86_64 VM. Enable it in the distro config:

```json
// androiddistro/bliss14.json
"inject_arm_trans": true
```

Required vendor props set automatically when enabled:
```
ro.dalvik.vm.native.bridge=libndk_translation.so
ro.enable.native.bridge.exec=1
ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
```

---

## Multiple Distros

The `androiddistro/` directory contains per-distro JSON configs that control the build pipeline. Three distros are included:

| Slug | Name | GApps | Source |
|---|---|---|---|
| `bliss14` | BlissOS 14 | ✗ (FOSS) | SourceForge (auto-latest) |
| `bliss15` | BlissOS 15 | ✗ (FOSS) | SourceForge (auto-latest) |
| `sakura` | Project Sakura FOSS | ✗ (FOSS) | SourceForge (direct) |

### Using Project Sakura

Sakura is a FOSS build with no GApps pre-installed. Requires virgl (host OpenGL) for full GPU acceleration.

**Option A — download from CI** (if a `sakura-base-*` release exists):
```bash
git pull && android-vm update
```

**Option B — build locally** (~30–90 min):
```bash
bash scripts/lib/fetch-distro.sh sakura
```

Then create an instance:
```bash
android-vm instance create my-sakura --profile pixel6a-bp1a --vm-profile balanced --distro sakura
bash scripts/set-profile.sh my-sakura
android-vm instance start my-sakura
```

### Switching between distros

Each instance disk is tied to the intermediate it was built from. To switch a profile from BlissOS to Sakura (or back), rebuild with the new distro:

```bash
bash scripts/set-profile.sh my-instance --distro sakura  --rebuild
# or back to BlissOS:
bash scripts/set-profile.sh my-instance --distro bliss14 --rebuild
```

The CI workflow builds all distros in parallel and publishes separate GitHub Releases. `android-vm update` downloads the latest of each automatically.

---

## Device Identity Spoofing

`config/device-spoof.json` controls the prop-patching behaviour of `set-profile.sh`:

| Field | Default | Effect |
|---|---|---|
| `enabled` | `true` | Master toggle — set `false` to skip all prop patching |
| `default_profile` | `generic` | Default device profile when none is given on the CLI |
| `patch_partitions` | `["system","vendor","product"]` | Which partitions to patch |
| `verify_after_build` | `false` | Auto-run `verify.sh` after every `set-profile.sh` build |
| `leak_scan_tokens` | `["generic_x86",…]` | Tokens `verify.sh` searches for in `getprop` output |

**Default device profile precedence** (when no profile is given on the command line):

1. `config/device-spoof.json` → `default_profile` (if set)
2. `config/defaults.json` → `default_device_profile`

`android-vm doctor` prints the effective default and which file supplied it.

---

## CI

`.github/workflows/build-base.yml` builds each distro's intermediate image on standard GitHub-hosted runners (offline NBD mount + file injection — no KVM required) and publishes it as a GitHub Release. Steps include:

- Extract distro ISO with 7z
- Generate `grub.cfg` with `linuxefi`/`initrdefi` entries
- Build `BOOTX64.EFI` with `grub-mkstandalone` (modules: `part_gpt fat ext2 search search_label configfile linux linuxefi normal echo serial terminal`)
- Assemble 3-partition GPT disk (ESP + BlissOS + Userdata) and convert to compressed qcow2

The optional boot smoke-test (`smoke-test` job) runs only on self-hosted KVM runners (`self-hosted, linux, kvm`).

---

## Troubleshooting

**QEMU exits immediately at startup**

All VM profiles use `gtk,gl=on` (host OpenGL required). If your host has no GL driver or no display, QEMU will exit silently. Fix:
- Ensure a display (`$DISPLAY`) is set, or start the VM via the GUI which uses `--headless`.
- Install Mesa: `sudo apt install libgl1-mesa-glx`.
- Or edit the vm-profile JSON to `"gpu": "std"` and `"display": "sdl"` for software rendering.

**Debug mode: serial works but display is black**

Normal for the standard (non-debug) GRUB menu entry. The framebuffer console only activates when `console=tty0` is in the kernel command line. The **BlissOS (debug)** GRUB entry adds it; use that entry when you need both serial and framebuffer output simultaneously.

**ADB not connecting**

The VM takes ~60 seconds to boot to the Android launcher on first run. Check the allocated port:
```bash
android-vm instance show my-android   # → adb_port: 5555
adb connect localhost:5555
adb wait-for-device && adb shell
```

**ARM apps crash or fail to install**

ARM translation (libndk_translation) must be injected at disk-build time. Set `"inject_arm_trans": true` in the distro JSON (e.g. `androiddistro/bliss14.json`) and rebuild the disk:
```bash
bash scripts/set-profile.sh my-android --rebuild
```

**"no free /dev/nbdN device" during disk build**

The NBD allocator searches up to 16 devices. If all are in use (parallel builds or leaked connections), disconnect stale ones:
```bash
for i in $(seq 0 15); do sudo qemu-nbd --disconnect /dev/nbd$i 2>/dev/null; done
```

---

## Known Limitations

- **Play Integrity**: `BASIC_INTEGRITY` at best. Hardware attestation (KeyMint) cannot be satisfied in a VM.
- **Widevine**: L3 only on x86 VMs. Streaming apps may downgrade video quality.
- **Google sign-in**: Requires network access on first boot.
- **Host OpenGL**: All current VM profiles require host GL (`virtio-vga-gl`). Software rendering fallback requires manual profile edits.
