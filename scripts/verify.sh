#!/usr/bin/env bash
# ADB-based verification of a running VM against a profile.
#
# Usage: verify.sh <profile.json>
set -euo pipefail

PROFILE="${1:?Usage: verify.sh <profile.json>}"
[ -f "$PROFILE" ] || { echo "Profile not found: $PROFILE" >&2; exit 1; }

FAIL=0

adb wait-for-device

check() {
  local key="$1" expected="$2"
  actual=$(adb shell getprop "$key" 2>/dev/null | tr -d '\r')
  if [ "$actual" = "$expected" ]; then
    printf "  \033[0;32m✓\033[0m %s\n" "$key"
  else
    printf "  \033[0;31m✗\033[0m %s\n" "$key"
    printf "      expected: %s\n" "$expected"
    printf "      actual:   %s\n" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=== Identity checks ==="
check "ro.product.manufacturer" "$(jq -r '.system["ro.product.manufacturer"]' "$PROFILE")"
check "ro.product.model"        "$(jq -r '.system["ro.product.model"]'        "$PROFILE")"
check "ro.product.brand"        "$(jq -r '.system["ro.product.brand"] // empty' "$PROFILE")"
check "ro.build.fingerprint"    "$(jq -r '.system["ro.build.fingerprint"]'    "$PROFILE")"
check "ro.vendor.build.fingerprint" \
      "$(jq -r '.vendor["ro.vendor.build.fingerprint"]' "$PROFILE")"

echo ""
echo "=== ARM translation ==="
check "ro.dalvik.vm.native.bridge" "libndk_translation.so"
check "ro.enable.native.bridge.exec" "1"

# binfmt_misc entries for ARM ELF magic bytes
if adb shell ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -q arm; then
  printf "  \033[0;32m✓\033[0m binfmt_misc ARM entries present\n"
else
  printf "  \033[0;31m✗\033[0m binfmt_misc ARM entries missing\n"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Leak scan ==="
for token in "generic_x86" "emulator" "test-keys" "lineage" "waydroid"; do
  if adb shell getprop 2>/dev/null | grep -qi "$token"; then
    printf "  \033[0;31m✗\033[0m LEAK: '%s' found in getprop output\n" "$token"
    FAIL=$((FAIL + 1))
  else
    printf "  \033[0;32m✓\033[0m No leak: %s\n" "$token"
  fi
done

echo ""
echo "=== Fingerprint trio consistency ==="
FP_SYS=$(adb shell getprop ro.build.fingerprint        2>/dev/null | tr -d '\r')
FP_SYS2=$(adb shell getprop ro.system.build.fingerprint 2>/dev/null | tr -d '\r')
FP_VEN=$(adb shell getprop ro.vendor.build.fingerprint  2>/dev/null | tr -d '\r')

bid_sys=$(echo "$FP_SYS"  | cut -d/ -f5 | cut -d: -f1)
bid_ven=$(echo "$FP_VEN"  | cut -d/ -f5 | cut -d: -f1)

if [ "$bid_sys" = "$bid_ven" ] && [ "$FP_SYS" = "$FP_SYS2" ]; then
  printf "  \033[0;32m✓\033[0m Fingerprint trio consistent (%s)\n" "$bid_sys"
else
  printf "  \033[0;31m✗\033[0m Fingerprint mismatch: system=%s vendor=%s\n" \
    "$bid_sys" "$bid_ven"
  [ "$FP_SYS" != "$FP_SYS2" ] && \
    printf "      ro.build.fingerprint != ro.system.build.fingerprint\n"
  FAIL=$((FAIL + 1))
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  printf "\033[0;31mFAILED (%d check(s) failed)\033[0m\n" "$FAIL"
  exit 1
else
  printf "\033[0;32mPASSED\033[0m\n"
fi
