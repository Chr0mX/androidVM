#!/usr/bin/env bash
# Download a distro ISO and build the intermediate qcow2 for use with set-profile.sh.
#
# Usage: fetch-distro.sh <distro-slug> [--force] [--gapps <zip>]
#
#   distro-slug      Name matching androiddistro/<slug>.json  (e.g. bliss14, sakura)
#   --force          Rebuild even if the intermediate qcow2 already exists
#   --gapps <zip>    Path to GApps zip (required only when inject_gapps=true)
#
# The script reads all source + build parameters from androiddistro/<slug>.json.
# Disk layout: GPT p1=ESP(FAT32) GRUB EFI, p2=ext4(BlissOS) android/ + grub/grub.cfg, p3=ext4(Userdata)
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SLUG="${1:?Usage: fetch-distro.sh <distro-slug> [--force] [--gapps <zip>]}"
FORCE=false
GAPPS_ZIP_ARG=""

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE=true;              shift   ;;
    --gapps)  GAPPS_ZIP_ARG="$2";     shift 2 ;;
    *) echo "[fetch-distro] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

DISTRO_FILE="${ROOT}/androiddistro/${SLUG}.json"
[ -f "$DISTRO_FILE" ] || { echo "[fetch-distro] ERROR: Distro not found: ${DISTRO_FILE}" >&2; exit 1; }
command -v jq &>/dev/null || { echo "[fetch-distro] ERROR: jq is required" >&2; exit 1; }

log()  { echo "[fetch-distro] $*"; }
die()  { echo "[fetch-distro] ERROR: $*" >&2; exit 1; }
warn() { echo "[fetch-distro] WARNING: $*" >&2; }

# ── Load distro metadata ───────────────────────────────────────────────────────
DISTRO_NAME=$(     jq -r '.name'               "$DISTRO_FILE")
BASE_IMAGE=$(      jq -r '.base_image'         "$DISTRO_FILE")
INJECT_GAPPS=$(    jq -r 'if .inject_gapps     == true then "true" else "false" end' "$DISTRO_FILE")
INJECT_ARM_TRANS=$(jq -r 'if .inject_arm_trans == true then "true" else "false" end' "$DISTRO_FILE")
SOURCE_TYPE=$(     jq -r '.source.type'        "$DISTRO_FILE")

OUT_IMG="${ROOT}/intermediate/${BASE_IMAGE}"

log "Distro: ${DISTRO_NAME}  slug=${SLUG}  inject_gapps=${INJECT_GAPPS}"
log "Output: ${OUT_IMG}"

# ── Resolve ISO URL ────────────────────────────────────────────────────────────
ISO_URL=""
ISO_FILENAME=""

case "$SOURCE_TYPE" in
  direct)
    ISO_URL=$(     jq -r '.source.url'      "$DISTRO_FILE")
    ISO_FILENAME=$(jq -r '.source.filename' "$DISTRO_FILE")
    ;;
  sourceforge_latest)
    sf_path=$(  jq -r '.source.sf_path'   "$DISTRO_FILE")
    sf_filter=$(jq -r '.source.sf_filter' "$DISTRO_FILE")
    log "Resolving latest ISO from SourceForge: ${sf_path}"
    resolver_out=$(python3 "${SCRIPT_DIR}/resolve-blissos-url.py" \
      --path "$sf_path" --filter "$sf_filter") \
      || die "Failed to resolve SourceForge URL for ${SLUG}"
    ISO_URL=$(     echo "$resolver_out" | grep '^url='      | cut -d= -f2-)
    ISO_FILENAME=$(echo "$resolver_out" | grep '^filename=' | cut -d= -f2-)
    ;;
  *)
    die "Unknown source.type '${SOURCE_TYPE}' in ${DISTRO_FILE}"
    ;;
esac

[ -n "$ISO_URL" ] || die "Could not determine ISO URL for ${SLUG}"
log "ISO URL:  ${ISO_URL}"
log "Filename: ${ISO_FILENAME}"

# ── Idempotency ───────────────────────────────────────────────────────────────
if [ -f "$OUT_IMG" ] && ! $FORCE; then
  log "Intermediate image already exists: ${OUT_IMG}"
  log "Use --force to rebuild."
  exit 0
fi

