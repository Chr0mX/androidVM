#!/usr/bin/env bash
# Download a distro ISO and build the intermediate qcow2 for use with set-profile.sh.
#
# Usage: fetch-distro.sh <distro-slug> [--force] [--gapps <zip>]
#
#   distro-slug      Name matching androiddistro/<slug>.json  (e.g. bliss14, sakura)
#   --force          Rebuild even if the intermediate qcow2 already exists
#   --gapps <zip>    Path to GApps zip (required only when inject_gapps=true)
#
# The script reads all source + build parameters from androiddistro/<slug>.json.
# Supported source.type values:
#   direct             — downloads from source.url (used for Project Sakura / any direct link)
#   sourceforge_latest — resolves the latest ISO via scripts/lib/resolve-blissos-url.py
#
# On completion, intermediate/<base_image> exists and is ready for set-profile.sh.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SLUG="${1:?Usage: fetch-distro.sh <distro-slug> [--force] [--gapps <zip>]}"
FORCE=false
GAPPS_ZIP_ARG=""

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE=true;              shift   ;;
    --gapps)  GAPPS_ZIP_ARG="$2";     shift 2 ;;
    *) echo "[fetch-distro] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

DISTRO_FILE="${ROOT}/androiddistro/${SLUG}.json"
[ -f "$DISTRO_FILE" ] || { echo "[fetch-distro] ERROR: Distro not found: ${DISTRO_FILE}" >&2; exit 1; }
command -v jq &>/dev/null || { echo "[fetch-distro] ERROR: jq is required" >&2; exit 1; }

log()  { echo "[fetch-distro] $*"; }
die()  { echo "[fetch-distro] ERROR: $*" >&2; exit 1; }
warn() { echo "[fetch-distro] WARNING: $*" >&2; }

# ── Load distro metadata ───────────────────────────────────────────────────────
DISTRO_NAME=$(    jq -r '.name'               "$DISTRO_FILE")
BASE_IMAGE=$(     jq -r '.base_image'         "$DISTRO_FILE")
INJECT_GAPPS=$(   jq -r 'if .inject_gapps     == false then "false" else "true" end' "$DISTRO_FILE")
INJECT_ARM_TRANS=$(jq -r 'if .inject_arm_trans == false then "false" else "true" end' "$DISTRO_FILE")
SOURCE_TYPE=$(    jq -r '.source.type'        "$DISTRO_FILE")

OUT_IMG="${ROOT}/intermediate/${BASE_IMAGE}"

log "Distro: ${DISTRO_NAME}  slug=${SLUG}  inject_gapps=${INJECT_GAPPS}"
log "Output: ${OUT_IMG}"

# ── Idempotency check ─────────────────────────────────────────────────────────
if [ -f "$OUT_IMG" ] && ! $FORCE; then
  log "Intermediate image already exists: ${OUT_IMG}"
  log "Use --force to rebuild it."
  exit 0
fi

# ── Resolve ISO URL ────────────────────────────────────────────────────────────
ISO_URL=""
ISO_FILENAME=""

case "$SOURCE_TYPE" in
  direct)
    ISO_URL=$(     jq -r '.source.url'      "$DISTRO_FILE")
    ISO_FILENAME=$(jq -r '.source.filename' "$DISTRO_FILE")
    ;;
  sourceforge_latest)
    sf_path=$(  jq -r '.source.sf_path'   "$DISTRO_FILE")
    sf_filter=$(jq -r '.source.sf_filter' "$DISTRO_FILE")
    log "Resolving latest ISO from SourceForge: ${sf_path}"
    resolver_out=$(python3 "${SCRIPT_DIR}/resolve-blissos-url.py" \
      --path "$sf_path" --filter "$sf_filter") \
      || die "Failed to resolve SourceForge URL for ${SLUG}"
    ISO_URL=$(     echo "$resolver_out" | grep '^url='      | cut -d= -f2-)
    ISO_FILENAME=$(echo "$resolver_out" | grep '^filename=' | cut -d= -f2-)
    ;;
  *)
    die "Unknown source.type '${SOURCE_TYPE}' in ${DISTRO_FILE}"
    ;;
esac

