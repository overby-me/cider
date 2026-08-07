#!/usr/bin/env nu
# Does one target still build, and what RAN? (task #68)
#
# This is the harness the rest of the invalidation work is verified through. It used to be four
# hand assembled steps every time -- a nix eval --apply to get a drvPath out of `named`, a
# nix build of that path, eyeballing the log for `building '` lines, and a manual probe edit
# and revert -- which is both slow and easy to get wrong in the same three ways each time.
#
# TWO RULES ARE BAKED IN, because both were re-derived by hand repeatedly and one of them was
# got wrong more than once:
#
#   1. JUDGE BY BUILDERS THAT RAN, NEVER BY drvPath. Every lowered derivation is content
#      addressed, so a consumer holds a placeholder keyed on the PRODUCING derivation: the
#      drvPath moves whenever anything upstream moves, whether or not a builder runs. This
#      script prints the drvPath labelled as the non-signal it is, and counts builders.
#
#   2. A FLAT BUILDER COUNT IS NOT A STALL ON ITS OWN. The nix-daemon concurrency bug here
#      shows up as the count flat AND unreaped zombie children of the worker AND zero live
#      children. Zombies beside live builders are routine. `buck-quick-check.nu stall` runs
#      exactly that three-part test rather than guessing from CPU.
#
# THE COUNTER SELF TESTS FIRST, and that is not ceremony. The whole method rests on reading
# ran=0 as "nothing rebuilt", so a counter that can only ever return 0 would turn every run
# into a silent pass. Six checks with that shape slipped through in one session. Before any
# measurement, this builds a one-line derivation carrying a fresh nonce -- never built before,
# so it MUST report exactly 1 -- and refuses to go on if it does not.
#
# Usage:
#   scripts/buck-quick-check.nu                        # build the canonical target, count
#   scripts/buck-quick-check.nu --attr .#some-package  # any flake attr
#   scripts/buck-quick-check.nu --probe <src file>     # + edit/rebuild/revert, the cascade test
#   scripts/buck-quick-check.nu --probe <f> --expect-zero   # exit 1 if anything rebuilt
#   scripts/buck-quick-check.nu --probe <f> --revert-only   # strip a probe left by a kill
#   scripts/buck-quick-check.nu stall                  # is a running build actually stalled
#
# COST, measured with this script on 2026-08-06:
#
#   run again, nothing changed          0.3s     the flake evaluation is cached
#   run after editing nix/              12.3s    ran=0, so the cache is the only thing lost
#   first build of the target           12.7s    12.3 of it evaluation, 0.4 the builder
#
# So the 12s is the strict parse of the 307 MB graph.json, it is paid ONCE PER CHANGE TO THE
# FLAKE SOURCE TREE, and not per build. That is the exact shape of the tax #66 is aimed at:
# iterating on the lowering itself pays it every single time, and nothing else does.
#
# --probe is only quick for a path both source filters exclude (scripts/, nix/, docs/,
# PLAN.md), and probing those tests nothing about the cascade for the same reason they are
# cheap. A probe anywhere else moves darling-src, so ld64 (about 26 min, content addressed and
# collapsing to the same output) and the graph (about 18 min) rebuild before the target is
# reached. The script says which of the two it is before it starts.

# THE PROBE TEXT MUST BE NEW EVERY RUN, and that is not cosmetic. It used to be a fixed string,
# so probing the same file twice reproduced a source tree that was ALREADY IN THE STORE, along
# with everything built from it. The second probe then reported ran=0 in 15.7s and read as total
# success while measuring nothing at all: the check could not fail. Rerunning on a file that had
# never been probed gave 6 builders and 17.5 minutes.
#
# So the marker carries a nonce. Reverting still works after a kill, because it strips any line
# containing MARKER_TAG rather than matching the whole string.
const MARKER_TAG = "buck-quick-check probe"
const DEFAULT_ATTR = ".#darling-buck2-one"

def say [msg: string] { print -e $msg }

# ps rather than nushell's own `ps`, because we need the process STATE letter and want the
# same field set the recorded diagnosis was written against.
def proc-table [] {
    ^ps -eo pid=,ppid=,stat=,comm=
    | lines
    | where {|l| ($l | str trim) != "" }
    | each {|l|
        let f = ($l | str trim | split row -r '\s+')
        {
            pid: ($f | get 0 | into int),
            ppid: ($f | get 1 | into int),
            stat: ($f | get 2),
            comm: ($f | skip 3 | str join " "),
        }
      }
}

