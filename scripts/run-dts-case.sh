#!/usr/bin/env bash
# Run ONE darling-testsuite case in a fresh container, against the freshly built runtime.
#
#   buck2 build //vendor/src:<case-target> --show-output      # note the path it prints
#   scripts/run-dts-case.sh <that path>
#
# THE VERDICT IS THE OUTPUT, NOT THE EXIT CODE. `cider shell` does NOT propagate a case that dies
# on a signal: a fired assertion aborts the guest process and cider still exits 0. Measured, after
# I briefly reported a pass on that basis. So this reads the output for the failure markers and
# prints PASS or FAIL itself, and exits 1 on FAIL.
#
# The cases print NOTHING on success, so always check a known-failing one before believing a pass.
# `dts_System_Library_PrivateFrameworks_PubSub_framework_test_test_PubSub_variable` is the negative
# control: PubSub.framework genuinely does not exist here, so it reports "image not found".
#
# The binary lives in buck-out on the host, which the container sees under /Volumes/SystemRoot.
# The env block mirrors scripts/app-drive.sh so the case runs against the tree you just built
# rather than an installed runtime.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

[ $# -ge 1 ] || { echo "usage: $0 <host path to a built dts case>" >&2; exit 2; }
hostbin="$1"
[ -x "$hostbin" ] || { echo "not executable: $hostbin" >&2; exit 2; }

CIDER=${CIDER:-$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/launcher/__cider__/cider 2>/dev/null | head -1)}
CIDERD=${CIDERD:-$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/server/__ciderd__/ciderd 2>/dev/null | head -1)}
MLDR=${MLDR:-$(ls -t "$REPO"/buck-out/v2/art/root/*/src/darwin/loader/__mldr__/mldr 2>/dev/null | head -1)}
RT=${RT:-$(ls -td "$REPO"/buck-out/v2/art/root/*/buck/prefix/__cider_prefix__/cider_prefix__prefix 2>/dev/null | head -1)}
ELF_LIBS=$(grep '^elf_lib_dirs' "$REPO/.buckconfig.local" 2>/dev/null | sed 's/^elf_lib_dirs *= *//')
for t in CIDER CIDERD MLDR RT; do
	[ -n "${!t}" ] || { echo "$t not found; build //buck/prefix:cider_prefix first" >&2; exit 2; }
done

# cider creates the prefix itself but not its parent, and it refuses a prefix that already exists.
PREFIX=${PREFIX:-/tmp/cider-dts-1000/prefix}
mkdir -p "$(dirname "$PREFIX")"

# A stale container makes the next run fail with "Cannot open mnt namespace"; one ERE pattern,
# because multi-pattern pkill is a usage error that kills nothing.
pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null
sleep 1

out=$(mktemp)
trap 'rm -f "$out"' EXIT

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
	CIDERPREFIX="$PREFIX" CIDER_NO_LAUNCHD="${LAUNCHD:-1}" \
	LD_LIBRARY_PATH="$ELF_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_INSERT_LIBRARIES=/usr/lib/swift/libswiftCompat.dylib \
	CIDER_COMPAT_LIBRARY=/usr/lib/swift/libswiftCompat.dylib \
	${TRACE_ENV:-} \
	DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
	DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
	timeout "${LIMIT:-120}" "$CIDER" shell "/Volumes/SystemRoot$(realpath "$hostbin")" 2>&1 \
	| tee /dev/stderr | grep -v '^dyld: shared cache' > "$out"
rc=${PIPESTATUS[0]}

pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null

# Anything the harness prints is a failure; silence is the pass.
if grep -qE 'Assertion failed|has failed|Unable to get|image not found' "$out"; then
	echo "FAIL (cider exit $rc)"
	exit 1
fi
if [ "$rc" -ne 0 ]; then
	echo "FAIL: cider exit $rc with no diagnostic"
	exit 1
fi
echo "PASS"

