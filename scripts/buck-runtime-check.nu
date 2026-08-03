#!/usr/bin/env nu
# Run every runtime check, in the one way that actually works.
#
# There are ten of these now and buck-test.sh runs none of them: it is almost entirely
# static, asking whether an artifact links and exports the right symbols. The checks here
# are the ones that RUN things, and they are what found an empty AppKit, a null
# ec_thread_get_stack, a missing 0x prefix and a python module installed under a name
# CPython cannot import.
#
# THEY CANNOT BE CHAINED NAIVELY, which is the knowledge this script exists to hold. Each
# check kills stale processes under its OWN scratch root at START and not at exit, so
# running three back to back leaves three darlingserver daemons alive at once and the
# earlier ones fail spuriously. Killing every stray daemon BETWEEN checks is what makes
# them agree with their own results run individually.
#
#   pgrep -x, never -f: an -f pattern matches the command line of the shell running it,
#   which is how a cleanup loop ends up killing its own invocation.
#
# Exit codes from the checks: 0 is a pass, 3 is a KNOWN partial state that the check's own
# header explains, anything else is a failure. Only the last kind fails this script.
#
# Converted from bash (task #40). Verified without containers, by driving it over STUB
# checks that exit 0, 3 and 1 and over a name that does not exist, which exercises the parts
# that are actually this script: .nu-before-.sh resolution, the rc classification, the
# summary table and the final verdict. The containers belong to the checks it calls.
#
# Usage:
#   scripts/buck-runtime-check.nu              # the nine fast checks
#   scripts/buck-runtime-check.nu --with-nix   # plus buck-nix-bash-check, which is slow
#   scripts/buck-runtime-check.nu <name>...    # just these, by bare name

def say [msg: string] { print -e $msg }

# Ordered cheapest-first, so a broken container is reported in a minute rather than after
# the GUI and interpreter cones have been built.
const CHECKS = [
    buck-bash-check
    buck-launchd-check
    buck-smoke-check
    buck-security-check
    buck-jsc-check
    buck-appkit-check
    buck-scripting-check
    buck-audio-check
    # libdispatch, which is cheap but goes last because it is the newest: it makes threads
    # and hands work between them, which is the machinery this port has broken most often.
    buck-dispatch-check
]
# Builds bash with Nix INSIDE Darling. It is the campaign's keystone milestone and it takes
# far longer than everything else here put together, so it is opt-in.
const SLOW = [buck-nix-bash-check]

def kill_daemons [] {
    # By PID from a list already read, and pgrep -x so the pattern cannot match this
    # process. -f would match the command line of the shell running the loop.
    for pid in (do -i { ^pgrep -x darlingserver | lines } | default []) {
        do -i { ^kill -9 $pid }
    }
    # The daemon takes a moment to release the prefix it had mounted, and a check that
    # materializes over a tree still held by one gets "Text file busy" on the loader.
    sleep 2sec
}

def main [...names: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let checks = if ($names | is-empty) {
        $CHECKS
    } else if ($names | first) == "--with-nix" {
        $CHECKS ++ $SLOW
    } else {
        $names
    }

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    mut results = []
    mut failed = false
    for c in $checks {
        # .nu first, .sh second: the checks are being converted to nushell one at a time
        # (task #40), so both kinds coexist and this resolves whichever is present.
        # nu_path, not nu: nu is a builtin nushell variable and cannot be shadowed.
        let nu_path = $"scripts/($c).nu"
        let sh_path = $"scripts/($c).sh"
        let script = if ($nu_path | path exists) { $nu_path } else { $sh_path }
        if not ($script | path exists) {
            say $"no such check: scripts/($c).{nu,sh}"
            exit 2
        }
        say ""
        say $"######## ($c) ########"
        kill_daemons
        let rc = (do -i { ^$"./($script)" } | complete | get exit_code)
        $results = ($results | append {name: $c, rc: $rc})
        if not ($rc in [0 3]) {
            $failed = true
        }
    }
    kill_daemons

    say ""
    say "######## summary ########"
    for r in $results {
        let verdict = if $r.rc == 0 {
            "PASS"
        } else if $r.rc == 3 {
            "KNOWN (see the check's header)"
        } else {
            "FAIL"
        }
        say ("  " + ($r.name | fill --alignment left --width 24) + " rc="
            + ($"($r.rc)" | fill --alignment left --width 3) + " " + $verdict)
    }

    if not $failed {
        say ""
        say "PASS: every runtime check is at 0 or a known 3"
        exit 0
    }
    say ""
    say "FAIL: at least one runtime check failed"
    exit 1
}
