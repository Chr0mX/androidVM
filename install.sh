#!/usr/bin/env bash
# ============================================================================
#  install.sh — Android 11 VM workspace auto-installer
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/Chr0mX/androidVM/main/install.sh | bash
#    # or clone first then:
#    bash install.sh [--repo <git-url>] [--dir <workspace>] [--no-download]
#                    [--profile <name>] [--boot] [--skip-verify]
#
#  What this does:
#    1. Detects and validates host (OS, CPU virtualisation, disk space)
#    2. Installs all required system packages
#    3. Clones the workspace repo (or uses an existing checkout)
#    4. Downloads and verifies the pre-built intermediate base image
#       (or builds it locally if --no-download is given)
#    5. Applies a starter profile and produces a bootable image
#    6. Optionally boots the VM and runs verification
#
#  Tested on: Ubuntu 22.04 LTS, Debian 12, Fedora 38
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Colour helpers ────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m' YEL='\033[0;33m' GRN='\033[0;32m'
  BLU='\033[0;34m' DIM='\033[2m'    NC='\033[0m'
else
  RED='' YEL='' GRN='' BLU='' DIM='' NC=''
fi

log()  { printf "${BLU}[install]${NC} %s\n" "$*"; }
ok()   { printf "${GRN}[  ok  ]${NC} %s\n" "$*"; }
warn() { printf "${YEL}[ warn ]${NC} %s\n" "$*"; }
die()  { printf "${RED}[ FAIL ]${NC} %s\n" "$*"; exit 1; }

usage() {
  cat <<'HELP'
Android 11 VM — install.sh

SYNOPSIS
  # Minimal one-liner (curl pipe):
  curl -fsSL https://raw.githubusercontent.com/Chr0mX/androidVM/main/install.sh | bash

  # With options via env vars (required when piping through curl):
  curl -fsSL .../install.sh | ANDROID_VM_PROFILE=pixel7-ap1a ANDROID_VM_BOOT=1 bash

  # Cloned locally:
  bash install.sh [OPTIONS]

OPTIONS
  --profile <name>    Device profile to apply   (default: pixel6a-bp1a)
  --dir <path>        Workspace directory        (default: ~/android11-vm)
  --repo <url>        Git repo to clone          (default: Chr0mX/androidVM)
  --boot              Launch VM after building
  --skip-verify       Skip ADB verification after boot
  --no-download       Build intermediate image locally instead of fetching release

ENV VAR OVERRIDES (use these when piping via curl)
  ANDROID_VM_PROFILE    same as --profile
  ANDROID_VM_DIR        same as --dir
  ANDROID_VM_REPO       same as --repo
  ANDROID_VM_BOOT       same as --boot       (set to any non-empty value)
  ANDROID_VM_NO_DL      same as --no-download (set to any non-empty value)
  ANDROID_VM_SKIP_VFY   same as --skip-verify (set to any non-empty value)

EXAMPLES
  # Pipe install, boot with Pixel 7 profile
  curl -fsSL https://raw.githubusercontent.com/Chr0mX/androidVM/main/install.sh \
    | ANDROID_VM_PROFILE=pixel7-ap1a ANDROID_VM_BOOT=1 bash

  # Local install, build intermediate locally, boot and verify
  bash install.sh --profile samsung-s23-eu --no-download --boot
HELP
}

# ── Defaults (env vars take lowest precedence, flags override them) ────────
REPO_URL="${ANDROID_VM_REPO:-https://github.com/Chr0mX/androidVM.git}"
WORKSPACE_DIR="${ANDROID_VM_DIR:-${HOME}/android11-vm}"
STARTER_PROFILE="${ANDROID_VM_PROFILE:-pixel6a-bp1a}"
DO_BOOT="${ANDROID_VM_BOOT:+true}"; DO_BOOT="${DO_BOOT:-false}"
SKIP_VERIFY="${ANDROID_VM_SKIP_VFY:+true}"; SKIP_VERIFY="${SKIP_VERIFY:-false}"
NO_DOWNLOAD="${ANDROID_VM_NO_DL:+true}"; NO_DOWNLOAD="${NO_DOWNLOAD:-false}"
BASE_IMAGE_RELEASE="https://github.com/Chr0mX/androidVM/releases/latest/download"
MIN_DISK_GB=25
MIN_RAM_GB=6

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO_URL="$2";        shift 2 ;;
    --dir)          WORKSPACE_DIR="$2";   shift 2 ;;
    --profile)      STARTER_PROFILE="$2"; shift 2 ;;
    --boot)         DO_BOOT=true;         shift   ;;
    --skip-verify)  SKIP_VERIFY=true;     shift   ;;
    --no-download)  NO_DOWNLOAD=true;     shift   ;;
    --debug)        set -x;              shift   ;;
    -h|--help)      usage; exit 0         ;;
    *) die "Unknown argument: $1" ;;
  esac
