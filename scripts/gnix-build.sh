#!/bin/sh
# gnix-build.sh -- generic guest-side driver: build any pre-seeded derivation
# FROM SOURCE with guest Nix under Darling, then optionally run its binary.
# Runs INSIDE one `darling shell sh <this>` session (rootless one-shot). The
# host-side counterpart scripts/build-pkg-bypass.sh sets up the prefix, seeds
# the store DB, and passes:
#   GDRV  the derivation to build (a /nix/store/....drv, canonical path in-guest)
#   GDB   host path to the closure DB dump (reached via /Volumes/SystemRoot)
#   GBIN  (optional) basename of a binary in the output's bin/ to run --version
# See scripts/gnix-hello.sh for the hello-specific M1 driver and
# plan/guest-nix-m1.md for the launchd-bypass background.
: "${GDRV:?set GDRV to the derivation to build}"
: "${GDB:?set GDB to the host closure-dump path}"

NIX="${NIXBIN:-/nix/store/fw9y98mcqkksxyah45mmbsrvaxxv7r6x-nix-2.34.8/bin}"
[ -x "$NIX/nix" ] || { echo "NO_NIX_BIN ($NIX)"; ls -d /nix/store/*nix-2.34* 2>/dev/null; exit 1; }
export PATH="$NIX:/usr/bin:/bin"
export HOME=/Users/root
export NIX_REMOTE=local
# Fresh guest-owned state dir (the inherited /nix/var db is owned by the unmapped
# host root -> unwritable, and its daemon socket makes nix pick daemon mode).
export NIX_STATE_DIR=/Users/root/nixstate
export NIX_LOG_DIR=/Users/root/nixlog
export TMPDIR=/Users/root/nixtmp
mkdir -p "$NIX_STATE_DIR" "$NIX_LOG_DIR" "$TMPDIR" 2>/dev/null
export NIX_CONFIG="experimental-features = nix-command flakes
sandbox = false
build-users-group =
require-sigs = false
substituters = "

nix-store --init 2>&1 | tail -1
# Seed the valid-paths DB so the substituted build inputs (present via the
# writable-/nix overlay lower) are trusted and GDRV itself is buildable.
if nix-store --load-db < "/Volumes/SystemRoot$GDB" 2>&1 | tail -1; then :; fi

echo "=NIXVER="; nix --version 2>&1 | head -1 || { echo NIX_RUN_FAIL; exit 1; }
echo "=BUILD $GDRV="
nix build --offline --no-link "${GDRV}^out" 2>&1
echo "build_rc=$?"

if [ -n "${GBIN:-}" ]; then
	echo "=RUN="
	out=$(nix-store -q --outputs "$GDRV" 2>/dev/null | head -1)
	if [ -x "$out/bin/$GBIN" ]; then
		"$out/bin/$GBIN" --version 2>&1 | head -1; echo "run_rc=$?"
	else
		echo "no_bin $GBIN (out=$out)"
	fi
fi
echo "=PKG_DONE $GDRV="
