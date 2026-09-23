#!/usr/bin/env bash
# Build and run ONE buck2 darwin_binary probe inside a guest, and print what it said.
#
#   scripts/run-probe.sh //tests/foundation:probe_bookmark_identity
#   scripts/run-probe.sh --no-build //tests/foundation:probe_sort_and_filter
#
# The probes under tests/foundation answer "does this core class ANSWER CORRECTLY", which is the
# highest yield question in this port, and until now every one of them was launched by hand from a
# copy of run-dts-batch.sh's environment block. That block is not optional: an empty
# WAYLAND_DISPLAY flips the backend, and the compat library has to be inserted or a Swift symbol
# aborts the load.
#
# A PROBE IS NOT A SUITE CASE. It prints and exits 0 whatever it found, so the caller reads the
# MISMATCH lines rather than the exit code.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

BUILD=1
[ "${1:-}" = "--no-build" ] && { BUILD=0; shift; }
TARGET=${1:-}
[ -n "$TARGET" ] || { echo "usage: $0 [--no-build] //tests/foundation:probe_name" >&2; exit 2; }

NAME=${TARGET##*:}
PKG=${TARGET%:*}; PKG=${PKG#//}
OUT=${OUT:-/tmp/cider-probe}
mkdir -p "$OUT"

if [ "$BUILD" = 1 ]; then
	buck2 build "$TARGET" > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
fi

BIN=$(ls -t "$REPO"/buck-out/v2/art/root/*/"$PKG"/__"${NAME}"__/"$NAME" 2>/dev/null | head -1)
[ -x "$BIN" ] || { echo "not built: $TARGET" >&2; exit 2; }

CIDER=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/launcher/__cider__/cider 2>/dev/null | head -1)
CIDERD=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/server/__ciderd__/ciderd 2>/dev/null | head -1)
MLDR=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/darwin/loader/__mldr__/mldr 2>/dev/null | head -1)
RT=$(ls -td "$REPO"/buck-out/v2/art/root/*/buck/prefix/__cider_prefix__/cider_prefix__prefix 2>/dev/null | head -1)
ELF_LIBS=$(grep '^elf_lib_dirs' "$REPO/.buckconfig.local" 2>/dev/null | sed 's/^elf_lib_dirs *= *//')

# Discover the socket rather than trust the caller: an empty WAYLAND_DISPLAY silently selects the
# X11 backend, which has no server here and dies in its failing-init path.
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
	WAYLAND_DISPLAY=$(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-[0-9]* 2>/dev/null \
		| grep -v '\.lock$' | grep -vE 'renderD' | sort | head -1 | xargs -r basename)
	[ -n "$WAYLAND_DISPLAY" ] && export WAYLAND_DISPLAY
fi

{
	echo '#!/bin/sh'
	echo 'mkdir -p /tmp/probe'
	echo 'cd /tmp/probe'
	echo 'D=$(pwd -P); cd "$D"'
	echo "cp \"/Volumes/SystemRoot$(realpath "$BIN")\" \"\$D/$NAME\" && chmod +x \"\$D/$NAME\""
	echo "\"\$D/$NAME\"; echo \"PROBE EXIT \$?\""
} > "$OUT/probe.sh"
chmod +x "$OUT/probe.sh"

pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null
sleep 1
mkdir -p /tmp/cider-probe-1000
chmod -R u+w /tmp/cider-probe-1000/prefix 2>/dev/null
rm -rf /tmp/cider-probe-1000/prefix

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
	CIDERPREFIX=/tmp/cider-probe-1000/prefix CIDER_NO_LAUNCHD=1 \
	LD_LIBRARY_PATH="$ELF_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_INSERT_LIBRARIES=/usr/lib/swift/libswiftCompat.dylib \
	CIDER_COMPAT_LIBRARY=/usr/lib/swift/libswiftCompat.dylib \
	DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
	DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
	timeout "${LIMIT:-300}" "$CIDER" shell /bin/sh "/Volumes/SystemRoot$OUT/probe.sh" \
	> "$OUT/run.log" 2>&1
pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null

cat "$OUT/run.log"
echo "---"
echo "probe log: $OUT/run.log"
grep -c MISMATCH "$OUT/run.log" | sed 's/^/mismatches: /'