done

phase() { printf "\n${DIM}━━━ %s ━━━${NC}\n" "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Host validation
# ─────────────────────────────────────────────────────────────────────────────
phase "Host validation"

if [ -f /etc/os-release ]; then
  . /etc/os-release
  log "Detected OS: ${PRETTY_NAME:-$ID}"
  case "${ID:-}" in
    ubuntu|debian)  PKG_MANAGER="apt"    ;;
    fedora)         PKG_MANAGER="dnf"    ;;
    arch|manjaro)   PKG_MANAGER="pacman" ;;
    *)
      warn "OS '${ID:-unknown}' not explicitly tested — attempting apt-style install"
      PKG_MANAGER="apt"
      ;;
  esac
else
  die "Cannot detect OS. /etc/os-release missing."
fi

ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] || die "Requires x86_64 host. Detected: $ARCH"
ok "Architecture: x86_64"

CPU_VENDOR="unknown"
if grep -q 'GenuineIntel' /proc/cpuinfo; then
  CPU_VENDOR="intel"
elif grep -q 'AuthenticAMD' /proc/cpuinfo; then
  CPU_VENDOR="amd"
fi

if grep -qE 'vmx|svm' /proc/cpuinfo; then
  ok "CPU virtualisation extensions detected (${CPU_VENDOR})"
  if [ "$CPU_VENDOR" = "intel" ]; then
    sudo modprobe kvm_intel 2>/dev/null \
      && log "Loaded kvm_intel module" \
      || warn "modprobe kvm_intel failed — may already be loaded"
  elif [ "$CPU_VENDOR" = "amd" ]; then
    sudo modprobe kvm_amd 2>/dev/null \
      && log "Loaded kvm_amd module" \
      || warn "modprobe kvm_amd failed — may already be loaded"
  fi
else
  warn "vmx/svm not found in /proc/cpuinfo — KVM will not be available"
  warn "The VM will run via QEMU TCG emulation (much slower)"
fi

if [ -e /dev/kvm ]; then
  ok "KVM device available: /dev/kvm"
  KVM_ENABLED=true
else
  warn "/dev/kvm not available — attempting to load KVM module"
  KVM_ENABLED=false
fi

if $KVM_ENABLED && [ "${USER:-root}" != "root" ] && ! groups | grep -q '\bkvm\b'; then
  log "Adding ${USER} to the kvm group..."
  sudo usermod -aG kvm "$USER" \
    && warn "Added to kvm group — you must log out and back in for this to take effect" \
    || warn "Failed to add to kvm group — run: sudo usermod -aG kvm \$USER"
fi

AVAIL_GB=$(df --output=avail -BG "${HOME}" | tail -1 | tr -d 'G ')
if [ "${AVAIL_GB:-0}" -lt "$MIN_DISK_GB" ]; then
  die "Need at least ${MIN_DISK_GB} GB free. Available: ${AVAIL_GB} GB"
fi
ok "Disk space: ${AVAIL_GB} GB available (need ${MIN_DISK_GB})"

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
if [ "$TOTAL_RAM_GB" -lt "$MIN_RAM_GB" ]; then
  warn "Less than ${MIN_RAM_GB} GB RAM detected (${TOTAL_RAM_GB} GB)"
  warn "VM will use 2 GB — may be slow with other applications running"
