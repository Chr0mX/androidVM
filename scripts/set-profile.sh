#!/usr/bin/env bash
# Create a per-profile bootable image by layering identity props onto the intermediate.
#
# Usage: set-profile.sh <profile-name> [OPTIONS]
#
#   --distro <name>       Android distro (default: bliss14); matches androiddistro/<name>.json
#   --rebuild             Force recreation even if a same-day build already exists
#   --boot                Launch the VM after building
#   --check               Run verify.sh against the booted VM
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_NAME="${1:?Usage: set-profile.sh <profile-name> [--distro <name>] [--rebuild] [--boot] [--check]}"
DISTRO_NAME="bliss14"
REBUILD=false
BOOT=false
CHECK=false

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --distro)     DISTRO_NAME="${2:?--distro requires a name}"; shift 2 ;;
    --rebuild)    REBUILD=true;  shift ;;
    --boot)       BOOT=true;     shift ;;
    --check)      CHECK=true;    shift ;;
    *) echo "[set-profile] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

PROFILE_FILE="${ROOT}/profiles/${PROFILE_NAME}.json"
DISTRO_FILE="${ROOT}/androiddistro/${DISTRO_NAME}.json"
OUT_IMG="${ROOT}/builds/android11-${PROFILE_NAME}-$(date +%Y%m%d).qcow2"
LATEST_LINK="${ROOT}/builds/android11-${PROFILE_NAME}-latest.qcow2"

# p2 = BlissOS data partition (android/ subdir with system.sfs, vendor.img, etc.)
MNT_ANDROID="${ROOT}/mnt/android"
# Loop-mounted from system.img on p1
MNT_SYSTEM="${ROOT}/mnt/system"
# Loop-mounted from vendor.img on p1 (if a separate vendor.img exists)
MNT_VENDOR="${ROOT}/mnt/vendor"
# Loop-mounted from product.img on p1 (if a separate product.img exists)
MNT_PRODUCT="${ROOT}/mnt/product"

log() { echo "[set-profile] $*"; }
die() { echo "[set-profile] ERROR: $*" >&2; exit 1; }

# ── Load device-spoof config (optional) ───────────────────────────────────────
SPOOF_JSON="${ROOT}/config/device-spoof.json"
SPOOF_ENABLED=true
SPOOF_PARTITIONS=("system" "vendor" "product")
VERIFY_AFTER_BUILD=false

if [ -f "$SPOOF_JSON" ] && command -v jq &>/dev/null; then
  SPOOF_ENABLED=$(jq -r '.enabled // true' "$SPOOF_JSON")
  mapfile -t SPOOF_PARTITIONS < <(jq -r '.patch_partitions[]? // empty' "$SPOOF_JSON")
  [ "${#SPOOF_PARTITIONS[@]}" -eq 0 ] && SPOOF_PARTITIONS=("system" "vendor" "product")
  VERIFY_AFTER_BUILD=$(jq -r '.verify_after_build // false' "$SPOOF_JSON")
fi

# ── Load distro config ─────────────────────────────────────────────────────
[ -f "$DISTRO_FILE" ] || die "Distro not found: $DISTRO_FILE"
command -v jq &>/dev/null || die "jq is required but not installed"

DISTRO_BASE_IMAGE=$(jq -r '.base_image' "$DISTRO_FILE")

INTERMEDIATE="${ROOT}/intermediate/${DISTRO_BASE_IMAGE}"

