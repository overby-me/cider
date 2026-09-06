#!/usr/bin/env bash
# Run ONE darling-testsuite case in a fresh container, against the freshly built runtime.
#
#   buck2 build //vendor/src:<case-target> --show-output      # note the path it prints
#   scripts/run-dts-case.sh <that path>
#
# EXIT CODE IS THE RESULT: 0 passed, 134 an assertion fired, 1 the case could not even load its
# framework. The cases print nothing on success, so ALWAYS check a known-failing one before
# believing a zero. `dts_System_Library_PrivateFrameworks_PubSub_framework_test_test_PubSub_variable`
# is a good negative control: PubSub.framework genuinely does not exist here, so it exits 1 with
# "image not found".
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

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
	CIDERPREFIX="$PREFIX" CIDER_NO_LAUNCHD="${LAUNCHD:-1}" \
	LD_LIBRARY_PATH="$ELF_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_INSERT_LIBRARIES=/usr/lib/swift/libswiftCompat.dylib \
	CIDER_COMPAT_LIBRARY=/usr/lib/swift/libswiftCompat.dylib \
	${TRACE_ENV:-} \
	DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
	DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
	timeout "${LIMIT:-120}" "$CIDER" shell "/Volumes/SystemRoot$(realpath "$hostbin")"
rc=$?

pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null
echo "TEST EXIT=$rc"
exit "$rc"
