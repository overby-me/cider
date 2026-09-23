#!/usr/bin/env bash
# DOES EACH PATCH SERIES STILL DESCRIBE THE TREE IT CLAIMS TO?
#
# buck-bundled-patch-record-check.nu replays a series FORWARD from vendor/pins and compares. That
# is the stronger check and it is the right one, but only cocotron has a pin here: corefoundation,
# foundation, objc4 and security are materialised from a nix source path that is not on this
# machine, so there is nothing to replay from and their records, 174 patches between them, were
# checked by nothing at all.
#
# REVERSING NEEDS NO BASE. A patch that reverse-applies to the materialised tree is a patch whose
# hunks are still present in it, so a series that reverses whole describes the tree's delta exactly.
# Newest first, because a later patch may edit lines an earlier one added.
#
# A FAILURE IS NOT ALWAYS ROT. Two patches that touch the same lines cannot both reverse: once the
# newer one is undone the older one's context is the ORIGINAL text, not what it produced. Those are
# legitimate and they are listed in the baseline beside this script. Only a patch that is not in
# the baseline is a finding.
#
# Exit 0 when every component matches its baseline, 1 otherwise.
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
BASELINE=${BASELINE:-scripts/checks/patch-series-reverse-baseline.txt}
STATUS=0
ACTUAL=$(mktemp)

for COMP in cocotron corefoundation foundation objc4 security; do
	SRC="vendor/src/$COMP"
	PAT="vendor/patches/$COMP"
	[ -d "$SRC" ] && [ -d "$PAT" ] || continue

	W=$(mktemp -d)
	cp -a "$SRC" "$W/tree"
	chmod -R u+w "$W/tree"
	ok=0; bad=0
	# ABSOLUTE PATHS: the loop below cds into the copy, so a relative patch path stops resolving and
	# every patch reads as a failure. That is what this check looked like when it was first run.
	for p in $(ls "$PAT"/*.patch | sort -r | while read -r f; do realpath "$f"; done); do
		if (cd "$W/tree" && patch -p1 -R -s --forward --dry-run < "$p" >/dev/null 2>&1); then
			(cd "$W/tree" && patch -p1 -R -s --forward < "$p" >/dev/null 2>&1)
			ok=$((ok + 1))
		else
			bad=$((bad + 1))
			echo "$COMP $(basename "$p")" >> "$ACTUAL"
		fi
	done
	rm -rf "$W"
	echo "$COMP: $ok reverse cleanly, $bad do not"
done

sort -o "$ACTUAL" "$ACTUAL"
if [ ! -f "$BASELINE" ]; then
	echo "no baseline at $BASELINE; writing one from this run" >&2
	grep -v '^#' /dev/null > "$BASELINE" 2>/dev/null || :
	cat "$ACTUAL" >> "$BASELINE"
fi

EXPECTED=$(mktemp)
grep -v '^#' "$BASELINE" | grep -v '^$' | sort > "$EXPECTED"

NEW=$(comm -13 "$EXPECTED" "$ACTUAL")
GONE=$(comm -23 "$EXPECTED" "$ACTUAL")

if [ -n "$NEW" ]; then
	echo "FAIL: patches that no longer reverse and are not in the baseline:"
	echo "$NEW" | sed 's/^/  /'
	STATUS=1
fi
if [ -n "$GONE" ]; then
	echo "NOTE: baseline entries that now reverse cleanly; remove them from $BASELINE:"
	echo "$GONE" | sed 's/^/  /'
fi
[ "$STATUS" = 0 ] && echo "PASS: every patch series matches its reverse baseline"

rm -f "$ACTUAL" "$EXPECTED"
exit "$STATUS"
