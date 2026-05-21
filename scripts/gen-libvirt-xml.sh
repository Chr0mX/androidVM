#!/usr/bin/env bash
# Generate a libvirt domain XML for use with virt-manager or virsh.
#
# Usage: gen-libvirt-xml.sh <device-profile> [OPTIONS]
#
#   --vm-profile <name>   VM hardware profile (default: from config/defaults.json)
#   --ram <mb>            Override ram_mb
#   --cores <n>           Override cpu_cores
#   --threads <n>         Override cpu_threads
#   --gpu <device>        Override gpu (virtio-vga | virtio-vga-gl | VGA)
#   --audio <device>      Override audio (ich9-intel-hda | AC97 | none)
#   --adb-port <n>        Override ADB host port
#   --no-spice            Use VNC display instead of SPICE
#   --output <path>       Output path (default: run/<profile>.xml)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_NAME="${1:?Usage: gen-libvirt-xml.sh <device-profile> [OPTIONS]}"
shift || true

VM_PROFILE_NAME=""
OVERRIDE_RAM=""
OVERRIDE_CORES=""
OVERRIDE_THREADS=""
OVERRIDE_GPU=""
OVERRIDE_AUDIO=""
OVERRIDE_ADB_PORT=""
NO_SPICE=false
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-profile) VM_PROFILE_NAME="$2"; shift 2 ;;
    --ram)        OVERRIDE_RAM="$2";     shift 2 ;;
    --cores)      OVERRIDE_CORES="$2";   shift 2 ;;
    --threads)    OVERRIDE_THREADS="$2"; shift 2 ;;
    --gpu)        OVERRIDE_GPU="$2";     shift 2 ;;
    --audio)      OVERRIDE_AUDIO="$2";   shift 2 ;;
    --adb-port)   OVERRIDE_ADB_PORT="$2"; shift 2 ;;
    --no-spice)   NO_SPICE=true;         shift   ;;
    --output)     OUTPUT_PATH="$2";      shift 2 ;;
    *) echo "[gen-libvirt-xml] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Config: defaults.json ─────────────────────────────────────────────────────
DEFAULTS_JSON="${ROOT}/config/defaults.json"
ADB_PORT=$(jq -r '.adb_port // 5555' "$DEFAULTS_JSON" 2>/dev/null || echo "5555")

# ── Resolve VM hardware profile ───────────────────────────────────────────────
if [ -z "$VM_PROFILE_NAME" ]; then
  VM_PROFILE_NAME=$(jq -r '.default_vm_profile // "balanced"' "$DEFAULTS_JSON" 2>/dev/null || echo "balanced")
fi

