#!/usr/bin/env bash
# Run libdispatch inside the buck2-built Darling.
#
# usr/lib/system/libdispatch.dylib ships in the prefix and nothing had ever executed a line
# of it. It deserves its own check rather than being taken on trust, because it is the one
# system library whose whole job is making threads and handing work between them, and that is
# the machinery this port has had the most trouble with: the guest runs on the daemon's
# microthreads, multithreading needed duct-tape's two-phase init before it worked at all, and
# a null pthread_list_mlock once surfaced as a silent SIGSEGV that read like a scheduler bug.
#
# tests/buck2/guest/dispatch_probe.c walks from the step that needs no thread to the one that
# needs several, so a failure names the layer:
#
#   dispatch_once     the atomic and the block, no queue
#   dispatch_sync     a queue, still on the calling thread
#   dispatch_async    a real handoff, joined with a semaphore
#   dispatch_apply    concurrent iterations on the global queue
#
# Usage:  scripts/buck-dispatch-check.sh [<scratch dir>]
set -uo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

root=${1:-/tmp/darling-dispatch-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

say "== building the prefix and the probe =="
out=$(buck2 build //buck/prefix:darling_prefix //tests/buck2/guest:dispatch_probe \
	--show-output 2>/dev/null)
art=$(awk '/darling_prefix/ {print $2}' <<<"$out")
bin=$(awk '/dispatch_probe/ {print $2}' <<<"$out")
for f in "$art" "$bin"; do
	[ -e "$f" ] || {
		say "missing build output: $f"
		exit 1
	}
done

# Anything still running under this root holds the old prefix mounted.
for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== materializing into $rt =="
chmod -R u+w "$rt" 2>/dev/null || true
rm -rf "$rt" "$prefix" "$prefix.workdir"
mkdir -p "$rt" "$prefix"
# `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
cp -a "$art"/. "$rt"/
chmod -R u+w "$rt"
cp "$bin" "$rt/libexec/darling/usr/bin/dispatch_probe"
chmod +x "$rt/libexec/darling/usr/bin/dispatch_probe"

say "== running the probe inside the container =="
out=$(
	DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 200 "$rt/bin/darling" shell /usr/bin/dispatch_probe 2>&1
) || true

printf '%s\n' "$out" | grep "DISPATCH_PROBE" || true

fail=0
expect() {
	case "$out" in
	*"$1"*) say "ok   $2" ;;
	*) say "FAIL $2"; fail=1 ;;
	esac
}
# Asserted step by step, so a regression says which layer stopped working rather than that
# dispatch broke.
expect "DISPATCH_PROBE once ran=1" "dispatch_once runs the block exactly once"
expect "DISPATCH_PROBE queue=created" "dispatch_queue_create returns a queue"
expect "DISPATCH_PROBE sync val=42" "dispatch_sync runs the block on the calling thread"
expect "DISPATCH_PROBE async wait=0 ran=1" "dispatch_async hands off to a real thread"
expect "DISPATCH_PROBE apply count=64" "dispatch_apply runs 64 concurrent iterations"
expect "DISPATCH_PROBE_DONE failures=0" "the probe ran to completion"

[ "$fail" = 0 ] && {
	say "PASS: libdispatch schedules work in the guest"
	exit 0
}
say "FAIL: see above"
exit 1
