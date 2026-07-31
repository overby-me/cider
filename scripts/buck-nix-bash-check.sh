#!/usr/bin/env bash
# Guest Nix, running inside the BUCK2-BUILT Darling, builds GNU bash from source and runs it.
#
# This is the goal the port was aiming at, and it is a strictly bigger claim than
# scripts/buck-bash-check.sh: that one boots the container and runs the bash the port itself
# built, while this one runs a Darwin toolchain under the port well enough to COMPILE a
# package and execute the result.
#
# Everything below the container is buck2's: the daemon, the launcher, the guest loader and
# the whole prefix. Nix itself is not: it is the x86_64-darwin nix already in the host store,
# reached through the writable-/nix overlay, exactly as scripts/gnix-hello.sh describes. The
# port's job is to run it, not to build it.
#
# Usage:  scripts/buck-nix-bash-check.sh [<attr> [<binary>]]
# Default attr is bash. Any nixpkgs x86_64-darwin attr works, since the driver underneath
# (scripts/build-pkg-bypass.sh) is generic.
set -uo pipefail
cd "$(dirname "$0")/.."

ATTR="${1:-bash}"
BIN="${2:-bash}"
# SHORT, because the daemon's control socket lives in the prefix and a Unix socket path is
# capped at 108 bytes.
RT="${BUCK2_RT:-/tmp/darling-buck2-$(id -u)/rt}"
PREFIX="${DPREFIX:-/tmp/darling-nixpkg-$(id -u)}"

say() { printf '%s\n' "$*" >&2; }

if [ ! -x "$RT/bin/darling" ]; then
	say "no materialized prefix at $RT"
	say "run scripts/buck-bash-check.sh first -- it builds //buck/prefix:darling_prefix and"
	say "copies it there, which is what this check then drives."
	exit 2
fi

# The two paths the daemon reads from the environment. The cmake build bakes them in; a
# relocatable prefix cannot, so they are passed here (same as scripts/buck-bash-check.sh).
export DSERVER_LIBEXEC_PATH="$RT/libexec/darling"
export DSERVER_MLDR_PATH="$RT/libexec/darling/usr/libexec/darling/mldr"

say "== guest nix builds $ATTR under the buck2-built Darling =="
out=$(./scripts/build-pkg-bypass.sh "$ATTR" "$BIN" --mono "$RT" --prefix "$PREFIX" 2>&1) || true
printf '%s\n' "$out"

# build_rc=0 alone is not enough: the driver retries, and a stale valid output in the store
# would let a build "succeed" without having run. The version line proves the binary the
# guest produced actually executed.
case "$out" in
*build_rc=0*run_rc=0*)
	say "PASS: guest nix built and ran $ATTR inside the buck2-built Darling"
	exit 0
	;;
*build_rc=0*)
	say "PARTIAL: $ATTR built but did not run"
	exit 1
	;;
*)
	say "FAIL: guest nix did not build $ATTR"
	exit 1
	;;
esac
