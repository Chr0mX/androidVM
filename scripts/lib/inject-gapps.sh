#!/usr/bin/env bash
# Inject GApps into a mounted system/product partition.
# Supports both OpenGApps (Core/*.tar.lz) and MindTheGapps (system/ + product/) formats.
#
# Usage: inject-gapps.sh <gapps.zip> <system-mnt> <product-mnt>
set -euo pipefail

GAPPS_ZIP="$1"
SYSTEM_MNT="$2"
PRODUCT_MNT="$3"

if [ ! -f "$GAPPS_ZIP" ]; then
  echo "[inject-gapps] ERROR: GApps zip not found: $GAPPS_ZIP" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "[inject-gapps] Unpacking $GAPPS_ZIP ..."
unzip -q "$GAPPS_ZIP" -d "$tmpdir"

if [ -d "${tmpdir}/Core" ]; then
  # ── OpenGApps format ──────────────────────────────────────────────────────
  # Each Core/*.tar.lz extracts to a tree rooted at "system/".
  echo "[inject-gapps] Detected OpenGApps format"

  extract_dir="${tmpdir}/extracted"
  mkdir -p "$extract_dir"

  for archive in "${tmpdir}/Core"/*.tar.lz; do
    [ -f "$archive" ] || continue
    echo "[inject-gapps] Extracting $(basename "$archive") ..."
    # tar --lzip requires lzip on PATH; fall back to explicit pipe
    tar --lzip -xf "$archive" -C "$extract_dir" 2>/dev/null \
      || lzip -dc "$archive" | tar -x -C "$extract_dir"
  done

  # Copy system-side files
  if [ -d "${extract_dir}/system" ]; then
    rsync -a "${extract_dir}/system/" "${SYSTEM_MNT}/"
    echo "[inject-gapps] Copied OpenGApps system tree"
  else
    echo "[inject-gapps] WARNING: no system/ directory found in OpenGApps archives" >&2
  fi

  # Copy product-side files if present
  if [ -d "${extract_dir}/product" ]; then
    rsync -a "${extract_dir}/product/" "${PRODUCT_MNT}/"
    echo "[inject-gapps] Copied OpenGApps product tree"
  fi

  # Permissions XML — some OpenGApps builds ship it outside the tar archives
  PERM_SRC=$(find "$tmpdir" -name "privapp-permissions-google*.xml" | head -1)
  if [ -n "$PERM_SRC" ]; then
    install -D -m 644 "$PERM_SRC" \
      "${SYSTEM_MNT}/etc/permissions/privapp-permissions-google.xml"
    echo "[inject-gapps] Installed privapp-permissions-google.xml"
  fi

elif [ -d "${tmpdir}/system" ]; then
  # ── MindTheGapps format ───────────────────────────────────────────────────
  echo "[inject-gapps] Detected MindTheGapps format"
  rsync -a "${tmpdir}/system/" "${SYSTEM_MNT}/"
  echo "[inject-gapps] Copied system-side GApps"

  if [ -d "${tmpdir}/product" ]; then
    rsync -a "${tmpdir}/product/" "${PRODUCT_MNT}/"
    echo "[inject-gapps] Copied product-side GApps"
  fi

  PERM_SRC="${tmpdir}/system/etc/permissions/privapp-permissions-google.xml"
  if [ -f "$PERM_SRC" ]; then
    install -D -m 644 "$PERM_SRC" \
      "${SYSTEM_MNT}/etc/permissions/privapp-permissions-google.xml"
    echo "[inject-gapps] Installed privapp-permissions-google.xml"
  else
    echo "[inject-gapps] WARNING: privapp-permissions-google.xml not found in zip" >&2
  fi

else
  echo "[inject-gapps] ERROR: Unrecognised GApps zip format" \
       "(expected Core/ for OpenGApps or system/ for MindTheGapps)" >&2
  echo "Top-level contents:" >&2
  ls "$tmpdir" >&2
  exit 1
fi

if command -v restorecon &>/dev/null; then
  restorecon -R "${SYSTEM_MNT}/priv-app/" 2>/dev/null || true
fi

echo "[inject-gapps] Injection complete"
