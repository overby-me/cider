#!/usr/bin/env bash
# How much of what the prefix installs can actually be LOADED?
#
# Every coverage number this port has is about building: 1452 of 1452 link edges, install
# UNMAPPED 0, codegen accounted for. None of them says anything about running, and the eight
# other runtime checks between them touch a few dozen artifacts out of the several hundred
# the prefix ships. The rest were believed to work because they linked.
#
# This dlopens all of them inside the container and counts. A failure here is not
# automatically a bug: some libraries are meant to be loaded only through their framework,
# and the nine dev-stub frameworks have no code at all. But a library that cannot be dlopened
# certainly is not working, so the number is a real measurement rather than an inference, and
# a drop in it is a regression nothing else would catch.
#
# Each dlopen runs in a forked child, so an initializer that dies costs one result rather
# than the sweep: AppKit with no display took the whole probe down before that, leaving the
# other 335 unmeasured. Crashes are counted apart from load failures, because "its
# initializer needs a display" and "it cannot be found" are different facts.
#
# The probe still prints each path BEFORE trying it, so a HANG, which no exit status reports,
# still names the culprit instead of leaving a bisection to do.
#
# Usage:  scripts/buck-loadall-check.sh [<scratch dir>]
set -uo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

root=${1:-/tmp/darling-loadall-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

say "== building the prefix and the probe =="
out=$(buck2 build //buck/prefix:darling_prefix //tests/buck2/guest:loadall_probe \
	--show-output 2>/dev/null)
art=$(awk '/darling_prefix/ {print $2}' <<<"$out")
bin=$(awk '/loadall_probe/ {print $2}' <<<"$out")
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
cp "$bin" "$rt/libexec/darling/usr/bin/loadall_probe"
chmod +x "$rt/libexec/darling/usr/bin/loadall_probe"

# The list, as the GUEST sees the paths: libexec/darling is the container root, so it comes
# off the front. Regular files only -- the prefix is full of compatibility symlinks and
# counting both would double every library that has one.
# The display-dependent frameworks are NOT swept, and that is not a gap: dlopening AppKit
# with no display takes the whole container down rather than just its child, so it ends the
# sweep and leaves the other 335 unmeasured. It has its own check, scripts/buck-appkit-check.sh,
# which brings it up properly under X11 and opens a window, so the cone is covered by the tool
# built for it. Anything added here has to be justified the same way: a dedicated check, or a
# reason it cannot be loaded blind.
# FRAMEWORK BINARIES ARE SWEPT TOO. They were excluded on the belief that AppKit needs a
# display and ends the guest without one. That was wrong in the same way the 22 native
# wrappers were: the killer was a missing LD_LIBRARY_PATH, so their initializers could not
# dlopen the host libX11 through elfcalls and aborted. With it, AppKit, ApplicationServices
# and CoreText all dlopen cleanly with no display anywhere.
#
# A framework binary has no extension: Foo.framework/Versions/A/Foo, reached through the
# Foo.framework/Foo symlink that -type f skips.
#
# The 123 .so BUNDLES are deliberately NOT swept, and this was measured rather than assumed.
# They are interpreter extensions -- PyObjC, python lib-dynload, perl XS, zsh modules -- and
# most resolve their symbols against the INTERPRETER process through a bundle loader, so a
# standalone dlopen returns NULL for a healthy module. Tried on six PyObjC bundles: _inlines
# loads, _AppKit and _CoreFoundation do not, and neither result says anything about whether
# the module works. They are already covered properly by scripts/buck-scripting-check.sh,
# which imports them THROUGH the interpreter: python 55 of 56, zsh 32 of 32, perl 14 of 14.
# Adding them here would only make this number noisier and less true.

say "== enumerating what the prefix ships =="
list="$rt/libexec/darling/tmp/loadall.txt"
mkdir -p "$(dirname "$list")"
{
	find "$rt/libexec/darling" -type f -name '*.dylib'
	find "$rt/libexec/darling/System/Library/Frameworks" \
		-mindepth 3 -maxdepth 4 -type f ! -name '*.*' 2>/dev/null
} | sed "s|^$rt/libexec/darling||" | sort -u >"$list"
n=$(wc -l <"$list")
say "   $n libraries to try"

# RESUMABLE, because a whole class of libraries does not fail when dlopened blind: it ends
# the guest process tree. AppKit and ApplicationServices do it, so does OpenGL's libGL, and
# forking inside the probe does not help because the whole tree goes. Rather than maintain a
# skip list discovered one four-minute run at a time, the host restarts the sweep after the
# library that killed it and records that library as its own category. The container stays
# up between restarts, so each costs an exec.
# The HOST ELF LIBRARY PATH, which is what the 22 "killed the guest" libraries were missing.
# usr/lib/native/*.dylib are wrapgen stubs whose initializers dlopen the real libX11, libGL
# and friends through elfcalls; without their directories on the loader path that dlopen
# fails and the initializer ABORTS, taking the whole guest process tree with it. The daemon
# log says it plainly, "sigexc: handler (6) returning", signal 6 being SIGABRT.
#
# scripts/buck-audio-check.sh has always done this, which is why the CoreAudio wrappers
# answer there and died here. A display is NOT the cause and was tried first: with Xvfb up
# and DISPLAY passed in, the count did not move at all.
elf_dirs=$(sed -n 's/^elf_lib_dirs *= *//p' .buckconfig.local)
[ -n "$elf_dirs" ] || say "no darling.elf_lib_dirs in .buckconfig.local -- run scripts/buck-setup.nu"

say "== dlopening every one of them in the container, resuming past any that kill it =="
run_list="$list"
all_out=""
killers=""
for _round in $(seq 1 40); do
	part=$(
		DPREFIX="$prefix" \
			DARLING_NO_LAUNCHD=1 \
			DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
			DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
			LD_LIBRARY_PATH="$elf_dirs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			timeout 900 "$rt/bin/darling" shell /usr/bin/loadall_probe \
			"/tmp/$(basename "$run_list")" 2>&1
	) || true
	all_out="$all_out$part
"
	case "$part" in
	*LOADALL_DONE*) break ;;
	esac
	# The last one it announced is the one that took the process down.
	last=$(printf '%s
' "$part" | sed -n 's/^LOADALL try //p' | tail -1)
	[ -n "$last" ] || break
	killers="$killers$last
"
	# Resume after it. A fresh list under the guest-visible /tmp.
	run_list="$rt/libexec/darling/tmp/loadall-resume.txt"
	awk -v k="$last" 'seen {print} $0 == k {seen = 1}' "$list" >"$run_list.new"
	# Keep narrowing the SAME source list so the next round resumes from the new tail.
	mv "$run_list.new" "$run_list"
	cp "$run_list" "$list"
	[ -s "$list" ] || break
done
out="$all_out"


count() { printf '%s\n' "$out" | grep -c "^LOADALL $1 "; }
ok=$(count ok)
bad=$(count fail)
crash=$(count crash)
hang=$(count hang)
nkill=$(printf '%s' "$killers" | grep -c . || true)

say "   ok=$ok fail=$bad crash=$crash hang=$hang killed-the-guest=$nkill  (of $n)"
if [ "${nkill:-0}" != 0 ]; then
	say ""
	say "   these end the guest process tree when dlopened with no display, which is a"
	say "   fact about loading them blind rather than about the port; the GUI cone has its"
	say "   own check in scripts/buck-appkit-check.sh:"
	printf '%s' "$killers" | sed 's/^/     /'
fi
if [ "$bad" != 0 ] || [ "${crash:-0}" != 0 ] || [ "${hang:-0}" != 0 ]; then
	say ""
	say "   did not load ($bad), died in an initializer ($crash), or hung (${hang:-0}):"
	printf '%s\n' "$out" | grep -E "^LOADALL (fail|crash|hang) " |
		sed -E 's/^LOADALL (fail|crash|hang) /     \1 /' | head -24
fi

# A FLOOR set to what was MEASURED. 292 of 336 load: 227 dylibs plus 109 framework binaries,
# and the 44 that do not are exactly the git LFS pointers under usr/lib/swift, which
# scripts/buck-dylib-shape.nu counts independently. So EVERY real artifact in the prefix
# loads in the guest, and the only failures are files that are not libraries at all.
#
# It read 161 of 227 an hour ago, with 22 ending the guest process and 110 frameworks not
# swept because AppKit was thought to need a display. Both were the same missing
# LD_LIBRARY_PATH.
#
# Raise it when the count goes up, the way the scripting check's floor tracks its own
# measurement.
floor=${LOADALL_FLOOR:-292}
if [ "${ok:-0}" -ge "$floor" ]; then
	say ""
	say "PASS: $ok of $n installed libraries load in the guest (floor $floor)"
	exit 0
fi
say ""
say "FAIL: only $ok of $n load, floor is $floor"
exit 1
