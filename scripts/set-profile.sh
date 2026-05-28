#!/usr/bin/env bash
# Build a per-instance bootable disk by layering identity props over the intermediate.
#
# Usage: set-profile.sh <instance-or-profile-name> [OPTIONS]
#
# If <name> matches an instance (instances/<name>.json) the disk is built at
# instances/<name>/disk.qcow2 using device_profile/distro from the instance file.
# Otherwise legacy mode: a profile build at builds/android11-<name>-latest.qcow2.
#
#   --distro <name>       (legacy only) Android distro; ignored if instance
#   --device-profile <p>  (legacy only) Device profile for prop patching
#   --rebuild             Force recreation even if a same-day build already exists
#   --boot                Launch the VM after building
#   --check               Run verify.sh against the booted VM
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NAME="${1:?Usage: set-profile.sh <instance-or-profile-name> [--distro <name>] [--rebuild] [--boot] [--check]}"
DISTRO_NAME="bliss14"
DEVICE_PROFILE=""
REBUILD=false
BOOT=false
CHECK=false

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --distro)         DISTRO_NAME="${2:?--distro requires a name}";        shift 2 ;;
    --device-profile) DEVICE_PROFILE="${2:?--device-profile requires a name}"; shift 2 ;;
    --rebuild)        REBUILD=true;  shift ;;
    --boot)           BOOT=true;     shift ;;
    --check)          CHECK=true;    shift ;;
    *) echo "[set-profile] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# shellcheck source=lib/instance.sh
. "${SCRIPT_DIR}/lib/instance.sh"
# shellcheck source=lib/alloc-nbd.sh
. "${SCRIPT_DIR}/lib/alloc-nbd.sh"

log() { echo "[set-profile] $*"; }
die() { echo "[set-profile] ERROR: $*" >&2; exit 1; }

# ── Resolve instance vs legacy mode ───────────────────────────────────────────
INSTANCE_MODE=false
if instance_exists "$NAME"; then
  INSTANCE_MODE=true
  CFG="$(instance_path "$NAME")"
  DEVICE_PROFILE=$(jq -r '.device_profile' "$CFG")
  DISTRO_NAME=$(jq -r '.distro' "$CFG")
  OUT_IMG=$(instance_disk "$NAME")
  LATEST_LINK=""  # instances don't use the symlink scheme
  mkdir -p "$(instance_disk_dir "$NAME")"
  log "Instance mode: name=${NAME}  device_profile=${DEVICE_PROFILE}  distro=${DISTRO_NAME}"
else
  [ -n "$DEVICE_PROFILE" ] || DEVICE_PROFILE="$NAME"
  OUT_IMG="${ROOT}/builds/android11-${NAME}-$(date +%Y%m%d).qcow2"
  LATEST_LINK="${ROOT}/builds/android11-${NAME}-latest.qcow2"
  mkdir -p "${ROOT}/builds"
  log "Legacy mode: name=${NAME}  device_profile=${DEVICE_PROFILE}  distro=${DISTRO_NAME}"
fi

PROFILE_FILE="${ROOT}/profiles/${DEVICE_PROFILE}.json"
DISTRO_FILE="${ROOT}/androiddistro/${DISTRO_NAME}.json"

# Per-instance/profile mount points so concurrent builds don't collide
MNT_BASE="${ROOT}/mnt/${NAME}"
MNT_ANDROID="${MNT_BASE}/android"
MNT_SYSTEM="${MNT_BASE}/system"
MNT_VENDOR="${MNT_BASE}/vendor"
MNT_PRODUCT="${MNT_BASE}/product"

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

# ── Existing-build short-circuit ──────────────────────────────────────────
if [ -f "$OUT_IMG" ] && ! $REBUILD; then
  log "Build already exists: $OUT_IMG"
  log "Use --rebuild to recreate it."
  if [ -n "$LATEST_LINK" ]; then
    ln -sf "$(basename "$OUT_IMG")" "$LATEST_LINK"
    echo "$DISTRO_NAME" > "${ROOT}/builds/android11-${NAME}.distro"
    log "Latest → $OUT_IMG"
  fi
else
  # Remove any leftover before re-creating
  [ -f "$OUT_IMG" ] && rm -f "$OUT_IMG"

  # ── Create derived image from intermediate (zero-copy layer) ──────────────
  log "Creating build layer from intermediate ..."
  qemu-img create -f qcow2 \
    -b "$INTERMEDIATE" -F qcow2 \
    "$OUT_IMG"

  # ── Mount via NBD (allocated, not hardcoded) ─────────────────────────────
  log "Allocating NBD device ..."
  NBD_DEV=$(alloc_nbd) || die "Could not allocate /dev/nbdN device"
  log "Using ${NBD_DEV}"

  mkdir -p "$MNT_ANDROID" "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT"

  SYSTEM_IMG_MOUNTED=false
  VENDOR_IMG_MOUNTED=false
  PRODUCT_IMG_MOUNTED=false
  NBD_CONNECTED=false

  cleanup() {
    log "Unmounting partitions ..."
    $PRODUCT_IMG_MOUNTED && sudo umount "$MNT_PRODUCT" 2>/dev/null || true
    $VENDOR_IMG_MOUNTED  && sudo umount "$MNT_VENDOR"  2>/dev/null || true
    $SYSTEM_IMG_MOUNTED  && sudo umount "$MNT_SYSTEM"  2>/dev/null || true
    sudo umount "$MNT_ANDROID" 2>/dev/null || true
    if $NBD_CONNECTED; then
      release_nbd "$NBD_DEV"
    fi
    rmdir "$MNT_ANDROID" "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT" 2>/dev/null || true
    rmdir "$MNT_BASE" 2>/dev/null || true
  }
  trap cleanup EXIT

  log "Connecting image via NBD ..."
  sudo qemu-nbd --connect="$NBD_DEV" "$OUT_IMG"
  NBD_CONNECTED=true
  sleep 2

  log "Partition layout:"
  lsblk "$NBD_DEV"

  sudo mount "${NBD_DEV}p2" "$MNT_ANDROID"

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

  log "Sealing partitions ..."
  trap - EXIT
  cleanup

  log "Recording checksum ..."
  sha256sum "$OUT_IMG" >> "${ROOT}/checksums.sha256"

  if [ -n "$LATEST_LINK" ]; then
    ln -sf "$(basename "$OUT_IMG")" "$LATEST_LINK"
    echo "$DISTRO_NAME" > "${ROOT}/builds/android11-${NAME}.distro"
    log "Latest → $OUT_IMG"
  else
    log "Disk → $OUT_IMG"
  fi
fi

# ── Boot ───────────────────────────────────────────────────────────────────
if $BOOT; then
  log "Launching VM ..."
  bash "${SCRIPT_DIR}/boot.sh" "$NAME" &
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
