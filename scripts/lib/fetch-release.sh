#!/usr/bin/env bash
# Download release assets from GitHub.
#
# Usage: fetch-release.sh <owner/repo> <asset-pattern> <dest-dir> [--tag-prefix <prefix>]
#
# With --tag-prefix:
#   Finds the latest release whose tag starts with <prefix> via the public
#   Atom feed (no auth, no rate limit), then downloads assets directly.
#   Split archives (.part-aa, .part-ab, …) are reassembled automatically.
#
# Without --tag-prefix:
#   Uses the GitHub REST API /releases/latest endpoint.
#   Set GITHUB_TOKEN to increase the 60 req/hr unauthenticated limit.
#
# Env vars:
#   GITHUB_TOKEN   Optional — raises REST API rate limit to 5000 req/hr
#   ROOT           Repo root; cache lands in $ROOT/cache (auto-detected)
set -euo pipefail
IFS=$'\n\t'

OWNER_REPO="${1:?Usage: fetch-release.sh <owner/repo> <asset-pattern> <dest-dir>}"
PATTERN="${2:?}"
DEST_DIR="${3:?}"
TAG_PREFIX=""
ALSO_FILES=()

shift 3 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag-prefix) TAG_PREFIX="${2:?--tag-prefix requires a value}"; shift 2 ;;
    --also)       ALSO_FILES+=("${2:?--also requires a value}");   shift 2 ;;
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

# ── Helpers ────────────────────────────────────────────────────────────────────

download_file() {
  local url="$1" dest="$2"
  curl -L -C - \
    --retry 5 --retry-delay 10 --retry-max-time 600 \
    --progress-bar \
    "$url" -o "$dest"
}

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

# Quick existence check — downloads only 1 byte via a range request.
# Returns 0 if the URL is reachable (HTTP 200 or 206), 1 otherwise.
url_exists() {
  local url="$1"
  local code
  code=$(curl -sSL -o /dev/null -w "%{http_code}" \
    --range 0-0 --max-time 20 "$url" 2>/dev/null) || code="000"
  code="${code: -3}"
  case "$code" in 200|206) return 0 ;; *) return 1 ;; esac
}

# ── REST API tag-prefix lookup ─────────────────────────────────────────────────
#
# Uses the GitHub REST API /releases?per_page=100 (paginated) to find the
# newest release whose tag starts with <prefix>.  Falls back gracefully when
# unauthenticated rate limits are hit; set GITHUB_TOKEN to raise the limit.

