#!/usr/bin/env bash
# blissos-stage.sh  (v7)
# ----------------------
# Fetch a BlissOS ISO from SourceForge, build two VM disks following the
# SAME process as the Bliss AUTO_INSTALL installer (init script Path 1):
#
#   system.sfs is kept intact — init loop-mounts it at boot:
#     mount -o loop system.sfs android
#     mount -o loop android/system.img android   (nested)
#
#   No extraction, no directory juggling, no vendor symlink hacks.
#   This is exactly what do_install copies to a real target partition.
#
#   blissos-system.{img,qcow2}   GPT: ESP + ext4 holding kernel/initrd/system.sfs
#   blissos-userdata.{img,qcow2} labeled ext4 with /data subdir

set -euo pipefail
export PATH="$PATH:/sbin:/usr/sbin"
# ============================================================================
# Defaults
# ============================================================================
ISO_URL="https://sourceforge.net/projects/blissos-x86/files/Official/BlissOS14/FOSS/Generic/Bliss-v14.10.3-x86_64-OFFICIAL-foss-20241012.iso/download"
ISO_FILE=""
WORKDIR="$(pwd)/blissos-work"
OUTDIR="$(pwd)/blissos-stage"
DATA_SIZE_GB=16
SYSTEM_MIN_GB=4
SRC_DIR_NAME="Bliss"
DATA_LABEL="BlissData"
DATA_DEV="vdb"               # block device name for userdata disk inside the VM
SYS_LABEL="bliss"
FINALIZE=""              # "" = ask interactively | img | qcow2
LATEST_MODE=""           # "yes" if --latest
LATEST_VARIANT=""        # bliss14 | bliss15 | bliss16 | sakura
NO_DEPS="no"             # --no-deps disables auto-install
AUTO_YES="no"            # -y / --yes skips the install prompt
PATCH_DISK="no"          # --patch-disk patches grub.cfg on existing disk only
SYS_DISK_OVERRIDE=""     # --sys-disk overrides system disk path for --patch-disk

usage() {
    cat <<EOF
Usage: $0 [options]

Sources (mutually exclusive; the last one wins):
  --iso-url URL         Pin to a specific URL (default: Bliss 14.10.3 FOSS x86_64)
                        Any SourceForge /download URL is auto-rewritten to direct CDN.
  --iso-file PATH       Skip download; use a local ISO.
  --latest [VARIANT]    Resolve newest dated ISO from SourceForge.
                          bliss14 (default) — Official/BlissOS14/FOSS/Generic
                          bliss15           — Official/BlissOS15/FOSS/Generic
                          bliss16           — Official/BlissOS16/FOSS/Generic
                          sakura            — projectsakura/x86_64 (FOSS builds)

Output:
  --workdir DIR         Scratch dir (default: ./blissos-work)
  --output  DIR         Output dir (default: ./blissos-stage)
  --finalize FMT        img|qcow2 — skip the interactive format prompt
  --data-size N         Userdata size in GB; 0 to skip (default: 16)
  --system-size N       Minimum system.img size in GB on repack (default: 4)
  --src-name NAME       Sub-directory name on target partition (default: Bliss)
  --data-label LABEL    Userdata partition/disk label (default: BlissData)
  --data-dev   DEV      Block device name for userdata inside the VM (default: vdb)
  --sys-label  LABEL    System partition label (default: bliss)

Deps:
  --no-deps             Don't auto-install missing dependencies.
  -y, --yes             Skip the install-confirmation prompt.

Maintenance:
  --patch-disk          Patch grub.cfg on the existing system disk only.
                        Skips ISO download/staging/disk rebuild entirely.
                        Use after changing kernel params without re-staging.
  --sys-disk PATH       Override system disk path for --patch-disk.
                        Default: \$OUTDIR/blissos-system.{img,qcow2}

  -h, --help            This help.

Examples:
  $0 --latest --finalize qcow2          # Newest Bliss 14 FOSS, two qcow2 disks
  $0 --latest bliss15 --finalize qcow2  # Newest Bliss 15 FOSS
  $0 --latest sakura --finalize img     # Newest Project Sakura, raw .img
  $0 --iso-file ~/iso/x.iso             # Stage from local ISO, no VM build
  $0 --patch-disk                       # Fix grub.cfg on existing disk only
  $0 --patch-disk --sys-disk /path/to/blissos-system.img  # Fix arbitrary disk
EOF
}