[ -n "$ISO_URL" ] || die "Could not determine ISO URL for ${SLUG}"
log "ISO URL:  ${ISO_URL}"
log "Filename: ${ISO_FILENAME}"

# ── GApps resolution ──────────────────────────────────────────────────────────
GAPPS_ZIP=""
# Per-distro URL from JSON; fall back to OpenGApps pico x86_64 11.0 if unset
GAPPS_URL_DEFAULT=$(jq -r '.gapps.url // ""' "$DISTRO_FILE")
[ -z "$GAPPS_URL_DEFAULT" ] && \
  GAPPS_URL_DEFAULT="https://sourceforge.net/projects/opengapps/files/x86_64/20220503/open_gapps-x86_64-11.0-pico-20220503.zip/download"

# Per-slug cache path avoids bliss14 and bliss15 sharing the same gapps.zip
GAPPS_CACHED="${ROOT}/gapps/${SLUG}-gapps.zip"

if [ "$INJECT_GAPPS" = "true" ]; then
  if [ -n "$GAPPS_ZIP_ARG" ]; then
    [ -f "$GAPPS_ZIP_ARG" ] || die "Specified GApps zip not found: ${GAPPS_ZIP_ARG}"
    GAPPS_ZIP="$GAPPS_ZIP_ARG"
  elif [ -f "$GAPPS_CACHED" ]; then
    GAPPS_ZIP="$GAPPS_CACHED"
  elif [ -f "${ROOT}/gapps/gapps.zip" ]; then
    GAPPS_ZIP="${ROOT}/gapps/gapps.zip"
  else
    log "GApps zip not found — downloading from ${GAPPS_URL_DEFAULT} ..."
    mkdir -p "${ROOT}/gapps"
    curl -L --retry 5 --retry-delay 10 --retry-max-time 300 --progress-bar \
      "$GAPPS_URL_DEFAULT" -o "${GAPPS_CACHED}"
    GAPPS_ZIP="$GAPPS_CACHED"
  fi
  log "GApps: ${GAPPS_ZIP}"
fi

# ── ARM translation ────────────────────────────────────────────────────────────
ARM_TRANS_DIR="${ROOT}/arm-trans/libndk_translation"
if [ "$INJECT_ARM_TRANS" = "true" ]; then
  if [ ! -f "${ARM_TRANS_DIR}/lib64/libndk_translation.so" ]; then
    log "ARM translation libs not found — fetching..."
    bash "${SCRIPT_DIR}/fetch-arm-trans.sh" "${ROOT}/arm-trans/"
  fi
  [ -f "${ARM_TRANS_DIR}/lib64/libndk_translation.so" ] \
    || die "libndk_translation.so still missing after fetch"
else
  log "ARM translation injection disabled (inject_arm_trans=false)"
fi

# ── Workspace ─────────────────────────────────────────────────────────────────
WORK="${ROOT}/cache/fetch-distro-${SLUG}"
ISO_DIR="${ROOT}/cache/source-iso"
mkdir -p "$WORK" "$ISO_DIR" "${ROOT}/intermediate"

cleanup_work() {
  log "Cleaning up work directory..."
  sudo umount "${WORK}/iso-mount"  2>/dev/null || true
  sudo umount "${WORK}/mnt/vendor" 2>/dev/null || true
  sudo umount "${WORK}/mnt/product" 2>/dev/null || true
  sudo umount "${WORK}/mnt/system" 2>/dev/null || true
  sudo umount "${WORK}/mnt/efi"    2>/dev/null || true
  sudo umount "${WORK}/mnt/android" 2>/dev/null || true
  [ -n "${LOOP_DEV:-}" ] && sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
  rm -rf "${WORK}/sfs-*" "${WORK}/"*.raw "${WORK}/disk.raw" "${WORK}/boot-*" 2>/dev/null || true
}
trap cleanup_work EXIT

# ── Download ISO ───────────────────────────────────────────────────────────────
ISO_PATH="${ISO_DIR}/${ISO_FILENAME}"
if [ -f "$ISO_PATH" ]; then
  log "ISO already in cache: ${ISO_PATH}"
