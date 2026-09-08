#!/usr/bin/env bash
# LOOP THE #209 SCENARIO AND NAME THE WINDOWS OF EVERY RUN.
#
# A single run proves nothing either way, so the only honest output is a RATE. Each run does what
# #209 recorded: launch LibreOffice, click Writer Document, then type with the Tip of the Day
# dialog still up, which is blind typing into whatever has focus.
#
#   scripts/repro-209.sh [runs]        default 10
#
# It prints RATE and, separately, SCENARIO: how many runs had a dialog on screen at all. Those are
# two different numbers and conflating them is what wasted 40 runs on 2026-09-08. A run with no
# dialog cannot fail this way, so its pass is not evidence about the defect.
#
# Per run it prints PASS or EXITED and the windows the run created, by TITLE. Naming the extra
# dialog is the whole point: every LibreOffice window is a SalFrameWindow, so the class cannot
# separate two dialogs and "style 0x3" is a guess about which one it is, not a name.
#
# Captures land in captures/r209-<n>/ and are NOT deleted, because the verdict is what the last
# capture LOOKS like and a black screenshot is the failing signature.
set -u

cd "$(dirname "$0")/.."
RUNS=${1:-10}
PREFIX=/tmp/cider-lo-1000/prefix
APP=/Applications/LibreOffice.app/Contents/MacOS/soffice
PROFILE="$PREFIX/Users/root/Library/Application Support/LibreOffice/4/user/registrymodifications.xcu"

# LibreOffice shows the Tip of the Day once per day, keyed on days since the Unix epoch. Without
# this reset every run after the first of a day measures a scenario with no dialog, which always
# passes. That invalidated 40 runs on 2026-09-08.
reset_tip() {
	[ -f "$PROFILE" ] || return 0
	sed -i -E 's/(oor:name="LastTipOfTheDayShown"[^>]*><value>)[0-9]+/\10/' "$PROFILE"
}

# A role line is NOT enough: the suppressed dialog is still created and still gets one, it just
# never maps. Only mapped=yes means there was something on screen to type into.
tip_shown() {
	local n
	for n in $(grep -oE "role number=[0-9]+ style=0x[0-9a-f]+ panel=[a-z]+ dialog=true" "$1" 2>/dev/null |
		grep -oE "number=[0-9]+" | cut -d= -f2); do
		grep -qE "cider-wayland-window mapped=yes number=$n " "$1" && printf '%s ' "$n"
	done
}

reap() {
	for p in $(ls /proc | grep -E '^[0-9]+$'); do
		case "$(readlink /proc/$p/exe 2>/dev/null)" in
			*mldr*|*ciderd*) kill -9 "$p" 2>/dev/null ;;
		esac
	done
	sleep 2
}

pass=0
fail=0
dialogs=0
for i in $(seq 1 "$RUNS"); do
	reap
	reset_tip
	rm -f "$PREFIX/ciderd.log"
	name="r209-$i"
	SETTLE=45 POST_SETTLE=12 LIMIT=300 LAUNCHD=1 \
		CLICK="100,273" TYPE="Cider types into Writer" \
		TRACE_ENV="${TRACE_ENV:-}" \
		scripts/app-drive.sh --prefix "$PREFIX" --app "$APP" --name "$name" \
		>"captures/$name.drive.log" 2>&1
	log="captures/$name/app.log"
	if grep -q "cider-app exit=" "$log" 2>/dev/null; then
		fail=$((fail + 1))
		verdict="EXITED"
	else
		pass=$((pass + 1))
		verdict="alive "
	fi
	shown=$(tip_shown "$log")
	if [ -n "$shown" ]; then
		dialogs=$((dialogs + 1))
	fi
	echo "run $i: $verdict  dialog_mapped=${shown:-NONE}  windows:"
	grep -oE "cider-wayland-window (role|hide) number=[0-9]+.*" "$log" 2>/dev/null |
		sed -E 's/panel=[a-z]+ //; s/class=SalFrameWindow //; s/^/    /'
done
echo
echo "RATE: $fail exited of $RUNS runs, $pass alive"
echo "SCENARIO: $dialogs of $RUNS runs actually had a dialog on screen to type into"
reap
