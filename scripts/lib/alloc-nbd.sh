#!/usr/bin/env bash
# Allocate a free /dev/nbdN device under flock so concurrent builds don't collide.
#
# Source then call:
#   nbd_dev=$(alloc_nbd)        → echoes /dev/nbdN (and holds an flock on $NBD_LOCK_FILE)
#   release_nbd "$nbd_dev"      → disconnects + releases the flock
#
# Caller must `sudo qemu-nbd --connect=$nbd_dev <img>` themselves; this helper
# only finds the device and serialises the choice.

NBD_LOCK_FILE=""

alloc_nbd() {
  local max="${1:-16}" lockdir="/tmp/android-vm-locks"
  mkdir -p "$lockdir"

  # Ensure the nbd module is loaded with enough partitions
  if ! lsmod 2>/dev/null | grep -q '^nbd '; then
    sudo modprobe nbd max_part=8 >/dev/null 2>&1 || true
  fi

  local i lockfile fd
  for (( i=0; i<max; i++ )); do
    local dev="/dev/nbd${i}"
    [ -b "$dev" ] || continue
    # Skip if already connected (kernel exposes /sys/block/nbdN/pid when in use)
    local sys_pid_file="/sys/block/nbd${i}/pid"
    [ -f "$sys_pid_file" ] && [ -s "$sys_pid_file" ] && continue
    lockfile="${lockdir}/nbd${i}.lock"
    # Open fd, try non-blocking flock
    exec {fd}>"$lockfile"
    if flock -n "$fd"; then
      NBD_LOCK_FILE="$lockfile"
      NBD_LOCK_FD="$fd"
      echo "$dev"
      return 0
    else
      eval "exec ${fd}>&-"
    fi
  done
  echo "alloc_nbd: no free /dev/nbdN device in [0,$max)" >&2
  return 1
}

release_nbd() {
  local dev="${1:?release_nbd: device required}"
  sudo qemu-nbd --disconnect "$dev" 2>/dev/null || true
  if [ -n "${NBD_LOCK_FD:-}" ]; then
    eval "exec ${NBD_LOCK_FD}>&-" 2>/dev/null || true
    NBD_LOCK_FD=""
  fi
  NBD_LOCK_FILE=""
}