else
  log "Downloading ISO..."
  curl -L -C - --retry 5 --retry-delay 10 --retry-max-time 600 --progress-bar \
    "$ISO_URL" -o "${ISO_PATH}.tmp"
  mv "${ISO_PATH}.tmp" "$ISO_PATH"
fi
file "$ISO_PATH" | grep -qi "ISO 9660\|CD-ROM" \
  || die "Downloaded file is not a valid ISO (got: $(file "$ISO_PATH"))"
log "ISO ready: ${ISO_PATH} ($(du -sh "$ISO_PATH" | cut -f1))"

# ── Extract partition images from ISO ─────────────────────────────────────────
log "Extracting partition images from ISO..."
mkdir -p "${WORK}/iso-mount"
sudo mount -o loop,ro "$ISO_PATH" "${WORK}/iso-mount"

log "ISO contents:"
ls -la "${WORK}/iso-mount/"

FOUND=0
for name in system vendor product; do
  sfs="${WORK}/iso-mount/${name}.sfs"
  img_direct="${WORK}/iso-mount/${name}.img"
  img_subdir="${WORK}/iso-mount/${name}/${name}.img"

  if [ -f "$sfs" ]; then
    sz=$(du -sh "$sfs" | cut -f1)
    log "Unsquashing ${name}.sfs (${sz})..."
    sudo unsquashfs -d "${WORK}/sfs-${name}" "$sfs"
    for inner in \
      "${WORK}/sfs-${name}/${name}.img" \
      "${WORK}/sfs-${name}/system.img" \
      "${WORK}/sfs-${name}/${name}/${name}.img"; do
      if [ -f "$inner" ]; then
        mv "$inner" "${WORK}/${name}.img"
        FOUND=$(( FOUND + 1 ))
        break
      fi
    done
    sudo rm -rf "${WORK}/sfs-${name}"
  elif [ -f "$img_direct" ]; then
    cp "$img_direct" "${WORK}/${name}.img"
    FOUND=$(( FOUND + 1 ))
  elif [ -f "$img_subdir" ]; then
    cp "$img_subdir" "${WORK}/${name}.img"
    FOUND=$(( FOUND + 1 ))
  fi
done

# Copy boot files
for item in kernel initrd.img ramdisk.img isolinux grub efi; do
  [ -e "${WORK}/iso-mount/${item}" ] \
    && cp -r "${WORK}/iso-mount/${item}" "${WORK}/boot-${item}" || true
done

sudo umount "${WORK}/iso-mount"
rmdir "${WORK}/iso-mount"

[ "$FOUND" -gt 0 ] || die "No partition images (.sfs or .img) found in ISO"
log "Extracted ${FOUND} partition image(s)"
ls -lh "${WORK}/"*.img 2>/dev/null || true

# ── Convert sparse images to raw ext4 ─────────────────────────────────────────
log "Converting partition images (sparse → raw)..."
for name in system vendor product; do
  src="${WORK}/${name}.img"
  dst="${WORK}/${name}.raw"
  [ -f "$src" ] || continue
  simg2img "$src" "$dst" 2>/dev/null \
    && log "  ${name}: sparse → raw" \
    || { cp "$src" "$dst"; log "  ${name}: already raw (not sparse)"; }
  rm -f "$src"
done

# ── Resize system partition if GApps will be injected ────────────────────────
if [ "$INJECT_GAPPS" = "true" ]; then
  log "Resizing system partition (+600 MB for GApps)..."
  e2fsck -yf "${WORK}/system.raw" || true
  truncate -s +600M "${WORK}/system.raw"
  resize2fs "${WORK}/system.raw"
  e2fsck -yf "${WORK}/system.raw" || true
fi

# ── Mount partition images ─────────────────────────────────────────────────────
log "Mounting partition images..."
mkdir -p "${WORK}/mnt/system" "${WORK}/mnt/product"
sudo mount -o loop,rw "${WORK}/system.raw" "${WORK}/mnt/system"

if [ -f "${WORK}/product.raw" ]; then
  sudo mount -o loop,rw "${WORK}/product.raw" "${WORK}/mnt/product"
else
  log "No product partition — product injection skipped"
fi

