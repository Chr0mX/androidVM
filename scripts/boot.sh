#!/usr/bin/env bash
# Boot a profile image in QEMU/KVM.
#
# Usage: boot.sh <profile-name> [OPTIONS]
#
#   --vm-profile <name>   VM hardware profile (default: from config/defaults.json)
#   --no-kvm              Force TCG emulation (no KVM)
#   --headless            No display window
#   --spice               Headless + SPICE remote display on port 5900
#   --vnc [display]       Headless + VNC on given display number (default: 0 → port 5900)
#   --snapshot            Ephemeral mode — changes to main image not persisted
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_NAME="${1:?Usage: boot.sh <profile-name> [--vm-profile <name>] [--no-kvm] [--headless] [--spice] [--vnc [display]] [--snapshot]}"
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
      # Accept optional display number (e.g. --vnc 1); skip if next arg is a flag or absent
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

# Source hardware detection helpers
# shellcheck source=lib/detect-hardware.sh
. "${SCRIPT_DIR}/lib/detect-hardware.sh"

# ── Resolve VM hardware profile ────────────────────────────────────────────────
DEFAULTS_JSON="${ROOT}/config/defaults.json"
if [ -z "$VM_PROFILE_NAME" ]; then
  VM_PROFILE_NAME=$(jq -r '.default_vm_profile // "balanced"' \
    "$DEFAULTS_JSON" 2>/dev/null || echo "balanced")
fi

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

# ── Image paths ────────────────────────────────────────────────────────────────
IMG="${ROOT}/builds/android11-${PROFILE_NAME}-latest.qcow2"
UDATA="${ROOT}/userdata/userdata-${PROFILE_NAME}.qcow2"

[ -f "$IMG" ] || { echo "[boot] ERROR: Image not found: $IMG" >&2; exit 1; }
[ -f "$UDATA" ] || {
  echo "[boot] Userdata volume not found — creating fresh $(jq -r '.userdata_size // "8G"' "$DEFAULTS_JSON" 2>/dev/null || echo "8G") volume..."
  UDATA_SIZE=$(jq -r '.userdata_size // "8G"' "$DEFAULTS_JSON" 2>/dev/null || echo "8G")
  qemu-img create -f qcow2 "$UDATA" "$UDATA_SIZE"
}

# ── KVM flags ─────────────────────────────────────────────────────────────────
KVM_FLAGS=()
CPU_VENDOR=$(detect_cpu_vendor)
if $NO_KVM; then
  echo "[boot] KVM disabled — using TCG (slow)"
elif [ -e /dev/kvm ]; then
  # -enable-kvm activates the KVM hypervisor for near-native CPU performance.
  # -cpu host exposes the host CPU features directly to the guest.
  KVM_FLAGS=(-enable-kvm -cpu host,+hypervisor)
  echo "[boot] KVM enabled (${CPU_VENDOR})"
else
  echo "[boot] WARNING: /dev/kvm not available — falling back to TCG (slow)"
  echo "[boot]          Run: sudo modprobe kvm_${CPU_VENDOR} && sudo chmod 666 /dev/kvm"
fi

# ── GPU flags ─────────────────────────────────────────────────────────────────
GPU_FLAGS=()
case "$GPU" in
  virtio-vga-gl|virtio-vga)
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
    -spice "port=5900,disable-ticketing=on"
    -vga none
    -device virtio-serial
    -chardev "spicevmc,id=vdagent,name=vdagent"
    -device "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
  )
  GPU_FLAGS=()   # SPICE manages its own rendering
elif $VNC_MODE; then
  VNC_PORT=$(( 5900 + VNC_DISPLAY ))
  # Use the profile's display backend (gtk,gl=on) for the GL context virtio-vga-gl needs;
  # -vnc mirrors the same framebuffer for remote access.
  GPU_FLAGS=(-device "virtio-vga-gl,xres=1920,yres=1080")
  DISPLAY_FLAGS=(-display "$DISPLAY_CFG" -vnc ":${VNC_DISPLAY}")
  echo "[boot] VNC:         vnc://localhost:${VNC_PORT}  (display :${VNC_DISPLAY})"
elif $HEADLESS; then
  DISPLAY_FLAGS=(-display none)
else
  DISPLAY_FLAGS=(-display "$DISPLAY_CFG")
fi

# ── Serial / monitor flags ────────────────────────────────────────────────────
mkdir -p "${ROOT}/logs"
if $VNC_MODE || $SPICE_MODE; then
  SERIAL_LOG="${ROOT}/logs/${PROFILE_NAME}-serial.log"
  SERIAL_FLAGS=(-serial "file:${SERIAL_LOG}")
  echo "[boot] Serial log: ${SERIAL_LOG}"
else
  SERIAL_FLAGS=(-serial mon:stdio)
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

# ── PID tracking ──────────────────────────────────────────────────────────────
RUN_DIR="${ROOT}/run"
mkdir -p "$RUN_DIR"
PID_FILE="${RUN_DIR}/${PROFILE_NAME}.pid"

ADB_PORT=$(jq -r '.adb_port // 5555' "$DEFAULTS_JSON" 2>/dev/null || echo "5555")
OVMF_PATH=$(jq -r '.ovmf_path // "/usr/share/OVMF/OVMF_CODE.fd"' "$DEFAULTS_JSON" 2>/dev/null \
  || echo "/usr/share/OVMF/OVMF_CODE.fd")

echo "[boot] Starting VM: profile=${PROFILE_NAME}  vm-profile=${VM_PROFILE_NAME}"
echo "[boot] Resources:   ${CPU_CORES}c/${CPU_THREADS}t  ${RAM_MB}MB RAM"
echo "[boot] Image:       ${IMG}"
echo "[boot] Userdata:    ${UDATA}"
echo "[boot] ADB:         adb connect localhost:${ADB_PORT}"
$SPICE_MODE && echo "[boot] SPICE:        spice://localhost:5900"

qemu-system-x86_64 \
  "${KVM_FLAGS[@]}" \
  -smp "cores=${CPU_CORES},threads=${CPU_THREADS}" \
  -m "${RAM_MB}" \
  "${HUGEPAGES_FLAGS[@]}" \
  -machine q35,vmport=off \
  -drive "file=${IMG},if=virtio,index=0,${IMG_SNAPSHOT}" \
  -drive "file=${UDATA},if=virtio,index=1,snapshot=off" \
  "${GPU_FLAGS[@]}" \
  "${DISPLAY_FLAGS[@]}" \
  "${AUDIO_FLAGS[@]}" \
  -device virtio-tablet \
  -device virtio-keyboard \
  -device qemu-xhci,id=xhci \
  -device virtio-net-pci,netdev=net0 \
  -netdev "user,id=net0,hostfwd=tcp::${ADB_PORT}-:5555" \
  -device virtio-rng-pci \
  -bios "$OVMF_PATH" \
  "${SERIAL_FLAGS[@]}" &

QEMU_PID=$!
echo "$QEMU_PID" > "$PID_FILE"

if $VNC_MODE || $SPICE_MODE || $HEADLESS; then
  # Return terminal immediately; background subshell cleans up PID file on exit
  ( wait "$QEMU_PID" 2>/dev/null; rm -f "$PID_FILE" ) &
  disown
  echo "[boot] VM running in background (PID ${QEMU_PID})"
  echo "[boot] Stop with: android-vm stop ${PROFILE_NAME}"
else
  # Interactive: terminal is attached to QEMU monitor — block until VM exits
  wait "$QEMU_PID" || true
  rm -f "$PID_FILE"
fi
