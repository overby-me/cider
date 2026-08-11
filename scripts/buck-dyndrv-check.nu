#!/usr/bin/env nu
# Do dynamic derivations still do the five things #66 depends on?
#
# NOT IN THE NIX-FREE SET. This one builds, so it is slow by that standard (tens of seconds
# warm) and belongs in the deliberate-run bucket, not the 27 second pre-flight.
#
# WHY IT EXISTS. #66 replaces the evaluator-computed derivations with derivations the generator
# EMITS, which only works if five properties hold. 1 to 3 are properties of NIX rather than of
# this project, verified by hand on 2026-08-11 with Nix 2.35.1; a Nix upgrade could take any of
# them away silently, and the failure would not look like "dynamic derivations regressed", it
# would look like the endpoint rebuilding everything, or an hour-long gate dying somewhere far
# away. 4 and 5 are properties of nix/lib/dyn-actions.nix, and BOTH were already false when
# they were first checked: the DAG edge and the whole specDir mode. Neither had a fixture, so
# neither could have been noticed.
#
#   1. builtins.outputOf works end to end.
#   2. EARLY CUTOFF SURVIVES IT. This is the one that matters. If a consumer bound through
#      outputOf rebuilds whenever the PRODUCER re-runs, #66 trades an eval cost for a rebuild
#      cost and is worse than what it replaces.
#   3. SUBSTITUTION SURVIVES IT. Nix warns "Ignoring dynamic derivation ...^out while querying
#      missing paths; not yet implemented", which sounds fatal and is not: it is the planning
#      pass. Verified by deleting the output and serving it from a file:// cache. This matters
#      because #50/#55 exist to produce a per-action cache a binary cache can serve.
#   4. AN EMITTED DERIVATION CAN CONSUME ANOTHER ONE'S OUTPUT. cider's groups are a DAG, so a
#      bridge that only does independent actions is no use here whatever else works. Unlike
#      1 to 3 this is a property of nix/lib/dyn-actions.nix rather than of Nix, and it was
#      silently broken until 2026-08-11: inputSrcs went to `nix derivation add` as a full
#      store path, which it rejects, so no declared source had ever worked. It could not be
#      caught by watching which builders ran, because the build ORDER was right either way.
#   5. THE TWO MODES OF dyn-actions.nix AGREE. `actions` serialises specs in the evaluator;
#      `specDir` reads pre-serialised ones off disk and is the mode that scales. Nothing had
#      ever BUILT a spec dir until 2026-08-11, so half the API was evaluated and never run.
#
# The probe itself, and the one structural constraint that makes it work at all (the inner
# output must NOT be named "out"), is documented in nix/lib/dyn-drv-probe.nix.
#
# Usage: scripts/buck-dyndrv-check.nu

def say [msg: string] { print -e $msg }
def ok [msg: string] { print -e $"  ok   ($msg)" }
def bad [msg: string] { print -e $"  FAIL ($msg)" }

def build_knob [knob: string] {
    let expr = $"\(import ./nix/lib/dyn-drv-probe.nix { pkgs = import <nixpkgs> {}; knob = \"($knob)\"; }).consumer"
    # STDERR IS THE MEASUREMENT HERE, not decoration: the builders announce themselves on it,
    # and which ones ran is the entire question. Never discard it.
    do -i { ^nix build --impure --expr $expr --no-link --print-out-paths -L } | complete
}

