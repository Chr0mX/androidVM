#!/usr/bin/env bash
# Download and extract libndk_translation from supremegamers prebuilts.
#
# Source: https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt
# Reference: https://github.com/casualsnek/waydroid_script/blob/main/stuff/ndk.py
#
# Usage: fetch-arm-trans.sh <output-dir>
#   output-dir: files land in <output-dir>/libndk_translation/
#
# Idempotent: skips if lib64/libndk_translation.so already exists.
set -euo pipefail

OUT_DIR="${1:-arm-trans}"
DEST="${OUT_DIR}/libndk_translation"
SENTINEL="${DEST}/lib64/libndk_translation.so"

COMMIT="9324a8914b649b885dad6f2bfd14a67e5d1520bf"
URL="https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt/archive/${COMMIT}.zip"
EXPECTED_MD5="c9572672d1045594448068079b34c350"
ZIPFILE="/tmp/libndktranslation.zip"
UNPACK_DIR="/tmp/libndkunpack"

if [ -f "$SENTINEL" ]; then
  echo "[fetch-arm-trans] Already present: $SENTINEL — skipping"
  exit 0
fi

echo "[fetch-arm-trans] Downloading libndk_translation (commit ${COMMIT:0:12}) ..."
curl -L --retry 5 --retry-delay 10 --progress-bar "$URL" -o "$ZIPFILE"

echo "[fetch-arm-trans] Verifying MD5 ..."
ACTUAL_MD5=$(md5sum "$ZIPFILE" | awk '{print $1}')
if [ "$ACTUAL_MD5" != "$EXPECTED_MD5" ]; then
  echo "[fetch-arm-trans] ERROR: MD5 mismatch" >&2
  echo "  expected: $EXPECTED_MD5" >&2
  echo "  actual:   $ACTUAL_MD5" >&2
  rm -f "$ZIPFILE"
  exit 1
fi
echo "[fetch-arm-trans] MD5 OK"

echo "[fetch-arm-trans] Extracting ..."
rm -rf "$UNPACK_DIR"
mkdir -p "$UNPACK_DIR"
unzip -q "$ZIPFILE" -d "$UNPACK_DIR"

# The zip contains exactly one top-level directory:
# vendor_google_proprietary_ndk_translation-prebuilt-<commit>
INNER=$(find "$UNPACK_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
[ -n "$INNER" ] || { echo "[fetch-arm-trans] ERROR: no top-level directory in zip" >&2; exit 1; }

PREBUILTS="${INNER}/prebuilts"
[ -d "$PREBUILTS" ] \
  || { echo "[fetch-arm-trans] ERROR: prebuilts/ not found inside $(basename "$INNER")" >&2; exit 1; }

mkdir -p "$DEST"
rsync -a "${PREBUILTS}/" "${DEST}/"

rm -rf "$UNPACK_DIR" "$ZIPFILE"

[ -f "$SENTINEL" ] \
  || { echo "[fetch-arm-trans] ERROR: extraction succeeded but $SENTINEL not found" >&2; exit 1; }

echo "[fetch-arm-trans] Done — libndk_translation in ${DEST}/"
