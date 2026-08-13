#!/usr/bin/env nu
# DOES A GUEST BINARY REACH A WAYLAND COMPOSITOR? (#112, the gate the X11 backend's replacement needs)
#
# This is the Wayland counterpart of buck-appkit-check.nu, and it exists BEFORE the backend on
# purpose: the plan in docs/wayland-port.md puts the compositor first, because writing 7,000 lines
# of CoreGraphics backend with no way to run them is how this repo has been burned.
#
# It supplies its OWN weston, headless, exactly as the X11 check supplies its own Xvfb rather than
# borrowing the developer's session: a probe that draws on the desktop is not usable from CI, and a
# probe that silently uses a session that happens to be there proves nothing on a machine without one.
#
# WHAT IS ASSERTED is the marker the probe prints, not the exit code. A guest process can die in
# dyld and still leave a 0 behind, which is why every runtime check here reads output.
#
# THE CONTROL MATTERS AS MUCH AS THE SUBJECT. wayland-info runs against the same socket from the
# HOST. If the probe fails and the control fails too, the compositor is the problem and the guest
# side is not implicated; if the control passes and the probe does not, the failure is ours. That
# ambiguity has cost this repo hours before.
#
# Usage:
#   scripts/checks/buck-wayland-check.nu [scratch-root]

def say [msg: string] { print -e $msg }
def ok [msg: string] { print -e $"  ok   ($msg)" }
def bad [msg: string] { print -e $"  FAIL ($msg)" }

