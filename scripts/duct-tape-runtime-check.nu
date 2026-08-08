#!/usr/bin/env nu
# Does the duct-tape glue that is Rust now actually WORK at runtime? (#71)
#
# The only runtime gate for a duct-tape change used to be checks.darling-buck2-min-smoke,
# which builds a whole minimal prefix and takes about an hour. That is far too slow to be the
# first thing that tells you a port is wrong. This drives the ported code directly and takes
# about a minute.
#
# //linux/server:scheduler_demo blocks a kernel microthread on a duct-tape semaphore and wakes
# it: dtape_semaphore_create, then dtape_semaphore_down_simple (which blocks, so the scheduler
# suspends the microthread), then dtape_semaphore_up from the main thread. All three are Rust
# as of the semaphore port, and the path runs down through XNU and back out through the
# thread_suspend and thread_resume hooks. Getting SCHED_DEMO_OK means the whole loop worked.
#
# IT ASSERTS ON THE OUTPUT, NOT ON THE EXIT CODE, and that is not a style choice. Verified by
# breaking it on purpose: making dtape_semaphore_down_simple report every successful wait as
# interrupted prints SCHED_DEMO_DOWN_FAILED and STILL EXITS 0, because the demo own asserts
# (did it suspend, did it finish) both still hold. An exit-code check would have passed a
# semaphore that never reports success.
#
# Usage:
#   scripts/duct-tape-runtime-check.nu           # build and run
#   scripts/duct-tape-runtime-check.nu --no-build

def say [msg: string] { print -e $msg }

def main [--no-build] {
    if not $no_build {
        say "building //linux/server:scheduler_demo ..."
        let build = (do -i { ^buck2 build //linux/server:scheduler_demo } | complete)
        if $build.exit_code != 0 {
            say "FAIL: the demo did not build"
            say $build.stderr
            exit 1
        }
    }

    let out = (do -i {
        ^buck2 build //linux/server:scheduler_demo --show-output
    } | complete)
    let path = ($out.stdout | lines | where {|l| $l =~ 'scheduler_demo' } | last
                | split row ' ' | last)
    if ($path | is-empty) {
        say "FAIL: could not find the built demo"
        exit 1
    }
    say $"running ($path)"

    let run = (do -i { ^$path } | complete)

    # The demo is chatty on stderr (the whole dtape_init trace); the verdict is on stdout.
    let verdict = ($run.stdout | lines | where {|l| $l =~ 'SCHED_DEMO' })
    if ($verdict | is-empty) {
        say "FAIL: the demo printed no verdict at all, so it did not reach the wake"
        say ($run.stderr | lines | last 15 | str join "\n")
        exit 1
    }

    let line = ($verdict | first)
    say $"  verdict: ($line)"
    if $line != "SCHED_DEMO_OK" {
        say $"FAIL: expected SCHED_DEMO_OK, got ($line)"
        say "  the ported dtape_semaphore_* did not complete a block and wake"
        exit 1
    }

    # Exit code is checked too, but SECOND: it is the weaker signal of the two.
    if $run.exit_code != 0 {
        say $"FAIL: verdict was OK but the demo exited ($run.exit_code)"
        exit 1
    }

    say "PASS: a microthread blocked on a Rust duct-tape semaphore and was woken"
}
