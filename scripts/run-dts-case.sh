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
# THE CASES PRINT NOTHING ON SUCCESS, so this script PROVES IT CAN STILL SAY FAIL before it says
# PASS about anything: it runs //src/darwin/testsuite-control:testsuite_control_always_fails first
# and refuses to give a verdict unless that one fails.
#
# The control used to be the PubSub case, on the grounds that PubSub.framework did not exist here.
# It does now, so that case passes, and this script spent an unknown period with NO CONTROL while
# its own comment still claimed one. A control that depends on something being ABSENT can be
# retired by anyone who adds it. The replacement asserts 1 == 2 and cannot be made to pass. #232.
#
# THE BATCH IS STILL THE AUTHORITY for anything that matters: scripts/run-dts-batch.sh runs all of
# them and is what caught the NSArchiver regression this control exists because of.
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

# Overridable ONLY so the NO VERDICT path below can itself be tested by pointing this at a case
# that passes. Nothing in normal use should set it.
CONTROL_TARGET=${CONTROL_TARGET:-//src/darwin/testsuite-control:testsuite_control_always_fails}

# Run one guest binary. Leaves its output in $out and its cider exit code in $rc, and answers 0 for
# a pass (silence and a zero exit) or 1 for a failure, so the control and the case are judged by
# EXACTLY the same rule.
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
run_one() {
	# A stale container makes the next run fail with "Cannot open mnt namespace"; one ERE pattern,
	# because multi-pattern pkill is a usage error that kills nothing.
	pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null
	sleep 1

	env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
		CIDERPREFIX="$PREFIX" CIDER_NO_LAUNCHD="${LAUNCHD:-1}" \
		LD_LIBRARY_PATH="$ELF_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		DYLD_INSERT_LIBRARIES=/usr/lib/swift/libswiftCompat.dylib \
		CIDER_COMPAT_LIBRARY=/usr/lib/swift/libswiftCompat.dylib \
		${TRACE_ENV:-} \
		DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
		DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
		timeout "${LIMIT:-120}" "$CIDER" shell "/Volumes/SystemRoot$(realpath "$1")" 2>&1 \
		| tee "${2:-/dev/stderr}" | grep -v '^dyld: shared cache' > "$out"
	rc=${PIPESTATUS[0]}

	pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null

	# ANY output is a failure; silence is the pass. A pattern list was tried first and gave false
	# passes twice: an NSDictionary case that prints an expected-versus-actual dump never says
	# "Assertion failed", and it exits 134 in the batch while the pattern list called it a pass.
	[ -s "$out" ] && return 1
	[ "$rc" -ne 0 ] && return 1
	return 0
}

# THE CONTROL FIRST. Its output is swallowed, because a control that fails is the NORMAL case and
# printing its assertion every time would train the reader to ignore it.
if [ "${SKIP_CONTROL:-0}" != 1 ]; then
	control=$(buck2 build --show-simple-output "$CONTROL_TARGET" 2>/dev/null | tail -1)
	if [ -z "$control" ] || [ ! -x "$control" ]; then
		echo "NO VERDICT: could not build the negative control $CONTROL_TARGET" >&2
		exit 3
	fi
	if run_one "$control" /dev/null; then
		echo "NO VERDICT: the negative control PASSED, so this script cannot currently detect a" >&2
		echo "failure and any verdict it gives is worthless. Fix the control before trusting it." >&2
		echo "  control: $control" >&2
		exit 3
	fi
fi

if run_one "$hostbin"; then
	echo "PASS"
	exit 0
fi

if [ -s "$out" ]; then
	echo "FAIL (cider exit $rc), output:"
	head -20 "$out"
else
	echo "FAIL: cider exit $rc with no diagnostic"
fi
exit 1
