#!/usr/bin/env bash
# Boot an instance (or legacy profile build) in QEMU/KVM with GRUB EFI firmware.
#
# Usage: boot.sh <instance-name> [OPTIONS]
#
# If <instance-name> matches instances/<name>.json, all VM hardware / ports /
# disk path come from that file. Otherwise we fall back to the legacy layout
# (builds/android11-<name>-latest.qcow2 + config/defaults.json ADB port).
#
#   --vm-profile <name>   VM hardware profile override (legacy mode only;
#                         instance mode reads it from the instance file)
#   --no-kvm              Force TCG emulation (no KVM)
#   --headless            No display window
#   --spice               Headless + SPICE remote display
#   --vnc [display]       Headless + VNC on given display number (offset from
#                         the instance's spice_port base; default 0)
#   --snapshot            Ephemeral mode — changes to main image not persisted
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { echo "[boot] ERROR: $*" >&2; exit 1; }

INSTANCE_NAME="${1:?Usage: boot.sh <instance-name> [--vm-profile <name>] [--no-kvm] [--headless] [--spice] [--vnc [display]] [--snapshot]}"
shift || true

VM_PROFILE_NAME=""
NO_KVM=false
HEADLESS=false
SPICE_MODE=false
VNC_MODE=false
VNC_DISPLAY="0"
SNAPSHOT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-profile) VM_PROFILE_NAME="$2"; shift 2 ;;
    --no-kvm)     NO_KVM=true;          shift   ;;
    --headless)   HEADLESS=true;        shift   ;;
    --spice)      SPICE_MODE=true;      shift   ;;
    --vnc)
      VNC_MODE=true
      if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
        VNC_DISPLAY="$2"; shift 2
      else
        shift
      fi
      ;;
    --snapshot)   SNAPSHOT=true;        shift   ;;
    *) echo "[boot] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Source helpers
# shellcheck source=lib/detect-hardware.sh
. "${SCRIPT_DIR}/lib/detect-hardware.sh"
# shellcheck source=lib/instance.sh
. "${SCRIPT_DIR}/lib/instance.sh"

DEFAULTS_JSON="${ROOT}/config/defaults.json"

# ── Resolve instance vs legacy mode ───────────────────────────────────────────
INSTANCE_MODE=false
ADB_PORT=""
SPICE_PORT=""
IMG=""
PID_FILE=""
SERIAL_LOG=""
QMP_SOCK=""

if instance_exists "$INSTANCE_NAME"; then
  INSTANCE_MODE=true
  CFG="$(instance_path "$INSTANCE_NAME")"
  ADB_PORT=$(jq -r '.adb_port'   "$CFG")
  SPICE_PORT=$(jq -r '.spice_port' "$CFG")
  [ -z "$VM_PROFILE_NAME" ] && VM_PROFILE_NAME=$(jq -r '.vm_profile' "$CFG")
  IMG=$(instance_disk "$INSTANCE_NAME")
  PID_FILE=$(instance_pid_file  "$INSTANCE_NAME")
  SERIAL_LOG=$(instance_serial_log "$INSTANCE_NAME")
  QMP_SOCK=$(instance_qmp_sock  "$INSTANCE_NAME")
else
  # Legacy fallback: builds/android11-<name>-latest.qcow2
  IMG="${ROOT}/builds/android11-${INSTANCE_NAME}-latest.qcow2"
  PID_FILE="${ROOT}/run/${INSTANCE_NAME}.pid"
  SERIAL_LOG="${ROOT}/logs/${INSTANCE_NAME}-serial.log"
  QMP_SOCK=""
  ADB_PORT=$(jq -r '.adb_port // 5555' "$DEFAULTS_JSON" 2>/dev/null || echo "5555")
  SPICE_PORT=5900
  [ -z "$VM_PROFILE_NAME" ] && VM_PROFILE_NAME=$(jq -r '.default_vm_profile // "balanced"' "$DEFAULTS_JSON" 2>/dev/null || echo "balanced")
fi

[ -f "$IMG" ] || die "Image not found: $IMG"

