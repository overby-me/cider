#!/usr/bin/env bash
# Run every runtime check, in the one way that actually works.
#
# There are eight of these now and buck-test.sh runs none of them: it is almost entirely
# static, asking whether an artifact links and exports the right symbols. The checks here
# are the ones that RUN things, and they are what found an empty AppKit, a null
# ec_thread_get_stack, a missing 0x prefix and a python module installed under a name
# CPython cannot import.
#
# THEY CANNOT BE CHAINED NAIVELY, which is the knowledge this script exists to hold. Each
# check kills stale processes under its OWN scratch root at START and not at exit, so
# running three back to back leaves three darlingserver daemons alive at once and the
# earlier ones fail spuriously. Killing every stray daemon BETWEEN checks is what makes
# them agree with their own results run individually.
#
#   pgrep -x, never -f: an -f pattern matches the command line of the shell running it,
#   which is how a cleanup loop ends up killing its own invocation.
#
# Exit codes from the checks: 0 is a pass, 3 is a KNOWN partial state that the check's own
# header explains, anything else is a failure. Only the last kind fails this script.
#
# Usage:
#   scripts/buck-runtime-check.sh              # the eight fast checks
#   scripts/buck-runtime-check.sh --with-nix   # plus buck-nix-bash-check, which is slow
#   scripts/buck-runtime-check.sh <name>...    # just these, by bare name
set -uo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

# Ordered cheapest-first, so a broken container is reported in a minute rather than after
# the GUI and interpreter cones have been built.
CHECKS=(
	buck-bash-check
	buck-launchd-check
	buck-smoke-check
	buck-security-check
	buck-jsc-check
	buck-appkit-check
	buck-scripting-check
)
# Builds bash with Nix INSIDE Darling. It is the campaign's keystone milestone and it takes
# far longer than everything else here put together, so it is opt-in.
SLOW=(buck-nix-bash-check)

case "${1:-}" in
--with-nix) CHECKS+=("${SLOW[@]}") ;;
"") ;;
*) CHECKS=("$@") ;;
esac

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

kill_daemons() {
	for pid in $(pgrep -x darlingserver 2>/dev/null); do
		kill -9 "$pid" 2>/dev/null || true
	done
	# The daemon takes a moment to release the prefix it had mounted, and a check that
	# materializes over a tree still held by one gets "Text file busy" on the loader.
	sleep 2
}

declare -a names=() codes=()
fail=0
for c in "${CHECKS[@]}"; do
	s="scripts/$c.sh"
	[ -x "$s" ] || {
		say "no such check: $s"
		exit 2
	}
	say ""
	say "######## $c ########"
	kill_daemons
	bash "$s"
	rc=$?
	names+=("$c")
	codes+=("$rc")
	case "$rc" in
	0 | 3) ;;
	*) fail=1 ;;
	esac
done
kill_daemons

say ""
say "######## summary ########"
for i in "${!names[@]}"; do
	case "${codes[$i]}" in
	0) verdict="PASS" ;;
	3) verdict="KNOWN (see the check's header)" ;;
	*) verdict="FAIL" ;;
	esac
	printf '  %-24s rc=%-3s %s\n' "${names[$i]}" "${codes[$i]}" "$verdict" >&2
done

[ "$fail" = 0 ] && {
	say ""
	say "PASS: every runtime check is at 0 or a known 3"
	exit 0
}
say ""
say "FAIL: at least one runtime check failed"
exit 1
