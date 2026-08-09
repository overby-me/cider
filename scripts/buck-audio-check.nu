#!/usr/bin/env nu
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
# Usage:  scripts/buck-audio-check.nu [<scratch dir>]
#
# Converted from bash (task #40) and verified by running BOTH versions against a real container:
# same per-wrapper lines, same verdict and same exit code.

def say [msg: string] { print -e $msg }

# --show-output prints one "<target> <path>" line per target, so pick by target name.
def artifact_for [rows: list, pat: string] {
    let hit = ($rows | where {|w| ($w | first) =~ $pat })
    if ($hit | is-empty) { "" } else { ($hit | first | get 1) }
}

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let root = ($scratch | default $"/tmp/cider-audio-(^id -u | str trim)")
    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    say "== building the prefix and the probe =="
    let b = (^buck2 build //buck/prefix:cider_prefix //tests/buck2/guest:audio_probe
        --show-output | complete)
    let rows = ($b.stdout | lines | each {|l| $l | split row " " } | where {|w| ($w | length) >= 2 })
    let art = (artifact_for $rows 'cider_prefix')
    let bin = (artifact_for $rows 'audio_probe')
    for f in [$art $bin] {
        if ($f | is-empty) or (not ($f | path exists)) {
            say $"missing build output: ($f)"
            exit 1
        }
    }

    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    do -i { ^chmod -R u+w $rt }
    # GNU rm: the overlay workdir holds a `work` directory at mode 000.
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    mkdir $rt $prefix_dir
    # `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt
    ^cp $bin $"($rt)/libexec/cider/usr/bin/audio_probe"
    ^chmod +x $"($rt)/libexec/cider/usr/bin/audio_probe"

    # A one-second 44.1kHz mono PCM WAV, written here rather than shipped or fetched, so the
    # check stays self-contained the way sec_probe.c is. Still python, because a WAV header and
    # 44100 samples is what the wave module is for.
    mkdir $"($rt)/tmp"
    let wavgen = 'import math, struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(44100)
    w.writeframes(b"".join(
        struct.pack("<h", int(20000 * math.sin(2 * math.pi * 440 * i / 44100)))
        for i in range(44100)))'
    $wavgen | ^python3 - $"($rt)/tmp/tone.wav"

    # The host ELF libraries have to be reachable by the LOADER: the wrappers dlopen them
    # through elfcalls, and a stub whose .so cannot be found is the whole failure mode here.
    let elf_dirs = (
        open --raw .buckconfig.local | lines
        | where {|l| $l =~ '^elf_lib_dirs *= *' }
        | each {|l| $l | str replace --regex '^elf_lib_dirs *= *' '' }
        | get 0? | default ""
    )
    if ($elf_dirs | is-empty) {
        say "no cider.elf_lib_dirs in .buckconfig.local -- run scripts/buck-setup.nu"
        exit 2
    }

    say "== running the probe inside the container =="
    let ld = (if (($env.LD_LIBRARY_PATH? | default "") | is-empty) { $elf_dirs } else { $"($elf_dirs):($env.LD_LIBRARY_PATH)" })
    let guest_cmd = $"cp /Volumes/SystemRoot($rt)/tmp/tone.wav /tmp/ 2>/dev/null; /usr/bin/audio_probe /tmp/tone.wav"
    let log = (mktemp --tmpdir buck-audio-check.XXXXXX)
    with-env {
        LD_LIBRARY_PATH: $ld
        DPREFIX: $prefix_dir
        DARLING_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
    } {
        do -i { ^timeout 200 $"($rt)/bin/cider" shell /bin/bash -c $guest_cmd out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    $out | lines | where {|l| $l =~ "AUDIO_PROBE" } | each {|l| print $l }

    mut fail = false
    for w in [avutil avcodec avformat swresample] {
        if ($out | str contains $"lib($w).dylib ($w)_version=") {
            say $"ok   lib($w) forwards to the host through elfcalls"
        } else {
            say $"FAIL lib($w) did not answer"
            $fail = true
        }
    }
    if $out =~ 'pa_get_library_version=[^\n]*[0-9]' {
        say "ok   libpulse forwards to the host through elfcalls"
    } else {
        say "FAIL libpulse did not answer"
        $fail = true
    }
    if not ($out | str contains "AUDIO_PROBE_DONE wrappers_bad=0") { $fail = true }

    if $fail {
        say "FAIL: an ELF wrapper did not work"
        exit 1
    }

    if ($out | str contains "audiofile_stubbed=0") {
        say "PASS: the wrappers work AND AudioFile is no longer stubbed"
        exit 0
    }
    say "KNOWN: the five ELF wrappers work; AudioFile still answers unimpErr, which is"
    say "upstream's state and not the port's. See the header of this script."
    exit 3
}
