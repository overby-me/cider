#!/usr/bin/env nu
# Does the xnu-sys glue that is Rust now actually WORK at runtime? (#71)
#
# The only runtime gate for a xnu-sys change used to be checks.cider-buck2-min-smoke,
# which builds a whole minimal prefix and takes about an hour. That is far too slow to be the
# first thing that tells you a port is wrong. This drives the ported code directly, in about a
# minute, and it is the check to run before reaching for the prefix gate.
#
# One demo per ported file, each blocking a kernel microthread and waking it, so the path runs
# down through XNU and back out through the thread_suspend and thread_resume hooks:
#
#   scheduler_demo  xnu_sys_semaphore_create / down_simple / up      (semaphore.c port)
#   condvar_demo    xnu_sys_condvar_wait / signal, over a xnu_sys_mutex (condvar.c port)
#   stage3_spike    the same semaphore path, 500,000 round-trips    (semaphore.c, stress)
#   host_demo       host_info, host_statistics, processor_set_info      (host.c, processor.c)
#   psynch_demo     the init invariants and the callback vtable          (psynch.c port)
#   kqchan_demo     create, has_events and destroy on a REAL port        (kqchan.c port)
#
# psynch_demo is a THIRD kind of check, and it is shaped by how psynch fails. It does not hang
# like the first three or answer with a wrong number like host_demo: it fails SILENTLY. Omitting
# init phase 2 left pthread_list_mlock NULL and the symptom was a SIGSEGV inside the kext on the
# first contended pthread wait, which surfaced only as a guest task exiting -111. So rather than
# drive a wait and hope, it asserts on the state init left behind: both allocations non-null,
# and all 18 callback vtable entries the port fills present. The other 78 entries come from a
# zeroed const and are SUPPOSED to be None, so the check names its 18 rather than sweeping,
# because a sweep would either fail on the legitimate Nones or pass on everything.
#
# host_demo is a DIFFERENT KIND of check, because host.c fails differently. The first three
# files hang or crash when they are wrong, so finishing at all is most of the proof. host.c
# hands NUMBERS back to the guest, and a wrong field offset does not crash anything, it just
# tells the guest the machine has the wrong amount of memory. So that demo compares the answers
# against /proc/meminfo and /proc/cpuinfo, which share no code path with the sysinfo and
# sysconf calls the port uses, and it drives the refusal paths as well as the happy one.
#
# The spike is the one that would catch a leak, a corrupted queue or an off-by-one, which a
# single block-and-wake cannot. Measured after the port: 500,000 round-trips in 5.79 s,
# 11,587 ns each, no assertion. There is no pre-port number to compare it against.
#
# TWO THINGS THIS GETS RIGHT THAT ARE EASY TO GET WRONG:
#
# IT ASSERTS ON THE OUTPUT, NOT THE EXIT CODE. Verified by breaking it on purpose: making
# xnu_sys_semaphore_down_simple report every successful wait as interrupted prints
# SCHED_DEMO_DOWN_FAILED and STILL EXITS 0, because the demo own asserts (did it suspend, did
# it finish) both still hold. An exit-code check would have passed a broken semaphore.
#
# IT BOUNDS THE RUN. A queue bug does not fail, it HANGS: lose the waiter in TAILQ_INSERT_TAIL
# and the signal finds nothing to pop, so nobody is ever woken and the demo waits forever.
# A timeout here is therefore load bearing, and is the reported failure mode. (This is a RUN,
# not a build -- never bound a long build this way, it just SIGTERMs it at the deadline.)
#
# Usage:
#   scripts/xnu-sys-runtime-check.nu
#   scripts/xnu-sys-runtime-check.nu --seconds 120

