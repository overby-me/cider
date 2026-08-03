#!/usr/bin/env bash
# cc-under-darling.sh — compile a C source with the x86_64-darwin bootstrap
# clang *inside* rootless Darling, link it against the apple-sdk libSystem, and
# run the result. Demonstrates the Phase C keystone: the nixpkgs Darwin
# toolchain (clang + ld + libSystem) works under Darling, so `hello` can be
# built from source there.
#
# It stages the host source through Darling's host-root mount
# (/Volumes/SystemRoot) and compiles into the container's writable $HOME
# (/tmp is read-only inside; clang also needs a writable TMPDIR there). Runs a
# single fresh container (rootless cannot re-join one; see plan/blockers.md).
#
# Prereqs (substitute once on the host):
#   nix copy --from https://cache.nixos.org \
#     /nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools --no-check-sigs
#   nix copy --from https://cache.nixos.org \
#     "$(nix eval --raw github:NixOS/nixpkgs/<rev>#legacyPackages.x86_64-darwin.apple-sdk.outPath)" \
#     --no-check-sigs
#
# Usage:
#   scripts/cc-under-darling.sh <host-source.c> [clang args...]
#
# STAYS BASH (task #40). This forwards ARBITRARY argv to another program, and a nushell
# script cannot receive that: nu parses a script's arguments against main's signature, so the
# first argument starting with a dash becomes an unknown flag and the script exits 1 before
# running. `--` does not help, in either `script.nu -- -la` or `nu script.nu -- -la` form; both
# are parsed as a flag with an empty name. Measured, not assumed.
set -euo pipefail

DARLING="${DARLING:-darling}"
PREFIX="${DPREFIX:-/tmp/dc}"
RETRIES="${RETRIES:-1}"  # boot is reliable under the Rust daemon (#44); set RETRIES>1 to re-enable the old busy-spin retry
BT="${BOOTSTRAP_TOOLS:-/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools}"
SDK_ROOT="${APPLE_SDK:-/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4}"
SDK="$SDK_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk"

[ $# -ge 1 ] || { echo "usage: $0 <host-source.c> [clang args...]" >&2; exit 2; }
src="$1"; shift
[ -f "$src" ] || { echo "no such source: $src" >&2; exit 2; }
srcAbs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"

# Map host paths into Darling's host-root mount.
g() { printf '/Volumes/SystemRoot%s' "$1"; }
gBT="$(g "$BT")"; gSDK="$(g "$SDK")"; gSRC="$(g "$srcAbs")"

marker="=CC_UNDER_DARLING_$$="
# Compile into writable $HOME with a writable TMPDIR, then run the product.
inner="cd \"\$HOME\" || exit 9; mkdir -p .cc-tmp; export TMPDIR=\"\$HOME/.cc-tmp\";
echo $marker;
$gBT/bin/clang -isysroot $gSDK $* -o .cc-out $gSRC && ./.cc-out; echo cc_rc=\$?"

for i in $(seq 1 "$RETRIES"); do
	pkill -9 -x darlingserver 2>/dev/null || true
	pkill -9 -x mldr 2>/dev/null || true
	sleep 1
	out=$(DPREFIX="$PREFIX" timeout 150 "$DARLING" shell sh -c "$inner" 2>&1) || true
	if printf '%s\n' "$out" | grep -q "$marker"; then
		printf '%s\n' "$out" | sed "0,/$marker/d" \
			| grep -avE 'Cannot chown|failed to increase FD rlimit|semaphore_timedwait failed|dserver_rpc|mach_msg_overwrite'
		pkill -9 -x darlingserver 2>/dev/null || true
		exit 0
	fi
done
echo "failed to get a working Darling shell after $RETRIES tries" >&2
pkill -9 -x darlingserver 2>/dev/null || true
exit 1
