#!/usr/bin/env bash
# Download libndk_translation from the Chr0mX/waydroid-customizer mirror.
#
# Usage: fetch-arm-trans.sh <version-tag> <output-dir>
#   e.g.: fetch-arm-trans.sh 0.2.2 arm-trans/
set -euo pipefail

VERSION="${1:-0.2.2}"
OUT_DIR="${2:-arm-trans}"

MIRROR_BASE="https://github.com/Chr0mX/waydroid-customizer/releases/download"
ARCHIVE="libndk_translation-${VERSION}.tar.gz"
URL="${MIRROR_BASE}/${VERSION}/${ARCHIVE}"

mkdir -p "$OUT_DIR"

echo "[fetch-arm-trans] Downloading libndk_translation ${VERSION} ..."
curl -L --retry 5 --retry-delay 10 --progress-bar \
  "$URL" -o "${OUT_DIR}/${ARCHIVE}"

echo "[fetch-arm-trans] Extracting to ${OUT_DIR}/libndk_translation/ ..."
mkdir -p "${OUT_DIR}/libndk_translation"
tar -xzf "${OUT_DIR}/${ARCHIVE}" -C "${OUT_DIR}/libndk_translation" --strip-components=1
rm -f "${OUT_DIR}/${ARCHIVE}"

echo "[fetch-arm-trans] Done — libndk_translation ${VERSION} in ${OUT_DIR}/libndk_translation/"
