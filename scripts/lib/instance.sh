#!/usr/bin/env bash
# Instance config helpers — single source of truth for what an instance is.
#
# Instance config lives at: $ROOT/instances/<name>.json
# Instance disk lives at:   $ROOT/instances/<name>/disk.qcow2
#
# Callers must define $ROOT (workspace root) before sourcing.

# shellcheck source=alloc-port.sh
. "$(dirname "${BASH_SOURCE[0]}")/alloc-port.sh"

instance_dir()       { echo "${ROOT}/instances"; }
instance_path()      { echo "${ROOT}/instances/$1.json"; }
instance_disk_dir()  { echo "${ROOT}/instances/$1"; }
instance_disk()      { echo "${ROOT}/instances/$1/disk.qcow2"; }
instance_pid_file()  { echo "${ROOT}/run/$1.pid"; }
instance_qmp_sock()  { echo "${ROOT}/run/$1.qmp.sock"; }
instance_serial_log(){ echo "${ROOT}/run/$1-serial.log"; }

instance_exists() {
  local name="${1:?}"
  [ -f "$(instance_path "$name")" ]
}

instance_load_field() {
  local name="${1:?}" key="${2:?}"
  jq -r "${key} // empty" "$(instance_path "$name")"
}

# Print used ADB / SPICE ports across all instances as comma-separated lists.
# Used by alloc_port to skip ports already claimed (even if process isn't running).
instance_used_ports() {
  local kind="${1:?adb|spice}"
  local field
  case "$kind" in
    adb)   field=".adb_port"   ;;
    spice) field=".spice_port" ;;
    *) echo "instance_used_ports: kind must be adb|spice" >&2; return 1 ;;
  esac
  local dir
  dir=$(instance_dir)
  [ -d "$dir" ] || { echo ""; return; }
  local out=()
  shopt -s nullglob
  for f in "$dir"/*.json; do
    local v
    v=$(jq -r "${field} // empty" "$f" 2>/dev/null)
    [ -n "$v" ] && out+=("$v")
  done
  shopt -u nullglob
  ( IFS=,; echo "${out[*]}" )
}

instance_running() {
  local name="${1:?}" pid
  local pf
  pf=$(instance_pid_file "$name")
  [ -f "$pf" ] || return 1
  pid=$(cat "$pf" 2>/dev/null || echo "")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Create a new instance config. Allocates free ports.
# Args: name device_profile vm_profile distro [base_adb] [base_spice]
instance_create() {
  local name="${1:?name}" device_profile="${2:?device_profile}" \
        vm_profile="${3:?vm_profile}" distro="${4:?distro}"
  local base_adb="${5:-5555}" base_spice="${6:-5900}"

  if instance_exists "$name"; then
    echo "instance_create: '$name' already exists" >&2
    return 1
  fi
  [ -f "${ROOT}/profiles/${device_profile}.json" ] \
    || { echo "instance_create: device profile not found: ${device_profile}" >&2; return 1; }
  [ -f "${ROOT}/config/vm-profiles/${vm_profile}.json" ] \
    || { echo "instance_create: vm profile not found: ${vm_profile}" >&2; return 1; }
  [ -f "${ROOT}/androiddistro/${distro}.json" ] \
    || { echo "instance_create: distro not found: ${distro}" >&2; return 1; }

  local adb_port spice_port used_adb used_spice
  used_adb=$(instance_used_ports adb)
  used_spice=$(instance_used_ports spice)
  adb_port=$(alloc_port "$base_adb" "$used_adb")
  spice_port=$(alloc_port "$base_spice" "$used_spice")

  mkdir -p "$(instance_dir)" "$(instance_disk_dir "$name")"
  jq -n \
    --arg name "$name" \
    --arg device_profile "$device_profile" \
    --arg vm_profile "$vm_profile" \
    --arg distro "$distro" \
    --argjson adb_port "$adb_port" \
    --argjson spice_port "$spice_port" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name:$name, device_profile:$device_profile, vm_profile:$vm_profile,
      distro:$distro, adb_port:$adb_port, spice_port:$spice_port,
      created_at:$created_at}' \
    > "$(instance_path "$name")"
}

instance_delete() {
  local name="${1:?}"
  rm -rf "$(instance_disk_dir "$name")"
  rm -f  "$(instance_path "$name")"
  rm -f  "$(instance_pid_file "$name")" \
         "$(instance_qmp_sock "$name")" \
         "$(instance_serial_log "$name")"
}

# Emit a JSON array of all instances with computed runtime state.
instance_list_json() {
  local dir
  dir=$(instance_dir)
  [ -d "$dir" ] || { echo "[]"; return; }
  local results="[]"
  shopt -s nullglob
  for f in "$dir"/*.json; do
    local name pid state="stopped"
    name=$(basename "$f" .json)
    if instance_running "$name"; then
      state="running"
      pid=$(cat "$(instance_pid_file "$name")")
    else
      pid=null
    fi
    local pid_arg=(--argjson pid null)
    [ "$pid" != "null" ] && pid_arg=(--argjson pid "$pid")
    results=$(jq \
      --slurpfile cfg "$f" \
      --arg state "$state" \
      "${pid_arg[@]}" \
      '. + [($cfg[0]) + {state:$state, pid:$pid}]' \
      <<< "$results")
  done
  shopt -u nullglob
  echo "$results"
}
