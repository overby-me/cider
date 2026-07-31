#!/usr/bin/env bash
# Boot the buck2-built Darling and run bash inside it.
#
# This is the milestone the whole port aims at: not "the targets build" but "the thing runs".
# Everything it uses comes from buck2 -- the 5,500-entry prefix, the Rust daemon, the
# launcher and the guest Mach-O loader -- so a pass means the port produced a working Darling
# and not just a pile of correct-looking artifacts.
#
# The prefix is DEREFERENCED into a scratch root first. buck2's prefix is a symlink farm
# pointing back into buck-out through relative paths; the daemon overlay-mounts that
# directory as the container's read-only lower, and inside the container's mount namespace
# those paths lead nowhere.
#
# Usage:  scripts/buck-bash-check.sh [<scratch dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

# SHORT by default, and that is not cosmetic: the daemon's control socket lives at
# <prefix>/.darlingserver.sock and a Unix socket path is capped at 108 bytes, so a scratch
# directory a few levels deep makes the daemon panic with "socket path too long" after it
# has already brought all of duct-tape up.
root=${1:-/tmp/darling-buck2-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

say "== building the prefix =="
art=$(buck2 build //buck/prefix:darling_prefix --show-output 2>/dev/null | tail -1 | awk '{print $2}')
[ -d "$art" ] || {
	say "the prefix did not build"
	exit 1
}

say "== materializing into $rt =="
# Only ever removes what this script created.
rm -rf "$rt" "$prefix" "$prefix.workdir"
mkdir -p "$rt" "$prefix"
# Not `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /, and dereferencing
# indiscriminately walks the whole machine. The materializer follows only the links that
# point into buck-out (the installed artifacts) and keeps the layout's own links verbatim.
./scripts/buck-prefix-materialize.py "$art" "$rt"
chmod -R u+w "$rt"

# Anything still running from a previous run holds the old prefix mounted.
for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== booting the container and running bash =="
# DARLING_NO_LAUNCHD: run the command directly instead of bringing launchd up, which is the
# lighter of the two paths and the one that answers "does bash run".
out=$(
	DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 180 "$rt/bin/darling" shell /bin/bash -c 'echo BUCK2_BASH_OK; uname -s' 2>&1
) || true

printf '%s\n' "$out"
case "$out" in
*BUCK2_BASH_OK*Darwin*)
	say "PASS: the buck2-built Darling boots and runs bash"
	exit 0
	;;
*BUCK2_BASH_OK*)
	say "PARTIAL: bash ran but uname did not report Darwin"
	exit 1
	;;
*)
	say "FAIL: bash did not run inside the container"
	exit 1
	;;
esac
