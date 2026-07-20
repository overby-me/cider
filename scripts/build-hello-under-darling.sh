#!/usr/bin/env bash
# build-hello-under-darling.sh — build GNU hello 2.12.3 from source *inside*
# rootless Darling with the x86_64-darwin bootstrap toolchain, and run it.
# This is campaign milestone M1: `pkgs.hello` builds from source and runs under
# Darling (the "builds" half; M0 is the "runs" half). It needs the dup2->EBADF
# fix (patches/xnu/0006) to get GNU hello's ./configure past its dup2 check.
#
# It runs the whole ./configure && make && ./hello in ONE `darling shell`
# session (rootless cannot re-join a container; see plan/blockers.md), staging
# the bootstrap-tools, the apple-sdk and the hello tarball through Darling's
# host-root mount (/Volumes/SystemRoot), building in the writable container
# $HOME with a writable TMPDIR, and forcing CONFIG_SHELL to the bootstrap bash
# (the host shell path leaks in and does not exist inside the container).
#
# Env overrides: DARLING (darling binary), DPREFIX (short prefix path),
# BOOTSTRAP_TOOLS, APPLE_SDK, HELLO_SRC (store paths), NIXPKGS_REV.
set -euo pipefail

DARLING="${DARLING:-darling}"
PREFIX="${DPREFIX:-/tmp/dhb}"
RETRIES="${RETRIES:-3}"
NIXPKGS_REV="${NIXPKGS_REV:-fd1462031fdee08f65fd0b4c6b64e22239a77870}"
CACHE="https://cache.nixos.org"

BT="${BOOTSTRAP_TOOLS:-/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools}"
SDK_ROOT="${APPLE_SDK:-/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4}"
HELLO_SRC="${HELLO_SRC:-}"
if [ -z "$HELLO_SRC" ]; then
	HELLO_SRC="$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_REV}#legacyPackages.x86_64-darwin.hello.src")"
fi

# Substitute prerequisites from the binary cache if missing (host-side).
for p in "$BT" "$SDK_ROOT" "$HELLO_SRC"; do
	[ -e "$p" ] || nix copy --from "$CACHE" "$p" --no-check-sigs
done

SDK="$SDK_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk"
g() { printf '/Volumes/SystemRoot%s' "$1"; }

# The build script that runs inside the container.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat > "$work/build.sh" <<INNER
#!/bin/sh
BT=$(g "$BT")
SDK=$(g "$SDK")
HSRC=$(g "$HELLO_SRC")
export PATH="\$BT/bin:/usr/bin:/bin"
export SDKROOT="\$SDK" CC=clang
export CFLAGS="-isysroot \$SDK -Wno-implicit-function-declaration"
export LDFLAGS="-isysroot \$SDK"
export CONFIG_SHELL="\$BT/bin/bash" SHELL="\$BT/bin/bash"
unset CONFIG_SITE
cd "\$HOME" || exit 9
rm -rf hbuild; mkdir -p hbuild tmp; export TMPDIR="\$HOME/tmp"
cd hbuild || exit 9
echo "=UNTAR="; tar xzf "\$HSRC" && echo untar_ok || { echo TAR_FAIL; exit 1; }
cd hello-2.12.3 || { echo NO_SRCDIR; exit 1; }
echo "=CONFIGURE="; "\$CONFIG_SHELL" ./configure >conf.log 2>&1; echo "configure_rc=\$?"; tail -3 conf.log
echo "=MAKE="; make >make.log 2>&1; echo "make_rc=\$?"; tail -4 make.log
echo "=RUN="; ./hello; echo "hello_rc=\$?"
INNER

gBUILD="$(g "$work/build.sh")"
for i in $(seq 1 "$RETRIES"); do
	pkill -9 -x darlingserver 2>/dev/null || true
	pkill -9 -x mldr 2>/dev/null || true
	sleep 1
	out=$(DPREFIX="$PREFIX" timeout 1500 "$DARLING" shell sh "$gBUILD" 2>&1) || true
	if printf '%s\n' "$out" | grep -q "=UNTAR="; then
		printf '%s\n' "$out" | grep -avE 'Cannot chown|failed to increase FD rlimit|semaphore_timedwait failed|dserver_rpc|mach_msg_overwrite'
		pkill -9 -x darlingserver 2>/dev/null || true
		printf '%s\n' "$out" | grep -q 'hello_rc=0' && exit 0 || exit 1
	fi
done
echo "failed to get a working Darling shell after $RETRIES tries" >&2
pkill -9 -x darlingserver 2>/dev/null || true
exit 1
