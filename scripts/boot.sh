#!/usr/bin/env bash
# Boot a profile image in QEMU/KVM.
#
# Usage: boot.sh <profile-name> [--no-kvm] [--headless]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_NAME="${1:?Usage: boot.sh <profile-name> [--no-kvm] [--headless]}"
NO_KVM=false
HEADLESS=false

shift || true
for arg in "$@"; do
  case "$arg" in
    --no-kvm)   NO_KVM=true   ;;
    --headless) HEADLESS=true ;;
    *) echo "[boot] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

IMG="${ROOT}/builds/android11-${PROFILE_NAME}-latest.qcow2"
UDATA="${ROOT}/userdata/userdata-${PROFILE_NAME}.qcow2"

[ -f "$IMG" ]   || { echo "[boot] ERROR: Image not found: $IMG" >&2; exit 1; }
[ -f "$UDATA" ] || {
  echo "[boot] Userdata volume not found — creating fresh 8G volume ..."
  qemu-img create -f qcow2 "$UDATA" 8G
}

KVM_FLAGS=()
if $NO_KVM; then
  echo "[boot] KVM disabled — using TCG (slow)"
elif [ -e /dev/kvm ]; then
  KVM_FLAGS=(-enable-kvm -cpu host,+hypervisor)
else
  echo "[boot] WARNING: /dev/kvm not available — falling back to TCG"
fi

DISPLAY_FLAGS=()
if $HEADLESS; then
  DISPLAY_FLAGS=(-display none)
else
  DISPLAY_FLAGS=(-device virtio-vga,xres=1080,yres=1920 -display gtk,gl=on)
fi

echo "[boot] Starting VM: profile=${PROFILE_NAME}"
echo "[boot] Image:    $IMG"
echo "[boot] Userdata: $UDATA"
echo "[boot] ADB:      adb connect localhost:5555"

exec qemu-system-x86_64 \
  "${KVM_FLAGS[@]}" \
  -smp cores=4,threads=2 \
  -m 4096 \
  -machine q35 \
  -drive file="$IMG",if=virtio,index=0,snapshot=off \
  -drive file="$UDATA",if=virtio,index=1,snapshot=off \
  "${DISPLAY_FLAGS[@]}" \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::5555-:5555 \
  -device virtio-rng-pci \
  -bios /usr/share/OVMF/OVMF_CODE.fd \
  -append "root=/dev/vda androidboot.hardware=android_x86_64 \
           androidboot.selinux=enforcing \
           DATA=/dev/vdb" \
  -serial mon:stdio