# ── Resolve VM hardware profile ───────────────────────────────────────────────
VM_PROFILE_FILE="${ROOT}/config/vm-profiles/${VM_PROFILE_NAME}.json"
if [ ! -f "$VM_PROFILE_FILE" ]; then
  echo "[boot] ERROR: VM profile not found: ${VM_PROFILE_FILE}" >&2
  echo "[boot] Available:" >&2
  for f in "${ROOT}"/config/vm-profiles/*.json; do
    echo "  $(basename "$f" .json)" >&2
  done
  exit 1
fi

RAM_MB=$(jq -r '.ram_mb'           "$VM_PROFILE_FILE")
CPU_CORES=$(jq -r '.cpu_cores'     "$VM_PROFILE_FILE")
CPU_THREADS=$(jq -r '.cpu_threads' "$VM_PROFILE_FILE")
HUGEPAGES=$(jq -r '.hugepages'     "$VM_PROFILE_FILE")
GPU=$(jq -r '.gpu'                 "$VM_PROFILE_FILE")
DISPLAY_CFG=$(jq -r '.display'     "$VM_PROFILE_FILE")
AUDIO=$(jq -r '.audio'             "$VM_PROFILE_FILE")

# ── Cap resources to host capabilities ────────────────────────────────────────
HOST_RAM_MB=$(detect_ram_mb)
HOST_CORES=$(detect_cores)
MAX_VM_RAM=$(suggest_vm_ram_mb "$HOST_RAM_MB")
MAX_VM_CORES=$(suggest_vm_cores "$HOST_CORES")

if [ "$RAM_MB" -gt "$MAX_VM_RAM" ]; then
  echo "[boot] WARNING: Profile requests ${RAM_MB}MB RAM but host suggests max ${MAX_VM_RAM}MB — capping"
  RAM_MB="$MAX_VM_RAM"
fi
if [ "$CPU_CORES" -gt "$MAX_VM_CORES" ]; then
  echo "[boot] WARNING: Profile requests ${CPU_CORES} cores but host suggests max ${MAX_VM_CORES} — capping"
  CPU_CORES="$MAX_VM_CORES"
fi

# ── OVMF/UEFI firmware ────────────────────────────────────────────────────────
OVMF_PATH=""
for _ovmf in /usr/share/OVMF/OVMF.fd \
             /usr/share/ovmf/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/x64/OVMF_CODE.fd \
             /usr/share/edk2-ovmf/OVMF_CODE.fd; do
  [ -f "$_ovmf" ] && { OVMF_PATH="$_ovmf"; break; }
done
[ -n "$OVMF_PATH" ] || die "OVMF not found — install: sudo apt install ovmf"

# ── KVM flags ─────────────────────────────────────────────────────────────────
KVM_FLAGS=()
CPU_VENDOR=$(detect_cpu_vendor)
if $NO_KVM; then
  echo "[boot] KVM disabled — using TCG (slow)"
elif [ -e /dev/kvm ]; then
  KVM_FLAGS=(-enable-kvm -cpu host,+hypervisor)
  echo "[boot] KVM enabled (${CPU_VENDOR})"
else
  echo "[boot] WARNING: /dev/kvm not available — falling back to TCG (slow)"
  echo "[boot]          Run: sudo modprobe kvm_${CPU_VENDOR} && sudo chmod 666 /dev/kvm"
fi

# ── GPU flags ─────────────────────────────────────────────────────────────────
GPU_FLAGS=()
case "$GPU" in
  virtio-vga-gl)
    GPU_FLAGS=(-vga none -device "${GPU},xres=1920,yres=1080")
    ;;
  virtio-vga)
    GPU_FLAGS=(-device "${GPU},xres=1920,yres=1080")
    ;;
  VGA)
    GPU_FLAGS=(-vga std)
    ;;
  *)
    GPU_FLAGS=(-device "$GPU")
    ;;
esac

SECONDARY_GPU=$(jq -r '.secondary_gpu // empty' "$VM_PROFILE_FILE")
[ -n "$SECONDARY_GPU" ] && GPU_FLAGS+=(-device "$SECONDARY_GPU")

# ── Display flags ─────────────────────────────────────────────────────────────
DISPLAY_FLAGS=()
if $SPICE_MODE; then
  DISPLAY_FLAGS=(
    -display none
    -spice "port=${SPICE_PORT},disable-ticketing=on"
    -vga none
    -device virtio-serial
    -chardev "spicevmc,id=vdagent,name=vdagent"
    -device "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
  )
  GPU_FLAGS=()
elif $VNC_MODE; then
  VNC_PORT=$(( SPICE_PORT + VNC_DISPLAY ))
  VNC_DISP_NUM=$(( VNC_PORT - 5900 ))
  GPU_FLAGS=(-device "virtio-vga,xres=1920,yres=1080")
  DISPLAY_FLAGS=(-display none -vnc ":${VNC_DISP_NUM}")
  echo "[boot] VNC:         vnc://localhost:${VNC_PORT}  (display :${VNC_DISP_NUM})"
elif $HEADLESS; then
  DISPLAY_FLAGS=(-display none)
else
  DISPLAY_FLAGS=(-display "$DISPLAY_CFG")
fi

# ── Serial / monitor flags ────────────────────────────────────────────────────
mkdir -p "${ROOT}/logs" "${ROOT}/run"
if $VNC_MODE || $SPICE_MODE; then
  SERIAL_FLAGS=(-serial "file:${SERIAL_LOG}")
  echo "[boot] Serial log: ${SERIAL_LOG}"
else
  SERIAL_FLAGS=(-serial mon:stdio)
fi

# ── QMP socket (instance mode only) ───────────────────────────────────────────
QMP_FLAGS=()
if [ -n "$QMP_SOCK" ]; then
  rm -f "$QMP_SOCK"
  QMP_FLAGS=(-qmp "unix:${QMP_SOCK},server=on,wait=off")
fi

# ── Audio flags ───────────────────────────────────────────────────────────────
AUDIO_FLAGS=()
if [ "$AUDIO" = "pa" ] && ! $SPICE_MODE && ! $HEADLESS; then
  if pactl info &>/dev/null 2>&1; then
    AUDIO_FLAGS=(
      -audiodev pa,id=audio0
      -device ich9-intel-hda
      -device hda-output,audiodev=audio0
    )
  else
    echo "[boot] WARNING: PulseAudio not running — audio disabled"
  fi
fi

# ── Hugepages ─────────────────────────────────────────────────────────────────
HUGEPAGES_FLAGS=()
if [ "$HUGEPAGES" = "true" ]; then
  HP_STATUS=$(check_hugepages)
  if [[ "$HP_STATUS" == available:* ]]; then
    FREE_HP="${HP_STATUS#available:}"
    if [ "${FREE_HP:-0}" -gt 0 ]; then
      HUGEPAGES_FLAGS=(-mem-path /dev/hugepages)
    else
      echo "[boot] WARNING: hugepages=true but 0 free hugepages — ignoring"
    fi
  else
    echo "[boot] WARNING: hugepages=true in profile but hugepages unavailable — ignoring"
  fi
fi

# ── Snapshot mode ─────────────────────────────────────────────────────────────
IMG_SNAPSHOT="snapshot=off"
$SNAPSHOT && IMG_SNAPSHOT="snapshot=on"

echo "[boot] Starting VM: instance=${INSTANCE_NAME}  vm-profile=${VM_PROFILE_NAME}"
echo "[boot] Resources:   ${CPU_CORES}c/${CPU_THREADS}t  ${RAM_MB}MB RAM"
echo "[boot] Image:       ${IMG}"
echo "[boot] OVMF:        ${OVMF_PATH}"
echo "[boot] ADB:         adb connect localhost:${ADB_PORT}"
$SPICE_MODE && echo "[boot] SPICE:        spice://localhost:${SPICE_PORT}"
[ -n "$QMP_SOCK" ] && echo "[boot] QMP:         ${QMP_SOCK}"

qemu-system-x86_64 \
  "${KVM_FLAGS[@]}" \
  -smp "cores=${CPU_CORES},threads=${CPU_THREADS}" \
  -m "${RAM_MB}" \
  "${HUGEPAGES_FLAGS[@]}" \
  -machine q35,vmport=off \
  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_PATH}" \
  -device virtio-scsi-pci,id=scsi0 \
  -drive "file=${IMG},if=none,id=hd0,${IMG_SNAPSHOT}" \
  -device "scsi-hd,drive=hd0,bus=scsi0.0" \
  "${GPU_FLAGS[@]}" \
  "${DISPLAY_FLAGS[@]}" \
  "${AUDIO_FLAGS[@]}" \
  -device ich9-usb-ehci1 \
  -device ich9-usb-uhci1 \
  -device ich9-usb-uhci2 \
  -device ich9-usb-uhci3 \
  -device usb-tablet \
  -device virtio-net-pci,netdev=net0 \
  -netdev "user,id=net0,hostfwd=tcp::${ADB_PORT}-:5555" \
  -device virtio-rng-pci \
  "${QMP_FLAGS[@]}" \
  "${SERIAL_FLAGS[@]}" &

QEMU_PID=$!
echo "$QEMU_PID" > "$PID_FILE"

if $VNC_MODE || $SPICE_MODE || $HEADLESS; then
  ( wait "$QEMU_PID" 2>/dev/null; rm -f "$PID_FILE" "$QMP_SOCK" ) &
  disown
  echo "[boot] VM running in background (PID ${QEMU_PID})"
  echo "[boot] Stop with: android-vm stop ${INSTANCE_NAME}"
else
  wait "$QEMU_PID" || true
  rm -f "$PID_FILE" "$QMP_SOCK"
fi
