#!/usr/bin/env bash
# Download release assets from GitHub Releases API with split-archive support.
#
# Usage: fetch-release.sh <owner/repo> <asset-pattern> <dest-dir>
#
#   owner/repo     e.g. Chr0mX/androidVM
#   asset-pattern  shell glob, e.g. "*.qcow2*"
#   dest-dir       directory where the final file is placed
#
# Env vars:
#   GITHUB_TOKEN   Optional — increases API rate limit from 60 to 5000 req/h
#   ROOT           Repo root; cache lands in $ROOT/cache (auto-detected if unset)
#
# Split archives:  the CI splits large files with GNU split -b 1900M, producing
#                  <base>.part-aa, <base>.part-ab, … — reassembled automatically.
set -euo pipefail
IFS=$'\n\t'

OWNER_REPO="${1:?Usage: fetch-release.sh <owner/repo> <asset-pattern> <dest-dir> [--tag-prefix <prefix>]}"
PATTERN="${2:?}"
DEST_DIR="${3:?}"
TAG_PREFIX=""

shift 3 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag-prefix) TAG_PREFIX="${2:?--tag-prefix requires a value}"; shift 2 ;;
    *) echo "[fetch-release] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ROOT:="$(cd "${SCRIPT_DIR}/../.." && pwd)"}"
CACHE_DIR="${ROOT}/cache"
mkdir -p "$CACHE_DIR" "$DEST_DIR"

log()  { echo "[fetch-release] $*"; }
warn() { echo "[fetch-release] WARNING: $*" >&2; }
die()  { echo "[fetch-release] ERROR: $*" >&2; exit 1; }

# ── GitHub API call ────────────────────────────────────────────────────────────
api_get() {
  local url="$1"
  local auth_header=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth_header=(-H "Authorization: token ${GITHUB_TOKEN}")

  local http_code
  # Omit -f so curl always writes the response body and the http_code -w output
  # regardless of HTTP status — we check the code ourselves below.
  http_code=$(curl -sSL -w "%{http_code}" "${auth_header[@]}" \
    -H "Accept: application/vnd.github.v3+json" \
    "$url" -o /tmp/fetch-release-api.json 2>/dev/null; echo)
  http_code="${http_code: -3}"

  if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
    warn "GitHub API rate limited (HTTP ${http_code})."
    warn "Set GITHUB_TOKEN env var to increase limit: export GITHUB_TOKEN=<token>"
    local api_msg
    api_msg=$(jq -r '.message // empty' /tmp/fetch-release-api.json 2>/dev/null || true)
    [ -n "$api_msg" ] && warn "GitHub says: ${api_msg}"
    return 1
  fi
  if [ "$http_code" != "200" ]; then
    warn "GitHub API returned HTTP ${http_code} for ${url}"
    return 1
  fi
  cat /tmp/fetch-release-api.json
}

# ── Resume-capable download ────────────────────────────────────────────────────
download_file() {
  local url="$1" dest="$2"
  curl -L -C - \
    --retry 5 --retry-delay 10 --retry-max-time 300 \
    --progress-bar \
    "$url" -o "$dest"
}

# ── SHA256 verification ────────────────────────────────────────────────────────
verify_sha256() {
  local file="$1" expected="$2"
  local actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [ "$actual" = "$expected" ]; then
    log "SHA256 OK: $(basename "$file")"
    return 0
  else
    warn "SHA256 mismatch for $(basename "$file")"
    warn "  expected: $expected"
    warn "  actual:   $actual"
    return 1
  fi
}

# ── Pattern match (shell glob) ─────────────────────────────────────────────────
matches_pattern() {
  local name="$1" pattern="$2"
  case "$name" in
    $pattern) return 0 ;;
    *)        return 1 ;;
  esac
}

# ── Main ───────────────────────────────────────────────────────────────────────
if [ -n "$TAG_PREFIX" ]; then
  API_URL="https://api.github.com/repos/${OWNER_REPO}/releases?per_page=20"
  log "Fetching releases (tag prefix: ${TAG_PREFIX}): ${OWNER_REPO}"
