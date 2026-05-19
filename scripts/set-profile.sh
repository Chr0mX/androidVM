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

MNT_SYSTEM="${ROOT}/mnt/system"
MNT_VENDOR="${ROOT}/mnt/vendor"
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

  mkdir -p "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT"

  VENDOR_MOUNTED=false
  PRODUCT_MOUNTED=false

  cleanup() {
    log "Unmounting partitions ..."
    $PRODUCT_MOUNTED && sudo umount "$MNT_PRODUCT" 2>/dev/null || true
    $VENDOR_MOUNTED  && sudo umount "$MNT_VENDOR"  2>/dev/null || true
    sudo umount "$MNT_SYSTEM" 2>/dev/null || true
    sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
  }
  trap cleanup EXIT

  log "Partition layout:"
  lsblk /dev/nbd0

  sudo mount /dev/nbd0p2 "$MNT_SYSTEM"

  # Vendor: try separate partition first; fall back to system/vendor directory
  if sudo mount /dev/nbd0p5 "$MNT_VENDOR" 2>/dev/null; then
    VENDOR_MOUNTED=true
    log "Vendor: mounted nbd0p5"
  else
    log "No separate vendor partition — using ${MNT_SYSTEM}/vendor"
    MNT_VENDOR="${MNT_SYSTEM}/vendor"
  fi

  # Product: try separate partition; fall back to system/product directory, or skip
  if sudo mount /dev/nbd0p6 "$MNT_PRODUCT" 2>/dev/null; then
    PRODUCT_MOUNTED=true
    log "Product: mounted nbd0p6"
  elif [ -d "${MNT_SYSTEM}/product" ]; then
    log "No separate product partition — using ${MNT_SYSTEM}/product"
    MNT_PRODUCT="${MNT_SYSTEM}/product"
  else
    log "No product partition — skipping"
    MNT_PRODUCT=""
  fi

  # ── Patch props ──────────────────────────────────────────────────────────
  log "Patching system/build.prop ..."
  python3 "${SCRIPT_DIR}/lib/patch-props.py" \
    "$MNT_SYSTEM/build.prop" system "$PROFILE_FILE"

  if [ -f "$MNT_VENDOR/build.prop" ]; then
    log "Patching vendor/build.prop ..."
    python3 "${SCRIPT_DIR}/lib/patch-props.py" \
      "$MNT_VENDOR/build.prop" vendor "$PROFILE_FILE"
  else
    log "WARNING: vendor/build.prop not found at ${MNT_VENDOR}/build.prop"
  fi

  if [ -f "$MNT_VENDOR/default.prop" ]; then
    log "Patching vendor/default.prop ..."
    python3 "${SCRIPT_DIR}/lib/patch-props.py" \
      "$MNT_VENDOR/default.prop" vendor "$PROFILE_FILE"
  fi

  if [ -n "$MNT_PRODUCT" ] && [ -f "$MNT_PRODUCT/build.prop" ]; then
    log "Patching product/build.prop ..."
    python3 "${SCRIPT_DIR}/lib/patch-props.py" \
      "$MNT_PRODUCT/build.prop" product "$PROFILE_FILE"
  fi

  # ── Patch GRUB config for userdata partition ──────────────────────────────
  GRUB_CFG="${MNT_SYSTEM}/boot/grub/grub.cfg"
  if [ -f "$GRUB_CFG" ]; then
    log "Patching GRUB config: DATA=/dev/vdb ..."
    sudo sed -i 's/ DATA= / DATA=\/dev\/vdb /g' "$GRUB_CFG"
    sudo sed -i 's/ DATA=$/ DATA=\/dev\/vdb/' "$GRUB_CFG"
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