def artifact_for [rows: list, needle: string] {
    let hit = ($rows | where {|w| ($w | first) =~ $needle } | first)
    if ($hit | is-empty) { "" } else { $hit | last }
}

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." ".." | path expand)

    # SHALLOW ROOT, and it is not a preference: the daemon socket is <prefix>/.ciderd.sock and the
    # Wayland socket is <root>/wl/<name>, and a unix socket path caps near 108 bytes. The first
    # attempt at the compositor prototype put it under the session scratchpad and weston died with
    # "failed to add socket: File name too long".
    let root = ($scratch | default $"/tmp/cider-wayland-(^id -u | str trim)")

    # SEATBELT, copied from buck-appkit-check.nu and for the same reason: the cleanup loop below
    # matches processes by `str starts-with $"($root)/"`, and an empty root makes that true for
    # every process on the machine, which SIGKILLs the login session.
    if ($root | is-empty) or (not ($root | str starts-with "/tmp/")) {
        print -e $"  refusing to run: scratch root must be a path under /tmp, got [($root)]"
        exit 2
    }

    let rt = $"($root)/rt"
    let xdg = $"($root)/wl"
    let sock = "cider-wl"

    for t in ["buck2" "weston" "wayland-info"] {
        if (which $t | is-empty) {
            say $"missing ($t) -- run inside nix develop, and see docs/wayland-port.md"
            exit 2
        }
    }

    say "== building the prefix and the wayland probe =="
    let b = (^buck2 build //buck/prefix:cider_prefix //src/darwin/wayland:cider-wayland-probe
        --show-output | complete)
    let rows = ($b.stdout | lines | each {|l| $l | split row " " } | where {|w| ($w | length) >= 2 })
    let art = (artifact_for $rows 'cider_prefix')
    let bin = (artifact_for $rows 'cider-wayland-probe')
    for f in [$art $bin] {
        if ($f | is-empty) or (not ($f | path exists)) {
            say $"missing build output: ($f)"
            exit 1
        }
    }

    # LEFTOVERS BY /proc/N/exe, never by name: a name pattern matches other checks and this script
    # itself, which is a mistake this repo has made repeatedly.
    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    do -i { ^chmod -R u+w $rt }
    ^rm -rf $rt $xdg
    mkdir $rt $xdg
    ^chmod 700 $xdg
    # `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt
    ^cp $bin $"($rt)/libexec/cider/usr/bin/cider-wayland-probe"
    ^chmod +x $"($rt)/libexec/cider/usr/bin/cider-wayland-probe"

    say "== starting weston, headless =="
    let weston = (job spawn {
        with-env {XDG_RUNTIME_DIR: $xdg} {
            do -i { ^weston --backend=headless --renderer=pixman --socket=cider-wl --width=1024 --height=768 out+err> $"($root)/weston.log" }
        }
    })
    # The socket appears a moment after the process does, and connecting before it exists looks
    # exactly like a backend failure.
    mut waited = 0
    while (not ($"($xdg)/($sock)" | path exists)) and $waited < 50 {
        sleep 200ms
        $waited = $waited + 1
    }
    if not ($"($xdg)/($sock)" | path exists) {
        bad "weston never created its socket"
        do -i { job kill $weston }
        exit 1
    }
    ok $"weston is up on ($xdg)/($sock)"

    # THE CONTROL, from the host, before the guest is asked anything.
    let control = (with-env {XDG_RUNTIME_DIR: $xdg, WAYLAND_DISPLAY: $sock} {
        do -i { ^timeout 30 wayland-info } | complete
    })
    let control_globals = ($control.stdout | lines | where {|l| $l =~ 'interface:' } | length)
    if $control_globals < 5 {
        bad $"the CONTROL failed: wayland-info saw ($control_globals) globals, so the compositor is the problem and not the guest side"
        do -i { job kill $weston }
        exit 1
    }
    ok $"control: wayland-info sees ($control_globals) globals on the same socket"

    # THE HOST LIBRARY PATH, without which the forwarding stub cannot dlopen the real
    # libwayland-client.so and every call returns nothing. buck-appkit-check.nu does the same for
    # the X libraries; leaving it out was why the first run of this check failed with the control
    # green and the guest silent.
    let elf_dirs = (
        open --raw .buckconfig.local | lines
        | where {|l| $l =~ '^elf_lib_dirs *= *' }
        | each {|l| $l | str replace --regex '^elf_lib_dirs *= *' '' }
        | get 0? | default ""
    )
    if ($elf_dirs | is-empty) {
        bad "no elf_lib_dirs in .buckconfig.local -- run scripts/buck-setup.nu"
        do -i { job kill $weston }
        exit 2
    }
    let ld = (if (($env.LD_LIBRARY_PATH? | default "") | is-empty) { $elf_dirs } else { $"($elf_dirs):($env.LD_LIBRARY_PATH)" })

    # A LEFTOVER DAEMON CARRIES A STALE ENVIRONMENT, and that is not a detail: the host side of
    # the process reads ITS environment, not the guest's, so a ciderd started before
    # WAYLAND_DISPLAY existed makes wl_display_connect fail with nothing to see. Kill only real
    # ciderd processes for THIS prefix, matched on /proc/N/exe rather than on a name.
    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let pid = ($p | path basename)
        let comm = (do -i { open --raw $"($p)/comm" | str trim } | default "")
        if $comm == "ciderd" {
            let args = (do -i { open --raw $"($p)/cmdline" } | default "" | str replace --all (char nul) " ")
            if ($args | str contains $root) { do -i { ^kill $pid } }
        }
    }

    say "== running the probe INSIDE cider =="
    let log = $"($root)/probe.log"
    with-env {
        LD_LIBRARY_PATH: $ld
        CIDERPREFIX: $"($root)/prefix"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
        XDG_RUNTIME_DIR: $xdg
        WAYLAND_DISPLAY: $sock
    } {
        do -i { ^timeout 180 $"($rt)/bin/cider" shell /usr/bin/cider-wayland-probe out+err> $log }
    }

    let out = (if ($log | path exists) { open --raw $log } else { "" })
    do -i { job kill $weston }

    mut failed = 0
    if ($out | str contains "cider-wayland-probe connect=ok") {
        ok "the guest connected to the compositor"
    } else {
        bad "the guest did not connect"
        $failed = $failed + 1
    }
    if ($out | str contains "can_open_a_window=true") {
        ok "wl_compositor, wl_shm and xdg_wm_base are all bound"
    } else {
        bad "the globals a window needs were not all found"
        $failed = $failed + 1
    }
    # THE HANDSHAKE, not just the objects. A compositor CONFIGURES a surface and the client acks
    # the serial; a client that never gets there is never mapped, so this is the assertion that
    # says a window really exists rather than that some ids were allocated.
    if ($out | str contains "window=configured") {
        ok "the compositor configured an xdg_toplevel and the ack completed"
    } else {
        bad "no xdg_surface configure arrived, so the surface was never mapped"
        $failed = $failed + 1
    }
    # PIXELS, asserted on the FRAME CALLBACK rather than the buffer release. A compositor may
    # legitimately hold a buffer after drawing with it, so demanding a release asks for more than
    # the protocol promises; a frame callback is the compositor saying it drew.
    if ($out | str contains "pixels=presented") {
        ok "a wl_shm buffer was attached and the compositor presented it"
    } else {
        bad "the surface was never presented, so no pixels reached the compositor"
        $failed = $failed + 1
    }

    print -e ""
    print -e ($out | lines | where {|l| $l =~ 'cider-wayland-probe' } | str join "\n")
    if $failed > 0 {
        say $"\nFAIL: ($failed) assertion\(s). The control passed, so this is the guest side."
        exit 1
    }
    say "\nPASS: a Mach-O guest binary reached a Wayland compositor"
}
