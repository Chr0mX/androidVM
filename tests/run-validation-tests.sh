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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All ${PASS} validation test(s) passed."
  exit 0
else
  echo "${FAIL} validation test(s) failed."
  exit 1
fi
