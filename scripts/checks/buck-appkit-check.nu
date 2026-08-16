#!/usr/bin/env nu
# Run an AppKit program inside the buck2-built Cider, against a real Wayland compositor.
#
# The GUI cone -- AppKit, cocotron, CoreGraphics, Onyx2D and the sixteen src/linux/native stubs
# that forward to the host's Wayland, cairo and OpenGL -- is the largest part of the port that
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
# WAYLAND, NOT X11, since 2026-08-13. This gate ran against Xvfb through the cocotron X11
# backend, which is being removed; it now supplies its own headless weston and sets
# CIDER_WAYLAND_BACKEND, so what it exercises is NSDisplayWayland and CGWindowWayland.
#
# --renderer=pixman IS NOT OPTIONAL. weston headless defaults to a no-op renderer that composites
# nothing, and against it a perfectly correct client reports pixels that never arrive. That cost
# an afternoon once and it is the reason this flag is written out rather than left to a default.
#
# It supplies its OWN compositor rather than borrowing $WAYLAND_DISPLAY: a probe that draws on the
# developer's desktop is a probe nobody runs twice, and a headless compositor makes the check
# usable from CI.
#
# Usage:  scripts/checks/buck-appkit-check.nu [<scratch dir>]
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
    cd ($env.FILE_PWD | path join ".." ".." | path expand)

    let root = ($scratch | default $"/tmp/cider-appkit-(^id -u | str trim)")

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
    if (which weston | is-empty) {
        say "missing weston -- the GUI cone needs a compositor to talk to"
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

    # A SHALLOW SOCKET PATH, and it is not a preference: a unix socket path caps near 108 bytes,
    # and the first compositor prototype put its runtime dir under the session scratchpad and died
    # with "failed to add socket: File name too long".
    let xdg = $"($root)/wl"
    let sock = "cider-wl"
    ^rm -rf $xdg
    mkdir $xdg
    ^chmod 700 $xdg

    say "== starting weston, headless =="
    # job spawn, because nushell has no & : the job is killed at the end rather than by a trap.
    # One line: a redirection cannot start a continuation line, unlike a flag. On its own line
    # nushell reports "redirecting nothing".
    let weston = (job spawn {
        with-env {XDG_RUNTIME_DIR: $xdg} {
            do -i { ^weston --backend=headless --renderer=pixman --socket=cider-wl --width=1280 --height=800 out+err> $"($root)/weston.log" }
        }
    })
    # The socket appears a moment after the process does, and connecting before it exists looks
    # exactly like "no compositor", which is the failure this probe is trying to distinguish.
    mut waited = 0
    while (not ($"($xdg)/($sock)" | path exists)) and $waited < 50 {
        sleep 100ms
        $waited = $waited + 1
    }
    if not ($"($xdg)/($sock)" | path exists) {
        say "weston never created its socket"
        do -i { job kill $weston }
        exit 1
    }

    # The host ELF libraries have to be reachable by the LOADER, not just by wrapgen. Without
    # this the probe does not merely fail to draw: loading AppKit kills the process before main,
    # with no output at all, because the sixteen src/linux/native stubs forward into libX11, cairo and
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
        do -i { job kill $weston }
        exit 2
    }

    say "== running the probe inside the container =="
    let ld = (if (($env.LD_LIBRARY_PATH? | default "") | is-empty) { $elf_dirs } else { $"($elf_dirs):($env.LD_LIBRARY_PATH)" })
    let log = (mktemp --tmpdir buck-appkit-check.XXXXXX)
    with-env {
        LD_LIBRARY_PATH: $ld
        CIDERPREFIX: $prefix_dir
        DARLING_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
        XDG_RUNTIME_DIR: $xdg
        WAYLAND_DISPLAY: $sock
        # WITHOUT THIS THE BACKEND DECLINES. NSDisplayWayland -init returns nil unless it is set,
        # so that a prefix carrying the bundle behaves exactly as before until asked.
        CIDER_WAYLAND_BACKEND: "1"
    } {
        do -i { ^timeout 180 $"($rt)/bin/cider" shell /usr/bin/appkit_probe out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    do -i { job kill $weston }
    print $out

    # A SIZE THE FALLBACK CANNOT PRODUCE. The backend falls back to 1024x768 when wl_output says
    # nothing, so a compositor at 1024x768 cannot tell the two apart: the right answer and the
    # guess are the same number. weston is started at 1280x800 for exactly this reason, and the
    # assertion is on the number rather than on the source= label the backend prints about itself.
    #
    # THE WAYLAND MARKERS ARE CHECKED SEPARATELY from the AppKit ones, because the probe can
    # succeed against a backend that is not this one: X11 printed APPKIT_PROBE_OK too. These say
    # the window was a real xdg_toplevel with a context over shm pages, which is what distinguishes
    # a pass from a pass by the wrong route.
    mut wl_gaps = 0
    for m in [
        ["cider-wayland-appkit init=ok" "the Wayland display backend was selected and connected"]
        ["cider-wayland-window create=ok" "an xdg_toplevel was created and configured for the NSWindow"]
        ["cider-wayland-window context=ok" "an O2Context was built over the shm mapping"]
        ["cider-wayland-window mapped=yes" "the buffer was attached and committed"]
        # THE ONE THAT SAYS DRAWING WORKS. Everything above is satisfied by a window that renders
        # nothing: a context that constructs is not a context that renders, and both produce a
        # window. This counts pixels that differ from the fill the backend wrote, in the same
        # mapping the compositor reads.
        ["cider-wayland-window pixels=drawn" "AppKit drawing reached the pages the compositor maps"]
        ["screens=1 frame=1280x800 source=wl_output" "the screen size came from wl_output, not the built-in fallback"]
    ] {
        if ($out | str contains ($m | get 0)) {
            say $"  ok: ($m | get 1)"
        } else {
            say $"  MISSING: ($m | get 1)"
            $wl_gaps = $wl_gaps + 1
        }
    }

    # TEXT, asserted by counting colours rather than by trusting "text=drawn". A string that
    # raises no exception and rasterises nothing prints exactly the same line. A flat fill over a
    # cleared window has TWO distinct values in it; antialiased glyphs have dozens, so anything
    # above two means something was rendered that a rectangle cannot explain.
    let colours = (
        $out | parse --regex 'colours=(?<n>\d+)' | get n? | get 0? | default "0" | into int
    )
    if $colours > 2 {
        say $"  ok: ($colours) distinct colours in the window, so glyphs rasterised"
    } else {
        say $"  MISSING: only ($colours) distinct colours, so nothing beyond flat fills was drawn"
        $wl_gaps = $wl_gaps + 1
    }

    # Graded, because the interesting outcomes are the partial ones: reaching NSApplication
    # proves the cone loads and the compositor connection opened, and reaching the window proves
    # the backend built a real surface.
    if ($out | str contains "APPKIT_PROBE_OK") and $wl_gaps == 0 {
        say "PASS: AppKit brought up an app, opened a Wayland window, drew into it and pumped the run loop"
        exit 0
    } else if ($out | str contains "APPKIT_PROBE_OK") {
        say $"PARTIAL: the probe passed but ($wl_gaps) Wayland marker\(s) were missing, so it did not go through this backend"
        exit 3
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
