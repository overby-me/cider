#!/usr/bin/env nu
# Does a change invalidate the Nix endpoint?
#
# The graph derivation takes the STAGED PROJECT as a single store path, and every lowered
# derivation takes it too, so one comment inside it rebuilds all ~1800 of them. Nothing
# said so out loud, and an endpoint build was left running for four hours after a doc
# sweep had already superseded it: it was producing a prefix derivation that HEAD no
# longer wanted. This answers that question in a second, before the hours are spent.
#
# Usage:
#   scripts/buck-endpoint-stale.nu                      # working copy vs its parent
#   scripts/buck-endpoint-stale.nu --since <rev>        # anything since <rev>
#   scripts/buck-endpoint-stale.nu --against <storepath> # re-measure the root list itself
#
# Exit 0 when nothing touched carries into the endpoint, 1 when something did, so a build
# wrapper can gate on it.

# Measured, not guessed: this is the top level of a real
# /nix/store/*-darling-buck2-project, which is what nix/lib/darlingBuck2Graph.nix passes as
# src. scripts/, nix/, docs/, plan/, PLAN.md and flake.nix are NOT in it. Re-measure with
# --against whenever a staged project is at hand.
#
# NECESSARY, NOT SUFFICIENT, and this script over-reports because of it. Being under one of
# these roots means a file CAN reach the endpoint, not that it does: editing
# tests/darling-buck2-smoke.nix was reported stale here, and the prefix derivation did not
# change at all -- nix build .#darling-buck2 afterwards consumed the very store path the
# earlier build had produced. So a STALE verdict means "check before you trust a running
# build", not "it is certainly wasted". The definitive answer is comparing the two
# drvPaths, which costs a graph build, which is the thing this script exists to avoid.
const ENDPOINT_ROOTS = [
    ".tangled" ".vscode" "buck" "buck-rust" "buck-src" "cmake" "darwin" "etc" "linux"
    "misc" "outputs" "patches" "src" "templates" "tests" "tools"
    ".buckconfig" ".buckroot" ".envrc" ".gdbinit" ".gitignore" ".watchmanconfig"
    "CMakeLists.txt" "LICENSE"
]

# Outside the staged project, but inputs of the endpoint in their own right: the first two
# are passed to the graph derivation as separate store paths, and the last two ARE the
# derivations, so a comment in them changes the drv text directly.
const OWN_INPUTS = [
    "scripts/buck2-graph-dump.py"
    "scripts/buck-src-normalise.py"
    "nix/lib/darlingBuck2Graph.nix"
    "nix/lib/darlingBuck2Lower.nix"
]

def classify [path: string] {
    if $path in $OWN_INPUTS { return "own-input" }
    let root = ($path | split row "/" | first)
    if $root in $ENDPOINT_ROOTS { "staged" } else { "neutral" }
}

def main [
    --since: string = ""        # compare this revision to the working copy (default: the parent)
    --against: string = ""      # a staged project store path, to re-measure the root list
] {
    cd ($env.CURRENT_FILE | path dirname | path join "..")

    if ($against | is-not-empty) {
        # The root list is the only guessable part of this, so check it against the real
        # thing rather than trusting a comment.
        # ls --all, because nushell hides dotfiles exactly like a shell ls does, and eight
        # of the roots are dotfiles. Without it the self-check reports them as absent.
        let actual = (ls --all $against | get name | each {|n| $n | path basename } | sort)
        let expected = ($ENDPOINT_ROOTS | sort)
        let missing = ($expected | where {|e| not ($e in $actual) })
        let extra = ($actual | where {|a| not ($a in $expected) })
        if ($missing | is-empty) and ($extra | is-empty) {
            print $"ok: the root list matches ($against)"
            exit 0
        }
        if ($missing | is-not-empty) { print $"listed but absent: ($missing | str join ', ')" }
        if ($extra | is-not-empty) { print $"present but unlisted: ($extra | str join ', ')" }
        print "The endpoint sees more (or less) than this script thinks. Fix ENDPOINT_ROOTS."
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
    exit 1
}
