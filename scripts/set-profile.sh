#!/usr/bin/env bash
# Create a per-profile bootable image by layering identity props onto the intermediate.
#
# Usage: set-profile.sh <profile-name> [--rebuild] [--boot] [--check]
#
#   --rebuild   Force recreation even if a same-day build already exists
#   --boot      Launch the VM after building
#   --check     Run verify.sh against the booted VM
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_NAME="${1:?Usage: set-profile.sh <profile-name> [--rebuild] [--boot] [--check]}"
REBUILD=false
BOOT=false
CHECK=false

shift
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=true ;;
    --boot)    BOOT=true    ;;
    --check)   CHECK=true   ;;
    *) echo "[set-profile] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

PROFILE_FILE="${ROOT}/profiles/${PROFILE_NAME}.json"
INTERMEDIATE="${ROOT}/intermediate/blissos14-gapps-arm.qcow2"
OUT_IMG="${ROOT}/builds/android11-${PROFILE_NAME}-$(date +%Y%m%d).qcow2"
LATEST_LINK="${ROOT}/builds/android11-${PROFILE_NAME}-latest.qcow2"

# p2 = Android data partition (holds system.img, kernel, grub.cfg, etc.)
MNT_ANDROID="${ROOT}/mnt/android"
# Loop-mounted from system.img on p2
MNT_SYSTEM="${ROOT}/mnt/system"
# Loop-mounted from vendor.img on p2 (if a separate vendor.img exists)
MNT_VENDOR="${ROOT}/mnt/vendor"
# Loop-mounted from product.img on p2 (if a separate product.img exists)
MNT_PRODUCT="${ROOT}/mnt/product"

log() { echo "[set-profile] $*"; }
die() { echo "[set-profile] ERROR: $*" >&2; exit 1; }

# ── Preconditions ──────────────────────────────────────────────────────────
[ -f "$PROFILE_FILE" ]  || die "Profile not found: $PROFILE_FILE"
[ -f "$INTERMEDIATE" ]  || die "Intermediate image not found: $INTERMEDIATE"

# ── Validate profile ───────────────────────────────────────────────────────
log "Validating profile ..."
python3 "${SCRIPT_DIR}/lib/profile-validator.py" "$PROFILE_FILE"

# ── Check for existing same-day build ─────────────────────────────────────
if [ -f "$OUT_IMG" ] && ! $REBUILD; then
  log "Build already exists for today: $OUT_IMG"
  log "Use --rebuild to recreate it."
  # Still update the latest symlink in case it points elsewhere
  ln -sf "$(basename "$OUT_IMG")" "$LATEST_LINK"
  log "Latest → $OUT_IMG"
