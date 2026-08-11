# WHAT DOES ONE EMITTED ACTION COST TO BUILD? #66 replaces evaluator-computed derivations with
# emitted ones, and every emitted action costs a PRODUCER derivation that runs `nix derivation
# add` inside a recursive-nix sandbox. At cider's 1,474 groups that per-producer cost is
# multiplied by 1,474, so if it is a second each the endgame trades ~12 s of evaluation for
# ~25 minutes of build and is not worth doing. This measures it instead of assuming.
#
#   nix build --impure -f nix/lib/dyn-actions-scale-toy.nix check --no-link --argstr n 20 \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# NOTHING CIDER-SHAPED IN HERE. The actions are trivial on purpose: the point is to price the
# BRIDGE, not the work. An action that compiles something would hide the producer cost inside
# its own, which is the opposite of what this is for.
#
# TIME IT FROM OUTSIDE. The `check` derivation cannot time its own dependencies. Compare two
# values of n rather than reading one: the fixed cost of the outer build is not small relative
# to a handful of trivial producers, so a single number over-states the per-action cost. That
# is not a detail -- n=4 measured SLOWER than n=16 here, because at that size the answer is
# entirely fixed cost and scheduling noise.
#
# MEASURED 2026-08-11, alongside gate16, so these are an UPPER bound and want redoing quiet:
#
#     n=4     9.9 s        n=16    8.9 s
#     n=64   36.5 s        n=128  72.8 s
#
#   16 -> 64    48 more producers, +27.6 s   0.575 s each
#   64 -> 128   64 more producers, +36.3 s   0.567 s each
#
# So about 0.57 s per emitted action, and LINEAR at this size rather than parallel. AT CIDER'S
# 1,474 GROUPS THAT IS ABOUT 14 MINUTES OF BUILD, to save the ~12.95 s of evaluation that
# computing those derivations costs. It is paid once per graph change rather than per
# invocation, because the producers are content addressed and only re-run when their own spec
# moves, so it amortises over repeated builds -- roughly 65 evaluations to break even.
#
# THAT IS THE NUMBER #66's ENDGAME HAS TO ANSWER TO, and it is worth knowing before the adapter
# is written rather than after. It does not say the endgame is wrong: the eval saving is per
# invocation and the producer cost is per change. It does say a design that emits one producer
# per ACTION rather than per group, 8,704 of them, would cost about 83 minutes and cannot pay
# for itself here.
#
# `stamp` must change to force real work. Reusing it measures the store's ability to do
# nothing, which is fast and meaningless -- the same trap buck-dyndrv-check.nu guards with its
# never-used knob values.
{
  pkgs ? import <nixpkgs> {},
  n ? "8",
  stamp ? "s1",
}: let
  count = if builtins.isInt n then n else pkgs.lib.toInt n;

  actions =
    map (i: {
      name = "scale-${stamp}-${toString i}";
      builder = "/bin/sh";
      args = ["-c" "echo SCALE ${stamp} ${toString i} > $result"];
    }) (builtins.genList (x: x) count);

  bridge = import ./dyn-actions.nix {inherit pkgs actions;};

  names = map (a: a.name) actions;
in {
  inherit bridge;

  # Realising this forces every producer and every emitted derivation.
  check = pkgs.runCommand "dyn-actions-scale-${stamp}-${toString count}" {} ''
    ${pkgs.lib.concatMapStrings (nm: ''
        cat ${bridge.outputs.${nm}} >> tally
      '')
      names}
    lines=$(wc -l < tally)
    if [ "$lines" != "${toString count}" ]; then
      echo "FAIL: expected ${toString count} outputs, got $lines" >&2
      exit 1
    fi
    echo "OK ${toString count} emitted actions realised" > $out
  '';
}
