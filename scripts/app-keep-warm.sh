#!/usr/bin/env bash
# KEEP THE STAGED APPLICATIONS ALIVE, because /tmp is swept by AGE and the prefixes live there.
#
# WHY THIS EXISTS. systemd-tmpfiles deletes files under /tmp once they are old enough and leaves the
# directory tree standing. The applications are staged into /tmp/cider-<tag>-1000/prefix and are the
# one part of a prefix that cannot be rebuilt: the runtime comes from buck-out, the applications came
# from a download.
#
# It has now happened twice. On 2026-09-01 every bundle was hollowed out (#169). On 2026-09-19 it
# took ONE file, iTermServer, and that was worse: the bundle still looked present to every ordinary
# check, iTerm2 still started, and what it produced was a terminal with no shell plus a crash three
# frames deep in NSFileManager. It cost an A/B against an innocent commit to find, and the file could
# not be restored because no iTerm2 source archive was left on the machine either.
#
# A MAIN EXECUTABLE SURVIVES AND ITS NEIGHBOURS DO NOT, which is what makes the damage so uneven:
# every run reads the main binary and that keeps it young, while an auxiliary binary that is only
# copied once ages out on schedule.
#
#   scripts/app-keep-warm.sh            touch everything, print a count per application
#   scripts/app-keep-warm.sh --check    compare against the recorded inventory, exit 1 on a loss
#   scripts/app-keep-warm.sh --write    re-record the inventory from what is on disk now
#
# The touch is cheap: 993 files over seven applications when this was written.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
inventory="$here/app-inventory.txt"
mode=touch
case "${1:-}" in
--check) mode=check ;;
--write) mode=write ;;
"") ;;
*)
	echo "usage: $0 [--check|--write]" >&2
	exit 2
	;;
esac

apps() {
	# One directory per staged application, whatever prefixes exist right now.
	find /tmp -maxdepth 4 -type d -path '/tmp/cider-*-1000/prefix/Applications' 2>/dev/null | sort
}

tag_of() {
	# /tmp/cider-XX-1000/prefix/Applications -> XX
	printf '%s\n' "$1" | sed -E 's|^/tmp/cider-([^-]+)-1000/.*$|\1|'
}

# The list is RELATIVE to the Applications directory, so it is comparable across machines.
list_one() {
	(cd "$1" && find . -type f 2>/dev/null | sort)
}

case "$mode" in
touch)
	total=0
	while read -r dir; do
		[ -n "$dir" ] || continue
		tag=$(tag_of "$dir")
		# -a and -m both, because a sweep may be configured on either.
		n=$(find "$dir" -type f -exec touch -a -m {} + -print 2>/dev/null | wc -l)
		total=$((total + n))
		echo "$tag warmed=$n"
	done < <(apps)
	echo "WARMED $total files across the staged applications"
	;;
write)
	: >"$inventory"
	{
		echo "# What each staged application is supposed to contain, relative to its Applications"
		echo "# directory. Recorded so that a file DELETED BY THE /tmp SWEEP is caught as a missing"
		echo "# file rather than as a mysterious application failure three frames deep."
		echo "#"
		echo "# NOT A CLEAN BASELINE FOR it: iTermServer had ALREADY been swept when this was first"
		echo "# written, and no source archive remained to restore it, so the iTerm2 list here is the"
		echo "# damaged tree. Re-record it after a real re-stage."
	} >>"$inventory"
	while read -r dir; do
		[ -n "$dir" ] || continue
		tag=$(tag_of "$dir")
		while read -r f; do
			echo "$tag|$f" >>"$inventory"
		done < <(list_one "$dir")
	done < <(apps)
	echo "recorded $(grep -vc '^#' "$inventory") files in $inventory"
	;;
check)
	if [ ! -f "$inventory" ]; then
		echo "no inventory at $inventory; run --write first" >&2
		exit 2
	fi
	missing=0
	while read -r dir; do
		[ -n "$dir" ] || continue
		tag=$(tag_of "$dir")
		have=$(mktemp)
		want=$(mktemp)
		list_one "$dir" >"$have"
		grep "^$tag|" "$inventory" | sed "s|^$tag||;s|^||" | cut -d'|' -f2- >"$want"
		# Only a LOSS is a failure. An extra file is an application writing state and is expected.
		gone=$(comm -13 "$have" "$want" | wc -l)
		if [ "$gone" -gt 0 ]; then
			echo "FAIL $tag is missing $gone file(s) from the recorded inventory:"
			comm -13 "$have" "$want" | head -10 | sed 's/^/    /'
			missing=$((missing + gone))
		else
			echo "ok $tag"
		fi
		rm -f "$have" "$want"
	done < <(apps)
	if [ "$missing" -gt 0 ]; then
		echo "FAILED: $missing staged file(s) have gone. /tmp is swept by AGE; see scripts/app-stage.sh."
		exit 1
	fi
	echo "PASS: every recorded staged file is still present"
	;;
esac