# ============================================================================
# Arg parsing
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso-url)    ISO_URL="$2"; LATEST_MODE=""; shift 2 ;;
        --iso-file)   ISO_FILE="$2"; ISO_URL=""; LATEST_MODE=""; shift 2 ;;
        --latest)
            LATEST_MODE="yes"
            if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
                LATEST_VARIANT="$2"; shift 2
            else
                LATEST_VARIANT="bliss14"; shift
            fi
            ISO_URL=""   # will be filled in by resolve_latest
            ;;
        --workdir)     WORKDIR="$2"; shift 2 ;;
        --output)      OUTDIR="$2"; shift 2 ;;
        --data-size)   DATA_SIZE_GB="$2"; shift 2 ;;
        --system-size) SYSTEM_MIN_GB="$2"; shift 2 ;;
        --src-name)    SRC_DIR_NAME="$2"; shift 2 ;;
        --data-label)  DATA_LABEL="$2"; shift 2 ;;
        --data-dev)    DATA_DEV="$2"; shift 2 ;;
        --sys-label)   SYS_LABEL="$2"; shift 2 ;;
        --finalize)    FINALIZE="$2"; shift 2 ;;
        --no-deps)     NO_DEPS="yes"; shift ;;
        -y|--yes)      AUTO_YES="yes"; shift ;;
        --patch-disk)  PATCH_DISK="yes"; shift ;;
        --sys-disk)    SYS_DISK_OVERRIDE="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

case "$FINALIZE" in ""|img|qcow2) ;; *) echo "--finalize must be img or qcow2" >&2; exit 1 ;; esac

