#!/usr/bin/env nu
# Run an AppKit program inside the buck2-built Darling, against a real X server.
#
# The GUI cone -- AppKit, cocotron, CoreGraphics, Onyx2D and the sixteen linux/native stubs
# that forward to the host's X11, cairo and OpenGL -- is the largest part of the port that
# links cleanly, exports the right symbols and has never executed an instruction. This runs
# tests/buck2/gui/appkit_probe.m, which brings NSApplication up, opens an NSWindow and
# pumps one event, printing at each step so a first run says how far it got rather than
# just pass or fail.
#
# CURRENT RESULT: PASS, with the right files in place. It went PARTIAL for a while and the
# reason is worth keeping: the reference installs the dev STUB frameworks to the same
# destinations as the real ones (src/frameworks/dev-stubs/AppKit/AppKit and cocotron's
# AppKit both land in AppKit.framework/Versions/C), so once install entries resolved by
# path instead of by artifact name, the stub won and the prefix shipped an EMPTY AppKit.
# NSApplication has nothing to come up in when its framework is a stub.
# gen-install-from-manifests.py now reports every such collision and keeps the real
# implementation.
#
# It supplies its OWN Xvfb rather than borrowing $DISPLAY: a probe that draws on the
# developer's desktop is a probe nobody runs twice, and a headless server makes the check
# usable from CI. Xephyr is fine too if you want to watch it.
#
# Usage:  scripts/buck-appkit-check.nu [<scratch dir>]
#
# Converted from bash (task #40) and verified by running BOTH versions against a real container
# and a real Xvfb, comparing the graded verdict, the exit code and the probe transcript.

def say [msg: string] { print -e $msg }

# --show-output prints one "<target> <path>" line per target, so pick by target name.
def artifact_for [rows: list, pat: string] {
    let hit = ($rows | where {|w| ($w | first) =~ $pat })
    if ($hit | is-empty) { "" } else { ($hit | first | get 1) }
}

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let root = ($scratch | default $"/tmp/cider-appkit-(^id -u | str trim)")
    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }
    if (which Xvfb | is-empty) {
        say "missing Xvfb -- the GUI cone needs an X server to talk to"
        exit 2
    }

    say "== building the prefix and the probe =="
    let b = (^buck2 build //buck/prefix:cider_prefix //tests/buck2/gui:appkit_probe
        --show-output | complete)
    let rows = ($b.stdout | lines | each {|l| $l | split row " " } | where {|w| ($w | length) >= 2 })
    let art = (artifact_for $rows 'cider_prefix')
    let bin = (artifact_for $rows 'appkit_probe')
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
    ^cp $bin $"($rt)/libexec/cider/usr/bin/appkit_probe"
    ^chmod +x $"($rt)/libexec/cider/usr/bin/appkit_probe"

    # A display number nobody else is on. :0 and the developer's own session are left alone.
    # random int rather than bash RANDOM, and the range is the same.
    let disp = $":(90 + (random int 0..7))"
    say $"== starting Xvfb on ($disp) =="
    # job spawn, because nushell has no & : the job is killed at the end rather than by a trap.
    # One line: a redirection cannot start a continuation line, unlike a flag. On its own line
    # nushell reports "redirecting nothing".
    let xvfb = (job spawn { do -i { ^Xvfb $disp -screen 0 1024x768x24 -nolisten tcp out+err> /dev/null } })
    let sock = $"/tmp/.X11-unix/X($disp | str substring 1..)"
    # Xvfb takes a moment to create the socket, and connecting before it exists looks exactly
    # like "cannot open display", which is the failure this probe is trying to distinguish.
    mut up = false
    for _ in 1..50 {
        if ($sock | path exists) { $up = true; break }
        sleep 100ms
    }
    if not $up {
        say $"Xvfb did not come up on ($disp)"
        do -i { job kill $xvfb }
        exit 1
    }

    # The host ELF libraries have to be reachable by the LOADER, not just by wrapgen. Without
    # this the probe does not merely fail to draw: loading AppKit kills the process before main,
    # with no output at all, because the sixteen linux/native stubs forward into libX11, cairo and
    # freetype through elfcalls and a stub whose .so cannot be dlopened takes the process with
    # it. .buckconfig.local already knows the directories -- cider.elf_lib_dirs is how wrapgen
    # found the same libraries at BUILD time -- so reuse them rather than inventing a second
    # list.
    let elf_dirs = (
        open --raw .buckconfig.local | lines
        | where {|l| $l =~ '^elf_lib_dirs *= *' }
        | each {|l| $l | str replace --regex '^elf_lib_dirs *= *' '' }
        | get 0? | default ""
    )
    if ($elf_dirs | is-empty) {
        say "no cider.elf_lib_dirs in .buckconfig.local -- run scripts/buck-setup.nu"
        do -i { job kill $xvfb }
        exit 2
    }

    say "== running the probe inside the container =="
    let ld = (if (($env.LD_LIBRARY_PATH? | default "") | is-empty) { $elf_dirs } else { $"($elf_dirs):($env.LD_LIBRARY_PATH)" })
    let log = (mktemp --tmpdir buck-appkit-check.XXXXXX)
    with-env {
        LD_LIBRARY_PATH: $ld
        DPREFIX: $prefix_dir
        DARLING_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
        DISPLAY: $disp
    } {
        do -i { ^timeout 180 $"($rt)/bin/cider" shell /usr/bin/appkit_probe out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    do -i { job kill $xvfb }
    print $out

    # Graded, because the interesting outcomes are the partial ones: reaching NSApplication
    # proves the cone loads and the X connection opened, and reaching the window proves
    # cocotron's backend built a real drawable.
    if ($out | str contains "APPKIT_PROBE_OK") {
        say "PASS: AppKit brought up an app, opened a window and pumped the run loop"
        exit 0
    } else if ($out | str contains "APPKIT_PROBE ordered-front") {
        say "PARTIAL: the window was created and ordered front, but the event pump did not finish"
        exit 3
    } else if ($out | str contains "APPKIT_PROBE window=yes") {
        say "PARTIAL: NSWindow was created but could not be ordered front"
        exit 3
    } else if ($out | str contains "APPKIT_PROBE app=yes") {
        say "PARTIAL: NSApplication came up but no window could be created"
        exit 3
    } else if ($out | str contains "APPKIT_PROBE start") {
        say "PARTIAL: the binary ran but NSApplication did not come up"
        exit 3
    } else {
        say "FAIL: the AppKit probe did not run at all"
        exit 1
    }
}
