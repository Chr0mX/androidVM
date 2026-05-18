#!/usr/bin/env bash
# Hardware detection helpers — source this file, do not execute directly.
# All functions write results to stdout; do not produce side-effect output.

detect_cpu_vendor() {
  local vendor
  vendor=$(grep 'vendor_id' /proc/cpuinfo | head -1 | awk '{print $3}')
  case "$vendor" in
    GenuineIntel) echo "intel" ;;
    AuthenticAMD)  echo "amd"   ;;
    *)             echo "unknown" ;;
  esac
}

detect_ram_mb() {
  awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo
}

detect_cores() {
  if command -v nproc &>/dev/null; then
    nproc
  else
    grep -c '^processor' /proc/cpuinfo
  fi
}

suggest_vm_ram_mb() {
  local total_mb="${1:?suggest_vm_ram_mb requires total_mb}"
  local half=$(( total_mb / 2 ))
  [ "$half" -lt 2048 ] && half=2048
  [ "$half" -gt 8192 ] && half=8192
  echo "$half"
}

suggest_vm_cores() {
  local total_cores="${1:?suggest_vm_cores requires total_cores}"
  local half=$(( total_cores / 2 ))
  [ "$half" -lt 2 ] && half=2
  echo "$half"
}

load_kvm_module() {
  local vendor="${1:-unknown}"
  case "$vendor" in
    intel) sudo modprobe kvm_intel 2>/dev/null && return 0 || return 1 ;;
    amd)   sudo modprobe kvm_amd   2>/dev/null && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

ensure_kvm_group() {
  # No-op when root — root always has /dev/kvm access
  [ "${USER:-root}" = "root" ] && return 0
  groups 2>/dev/null | grep -q '\bkvm\b' && return 0
  sudo usermod -aG kvm "$USER" 2>/dev/null \
    && { echo "[detect-hardware] Added ${USER} to kvm group — re-login required" >&2; return 1; } \
    || { echo "[detect-hardware] Could not add ${USER} to kvm group — run: sudo usermod -aG kvm \$USER" >&2; return 1; }
}

check_hugepages() {
  if [ ! -f /proc/meminfo ]; then
    echo "unavailable"
    return
  fi
  local total free
  total=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
  free=$(awk '/HugePages_Free/  {print $2}' /proc/meminfo)
  if [ -z "$total" ] || [ "$total" -eq 0 ]; then
    echo "unavailable"
  else
    echo "available:${free}"
  fi
}