def main [] {
    mut fails = 0

    say "== dynamic derivations: does the mechanism #66 needs still work? =="

    # TWO KNOB VALUES THAT HAVE NEVER BEEN USED, one per run. Reusing fixed values makes the
    # producer's output cached, so it does not re-run, and then "the consumer did not rebuild"
    # is explained by nothing having happened at all. The first version of this check hit
    # exactly that and reported the knob as inert, which is what the guard below is for.
    let stamp = (date now | format date "%s%f")
    let ka = $"a($stamp)"
    let kb = $"b($stamp)"

    let a = (build_knob $ka)
    if $a.exit_code != 0 {
        bad "the probe does not build at all; builtins.outputOf or recursive-nix has regressed"
        print -e ($a.stderr | lines | last 12 | str join "\n")
        exit 1
    }
    let path_a = ($a.stdout | str trim | lines | last)
    ok $"outputOf builds end to end, consumer at ($path_a | path basename)"

    # EARLY CUTOFF. knob changes the producer's input and nothing the inner derivation sees,
    # so the emitted drv is byte identical and NOTHING downstream may rebuild.
    let b = (build_knob $kb)
    if $b.exit_code != 0 {
        bad "the probe fails with the knob flipped, which is a different bug to the above"
        $fails += 1
    } else {
        let path_b = ($b.stdout | str trim | lines | last)
        let producer_ran = ($b.stderr | str contains $"PRODUCER RAN knob=($kb)")
        let consumer_ran = ($b.stderr | str contains "CONSUMER RAN")
        if not $producer_ran {
            # Not a pass. If the producer did NOT re-run, the knob is not reaching it and the
            # experiment proves nothing: a consumer that does not rebuild is then trivially
            # explained by nothing having changed at all.
            bad "the producer did not re-run, so this run tests nothing; the knob is inert"
            $fails += 1
        } else if $consumer_ran {
            bad "EARLY CUTOFF IS GONE: the producer re-ran and the consumer rebuilt with it"
            $fails += 1
        } else if $path_a != $path_b {
            bad $"the consumer output moved, ($path_a) to ($path_b)"
            $fails += 1
        } else {
            ok "early cutoff survives: producer re-ran, consumer did not, same output path"
        }
    }

    # SUBSTITUTION IS DELIBERATELY NOT AUTOMATED HERE. Proving it requires DELETING a store
    # path and rebuilding, and a check that deletes from a live store without being asked is
    # not a check, it is a hazard. It was verified by hand on 2026-08-11 and the exact
    # sequence is below so it can be redone in a minute:
    #
    #   DRV=$(nix eval --impure --raw --expr '(import ./nix/lib/dyn-drv-probe.nix {
    #           pkgs = import <nixpkgs> {}; }).producer.outPath')
    #   INNER=$(nix path-info "$(cat $DRV | head -c0; echo $DRV)^inner")   # the emitted drv
    #   nix copy --to file:///tmp/dyncache "$INNER"
    #   nix store delete <consumer> <consumer.drv> "$INNER"
    #   nix build ... --substituters file:///tmp/dyncache --no-require-sigs
    #
    # Expected, and what was observed: the "Ignoring dynamic derivation ...^out while querying
    # missing paths" warning appears AND the output is copied from the cache rather than
    # rebuilt. The warning is the planning pass; substitution itself is intact.
    say "  note substitution is not automated; the header gives the by-hand sequence"

    # 4. THE DAG PROPERTY. cider's 1,474 groups depend on each other, so a bridge that only
    # does INDEPENDENT actions is no use to #66 whatever else works. This was silently broken
    # until 2026-08-11: inputSrcs was passed to `nix derivation add` as a full store path,
    # which it rejects, so no declared source had ever worked and no toy noticed because none
    # declares one. The probe reads its dependency's CONTENT rather than testing for the path,
    # because an empty file at the right path would pass a weaker check for the wrong reason.
    let feats = "nix-command ca-derivations dynamic-derivations recursive-nix"
    let dep = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-dep-probe.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $dep.exit_code != 0 {
        bad "the dependency probe does not build"
        print -e ($dep.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        let said = (open --raw ($dep.stdout | str trim | lines | last) | str trim)
        if ($said | str starts-with "B-SEES-A") {
            ok $"an emitted derivation reads its dependency: ($said)"
        } else if $said == "B-BLIND" {
            # The exact regression the probe exists for: the build ORDER still looks right,
            # so this cannot be caught by watching which builders ran.
            bad "B-BLIND: an emitted derivation can no longer see its dependency's output"
            $fails += 1
        } else {
            bad $"the dependency probe said something unexpected: ($said)"
            $fails += 1
        }
    }

    # 5. THE TWO MODES AGREE. dyn-actions.nix can be reached two ways: `actions`, which
    # serialises each spec in the evaluator, and `specDir`, which reads pre-serialised ones off
    # disk so the evaluator never touches them. specDir is the one that scales and was the one
    # NOTHING had ever built: until 2026-08-11 no fixture produced a spec directory, so half
    # the API had been evaluated and never run. A consumer that develops against the convenient
    # mode and ships the scalable one must get the same derivations, or the difference surfaces
    # as an unexplained full rebuild.
    #
    # The toy asserts on the output PATHS, not the contents: equal contents would not rule out
    # two different derivations that happen to print the same thing.
    let sd = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-specdir-toy.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $sd.exit_code != 0 {
        bad "actions mode and specDir mode disagree, or the spec dir round trip is broken"
        print -e ($sd.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($sd.stdout | str trim | lines | last) | str trim)
    }

    if $fails == 0 {
        say "PASS: outputOf, early cutoff, a real DAG, and both modes agreeing"
        exit 0
    }
    say $"FAIL: ($fails) property\(ies) of dynamic derivations no longer hold"
    exit 1
}