fi
ok "RAM: ${TOTAL_RAM_GB} GB"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Install packages
# ─────────────────────────────────────────────────────────────────────────────
phase "Installing packages"

install_apt() {
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils qemu-kvm \
    android-tools-adb \
    e2fsprogs python3 python3-pip \
    jq curl rsync git wget \
    ovmf p7zip-full ca-certificates \
    bridge-utils lzip squashfs-tools parted unzip tar \
    grub-efi-amd64-bin
  # simg2img/img2simg: standalone on Ubuntu ≤22.04, part of libsparse on Debian 12+ / Ubuntu 24.04+
  if apt-cache show android-sdk-libsparse-utils &>/dev/null 2>&1; then
    sudo apt-get install -y --no-install-recommends android-sdk-libsparse-utils
  else
    sudo apt-get install -y --no-install-recommends simg2img img2simg 2>/dev/null \
      || warn "simg2img not available — sparse image conversion may not work"
  fi
  pip3 install jsonschema --quiet --break-system-packages 2>/dev/null \
    || pip3 install jsonschema --quiet
}

install_dnf() {
  sudo dnf install -y \
    qemu-system-x86 qemu-img qemu-kvm \
    android-tools \
    e2fsprogs python3 python3-pip \
    jq curl rsync git wget \
    edk2-ovmf p7zip \
    bridge-utils lzip squashfs-tools parted unzip tar
  pip3 install jsonschema --quiet
}

install_pacman() {
  sudo pacman -Sy --noconfirm \
    qemu-full \
    android-tools \
    e2fsprogs python python-pip \
    jq curl rsync git \
    edk2-ovmf p7zip
  pip3 install jsonschema --quiet
}

case "$PKG_MANAGER" in
  apt)    install_apt    ;;
  dnf)    install_dnf    ;;
  pacman) install_pacman ;;
esac
ok "Packages installed"

for bin in qemu-system-x86_64 qemu-img adb simg2img python3 jq; do
  command -v "$bin" > /dev/null 2>&1 \
    || die "Required binary not found after install: $bin"
done
ok "All required binaries present"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Clone or update workspace repo
# ─────────────────────────────────────────────────────────────────────────────
phase "Workspace setup"

if [ -d "${WORKSPACE_DIR}/.git" ]; then
  log "Repo already exists at ${WORKSPACE_DIR} — pulling latest"
  git -C "$WORKSPACE_DIR" pull --ff-only
else
  log "Cloning ${REPO_URL} → ${WORKSPACE_DIR}"
  git clone "$REPO_URL" "$WORKSPACE_DIR"
fi

cd "$WORKSPACE_DIR"

mkdir -p base intermediate builds profiles scripts/lib arm-trans gapps \
         logs userdata mnt/{system,vendor,product} run cache \
         config/vm-profiles
ok "Workspace ready at ${WORKSPACE_DIR}"

find scripts/ -name '*.sh' -exec chmod +x {} \;
chmod +x scripts/set-profile.sh scripts/verify.sh 2>/dev/null || true

# Source hardware detection helpers (available after clone)
if [ -f "scripts/lib/detect-hardware.sh" ]; then
  # shellcheck source=scripts/lib/detect-hardware.sh
  . "scripts/lib/detect-hardware.sh"
fi

# Install android-vm CLI system-wide
if [ -f "${WORKSPACE_DIR}/android-vm" ]; then
  chmod +x "${WORKSPACE_DIR}/android-vm"
  if sudo ln -sf "${WORKSPACE_DIR}/android-vm" /usr/local/bin/android-vm 2>/dev/null; then
    ok "android-vm command installed to /usr/local/bin/android-vm"
  else
    warn "Could not install to /usr/local/bin — run manually:"
    warn "  sudo ln -sf ${WORKSPACE_DIR}/android-vm /usr/local/bin/android-vm"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Fetch or build the intermediate base image
