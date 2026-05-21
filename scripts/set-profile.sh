#!/usr/bin/env bash
# Create a per-profile bootable image by layering identity props onto the intermediate.
#
# Usage: set-profile.sh <profile-name> [OPTIONS]
#
#   --distro <name>       Android distro (default: bliss14); matches androiddistro/<name>.json
#   --rebuild             Force recreation even if a same-day build already exists
#   --boot                Launch the VM after building
#   --check               Run verify.sh against the booted VM
#   --boot-param <param>  Append an extra kernel parameter (repeatable)
#   --debug [1|2]         Debug boot: add DEBUG=<level>, remove 'quiet'.
#                           Level 1 (default): busybox shell before Android init — type 'exit' to continue
#                           Level 2: additional shell breakpoints at each init stage
#                           Ref: https://docs.blissos.org/knowledgebase/troubleshooting/debug-booting/
#   --nomodeset           Graphics debug: disable DRM/KMS, force software framebuffer (VGA/VESA).
#                           Use when display is black or GPU init hangs.
#                           Ref: https://docs.blissos.org/knowledgebase/troubleshooting/graphics-troubleshooting/
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_NAME="${1:?Usage: set-profile.sh <profile-name> [--distro <name>] [--rebuild] [--boot] [--check] [--boot-param <param>] [--debug [1|2]] [--nomodeset]}"
DISTRO_NAME="bliss14"
REBUILD=false
BOOT=false
CHECK=false
EXTRA_BOOT_PARAMS=()
DEBUG_LEVEL=""   # empty = no debug; "1" or "2" = DEBUG=<level> + strip quiet
NOMODESET=false

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --distro)     DISTRO_NAME="${2:?--distro requires a name}"; shift 2 ;;
    --rebuild)    REBUILD=true;  shift ;;
    --boot)       BOOT=true;     shift ;;
    --check)      CHECK=true;    shift ;;
    --boot-param) EXTRA_BOOT_PARAMS+=("${2:?--boot-param requires a value}"); shift 2 ;;
    --nomodeset)  NOMODESET=true; shift ;;
    --debug)
      DEBUG_LEVEL="1"
      shift
      if [[ "${1:-}" =~ ^[12]$ ]]; then DEBUG_LEVEL="$1"; shift; fi
      ;;
    *) echo "[set-profile] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

PROFILE_FILE="${ROOT}/profiles/${PROFILE_NAME}.json"
DISTRO_FILE="${ROOT}/androiddistro/${DISTRO_NAME}.json"
OUT_IMG="${ROOT}/builds/android11-${PROFILE_NAME}-$(date +%Y%m%d).qcow2"
LATEST_LINK="${ROOT}/builds/android11-${PROFILE_NAME}-latest.qcow2"

# p1 = EFI FAT32 partition (GRUB binary + grub.cfg + kernel + initrd)
MNT_EFI="${ROOT}/mnt/efi"
# p2 = Android data partition (system.img, vendor.img, etc.; also kernel + initrd + boot/grub/grub.cfg)
MNT_ANDROID="${ROOT}/mnt/android"
# Loop-mounted from system.img on p2
MNT_SYSTEM="${ROOT}/mnt/system"
# Loop-mounted from vendor.img on p2 (if a separate vendor.img exists)
MNT_VENDOR="${ROOT}/mnt/vendor"
# Loop-mounted from product.img on p2 (if a separate product.img exists)
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