else
  API_URL="https://api.github.com/repos/${OWNER_REPO}/releases/latest"
  log "Fetching latest release: ${OWNER_REPO}"
fi

RELEASE_JSON=""
if ! RELEASE_JSON=$(api_get "$API_URL" 2>/dev/null); then
  warn "GitHub API call failed — falling back to direct releases/latest/download URL"
  # Derive base filename from pattern (strip globs)
  BASE_NAME="${PATTERN//\*/}"
  BASE_NAME="${BASE_NAME%%.*}"
  FALLBACK_URL="https://github.com/${OWNER_REPO}/releases/latest/download/${BASE_NAME}.qcow2"
  log "Trying: ${FALLBACK_URL}"
  download_file "$FALLBACK_URL" "${DEST_DIR}/$(basename "$FALLBACK_URL")"
  exit 0
fi

# When --tag-prefix is set the API returned an array; pick the first matching release
if [ -n "$TAG_PREFIX" ]; then
  RESP_TYPE=$(echo "$RELEASE_JSON" | jq -r 'type' 2>/dev/null || echo "invalid")
  if [ "$RESP_TYPE" != "array" ]; then
    API_MSG=$(echo "$RELEASE_JSON" | jq -r '.message // empty' 2>/dev/null || true)
    [ -n "$API_MSG" ] && warn "GitHub API message: ${API_MSG}"
    warn "Expected a JSON array from the releases endpoint, got: ${RESP_TYPE}"
    warn "If rate limited, set GITHUB_TOKEN: export GITHUB_TOKEN=<your-token>"
    die "Cannot list releases for ${OWNER_REPO}"
  fi
  RELEASE_JSON=$(echo "$RELEASE_JSON" \
    | jq --arg p "$TAG_PREFIX" 'map(select(.tag_name | startswith($p))) | first // empty')
  if [ -z "$RELEASE_JSON" ] || [ "$RELEASE_JSON" = "null" ]; then
    die "No release with tag prefix '${TAG_PREFIX}' found in ${OWNER_REPO}"
  fi
  log "Using release: $(echo "$RELEASE_JSON" | jq -r '.tag_name')"
fi

# Check for empty assets
ASSET_COUNT=$(echo "$RELEASE_JSON" | jq '.assets | length')
if [ "${ASSET_COUNT:-0}" -eq 0 ]; then
  die "No assets found in latest release of ${OWNER_REPO}. Publish a release first."
fi

# Build asset list: "name url" per line
mapfile -t ASSET_LINES < <(echo "$RELEASE_JSON" | \
  jq -r '.assets[] | "\(.name) \(.browser_download_url)"')

log "Release has ${#ASSET_LINES[@]} asset(s)"

# ── Filter matching assets ─────────────────────────────────────────────────────
MATCHING=()
SHA256_ASSETS=()

for line in "${ASSET_LINES[@]}"; do
  name="${line%% *}"
  url="${line#* }"
  if matches_pattern "$name" "$PATTERN"; then
    MATCHING+=("$name $url")
  fi
  # Collect sha256 sidecar files regardless of pattern
  if [[ "$name" == *.sha256 ]]; then
    SHA256_ASSETS+=("$name $url")
  fi
done

[ "${#MATCHING[@]}" -eq 0 ] && die "No assets match pattern '${PATTERN}' in release"

log "Matched ${#MATCHING[@]} asset(s): $(printf '%s ' "${MATCHING[@]}" | awk '{print $1}')"

# ── Detect split parts ────────────────────────────────────────────────────────
# GNU split uses alphabetic suffixes: .part-aa, .part-ab, …
# Find the base name (the name without .part-XX suffix)

BASE_NAME=""
PART_NAMES=()

for entry in "${MATCHING[@]}"; do
  name="${entry%% *}"
  if [[ "$name" =~ \.part-[a-z]{2}$ ]]; then
    candidate="${name%.part-??}"
    if [ -z "$BASE_NAME" ]; then
      BASE_NAME="$candidate"
    elif [ "$BASE_NAME" != "$candidate" ]; then
      die "Conflicting base names in split parts: ${BASE_NAME} vs ${candidate}"
    fi
    PART_NAMES+=("$name")
  fi
