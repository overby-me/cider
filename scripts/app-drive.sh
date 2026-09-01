#!/usr/bin/env bash
# DRIVE A GUI APPLICATION UNDER CIDER AND CAPTURE WHAT IT DREW.
#
# WHY THIS IS IN THE REPOSITORY. Every driver that verified an application used to live in the
# session scratchpad under /tmp, and on 2026-09-01 systemd-tmpfiles deleted all of it: the drivers,
# the status file and every analysis tool, because they were eleven days old and /tmp is swept by
# age. The machine had not rebooted. Nothing was recoverable, because scratchpad/ in this repository
# is a SYMLINK into that same directory and was never tracked. So the harness lives here now.
#
# WHAT IT DOES, which is exactly the three criteria and nothing else:
#   RENDERS     a capture at startup, to be LOOKED AT rather than counted
#   INTERACTIVE a real pointer click and a real key press, through a virtual input device
#   RESIZABLE   the compositor output is resized and the window captured again
#
# The application runs inside a NESTED compositor, not the user's own: the user's session is a
# tiling manager, and a window there gets resized by the manager mid-run, which has silently
# invalidated resize measurements before.
#
#   scripts/app-drive.sh --prefix /tmp/cider-sp-1000/prefix \
#       --app "/Applications/Swift Publisher 5.app/Contents/MacOS/Swift Publisher 5"
#
# Captures land in captures/<name>/ in the repository, NOT in /tmp, for the reason above.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=""
APPBIN=""
NAME=""
SETTLE=${SETTLE:-25}       # seconds to let the application draw before the first capture
LIMIT=${LIMIT:-120}        # hard stop for the whole run
WIDTH=${WIDTH:-1256}
HEIGHT=${HEIGHT:-684}
CLICK=${CLICK:-}           # "x,y" to click after the first capture, empty to skip
TYPE=${TYPE:-}             # text to type after the click, empty to skip

while [ $# -gt 0 ]; do
	case "$1" in
		--prefix) PREFIX="$2"; shift 2 ;;
		--app) APPBIN="$2"; shift 2 ;;
		--name) NAME="$2"; shift 2 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
[ -n "$PREFIX" ] && [ -n "$APPBIN" ] || { echo "usage: $0 --prefix <dir> --app <guest binary> [--name <label>]" >&2; exit 2; }
[ -n "$NAME" ] || NAME=$(basename "$(dirname "$(dirname "$APPBIN")")" .app | tr ' ' '-')

say() { echo "DRIVE $*" >&2; }

# TOOLS. sway, grim and wtype are nixpkgs; a store path that worked last month may have been
# collected, so ask nix rather than hardcoding one. This is the slow part of a cold run and the
# fast part of every other one.
tool() {
	local attr=$1 bin=$2 path
	if command -v "$bin" >/dev/null 2>&1; then command -v "$bin"; return; fi
	path=$(nix build --no-link --print-out-paths "nixpkgs#$attr" 2>/dev/null | head -1)
	[ -n "$path" ] && [ -x "$path/bin/$bin" ] && { echo "$path/bin/$bin"; return; }
	echo ""
}
SWAY=$(tool sway sway); SWAYMSG=$(dirname "$SWAY" 2>/dev/null)/swaymsg
GRIM=$(tool grim grim)
WTYPE=$(tool wtype wtype)
for t in SWAY GRIM WTYPE; do
	[ -n "${!t}" ] || { echo "missing tool: $t" >&2; exit 3; }
done

