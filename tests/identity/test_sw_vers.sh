#!/bin/sh
# test_sw_vers.sh — Verify sw_vers and the Nix-visible system identity report
# the macOS 14 (Sonoma) class version. Run inside `darling shell`.
#
# Expected after Phase A.2 (baseline 11.7.4 makes this FAIL by design):
#   sw_vers -productVersion  -> 14.4.1
#   sw_vers -buildVersion    -> 23E224
#
# Exit 0 = pass, nonzero = fail.

EXPECT_PRODUCT="14.4.1"
EXPECT_BUILD="23E224"
EXPECT_PRODUCT_MAJOR="14"

run=0
pass=0
check() { # desc, actual, expected
    run=$((run + 1))
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS [%d]: %s (%s)\n' "$run" "$1" "$2"
    else
        printf '  FAIL [%d]: %s (got "%s", want "%s")\n' "$run" "$1" "$2" "$3"
    fi
}

echo "== sw_vers identity =="

PV=$(sw_vers -productVersion 2>/dev/null)
BV=$(sw_vers -buildVersion 2>/dev/null)
PN=$(sw_vers -productName 2>/dev/null)

echo "  sw_vers: $PN $PV ($BV)"

# Major version must be 14 (strict); full version and build are the A.2 target.
check "productVersion major is 14" "$(echo "$PV" | cut -d. -f1)" "$EXPECT_PRODUCT_MAJOR"
check "productVersion" "$PV" "$EXPECT_PRODUCT"
check "buildVersion" "$BV" "$EXPECT_BUILD"

printf 'Tests: %d/%d passed\n' "$pass" "$run"
[ "$pass" -eq "$run" ]