# Detect system layout
if [ -f "${WORK}/mnt/system/build.prop" ] || \
   [ -d "${WORK}/mnt/system/app" ]        || \
   [ -d "${WORK}/mnt/system/lib" ]; then
  SYS="${WORK}/mnt/system"
  log "Layout: system-partition (system files at mnt/system/)"
elif [ -f "${WORK}/mnt/system/system/build.prop" ] || \
     [ -d "${WORK}/mnt/system/system/app" ]; then
  SYS="${WORK}/mnt/system/system"
  log "Layout: rootfs (system files at mnt/system/system/)"
else
  SYS="${WORK}/mnt/system"
  log "Layout: unknown — defaulting to mnt/system/"
fi

# Vendor: separate vendor.raw or directory inside system
if [ -f "${WORK}/vendor.raw" ]; then
  mkdir -p "${WORK}/mnt/vendor"
  sudo mount -o loop,rw "${WORK}/vendor.raw" "${WORK}/mnt/vendor"
  VENDOR="${WORK}/mnt/vendor"
  log "Mounted vendor.raw"
else
  VENDOR="${SYS}/vendor"
  sudo mkdir -p "$VENDOR"
  log "Vendor: using ${VENDOR}"
fi

# ── Inject GApps ──────────────────────────────────────────────────────────────
if [ "$INJECT_GAPPS" = "true" ]; then
  log "Injecting GApps from ${GAPPS_ZIP}..."
  sudo bash "${SCRIPT_DIR}/inject-gapps.sh" \
    "$GAPPS_ZIP" "$SYS" "${WORK}/mnt/product"
  # Verify GmsCore was installed
  gms_ok=false
  for d in com.google.android.gms PrebuiltGmsCore GmsCore; do
    sudo test -d "${SYS}/priv-app/${d}" && { gms_ok=true; break; }
  done
  $gms_ok || warn "GmsCore not found after GApps injection — check ${GAPPS_ZIP}"
fi

# ── Inject ARM translation ─────────────────────────────────────────────────────
if [ "$INJECT_ARM_TRANS" = "true" ]; then
  log "Injecting ARM translation libs..."
  sudo bash "${SCRIPT_DIR}/inject-arm-trans.sh" \
    "$ARM_TRANS_DIR" "$VENDOR"

  # ── Write ARM bridge props ───────────────────────────────────────────────────
  log "Writing ARM bridge props to vendor/build.prop..."
  VPROP="${VENDOR}/build.prop"
  sudo touch "$VPROP"
  for kv in \
    "ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi" \
    "ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi" \
    "ro.product.cpu.abilist64=x86_64,arm64-v8a" \
    "ro.dalvik.vm.native.bridge=libndk_translation.so" \
    "ro.enable.native.bridge.exec=1" \
    "ro.vendor.enable.native.bridge.exec=1" \
    "ro.vendor.enable.native.bridge.exec64=1" \
    "ro.ndk_translation.version=0.2.2"
  do
    key="${kv%%=*}"
    if sudo grep -q "^${key}=" "$VPROP" 2>/dev/null; then
      sudo sed -i "s|^${key}=.*|${kv}|" "$VPROP"
    else
      echo "$kv" | sudo tee -a "$VPROP" > /dev/null
    fi
  done
  sudo grep "ro\.dalvik\|ro\.enable\.native\|abilist" "$VPROP" || true
fi

# ── Unmount partition images ──────────────────────────────────────────────────
log "Unmounting partition images..."
[ -f "${WORK}/vendor.raw" ] && { sudo umount "${WORK}/mnt/vendor" 2>/dev/null || true; }
sudo umount "${WORK}/mnt/product" 2>/dev/null || true
sudo umount "${WORK}/mnt/system"  2>/dev/null || true

# ── Assemble bootable disk (GPT: EFI vfat p1 + ext4 Android data p2 + ext4 Userdata p3) ──
log "Assembling bootable disk image..."
SYSTEM_SZ=$( stat -c%s "${WORK}/system.raw")
VENDOR_SZ=$([ -f "${WORK}/vendor.raw"  ] && stat -c%s "${WORK}/vendor.raw"  || echo 0)
PRODUCT_SZ=$([ -f "${WORK}/product.raw"] && stat -c%s "${WORK}/product.raw" || echo 0)
BOOT_SZ=$(find "${WORK}" -maxdepth 1 -name 'boot-*' -exec du -sb {} + 2>/dev/null \
          | awk '{s+=$1}END{print s+0}')
