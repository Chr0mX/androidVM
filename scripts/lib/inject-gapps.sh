#!/usr/bin/env bash
# Inject GApps into a mounted system partition.
# Supports OpenGApps (Core/*.tar.lz) and MindTheGapps (system/) formats.
#
# Usage: inject-gapps.sh <gapps.zip> <system-mnt> <product-mnt>
#
# OpenGApps tar.lz structure:
#   - Config packages (defaultetc, defaultframework): extract dirs like
#     etc/, framework/ relative to the system root → rsync directly
#   - APK packages (gmscore, vending, ...): extract as <PkgName>/<dpi>/<Pkg>.apk
#     → install to priv-app/<PkgName>/
set -euo pipefail

GAPPS_ZIP="$1"
SYSTEM_MNT="$2"
PRODUCT_MNT="$3"

# Top-level dir names that map directly onto the system root (not APK packages)
SYSTEM_TREE_DIRS="etc framework lib lib64 bin overlay app priv-app"

if [ ! -f "$GAPPS_ZIP" ]; then
  echo "[inject-gapps] ERROR: GApps zip not found: $GAPPS_ZIP" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "[inject-gapps] Unpacking $GAPPS_ZIP ..."
unzip -q "$GAPPS_ZIP" -d "$tmpdir"

echo "[inject-gapps] Zip top-level contents:"
ls "$tmpdir"

if [ -d "${tmpdir}/Core" ]; then
  # ── OpenGApps format ──────────────────────────────────────────────────────
  echo "[inject-gapps] Detected OpenGApps format"
  echo "[inject-gapps] Core directory contents:"
  ls "${tmpdir}/Core/"

  extract_dir="${tmpdir}/extracted"
  mkdir -p "$extract_dir"

  archive_count=0
  for archive in "${tmpdir}/Core"/*.tar.lz; do
    [ -f "$archive" ] || continue
    archive_count=$((archive_count + 1))
    echo "[inject-gapps] Extracting $(basename "$archive") ..."
    tar --lzip -xf "$archive" -C "$extract_dir" \
      || lzip -dc "$archive" | tar -x -C "$extract_dir"
  done

  if [ "$archive_count" -eq 0 ]; then
    echo "[inject-gapps] ERROR: No .tar.lz archives found in Core/" >&2
    echo "[inject-gapps] Core directory:" >&2
    ls "${tmpdir}/Core/" >&2
    exit 1
  fi

  echo "[inject-gapps] Extracted $archive_count archive(s). Extracted contents:"
  ls "$extract_dir"

  apk_count=0
  for entry in "${extract_dir}"/*/; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")

    # Does this look like a system-tree directory?
    is_tree_dir=false
    for d in $SYSTEM_TREE_DIRS; do
      [ "$name" = "$d" ] && { is_tree_dir=true; break; }
    done

    if $is_tree_dir; then
      rsync -a "${entry}" "${SYSTEM_MNT}/${name}/"
      echo "[inject-gapps] Installed system tree: ${name}/"
    else
      # APK package directory: <PkgName>/<dpi>/<PkgName>.apk
      apk=$(find "$entry" -name "*.apk" | head -1)
      if [ -z "$apk" ]; then
        echo "[inject-gapps] WARN: No APK found in ${name}/, skipping"
        continue
      fi
      dest="${SYSTEM_MNT}/priv-app/${name}"
      mkdir -p "$dest"
      cp "$apk" "${dest}/${name}.apk"
      # Copy native libs if present
      lib_dir=$(find "$entry" -maxdepth 2 -name "lib" -type d | head -1)
      [ -n "$lib_dir" ] && rsync -a "${lib_dir}/" "${dest}/lib/" || true
      apk_count=$((apk_count + 1))
      echo "[inject-gapps] Installed priv-app/${name} (from $(basename "$apk"))"
    fi
  done

  if [ "$apk_count" -eq 0 ]; then
    echo "[inject-gapps] ERROR: No APK packages were installed" >&2
    echo "[inject-gapps] Extracted directory contents:" >&2
    find "$extract_dir" -maxdepth 3 >&2
    exit 1
  fi
  echo "[inject-gapps] Installed $apk_count APK package(s)"

elif [ -d "${tmpdir}/system" ]; then
  # ── MindTheGapps format ───────────────────────────────────────────────────
  echo "[inject-gapps] Detected MindTheGapps format"
  rsync -a "${tmpdir}/system/" "${SYSTEM_MNT}/"
  [ -d "${tmpdir}/product" ] && rsync -a "${tmpdir}/product/" "${PRODUCT_MNT}/" || true
  echo "[inject-gapps] Copied system/product trees"

else
  echo "[inject-gapps] ERROR: Unrecognised GApps zip format" >&2
  echo "Top-level contents:" >&2
  ls "$tmpdir" >&2
  exit 1
fi

if command -v restorecon &>/dev/null; then
  restorecon -R "${SYSTEM_MNT}/priv-app/" 2>/dev/null || true
fi

echo "[inject-gapps] Injection complete"
