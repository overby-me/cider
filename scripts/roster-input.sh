#!/usr/bin/env bash
# DRIVE THE ROSTER WITH REAL INPUT AND SAY WHERE IT LANDED.
#
# WHY THIS EXISTS ALONGSIDE roster-sweep.sh. That script launches and resizes, and its own docstring
# says it does not test input, so it can establish two of the three criteria and never the second.
# INTERACTIVE was carried for a long time as a claim in task #189 with no repeatable check behind
# it, and for MoneyMoney and LibreOffice it had never been demonstrated at all. This is that check.
#
#   scripts/roster-input.sh              drive all of them
#   scripts/roster-input.sh mm lo        drive a subset
#
# Captures land in captures/input-<tag>/. LOOK AT THEM: d2-click is after the clicks, d3-typed
# after the keys, and d5-settled POST_SETTLE later. A byte count is not a verdict. d3 in particular
# catches iTerm2 mid-word, because wtype spaces its keys and the shot does not wait for the last
# one; d5 is the one that shows the finished line.
#
# THE COORDINATES ARE FOR THE DEFAULT 1256x684 OUTPUT and were read off captures at that size. They
# are the fragile part of this file: a chrome change moves them and the click lands on nothing,
# which looks exactly like a click that was never delivered. When a step stops working, re-read the
# coordinate off a fresh d1-start before assuming the input path broke.
#
# NEVER USE REAL CREDENTIALS WITH MONEYMONEY. It talks to banks. The step here types into the
# TOOLBAR SEARCH FIELD, which is a local filter over accounts and contacts nothing.
#
# CLICK RUNS BEFORE TYPE FOR EVERY ENTRY and that ordering is load bearing twice over. TYPE is what
# creates the keyboard, so a click-only run has no key window; and a run driven the other way round,
# TYPE then POST_CLICK, was observed ONCE on mmex to get no pointer capability at all, so the click
# was never delivered and the application looked unresponsive when it was not. One observation is
# not a rate and it is not chased here, but every entry below uses the order that is known to work.
set -u

cd "$(dirname "$0")/.."
SHOTS=captures
SETTLE=${SETTLE:-45}
POST_SETTLE=${POST_SETTLE:-15}
LIMIT=${LIMIT:-360}

# tag | prefix | app binary | launchd (0 = ON) | CLICK sequence | TYPE | what it proves
#
# iA Writer is clicked ON THE MENU BAR and nothing is typed, and both of those are deliberate.
# Measured 2026-09-07: a click on a file row and a click on a sidebar item BOTH produce no visible
# response, and the window's traffic lights stay grey, so it never becomes key. The menu bar is a
# different path and works. Keys arrive and the app discards them because the editor is licence
# gated, which is its own behaviour and not an input defect. See #210.
roster() {
	cat <<'EOF'
ia|/tmp/cider-ia-1000/prefix|/Applications/iA Writer.app/Contents/MacOS/iA Writer|1|293,36||the View menu opens with its full item list
sp|/tmp/cider-sp-1000/prefix|/Applications/Swift Publisher 5.app/Contents/MacOS/Swift Publisher 5|1|1022,619;72,174||welcome window closes, Brochures selects
mm|/tmp/cider-mm-1000/prefix|/Applications/MoneyMoney.app/Contents/MacOS/MoneyMoney|1|1130,75|cider|search field focuses and shows cider
it|/tmp/cider-it-1000/prefix|/Applications/iTerm2.app/Contents/MacOS/iTerm2|0||echo cider types here|the command appears at the prompt
lo|/tmp/cider-lo-1000/prefix|/Applications/LibreOffice.app/Contents/MacOS/soffice|1|100,273;813,434;600,550|Cider types into Writer|Writer opens and the text lands on the page
mx|/tmp/cider-mx-1000/prefix|/Applications/mmex.app/Contents/MacOS/mmex|1|627,313|key:Escape|the User Interface Language dialog opens, then Escape closes it again
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
while IFS='|' read -r tag prefix app launchd clicks keys proves; do
	[ -n "$tag" ] || continue
	if [ -n "$want" ]; then case " $want " in *" $tag "*) ;; *) continue ;; esac; fi
	if [ ! -d "$prefix/Applications" ]; then
		echo "SKIP $tag: nothing staged in $prefix (scripts/app-stage.sh)"
		continue
	fi
	reap
	rm -f "$prefix/ciderd.log"
	env SETTLE="$SETTLE" POST_SETTLE="$POST_SETTLE" LIMIT="$LIMIT" LAUNCHD="$launchd" \
		CLICK="$clicks" TYPE="$keys" \
		scripts/app-drive.sh --prefix "$prefix" --app "$app" --name "input-$tag" \
		>"$SHOTS/input-$tag.drive.log" 2>&1 || rc=1
	# The last capture the run produced, since which one exists depends on whether the step clicks,
	# types or both. Naming it beats guessing at d2 or d3.
	last=$(ls -1 "$SHOTS/input-$tag"/d*.png 2>/dev/null | tail -1)
	if [ -n "$last" ]; then
		echo "$tag: $last   EXPECT: $proves   LOOK AT IT"
	else
		echo "$tag: NO CAPTURE, see $SHOTS/input-$tag.drive.log"
		rc=1
	fi
done < <(roster)
reap
exit "$rc"