# ============================================================================
# Helpers
# ============================================================================
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# https://sourceforge.net/projects/X/files/PATH/download  ->  https://downloads.sourceforge.net/project/X/PATH
rewrite_sf_url() {
    local url="$1"
    if [[ "$url" =~ ^https://sourceforge\.net/projects/([^/]+)/files/(.+)/download/?$ ]]; then
        printf 'https://downloads.sourceforge.net/project/%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf '%s\n' "$url"
    fi
}

# ============================================================================
# Package mapping (tool -> distro package, space-separated for multi-package)
# ============================================================================
declare -gA PKG_apt=(
    [7z]="p7zip-full"
    [unsquashfs]="squashfs-tools"
    [mkfs.ext4]="e2fsprogs"
    [debugfs]="e2fsprogs"
    [e2fsck]="e2fsprogs"
    [file]="file"
    [curl]="curl"
    [python3]="python3"
    [simg2img]="android-sdk-libsparse-utils"
    [qemu-img]="qemu-utils"
    [parted]="parted"
    [mkfs.vfat]="dosfstools"
    [grub-mkstandalone]="grub-common grub-efi-amd64-bin"
    [zstdcat]="zstd"
)
declare -gA PKG_dnf=(
    [7z]="p7zip-plugins"
    [unsquashfs]="squashfs-tools"
    [mkfs.ext4]="e2fsprogs"
    [debugfs]="e2fsprogs"
    [e2fsck]="e2fsprogs"
    [file]="file"
    [curl]="curl"
    [python3]="python3"
    [simg2img]="android-tools"
    [qemu-img]="qemu-img"
    [parted]="parted"
    [mkfs.vfat]="dosfstools"
    [grub-mkstandalone]="grub2-tools grub2-efi-x64-modules"
    [zstdcat]="zstd"
)
declare -gA PKG_pacman=(
    [7z]="p7zip"
    [unsquashfs]="squashfs-tools"
    [mkfs.ext4]="e2fsprogs"
    [debugfs]="e2fsprogs"
    [e2fsck]="e2fsprogs"
    [file]="file"
    [curl]="curl"
    [python3]="python"
    [simg2img]="android-tools"
    [qemu-img]="qemu-img"
    [parted]="parted"
    [mkfs.vfat]="dosfstools"
    [grub-mkstandalone]="grub edk2-ovmf"
    [zstdcat]="zstd"
)
declare -gA PKG_zypper=(
    [7z]="p7zip-full"
    [unsquashfs]="squashfs"
    [mkfs.ext4]="e2fsprogs"
    [debugfs]="e2fsprogs"
    [e2fsck]="e2fsprogs"
    [file]="file"
    [curl]="curl"
    [python3]="python3"
    [simg2img]="android-tools"
    [qemu-img]="qemu-tools"
    [parted]="parted"
    [mkfs.vfat]="dosfstools"
    [grub-mkstandalone]="grub2 grub2-x86_64-efi"
    [zstdcat]="zstd"
)

detect_pkgmgr() {
    if   command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf     >/dev/null 2>&1; then echo dnf
    elif command -v pacman  >/dev/null 2>&1; then echo pacman
    elif command -v zypper  >/dev/null 2>&1; then echo zypper
    else echo unknown
    fi
}

# Install missing deps (interactively unless -y or non-tty). Required vs.
# recommended is decided by what the run actually needs (download / latest /
# finalize all bump the required set).
maybe_install_deps() {
    local -a required=() recommended=()
    local t

    for t in 7z unsquashfs mkfs.ext4 file find awk; do
        command -v "$t" >/dev/null 2>&1 || required+=("$t")
    done

    if [[ -n "$ISO_URL" || "$LATEST_MODE" == "yes" ]]; then
        command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || required+=("curl")
    fi

    if [[ "$LATEST_MODE" == "yes" ]]; then
        command -v python3 >/dev/null 2>&1 || required+=("python3")
    fi

    # Always need finalize deps — we always build VM disks
    for t in qemu-img parted mkfs.vfat grub-mkstandalone losetup; do
            command -v "$t" >/dev/null 2>&1 || required+=("$t")
    done

    command -v simg2img >/dev/null 2>&1 || recommended+=("simg2img")

    if (( ${#required[@]} == 0 && ${#recommended[@]} == 0 )); then
        log "All dependencies satisfied"
        return 0
    fi

    (( ${#required[@]}    > 0 )) && log    "Missing required:    ${required[*]}"
    (( ${#recommended[@]} > 0 )) && warn   "Missing recommended: ${recommended[*]}"

    if [[ "$NO_DEPS" == "yes" ]]; then
        (( ${#required[@]} > 0 )) && die "Required tools missing and --no-deps set"
        warn "Continuing without recommended tools (--no-deps)"
        return 0
    fi

    local pkgmgr
    pkgmgr=$(detect_pkgmgr)
    if [[ "$pkgmgr" == "unknown" ]]; then
        (( ${#required[@]} > 0 )) && die "Required tools missing; install manually (no supported package manager: apt, dnf, pacman, zypper)"
        warn "Continuing without recommended tools (no supported package manager)"
        return 0
    fi

    # Resolve tool -> package(s). Use a nameref to the right associative array.
    declare -n pkg_map="PKG_$pkgmgr"
    local -a pkgs=()
    for t in "${required[@]}" "${recommended[@]}"; do
        local mapped="${pkg_map[$t]:-}"
        if [[ -z "$mapped" ]]; then
            warn "No package mapping for '$t' on $pkgmgr — you may need to install it manually"
            continue
        fi
        # Multi-package entries are space-separated; word-split here is intentional
        for p in $mapped; do pkgs+=("$p"); done
    done

    if (( ${#pkgs[@]} == 0 )); then
        return 0
    fi

    # Dedup
    local -a unique_pkgs=()
    while IFS= read -r p; do unique_pkgs+=("$p"); done < <(printf '%s\n' "${pkgs[@]}" | sort -u)

    log "Will install via $pkgmgr: ${unique_pkgs[*]}"

    if [[ "$AUTO_YES" != "yes" ]] && [[ -t 0 ]]; then
        local ans
        read -rp "Proceed? [Y/n] " ans
        if [[ "$ans" =~ ^[Nn] ]]; then
            (( ${#required[@]} > 0 )) && die "Aborted by user"
            warn "Skipping recommended-tools install"
            return 0
        fi
    fi

    case "$pkgmgr" in
        apt)
            sudo apt-get update -qq || warn "apt-get update failed; trying install anyway"
            sudo apt-get install -y --no-install-recommends "${unique_pkgs[@]}"
            ;;
        dnf)
            sudo dnf install -y "${unique_pkgs[@]}"
            ;;
        pacman)
            sudo pacman -Sy --needed --noconfirm "${unique_pkgs[@]}"
            ;;
        zypper)
            sudo zypper --non-interactive install "${unique_pkgs[@]}"
            ;;
    esac

    # Verify required tools are now present
    local -a still=()
    for t in "${required[@]}"; do
        command -v "$t" >/dev/null 2>&1 || still+=("$t")
    done
    if (( ${#still[@]} > 0 )); then
        die "Still missing after install (package mapping wrong on $pkgmgr?): ${still[*]}"
    fi
    log "Dependencies satisfied"
}

# ============================================================================
# Latest-ISO resolver (port of Chr0mX/androidVM resolve-blissos-url.py)
# ============================================================================
resolve_latest() {
    local variant="$1"
    local project path filter
    case "$variant" in
        bliss14) project="blissos-x86"   path="Official/BlissOS14/FOSS/Generic" filter=".iso" ;;
        bliss15) project="blissos-x86"   path="Official/BlissOS15/FOSS/Generic" filter=".iso" ;;
        bliss16) project="blissos-x86"   path="Official/BlissOS16/FOSS/Generic" filter=".iso" ;;
        sakura)  project="projectsakura" path="x86_64"                          filter="FOSS" ;;
        *) die "Unknown --latest variant: '$variant' (expected: bliss14, bliss15, bliss16, sakura)" ;;
    esac

    log "Resolving newest $variant ISO from sourceforge.net/projects/$project/files/$path"

    local result
    result=$(SF_PROJECT="$project" SF_PATH="$path" SF_FILTER="$filter" python3 - <<'PYEOF'
"""
Scrape a SourceForge directory listing, find ISO downloads matching a filter,
pick the newest by embedded YYYYMMDD date, rewrite the /download URL to the
direct CDN form.
"""
import os, re, sys, urllib.request, urllib.error

project    = os.environ["SF_PROJECT"]
path       = os.environ["SF_PATH"].strip("/")
filter_str = os.environ.get("SF_FILTER", ".iso")

url = f"https://sourceforge.net/projects/{project}/files/{path}/"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 blissos-stage"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        html = r.read().decode("utf-8", errors="replace")
except urllib.error.HTTPError as e:
    sys.exit(f"SourceForge HTTP {e.code} for {url}")
except urllib.error.URLError as e:
    sys.exit(f"SourceForge unreachable: {e.reason}")

HREF_RE     = re.compile(r'href="(https://sourceforge\.net/projects/[^"]+?/files/[^"]+?/([^"/]+\.iso)/download)"')
DATE_RE     = re.compile(r"-(\d{8})\.iso$", re.IGNORECASE)
REDIRECT_RE = re.compile(r"https://sourceforge\.net/projects/([^/]+)/files/(.*)/download$")

cands, seen = [], set()
for m in HREF_RE.finditer(html):
    dl_url, name = m.group(1), m.group(2)
    if name in seen or filter_str.lower() not in name.lower():
        continue
    seen.add(name)
    d = DATE_RE.search(name)
    cands.append((d.group(1) if d else "", name, dl_url))

if not cands:
    sys.exit(f"No files matching '{filter_str}' under {url}")

cands.sort(key=lambda t: t[0], reverse=True)
_date, name, dl = cands[0]

rm = REDIRECT_RE.match(dl)
if rm:
    dl = f"https://downloads.sourceforge.net/project/{rm.group(1)}/{rm.group(2)}"

print(f"url={dl}")
print(f"filename={name}")
print(f"candidates_found={len(cands)}", file=sys.stderr)
PYEOF
    ) || die "Latest-ISO resolution failed (see error above)"

    ISO_URL=$(printf '%s\n' "$result" | sed -n 's/^url=//p')
    local resolved_name
    resolved_name=$(printf '%s\n' "$result" | sed -n 's/^filename=//p')

    [[ -n "$ISO_URL" ]] || die "Resolver returned no URL"
    log "Newest: $resolved_name"
}

# ============================================================================
# patch_existing_disk — rewrite grub.cfg on an already-built system disk.
# Strips stale GRALLOC/HWC overrides and injects HWC=drm_minigbm (virgl fix).
# Called by --patch-disk for a quick fix without re-staging or rebuilding.
# ============================================================================
patch_existing_disk() {
    local fmt="${1:-img}"
    [[ "$fmt" == "qcow2" ]] && local ext="qcow2" || local ext="img"
    local sys_disk="${SYS_DISK_OVERRIDE:-$OUTDIR/blissos-system.$ext}"

    [[ -f "$sys_disk" ]] || die "System disk not found: $sys_disk"
    log "Patching grub.cfg on $sys_disk"

    local mnt loop
    mnt=$(mktemp -d /tmp/grub-patch.XXXXXX)
    loop=$(sudo losetup --find --show --partscan "$sys_disk")

    cleanup_patch() {
        sudo umount "$mnt" 2>/dev/null || true
        sudo losetup -d "$loop"  2>/dev/null || true
        rmdir "$mnt"             2>/dev/null || true
    }
    trap cleanup_patch RETURN

    sudo mount "${loop}p2" "$mnt"

    local grub_cfg="$mnt/grub/grub.cfg"
    [[ -f "$grub_cfg" ]] || die "grub.cfg not found at $grub_cfg"

    sudo sed -i \
        -e 's/ GRALLOC=[^ \\]*//g' \
        -e 's/ HWC=[^ \\]*//g' \
        -e 's/androidboot\.hardware=android_x86_64 \\/androidboot.hardware=android_x86_64 HWC=drm_minigbm GRALLOC=minigbm \\/g' \
        "$grub_cfg"

    log "Updated kernel lines:"
    grep 'linux ' "$grub_cfg" | sed 's/^/    /'

    sync
    sudo umount "$mnt"
    sudo losetup -d "$loop"
    trap - RETURN
    rmdir "$mnt"
    log "grub.cfg patched."
}


# --patch-disk: fix grub.cfg on existing disk without touching ISO or staging
if [[ "$PATCH_DISK" == "yes" ]]; then
    if   [[ -n "$SYS_DISK_OVERRIDE" ]]; then
        [[ "$SYS_DISK_OVERRIDE" == *.qcow2 ]] && _pfmt="qcow2" || _pfmt="img"
    elif [[ -f "$OUTDIR/blissos-system.qcow2" ]]; then _pfmt="qcow2"
    elif [[ -f "$OUTDIR/blissos-system.img"   ]]; then _pfmt="img"
    else die "No system disk found in $OUTDIR — use --sys-disk PATH or build one first"
    fi
    patch_existing_disk "$_pfmt"
    echo "Reboot the VM to apply."
    exit 0
fi

# ============================================================================
# Phase 1: deps & latest resolution
# ============================================================================
maybe_install_deps

if [[ "$LATEST_MODE" == "yes" ]]; then
    resolve_latest "$LATEST_VARIANT"
fi

if [[ -n "$ISO_URL" ]]; then
    if   command -v curl >/dev/null 2>&1; then DL=(curl -L --fail --retry 5 --retry-delay 10 --retry-max-time 600 -C - -o)
    elif command -v wget >/dev/null 2>&1; then DL=(wget -c -O)
    else die "Need curl or wget to download the ISO"
    fi
fi

mkdir -p "$WORKDIR" "$OUTDIR"

# ============================================================================
# Phase 2: download
# ============================================================================
if [[ -n "$ISO_URL" ]]; then
    ORIG_URL="$ISO_URL"
    ISO_URL="$(rewrite_sf_url "$ISO_URL")"
    [[ "$ISO_URL" != "$ORIG_URL" ]] && log "Rewrote SourceForge URL to direct CDN form"

    ISO_FILE="$WORKDIR/$(basename "${ISO_URL%%\?*}")"
    if [[ -s "$ISO_FILE" ]] && file "$ISO_FILE" | grep -qi 'ISO 9660\|CD-ROM'; then
        log "ISO already present at $ISO_FILE — skipping download"
    else
        [[ -f "$ISO_FILE" ]] && rm -f "$ISO_FILE"
        log "Downloading: $ISO_URL"
        "${DL[@]}" "$ISO_FILE" "$ISO_URL"
    fi
fi
[[ -s "$ISO_FILE" ]] || die "ISO not found or empty: $ISO_FILE"

file "$ISO_FILE" | grep -qi 'ISO 9660\|CD-ROM' \
    || die "Downloaded file is not a valid ISO (got: $(file -b "$ISO_FILE"))"

log "Using ISO: $ISO_FILE ($(du -h "$ISO_FILE" | awk '{print $1}'))"

# ============================================================================
# Phase 3: extract boot bits + partition images from ISO
# ============================================================================
EXTRACT_DIR="$WORKDIR/iso"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

log "Pulling kernel / initrd / system / vendor / product / *.cfg from ISO..."
7z x -y -bb0 -o"$EXTRACT_DIR" "$ISO_FILE" \
    'kernel' 'initrd.img' 'ramdisk.img' 'install.img' \
    'system.sfs' 'system.img' \
    'vendor.sfs' 'vendor.img' \
    'product.sfs' 'product.img' \
    '*.cfg' -r >/dev/null

find "$EXTRACT_DIR" -mindepth 2 -type f \
    \( -name kernel -o -name initrd.img -o -name ramdisk.img -o -name install.img \
       -o -name system.sfs  -o -name system.img \
       -o -name vendor.sfs  -o -name vendor.img \
       -o -name product.sfs -o -name product.img \) \
    -exec mv -n {} "$EXTRACT_DIR/" \;
# Consolidate cfg files into a dedicated subdir (avoids name collisions)
mkdir -p "$EXTRACT_DIR/_cfg"
find "$EXTRACT_DIR" -mindepth 2 -type f -name '*.cfg' -exec mv -n {} "$EXTRACT_DIR/_cfg/" \;
find "$EXTRACT_DIR" -mindepth 1 -type d -empty -delete

[[ -f "$EXTRACT_DIR/kernel"     ]] || die "kernel not found in ISO"
[[ -f "$EXTRACT_DIR/initrd.img" ]] || die "initrd.img not found in ISO"
log "Found: $(ls "$EXTRACT_DIR" | tr '\n' ' ')"
[[ -d "$EXTRACT_DIR/_cfg" ]] && log "  cfg files: $(ls "$EXTRACT_DIR/_cfg" 2>/dev/null | tr '\n' ' ')"

# ============================================================================
# Phase 4: verify system.sfs (keep it intact — init loop-mounts it at boot)
#
# The Bliss installer's do_install copies system.sfs as-is to the target
# partition. The init handles all loop-mounting (Path 1):
#   mount -o loop system.sfs android        <- mounts squashfs
#   mount -o loop android/system.img android <- mounts nested raw ext4
#
# No extraction, no simg2img, no directory tricks needed.
# ============================================================================
[[ -f "$EXTRACT_DIR/system.sfs" ]] \
    || die "system.sfs not found in ISO — this ISO may require a different layout"

log "system.sfs: $(du -h "$EXTRACT_DIR/system.sfs" | awk '{print $1}')"

# ============================================================================
# Phase 5: stage files (mirrors what do_install copies to a target partition)
# ============================================================================
STAGE="$OUTDIR/$SRC_DIR_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

for f in kernel initrd.img ramdisk.img install.img system.sfs \
         vendor.sfs vendor.img product.sfs product.img; do
    [[ -f "$EXTRACT_DIR/$f" ]] && cp -f "$EXTRACT_DIR/$f" "$STAGE/" \
        && log "  staged: $f ($(du -h "$EXTRACT_DIR/$f" | awk '{print $1}'))"
done

# Stub scripts for functions the init calls that are absent from the ISO's
# initrd.img — prevents "not found" errors in DEBUG mode and makes intent explicit.
# detect_hardware returning 1 tells init to fall through to auto_detect.
mkdir -p "$STAGE/scripts"
printf 'setup_dpi() { :; }\n'                                   > "$STAGE/scripts/4-dpi"
printf 'detect_hardware() { return 1; }\npost_detect() { :; }\n' > "$STAGE/scripts/5-post"

log "Staged into $STAGE:"
ls -lh "$STAGE" | awk 'NR>1 {printf "    %-16s  %s\n", $9, $5}'

# ============================================================================
# Extract original kernel cmdline from the ISO's android.cfg / grub.cfg.
# Strips params we own (SRC, DATA, BOOT_IMAGE, iso-scan, quiet) so we can
# inject them cleanly. Works for any ISO regardless of name/version.
# ============================================================================
extract_iso_base_params() {
    local cfg line
    for cfg in "$EXTRACT_DIR/_cfg/android.cfg" "$EXTRACT_DIR/_cfg/grub.cfg" \
               "$EXTRACT_DIR/_cfg"/*.cfg; do
        [[ -f "$cfg" ]] || continue
        line=$(awk '
            /^[[:space:]]*menuentry/ { in_entry = 1; next }
            in_entry && /^[[:space:]]*linux[[:space:]]/ {
                sub(/^[[:space:]]*linux[[:space:]]+[^[:space:]]+[[:space:]]*/, "")
                print
                exit
            }
        ' "$cfg")
        [[ -n "$line" ]] || continue
        echo "$line" | sed -E "
            s#(^|[[:space:]])SRC=[^ ]+##g
            s#(^|[[:space:]])DATA=[^ ]+##g
            s#(^|[[:space:]])BOOT_IMAGE=[^ ]+##g
            s#(^|[[:space:]])iso-scan/filename=[^ ]+##g
            s#(^|[[:space:]])quiet([[:space:]]|\$)#\1\2#g
            s#[[:space:]]+# #g
            s#^[[:space:]]+##
            s#[[:space:]]+\$##
        "
        return 0
    done
    return 1
}

if ISO_BASE=$(extract_iso_base_params) && [[ -n "$ISO_BASE" ]]; then
    log "Base cmdline (from ISO): $ISO_BASE"
else
    ISO_BASE="root=/dev/ram0 androidboot.selinux=permissive androidboot.hardware=android_x86_64"
    warn "No android.cfg found in ISO — using hardcoded fallback cmdline"
fi

cat > "$OUTDIR/grub.cfg.snippet" <<EOF
# --- BlissOS / Sakura (Path 1: system.sfs installer layout) ---
# Base cmdline from ISO android.cfg; SRC/DATA/HWC layered on top.
# Entry 0 (default): swiftshader — works with any QEMU version
# Entry 1/2: virgl (HWC=drm_minigbm) — requires QEMU 7.0+ for +host_visible

serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input  serial console
terminal_output serial console

menuentry "BlissOS / Sakura" --class android {
    search --set=root --file /$SRC_DIR_NAME/kernel
    linux /$SRC_DIR_NAME/kernel $ISO_BASE \\
        SRC=$SRC_DIR_NAME DATA=$DATA_DEV HWC=swiftshader
    initrd /$SRC_DIR_NAME/initrd.img
}

menuentry "BlissOS / Sakura (virgl / QEMU 7.0+)" --class android {
    search --set=root --file /$SRC_DIR_NAME/kernel
    linux /$SRC_DIR_NAME/kernel $ISO_BASE \\
        SRC=$SRC_DIR_NAME DATA=$DATA_DEV HWC=drm_minigbm GRALLOC=minigbm
    initrd /$SRC_DIR_NAME/initrd.img
}

menuentry "BlissOS / Sakura (virgl debug / QEMU 7.0+)" --class android {
    search --set=root --file /$SRC_DIR_NAME/kernel
    linux /$SRC_DIR_NAME/kernel $ISO_BASE \\
        SRC=$SRC_DIR_NAME DATA=$DATA_DEV HWC=drm_minigbm GRALLOC=minigbm DEBUG=2 \\
        console=ttyS0,115200n8 console=tty0 \\
        androidboot.console=ttyS0 androidboot.debug=true
    initrd /$SRC_DIR_NAME/initrd.img
}
EOF

# ============================================================================
# Phase 6: choose output format then build both VM disks
# ============================================================================

# If --finalize was not set, ask now (after the slow work is done).
if [[ -z "$FINALIZE" ]]; then
    echo
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │          Choose VM disk format          │"
    echo "  ├─────────────────────────────────────────┤"
    echo "  │  1) img    — raw disk images (.img)     │"
    echo "  │             larger, no extra tools      │"
    echo "  │  2) qcow2  — QEMU native (.qcow2)       │"
    echo "  │             compressed, sparse, faster  │"
    echo "  └─────────────────────────────────────────┘"
    while true; do
        read -rp "  Format [1/2]: " _fmt_choice
        case "$_fmt_choice" in
            1|img)    FINALIZE="img";   break ;;
            2|qcow2)  FINALIZE="qcow2"; break ;;
            *) echo "  Please enter 1 (img) or 2 (qcow2)." ;;
        esac
    done
    echo
fi
build_system_disk() {
    local fmt="$1"
    local sysraw="$WORKDIR/blissos-system.raw"

    local stage_bytes esp_mb sys_mb total_mb
    stage_bytes=$(du -sb "$STAGE" | awk '{print $1}')
    esp_mb=256
    sys_mb=$(( (stage_bytes / 1024 / 1024) + 1536 ))
    total_mb=$(( esp_mb + sys_mb + 32 ))

    log "System disk: ${total_mb} MiB (ESP=${esp_mb}M, system=${sys_mb}M)"
    rm -f "$sysraw"
    truncate -s "${total_mb}M" "$sysraw"

    parted -s "$sysraw" \
        mklabel gpt \
        mkpart ESP fat32 1MiB "$((1 + esp_mb))MiB" \
        set 1 esp on \
        mkpart "$SYS_LABEL" ext4 "$((1 + esp_mb))MiB" 100%

    log "Loop-mounting (sudo) and laying down filesystems"
    local loop mnt_esp mnt_sys
    loop=$(sudo losetup --find --show --partscan "$sysraw")
    mnt_esp=$(mktemp -d)
    mnt_sys=$(mktemp -d)

    cleanup_sysbuild() {
        sudo umount "$mnt_esp" 2>/dev/null || true
        sudo umount "$mnt_sys" 2>/dev/null || true
        rmdir "$mnt_esp" "$mnt_sys" 2>/dev/null || true
        sudo losetup -d "$loop" 2>/dev/null || true
    }
    trap cleanup_sysbuild RETURN

    sudo mkfs.vfat -F32 -n EFI "${loop}p1" >/dev/null
    sudo mkfs.ext4 -F -L "$SYS_LABEL" "${loop}p2" >/dev/null

    sudo mount "${loop}p1" "$mnt_esp"
    sudo mount "${loop}p2" "$mnt_sys"

    log "Copying staged tree into system partition"
    sudo mkdir -p "$mnt_sys/$SRC_DIR_NAME"
    sudo cp -a "$STAGE/." "$mnt_sys/$SRC_DIR_NAME/"

    log "Writing /grub/grub.cfg on system partition"
    sudo mkdir -p "$mnt_sys/grub"
    sudo tee "$mnt_sys/grub/grub.cfg" >/dev/null <<GRUBEOF
set timeout=5
set default=0

$(cat "$OUTDIR/grub.cfg.snippet")
GRUBEOF

    log "Building standalone GRUB EFI (/EFI/BOOT/BOOTX64.EFI)"
    local stub
    stub=$(mktemp)
    cat > "$stub" <<EOF
search --set=root --label $SYS_LABEL
set prefix=(\$root)/grub
configfile /grub/grub.cfg
EOF
    sudo mkdir -p "$mnt_esp/EFI/BOOT"
    sudo grub-mkstandalone \
        --format=x86_64-efi \
        --output="$mnt_esp/EFI/BOOT/BOOTX64.EFI" \
        --locales="" --fonts="" \
        --modules="part_gpt fat ext2 search search_label configfile linux normal echo" \
        "boot/grub/grub.cfg=$stub"
    rm -f "$stub"

    sync
    sudo umount "$mnt_esp" "$mnt_sys"
    rmdir "$mnt_esp" "$mnt_sys"
    sudo losetup -d "$loop"
    trap - RETURN

    if [[ "$fmt" == "qcow2" ]]; then
        log "Converting system disk -> qcow2 (compressed)"
        qemu-img convert -f raw -O qcow2 -c "$sysraw" "$OUTDIR/blissos-system.qcow2"
        rm -f "$sysraw"
        SYS_OUT="$OUTDIR/blissos-system.qcow2"
    else
        mv -f "$sysraw" "$OUTDIR/blissos-system.img"
        SYS_OUT="$OUTDIR/blissos-system.img"
    fi
}

build_userdata_disk() {
    local fmt="$1"
    (( DATA_SIZE_GB > 0 )) || { warn "--data-size 0 — skipping userdata disk"; DATA_OUT=""; return 0; }

    local dataraw="$WORKDIR/blissos-userdata.raw"
    log "Userdata disk: ${DATA_SIZE_GB} GiB ext4, label=$DATA_LABEL"
    rm -f "$dataraw"
    truncate -s "${DATA_SIZE_GB}G" "$dataraw"
    mkfs.ext4 -F -L "$DATA_LABEL" "$dataraw" >/dev/null

    log "Creating /data inside userdata filesystem"
    if command -v debugfs >/dev/null 2>&1 \
        && echo "mkdir data" | sudo debugfs -w "$dataraw" >/dev/null 2>&1; then
        :
    else
        local mnt
        mnt=$(mktemp -d)
        sudo mount -o loop "$dataraw" "$mnt"
        sudo mkdir -p "$mnt/data"
        sudo umount "$mnt"
        rmdir "$mnt"
    fi

    if [[ "$fmt" == "qcow2" ]]; then
        log "Converting userdata disk -> qcow2 (sparse)"
        qemu-img convert -f raw -O qcow2 "$dataraw" "$OUTDIR/blissos-userdata.qcow2"
        rm -f "$dataraw"
        DATA_OUT="$OUTDIR/blissos-userdata.qcow2"
    else
        mv -f "$dataraw" "$OUTDIR/blissos-userdata.img"
        DATA_OUT="$OUTDIR/blissos-userdata.img"
    fi
}

SYS_OUT=""
DATA_OUT=""

build_system_disk   "$FINALIZE"
build_userdata_disk "$FINALIZE"

# ============================================================================
# Summary
# ============================================================================
log "Done."
echo
echo "Output files:"
[[ -f "$SYS_OUT"  ]] && echo "   System disk  : $SYS_OUT   ($(du -h "$SYS_OUT"  | awk '{print $1}') on disk)"
[[ -f "$DATA_OUT" ]] && echo "   Userdata disk: $DATA_OUT  ($(du -h "$DATA_OUT" | awk '{print $1}') on disk)"
echo

fmt_arg="$([[ "$FINALIZE" == "qcow2" ]] && echo qcow2 || echo raw)"
