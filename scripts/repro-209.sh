#!/usr/bin/env bash
# LOOP THE #209 SCENARIO AND NAME THE WINDOWS OF EVERY RUN.
#
# The defect is roughly 1 run in 5, so a single run proves nothing either way and the only honest
# output is a RATE. Each run does exactly what #209 recorded: launch LibreOffice, click Writer
# Document, then type with the Tip of the Day dialog still up, which is blind typing into whatever
# has focus.
#
#   scripts/repro-209.sh [runs]        default 10
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
for i in $(seq 1 "$RUNS"); do
	reap
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
	echo "run $i: $verdict  windows:"
	grep -oE "cider-wayland-window (role|hide) number=[0-9]+.*" "$log" 2>/dev/null |
		sed -E 's/panel=[a-z]+ //; s/class=SalFrameWindow //; s/^/    /'
done
echo
echo "RATE: $fail exited of $RUNS runs, $pass alive"
reap
