#!/usr/bin/env bash
# Build the intermediate qcow2 image: base + GApps + ARM translation.
# This is the slow path (~30–90 min). The result is reused across all profiles.
#
# Usage: build-intermediate.sh [--source <img>] [--gapps <zip>]
#
# Prerequisites: base image in base/android11-base.qcow2 (or pass --source),
#                GApps zip in gapps/mindthegapps.zip (or pass --gapps),
#                ARM trans in arm-trans/libndk_translation/ (auto-fetched if absent)
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_IMG="${ROOT}/base/android11-base.qcow2"
GAPPS_ZIP="${ROOT}/gapps/mindthegapps.zip"
ARM_TRANS_DIR="${ROOT}/arm-trans/libndk_translation"
OUT_IMG="${ROOT}/intermediate/android11-gapps-arm.qcow2"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_IMG="$2"; shift 2 ;;
    --gapps)  GAPPS_ZIP="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[build-intermediate] $*"; }
die()  { echo "[build-intermediate] ERROR: $*" >&2; exit 1; }

# ── Precondition checks ────────────────────────────────────────────────────
[ -f "$SOURCE_IMG" ] || die "Source image not found: $SOURCE_IMG"
[ -f "$GAPPS_ZIP"  ] || die "GApps zip not found: $GAPPS_ZIP"

if [ ! -f "${ARM_TRANS_DIR}/lib64/libndk_translation.so" ]; then
  log "ARM translation libs not found — fetching ..."
  bash "${SCRIPT_DIR}/lib/fetch-arm-trans.sh" "${ROOT}/arm-trans"
fi

[ -f "${ARM_TRANS_DIR}/lib64/libndk_translation.so" ] \
  || die "libndk_translation.so not found in $ARM_TRANS_DIR/lib64/"

# ── Create derived image ───────────────────────────────────────────────────
log "Creating intermediate layer from $(basename "$SOURCE_IMG") ..."
qemu-img create -f qcow2 \
  -b "$SOURCE_IMG" -F qcow2 \
  "$OUT_IMG"

# ── Mount via NBD ──────────────────────────────────────────────────────────
log "Loading nbd module ..."
sudo modprobe nbd max_part=8
sleep 1

log "Connecting image via NBD ..."
sudo qemu-nbd --connect=/dev/nbd0 "$OUT_IMG"
sleep 2

MNT_SYSTEM="${ROOT}/mnt/system"
MNT_VENDOR="${ROOT}/mnt/vendor"
MNT_PRODUCT="${ROOT}/mnt/product"
mkdir -p "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT"

cleanup() {
  log "Cleaning up mounts ..."
  sudo umount "$MNT_SYSTEM" "$MNT_VENDOR" "$MNT_PRODUCT" 2>/dev/null || true
  sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
}
trap cleanup EXIT

log "Partition layout:"
lsblk /dev/nbd0

sudo mount /dev/nbd0p2 "$MNT_SYSTEM"
sudo mount /dev/nbd0p5 "$MNT_VENDOR"
sudo mount /dev/nbd0p6 "$MNT_PRODUCT" || log "WARNING: No product partition at nbd0p6 — skipping"

# ── Apply baseline ARM bridge props (before profile patching) ─────────────
log "Writing ARM translation props to vendor/build.prop ..."
VENDOR_PROP="$MNT_VENDOR/build.prop"
if [ -f "$VENDOR_PROP" ]; then
  # Only add if not already present
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
    if ! grep -q "^${key}=" "$VENDOR_PROP"; then
      echo "$kv" >> "$VENDOR_PROP"
    else
      # Replace existing value
      sudo sed -i "s|^${key}=.*|${kv}|" "$VENDOR_PROP"
    fi
  done
fi

# ── Inject GApps ──────────────────────────────────────────────────────────
log "Injecting GApps ..."
sudo bash "${SCRIPT_DIR}/lib/inject-gapps.sh" \
  "$GAPPS_ZIP" "$MNT_SYSTEM" "$MNT_PRODUCT"

# ── Inject ARM translation ─────────────────────────────────────────────────
log "Injecting ARM translation libs ..."
sudo bash "${SCRIPT_DIR}/lib/inject-arm-trans.sh" \
  "$ARM_TRANS_DIR" "$MNT_VENDOR"

# ── Cleanup handled by trap ────────────────────────────────────────────────
log "Unmounting ..."
# trap handles it

log ""
log "Intermediate image ready: $OUT_IMG"
log "$(qemu-img info "$OUT_IMG" | grep -E 'virtual size|disk size')"