api_latest_tag() {
  local prefix="$1"
  local auth_args=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth_args=(-H "Authorization: token ${GITHUB_TOKEN}")

  local tag="" page=1
  while true; do
    local result
    result=$(curl -fsSL --max-time 30 \
      "${auth_args[@]}" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${OWNER_REPO}/releases?per_page=100&page=${page}" \
      2>/dev/null) || break

    tag=$(printf '%s' "$result" | jq -r --arg p "$prefix" \
      '[.[] | select(.tag_name | startswith($p))] | .[0].tag_name // empty' \
      2>/dev/null || true)
    [ -n "$tag" ] && { printf '%s' "$tag"; return 0; }

    local count
    count=$(printf '%s' "$result" | jq 'length' 2>/dev/null || echo 0)
    [ "${count:-0}" -lt 100 ] && break
    page=$(( page + 1 ))
  done

  return 1
}

fetch_via_api() {
  local prefix="$1" file_glob="$2" dest_dir="$3"
  local file_base="${file_glob//\*/}"   # blissos14-base.qcow2* → blissos14-base.qcow2

  log "Looking up latest '${prefix}' release via GitHub API..."
  local tag
  if ! tag=$(api_latest_tag "$prefix") || [ -z "$tag" ]; then
    die "No release found for prefix '${prefix}' in ${OWNER_REPO}.
  Make sure a '${prefix}YYYYMMDD-HHMM' release has been published:
  https://github.com/${OWNER_REPO}/releases"
  fi
  log "Found release: ${tag}"

  local base_url="https://github.com/${OWNER_REPO}/releases/download/${tag}"
  local dest_file="${dest_dir}/${file_base}"

  # Idempotency — verify against checksum if available
  if [ -f "$dest_file" ]; then
    local sha_expected
    if sha_expected=$(curl -fsSL --max-time 15 \
        "${base_url}/${file_base}.sha256" 2>/dev/null | awk '{print $1}') \
        && [ -n "$sha_expected" ]; then
      if verify_sha256 "$dest_file" "$sha_expected" 2>/dev/null; then
        log "${file_base} already present and verified — skipping"
        return 0
      else
        log "Existing file failed checksum — re-downloading"
        rm -f "$dest_file"
      fi
    else
      log "${file_base} already present — skipping"
      return 0
    fi
  fi

  # Try whole file first; if 404, try split parts
  if url_exists "${base_url}/${file_base}"; then
    log "Downloading: ${file_base}"
    download_file "${base_url}/${file_base}" "${dest_file}.tmp"
    mv "${dest_file}.tmp" "$dest_file"

  else
    log "Whole file not available — downloading split parts"
    local parts=() part part_cache
    local -a alpha=(a b c d e f g h i j k l m n o p q r s t u v w x y z)

    for a in "${alpha[@]}"; do
      for b in "${alpha[@]}"; do
        part="${file_base}.part-${a}${b}"
        part_cache="${CACHE_DIR}/${part}"

        if url_exists "${base_url}/${part}"; then
          log "Downloading part: ${part}"
          download_file "${base_url}/${part}" "${part_cache}.tmp"
          mv "${part_cache}.tmp" "$part_cache"
          parts+=("$part")
        else
          break 2
        fi
      done
    done

    if [ ${#parts[@]} -eq 0 ]; then
      die "No files found for ${file_base} in release ${tag}.
  Check: https://github.com/${OWNER_REPO}/releases/tag/${tag}"
    fi

    log "Reassembling ${#parts[@]} parts → ${file_base}"
    local part_files=()
    for p in "${parts[@]}"; do part_files+=("${CACHE_DIR}/${p}"); done
    cat "${part_files[@]}" > "${dest_file}.tmp"
    mv "${dest_file}.tmp" "$dest_file"
    rm -f "${part_files[@]}"
    log "Temporary parts removed from cache"
  fi

  # Verify checksum
  local sha_expected
  if sha_expected=$(curl -fsSL --max-time 15 \
      "${base_url}/${file_base}.sha256" 2>/dev/null | awk '{print $1}') \
      && [ -n "$sha_expected" ]; then
    verify_sha256 "$dest_file" "$sha_expected" || {
      rm -f "$dest_file"
      die "Checksum mismatch — downloaded file removed"
    }
  else
    warn "No .sha256 sidecar for ${file_base} — skipping verification"
  fi

  log "Done: ${dest_file} ($(du -sh "$dest_file" | cut -f1))"

  # Download companion files (--also) from the same release tag without a
  # second API lookup.
  for extra_file in "${ALSO_FILES[@]+"${ALSO_FILES[@]}"}"; do
    local extra_dest="${dest_dir}/${extra_file}"
    if [ -f "$extra_dest" ]; then
      log "${extra_file} already present — skipping"
      continue
    fi
    if url_exists "${base_url}/${extra_file}"; then
      log "Downloading: ${extra_file}"
      download_file "${base_url}/${extra_file}" "${extra_dest}.tmp"
      mv "${extra_dest}.tmp" "$extra_dest"
      log "Done: ${extra_file} ($(du -sh "$extra_dest" | cut -f1))"
    else
      warn "${extra_file} not found in release ${tag} — skipping"
    fi
  done
}

# ── Main ───────────────────────────────────────────────────────────────────────

# --tag-prefix mode: REST API filtered by prefix
if [ -n "$TAG_PREFIX" ]; then
  fetch_via_api "$TAG_PREFIX" "$PATTERN" "$DEST_DIR"
  exit 0
fi

# No --tag-prefix: use REST API for /releases/latest
log "Fetching latest release: ${OWNER_REPO}"
API_URL="https://api.github.com/repos/${OWNER_REPO}/releases/latest"

auth_header=()
[ -n "${GITHUB_TOKEN:-}" ] && auth_header=(-H "Authorization: token ${GITHUB_TOKEN}")

http_code=$(curl -sSL -w "%{http_code}" "${auth_header[@]}" \
  -H "Accept: application/vnd.github.v3+json" \
  "$API_URL" -o /tmp/fetch-release-api.json 2>/dev/null; echo)
http_code="${http_code: -3}"

if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
  msg=$(jq -r '.message // empty' /tmp/fetch-release-api.json 2>/dev/null || true)
  warn "GitHub API rate limited (HTTP ${http_code})${msg:+: ${msg}}"
  warn "Set GITHUB_TOKEN to raise the limit: export GITHUB_TOKEN=<token>"
  exit 1
fi
if [ "$http_code" != "200" ]; then
  warn "GitHub API returned HTTP ${http_code}"
  exit 1
fi

RELEASE_JSON=$(cat /tmp/fetch-release-api.json)
ASSET_COUNT=$(echo "$RELEASE_JSON" | jq '.assets | length')
[ "${ASSET_COUNT:-0}" -eq 0 ] && die "No assets in latest release of ${OWNER_REPO}"

mapfile -t ASSET_LINES < <(echo "$RELEASE_JSON" | \
  jq -r '.assets[] | "\(.name) \(.browser_download_url)"')

TAG_NAME=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
log "Release ${TAG_NAME} has ${#ASSET_LINES[@]} asset(s)"

# Filter matching assets
MATCHING=()
SHA256_ASSETS=()
for line in "${ASSET_LINES[@]}"; do
  name="${line%% *}"
  url="${line#* }"
  case "$name" in $PATTERN) MATCHING+=("$name $url") ;; esac
  [[ "$name" == *.sha256 ]] && SHA256_ASSETS+=("$name $url")
done
[ "${#MATCHING[@]}" -eq 0 ] && die "No assets match pattern '${PATTERN}' in release ${TAG_NAME}"
log "Matched ${#MATCHING[@]} asset(s)"

# Detect split parts
BASE_NAME=""
PART_NAMES=()
for entry in "${MATCHING[@]}"; do
  name="${entry%% *}"
  if [[ "$name" =~ \.part-[a-z]{2}$ ]]; then
    candidate="${name%.part-??}"
    [ -z "$BASE_NAME" ] && BASE_NAME="$candidate"
    [ "$BASE_NAME" != "$candidate" ] && die "Conflicting split base names: ${BASE_NAME} vs ${candidate}"
    PART_NAMES+=("$name")
  fi
done
IS_SPLIT=false
[ "${#PART_NAMES[@]}" -gt 0 ] && IS_SPLIT=true
$IS_SPLIT || BASE_NAME="${MATCHING[0]%% *}"

DEST_FILE="${DEST_DIR}/${BASE_NAME}"
if [ -f "$DEST_FILE" ]; then
  log "$(basename "$DEST_FILE") already present — skipping"
  exit 0
fi

if $IS_SPLIT; then
  mapfile -t SORTED_PARTS < <(printf '%s\n' "${PART_NAMES[@]}" | sort)
  log "Downloading ${#SORTED_PARTS[@]} split parts..."
  for part_name in "${SORTED_PARTS[@]}"; do
    part_url=""
    for entry in "${MATCHING[@]}"; do
      [ "${entry%% *}" = "$part_name" ] && { part_url="${entry#* }"; break; }
    done
    [ -z "$part_url" ] && die "URL not found for part: ${part_name}"
    log "Downloading part: ${part_name}"
    download_file "$part_url" "${CACHE_DIR}/${part_name}"
  done
  log "Reassembling → ${BASE_NAME}"
  PART_FILES=()
  for p in "${SORTED_PARTS[@]}"; do PART_FILES+=("${CACHE_DIR}/${p}"); done
  cat "${PART_FILES[@]}" > "${DEST_FILE}.tmp"
  mv "${DEST_FILE}.tmp" "$DEST_FILE"
  rm -f "${PART_FILES[@]}"
else
  log "Downloading: ${BASE_NAME}"
  download_file "${MATCHING[0]#* }" "${DEST_FILE}.tmp"
  mv "${DEST_FILE}.tmp" "$DEST_FILE"
fi

# Verify checksum
SHA256_EXPECTED=""
for s in "${SHA256_ASSETS[@]}"; do
  [ "${s%% *}" = "${BASE_NAME}.sha256" ] && {
    SHA256_EXPECTED=$(curl -fsSL "${s#* }" | awk '{print $1}')
    break
  }
done

if [ -n "$SHA256_EXPECTED" ]; then
  verify_sha256 "$DEST_FILE" "$SHA256_EXPECTED" || {
    rm -f "$DEST_FILE"
    die "Checksum mismatch — downloaded file removed"
  }
else
  warn "No .sha256 asset found — skipping verification"
fi

log "Done: ${DEST_FILE} ($(du -sh "$DEST_FILE" | cut -f1))"
