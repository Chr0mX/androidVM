#!/usr/bin/env bash
# Inject MindTheGapps 11.0.0 x86_64 into a mounted system/product partition.
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

# System-side APKs and libraries
if [ -d "$tmpdir/system" ]; then
  rsync -a "$tmpdir/system/" "$SYSTEM_MNT/"
  echo "[inject-gapps] Copied system-side GApps"
fi

# Product-side APKs (Play Store, GMS config, etc.)
if [ -d "$tmpdir/product" ]; then
  rsync -a "$tmpdir/product/" "$PRODUCT_MNT/"
  echo "[inject-gapps] Copied product-side GApps"
fi

# Privapp permissions whitelist — required or GMS crashes silently on entitled APIs
PERM_SRC="$tmpdir/system/etc/permissions/privapp-permissions-google.xml"
if [ -f "$PERM_SRC" ]; then
  install -D -m 644 "$PERM_SRC" \
    "$SYSTEM_MNT/etc/permissions/privapp-permissions-google.xml"
  echo "[inject-gapps] Installed privapp-permissions-google.xml"
else
  echo "[inject-gapps] WARNING: privapp-permissions-google.xml not found in zip" >&2
fi

# SELinux MAC permissions — append Google contexts without clobbering existing
SEINFO_SRC="$tmpdir/system/etc/seinfo/google.xml"
SEINFO_DST="$SYSTEM_MNT/etc/seinfo/plat_mac_permissions.xml"
if [ -f "$SEINFO_SRC" ] && [ -f "$SEINFO_DST" ]; then
  cat "$SEINFO_SRC" >> "$SEINFO_DST"
  echo "[inject-gapps] Appended GApps seinfo contexts"
elif [ -f "$SEINFO_SRC" ]; then
  install -D -m 644 "$SEINFO_SRC" "$SYSTEM_MNT/etc/seinfo/google.xml"
  echo "[inject-gapps] Installed GApps seinfo (no existing plat_mac_permissions.xml)"
fi

# Restore SELinux file contexts for priv-app
if command -v restorecon &>/dev/null; then
  restorecon -R "$SYSTEM_MNT/priv-app/" 2>/dev/null || true
  echo "[inject-gapps] Restored SELinux contexts for priv-app"
fi

echo "[inject-gapps] Injection complete"
