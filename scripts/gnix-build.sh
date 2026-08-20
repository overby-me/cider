#!/bin/sh
# gnix-build.sh -- generic guest-side driver: build any pre-seeded derivation
# FROM SOURCE with guest Nix under Darling, then optionally run its binary.
# Runs INSIDE one `cider shell sh <this>` session (rootless one-shot). The
# host-side counterpart scripts/build/build-pkg-bypass.nu sets up the prefix, seeds
# the store DB, and passes:
#   GDRV  the derivation to build (a /nix/store/....drv, canonical path in-guest)
#   GDB   host path to the closure DB dump (reached via /Volumes/SystemRoot)
#   GBIN  (optional) basename of a binary in the output's bin/ to run --version
# See scripts/gnix-hello.sh for the hello-specific M1 driver and
# docs/changelog.md for the launchd-bypass background.
#
# STAYS BASH. This runs inside the GUEST, under a cider shell session, where the
# shell is Darwin bash 3.2.57 and there is no nushell in the prefix. The bash-to-
# nushell conversion (task #40) covers HOST tooling only; converting this would break
# the guest, and putting a nushell in the prefix is a different project.
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

echo "=NIXVER="; nix --version 2>&1; echo "=NIXVER_RC=$?="
echo "=INIT="; nix-store --init 2>&1; echo "=INIT_RC=$?="
# Seed the valid-paths DB so the substituted build inputs (present via the
# writable-/nix overlay lower) are trusted and GDRV itself is buildable.
echo "=LOADDB="; nix-store --load-db < "/Volumes/SystemRoot$GDB" 2>&1; echo "=LOADDB_RC=$?="
echo "=BUILD $GDRV="
# ^* builds all outputs, so multi-output packages (bin/lib/dev/...) work too.
# Retry: guest test/build binaries occasionally crash with a transient signal
# (e.g. SIGFPE in an autoconf mbrtowc/locale probe) -- a cider execution-
# fidelity flake, not a real build error (see docs/changelog.md, task #44).
# nix builds are atomic, so a fresh attempt re-runs configure and usually passes.
brc=1
for attempt in 1 2 3 4; do
	# Cores default to 1 (serial). Parallel `make -j` hung under cider on aarch64: make's
	# jobserver waits in poll() (Darwin poll -> Linux ppoll on arm64) and uses the poll timeout
	# as the heartbeat on which it reaps finished jobs. The arm64 ppoll ms->timespec conversion
	# was broken (poll.c: tv_sec = (timeout%1000)*1000000), so a sub-second timeout became a
	# ~15-year wait; finished children piled up as unreaped zombies and the build never
	# progressed (seen after the builtins/support subdirs). Serial fork+wait4 (as configure uses)
	# never hits that path, so it always worked. The timeout bug is fixed in
	# vendor/patches/xnu/0038; set CIDER_GNIX_CORES>1 to build in parallel once a prefix rebuilt
	# with 0038 has confirmed it, then this default can drop. 1 stays the safe default until then.
	nix build -L --cores "${CIDER_GNIX_CORES:-1}" --offline --no-link "${GDRV}^*" 2>&1
	brc=$?
	[ "$brc" -eq 0 ] && break
	echo "build attempt $attempt failed (rc=$brc); retrying (transient-crash mitigation)..."
done
echo "build_rc=$brc"

if [ -n "${GBIN:-}" ]; then
	echo "=RUN="
	found=""
	for out in $(nix-store -q --outputs "$GDRV" 2>/dev/null); do
		if [ -x "$out/bin/$GBIN" ]; then found="$out/bin/$GBIN"; break; fi
	done
	if [ -n "$found" ]; then
		"$found" --version 2>&1 | head -1; echo "run_rc=$?"
	else
		echo "no_bin $GBIN (outputs: $(nix-store -q --outputs "$GDRV" 2>/dev/null | tr '\n' ' '))"
	fi
fi
echo "=PKG_DONE $GDRV="