else
  # ── Create derived image from intermediate (zero-copy layer) ──────────────
  log "Creating build layer from intermediate ..."
  qemu-img create -f qcow2 \
    -b "$INTERMEDIATE" -F qcow2 \
    "$OUT_IMG"

  # ── Mount via NBD ────────────────────────────────────────────────────────
  log "Loading nbd module ..."
  sudo modprobe nbd max_part=8
  sleep 1

  log "Connecting image via NBD ..."
  sudo qemu-nbd --connect=/dev/nbd0 "$OUT_IMG"
  sleep 2

  mkdir -p "$MNT_ANDROID" "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT"

  SYSTEM_IMG_MOUNTED=false
  VENDOR_IMG_MOUNTED=false
  PRODUCT_IMG_MOUNTED=false

  cleanup() {
    log "Unmounting partitions ..."
    $PRODUCT_IMG_MOUNTED && sudo umount "$MNT_PRODUCT" 2>/dev/null || true
    $VENDOR_IMG_MOUNTED  && sudo umount "$MNT_VENDOR"  2>/dev/null || true
    $SYSTEM_IMG_MOUNTED  && sudo umount "$MNT_SYSTEM"  2>/dev/null || true
    sudo umount "$MNT_ANDROID" 2>/dev/null || true
    sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
  }
  trap cleanup EXIT

  log "Partition layout:"
  lsblk /dev/nbd0

  # p2 = Android data partition (contains system.img, grub.cfg, kernel, etc.)
  sudo mount /dev/nbd0p2 "$MNT_ANDROID"

  # Loop-mount the inner system.img to reach the actual Android system files
  if [ -f "${MNT_ANDROID}/system.img" ]; then
    sudo mount -o loop,rw "${MNT_ANDROID}/system.img" "$MNT_SYSTEM"
    SYSTEM_IMG_MOUNTED=true
    log "Mounted system.img (loop)"
  else
    die "system.img not found on data partition (${MNT_ANDROID}) — is this a valid BlissOS image?"
  fi

  # Detect system layout: system-partition image vs rootfs image
  # Use sudo test — files in the mounted ext4 may be root-owned with 600/700 perms
  if sudo test -f "${MNT_SYSTEM}/build.prop" || sudo test -d "${MNT_SYSTEM}/app" || sudo test -d "${MNT_SYSTEM}/lib"; then
    SYS_DIR="$MNT_SYSTEM"
    log "Layout: system-partition (build.prop at ${SYS_DIR}/)"
  elif sudo test -f "${MNT_SYSTEM}/system/build.prop" || sudo test -d "${MNT_SYSTEM}/system/app"; then
    SYS_DIR="${MNT_SYSTEM}/system"
    log "Layout: rootfs (build.prop at ${SYS_DIR}/)"
  else
    SYS_DIR="$MNT_SYSTEM"
    log "Layout: unknown — defaulting to system-partition"
  fi

  # Vendor: separate vendor.img or directory inside system
  if [ -f "${MNT_ANDROID}/vendor.img" ]; then
    sudo mount -o loop,rw "${MNT_ANDROID}/vendor.img" "$MNT_VENDOR"
    VENDOR_IMG_MOUNTED=true
    VENDOR_DIR="$MNT_VENDOR"
    log "Mounted vendor.img (loop)"
  else
    VENDOR_DIR="${SYS_DIR}/vendor"
    log "Vendor: using ${VENDOR_DIR}"
  fi

  # Product: separate product.img, directory inside system, or skip
  if [ -f "${MNT_ANDROID}/product.img" ]; then
    sudo mount -o loop,rw "${MNT_ANDROID}/product.img" "$MNT_PRODUCT"
    PRODUCT_IMG_MOUNTED=true
    PRODUCT_DIR="$MNT_PRODUCT"
    log "Mounted product.img (loop)"
  elif [ -d "${SYS_DIR}/product" ]; then
    PRODUCT_DIR="${SYS_DIR}/product"
    log "Product: using ${PRODUCT_DIR}"
  else
    PRODUCT_DIR=""
    log "No product partition — skipping"
  fi

  # ── Patch props (sudo required — files owned by root in mounted ext4) ────
  log "Patching system/build.prop ..."
  sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
    "${SYS_DIR}/build.prop" system "$PROFILE_FILE"

  if sudo test -f "${VENDOR_DIR}/build.prop"; then
    log "Patching vendor/build.prop ..."
    sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
      "${VENDOR_DIR}/build.prop" vendor "$PROFILE_FILE"
  else
    log "WARNING: vendor/build.prop not found at ${VENDOR_DIR}/build.prop"
  fi

  if sudo test -f "${VENDOR_DIR}/default.prop"; then
    log "Patching vendor/default.prop ..."
    sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
      "${VENDOR_DIR}/default.prop" vendor "$PROFILE_FILE"
  fi

  if [ -n "$PRODUCT_DIR" ] && sudo test -f "${PRODUCT_DIR}/build.prop"; then
    log "Patching product/build.prop ..."
    sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
      "${PRODUCT_DIR}/build.prop" product "$PROFILE_FILE"
  fi

  # ── Patch GRUB config ─────────────────────────────────────────────────────
  # grub.cfg lives on the Android data partition (p2), not inside system.img
  GRUB_CFG="${MNT_ANDROID}/boot/grub/grub.cfg"
  if [ -f "$GRUB_CFG" ]; then
    log "Patching GRUB config: DATA=/dev/vdb + console=ttyS0 ..."
    # Set userdata partition (handles both "DATA= " and "DATA=<eol>" forms)
    sudo sed -i 's/ DATA= / DATA=\/dev\/vdb /g' "$GRUB_CFG"
    sudo sed -i 's/ DATA=$/ DATA=\/dev\/vdb/' "$GRUB_CFG"
    # Add serial console so kernel/init messages are visible in serial log
    sudo sed -i '/linux \/kernel/s/$/ console=ttyS0,115200n8/' "$GRUB_CFG"
    log "GRUB config after patching:"
    sudo grep 'linux ' "$GRUB_CFG" | head -5
  else
    log "WARNING: GRUB config not found at ${GRUB_CFG} — userdata partition may not mount"
  fi

  # ── Cleanup via trap ──────────────────────────────────────────────────────
  log "Sealing partitions ..."

  # ── Checksum ──────────────────────────────────────────────────────────────
  # Wait for trap to finish before checksumming
  trap - EXIT
  cleanup

  log "Recording checksum ..."
  sha256sum "$OUT_IMG" >> "${ROOT}/checksums.sha256"

  # Update latest symlink
  ln -sf "$(basename "$OUT_IMG")" "$LATEST_LINK"
  log "Latest → $OUT_IMG"
fi

# ── Boot ───────────────────────────────────────────────────────────────────
if $BOOT; then
  log "Launching VM ..."
  bash "${SCRIPT_DIR}/boot.sh" "$PROFILE_NAME" &
  log "VM started in background. Waiting 40 seconds for ADB ..."
  sleep 40
fi

# ── Verify ─────────────────────────────────────────────────────────────────
if $CHECK; then
  log "Running verification ..."
  bash "${SCRIPT_DIR}/verify.sh" "$PROFILE_FILE"
fi

log "Done → $OUT_IMG"