# ── GApps resolution ──────────────────────────────────────────────────────────
GAPPS_ZIP=""
GAPPS_URL_DEFAULT=$(jq -r '.gapps.url // ""' "$DISTRO_FILE")
[ -z "$GAPPS_URL_DEFAULT" ] && \
  GAPPS_URL_DEFAULT="https://sourceforge.net/projects/opengapps/files/x86_64/20220503/open_gapps-x86_64-11.0-pico-20220503.zip/download"
GAPPS_CACHED="${ROOT}/gapps/${SLUG}-gapps.zip"

if [ "$INJECT_GAPPS" = "true" ]; then
  if [ -n "$GAPPS_ZIP_ARG" ]; then
    [ -f "$GAPPS_ZIP_ARG" ] || die "Specified GApps zip not found: ${GAPPS_ZIP_ARG}"
    GAPPS_ZIP="$GAPPS_ZIP_ARG"
  elif [ -f "$GAPPS_CACHED" ]; then
    GAPPS_ZIP="$GAPPS_CACHED"
  elif [ -f "${ROOT}/gapps/gapps.zip" ]; then
    GAPPS_ZIP="${ROOT}/gapps/gapps.zip"
  else
    log "GApps zip not found — downloading from ${GAPPS_URL_DEFAULT} ..."
    mkdir -p "${ROOT}/gapps"
    curl -L --retry 5 --retry-delay 10 --retry-max-time 300 --progress-bar \
      "$GAPPS_URL_DEFAULT" -o "${GAPPS_CACHED}"
    GAPPS_ZIP="$GAPPS_CACHED"
  fi
  log "GApps: ${GAPPS_ZIP}"
fi

# ── ARM translation ────────────────────────────────────────────────────────────
ARM_TRANS_DIR="${ROOT}/arm-trans/libndk_translation"
if [ "$INJECT_ARM_TRANS" = "true" ]; then
  if [ ! -f "${ARM_TRANS_DIR}/lib64/libndk_translation.so" ]; then
    log "ARM translation libs not found — fetching..."
    bash "${SCRIPT_DIR}/fetch-arm-trans.sh" "${ROOT}/arm-trans/"
  fi
  [ -f "${ARM_TRANS_DIR}/lib64/libndk_translation.so" ] \
    || die "libndk_translation.so still missing after fetch"
else
  log "ARM translation injection disabled (inject_arm_trans=false)"
fi

# ── Workspace ─────────────────────────────────────────────────────────────────
WORK="${ROOT}/cache/fetch-distro-${SLUG}"
ISO_DIR="${ROOT}/cache/source-iso"
mkdir -p "$WORK" "$ISO_DIR" "${ROOT}/intermediate"

LOOP_DEV=""

cleanup_work() {
  log "Cleaning up work directory..."
  sudo umount "${WORK}/mnt/vendor"  2>/dev/null || true
  sudo umount "${WORK}/mnt/esp"     2>/dev/null || true
  sudo umount "${WORK}/mnt/bliss"   2>/dev/null || true
  [ -n "${LOOP_DEV:-}" ] && sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
  sudo rm -rf "${WORK}/vendor-sq" 2>/dev/null || true
  rm -rf "${WORK}/"*.raw "${WORK}/disk.raw" "${WORK}/iso-extract" \
    "${WORK}/grub.cfg" "${WORK}/grub-stub.cfg" "${WORK}/BOOTX64.EFI" 2>/dev/null || true
}
trap cleanup_work EXIT

# ── Download ISO ───────────────────────────────────────────────────────────────
ISO_PATH="${ISO_DIR}/${ISO_FILENAME}"
if [ -f "$ISO_PATH" ]; then
  log "ISO already in cache: ${ISO_PATH}"
else
  log "Downloading ISO..."
  curl -L -C - --retry 5 --retry-delay 10 --retry-max-time 600 --progress-bar \
    "$ISO_URL" -o "${ISO_PATH}.tmp"
  mv "${ISO_PATH}.tmp" "$ISO_PATH"
fi
file "$ISO_PATH" | grep -qi "ISO 9660\|CD-ROM" \
  || die "Downloaded file is not a valid ISO (got: $(file "$ISO_PATH"))"
log "ISO ready: ${ISO_PATH} ($(du -sh "$ISO_PATH" | cut -f1))"

# ── Extract files from ISO (7z — no sudo loop-mount needed) ──────────────────
log "Extracting files from ISO via 7z..."
EXTRACT="${WORK}/iso-extract"
mkdir -p "$EXTRACT"
7z x -y -bb0 -o"$EXTRACT" "$ISO_PATH" \
    kernel initrd.img ramdisk.img \
    system.sfs system.img \
    vendor.sfs vendor.img \
    product.sfs product.img \
    '*.cfg' -r >/dev/null 2>&1 || true

