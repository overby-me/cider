#!/usr/bin/env bash
# Build GNU bash from source inside a Darling container using the 26.05
# bootstrap-tools clang + apple-sdk-14.4, then run it. Mirrors
# build-hello-under-darling.sh; bash is a much larger configure/make and
# exercises far more of libSystem (signals, job control, termios, locale).
set -euo pipefail
DARLING="${DARLING:-darling}"
PREFIX="${DPREFIX:-$HOME/.dbash}"
RETRIES="${RETRIES:-3}"
NIXPKGS_REV="${NIXPKGS_REV:-fd1462031fdee08f65fd0b4c6b64e22239a77870}"
CACHE="https://cache.nixos.org"
BT="${BOOTSTRAP_TOOLS:-/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools}"
SDK_ROOT="${APPLE_SDK:-/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4}"
BASH_SRC="${BASH_SRC:-}"
if [ -z "$BASH_SRC" ]; then
	BASH_SRC="$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_REV}#legacyPackages.x86_64-darwin.bash.src")"
fi
for p in "$BT" "$SDK_ROOT" "$BASH_SRC"; do
	[ -e "$p" ] || nix copy --from "$CACHE" "$p" --no-check-sigs
done
SDK="$SDK_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk"
g() { printf '/Volumes/SystemRoot%s' "$1"; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat > "$work/build.sh" <<INNER
#!/bin/sh
BT=$(g "$BT")
SDK=$(g "$SDK")
BSRC=$(g "$BASH_SRC")
export PATH="\$BT/bin:/usr/bin:/bin"
export SDKROOT="\$SDK" CC=clang
# -fcommon: bash's bundled termcap and readline both give tentative defs of the
# termcap globals (PC, BC, UP, ospeed); modern clang defaults to -fno-common,
# which makes them hard duplicate symbols at link. -fcommon merges them.
export CFLAGS="-isysroot \$SDK -Wno-implicit-function-declaration -Wno-error -fcommon"
export LDFLAGS="-isysroot \$SDK"
export CONFIG_SHELL="\$BT/bin/bash" SHELL="\$BT/bin/bash"
unset CONFIG_SITE
cd "\$HOME" || exit 9
rm -rf bbuild; mkdir -p bbuild tmp; export TMPDIR="\$HOME/tmp"
cd bbuild || exit 9
echo "=UNTAR="; tar xzf "\$BSRC" && echo untar_ok || { echo TAR_FAIL; exit 1; }
cd bash-5.3 || { echo NO_SRCDIR; exit 1; }
# darling's linker makes __private_extern__ termcap globals (BC/UP/PC/ospeed) fully LOCAL, so
# readline's references to them are undefined at the final link (works with Apple's ld). Make
# them global so bash links. (Proper fix belongs in darling-ld64's private_extern handling.)
sed -i "s/__private_extern__//g" lib/termcap/tparam.c lib/termcap/termcap.c
echo "=CONFIGURE="; "\$CONFIG_SHELL" ./configure --without-bash-malloc >conf.log 2>&1; echo "configure_rc=\$?"; tail -3 conf.log
echo "=MAKE="; make >make.log 2>&1; echo "make_rc=\$?"; tail -4 make.log
echo "=VER="; ./bash --version 2>&1 | head -1; echo "ver_rc=\$?"
echo "=RUN="; ./bash -c 'echo BASH_RUNS_OK; x=2; echo sum=\$((x+3)); for i in a b c; do printf "%s" "\$i"; done; echo'; echo "run_rc=\$?"
INNER
gBUILD="$(g "$work/build.sh")"
for i in $(seq 1 "$RETRIES"); do
	pkill -9 -x darlingserver 2>/dev/null || true
	pkill -9 -x mldr 2>/dev/null || true
	sleep 1
	out=$(DPREFIX="$PREFIX" timeout 2400 "$DARLING" shell sh "$gBUILD" 2>&1) || true
	if printf '%s\n' "$out" | grep -q "=UNTAR="; then
		printf '%s\n' "$out" | grep -avE 'Cannot chown|failed to increase FD rlimit|semaphore_timedwait failed|dserver_rpc|mach_msg_overwrite'
		pkill -9 -x darlingserver 2>/dev/null || true
		printf '%s\n' "$out" | grep -q 'run_rc=0' && exit 0 || exit 1
	fi
done
echo "failed to get a working Darling shell after $RETRIES tries" >&2
pkill -9 -x darlingserver 2>/dev/null || true
exit 1