done

IS_SPLIT=false
[ "${#PART_NAMES[@]}" -gt 0 ] && IS_SPLIT=true

# If not split, the base name is the single matched asset
if ! $IS_SPLIT; then
  BASE_NAME="${MATCHING[0]%% *}"
fi

# ── Idempotency check ──────────────────────────────────────────────────────────
DEST_FILE="${DEST_DIR}/${BASE_NAME}"
if [ -f "$DEST_FILE" ]; then
  # Try to find a sha256 asset for verification
  SHA256_EXPECTED=""
  for s in "${SHA256_ASSETS[@]}"; do
    sname="${s%% *}"
    surl="${s#* }"
    if [ "$sname" = "${BASE_NAME}.sha256" ]; then
      SHA256_EXPECTED=$(curl -fsSL "$surl" | awk '{print $1}')
      break
    fi
  done
  if [ -n "$SHA256_EXPECTED" ]; then
    if verify_sha256 "$DEST_FILE" "$SHA256_EXPECTED" 2>/dev/null; then
      log "$(basename "$DEST_FILE") already present and verified — skipping download"
      exit 0
    else
      log "Existing file failed checksum — re-downloading"
      rm -f "$DEST_FILE"
    fi
  else
    log "$(basename "$DEST_FILE") already present (no checksum to verify) — skipping"
    exit 0
  fi
fi

# ── Download ───────────────────────────────────────────────────────────────────
if $IS_SPLIT; then
  log "Downloading ${#PART_NAMES[@]} split parts..."

  # Sort parts alphabetically to guarantee correct order
  mapfile -t SORTED_PARTS < <(printf '%s\n' "${PART_NAMES[@]}" | sort)

  for part_name in "${SORTED_PARTS[@]}"; do
    part_url=""
    for entry in "${MATCHING[@]}"; do
      n="${entry%% *}"
      u="${entry#* }"
      [ "$n" = "$part_name" ] && { part_url="$u"; break; }
    done
    [ -z "$part_url" ] && die "URL not found for part: ${part_name}"

    part_dest="${CACHE_DIR}/${part_name}"
    log "Downloading part: ${part_name}"
    download_file "$part_url" "$part_dest"
  done

  log "Reassembling ${#SORTED_PARTS[@]} parts → ${BASE_NAME}"
  PART_FILES=()
  for p in "${SORTED_PARTS[@]}"; do
    PART_FILES+=("${CACHE_DIR}/${p}")
  done
  cat "${PART_FILES[@]}" > "${DEST_FILE}.tmp"
  mv "${DEST_FILE}.tmp" "$DEST_FILE"

  # Clean up parts
  for pf in "${PART_FILES[@]}"; do rm -f "$pf"; done
  log "Parts removed from cache"

else
  log "Downloading: ${BASE_NAME}"
  ASSET_URL="${MATCHING[0]#* }"
  download_file "$ASSET_URL" "${DEST_FILE}.tmp"
  mv "${DEST_FILE}.tmp" "$DEST_FILE"
fi

# ── Verify checksum ────────────────────────────────────────────────────────────
SHA256_EXPECTED=""
for s in "${SHA256_ASSETS[@]}"; do
  sname="${s%% *}"
  surl="${s#* }"
  if [ "$sname" = "${BASE_NAME}.sha256" ]; then
    log "Downloading checksum: ${sname}"
    SHA256_EXPECTED=$(curl -fsSL "$surl" | awk '{print $1}')
    break
  fi
done

if [ -n "$SHA256_EXPECTED" ]; then
  verify_sha256 "$DEST_FILE" "$SHA256_EXPECTED" || {
    rm -f "$DEST_FILE"
    die "Checksum mismatch — downloaded file removed"
  }
else
  warn "No .sha256 asset found for ${BASE_NAME} — skipping checksum verification"
fi

log "Done: ${DEST_FILE} ($(du -sh "$DEST_FILE" | cut -f1))"
