#!/usr/bin/env bash
# RUN THE SAME DRIVE N TIMES AND REPORT A RATE, because asserting one has been wrong repeatedly.
#
#   N=12 scripts/app-rate.sh --prefix /tmp/cider-sp-1000/prefix \
#        --app "/Applications/Swift Publisher 5.app/Contents/MacOS/Swift Publisher 5" \
#        --name sp-rate --click "1022,619;60,197"
#
# SURVIVED means the driver hit its time limit with the application still running: app-drive prints
# cider-app exit=124 for the timeout, or no exit line at all. ANY other exit code is a failure for
# this purpose, because the application was supposed to still be up. That distinction matters: a
# crash iA Writer swallowed reported exit=0, which reads as success to anything naive.
#
# TWO CONTROLS ARE PRINTED, and neither is optional. A trial whose click did not land is vacuous,
# so the run compares d1 against d2 and counts how many actually changed the screen. And a detector
# that cannot fail proves nothing, so the exit classification is stated for the reader to check.
#
# The arithmetic to go with the count, for 0 failures in N trials:
#   95 percent upper bound on the rate is 1 - 0.05^(1/N)   N=12 -> 0.22, N=25 -> 0.11, N=40 -> 0.07
# Zero failures NEVER means the defect is gone; it bounds how common it can still be.
set -u
cd "$(dirname "$0")/.."
N=${N:-10}
PREFIX=""; APP=""; NAME="rate"; CLICKS=""; TYPETEXT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--prefix) PREFIX="$2"; shift 2 ;;
		--app)    APP="$2";    shift 2 ;;
		--name)   NAME="$2";   shift 2 ;;
		--click)  CLICKS="$2"; shift 2 ;;
		--type)   TYPETEXT="$2"; shift 2 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
[ -n "$PREFIX" ] && [ -n "$APP" ] || { echo "usage: $0 --prefix <dir> --app <binary> [--name x] [--click seq] [--type text]" >&2; exit 2; }

reap() {
	for p in $(ls /proc | grep -E '^[0-9]+$'); do
		case "$(readlink /proc/$p/exe 2>/dev/null)" in *mldr*|*ciderd*) kill -9 "$p" 2>/dev/null ;; esac
	done
	sleep 2
}

pass=0; fail=0; landed=0; vacuous=0
for i in $(seq 1 "$N"); do
	reap
	rm -f "$PREFIX/ciderd.log"          # append only across runs, so truncate before measuring
	env SETTLE="${SETTLE:-20}" LIMIT="${LIMIT:-70}" POST_SETTLE="${POST_SETTLE:-3}" \
		${RESIZE_W:+RESIZE_W=$RESIZE_W} ${RESIZE_H:+RESIZE_H=$RESIZE_H} \
		${CLICKS:+CLICK="$CLICKS"} ${TYPETEXT:+TYPE="$TYPETEXT"} \
		scripts/app-drive.sh --prefix "$PREFIX" --app "$APP" --name "$NAME-$i" \
		>"captures/$NAME-$i.drive.log" 2>&1

	ex=$(grep -a "cider-app exit=" "captures/$NAME-$i/app.log" 2>/dev/null | tail -1 | sed 's/.*exit=//')
	if [ -z "$ex" ] || [ "$ex" = "124" ]; then
		pass=$((pass + 1)); verdict=SURVIVED
	else
		fail=$((fail + 1)); verdict="GONE exit=$ex"
	fi

	if [ -n "$CLICKS" ]; then
		a=$(md5sum "captures/$NAME-$i/d1-start.png" 2>/dev/null | awk '{print $1}')
		b=$(md5sum "captures/$NAME-$i/d2-click.png" 2>/dev/null | awk '{print $1}')
		if [ -n "$a" ] && [ "$a" = "$b" ]; then vacuous=$((vacuous + 1)); else landed=$((landed + 1)); fi
	fi
	echo "trial $i: $verdict"
done

reap
echo "RATE: $fail failures in $N trials (survived $pass)"
[ -n "$CLICKS" ] && echo "CONTROL: the click changed the screen in $landed trials, did nothing in $vacuous"
echo "CONTROL: a run that exits 0 is counted GONE, not survived"