# Run one nix build and report what RAN. `building '<drv>'` goes to stderr; --print-out-paths
# writes the output path to stdout, so the two never have to be untangled by hand.
def build-and-count [attr: string, jobs: int, cores: int] {
    let started = (date now)
    let r = (do {
        ^nix build $attr --no-link --print-out-paths --max-jobs $jobs --cores $cores --keep-going
    } | complete)
    let ran = ($r.stderr | lines | where {|l| $l | str starts-with "building '" })
    let outs = ($r.stdout | lines | where {|l| $l | str starts-with "/nix/store/" })
    {
        exit: $r.exit_code,
        ran: ($ran | length),
        drvs: $ran,
        out: (if ($outs | is-empty) { "" } else { $outs | last }),
        stderr: $r.stderr,
        secs: (((((date now) - $started) / 1sec)) | math round -p 1),
    }
}

# The negative control for the counter itself. A derivation carrying a nonce has never been
# built, so a working counter reports exactly 1. If this reads 0 the log format changed and
# every ran=0 below would be a false pass.
def counter-selftest [] {
    let nonce = (random chars --length 16)
    let expr = $"derivation { name = \"buck-quick-check-selftest\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ($nonce) > $out\" ]; }"
    let r = (do { ^nix build --expr $expr --no-link --print-out-paths } | complete)
    let ran = ($r.stderr | lines | where {|l| $l | str starts-with "building '" } | length)
    if $r.exit_code != 0 {
        say "FAIL: the counter self test could not build a one line derivation."
        say ($r.stderr | lines | last 5 | str join "\n")
        exit 2
    }
    if $ran != 1 {
        say $"FAIL: counter self test counted ($ran) builders for a derivation that had never"
        say "been built. Expected exactly 1. `building '<drv>'` is no longer how nix reports a"
        say "builder starting, so every ran=0 this script prints would be a false pass."
        exit 2
    }
    say $"counter self test: ran=1 as expected, the counter can report non zero"
}

# What this probe will actually cost, which is not one number. Both source filters exclude
# scripts/, nix/, docs/ and PLAN.md, so a probe there re-evaluates and rebuilds NOTHING;
# anything else moves darling-src and drags ld64 and the graph in ahead of the target.
def probe-cost []: string -> string {
    let path = $in
    let free = ["docs/", "PLAN.md"]
    # scripts/ and nix/ are excluded from the SOURCE FILTERS, so they do not move darling-src,
    # but that is not the same as free: several are nix path INPUTS, referenced as
    # ${../../scripts/<name>}, so editing one moves the derivation that uses it. Measured:
    # probing scripts/buck-codegen-keep.txt rebuilt darling-buck2-skeleton. This message used
    # to say those paths rebuild nothing at all, which was wrong.
    let filtered = ["scripts/", "nix/"]
    if ($free | any {|p| $path | str starts-with $p }) {
        "Excluded from everything, so this re-evaluates but rebuilds nothing: about 12s."
    } else if ($filtered | any {|p| $path | str starts-with $p }) {
        "Outside both source filters, so darling-src does not move, but a script or nix file used as a nix INPUT still rebuilds whatever consumes it."
    } else {
        "This moves darling-src, so ld64 rebuilds. The GRAPH no longer does (#56). MEASURED end to end on one .m file: 6 builders, 17.5 minutes."
    }
}

def has-probe [path: string] {
    (open --raw $path | str contains $MARKER_TAG)
}

def apply-probe [path: string] {
    let text = (open --raw $path)
    let sep = (if ($text | str ends-with "\n") { "" } else { "\n" })
    # The nonce is what makes this a real probe rather than a replay of a cached tree.
    let marker = $"/* ($MARKER_TAG) (random chars --length 16): safe to delete */"
    $"($text)($sep)($marker)\n" | save -f $path
}

# Reverting by STRIPPING THE MARKER rather than restoring a backup, so an interrupted run
# leaves something a later run can clean up by itself. A backup file cannot promise that.
def revert-probe [path: string] {
    let kept = (open --raw $path | lines | where {|l| not ($l | str contains $MARKER_TAG) })
    ($kept | str join "\n") + "\n" | save -f $path
}

