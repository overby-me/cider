#!/usr/bin/env bash
# Run an AppKit program inside the buck2-built Darling, against a real X server.
#
# The GUI cone -- AppKit, cocotron, CoreGraphics, Onyx2D and the sixteen src/native stubs
# that forward to the host's X11, cairo and OpenGL -- is the largest part of the port that
# links cleanly, exports the right symbols and has never executed an instruction. This runs
# tests/buck2/gui/appkit_probe.m, which brings NSApplication up, opens an NSWindow and
# pumps one event, printing at each step so a first run says how far it got rather than
# just pass or fail.
#
# It supplies its OWN Xvfb rather than borrowing $DISPLAY: a probe that draws on the
# developer's desktop is a probe nobody runs twice, and a headless server makes the check
# usable from CI. Xephyr is fine too if you want to watch it.
#
# Usage:  scripts/buck-appkit-check.sh [<scratch dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

root=${1:-/tmp/darling-appkit-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}
command -v Xvfb >/dev/null || {
	say "missing Xvfb -- the GUI cone needs an X server to talk to"
	exit 2
}

say "== building the prefix and the probe =="
out=$(buck2 build //buck/prefix:darling_prefix //tests/buck2/gui:appkit_probe \
	--show-output 2>/dev/null)
art=$(awk '/darling_prefix/ {print $2}' <<<"$out")
bin=$(awk '/appkit_probe/ {print $2}' <<<"$out")
for f in "$art" "$bin"; do
	[ -e "$f" ] || {
		say "missing build output: $f"
		exit 1
	}
done

for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== materializing into $rt =="
chmod -R u+w "$rt" 2>/dev/null || true
rm -rf "$rt" "$prefix" "$prefix.workdir"
mkdir -p "$rt" "$prefix"
# `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
cp -a "$art"/. "$rt"/
chmod -R u+w "$rt"
cp "$bin" "$rt/libexec/darling/usr/bin/appkit_probe"
chmod +x "$rt/libexec/darling/usr/bin/appkit_probe"

# A display number nobody else is on. :0 and the developer's own session are left alone.
disp=:$((90 + (RANDOM % 8)))
say "== starting Xvfb on $disp =="
Xvfb "$disp" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
trap 'kill '"$xvfb"' 2>/dev/null || true' EXIT
# Xvfb takes a moment to create the socket, and connecting before it exists looks exactly
# like "cannot open display", which is the failure this probe is trying to distinguish.
for _ in $(seq 1 50); do
	[ -e "/tmp/.X11-unix/X${disp#:}" ] && break
	sleep 0.1
done
[ -e "/tmp/.X11-unix/X${disp#:}" ] || {
	say "Xvfb did not come up on $disp"
	exit 1
}

# The host ELF libraries have to be reachable by the LOADER, not just by wrapgen. Without
# this the probe does not merely fail to draw: loading AppKit kills the process before
# main, with no output at all, because the sixteen src/native stubs forward into libX11,
# cairo and freetype through elfcalls and a stub whose .so cannot be dlopened takes the
# process with it. .buckconfig.local already knows the directories -- darling.elf_lib_dirs
# is how wrapgen found the same libraries at BUILD time -- so reuse them rather than
# inventing a second list.
elf_dirs=$(sed -n 's/^elf_lib_dirs *= *//p' .buckconfig.local)
[ -n "$elf_dirs" ] || {
	say "no darling.elf_lib_dirs in .buckconfig.local -- run scripts/buck-setup.sh"
	exit 2
}

say "== running the probe inside the container =="
out=$(
	LD_LIBRARY_PATH="$elf_dirs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		DISPLAY="$disp" \
		timeout 180 "$rt/bin/darling" shell /usr/bin/appkit_probe 2>&1
) || true

printf '%s\n' "$out"
# Graded, because the interesting outcomes are the partial ones: reaching NSApplication
# proves the cone loads and the X connection opened, and reaching the window proves
# cocotron's backend built a real drawable.
case "$out" in
*APPKIT_PROBE_OK*)
	say "PASS: AppKit brought up an app, opened a window and pumped the run loop"
	exit 0
	;;
*"APPKIT_PROBE ordered-front"*)
	say "PARTIAL: the window was created and ordered front, but the event pump did not finish"
	exit 3
	;;
*"APPKIT_PROBE window=yes"*)
	say "PARTIAL: NSWindow was created but could not be ordered front"
	exit 3
	;;
*"APPKIT_PROBE app=yes"*)
	say "PARTIAL: NSApplication came up but no window could be created"
	exit 3
	;;
*"APPKIT_PROBE start"*)
	say "PARTIAL: the binary ran but NSApplication did not come up"
	exit 3
	;;
*)
	say "FAIL: the AppKit probe did not run at all"
	exit 1
	;;
esac