# Flatten nested files to extract root
find "$EXTRACT" -mindepth 2 -type f \( \
    -name kernel -o -name initrd.img -o -name ramdisk.img \
    -o -name 'system.sfs' -o -name 'system.img' \
    -o -name 'vendor.sfs' -o -name 'vendor.img' \
    -o -name 'product.sfs' -o -name 'product.img' \) \
  -exec mv -n {} "$EXTRACT/" \; 2>/dev/null || true

# Consolidate *.cfg into _cfg/ (avoids name collisions)
mkdir -p "$EXTRACT/_cfg"
find "$EXTRACT" -mindepth 2 -type f -name '*.cfg' \
  -exec mv -n {} "$EXTRACT/_cfg/" \; 2>/dev/null || true
find "$EXTRACT" -mindepth 1 -type d -empty -delete 2>/dev/null || true

log "Extracted: $(ls "$EXTRACT" | tr '\n' ' ')"

[ -f "$EXTRACT/kernel" ]     || die "kernel not found in ISO"
[ -f "$EXTRACT/initrd.img" ] \
  || [ -f "$EXTRACT/ramdisk.img" ] \
  || die "initrd.img / ramdisk.img not found in ISO"
[ -f "$EXTRACT/system.sfs" ] || [ -f "$EXTRACT/system.img" ] \
  || die "No system.sfs or system.img found in ISO"

# ── Inject ARM translation into vendor (vendor.sfs → vendor.img → inject) ────
if [ "$INJECT_ARM_TRANS" = "true" ]; then
  log "Extracting vendor for ARM translation injection..."
  if [ -f "$EXTRACT/vendor.sfs" ]; then
    sudo unsquashfs -d "${WORK}/vendor-sq" "$EXTRACT/vendor.sfs"
    _vendor_inner=""
    for _vi in "${WORK}/vendor-sq/vendor.img" "${WORK}/vendor-sq/system.img"; do
      [ -f "$_vi" ] && { _vendor_inner="$_vi"; break; }
    done
    [ -n "$_vendor_inner" ] || die "No vendor.img inside vendor.sfs"
    cp "$_vendor_inner" "${WORK}/vendor.img"
    sudo rm -rf "${WORK}/vendor-sq"
  elif [ -f "$EXTRACT/vendor.img" ]; then
    cp "$EXTRACT/vendor.img" "${WORK}/vendor.img"
  else
    die "No vendor.sfs or vendor.img in ISO for ARM injection"
  fi
  if file "${WORK}/vendor.img" | grep -qi "Android sparse"; then
    simg2img "${WORK}/vendor.img" "${WORK}/vendor.raw" \
      && mv "${WORK}/vendor.raw" "${WORK}/vendor.img"
  fi
  mkdir -p "${WORK}/mnt/vendor"
  sudo mount -o loop,rw "${WORK}/vendor.img" "${WORK}/mnt/vendor"
  sudo bash "${SCRIPT_DIR}/inject-arm-trans.sh" "$ARM_TRANS_DIR" "${WORK}/mnt/vendor"
  log "Writing ARM bridge props..."
  VPROP="${WORK}/mnt/vendor/build.prop"
  sudo touch "$VPROP"
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
    if sudo grep -q "^${key}=" "$VPROP" 2>/dev/null; then
      sudo sed -i "s|^${key}=.*|${kv}|" "$VPROP"
    else
      echo "$kv" | sudo tee -a "$VPROP" >/dev/null
    fi
  done
  sudo umount "${WORK}/mnt/vendor"
  sudo rmdir  "${WORK}/mnt/vendor"
  log "ARM translation injected into vendor.img"
fi

# ── Stage files in android/ subdir (mirrors do_install) ──────────────────────
log "Staging files into android/ subdir..."
mkdir -p "${WORK}/stage/android"

cp "$EXTRACT/kernel" "${WORK}/stage/android/kernel"
if   [ -f "$EXTRACT/initrd.img"  ]; then cp "$EXTRACT/initrd.img"  "${WORK}/stage/android/initrd.img"
elif [ -f "$EXTRACT/ramdisk.img" ]; then cp "$EXTRACT/ramdisk.img" "${WORK}/stage/android/initrd.img"
fi

