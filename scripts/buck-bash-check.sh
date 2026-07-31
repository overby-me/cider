#!/usr/bin/env bash
# Boot the buck2-built Darling and run bash inside it.
#
# This is the milestone the whole port aims at: not "the targets build" but "the thing runs".
# Everything it uses comes from buck2 -- the 5,500-entry prefix, the Rust daemon, the
# launcher and the guest Mach-O loader -- so a pass means the port produced a working Darling
# and not just a pile of correct-looking artifacts.
#
# The prefix is COPIED into a scratch root first, rather than mounted out of buck-out
# directly: the container writes nothing to it, but a build tree is not a thing to hand a
# daemon as a root filesystem.
#
# Usage:  scripts/buck-bash-check.sh [<scratch dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

# An already-built prefix to test instead of building one. This is how the same check
# covers BOTH endpoints: with no argument it builds through the buck2 daemon, and with one
# it takes a tree the Nix endpoint produced
# (nix build .#darling-buck2-prefix, then result/darling_prefix__prefix).
art=""
if [ "${1:-}" = "--prefix" ]; then
	art=$2
	shift 2
	[ -d "$art" ] || {
		say "not a directory: $art"
		exit 2
	}
fi

# SHORT by default, and that is not cosmetic: the daemon's control socket lives at
# <prefix>/.darlingserver.sock and a Unix socket path is capped at 108 bytes, so a scratch
# directory a few levels deep makes the daemon panic with "socket path too long" after it
# has already brought all of duct-tape up.
root=${1:-/tmp/darling-buck2-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

if [ -z "$art" ]; then
	command -v buck2 >/dev/null || {
		say "missing buck2 -- run inside \`nix develop\`"
		exit 2
	}
	say "== building the prefix =="
	art=$(buck2 build //buck/prefix:darling_prefix --show-output 2>/dev/null | tail -1 | awk '{print $2}')
	[ -d "$art" ] || {
		say "the prefix did not build"
		exit 1
	}
fi

# Anything still running from a previous run holds the old prefix mounted, and removing the
# tree underneath a live daemon leaves it wedged -- so this comes FIRST.
for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== materializing into $rt =="
# Only ever removes what this script created.
chmod -R u+w "$rt" 2>/dev/null || true
rm -rf "$rt" "$prefix" "$prefix.workdir"
mkdir -p "$rt" "$prefix"
# `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /, so
# dereferencing indiscriminately walks the whole machine (it copied 82 GB once). -a is
# correct here because prefix_tree already resolved every installed artifact into a real
# file; the only symlinks left are the 72 the layout itself declares, and those have to
# survive as links.
cp -a "$art"/. "$rt"/
chmod -R u+w "$rt"

say "== booting the container and running bash =="
# DARLING_NO_LAUNCHD: run the command directly instead of bringing launchd up, which is the
# lighter of the two paths and the one that answers "does bash run".
out=$(
	DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 180 "$rt/bin/darling" shell /bin/bash -c 'echo BUCK2_BASH_OK $BASH_VERSION $MACHTYPE' 2>&1
) || true

printf '%s\n' "$out"
# What is asserted is BASH ITSELF, not a coreutil: uname lives in the cli component, which
# this milestone deliberately does not build (task #3 -- bash links libSystem and nothing
# else), and the Nix-built reference cannot run it here either.
case "$out" in
*BUCK2_BASH_OK*darwin*)
	say "PASS: the buck2-built Darling boots and runs bash"
	exit 0
	;;
*BUCK2_BASH_OK*)
	say "PARTIAL: bash ran but did not report a Darwin build"
	exit 1
	;;
*)
	say "FAIL: bash did not run inside the container"
	exit 1
	;;
esac