const DEMOS = [
    [target, verdict, covers];
    ["scheduler_demo", "SCHED_DEMO_OK", "semaphore.c"]
    ["condvar_demo", "CONDVAR_DEMO_OK", "condvar.c"]
    ["stage3_spike", "SPIKE_RESUMED_OK", "semaphore.c under 500k round-trips"]
    ["host_demo", "HOST_DEMO_OK", "host.c and processor.c, cross-checked against /proc"]
    ["psynch_demo", "PSYNCH_DEMO_OK", "psynch.c init invariants and the 18 vtable entries"]
    ["kqchan_demo", "KQCHAN_DEMO_OK", "kqchan.c create, has_events and destroy on a real port"]

    # RESTORED from the deleted checks.server (#82). That check was fed by the cmake xnu-sys
    # package, so removing cmake silently took 17 runtime proofs of the daemon with it. They
    # had no buck2 target because cargo built them; they have one now.
    ["rpc_wire_check", "RPC_WIRE_OK", "the generated RPC wire structs, their sizes and alignment"]
    ["dispatch_demo", "DISPATCH_OK", "the generated RPC dispatch"]
    ["rpc_loop_demo", "RPC_LOOP_OK", "the daemon receive and decode half of the RPC loop"]
    ["rpc_roundtrip_demo", "RPC_ROUNDTRIP_OK", "the full daemon request to reply cycle"]
    ["registry_demo", "REGISTRY_OK", "per-guest routing through the process and thread tables"]
    ["mem_hooks_demo", "MEM_HOOKS_OK", "the guest-memory hooks, task_read_memory and task_write_memory"]
    ["mach_traps_demo", "MACH_TRAPS_OK", "the Mach special-port traps served by the Rust daemon"]
    ["persistent_threads_demo", "PERSISTENT_THREADS_OK", "persistent per-guest threads"]
    ["mach_port_demo", "MACH_PORT_OK", "Mach port-right operations through XNU on a guest task"]
    ["mach_port_lifecycle_demo", "MACH_PORT_LIFECYCLE_OK", "a full Mach port-name lifecycle"]
    ["mach_msg_demo", "MACH_MSG_OK", "mach_msg_overwrite through real XNU"]
    ["blocking_msg_demo", "BLOCKING_MSG_OK", "a blocking mach_msg receive across two guest threads"]
    ["thread_call_loop_demo", "THREAD_LOOP_OK", "the persistent-thread doWork loop"]
    ["daemon_mach_demo", "DAEMON_MACH_OK", "a real client over the socket for the special-port traps"]
    ["daemon_alloc_demo", "DAEMON_ALLOC_OK", "cross-process copyout over a real socket"]
    ["daemon_msg_demo", "DAEMON_MSG_OK", "a client process running a full mach_msg send and receive"]
    ["daemon_session_demo", "DAEMON_SESSION_OK", "a full guest session on one persistent connection"]
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

    # Presence, not equality: a binary may print several verdicts (stage3_spike prints two).
    # Presence alone would be too weak, so a failure marker anywhere is also fatal -- that is
    # what catches SCHED_DEMO_DOWN_FAILED being printed ALONGSIDE something that looks fine.
    let lines = ($run.stdout | lines)
    let bad = ($lines | where {|l| ($l =~ 'FAILED') or ($l =~ 'UNEXPECTED') })
    if not ($bad | is-empty) {
        say $"  FAIL: ($bad | first)"
        return false
    }
    # STARTS WITH, not equals. The comment above says presence and the code said equality,
    # which is fine while every demo prints its marker bare, and wrong the moment one prints
    # "MARKER: detail". The 17 restored from checks.server all do, and all 17 were reported
    # as failures while their output plainly contained the marker. Starts-with keeps this
    # stricter than a bare contains: the marker still has to open the line.
    if not ($lines | any {|l| ($l == $verdict) or ($l | str starts-with $"($verdict):") }) {
        say $"  FAIL: never printed ($verdict); saw: ($lines | str join ', ')"
        say ($run.stderr | lines | last 10 | str join "\n")
        return false
    }
    let line = $verdict
    # Checked SECOND, deliberately: it is the weaker of the two signals.
    if $run.exit_code != 0 {
        say $"  FAIL: verdict was ($line) but it exited ($run.exit_code)"
        return false
    }
    say $"  ok: ($line)"
    true
}

# THE LINK CHECK, and it runs FIRST because it is the cheapest way to be wrong.
#
# Every port before locks.c was proven with the demos plus a symbol table check, and both
# PASSED on a debug.rs that could not link. xnu_sys_task_for_xnu_task is always_inline static in
# task.h, so there is no symbol; the port declared it extern, and the DEMOS still linked because
# nothing in them reaches that path and the linker garbage collected it. Only ciderd,
# where handler.rs really calls it, produced the undefined reference.
#
# So a demo binary is NOT an artifact that contains everything a port touches. The daemon is.
# It is built, not run: linking is the whole question here.
def link_check [] {
    say "ciderd -- does everything a port declares actually resolve"
    let built = (do -i { ^buck2 build //linux/server:ciderd } | complete)
    if $built.exit_code != 0 {
        say "  FAIL: ciderd did not link"
        let undef = ($built.stderr | lines | where {|l| $l =~ 'undefined reference' })
        if not ($undef | is-empty) {
            say $"  ($undef | first)"
            say "  an always_inline or static inline C function has NO symbol to link against;"
            say "  compute it in Rust instead, as condvar.rs does for xnu_sys_thread_for_xnu_thread"
        }
        return false
    }
    say "  ok: ciderd links"
    true
}

# The 29 trap wrappers in traps_generated.rs are emitted from the RPC table by
# scripts/gen-xnu-sys-traps.py and CHECKED IN, so they can go stale if that table moves. The C
# they replace could not: it was a macro expanded at compile time. This restores that property.
def traps_check [] {
    say "traps_generated.rs -- still matches the RPC table it was generated from"
    let r = (do -i { ^python3 scripts/gen-xnu-sys-traps.py --check } | complete)
    if $r.exit_code != 0 {
        say "  FAIL: the generated trap wrappers are stale"
        say ($r.stderr | lines | last 3 | str join "\n")
        return false
    }
    say $"  ok: ($r.stdout | str trim)"
    true
}

def main [--seconds: int = 90] {
    mut failed = 0
    if not (link_check) { $failed += 1 }
    if not (traps_check) { $failed += 1 }
    for d in $DEMOS {
        if not (run_one $d.target $d.verdict $d.covers $seconds) { $failed += 1 }
    }
    if $failed > 0 {
        say $"FAIL: ($failed) of (($DEMOS | length) + 1) checks failed"
        exit 1
    }
    say $"PASS: the daemon links and ($DEMOS | length) runtime checks pass over the ported files"
}