# ─────────────────────────────────────────────────────────────────────────────
phase "Base image"

INTERMEDIATE="intermediate/blissos14-gapps-arm.qcow2"

if [ -f "$INTERMEDIATE" ]; then
  ok "Intermediate image already present — skipping download"
else
  if $NO_DOWNLOAD; then
    log "--no-download set — building intermediate from scratch"
    log "This will take 30–90 minutes depending on your hardware"
    [ -f "gapps/mindthegapps.zip" ] \
      || die "GApps zip missing at gapps/mindthegapps.zip — place it there first"
    if [ ! -d "arm-trans/libndk_translation" ]; then
      log "Fetching ARM translation libs..."
      bash scripts/lib/fetch-arm-trans.sh arm-trans/
    fi
    bash scripts/build-intermediate.sh
  else
    if [ -f "scripts/lib/fetch-release.sh" ]; then
      log "Downloading intermediate image via GitHub Releases (split-archive aware, resumable)..."
      OWNER_REPO=$(echo "$REPO_URL" \
        | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|; s|.*github\.com[:/]\(.*\)|\1|')
      ROOT="${WORKSPACE_DIR}" bash scripts/lib/fetch-release.sh \
        "$OWNER_REPO" "blissos14-gapps-arm.qcow2*" "intermediate/" \
        --tag-prefix "bliss14-base-" \
        || die "No bliss14 release found on GitHub. Trigger the CI workflow first:
  https://github.com/${OWNER_REPO}/actions/workflows/build-base.yml
  Then re-run the installer once the release is published."
    else
      log "Downloading pre-built intermediate image from GitHub Releases..."
      curl -L --retry 5 --retry-delay 10 --progress-bar \
           "${BASE_IMAGE_RELEASE}/blissos14-gapps-arm.qcow2" \
           -o "${INTERMEDIATE}.tmp" \
        || die "Download failed. Check https://github.com/Chr0mX/androidVM/releases for available images."
      mv "${INTERMEDIATE}.tmp" "$INTERMEDIATE"
    fi

    [ -f "$INTERMEDIATE" ] && ok "Intermediate image ready ($(du -sh "$INTERMEDIATE" | cut -f1))"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — Validate starter profile exists
# ─────────────────────────────────────────────────────────────────────────────
phase "Profile validation"

PROFILE_FILE="profiles/${STARTER_PROFILE}.json"

if [ ! -f "$PROFILE_FILE" ]; then
  warn "Profile '${STARTER_PROFILE}' not found — writing a minimal placeholder"
  cat > "$PROFILE_FILE" << 'PROFILE_EOF'
{
  "meta": {
    "id": "pixel6a-bp1a",
    "description": "Pixel 6a placeholder — replace fingerprint values with a real build",
    "created": "2024-01-01"
  },
  "system": {
    "ro.product.manufacturer": "Google",
    "ro.product.model": "Pixel 6a",
    "ro.product.name": "bluejay",
    "ro.product.device": "bluejay",
    "ro.product.brand": "google",
    "ro.build.fingerprint": "google/bluejay/bluejay:13/BP1A.240905.003/12231197:user/release-keys",
    "ro.build.description": "bluejay-user 13 BP1A.240905.003 12231197 release-keys",
    "ro.build.tags": "release-keys",
    "ro.build.type": "user",
    "ro.system.build.fingerprint": "google/bluejay/bluejay:13/BP1A.240905.003/12231197:user/release-keys",
    "ro.product.system.manufacturer": "Google",
    "ro.product.system.model": "Pixel 6a",
    "ro.product.system.name": "bluejay",
    "ro.product.system.device": "bluejay",
    "ro.product.system.brand": "google"
  },
  "vendor": {
    "ro.product.vendor.manufacturer": "Google",
    "ro.product.vendor.model": "Pixel 6a",
    "ro.product.vendor.name": "bluejay",
    "ro.product.vendor.device": "bluejay",
    "ro.product.vendor.brand": "google",
    "ro.vendor.build.fingerprint": "google/bluejay/bluejay:13/BP1A.240905.003/12231197:user/release-keys"
  }
}
PROFILE_EOF
  warn "Edit ${PROFILE_FILE} with real fingerprint values before production use"
fi

python3 scripts/lib/profile-validator.py "$PROFILE_FILE" \
  && ok "Profile '${STARTER_PROFILE}' valid" \
  || die "Profile validation failed — fix ${PROFILE_FILE} before continuing"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — Build the profile image
# ─────────────────────────────────────────────────────────────────────────────
phase "Building profile image: ${STARTER_PROFILE}"

if ! lsmod | grep -q nbd; then
  sudo modprobe nbd max_part=8
  sleep 1
fi

bash scripts/set-profile.sh "$STARTER_PROFILE"
ok "Profile image built"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — Create userdata volume
# ─────────────────────────────────────────────────────────────────────────────
phase "Userdata volume"

UDATA="userdata/userdata-${STARTER_PROFILE}.qcow2"
if [ -f "$UDATA" ]; then
  ok "Userdata volume already exists — leaving it intact"
else
  qemu-img create -f qcow2 "$UDATA" 8G
  ok "Userdata volume created (8 GB, sparse)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — Optionally boot and verify
# ─────────────────────────────────────────────────────────────────────────────
if $DO_BOOT; then
  phase "Booting VM"
  bash scripts/boot.sh "$STARTER_PROFILE" &
  QEMU_PID=$!
  log "VM started (PID ${QEMU_PID}), waiting 40 seconds for ADB..."
  sleep 40

  if $SKIP_VERIFY; then
    ok "Boot launched — skipping verification (--skip-verify)"
  else
    phase "Running verification"
    if bash scripts/verify.sh "$PROFILE_FILE"; then
      ok "All checks passed"
    else
      warn "Some verification checks failed — see output above"
      warn "The VM is still running. Connect with: adb connect localhost:5555"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
phase "Install complete"

cat << EOF

${GRN}Everything is set up in: ${WORKSPACE_DIR}${NC}

Quick reference:

  ${DIM}# Start the VM (unified CLI)${NC}
  android-vm start ${STARTER_PROFILE}
  android-vm start ${STARTER_PROFILE} --vm-profile performance

  ${DIM}# Stop / reset userdata${NC}
  android-vm stop ${STARTER_PROFILE}
  android-vm reset ${STARTER_PROFILE}

  ${DIM}# Diagnose issues${NC}
  android-vm doctor

  ${DIM}# List available profiles${NC}
  android-vm profiles

  ${DIM}# Build a profile image (required before first start)${NC}
  cd ${WORKSPACE_DIR}
  bash scripts/set-profile.sh ${STARTER_PROFILE} --rebuild

  ${DIM}# Connect via ADB${NC}
  adb connect localhost:5555

Workspace layout:
  android-vm     → unified CLI (also at /usr/local/bin/android-vm)
  base/          → read-only source image (never boot this)
  intermediate/  → GApps + ARM trans baked in (never boot this)
  builds/        → per-profile bootable images  ← boot these
  userdata/      → per-profile userdata volumes
  profiles/      → JSON device identity profiles
  config/        → defaults.json, device-spoof.json, vm-profiles/
  logs/          → build and verify logs

EOF

# Hardware summary
if command -v detect_ram_mb &>/dev/null; then
  TOTAL_MB=$(detect_ram_mb)
  TOTAL_GB=$(( TOTAL_MB / 1024 ))
  if   [ "$TOTAL_GB" -ge 8 ]; then REC_VM_PROFILE="performance"
  elif [ "$TOTAL_GB" -ge 6 ]; then REC_VM_PROFILE="balanced"
  elif [ "$TOTAL_GB" -ge 4 ]; then REC_VM_PROFILE="balanced"
  else                              REC_VM_PROFILE="lowram"; fi
  printf "  Host RAM: %d GB   Cores: %s   Recommended vm-profile: %s\n\n" \
    "$TOTAL_GB" "$(detect_cores)" "$REC_VM_PROFILE"
fi