log "Distro: $(jq -r '.name' "$DISTRO_FILE")"

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
  echo "$DISTRO_NAME" > "${ROOT}/builds/android11-${PROFILE_NAME}.distro"
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

  mkdir -p "$MNT_ANDROID" "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT"

  SYSTEM_IMG_MOUNTED=false
  VENDOR_IMG_MOUNTED=false
  PRODUCT_IMG_MOUNTED=false
  NBD_CONNECTED=false

  # Arm the trap BEFORE qemu-nbd connects so a failure between connect and the
  # first mount still releases the NBD device.
  cleanup() {
    log "Unmounting partitions ..."
    $PRODUCT_IMG_MOUNTED && sudo umount "$MNT_PRODUCT" 2>/dev/null || true
    $VENDOR_IMG_MOUNTED  && sudo umount "$MNT_VENDOR"  2>/dev/null || true
    $SYSTEM_IMG_MOUNTED  && sudo umount "$MNT_SYSTEM"  2>/dev/null || true
    sudo umount "$MNT_ANDROID" 2>/dev/null || true
    $NBD_CONNECTED && sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
  }
  trap cleanup EXIT

  log "Connecting image via NBD ..."
  sudo qemu-nbd --connect=/dev/nbd0 "$OUT_IMG"
  NBD_CONNECTED=true
  sleep 2

  log "Partition layout:"
  lsblk /dev/nbd0

  # p2 = BlissOS data partition (android/ subdir with system.sfs, vendor.img, etc.)
  sudo mount /dev/nbd0p2 "$MNT_ANDROID"

  # system is now system.sfs (squashfs — read-only, cannot be patched in place)
  ANDROID_DIR="${MNT_ANDROID}/android"
  if sudo test -f "${ANDROID_DIR}/system.sfs"; then
    log "system.sfs present (squashfs — read-only, system props not patchable)"
    SYS_DIR=""
  elif sudo test -f "${ANDROID_DIR}/system.img"; then
    sudo mount -o loop,rw "${ANDROID_DIR}/system.img" "$MNT_SYSTEM"
    SYSTEM_IMG_MOUNTED=true
    log "Mounted android/system.img (loop)"
    if sudo test -f "${MNT_SYSTEM}/build.prop" || sudo test -d "${MNT_SYSTEM}/app"; then
      SYS_DIR="$MNT_SYSTEM"
    elif sudo test -f "${MNT_SYSTEM}/system/build.prop"; then
      SYS_DIR="${MNT_SYSTEM}/system"
    else
      SYS_DIR="$MNT_SYSTEM"
    fi
    log "System layout: ${SYS_DIR}"
  else
    die "No android/system.sfs or android/system.img on data partition — is this a v8+ image? (distro: ${DISTRO_NAME})"
  fi

  # Vendor: android/vendor.img (raw ext4 when ARM trans injected, sfs otherwise)
  VENDOR_DIR=""
  if sudo test -f "${ANDROID_DIR}/vendor.img"; then
    sudo mount -o loop,rw "${ANDROID_DIR}/vendor.img" "$MNT_VENDOR"
    VENDOR_IMG_MOUNTED=true
    VENDOR_DIR="$MNT_VENDOR"
    log "Mounted android/vendor.img (loop)"
  elif [ -n "$SYS_DIR" ] && sudo test -d "${SYS_DIR}/vendor"; then
    VENDOR_DIR="${SYS_DIR}/vendor"
    log "Vendor: using ${VENDOR_DIR}"
  fi

  # Product
  PRODUCT_DIR=""
  if sudo test -f "${ANDROID_DIR}/product.img"; then
    sudo mount -o loop,rw "${ANDROID_DIR}/product.img" "$MNT_PRODUCT"
    PRODUCT_IMG_MOUNTED=true
    PRODUCT_DIR="$MNT_PRODUCT"
    log "Mounted android/product.img (loop)"
  elif [ -n "$SYS_DIR" ] && sudo test -d "${SYS_DIR}/product"; then
    PRODUCT_DIR="${SYS_DIR}/product"
    log "Product: using ${PRODUCT_DIR}"
  fi

  # ── Patch props (sudo required — files owned by root in mounted ext4) ────
  contains_partition() {
    local needle="$1"; local item
    for item in "${SPOOF_PARTITIONS[@]}"; do [ "$item" = "$needle" ] && return 0; done
    return 1
  }

  if [ "$SPOOF_ENABLED" = "true" ]; then
    if contains_partition "system"; then
      if [ -n "$SYS_DIR" ]; then
        log "Patching system/build.prop ..."
        sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
          "${SYS_DIR}/build.prop" system "$PROFILE_FILE"
      else
        log "WARNING: system is squashfs (system.sfs) — system prop patching skipped"
      fi
    else
      log "Skipping system prop patching (device-spoof.json: patch_partitions)"
    fi

    if contains_partition "vendor"; then
      if [ -n "$VENDOR_DIR" ] && sudo test -f "${VENDOR_DIR}/build.prop"; then
        log "Patching vendor/build.prop ..."
        sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
          "${VENDOR_DIR}/build.prop" vendor "$PROFILE_FILE"
      else
        log "WARNING: vendor/build.prop not found — skipping"
      fi
      if [ -n "$VENDOR_DIR" ] && sudo test -f "${VENDOR_DIR}/default.prop"; then
        log "Patching vendor/default.prop ..."
        sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
          "${VENDOR_DIR}/default.prop" vendor "$PROFILE_FILE"
      fi
    else
      log "Skipping vendor prop patching (device-spoof.json: patch_partitions)"
    fi

    if contains_partition "product"; then
      if [ -n "$PRODUCT_DIR" ] && sudo test -f "${PRODUCT_DIR}/build.prop"; then
        log "Patching product/build.prop ..."
        sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
          "${PRODUCT_DIR}/build.prop" product "$PROFILE_FILE"
      fi
    else
      log "Skipping product prop patching (device-spoof.json: patch_partitions)"
    fi
  else
    log "Device spoofing disabled (device-spoof.json: enabled=false) — skipping prop patching"
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
  echo "$DISTRO_NAME" > "${ROOT}/builds/android11-${PROFILE_NAME}.distro"
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
RUN_CHECK=$CHECK
[ "$VERIFY_AFTER_BUILD" = "true" ] && RUN_CHECK=true

if $RUN_CHECK; then
  log "Running verification ..."
  bash "${SCRIPT_DIR}/verify.sh" "$PROFILE_FILE"
fi

log "Done → $OUT_IMG"
