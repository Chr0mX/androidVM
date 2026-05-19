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

# ── Atom feed fallback — no API auth required, no rate limit ──────────────────
# Used automatically when the GitHub REST API is unavailable or rate-limited.
# Parses the public releases Atom feed to discover the latest tag, then
# downloads assets directly (whole file or split parts) without any API call.
fetch_via_atom() {
  local prefix="$1" file_glob="$2" dest_dir="$3"
  local file_base="${file_glob//\*/}"   # blissos14-gapps-arm.qcow2* → blissos14-gapps-arm.qcow2

  log "GitHub API unavailable — using Atom feed fallback (no token needed)"

  local tag
  tag=$(curl -fsSL "https://github.com/${OWNER_REPO}/releases.atom" 2>/dev/null \
    | grep -o "releases/tag/${prefix}[^\"<]*" | head -1 | sed 's|releases/tag/||') || true

  if [ -z "$tag" ]; then
    warn "Atom feed: no release found for prefix '${prefix}'"
    return 1
  fi
  log "Atom feed: latest tag = ${tag}"

  local base_url="https://github.com/${OWNER_REPO}/releases/download/${tag}"
  local dest_file="${dest_dir}/${file_base}"

  # Idempotency
  if [ -f "$dest_file" ]; then
    log "${file_base} already present — skipping"
    return 0
  fi

  # Try whole file first; fall through to split parts on failure
  if curl -fsSL -L --retry 3 --retry-delay 10 --progress-bar \
      "${base_url}/${file_base}" -o "${dest_file}.tmp" 2>/dev/null; then
    mv "${dest_file}.tmp" "$dest_file"
  else
    rm -f "${dest_file}.tmp"
    log "Whole-file download failed — trying split parts"

    local parts=() part part_dest
    local -a alpha=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
    for a in "${alpha[@]}"; do
      for b in "${alpha[@]}"; do
        part="${file_base}.part-${a}${b}"
        part_dest="${CACHE_DIR}/${part}"
        if curl -fsSL -L --retry 3 --retry-delay 10 --progress-bar \
            "${base_url}/${part}" -o "${part_dest}.tmp" 2>/dev/null; then
          mv "${part_dest}.tmp" "$part_dest"
          parts+=("$part")
          log "Downloaded part: ${part}"
        else
          rm -f "${part_dest}.tmp"
          break 2
        fi
      done
    done

    if [ ${#parts[@]} -eq 0 ]; then
      warn "No files or split parts found at ${base_url}/"
      return 1
    fi

    log "Reassembling ${#parts[@]} parts → ${file_base}"
    local part_files=()
    for p in "${parts[@]}"; do part_files+=("${CACHE_DIR}/${p}"); done
    cat "${part_files[@]}" > "${dest_file}.tmp"
    mv "${dest_file}.tmp" "$dest_file"
    rm -f "${part_files[@]}"
    log "Parts removed from cache"
  fi

  # Verify checksum if sidecar exists
  local sha_expected
  if sha_expected=$(curl -fsSL "${base_url}/${file_base}.sha256" 2>/dev/null | awk '{print $1}') \
      && [ -n "$sha_expected" ]; then
    verify_sha256 "$dest_file" "$sha_expected" || {
      rm -f "$dest_file"
      die "Checksum mismatch — downloaded file removed"
    }
  else
    warn "No .sha256 available for ${file_base} — skipping verification"
  fi

  log "Done: ${dest_file} ($(du -sh "$dest_file" | cut -f1))"
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
  if [ -n "$TAG_PREFIX" ]; then
    # REST API failed (rate limit or network) — Atom feed has no such limits
    fetch_via_atom "$TAG_PREFIX" "$PATTERN" "$DEST_DIR" && exit 0
    die "Both GitHub API and Atom feed fallback failed for prefix '${TAG_PREFIX}'"
  fi
  # No tag prefix: try the classic direct-URL fallback
  warn "GitHub API unavailable — trying direct download URL"
  BASE_NAME="${PATTERN//\*/}"
  FALLBACK_URL="https://github.com/${OWNER_REPO}/releases/latest/download/${BASE_NAME}"
  log "Trying: ${FALLBACK_URL}"
  download_file "$FALLBACK_URL" "${DEST_DIR}/${BASE_NAME}"
  exit 0
fi

# When --tag-prefix is set the API returned an array; pick the first matching release
if [ -n "$TAG_PREFIX" ]; then
  RESP_TYPE=$(echo "$RELEASE_JSON" | jq -r 'type' 2>/dev/null || echo "invalid")
  if [ "$RESP_TYPE" != "array" ]; then
    API_MSG=$(echo "$RELEASE_JSON" | jq -r '.message // empty' 2>/dev/null || true)
    [ -n "$API_MSG" ] && warn "GitHub API message: ${API_MSG}"
    warn "API returned '${RESP_TYPE}' instead of an array — trying Atom feed fallback"
    fetch_via_atom "$TAG_PREFIX" "$PATTERN" "$DEST_DIR" && exit 0
    die "Cannot fetch release for prefix '${TAG_PREFIX}' from ${OWNER_REPO}"
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