if   [ -f "$EXTRACT/system.sfs" ]; then cp "$EXTRACT/system.sfs" "${WORK}/stage/android/system.sfs"
elif [ -f "$EXTRACT/system.img" ]; then cp "$EXTRACT/system.img" "${WORK}/stage/android/system.img"
fi

if   [ -f "${WORK}/vendor.img"     ]; then cp "${WORK}/vendor.img"     "${WORK}/stage/android/vendor.img"
elif [ -f "$EXTRACT/vendor.sfs"    ]; then cp "$EXTRACT/vendor.sfs"    "${WORK}/stage/android/vendor.sfs"
elif [ -f "$EXTRACT/vendor.img"    ]; then cp "$EXTRACT/vendor.img"    "${WORK}/stage/android/vendor.img"
fi

if   [ -f "$EXTRACT/product.sfs" ]; then cp "$EXTRACT/product.sfs" "${WORK}/stage/android/product.sfs"
elif [ -f "$EXTRACT/product.img" ]; then cp "$EXTRACT/product.img" "${WORK}/stage/android/product.img"
fi

log "Staged: $(ls "${WORK}/stage/android" | tr '\n' ' ')"

# ── Extract ISO cmdline for grub.cfg ──────────────────────────────────────────
log "Extracting ISO cmdline for grub.cfg..."
_linux_line=""
for _cfg in "$EXTRACT/_cfg/android.cfg" "$EXTRACT/_cfg/grub.cfg" \
            "$EXTRACT/_cfg/"*.cfg; do
  [ -f "$_cfg" ] || continue
  _line=$(awk '
    /^[[:space:]]*menuentry/ { in_entry=1; next }
    in_entry && /^[[:space:]]*linux[[:space:]]/ {
      sub(/^[[:space:]]*linux[[:space:]]+[^[:space:]]+[[:space:]]*/,""); print; exit
    }' "$_cfg" 2>/dev/null || true)
  [ -n "$_line" ] && { _linux_line="$_line"; break; }
done
if [ -z "$_linux_line" ]; then
  for _icfg in "$EXTRACT/_cfg/isolinux.cfg" "$EXTRACT/_cfg/android.cfg" \
               "$EXTRACT/_cfg/default.cfg"; do
    [ -f "$_icfg" ] || continue
    _al=$(grep -m1 -iE '^\s*APPEND\s' "$_icfg" 2>/dev/null || true)
    if [ -n "$_al" ]; then
      _linux_line="linux /kernel $(echo "$_al" | sed -E 's/^\s*APPEND\s+//')"
      break
    fi
  done
fi

if [ -n "$_linux_line" ]; then
  _iso_base=$(echo "$_linux_line" \
    | sed -E 's/^\s*linux\s+\S+\s*//' \
    | tr ' ' '\n' \
    | grep -vE '^(root=|SRC=|DATA=|BOOT_IMAGE=|iso-scan|console=|quiet$|nomodeset$|androidboot\.enable_console=|HWC=|GRALLOC=)' \
    | grep -v '^$' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
else
  warn "No linux/APPEND line found in ISO config — using fallback cmdline"
  _iso_base="androidboot.hardware=android_x86_64 androidboot.selinux=permissive"
fi

_cmdline="${_iso_base} SRC=android DATA=Userdata HWC=swiftshader"
log "Kernel cmdline: ${_cmdline}"

# ── Generate grub.cfg ─────────────────────────────────────────────────────────
cat > "${WORK}/grub.cfg" <<GRUBEOF
set timeout=5
set default=0

serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input  serial console
terminal_output serial console

menuentry "BlissOS / Sakura" --class android {
    search --set=root --file /android/kernel
    linux /android/kernel ${_cmdline}
    initrd /android/initrd.img
}

menuentry "BlissOS / Sakura (debug)" --class android {
    search --set=root --file /android/kernel
    linux /android/kernel ${_cmdline} DEBUG=2 console=ttyS0,115200n8 androidboot.enable_console=1
    initrd /android/initrd.img
}
GRUBEOF
log "grub.cfg written (cmdline: ${_cmdline})"

# ── Build GRUB standalone EFI binary ──────────────────────────────────────────
log "Building GRUB EFI binary (grub-mkstandalone)..."
cat > "${WORK}/grub-stub.cfg" <<'STUBEOF'
search --set=root --label BlissOS
set prefix=($root)/grub
configfile /grub/grub.cfg
STUBEOF
grub-mkstandalone \
    --format=x86_64-efi \
    --output="${WORK}/BOOTX64.EFI" \
    --locales="" --fonts="" \
    --modules="part_gpt fat ext2 search search_label configfile linux normal echo serial terminal" \
    "boot/grub/grub.cfg=${WORK}/grub-stub.cfg"
log "GRUB EFI binary: ${WORK}/BOOTX64.EFI ($(du -sh "${WORK}/BOOTX64.EFI" | cut -f1))"

# ── Assemble bootable disk (GPT: p1=ESP FAT32, p2=BlissOS ext4, p3=Userdata ext4) ──
log "Assembling bootable disk image..."
ESP_MIB=256
STAGE_BYTES=$(du -sb "${WORK}/stage/android" | awk '{print $1}')
BLISS_MIB=$(( (STAGE_BYTES / 1024 / 1024) * 12 / 10 + 256 ))
USERDATA_MIB=8192
ESP_END_MIB=$(( 1 + ESP_MIB ))
BLISS_END_MIB=$(( ESP_END_MIB + BLISS_MIB ))
DISK_MIB=$(( BLISS_END_MIB + USERDATA_MIB + 4 ))

log "Disk: ${DISK_MIB} MiB  (ESP=${ESP_MIB} MiB + BlissOS=${BLISS_MIB} MiB + Userdata=${USERDATA_MIB} MiB)"
truncate -s "${DISK_MIB}M" "${WORK}/disk.raw"
sudo parted -s "${WORK}/disk.raw" \
  mklabel gpt \
  mkpart ESP      fat32 1MiB                "${ESP_END_MIB}MiB" \
  set 1 esp on \
  mkpart BlissOS  ext4  "${ESP_END_MIB}MiB" "${BLISS_END_MIB}MiB" \
  mkpart Userdata ext4  "${BLISS_END_MIB}MiB" 100%

LOOP_DEV=$(sudo losetup --find --show --partscan "${WORK}/disk.raw")
log "Loop device: ${LOOP_DEV}"
sleep 1

sudo mkfs.vfat -F32 -n EFI "${LOOP_DEV}p1"
sudo mkfs.ext4 -L BlissOS  "${LOOP_DEV}p2"
sudo mkfs.ext4 -L Userdata "${LOOP_DEV}p3"

# p1: ESP — install GRUB EFI bootloader
mkdir -p "${WORK}/mnt/esp"
sudo mount "${LOOP_DEV}p1" "${WORK}/mnt/esp"
sudo mkdir -p "${WORK}/mnt/esp/EFI/BOOT"
sudo cp "${WORK}/BOOTX64.EFI" "${WORK}/mnt/esp/EFI/BOOT/"
sudo umount "${WORK}/mnt/esp"
sudo rmdir  "${WORK}/mnt/esp"

# p2: BlissOS — Android files in android/ + grub/grub.cfg
mkdir -p "${WORK}/mnt/bliss"
sudo mount "${LOOP_DEV}p2" "${WORK}/mnt/bliss"
sudo cp -a "${WORK}/stage/android" "${WORK}/mnt/bliss/"
sudo mkdir -p "${WORK}/mnt/bliss/grub"
sudo cp "${WORK}/grub.cfg" "${WORK}/mnt/bliss/grub/"
sudo umount "${WORK}/mnt/bliss"
sudo rmdir  "${WORK}/mnt/bliss"

sudo losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ── Convert raw disk to qcow2 ─────────────────────────────────────────────────
log "Converting disk.raw → ${BASE_IMAGE} (qcow2, compressed)..."
qemu-img convert -O qcow2 -c "${WORK}/disk.raw" "$OUT_IMG"
qemu-img info "$OUT_IMG"
log "Recording checksum..."
sha256sum "$OUT_IMG" >> "${ROOT}/checksums.sha256"

# ── Tidy work directory ───────────────────────────────────────────────────────
log "Removing work files..."
rm -rf "${WORK}/disk.raw" "${WORK}/"*.raw "${WORK}/stage" "${WORK}/iso-extract" \
  "${WORK}/vendor.img" "${WORK}/grub.cfg" "${WORK}/grub-stub.cfg" \
  "${WORK}/BOOTX64.EFI" 2>/dev/null || true

trap - EXIT

log ""
log "Intermediate image ready: ${OUT_IMG}"
log "$(qemu-img info "$OUT_IMG" | grep -E 'virtual size|disk size')"
log "Disk layout: p1=ESP(GRUB EFI)  p2=BlissOS(android/)  p3=Userdata"
log ""
log "Next step:  bash scripts/set-profile.sh <profile> --distro ${SLUG}"
