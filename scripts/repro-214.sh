#!/usr/bin/env bash
# LOOP THE #214 SCENARIO AND SAY WHERE EACH RUN FAULTED.
#
# One run is not a rate. #214 has been seen once, so the first job here is to find out whether
# cancelling the save panel kills mmex every time or now and then.
#
#   scripts/repro-214.sh [runs]        default 5
#
# The click at 627,249 is the New Database button on the startup screen, which opens the main
# window AND our NSSavePanel on top of it. Escape then cancels the panel.
#
# The driver reports cider-app exit=0 for this crash, so DO NOT read the exit status: the fault is
# recorded by the guest signal path in ciderd.log as "sigexc: have RIP". That file appends across
# runs, so it is removed before each one.
set -u

cd "$(dirname "$0")/.."
RUNS=${1:-5}
PREFIX=/tmp/cider-mx-1000/prefix
APP=/Applications/mmex.app/Contents/MacOS/mmex

reap() {
	for p in $(ls /proc | grep -E '^[0-9]+$'); do
		case "$(readlink /proc/$p/exe 2>/dev/null)" in
			*mldr*|*ciderd*) kill -9 "$p" 2>/dev/null ;;
		esac
	done
	sleep 2
}

crashed=0
alive=0
for i in $(seq 1 "$RUNS"); do
	reap
	name="r214-$i"
	rm -rf "$PREFIX/ciderd.log" "captures/$name" "captures/$name.ciderd.log"
	SETTLE=${SETTLE:-45} POST_SETTLE=${POST_SETTLE:-12} LIMIT=${LIMIT:-300} LAUNCHD=1 \
		CLICK="${CLICK:-627,249}" TYPE="${TYPE:-key:Escape}" \
		TRACE_ENV="${TRACE_ENV:-}" \
		scripts/app-drive.sh --prefix "$PREFIX" --app "$APP" --name "$name" \
		>"captures/$name.drive.log" 2>&1
	cp -f "$PREFIX/ciderd.log" "captures/$name.ciderd.log" 2>/dev/null
	# A run that never launched leaves the PREVIOUS run's log in place, and reading it reports a
	# fault that did not happen. Seen once: the nested compositor came up on a display the driver
	# was not watching, and the stale verdict looked like a fresh reproduction.
	if [ ! -f "captures/$name/app.log" ]; then
		echo "run $i: NORUN   see captures/$name.drive.log"
		continue
	fi
	if grep -q "sigexc" "captures/$name.ciderd.log" 2>/dev/null; then
		crashed=$((crashed + 1))
		verdict="FAULTED"
	else
		alive=$((alive + 1))
		verdict="clean  "
	fi
	echo "run $i: $verdict"
	grep -oE "sigexc: have RIP [0-9A-Fa-fx]+" "captures/$name.ciderd.log" 2>/dev/null | sed 's/^/    /'
	grep -oE "cider-wayland-window (role|hide) number=[0-9]+.*" "captures/$name/app.log" 2>/dev/null |
		sed -E 's/panel=[a-z]+ //; s/^/    /'
done
echo
echo "RATE: $crashed faulted of $RUNS runs, $alive clean"
reap