def "main stall" [] {
    let procs = (proc-table)
    let clients = ($procs | where comm == "nix")
    if ($clients | is-empty) {
        say "no `nix` client is running, so there is nothing to be stalled. Relaunch the build."
        exit 0
    }
    say $"nix clients: ($clients | get pid | str join ', ')"

    let daemons = ($procs | where comm == "nix-daemon")
    mut stalled = false
    for d in $daemons {
        let kids = ($procs | where ppid == $d.pid)
        if ($kids | is-empty) { continue }
        let zombies = ($kids | where {|k| $k.stat | str starts-with "Z" })
        let live = ($kids | where {|k| not ($k.stat | str starts-with "Z") })
        say $"  daemon ($d.pid): ($live | length) live child\(ren), ($zombies | length) zombie\(s)"
        # All three parts, not one: zombies BESIDE live children are routine and were measured
        # alongside the count advancing 17 to 43 in four minutes.
        if ($zombies | is-not-empty) and ($live | is-empty) {
            $stalled = true
        }
    }
    if $stalled {
        say ""
        say "STALL SIGNATURE: a worker holds only zombies and has no live builder. Confirm the"
        say "builder count in the job log is also flat, sampled a minute apart, then TaskStop the"
        say "job and relaunch. No work is lost: finished derivations are already in the store."
        exit 1
    }
    say "no stall signature: every worker with children has at least one live builder."
    exit 0
}

def main [
    --attr: string = ""          # flake attr to build (default: the canonical one target)
    --probe: string = ""         # tracked source file to perturb, then revert
    --jobs: int = 5              # --max-jobs; 6 stalls the daemon on this box
    --cores: int = 4
    --expect-zero                # fail if the probe rebuilds anything
    --revert-only                # only strip a probe marker left behind by a kill
] {
    let attr = (if ($attr | is-empty) { $DEFAULT_ATTR } else { $attr })

    if $revert_only {
        if ($probe | is-empty) { say "--revert-only needs --probe <path>"; exit 2 }
        if not ($probe | path exists) { say $"no such file: ($probe)"; exit 2 }
        if not (has-probe $probe) { say $"no probe marker in ($probe), nothing to revert"; exit 0 }
        revert-probe $probe
        say $"reverted the probe in ($probe)"
        exit 0
    }

    if ($probe | is-not-empty) {
        if not ($probe | path exists) { say $"no such file: ($probe)"; exit 2 }
        if (has-probe $probe) {
            say $"($probe) already carries a probe marker, from a run that was killed."
            say "Revert it first: scripts/buck-quick-check.nu --probe <path> --revert-only"
            exit 2
        }
    }

    counter-selftest

    say $"building ($attr) ..."
    let base = (build-and-count $attr $jobs $cores)
    if $base.exit != 0 {
        say $"FAIL: ($attr) does not build \(exit ($base.exit))"
        say ($base.stderr | lines | last 30 | str join "\n")
        exit 1
    }
    say $"  baseline: ran=($base.ran) in ($base.secs)s"
    say $"  out: ($base.out)"

    if ($probe | is-empty) {
        say "PASS: the target builds. Pass --probe <src file> to measure the cascade."
        exit 0
    }

    # From here the probe is on disk, so every exit path has to remove it again.
    say ""
    say $"probing ($probe). ($probe | probe-cost)"
    apply-probe $probe
    let after = (try {
        build-and-count $attr $jobs $cores
    } catch {|e|
        revert-probe $probe
        say $"the probe build raised: ($e.msg)"
        exit 2
    })
    revert-probe $probe
    say $"reverted ($probe)"

    if $after.exit != 0 {
        say $"FAIL: ($attr) does not build with the probe applied \(exit ($after.exit))"
        say ($after.stderr | lines | last 30 | str join "\n")
        exit 1
    }

    say ""
    say $"  after probe: ran=($after.ran) in ($after.secs)s"
    # Printed, and printed as a NON signal on purpose. Comparing these two is the mistake this
    # script exists to stop: under content addressing they differ on every run that changes
    # anything upstream, including runs where not one builder started.
    say $"  \(drvPath moves regardless and is not evidence either way\)"
    if ($after.ran > 0) {
        let shown = ($after.drvs | first ([$after.ran, 5] | math min))
        say "  rebuilt:"
        $shown | each {|d| say $"    ($d)" }
    }

    if $expect_zero and $after.ran > 0 {
        say ""
        say $"FAIL: expected nothing to rebuild, ($after.ran) builders ran."
        exit 1
    }
    say ""
    say $"PASS: ($after.ran) builder\(s) ran after editing ($probe)."
    exit 0
}