DATA_CONTENT=$(( SYSTEM_SZ + VENDOR_SZ + PRODUCT_SZ + BOOT_SZ ))
DATA_SZ=$(( DATA_CONTENT * 12 / 10 + 256 * 1024 * 1024 ))
USERDATA_SZ=$(( 8 * 1024 * 1024 * 1024 ))   # 8 GiB userdata partition (sda3)
DISK_SZ=$(( DATA_SZ + 256 * 1024 * 1024 + 4 * 1024 * 1024 + USERDATA_SZ ))
log "Disk size: $(( DISK_SZ / 1024 / 1024 )) MB  (data $(( DATA_SZ / 1024 / 1024 )) MB + 8192 MB userdata)"

# Compute where the data partition ends (MiB, rounded up) for the third partition boundary
DATA_END_MIB=$(( 257 + (DATA_SZ + 1048575) / 1048576 ))

truncate -s $DISK_SZ "${WORK}/disk.raw"
sudo parted -s "${WORK}/disk.raw" \
  mklabel gpt \
  mkpart EFI      fat32 1MiB               257MiB \
  set 1 esp on \
  mkpart Data     ext4  257MiB             ${DATA_END_MIB}MiB \
  mkpart Userdata ext4  ${DATA_END_MIB}MiB 100%

LOOP_DEV=$(sudo losetup --find --show --partscan "${WORK}/disk.raw")
log "Loop device: ${LOOP_DEV}"
sleep 1

sudo mkfs.vfat -n EFI        "${LOOP_DEV}p1"
sudo mkfs.ext4 -L BlissOS    "${LOOP_DEV}p2"
sudo mkfs.ext4 -L Userdata   "${LOOP_DEV}p3"

mkdir -p "${WORK}/mnt/efi" "${WORK}/mnt/android"
sudo mount "${LOOP_DEV}p1" "${WORK}/mnt/efi"
sudo mount "${LOOP_DEV}p2" "${WORK}/mnt/android"

sudo cp "${WORK}/system.raw" "${WORK}/mnt/android/system.img"
[ -f "${WORK}/vendor.raw"  ] && sudo cp "${WORK}/vendor.raw"  "${WORK}/mnt/android/vendor.img"  || true
[ -f "${WORK}/product.raw" ] && sudo cp "${WORK}/product.raw" "${WORK}/mnt/android/product.img" || true

# Kernel + initrd go on the EFI partition (FAT32, always readable by GRUB) AND on the
# android ext4 partition.  Android-x86-derived GRUB binaries typically search for the
# partition containing system.img, root to it, and load kernel/initrd relative to that
# root — so they must be present on both partitions to work regardless of prefix.
[ -f "${WORK}/boot-kernel"      ] && sudo cp "${WORK}/boot-kernel"      "${WORK}/mnt/efi/kernel"         || true
[ -f "${WORK}/boot-ramdisk.img" ] && sudo cp "${WORK}/boot-ramdisk.img" "${WORK}/mnt/efi/initrd.img"     || true
[ -f "${WORK}/boot-initrd.img"  ] && sudo cp "${WORK}/boot-initrd.img"  "${WORK}/mnt/efi/initrd.img"     || true
[ -f "${WORK}/boot-kernel"      ] && sudo cp "${WORK}/boot-kernel"      "${WORK}/mnt/android/kernel"     || true
[ -f "${WORK}/boot-ramdisk.img" ] && sudo cp "${WORK}/boot-ramdisk.img" "${WORK}/mnt/android/initrd.img" || true
[ -f "${WORK}/boot-initrd.img"  ] && sudo cp "${WORK}/boot-initrd.img"  "${WORK}/mnt/android/initrd.img" || true

