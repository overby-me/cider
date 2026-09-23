#!/usr/bin/env bash
#
# CAN AN APPLICATION STILL INVOKE A MENU COMMAND.
#
# Nothing in the four standing gates exercises this. roster-input OPENS a menu and stops there, and
# a capture cannot see the difference anyway: every menu drew perfectly throughout the six defects
# that were fixed on 2026-09-23, and the only thing that ever told them apart was the tracking
# trace. So this asserts on the trace rather than on pixels.
#
# One drive, on iA Writer, because its View menu is the sharpest case available:
#
#   - it HIDES an item (Enable Dark Mode) at the head of the menu, so a hit test that walks the
#     menu's full item array instead of the visible one picks the separator (cocotron 0124);
#   - Text Size is a PARENT, so releasing on it has to leave the menu open rather than end
#     tracking (cocotron 0123);
#   - and the item chosen is three levels down, which is the only path that exercises a viewStack
#     deeper than two.
#
# Make Text Normal Size is deliberate: it sets the editor text size to the default, so a pass
# leaves no persisted state behind and cannot move a roster baseline.
#
# NOT covered here, and both want their own case if this grows: the leftmost bar item, which is the
# only one that met cocotron 0125, and key equivalents, which met 0128.
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"

PREFIX=${PREFIX:-/tmp/cider-ia-1000/prefix}
APP=${APP:-/Applications/iA Writer.app/Contents/MacOS/iA Writer}
NAME=${NAME:-check-menu-command}
WANT=${WANT:-Make Text Normal Size}

scripts/kill-cider-container.sh "$PREFIX" >/dev/null 2>&1 || true
sleep 2

SETTLE=45 LIMIT=280 WIDTH=1000 HEIGHT=600 LAUNCHD=1 \
	TRACE_ENV="CIDER_TRACE_MENU=1" \
	STEPS="wait:45 click:293,36 wait:22 click:325,252 wait:26 click:547,289 wait:28 shot:chosen" \
	scripts/app-drive.sh --prefix "$PREFIX" --app "$APP" --name "$NAME" \
	>"/tmp/$NAME.drive.log" 2>&1

LOG="captures/$NAME/app.log"
if [ ! -s "$LOG" ]; then
	echo "FAIL: no app.log, see /tmp/$NAME.drive.log"
	exit 1
fi

# A GUEST THAT NEVER STARTED LOOKS EXACTLY LIKE A MENU THAT CHOSE NOTHING, and both are silent
# here, so prove the run happened before reading anything into the absence of a track line.
lines=$(wc -l < "$LOG")
if [ "$lines" -lt 100 ]; then
	echo "FAIL: the guest never started, $lines lines of log, see $LOG"
	exit 1
fi

track=$(grep -m1 'CIDER_MENU track ' "$LOG" || true)
if [ -z "$track" ]; then
	echo "FAIL: tracking never returned an item at all"
	echo "  the menu opened but nothing was chosen; see $LOG"
	exit 1
fi

case "$track" in
*"item=$WANT "*)
	echo "PASS: $track"
	exit 0
	;;
esac

echo "FAIL: tracking chose the wrong item"
echo "  wanted: item=$WANT"
echo "  got:    $track"
exit 1
