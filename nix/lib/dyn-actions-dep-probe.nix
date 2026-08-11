# CAN ONE EMITTED DERIVATION CONSUME ANOTHER ONE'S OUTPUT? YES, since 2026-08-11, and this is
# the probe that established both the NO and then the YES. It stays in the repo because it is
# the property #66's endpoint binding rests on, and a claim like that has to stay re-runnable.
#
#   nix build --impure -f nix/lib/dyn-actions-dep-probe.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# It must print   B-SEES-A [A-RAN-<stamp>]   which is B reading the CONTENT of A's output, not
# merely finding the path. B-BLIND means the dependency edge is gone again.
#
# WHAT WAS ACTUALLY WRONG, because it was two bugs stacked and the first hid the second.
#
# 1. inputs.srcs WANTS STORE-DIR-RELATIVE NAMES. The version 4 format `nix derivation add`
#    reads wants `<hash>-<name>`, not `/nix/store/<hash>-<name>`; given a full path it fails
#    with "contains illegal base-32 character '/'". dyn-actions.nix passed inputSrcs through
#    whole, so NO declared source ever worked. Nothing noticed, because the toy actions
#    declare none. Confirmed by feeding `nix derivation add` both forms directly.
#
# 2. THE CONVERSION CANNOT HAPPEN AT EVAL TIME. A source may be another action's output, which
#    at eval is a builtins.outputOf PLACEHOLDER; the outer Nix substitutes the real path only
#    when the producer runs, and it matches the placeholder TEXT exactly. Calling baseNameOf on
#    it, or discarding its context, mangles that text, the substitution never happens, and the
#    emitted drv names a path that "is not valid". So the producer strips the store directory
#    itself, after substitution. Both failure modes were measured, not reasoned about.
#
# THE OTHER HALF ALREADY WORKED: builtins.outputOf yields exactly the placeholder the drv
# format wants, so the ARGS never needed anything. Only the declaration was missing.
#
# ORDERING IS NOT AN INPUT, which is what made the first result confusing. Before the fix, A
# was still realised BEFORE B, so the edge LOOKED honoured, and B was blind anyway. A was
# realised only because B's PRODUCER carries A's outputOf string in its own args and that
# string has context. A dependency you can see in the build order is not a dependency the
# sandbox has.
#
# THREE EARLIER RUNS PROVED NOTHING and every failure was the probe's own:
#   probe1  bare `cat`: the emitted sandbox has no PATH.       "sh: cat: not found"
#   probe2  ${pkgs.coreutils}/bin/cat: no coreutils either,    same error, full path
#           because inputSrcs was never declared.
#   probe3  shell builtins, no inputSrcs declared:             B-BLIND, the real answer.
# Only shell BUILTINS answer the question without dragging in something that can fail on its
# own. `[ -e ]` and `read` are builtins; nothing else here is.
{pkgs ? import <nixpkgs> {}}: let
  # Bump to re-run against fresh derivations rather than reading a cached answer.
  stamp = "probe6";

  a = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [
      {
        name = "dep-a-${stamp}";
        builder = "/bin/sh";
        args = ["-c" "echo A-RAN-${stamp} > $result"];
      }
    ];
  };

  aOut = a.outputs."dep-a-${stamp}";

  b = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [
      {
        name = "dep-b-${stamp}";
        builder = "/bin/sh";
        # SHELL BUILTINS ONLY, and it reads the CONTENT rather than just testing the path:
        # a path can exist and be empty, which would pass a weaker check for the wrong reason.
        args = [
          "-c"
          "if [ -e ${aOut} ]; then read L < ${aOut}; echo \"B-SEES-A [$L]\" > $result; else echo B-BLIND > $result; fi"
        ];
        # THE WHOLE FIX, on the caller's side: declare it. Without this line the same probe
        # prints B-BLIND, which is the negative control and is worth re-running after any
        # change to specOf or producerOf.
        inputSrcs = [aOut];
      }
    ];
  };

  bOut = b.outputs."dep-b-${stamp}";
in {
  inherit aOut bOut;

  check = pkgs.runCommand "dyn-actions-dep-probe" {} ''
    echo "--- B says:"
    cat ${bOut}
    cp ${bOut} $out
  '';
}
