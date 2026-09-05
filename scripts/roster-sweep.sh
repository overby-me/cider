#!/usr/bin/env bash
# DRIVE THE WHOLE ROSTER AND SAY WHICH APPLICATIONS STILL WORK.
#
# WHY THIS EXISTS. A change in the guest runtime (libsystem_kernel, CoreFoundation, AppKit) is a
# change for EVERY application, and verifying only the one being worked on has repeatedly missed
# what it broke elsewhere. Task #196 removed a cached MIG reply used by every process; this is what
# says the other four still run.
#
#   scripts/roster-sweep.sh              drive all of them
#   scripts/roster-sweep.sh sp mm        drive a subset
#
# Captures land in captures/sweep-<tag>/. LOOK AT THEM. A byte count is not a verdict: an empty
# iA Writer capture is 2578 bytes and a black one of the right size is still black.
#
# TWO THINGS THIS ENCODES, both of which cost a wrong conclusion once:
#
#   ciderd.log is APPEND ONLY in a persistent prefix, so it accumulates every run ever made. Read
#   without truncating, it reported 128 stale failures and two different log formats at once. Every
#   run here truncates it first.
#
#   LAUNCHD IS PER APPLICATION and the variable is INVERTED: LAUNCHD=0 turns launchd ON. iTerm2
#   needs it on, because with no launchd its session gets a null bootstrap port and the shell exits
#   immediately ("A session ended very soon after starting"). The others are driven with it off,
#   which is what every earlier drive used.
set -u
cd "$(dirname "$0")/.."
SHOTS=captures
SETTLE=${SETTLE:-30}
LIMIT=${LIMIT:-140}

# tag | prefix | app binary | launchd (0 = ON) | resize WxH | extra TRACE_ENV
#
# THE RESIZE TARGET MUST CLEAR THE WINDOW MINIMUM. Below it the application answers its minimum,
# the extra height hangs off the output, and the capture shows a clipped title bar that reads as a
# window ignoring the configure. Measured minimum heights: Swift Publisher 618, LibreOffice 739.
# Above them both follow the request exactly, frame equal to surface.
roster() {
	cat <<'EOF'
ia|/tmp/cider-ia-1000/prefix|/Applications/iA Writer.app/Contents/MacOS/iA Writer|1|1000x600|
sp|/tmp/cider-sp-1000/prefix|/Applications/Swift Publisher 5.app/Contents/MacOS/Swift Publisher 5|1|900x650|
mm|/tmp/cider-mm-1000/prefix|/Applications/MoneyMoney.app/Contents/MacOS/MoneyMoney|1|1000x600|
it|/tmp/cider-it-1000/prefix|/Applications/iTerm2.app/Contents/MacOS/iTerm2|0|1000x600|
lo|/tmp/cider-lo-1000/prefix|/Applications/LibreOffice.app/Contents/MacOS/soffice|1|900x800|SAL_DISABLE_OPENCL=1
EOF
}

# Stale guest processes survive a driver exit and the next run inherits them, so reap by
# /proc/<pid>/exe rather than by name. Killing by interpreter name once took out the login shell.
reap() {
	for p in $(ls /proc | grep -E '^[0-9]+$'); do
		case "$(readlink /proc/$p/exe 2>/dev/null)" in
			*mldr*|*ciderd*) kill -9 "$p" 2>/dev/null ;;
		esac
	done
	sleep 2
}

want=${*:-}
rc=0
while IFS='|' read -r tag prefix app launchd resize extra; do
	[ -n "$tag" ] || continue
	if [ -n "$want" ]; then case " $want " in *" $tag "*) ;; *) continue ;; esac; fi
	if [ ! -d "$prefix/Applications" ]; then
		echo "SKIP $tag: nothing staged in $prefix (scripts/app-stage.sh)"
		continue
	fi
	reap
	rm -f "$prefix/ciderd.log"
	env SETTLE="$SETTLE" LIMIT="$LIMIT" LAUNCHD="$launchd" \
		RESIZE_W="${resize%x*}" RESIZE_H="${resize#*x}" ${extra:+TRACE_ENV="$extra"} \
		scripts/app-drive.sh --prefix "$prefix" --app "$app" --name "sweep-$tag" \
		>"$SHOTS/sweep-$tag.drive.log" 2>&1 || rc=1
	shot="$SHOTS/sweep-$tag/d1-start.png"
	if [ -f "$shot" ]; then
		echo "$tag: $(stat -c %s "$shot") bytes  $shot   LOOK AT IT"
	else
		echo "$tag: NO CAPTURE, see $SHOTS/sweep-$tag.drive.log"
		rc=1
	fi
done < <(roster)
reap
exit "$rc"
