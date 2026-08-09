#!/usr/bin/env nu
# Run libdispatch inside the buck2-built Darling.
#
# usr/lib/system/libdispatch.dylib ships in the prefix and nothing had ever executed a line
# of it. It deserves its own check rather than being taken on trust, because it is the one
# system library whose whole job is making threads and handing work between them, and that is
# the machinery this port has had the most trouble with: the guest runs on the daemon's
# microthreads, multithreading needed duct-tape's two-phase init before it worked at all, and
# a null pthread_list_mlock once surfaced as a silent SIGSEGV that read like a scheduler bug.
#
# tests/buck2/guest/dispatch_probe.c walks from the step that needs no thread to the one that
# needs several, so a failure names the layer:
#
#   dispatch_once     the atomic and the block, no queue
#   dispatch_sync     a queue, still on the calling thread
#   dispatch_async    a real handoff, joined with a semaphore
#   dispatch_apply    concurrent iterations on the global queue
#
# Converted from bash (task #40) and checked by running both against the same container and
# diffing, not by reading it.
#
# Usage:  scripts/buck-dispatch-check.nu [<scratch dir>]

def say [msg: string] { print -e $msg }

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let root = ($scratch | default $"/tmp/cider-dispatch-(^id -u | str trim)")
    let rt = ($root | path join "rt")
    let prefix = ($root | path join "prefix")

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    say "== building the prefix and the probe =="
    let built = (^buck2 build //buck/prefix:cider_prefix //tests/buck2/guest:dispatch_probe
        --show-output | complete)
    let lines = ($built.stdout | lines)
    let art = ($lines | where {|l| $l =~ "cider_prefix" } | first | split row " " | last)
    let bin = ($lines | where {|l| $l =~ "dispatch_probe" } | first | split row " " | last)
    for f in [$art $bin] {
        if not ($f | path exists) {
            say $"missing build output: ($f)"
            exit 1
        }
    }

    # Anything still running under this root holds the old prefix mounted, so it goes FIRST.
    # By PID from a list already read, and never a pattern that could match this process.
    for p in (glob "/proc/[0-9]*") {
        let exe = (do -i { $"($p)/exe" | path expand })
        if ($exe != null) and ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    # err> /dev/null as well as do -i: on a fresh scratch dir rt does not exist yet, and
    # do -i swallows the FAILURE while still letting chmod print to stderr. The bash version
    # had 2>/dev/null, and without this the two differ by exactly that line.
    do -i { ^chmod -R u+w $rt err> /dev/null }
    do -i { rm -rf $rt }
    do -i { rm -rf $prefix }
    do -i { rm -rf $"($prefix).workdir" }
    mkdir $rt
    mkdir $prefix
    # cp -a, never cp -aL: the prefix installs Volumes/DarlingEmulatedDrive -> /.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt
    ^cp $bin $"($rt)/libexec/cider/usr/bin/dispatch_probe"
    ^chmod +x $"($rt)/libexec/cider/usr/bin/dispatch_probe"

    say "== running the probe inside the container =="
    let out = (
        with-env {
            DPREFIX: $prefix
            DARLING_NO_LAUNCHD: "1"
            DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
            DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
        } {
            ^timeout 200 $"($rt)/bin/cider" shell /usr/bin/dispatch_probe | complete
        }
    )
    let text = $"($out.stdout)($out.stderr)"

    $text | lines | where {|l| $l =~ "DISPATCH_PROBE" } | each {|l| say $l }

    # Asserted step by step, so a regression says which layer stopped working rather than
    # that dispatch broke.
    let checks = [
        ["DISPATCH_PROBE once ran=1", "dispatch_once runs the block exactly once"]
        ["DISPATCH_PROBE queue=created", "dispatch_queue_create returns a queue"]
        ["DISPATCH_PROBE sync val=42", "dispatch_sync runs the block on the calling thread"]
        ["DISPATCH_PROBE async wait=0 ran=1", "dispatch_async hands off to a real thread"]
        ["DISPATCH_PROBE apply count=64", "dispatch_apply runs 64 concurrent iterations"]
        ["DISPATCH_PROBE_DONE failures=0", "the probe ran to completion"]
    ]
    mut failed = false
    for c in $checks {
        if ($text | str contains ($c | first)) {
            say $"ok   ($c | last)"
        } else {
            say $"FAIL ($c | last)"
            $failed = true
        }
    }

    if not $failed {
        say "PASS: libdispatch schedules work in the guest"
        exit 0
    }
    say "FAIL: see above"
    exit 1
}
