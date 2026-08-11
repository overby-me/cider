#!/usr/bin/env nu
# Do dynamic derivations still do the fourteen things #66 depends on?
#
# NOT IN THE NIX-FREE SET. This one builds, so it is slow by that standard (tens of seconds
# warm) and belongs in the deliberate-run bucket, not the 27 second pre-flight.
#
# WHY IT EXISTS. #66 replaces the evaluator-computed derivations with derivations the generator
# EMITS, which only works if fourteen properties hold. 1 to 3 are properties of NIX rather than of
# this project, verified by hand on 2026-08-11 with Nix 2.35.1; a Nix upgrade could take any of
# them away silently, and the failure would not look like "dynamic derivations regressed", it
# would look like the endpoint rebuilding everything, or an hour-long gate dying somewhere far
# away. 4 to 8 are properties of nix/lib/dyn-actions.nix, and the first two of those were false when
# first checked: the DAG edge and the whole specDir mode. Neither had a fixture, so
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
#   6. A DAG THREE LEVELS DEEP, reached through `deps`. 4 only shows an action can see the
#      thing directly beneath it with the caller threading the outputOf string by hand. A
#      generator-written spec cannot interpolate anything, so the action has to find its
#      dependency through the env the bridge sets, transitively.
#   7. A DAG THROUGH specDir, the combination a real consumer needs and the last to work.
#      specDir cannot interpolate, so the edges travel in a deps.json beside the specs. A
#      generator that omits it gets a SET, silently, every action seeing an empty dependency.
#   8. inferSrcs, for the caller whose input paths live inside an existing build SCRIPT rather
#      than in a list. Asserted in BOTH directions: a flag that does nothing and a flag that
#      fires unconditionally both pass a one-sided test.
#   9. extraEnv, so a specDir action can use a store path its SPEC NEVER NAMES. That is the
#      position a generator is in: it writes specs before any consumer path exists. The toy
#      checks the path is ABSENT from the spec as well as present at build time.
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

    # 6. THREE LEVELS, THROUGH `deps`. Property 4 only proves an action can reach the thing
    # directly beneath it, with the caller threading the outputOf string itself. cider's groups
    # are deeper than that and its generator cannot interpolate anything, so the interesting
    # case is an action reaching its dependency through the env the bridge sets, transitively,
    # without naming the level below that.
    let dag = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-dag-toy.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $dag.exit_code != 0 {
        bad "the three level DAG does not carry through"
        print -e ($dag.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($dag.stdout | str trim | lines | last) | str trim)
    }

    # 7. A DAG THROUGH specDir, which is the combination a real consumer actually needs and the
    # last one to work. `actions` mode can express a DAG easily because the caller is writing
    # Nix and can interpolate anything; specDir cannot, since the spec is a file nobody parses.
    # The edges travel in a deps.json beside the specs instead. A generator that omits it gets
    # a SET, silently: every action still emits and builds, in a plausible order, each seeing an
    # empty dependency. Verified both ways -- stripping deps.json from the spec dir yields
    # "SPECDIR-BETA saw " with nothing after it, and exit 0 from the build.
    let sdd = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-specdir-dag-toy.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $sdd.exit_code != 0 {
        bad "specDir mode cannot carry a dependency"
        print -e ($sdd.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($sdd.stdout | str trim | lines | last) | str trim)
    }

    # 8. inferSrcs FINDS WHAT THE COMMAND NAMES, and does nothing when off. For the caller
    # whose input paths live inside an existing build SCRIPT rather than in a list: string
    # context carries them, the outer Nix substitutes them when the producer runs, and there is
    # no earlier point at which they could be enumerated. The toy asserts BOTH halves, because
    # a flag that does nothing and a flag that fires unconditionally both pass a one-sided test.
    let inf = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-infer-toy.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $inf.exit_code != 0 {
        bad "inferSrcs does not behave in both directions"
        print -e ($inf.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($inf.stdout | str trim | lines | last) | str trim)
    }

    # 9. extraEnv: a specDir action using a store path its SPEC NEVER NAMES. That is the
    # position a generator is in, since it writes the specs long before any consumer path
    # exists, and it is how a toolchain, a staging script or a data tree reaches the action.
    # The toy asserts the path is absent from the spec file as well as present at build time,
    # because a spec that happened to bake it in would pass for the wrong reason.
    let xe = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-extraenv-toy.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $xe.exit_code != 0 {
        bad "extraEnv does not carry a consumer path into a specDir action"
        print -e ($xe.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($xe.stdout | str trim | lines | last) | str trim)
    }

    # 10. A SPEC DIR WRITTEN BY SOMETHING THAT IS NOT THIS BRIDGE, holding only name, builder
    # and args. That is the whole claim of specDir mode and it was untested until now: every
    # other spec dir in the repo came from mkSpecDir, so the mode had only ever been shown
    # reading files the bridge itself wrote. The system, the version, the outputs and the
    # output PLACEHOLDER are things a generator cannot honestly supply, so the fixup fills
    # them in. The toy asserts the spec files do not carry them, or it would pass while
    # testing nothing.
    let mn = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-minimal-spec-toy.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $mn.exit_code != 0 {
        bad "a spec dir not written by this bridge does not build"
        print -e ($mn.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($mn.stdout | str trim | lines | last) | str trim)
    }

    # 11. AN ACTION WHOSE SCRIPT IS TOO LONG TO PASS AS AN ARGUMENT. Linux caps a single argv
    # string at MAX_ARG_STRLEN, 131,072 bytes, which is NOT ARG_MAX and is not reached by any
    # other fixture here: every one of them is a few kilobytes. A real consumer has 89 actions
    # of 1,474 over it, the largest 5.1 MB, and both halves broke. The producer embedded the
    # spec in its OWN command line, so it died before the fixup ran; and the emitted action
    # carried the script as a -c argument. Specs go through a store file now, and an over-long
    # -c argument spills to one and becomes `. <path>`, which is equivalent for a shell.
    # The toy asserts the script really is over the limit, or it would test nothing.
    let ba = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-bigarg-toy.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $ba.exit_code != 0 {
        bad "an action whose script exceeds the per-argument limit does not build"
        print -e ($ba.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($ba.stdout | str trim | lines | last) | str trim)
    }

    # 12. A SPEC DIR WITH NO deps.json. The file is optional and its absence means no action
    # depends on another, which is a perfectly valid graph. That was a claim resting on a
    # pathExists guard until this fixture existed. The probe asserts deps.json is ABSENT
    # before building, so it cannot pass for the wrong reason.
    let nd = (do -i { ^nix build --impure -f ./nix/lib/dyn-actions-nodeps-probe.nix check --no-link --print-out-paths --extra-experimental-features $feats } | complete)
    if $nd.exit_code != 0 {
        bad "a spec dir with no deps.json does not build"
        print -e ($nd.stderr | lines | last 10 | str join "\n")
        $fails += 1
    } else {
        ok (open --raw ($nd.stdout | str trim | lines | last) | str trim)
    }

    # 13. DUPLICATE ACTION NAMES ARE REJECTED, and this one BUILDS NOTHING: it is an
    # evaluation-time assertion, so both directions are one `nix eval` each.
    #
    # WHY IT MATTERS: the name keys the consumer lookup, so two actions sharing one would
    # silently merge into a single derivation and one of them would simply never be built.
    # The assertion has been in dyn-actions.nix since the start and nothing had ever fired it,
    # which is the same as not having it.
    #
    # ASSERTED IN BOTH DIRECTIONS, because a guard that throws unconditionally would pass a
    # one-sided test: duplicates must THROW and distinct names must EVALUATE.
    let dupExpr = "(import ./nix/lib/dyn-actions.nix { pkgs = import <nixpkgs> {}; actions = [ { name = \"dup\"; builder = \"/bin/sh\"; args = [\"-c\" \"true\"]; } { name = \"dup\"; builder = \"/bin/sh\"; args = [\"-c\" \"true\"]; } ]; }).outputs"
    let okExpr = "(import ./nix/lib/dyn-actions.nix { pkgs = import <nixpkgs> {}; actions = [ { name = \"a1\"; builder = \"/bin/sh\"; args = [\"-c\" \"true\"]; } { name = \"a2\"; builder = \"/bin/sh\"; args = [\"-c\" \"true\"]; } ]; }).outputs"
    let dup = (do -i { ^nix eval --impure --json --expr $dupExpr } | complete)
    let uniq = (do -i { ^nix eval --impure --json --expr $okExpr } | complete)
    if $dup.exit_code == 0 {
        bad "two actions with the SAME name were accepted, so one would silently vanish"
        $fails += 1
    } else if $uniq.exit_code != 0 {
        bad "two actions with DISTINCT names were rejected, so the guard fires on everything"
        print -e ($uniq.stderr | lines | last 6 | str join "\n")
        $fails += 1
    } else if not ($dup.stderr | str contains "names must be unique") {
        bad "duplicates were rejected, but not by the uniqueness assertion"
        print -e ($dup.stderr | lines | last 6 | str join "\n")
        $fails += 1
    } else {
        ok "duplicate action names throw, distinct ones evaluate"
    }

    # 14. THE OTHER TWO GUARDS, which had also never been fired. Same class as 13: an
    # assertion nobody has seen reject anything is not known to reject anything.
    #
    #   outputName = "out"   must throw. It is THE constraint the whole design turns on, and
    #                        it is the one a caller is most likely to try to override.
    #   neither source       must throw, and so must BOTH, since the guard is an equality on
    #                        two null tests and one-sided testing would miss half of it.
    #
    # AND THE POSITIVE SIDE: a non-out outputName must still be accepted, or the guard is just
    # rejecting everything. Builds nothing; four evals.
    let gOut = (do -i { ^nix eval --impure --json --expr "(import ./nix/lib/dyn-actions.nix { pkgs = import <nixpkgs> {}; actions = []; outputName = \"out\"; }).outputs" } | complete)
    let gNone = (do -i { ^nix eval --impure --json --expr "(import ./nix/lib/dyn-actions.nix { pkgs = import <nixpkgs> {}; }).outputs" } | complete)
    let gBoth = (do -i { ^nix eval --impure --json --expr "(import ./nix/lib/dyn-actions.nix { pkgs = import <nixpkgs> {}; actions = []; specDir = \"/nix/store\"; }).outputs" } | complete)
    let gOk = (do -i { ^nix eval --impure --json --expr "(import ./nix/lib/dyn-actions.nix { pkgs = import <nixpkgs> {}; actions = []; outputName = \"thing\"; }).outputName" } | complete)
    mut gbad = []
    if $gOut.exit_code == 0 { $gbad = ($gbad | append "outputName=out was ACCEPTED") }
    if $gNone.exit_code == 0 { $gbad = ($gbad | append "neither actions nor specDir was ACCEPTED") }
    if $gBoth.exit_code == 0 { $gbad = ($gbad | append "both actions and specDir were ACCEPTED") }
    if $gOk.exit_code != 0 { $gbad = ($gbad | append "a NON-out outputName was rejected") }
    if ($gbad | is-not-empty) {
        bad $"the bridge guards do not hold: ($gbad | str join '; ')"
        $fails += 1
    } else {
        ok "outputName=out throws, a missing or doubled source throws, a normal outputName does not"
    }

    if $fails == 0 {
        say "PASS: outputOf, early cutoff, both modes, a DAG in each, inferSrcs, extraEnv, a foreign spec dir, an over-long argument, an optional deps.json, unique names and the argument guards"
        exit 0
    }
    say $"FAIL: ($fails) property\(ies) of dynamic derivations no longer hold"
    exit 1
}
