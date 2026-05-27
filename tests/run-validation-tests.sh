#!/usr/bin/env bash
# Validation consistency tests.
#
# Runs scripts/lib/profile-validator.py against the fixtures in tests/fixtures/
# and asserts each one passes or fails as expected. Exits non-zero if any
# fixture behaves differently than expected — wired into CI (build-base.yml).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="${ROOT}/scripts/lib/profile-validator.py"
FIXTURES="${SCRIPT_DIR}/fixtures"

PASS=0
FAIL=0

# run_case <fixture-file> <expected: pass|fail>
run_case() {
  local fixture="$1" expect="$2"
  local rc=0
  python3 "$VALIDATOR" "${FIXTURES}/${fixture}" >/dev/null 2>&1 || rc=$?

  local got="pass"
  [ "$rc" -ne 0 ] && got="fail"

  if [ "$got" = "$expect" ]; then
    printf '  [ ok ] %-28s expected %-4s got %s\n' "$fixture" "$expect" "$got"
    PASS=$(( PASS + 1 ))
  else
    printf '  [FAIL] %-28s expected %-4s got %s\n' "$fixture" "$expect" "$got"
    FAIL=$(( FAIL + 1 ))
  fi
}

echo "Running profile validation consistency tests..."
run_case "valid.json"                "pass"
run_case "prohibited-key.json"       "fail"
run_case "fingerprint-mismatch.json" "fail"

echo ""
echo "Running bash -n syntax checks..."
for script in \
  "${ROOT}/android-vm" \
  "${ROOT}/install.sh" \
  "${ROOT}/scripts/boot.sh" \
  "${ROOT}/scripts/set-profile.sh" \
  "${ROOT}/scripts/gen-libvirt-xml.sh" \
  "${ROOT}/scripts/verify.sh" \
  "${ROOT}/scripts/lib/fetch-distro.sh" \
  "${ROOT}/scripts/lib/fetch-release.sh" \
  "${ROOT}/scripts/lib/fetch-arm-trans.sh" \
  "${ROOT}/scripts/lib/inject-gapps.sh" \
  "${ROOT}/scripts/lib/inject-arm-trans.sh" \
  "${ROOT}/scripts/lib/detect-hardware.sh" \
; do
  [ -f "$script" ] || continue
  name="$(basename "$script")"
  if bash -n "$script" 2>/dev/null; then
    printf '  [ ok ] bash -n %s\n' "$name"
    PASS=$(( PASS + 1 ))
  else
    printf '  [FAIL] bash -n %s\n' "$name"
    bash -n "$script" 2>&1 | sed 's/^/         /'
    FAIL=$(( FAIL + 1 ))
  fi
done

echo ""
echo "Running JSON config validation..."
for f in \
  "${ROOT}/config/defaults.json" \
  "${ROOT}/androiddistro"/*.json \
  "${ROOT}/profiles"/*.json \
  "${ROOT}/config/vm-profiles"/*.json \
; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if jq empty "$f" 2>/dev/null; then
    printf '  [ ok ] jq %s\n' "$name"
    PASS=$(( PASS + 1 ))
  else
    printf '  [FAIL] jq %s\n' "$name"
    jq empty "$f" 2>&1 | sed 's/^/         /'
    FAIL=$(( FAIL + 1 ))
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All ${PASS} validation test(s) passed."
  exit 0
else
  echo "${FAIL} validation test(s) failed."
  exit 1
fi
