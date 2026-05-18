#!/usr/bin/env bash
# Inject libndk_translation ARM translation libs into a mounted vendor partition.
#
# Usage: inject-arm-trans.sh <trans-dir> <vendor-mnt>
#   trans-dir: directory containing bin/, lib/, lib64/, etc/binfmt_misc/
set -euo pipefail

TRANS_DIR="$1"
VENDOR_MNT="$2"

if [ ! -d "$TRANS_DIR" ]; then
  echo "[inject-arm-trans] ERROR: ARM trans directory not found: $TRANS_DIR" >&2
  exit 1
fi

# 64-bit bridge runner
if [ -f "$TRANS_DIR/bin/arm64/ndk_translation_program_runner_binfmt_misc" ]; then
  install -D -m 755 \
    "$TRANS_DIR/bin/arm64/ndk_translation_program_runner_binfmt_misc" \
    "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm64"
  echo "[inject-arm-trans] Installed arm64 bridge runner"
fi

# 32-bit bridge runner
if [ -f "$TRANS_DIR/bin/arm/ndk_translation_program_runner_binfmt_misc" ]; then
  install -D -m 755 \
    "$TRANS_DIR/bin/arm/ndk_translation_program_runner_binfmt_misc" \
    "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm"
  echo "[inject-arm-trans] Installed arm32 bridge runner"
fi

# Shared libraries — both bitnesses
if [ -d "$TRANS_DIR/lib" ]; then
  mkdir -p "$VENDOR_MNT/lib/ndk_translation"
  rsync -a "$TRANS_DIR/lib/" "$VENDOR_MNT/lib/ndk_translation/"
  echo "[inject-arm-trans] Copied 32-bit translation libs"
fi

if [ -d "$TRANS_DIR/lib64" ]; then
  mkdir -p "$VENDOR_MNT/lib64/ndk_translation"
  rsync -a "$TRANS_DIR/lib64/" "$VENDOR_MNT/lib64/ndk_translation/"
  echo "[inject-arm-trans] Copied 64-bit translation libs"
fi

# binfmt_misc registration configs — registers ARM ELF magic bytes with the kernel
if [ -d "$TRANS_DIR/etc/binfmt_misc" ]; then
  mkdir -p "$VENDOR_MNT/etc/binfmt_misc"
  cp "$TRANS_DIR/etc/binfmt_misc/"*.conf "$VENDOR_MNT/etc/binfmt_misc/" 2>/dev/null || true
  echo "[inject-arm-trans] Installed binfmt_misc configs"
fi

# Restore SELinux contexts for NDK translation libs
if command -v restorecon &>/dev/null; then
  restorecon -R "$VENDOR_MNT/lib/ndk_translation/" 2>/dev/null || true
  restorecon -R "$VENDOR_MNT/lib64/ndk_translation/" 2>/dev/null || true
fi

echo "[inject-arm-trans] Injection complete"
