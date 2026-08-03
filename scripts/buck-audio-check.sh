#!/usr/bin/env bash
# Run the CoreAudio cone inside the buck2-built Darling.
#
# CoreAudio was the last cone of any size never to have executed, and it splits cleanly in
# two:
#
#   The PORT-SPECIFIC half is five ELF wrappers under /usr/lib/native. wrapgen generates a
#   Mach-O stub whose every export forwards into the host's ffmpeg or pulseaudio through
#   elfcalls. These are what buck2 built, and calling one proves the bridge carries a real
#   answer back rather than merely resolving.
#
#   The FRAMEWORK half is stubbed in Darling itself. Every entry point in
#   src/CoreAudio/AudioToolbox/AudioFile.cpp is literally `return unimpErr`, so
#   AudioFileOpenURL answers -4 and there is no decode path at that layer to exercise. That
#   is upstream's state, not the port's, and afinfo hides it: it prints "AudioFileOpen
#   failed" and swallows the status, which is why this probe prints the number.
#
# So a PASS here means the wrappers work. The stubbed AudioFile is reported and returns 3,
# the convention the other checks use for a known partial state -- and the day someone
# implements AudioFile, this check starts returning 0 and says so.
#
# Usage:  scripts/buck-audio-check.sh [<scratch dir>]
set -uo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

root=${1:-/tmp/darling-audio-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

say "== building the prefix and the probe =="
out=$(buck2 build //buck/prefix:darling_prefix //tests/buck2/guest:audio_probe \
	--show-output 2>/dev/null)
art=$(awk '/darling_prefix/ {print $2}' <<<"$out")
bin=$(awk '/audio_probe/ {print $2}' <<<"$out")
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
cp "$bin" "$rt/libexec/darling/usr/bin/audio_probe"
chmod +x "$rt/libexec/darling/usr/bin/audio_probe"

# A one-second 44.1kHz mono PCM WAV, written here rather than shipped or fetched, so the
# check stays self-contained the way sec_probe.c is.
mkdir -p "$rt/tmp"
python3 - "$rt/tmp/tone.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(44100)
    w.writeframes(b"".join(
        struct.pack("<h", int(20000 * math.sin(2 * math.pi * 440 * i / 44100)))
        for i in range(44100)))
PY

# The host ELF libraries have to be reachable by the LOADER: the wrappers dlopen them
# through elfcalls, and a stub whose .so cannot be found is the whole failure mode here.
elf_dirs=$(sed -n 's/^elf_lib_dirs *= *//p' .buckconfig.local)
[ -n "$elf_dirs" ] || {
	say "no darling.elf_lib_dirs in .buckconfig.local -- run scripts/buck-setup.nu"
	exit 2
}

say "== running the probe inside the container =="
out=$(
	LD_LIBRARY_PATH="$elf_dirs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 200 "$rt/bin/darling" shell /bin/bash -c \
		'cp /Volumes/SystemRoot'"$rt"'/tmp/tone.wav /tmp/ 2>/dev/null; /usr/bin/audio_probe /tmp/tone.wav' 2>&1
) || true

printf '%s\n' "$out" | grep "AUDIO_PROBE" || true

fail=0
for w in avutil avcodec avformat swresample; do
	case "$out" in
	*"lib$w.dylib ${w}_version="*) say "ok   lib$w forwards to the host through elfcalls" ;;
	*) say "FAIL lib$w did not answer"; fail=1 ;;
	esac
done
case "$out" in
*"pa_get_library_version="*[0-9]*) say "ok   libpulse forwards to the host through elfcalls" ;;
*) say "FAIL libpulse did not answer"; fail=1 ;;
esac
case "$out" in
*"AUDIO_PROBE_DONE wrappers_bad=0"*) ;;
*) fail=1 ;;
esac

[ "$fail" != 0 ] && {
	say "FAIL: an ELF wrapper did not work"
	exit 1
}

case "$out" in
*"audiofile_stubbed=0"*)
	say "PASS: the wrappers work AND AudioFile is no longer stubbed"
	exit 0
	;;
*)
	say "KNOWN: the five ELF wrappers work; AudioFile still answers unimpErr, which is"
	say "upstream's state and not the port's. See the header of this script."
	exit 3
	;;
esac