# Install GRUB EFI extracted from the ISO.
# ISOs ship BOOTx64.EFI (shim) + grubx64.efi (the real GRUB binary).
# We don't need Secure Boot, so install grubx64.efi directly as BOOTx64.EFI —
# OVMF runs it straight and there is no shim chain-load to fail.
GRUB_EFI=$(find "${WORK}/boot-efi/" -iname 'grubx64.efi' 2>/dev/null | head -1 || true)
[ -f "$GRUB_EFI" ] || GRUB_EFI=$(find "${WORK}/boot-efi/" -iname 'bootx64.efi' 2>/dev/null | head -1 || true)
[ -f "$GRUB_EFI" ] || die "GRUB EFI binary not found in ISO (expected boot-efi/BOOT/grubx64.efi)"

sudo mkdir -p "${WORK}/mnt/efi/EFI/BOOT" "${WORK}/mnt/android/boot/grub"
sudo cp "$GRUB_EFI" "${WORK}/mnt/efi/EFI/BOOT/BOOTx64.EFI"
log "GRUB EFI: $(basename "$GRUB_EFI") → EFI/BOOT/BOOTx64.EFI"

# Copy grub.cfg from the ISO to both partitions, preserving the distro's original
# menu entries, HWC/GRALLOC, quiet, timeouts, and any debug entries.
# set-profile.sh will only patch DATA= and add console=ttyS0 on top.
#
# Priority: UEFI copy (clean /kernel paths) > BIOS copy (may have (loop)/ prefixes).
ISO_GRUB_CFG=""
[ -f "${WORK}/boot-efi/EFI/BOOT/grub.cfg" ] && ISO_GRUB_CFG="${WORK}/boot-efi/EFI/BOOT/grub.cfg"
[ -z "$ISO_GRUB_CFG" ] && [ -f "${WORK}/boot-grub/grub.cfg" ] && ISO_GRUB_CFG="${WORK}/boot-grub/grub.cfg"

if [ -n "$ISO_GRUB_CFG" ]; then
  log "Using ISO grub.cfg: ${ISO_GRUB_CFG}"
  # Normalize any ISO-device path prefixes on linux/initrd lines so they work on a
  # flat FAT32/ext4 disk — e.g. "(loop)/kernel" or "(hd0,gpt1)/kernel" → "/kernel".
  sudo sed -E \
    -e 's|^(\s*linux\s+)\([^)]+\)/|\1/|' \
    -e 's|^(\s*initrd\s+)\([^)]+\)/|\1/|' \
    "$ISO_GRUB_CFG" \
    | sudo tee "${WORK}/mnt/efi/EFI/BOOT/grub.cfg" \
               "${WORK}/mnt/android/boot/grub/grub.cfg" > /dev/null
else
  log "ISO grub.cfg not found — writing minimal fallback config"
  DISTRO_DISPLAY_NAME=$(jq -r '.name' "$DISTRO_FILE")
  sudo tee "${WORK}/mnt/efi/EFI/BOOT/grub.cfg" \
           "${WORK}/mnt/android/boot/grub/grub.cfg" > /dev/null <<GRUBCFG
set default=0
set timeout=3

menuentry "${DISTRO_DISPLAY_NAME}" {
    linux /kernel root=/dev/ram0 androidboot.hardware=android_x86_64 androidboot.selinux=permissive SRC= DATA=
    initrd /initrd.img
}
GRUBCFG
fi

sudo umount "${WORK}/mnt/efi"    "${WORK}/mnt/android"
sudo rmdir  "${WORK}/mnt/efi"    "${WORK}/mnt/android"
sudo losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ── Convert raw disk to qcow2 ─────────────────────────────────────────────────
log "Converting disk.raw → ${BASE_IMAGE} (qcow2, compressed)..."
qemu-img convert -O qcow2 -c \
  "${WORK}/disk.raw" \
  "$OUT_IMG"
qemu-img info "$OUT_IMG"

log "Recording checksum..."
sha256sum "$OUT_IMG" >> "${ROOT}/checksums.sha256"

# ── Tidy work directory ───────────────────────────────────────────────────────
log "Removing work files..."
rm -rf "${WORK}/disk.raw" "${WORK}/"*.raw "${WORK}/boot-"* 2>/dev/null || true

trap - EXIT

log ""
log "Intermediate image ready: ${OUT_IMG}"
log "$(qemu-img info "$OUT_IMG" | grep -E 'virtual size|disk size')"
log ""
log "Next step:  bash scripts/set-profile.sh <profile> --distro ${SLUG}"