VM_PROFILE_FILE="${ROOT}/config/vm-profiles/${VM_PROFILE_NAME}.json"
if [ ! -f "$VM_PROFILE_FILE" ]; then
  echo "[gen-libvirt-xml] ERROR: VM profile not found: ${VM_PROFILE_FILE}" >&2
  echo "[gen-libvirt-xml] Available:" >&2
  for f in "${ROOT}"/config/vm-profiles/*.json; do
    echo "  $(basename "$f" .json)" >&2
  done
  exit 1
fi

RAM_MB=$(     jq -r '.ram_mb'      "$VM_PROFILE_FILE")
CPU_CORES=$(  jq -r '.cpu_cores'   "$VM_PROFILE_FILE")
CPU_THREADS=$(jq -r '.cpu_threads' "$VM_PROFILE_FILE")
HUGEPAGES=$(  jq -r '.hugepages'   "$VM_PROFILE_FILE")
GPU=$(        jq -r '.gpu'         "$VM_PROFILE_FILE")
AUDIO=$(      jq -r '.audio'       "$VM_PROFILE_FILE")

# ── Read distro sidecar for audio device ─────────────────────────────────────
DISTRO_AUDIO_DEVICE="ich9-intel-hda"
DISTRO_SIDECAR="${ROOT}/builds/android11-${PROFILE_NAME}.distro"
if [ -f "$DISTRO_SIDECAR" ]; then
  _DISTRO=$(cat "$DISTRO_SIDECAR")
  _DISTRO_FILE="${ROOT}/androiddistro/${_DISTRO}.json"
  if [ -f "$_DISTRO_FILE" ]; then
    _DA=$(jq -r '.qemu.audio_device // empty' "$_DISTRO_FILE" 2>/dev/null || true)
    [ -n "$_DA" ] && DISTRO_AUDIO_DEVICE="$_DA"
  fi
fi

# ── CLI overrides ─────────────────────────────────────────────────────────────
[ -n "$OVERRIDE_RAM" ]      && RAM_MB="$OVERRIDE_RAM"
[ -n "$OVERRIDE_CORES" ]    && CPU_CORES="$OVERRIDE_CORES"
[ -n "$OVERRIDE_THREADS" ]  && CPU_THREADS="$OVERRIDE_THREADS"
[ -n "$OVERRIDE_GPU" ]      && GPU="$OVERRIDE_GPU"
[ -n "$OVERRIDE_AUDIO" ]    && AUDIO="$OVERRIDE_AUDIO"
[ -n "$OVERRIDE_ADB_PORT" ] && ADB_PORT="$OVERRIDE_ADB_PORT"

# ── Boot sidecars ─────────────────────────────────────────────────────────────
KERNEL="${ROOT}/builds/android11-${PROFILE_NAME}-kernel"
INITRD="${ROOT}/builds/android11-${PROFILE_NAME}-initrd.img"
CMDLINE_FILE="${ROOT}/builds/android11-${PROFILE_NAME}-cmdline"

if [ ! -f "$KERNEL" ] || [ ! -f "$INITRD" ] || [ ! -f "$CMDLINE_FILE" ]; then
  echo "[gen-libvirt-xml] ERROR: Boot sidecars not found for '${PROFILE_NAME}'" >&2
  echo "[gen-libvirt-xml] Run: bash scripts/set-profile.sh ${PROFILE_NAME} --rebuild" >&2
  exit 1
fi
ISO_PARAMS=$(cat "$CMDLINE_FILE")
APPEND="root=/dev/ram0 ${ISO_PARAMS} SRC= DATA=/dev/sda2 console=ttyS0,115200n8 androidboot.enable_console=1 quiet"

# ── Image paths ───────────────────────────────────────────────────────────────
IMG="${ROOT}/builds/android11-${PROFILE_NAME}-latest.qcow2"
[ -f "$IMG" ] || {
  echo "[gen-libvirt-xml] ERROR: Image not found: $IMG" >&2
  echo "[gen-libvirt-xml] Build it first: bash scripts/set-profile.sh ${PROFILE_NAME}" >&2
  exit 1
}

mkdir -p "${ROOT}/run" "${ROOT}/logs"
SERIAL_LOG="${ROOT}/logs/${PROFILE_NAME}-serial.log"

# ── Derived values ────────────────────────────────────────────────────────────
VCPUS=$(( CPU_CORES * CPU_THREADS ))
DOMAIN_NAME="android-${PROFILE_NAME}"
QEMU_BIN=$(command -v qemu-system-x86_64 2>/dev/null || echo "/usr/bin/qemu-system-x86_64")

# ── GPU → libvirt video model ─────────────────────────────────────────────────
case "$GPU" in
  virtio-vga|virtio-vga-gl) VIDEO_MODEL="virtio" ;;
  VGA)                       VIDEO_MODEL="vga"    ;;
  *)                         VIDEO_MODEL="virtio" ;;
esac

# ── Audio → libvirt sound model ───────────────────────────────────────────────
SOUND_XML=""
EFFECTIVE_AUDIO="$AUDIO"
[ "$AUDIO" = "pa" ] && EFFECTIVE_AUDIO="$DISTRO_AUDIO_DEVICE"
case "$EFFECTIVE_AUDIO" in
  ich9-intel-hda) SOUND_XML="    <sound model='ich9'/>" ;;
  AC97)           SOUND_XML="    <sound model='ac97'/>" ;;
  *)              SOUND_XML="" ;;
esac

# ── Hugepages block ───────────────────────────────────────────────────────────
HUGEPAGES_BLOCK=""
[ "$HUGEPAGES" = "true" ] && HUGEPAGES_BLOCK="  <memoryBacking><hugepages/></memoryBacking>"

# ── Display XML ───────────────────────────────────────────────────────────────
CHANNEL_XML=""
if $NO_SPICE; then
  DISPLAY_XML="    <graphics type='vnc' port='-1' autoport='yes'><listen type='address'/></graphics>"
else
  DISPLAY_XML="    <graphics type='spice' autoport='yes'><listen type='address'/><image compression='off'/></graphics>"
  CHANNEL_XML="    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>"
fi

# ── Output path ───────────────────────────────────────────────────────────────
[ -z "$OUTPUT_PATH" ] && OUTPUT_PATH="${ROOT}/run/${PROFILE_NAME}.xml"

# ── Generate XML ──────────────────────────────────────────────────────────────
cat > "$OUTPUT_PATH" <<XMLEOF
<domain type='kvm'>
  <name>${DOMAIN_NAME}</name>
  <memory unit='MiB'>${RAM_MB}</memory>
  <vcpu placement='static'>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-10.0'>hvm</type>
    <kernel>${KERNEL}</kernel>
    <initrd>${INITRD}</initrd>
    <cmdline>${APPEND}</cmdline>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='${CPU_CORES}' threads='${CPU_THREADS}'/>
  </cpu>
${HUGEPAGES_BLOCK}
  <devices>
    <emulator>${QEMU_BIN}</emulator>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none'/>
      <source file='${IMG}'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
      <boot order='1'/>
    </disk>
    <controller type='usb' index='0' model='ich9-ehci1'/>
    <controller type='usb' index='0' model='ich9-uhci1'><master startport='0'/></controller>
    <controller type='usb' index='0' model='ich9-uhci2'><master startport='2'/></controller>
    <controller type='usb' index='0' model='ich9-uhci3'><master startport='4'/></controller>
    <input type='tablet' bus='usb'/>
    <input type='keyboard' bus='ps2'/>
    <interface type='user'>
      <model type='virtio'/>
      <portForward proto='tcp'>
        <range start='${ADB_PORT}' to='5555'/>
      </portForward>
    </interface>
    <video>
      <model type='${VIDEO_MODEL}' heads='1' primary='yes'/>
    </video>
${DISPLAY_XML}
${CHANNEL_XML}
${SOUND_XML}
    <serial type='file'>
      <source path='${SERIAL_LOG}' append='on'/>
      <target type='isa-serial' port='0'/>
    </serial>
    <console type='file'>
      <source path='${SERIAL_LOG}' append='on'/>
      <target type='serial' port='0'/>
    </console>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <memballoon model='virtio'/>
  </devices>
</domain>
XMLEOF

echo "[gen-libvirt-xml] XML written to: ${OUTPUT_PATH}"
echo "[gen-libvirt-xml] Domain: ${DOMAIN_NAME}  RAM: ${RAM_MB}MB  vCPUs: ${VCPUS} (${CPU_CORES}c/${CPU_THREADS}t)"
