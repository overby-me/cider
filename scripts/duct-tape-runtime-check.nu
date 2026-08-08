#!/usr/bin/env nu
# Does the duct-tape glue that is Rust now actually WORK at runtime? (#71)
#
# The only runtime gate for a duct-tape change used to be checks.darling-buck2-min-smoke,
# which builds a whole minimal prefix and takes about an hour. That is far too slow to be the
# first thing that tells you a port is wrong. This drives the ported code directly, in about a
# minute, and it is the check to run before reaching for the prefix gate.
#
# One demo per ported file, each blocking a kernel microthread and waking it, so the path runs
# down through XNU and back out through the thread_suspend and thread_resume hooks:
#
#   scheduler_demo  dtape_semaphore_create / down_simple / up      (semaphore.c port)
#   condvar_demo    dtape_condvar_wait / signal, over a dtape_mutex (condvar.c port)
#
# TWO THINGS THIS GETS RIGHT THAT ARE EASY TO GET WRONG:
#
# IT ASSERTS ON THE OUTPUT, NOT THE EXIT CODE. Verified by breaking it on purpose: making
# dtape_semaphore_down_simple report every successful wait as interrupted prints
# SCHED_DEMO_DOWN_FAILED and STILL EXITS 0, because the demo own asserts (did it suspend, did
# it finish) both still hold. An exit-code check would have passed a broken semaphore.
#
# IT BOUNDS THE RUN. A queue bug does not fail, it HANGS: lose the waiter in TAILQ_INSERT_TAIL
# and the signal finds nothing to pop, so nobody is ever woken and the demo waits forever.
# A timeout here is therefore load bearing, and is the reported failure mode. (This is a RUN,
# not a build -- never bound a long build this way, it just SIGTERMs it at the deadline.)
#
# Usage:
#   scripts/duct-tape-runtime-check.nu
#   scripts/duct-tape-runtime-check.nu --seconds 120

const DEMOS = [
    [target, verdict, covers];
    ["scheduler_demo", "SCHED_DEMO_OK", "semaphore.c"]
    ["condvar_demo", "CONDVAR_DEMO_OK", "condvar.c"]
]

def say [msg: string] { print -e $msg }

def run_one [target: string, verdict: string, covers: string, seconds: int] {
    say $"($target) -- covers ($covers)"

    let built = (do -i {
        ^buck2 build $"//linux/server:($target)" --show-output
    } | complete)
    if $built.exit_code != 0 {
        say $"  FAIL: ($target) did not build"
        say ($built.stderr | lines | last 15 | str join "\n")
        return false
    }
    let path = ($built.stdout | lines | where {|l| $l =~ $target } | last
                | split row ' ' | last)
    if ($path | is-empty) {
        say $"  FAIL: could not find the built ($target)"
        return false
    }

    # Bounded, because the interesting failure is a hang rather than an error.
    let run = (do -i { ^timeout $"($seconds)s" $path } | complete)
    if $run.exit_code == 124 {
        say $"  FAIL: ($target) still running after ($seconds)s, so it never woke."
        say "  a lost waiter looks exactly like this: the signal found an empty queue"
        return false
    }

    let got = ($run.stdout | lines | where {|l| $l =~ '_DEMO_' })
    if ($got | is-empty) {
        say "  FAIL: no verdict printed, so it did not reach the wake"
        say ($run.stderr | lines | last 10 | str join "\n")
        return false
    }
    let line = ($got | first)
    if $line != $verdict {
        say $"  FAIL: expected ($verdict), got ($line)"
        return false
    }
    # Checked SECOND, deliberately: it is the weaker of the two signals.
    if $run.exit_code != 0 {
        say $"  FAIL: verdict was ($line) but it exited ($run.exit_code)"
        return false
    }
    say $"  ok: ($line)"
    true
}

def main [--seconds: int = 90] {
    mut failed = 0
    for d in $DEMOS {
        if not (run_one $d.target $d.verdict $d.covers $seconds) { $failed += 1 }
    }
    if $failed > 0 {
        say $"FAIL: ($failed) of ($DEMOS | length) runtime checks failed"
        exit 1
    }
    say $"PASS: ($DEMOS | length) ported duct-tape files block and wake a microthread"
}