log "Distro: $(jq -r '.name' "$DISTRO_FILE")  (GRUB options preserved from ISO)"

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

  log "Connecting image via NBD ..."
  sudo qemu-nbd --connect=/dev/nbd0 "$OUT_IMG"
  sleep 2

  mkdir -p "$MNT_EFI" "$MNT_ANDROID" "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT"

  EFI_MOUNTED=false
  SYSTEM_IMG_MOUNTED=false
  VENDOR_IMG_MOUNTED=false
  PRODUCT_IMG_MOUNTED=false

  cleanup() {
    log "Unmounting partitions ..."
    $PRODUCT_IMG_MOUNTED && sudo umount "$MNT_PRODUCT" 2>/dev/null || true
    $VENDOR_IMG_MOUNTED  && sudo umount "$MNT_VENDOR"  2>/dev/null || true
    $SYSTEM_IMG_MOUNTED  && sudo umount "$MNT_SYSTEM"  2>/dev/null || true
    sudo umount "$MNT_ANDROID" 2>/dev/null || true
    $EFI_MOUNTED         && sudo umount "$MNT_EFI"     2>/dev/null || true
    sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
  }
  trap cleanup EXIT

  log "Partition layout:"
  lsblk /dev/nbd0

  # p1 = EFI FAT32 partition (GRUB binary + grub.cfg + kernel + initrd)
  sudo mount /dev/nbd0p1 "$MNT_EFI"
  EFI_MOUNTED=true

  # p2 = Android data partition (system.img, vendor.img, etc.)
  sudo mount /dev/nbd0p2 "$MNT_ANDROID"

  # Loop-mount the inner system.img to reach the actual Android system files
  if [ -f "${MNT_ANDROID}/system.img" ]; then
    sudo mount -o loop,rw "${MNT_ANDROID}/system.img" "$MNT_SYSTEM"
    SYSTEM_IMG_MOUNTED=true
    log "Mounted system.img (loop)"
  else
    die "system.img not found on data partition (${MNT_ANDROID}) — is this a valid Android-x86 image? (distro: ${DISTRO_NAME})"
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
  contains_partition() {
    local needle="$1"; local item
    for item in "${SPOOF_PARTITIONS[@]}"; do [ "$item" = "$needle" ] && return 0; done
    return 1
  }

  if [ "$SPOOF_ENABLED" = "true" ]; then
    if contains_partition "system"; then
      log "Patching system/build.prop ..."
      sudo python3 "${SCRIPT_DIR}/lib/patch-props.py" \
        "${SYS_DIR}/build.prop" system "$PROFILE_FILE"
    else
      log "Skipping system prop patching (device-spoof.json: patch_partitions)"
    fi

    if contains_partition "vendor"; then
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

  # ── Patch bootloader config ───────────────────────────────────────────────
  GRUB_CFGS=()
  GRUB_CFG_EFI="${MNT_EFI}/EFI/BOOT/grub.cfg"
  GRUB_CFG_ANDROID="${MNT_ANDROID}/boot/grub/grub.cfg"
  REFIND_CFG="${MNT_EFI}/EFI/BOOT/refind.conf"

  # Patch every grub.cfg present — new builds have copies on both the EFI partition
  # and the android data partition so GRUB finds its config regardless of which
  # partition its embedded prefix resolves to.
  [ -f "$GRUB_CFG_EFI" ]     && GRUB_CFGS+=("$GRUB_CFG_EFI")
  [ -f "$GRUB_CFG_ANDROID" ] && GRUB_CFGS+=("$GRUB_CFG_ANDROID")

  if [ "${#GRUB_CFGS[@]}" -gt 0 ]; then
    # ── GRUB image(s) ─────────────────────────────────────────────────────────
    # HWC, GRALLOC, quiet, and other distro params come from the ISO's grub.cfg.
    # We only set DATA= (userdata disk) and add console= (headless QEMU serial).
    log "Patching ${#GRUB_CFGS[@]} GRUB config(s): DATA=/dev/vdb + console=ttyS0 ..."
    for GRUB_CFG in "${GRUB_CFGS[@]}"; do
      # Replace DATA= regardless of whether it is empty or already set to something
      sudo sed -i 's|DATA=[^ ]*|DATA=/dev/sda3|g' "$GRUB_CFG"
      for param in "${EXTRA_BOOT_PARAMS[@]}"; do
        key="${param%%=*}"
        sudo sed -i "/linux \/kernel/{ /${key}/! s|$| ${param}|; }" "$GRUB_CFG"
      done
      if [ -n "$DEBUG_LEVEL" ]; then
        sudo sed -i '/linux \/kernel/s/ quiet\b//g' "$GRUB_CFG"
        sudo sed -i "/linux \/kernel/{ /DEBUG=/! s|$| DEBUG=${DEBUG_LEVEL}|; }" "$GRUB_CFG"
      fi
      if $NOMODESET; then
        sudo sed -i "/linux \/kernel/{ /nomodeset/! s|$| nomodeset|; }" "$GRUB_CFG"
      fi
      sudo sed -i '/linux \/kernel/{ /console=ttyS0/! s/$/ console=ttyS0,115200n8/; }' "$GRUB_CFG"
    done
    if [ -n "$DEBUG_LEVEL" ]; then
      log "Debug boot enabled (DEBUG=${DEBUG_LEVEL}) — type 'exit' at busybox prompt to continue"
      log "NOTE: expect 'linker: Warning: failed to find generated linker configuration'"
      log "      from /linkerconfig/ld.config.txt — this is normal at the busybox breakpoint."
      log "      Android init hasn't run yet; linkerconfig generates that file after 'exit'."
    fi
    if $NOMODESET; then
      log "nomodeset enabled — DRM/KMS disabled, using software framebuffer"
    fi
    log "GRUB linux line after patching:"
    sudo grep 'linux ' "${GRUB_CFGS[0]}" | head -3

  elif [ -f "$REFIND_CFG" ]; then
    # ── rEFInd image (backward compatibility for pre-GRUB builds) ─────────
    log "Patching rEFInd config: DATA=/dev/vdb + console=ttyS0 ..."
    log "NOTE: this image uses rEFInd — rebuild from fetch-distro.sh to switch to GRUB"
    sudo sed -i 's|DATA=[^ "]*|DATA=/dev/sda3|g' "$REFIND_CFG"
    for param in "${EXTRA_BOOT_PARAMS[@]}"; do
      key="${param%%=*}"
      sudo sed -i "/^\s*options /{ /${key}/! s|\"$| ${param}\"|; }" "$REFIND_CFG"
    done
    if [ -n "$DEBUG_LEVEL" ]; then
      sudo sed -i '/^\s*options /s/ quiet\b//g' "$REFIND_CFG"
      sudo sed -i "/^\s*options /{ /DEBUG=/! s|\"$| DEBUG=${DEBUG_LEVEL}\"|; }" "$REFIND_CFG"
      log "Debug boot enabled (DEBUG=${DEBUG_LEVEL}) — type 'exit' at busybox prompt to continue"
      log "NOTE: expect 'linker: Warning: failed to find generated linker configuration'"
      log "      from /linkerconfig/ld.config.txt — this is normal at the busybox breakpoint."
      log "      Android init hasn't run yet; linkerconfig generates that file after 'exit'."
    fi
    if $NOMODESET; then
      sudo sed -i "/^\s*options /{ /nomodeset/! s|\"$| nomodeset\"|; }" "$REFIND_CFG"
      log "nomodeset enabled — DRM/KMS disabled, using software framebuffer"
    fi
    sudo sed -i "/^\s*options /{ /console=ttyS0/! s|\"$| console=ttyS0,115200n8\"|; }" "$REFIND_CFG"
    log "rEFInd options after patching:"
    sudo grep 'options ' "$REFIND_CFG"

  else
    log "WARNING: no bootloader config found"
    log "         Checked: ${GRUB_CFG_EFI}"
    log "                  ${GRUB_CFG_ANDROID}"
    log "                  ${REFIND_CFG}"
    log "         Kernel params (DATA=, HWC=, etc.) will NOT be set — VM may not boot correctly"
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
