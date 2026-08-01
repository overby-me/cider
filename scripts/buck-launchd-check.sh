#!/usr/bin/env bash
# Boot the buck2-built Darling through LAUNCHD and run a command inside it.
#
# The sibling check (buck-bash-check.sh) sets DARLING_NO_LAUNCHD=1, which runs the command
# directly and skips init entirely. This one takes the real path: launchd comes up as guest
# pid 1, `launchctl bootstrap -S System` loads the system jobs, those jobs start, and only
# then does the requested command run via shellspawn. It exercises the whole Mach IPC core --
# portsets, blocking mach_msg receives across processes, OOL descriptor copyout, and the S2C
# calls that back them -- which the no-launchd path never touches.
#
# It stayed broken for a long time (task #47) and the failure was silent: the container just
# never finished. So it gets its own check, because "bash runs" does not imply "init works".
#
# Usage:  scripts/buck-launchd-check.sh [--prefix <dir>] [<scratch dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

art=""
if [ "${1:-}" = "--prefix" ]; then
	art=$2
	shift 2
	[ -d "$art" ] || {
		say "not a directory: $art"
		exit 2
	}
fi

# Short by default: <prefix>/.darlingserver.sock has to fit in a 108-byte sun_path.
root=${1:-/tmp/darling-buck2-$(id -u)}
rt="$root/rt"
prefix="$root/prefix-launchd"

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

# Anything still running from a previous run holds the old prefix mounted.
for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== materializing into $rt =="
chmod -R u+w "$rt" 2>/dev/null || true
rm -rf "$rt" "$prefix" "$prefix.workdir"
# Only $rt. The prefix directory must NOT be pre-created: darling treats an existing DPREFIX
# as one it has already set up, so creating it empty skips first-time setup entirely and
# launchd then boots into an unpopulated filesystem and stalls (deterministically, at ~509
# lines of daemon log). The no-launchd check gets away with it because running one command
# directly needs almost none of what that setup lays down.
mkdir -p "$rt"
# `cp -a`, never `cp -aL`: see buck-bash-check.sh.
cp -a "$art"/. "$rt"/
chmod -R u+w "$rt"

say "== booting the container through launchd =="
# No DARLING_NO_LAUNCHD here -- that is the entire point of this check.
out=$(
	DPREFIX="$prefix" \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 180 "$rt/bin/darling" shell /bin/bash -c 'echo BUCK2_LAUNCHD_OK $BASH_VERSION $MACHTYPE' 2>&1
) || true

printf '%s\n' "$out"
# The home-directory template copy ("cp: /Users/root: No such file or directory") is expected
# noise: /Users/root is not part of the prefix. It does not stop the boot, so it is not
# asserted on either way.
case "$out" in
*BUCK2_LAUNCHD_OK*darwin*)
	say "PASS: the buck2-built Darling boots through launchd and runs a command"
	exit 0
	;;
*BUCK2_LAUNCHD_OK*)
	say "PARTIAL: the command ran but did not report a Darwin build"
	exit 1
	;;
*)
	say "FAIL: the container did not finish with launchd as init"
	exit 1
	;;
esac
