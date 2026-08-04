#!/usr/bin/env nu
# Does a change invalidate the Nix endpoint?
#
# The graph derivation takes the STAGED PROJECT as a single store path, and every lowered
# derivation takes it too, so one comment inside it rebuilds all ~1800 of them. Nothing
# said so out loud, and an endpoint build was left running for four hours after a doc
# sweep had already superseded it: it was producing a prefix derivation that HEAD no
# longer wanted. This answers that question in a second, before the hours are spent.
#
# SINCE #50 AN OWN-INPUT HIT IS NO LONGER AUTOMATICALLY EXPENSIVE, and this script cannot
# tell the difference, so read its verdict with that in mind. The graph derivation now has
# two content-addressed outputs: `out` holds graph.json and target-sources.json, which only
# the EVALUATOR reads, and `data` holds staged/ and treelinks/, which the lowered BUILDERS
# read. A dump change that only alters graph.json leaves `data` byte-identical, so its path
# does not move and every lowered target resolves to the output it already has -- the work
# in flight is not wasted. A dump change that alters staged/ or treelinks/ does move it and
# everything downstream really does rebuild.
#
# Which of the two it is cannot be decided from the source diff, only measured: rebuild the
# GRAPH alone and see whether nix reruns any builder. And the check is whether it RERUNS,
# not whether a drvPath moved -- a consumer of a content-addressed output holds a deferred
# reference carrying the producing drv, so its drvPath moves every time and means nothing.
#
# Usage:
#   scripts/buck-endpoint-stale.nu                      # working copy vs its parent
#   scripts/buck-endpoint-stale.nu --since <rev>        # anything since <rev>
#   scripts/buck-endpoint-stale.nu --against <storepath> # re-measure the root list itself
#
# Exit 0 when nothing touched carries into the endpoint, 1 when something did, so a build
# wrapper can gate on it.

# What the endpoint actually reads, taken from the two filters themselves rather than from a
# listing of the result: nix/lib/darlingBuck2Graph.nix and nix/lib/darlingBuck2Lower.nix each
# drop these top-level names, and both additionally drop tests/**/*.nix. This is the
# INTERSECTION of the two lists, so a path is called neutral only when BOTH filters drop it.
# The lowering drops seven more (LICENSE, .vscode, .claude, .tangled, .gdbinit,
# .dfx-boot.log, result-graph-ref); calling those staged is the safe direction.
#
# The first version of this script whitelisted the top level of a built staged project
# instead, which said tests/ was an endpoint input. It is not: tests/buck2 holds real buck2
# targets and passes the filter, while the NixOS VM tests beside it are Nix that buck2 never
# reads. Editing tests/darling-buck2-smoke.nix was reported stale and the prefix derivation
# did not move at all.
const NEUTRAL_TOPS = [
    "plan" "docs" "nix" "scripts" "PLAN.md" "README.md" "CONTRIBUTORS.md"
    ".git" ".jj" ".direnv" "buck-out" "flake.nix" "flake.lock" "result-graph-ref"
]

# Outside those filters but inputs of the endpoint in their own right: the first two are
# passed to the graph derivation as separate store paths, and the last two ARE the
# derivations, so a comment in them changes the drv text directly. They sit under tops the
# filters drop, which is exactly why they need naming.
const OWN_INPUTS = [
    "scripts/buck2-graph-dump.py"
    "scripts/buck-src-normalise.py"
    "nix/lib/darlingBuck2Graph.nix"
    "nix/lib/darlingBuck2Lower.nix"
]

def classify [path: string] {
    if $path in $OWN_INPUTS { return "own-input" }
    let top = ($path | split row "/" | first)
    # both filters drop the Nix files under tests/, and only those
    if $top == "tests" and ($path | str ends-with ".nix") { return "neutral" }
    if $top in $NEUTRAL_TOPS { return "neutral" }
    "staged"
}

def main [
    --since: string = ""        # compare this revision to the working copy (default: the parent)
    --against: string = ""      # a staged project store path, to re-measure the root list
] {
    cd ($env.CURRENT_FILE | path dirname | path join "..")

    if ($against | is-not-empty) {
        # The exclusion list is the guessable part, so check it against a real staged
        # project: not one of these names may appear in it, and no Nix file under tests/
        # may either. If one does, the endpoint reads it and this script is calling it
        # neutral, which is the dangerous direction.
        let present = ($NEUTRAL_TOPS | where {|t| ($against | path join $t) | path exists })
        let stray = (glob $"($against)/tests/**/*.nix" | length)
        if ($present | is-empty) and $stray == 0 {
            print $"ok: none of the ($NEUTRAL_TOPS | length) excluded names is in ($against), and no tests Nix file either"
            exit 0
        }
        if ($present | is-not-empty) { print $"present but called neutral: ($present | str join ', ')" }
        if $stray > 0 { print $"($stray) Nix file\(s) under tests/ are in the staged project" }
        print "The endpoint reads more than this script thinks. Fix NEUTRAL_TOPS."
        exit 1
    }

    # jj diff --summary prints "<status> <path>", one per line.
    let raw = if ($since | is-empty) {
        (^jj diff --summary | into string)
    } else {
        (^jj diff --summary --from $since --to "@" | into string)
    }
    let changed = (
        $raw | str replace -r '\n+$' '' | split row "\n"
        | where {|l| ($l | str length) > 2 }
        | each {|l| $l | str substring 2.. }
    )

    if ($changed | is-empty) {
        print "ok: nothing changed"
        exit 0
    }

    let rows = ($changed | each {|p| {path: $p, kind: (classify $p)} })
    let hits = ($rows | where {|r| $r.kind != "neutral" })

    if ($hits | is-empty) {
        print $"ok: ($changed | length) changed file\(s), none of them an endpoint input"
        exit 0
    }

    print $"STALE: ($hits | length) of ($changed | length) changed file\(s) feed the endpoint"
    for h in $hits { print $"  ($h.kind)  ($h.path)" }
    print ""
    print "A build started before these is producing a prefix derivation HEAD no longer wants."
    if ($hits | any {|h| $h.kind == "own-input" }) and ($hits | all {|h| $h.kind == "own-input" }) {
        print ""
        print "ALL of them are own-inputs, so this may be cheap. Since #50 a dump change that"
        print "only alters graph.json leaves the data output byte-identical and every lowered"
        print "target keeps the output it already has. Rebuild the GRAPH alone and see whether"
        print "nix reruns a builder; do not read the drvPath, a deferred reference always moves."
    }
    exit 1
}
