#!/usr/bin/env nu
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
# Usage:  scripts/checks/buck-loadall-check.nu [<scratch dir>]
#
# Converted from bash (task #40) and verified against it on a real container: the enumerated
# list is compared line by line, and the counts, the verdict and the exit code all match.

def say [msg: string] { print -e $msg }

# --show-output prints one "<target> <path>" line per target, so pick by target name.
def artifact_for [rows: list, pat: string] {
    let hit = ($rows | where {|w| ($w | first) =~ $pat })
    if ($hit | is-empty) { "" } else { ($hit | first | get 1) }
}

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." ".." | path expand)

    let root = ($scratch | default $"/tmp/cider-loadall-(^id -u | str trim)")

    # SEATBELT, added 2026-08-12. A wrong root here SIGKILLs the user's ENTIRE login session,
    # because the cleanup loop below matches processes with `str starts-with $"($root)/"` and an
    # empty root makes that `starts-with "/"`, which is true for every process on the machine.
    # This is safe today ONLY because `scratch` is an optional POSITIONAL, so it is null when
    # absent and `| default` fills it. It becomes lethal the moment someone declares it as a flag
    # with an empty default, because `"" | default X` returns "" in nushell, not X. That is not
    # hypothetical: it is exactly what buck-darwin-rust-run.nu did when it was first written.
    # The check costs nothing and the failure costs the desktop, so it stays.
    if ($root | is-empty) or (not ($root | str starts-with "/tmp/")) {
        print -e $"  refusing to run: scratch root must be a path under /tmp, got [($root)]"
        exit 2
    }

    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    say "== building the prefix and the probe =="
    let b = (^buck2 build //buck/prefix:cider_prefix //tests/buck2/guest:loadall_probe
        --show-output | complete)
    let rows = ($b.stdout | lines | each {|l| $l | split row " " } | where {|w| ($w | length) >= 2 })
    let art = (artifact_for $rows 'cider_prefix')
    let bin = (artifact_for $rows 'loadall_probe')
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
    ^cp $bin $"($rt)/libexec/cider/usr/bin/loadall_probe"
    ^chmod +x $"($rt)/libexec/cider/usr/bin/loadall_probe"

    # The list, as the GUEST sees the paths: libexec/cider is the container root, so it comes
    # off the front. Regular files only -- the prefix is full of compatibility symlinks and
    # counting both would double every library that has one.
    # The display-dependent frameworks are NOT swept, and that is not a gap: dlopening AppKit
    # with no display takes the whole container down rather than just its child, so it ends the
    # sweep and leaves the other 335 unmeasured. It has its own check, scripts/checks/buck-appkit-check.nu,
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
    # the module works. They are already covered properly by scripts/checks/buck-scripting-check.nu,
    # which imports them THROUGH the interpreter: python 55 of 56, zsh 32 of 32, perl 14 of 14.
    # Adding them here would only make this number noisier and less true.

    say "== enumerating what the prefix ships =="
    let sdk = $"($rt)/libexec/cider"
    let list = $"($sdk)/tmp/loadall.txt"
    mkdir ($list | path dirname)
    # find, not glob: -mindepth/-maxdepth under Frameworks and "no dot in the name" are what
    # select a framework BINARY, and the generated list is compared against the bash one line
    # by line, so this stays the same tool doing the same thing.
    let dylibs = (^find $sdk -type f -name "*.dylib" | complete | get stdout | lines)
    let fwbins = (^find $"($sdk)/System/Library/Frameworks" -mindepth 3 -maxdepth 4 -type f
        ! -name "*.*" | complete | get stdout | lines)
    # Through the external sort -u, like the bash version: nushell sort is by codepoint and
    # sort is locale-collated, so the two orders differ on case and punctuation. The counts are
    # the same either way, but the transcript is compared line by line.
    let entries = (($dylibs ++ $fwbins
        | each {|p| $p | str replace $sdk "" }
        | where {|p| $p != "" }
        | str join "
") | ^sort -u | lines)
    ($entries | str join "\n") + "\n" | save -f $list
    let n = ($entries | length)
    say $"   ($n) libraries to try"

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
    # scripts/checks/buck-audio-check.nu has always done this, which is why the CoreAudio wrappers
    # answer there and died here. A display is NOT the cause and was tried first: with Xvfb up
    # and DISPLAY passed in, the count did not move at all.

    let elf_dirs = (
        open --raw .buckconfig.local | lines
        | where {|l| $l =~ '^elf_lib_dirs *= *' }
        | each {|l| $l | str replace --regex '^elf_lib_dirs *= *' '' }
        | get 0? | default ""
    )
    if ($elf_dirs | is-empty) {
        say "no cider.elf_lib_dirs in .buckconfig.local -- run scripts/buck-setup.nu"
    }
    let ld = (if (($env.LD_LIBRARY_PATH? | default "") | is-empty) { $elf_dirs } else { $"($elf_dirs):($env.LD_LIBRARY_PATH)" })

    say "== dlopening every one of them in the container, resuming past any that kill it =="
    mut remaining = $entries
    mut run_name = "loadall.txt"
    mut all_out = ""
    mut killers = []
    for _round in 1..40 {
        let log = (mktemp --tmpdir buck-loadall-check.XXXXXX)
        # An immutable copy, because nushell refuses to capture a mut in a closure.
        let rn = $run_name
        with-env {
            CIDERPREFIX: $prefix_dir
            DARLING_NO_LAUNCHD: "1"
            DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
            DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
            LD_LIBRARY_PATH: $ld
        } {
            do -i { ^timeout 900 $"($rt)/bin/cider" shell /usr/bin/loadall_probe $"/tmp/($rn)" out+err> $log }
        }
        let part = (open --raw $log)
        rm -f $log
        $all_out = $all_out + $part + "\n"
        if ($part | str contains "LOADALL_DONE") { break }
        # The last one it announced is the one that took the process down.
        let tried = ($part | lines | where {|l| $l starts-with "LOADALL try " }
            | each {|l| $l | str replace "LOADALL try " "" })
        if ($tried | is-empty) { break }
        let last = ($tried | last)
        $killers = ($killers | append $last)
        # Resume AFTER it, narrowing the same list so the next round starts from the new tail.
        let idx = ($remaining | enumerate | where {|it| $it.item == $last } | get 0?.index)
        if $idx == null { break }
        $remaining = ($remaining | skip ($idx + 1))
        if ($remaining | is-empty) { break }
        $run_name = "loadall-resume.txt"
        ($remaining | str join "\n") + "\n" | save -f $"($sdk)/tmp/($run_name)"
    }
    let out = $all_out

    let lines_out = ($out | lines)
    let ok = ($lines_out | where {|l| $l starts-with "LOADALL ok " } | length)
    let bad = ($lines_out | where {|l| $l starts-with "LOADALL fail " } | length)
    let crash = ($lines_out | where {|l| $l starts-with "LOADALL crash " } | length)
    let hang = ($lines_out | where {|l| $l starts-with "LOADALL hang " } | length)
    let nkill = ($killers | length)

    say $"   ok=($ok) fail=($bad) crash=($crash) hang=($hang) killed-the-guest=($nkill)  \(of ($n))"
    if $nkill != 0 {
        say ""
        say "   these end the guest process tree when dlopened with no display, which is a"
        say "   fact about loading them blind rather than about the port; the GUI cone has its"
        say "   own check in scripts/checks/buck-appkit-check.nu:"
        for k in $killers { say $"     ($k)" }
    }
    if ($bad != 0) or ($crash != 0) or ($hang != 0) {
        say ""
        say $"   did not load \(($bad)), died in an initializer \(($crash)), or hung \(($hang)):"
        $lines_out
        | where {|l| ($l starts-with "LOADALL fail ") or ($l starts-with "LOADALL crash ") or ($l starts-with "LOADALL hang ") }
        | first 24
        | each {|l| say ("     " + ($l | str replace "LOADALL " "")) }
    }

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

    let floor = (($env.LOADALL_FLOOR? | default "292") | into int)
    if $ok >= $floor {
        say ""
        say $"PASS: ($ok) of ($n) installed libraries load in the guest \(floor ($floor))"
        exit 0
    }
    say ""
    say $"FAIL: only ($ok) of ($n) load, floor is ($floor)"
    exit 1
}
