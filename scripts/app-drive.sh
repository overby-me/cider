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
# HEADLESS, NOT NESTED IN A WINDOW. On the wayland backend the output is a window in the user's
# tiling manager, and neither the mode in this config nor a later swaymsg output mode changes its
# size: two captures taken either side of a resize came back identically 930x1028, the size the
# parent had chosen. Headless owns its own output, so the size asked for is the size captured, and
# the resize criterion becomes measurable.
WAYLAND_DISPLAY=$PARENT_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
	WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_HEADLESS_INPUTS=1 "$SWAY" -c "$SHOTS/sway.conf" -d >"$SHOTS/sway.log" 2>&1 &
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
# swaymsg finds its IPC socket through SWAYSOCK, not through WAYLAND_DISPLAY: without it the resize
# step failed with "Unable to retrieve socket path" and the output never changed size.
SWAYSOCK=$(ls -t "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1)
export SWAYSOCK

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

# THE HOST LIBRARIES THE GUEST DLOPENS. mldr loads libGL and friends out of the nix store, and with
# no search path it tries whichever store directory it saw last: the first run failed with
# "libGL.so.1: /nix/store/...-alsa-lib-.../lib/libGL.so.1: cannot open shared object file", which
# names alsa-lib because that was simply the last entry, not because anyone asked for it.
# buck-setup.nu already computes the list; it is the same one the compiler links against.
ELF_LIBS=$(grep '^elf_lib_dirs' "$REPO/.buckconfig.local" 2>/dev/null | sed 's/^elf_lib_dirs *= *//')

# THE ENTRY POINTS A NEWER SWIFT EXPECTS. Nothing links this library, so it has to be inserted, and
# dyld's last-resort lookup matches the image by its exact path, which is why the same string is
# both variables. Without it iTerm2 and iA Writer die in dyld before any window:
# "Symbol not found: _$ss042_stdlib_isOSVersionAtLeastOrVariantVersion..., expected in libswiftCore".
COMPAT=${COMPAT:-/usr/lib/swift/libswiftCompat.dylib}

say "launching $APPBIN"
(
	# env, NOT an assignment prefix. An unquoted ${VAR:+NAME=value} is expanded AFTER the line is
	# parsed, so bash does not see an assignment and takes it as the command name: the whole run
	# died with "CIDER_WAYLAND_TRACE_INPUT=1: command not found" and an empty log.
	# SLIM THE ENVIRONMENT, and this is not tidiness. iTerm2 encodes a launch request for every
	# child it starts, the request CARRIES THE ENVIRONMENT, and the buffer is fixed: with the nix
	# devshell inherited (NIX_CFLAGS_COMPILE alone is 21 KB) it aborts at "encoded length 67951" and
	# no session ever starts. The failure never mentions size. PATH and LD_LIBRARY_PATH stay because
	# the runtime needs them.
	UNSET=$(env | awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ && length($0)>400 && $1!="PATH" && $1!="LD_LIBRARY_PATH" {printf "-u %s ", $1}')
	env $UNSET CIDERPREFIX="$PREFIX" WAYLAND_DISPLAY=$NEW XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000} \
		CIDER_NO_LAUNCHD="${LAUNCHD:-1}" LD_LIBRARY_PATH="$ELF_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		DYLD_INSERT_LIBRARIES="$COMPAT" CIDER_COMPAT_LIBRARY="$COMPAT" \
		${TRACE_INPUT:+CIDER_WAYLAND_TRACE_INPUT=1} ${TRACE_ENV:-} \
		DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
		DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
		${WRAP:-} timeout "$LIMIT" "$CIDER" shell "$APPBIN"
	# A quiet exit and a process still running at the limit leave the same silence in the log, and
	# they want opposite work. 124 is the timeout's own code: still alive.
	echo "cider-app exit=$?"
) >"$SHOTS/app.log" 2>&1 &
APPPID=$!

sleep "$SETTLE"
shoot d1-start

# A SEQUENCE, not a click. Showing that the keyboard works needs a text field, and a text field is
# several clicks deep in most applications: Swift Publisher wants the welcome window closed, a
# template picked and Choose pressed before anything will take a keystroke. Semicolons separate.
for STEP in ${CLICK//;/ }; do
	x=${STEP%,*}; y=${STEP#*,}
	say "click at $x,$y"
	# The vocabulary is abs/rel/press/release/scroll/sleep. "move" and "click" were ignored in
	# silence, which reads exactly like a click that landed and did nothing.
	printf 'abs %s %s\nsleep 200\npress left\nsleep 80\nrelease left\n' "$x" "$y" \
		| WAYLAND_DISPLAY=$NEW "$VPTR" "$WIDTH" "$HEIGHT" >>"$SHOTS/driver.log" 2>&1
	sleep 4
done
[ -n "$CLICK" ] && shoot d2-click

if [ -n "$TYPE" ]; then
	say "typing $TYPE"
	# key:<name> sends a named key rather than text. Proving the keyboard works needs something
	# whose effect is VISIBLE, and in an application whose text fields are several clicks deep the
	# cheapest such thing is Return on a selection.
	send_keys() {
		# -s SLEEPS BEFORE TYPING, and that is the whole trick. wtype creates its virtual keyboard
		# when it starts and destroys it when it exits, so the seat gains and loses the capability in
		# one breath; the guest attaches its wl_keyboard listener only after it SEES the capability,
		# and every key was gone before the listener existed. Sleeping first keeps the device alive
		# long enough for the application to attach, and -d spaces the keys so none is lost to the
		# same race.
		case "$TYPE" in
			key:*) WAYLAND_DISPLAY=$NEW "$WTYPE" -s 1500 -k "${TYPE#key:}" >>"$SHOTS/driver.log" 2>&1 ;;
			*)     WAYLAND_DISPLAY=$NEW "$WTYPE" -s 1500 -d 120 "$TYPE" >>"$SHOTS/driver.log" 2>&1 ;;
		esac
	}
	send_keys
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