# The virtual pointer holds its device open for a whole gesture. sway IPC makes a device per
# command list and drops it at the end, so a press and a release arrive with the same timestamp and
# every motion comes with no button held: that is why this exists rather than swaymsg seat commands.
VPTR="$REPO/.cache/cider-vptr"
if [ ! -x "$VPTR" ] || [ "$REPO/scripts/cider-vptr.c" -nt "$VPTR" ]; then
	mkdir -p "$REPO/.cache"
	say "building the virtual pointer"
	# The wlr virtual pointer protocol is XML, not a header: wayland-scanner generates both halves,
	# and the glue C has to be compiled in or every request is an undefined symbol.
	proto=$(nix build --no-link --print-out-paths nixpkgs#wlr-protocols 2>/dev/null | head -1)
	scanner=$(nix build --no-link --print-out-paths nixpkgs#wayland-scanner 2>/dev/null | grep -m1 bin)
	xml="$proto/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml"
	[ -f "$xml" ] || { echo "wlr-protocols has no virtual pointer xml at $xml" >&2; exit 3; }
	"$scanner/bin/wayland-scanner" client-header "$xml" \
		"$REPO/.cache/wlr-virtual-pointer-unstable-v1-client-protocol.h" || exit 3
	"$scanner/bin/wayland-scanner" private-code "$xml" \
		"$REPO/.cache/wlr-virtual-pointer-unstable-v1-protocol.c" || exit 3
	cc -O2 -I"$REPO/.cache" -o "$VPTR" "$REPO/scripts/cider-vptr.c" \
		"$REPO/.cache/wlr-virtual-pointer-unstable-v1-protocol.c" \
		$(pkg-config --cflags --libs wayland-client 2>/dev/null || echo -lwayland-client) \
		2>"$REPO/.cache/cider-vptr.log" || { echo "vptr build failed, see .cache/cider-vptr.log" >&2; exit 3; }
fi

# The artifact path carries the package path, which moved when first-party code went under src/, so
# match both and take the newest: an old launcher still on disk is the wrong guest entirely.
CIDER=${CIDER:-$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/launcher/__cider__/cider \
	"$REPO"/buck-out/v2/art/root/*/linux/launcher/__cider__/cider 2>/dev/null | head -1)}
[ -x "$CIDER" ] || { echo "no cider launcher found, build //src/linux/launcher:cider or set CIDER" >&2; exit 3; }

SHOTS="$REPO/captures/$NAME"
rm -rf "$SHOTS"; mkdir -p "$SHOTS"

# A NESTED COMPOSITOR OF OUR OWN, so the user's tiling manager cannot resize the window under us.
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
PARENT_DISPLAY=${PARENT_DISPLAY:-wayland-1}
cat > "$SHOTS/sway.conf" <<EOF
default_border none
focus_follows_mouse yes
output * mode ${WIDTH}x${HEIGHT}
EOF
# Which socket is OURS is decided by difference: sway picks the next free wayland-N, so record the
# set before starting it and take whatever is new. Guessing a name races the compositor.
before=$(ls "$XDG_RUNTIME_DIR"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | sort)
WAYLAND_DISPLAY=$PARENT_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
	WLR_BACKENDS=wayland "$SWAY" -c "$SHOTS/sway.conf" -d >"$SHOTS/sway.log" 2>&1 &
SWAYPID=$!
NEW=""
for _ in $(seq 1 60); do
	after=$(ls "$XDG_RUNTIME_DIR"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | sort)
	fresh=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
	[ -n "$fresh" ] && { NEW=$(basename "$fresh"); break; }
	sleep 0.25
done
[ -n "$NEW" ] || { echo "nested compositor never came up, see $SHOTS/sway.log" >&2; kill $SWAYPID 2>/dev/null; exit 4; }
say "nested compositor on $NEW"

shoot() { WAYLAND_DISPLAY=$NEW "$GRIM" "$SHOTS/$1.png" 2>>"$SHOTS/driver.log" && say "shot $1"; }

# WHAT THE GUEST NEEDS TOLD, and every one of these was a silent hang until it was measured (#168).
# The launcher bakes an install prefix and only finds its daemon as a SIBLING, which buck artifacts
# never are; the daemon names its own missing paths only in <prefix>/ciderd.log; and launchd cannot
# spawn a job here (#139), so the container is booted WITHOUT it, which is what every driver that
# ever ran an application did. Set LAUNCHD=1 to get the launchd path back.
CIDERD=${CIDERD:-$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/server/__ciderd__/ciderd 2>/dev/null | head -1)}
MLDR=${MLDR:-$(ls -t "$REPO"/buck-out/v2/art/root/*/src/darwin/loader/__mldr__/mldr 2>/dev/null | head -1)}
RT=${RT:-$(ls -td "$REPO"/buck-out/v2/art/root/*/buck/prefix/__cider_prefix__/cider_prefix__prefix 2>/dev/null | head -1)}
for t in CIDERD MLDR RT; do
	[ -e "${!t}" ] || { echo "missing $t: build //src/linux/server:ciderd, //src/darwin/loader:mldr and //buck/prefix:cider_prefix" >&2; exit 3; }
done

say "launching $APPBIN"
(
	CIDERPREFIX="$PREFIX" WAYLAND_DISPLAY=$NEW XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000} \
		CIDER_NO_LAUNCHD=${LAUNCHD:-1} \
		DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
		DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
		timeout "$LIMIT" "$CIDER" shell "$APPBIN"
) >"$SHOTS/app.log" 2>&1 &
APPPID=$!

sleep "$SETTLE"
shoot d1-start

if [ -n "$CLICK" ]; then
	x=${CLICK%,*}; y=${CLICK#*,}
	say "click at $x,$y"
	printf 'move %s %s\nclick\n' "$x" "$y" | WAYLAND_DISPLAY=$NEW "$VPTR" "$WIDTH" "$HEIGHT" \
		>>"$SHOTS/driver.log" 2>&1
	sleep 3
	shoot d2-click
fi

if [ -n "$TYPE" ]; then
	say "typing"
	WAYLAND_DISPLAY=$NEW "$WTYPE" "$TYPE" >>"$SHOTS/driver.log" 2>&1
	sleep 3
	shoot d3-typed
fi

say "resizing the output to $((WIDTH - 256))x$((HEIGHT - 84))"
WAYLAND_DISPLAY=$NEW "$SWAYMSG" output '*' mode $((WIDTH - 256))x$((HEIGHT - 84)) >>"$SHOTS/driver.log" 2>&1
sleep 5
shoot d4-resized

kill $APPPID 2>/dev/null
kill $SWAYPID 2>/dev/null
say "captures in $SHOTS"
ls "$SHOTS"/*.png 2>/dev/null
