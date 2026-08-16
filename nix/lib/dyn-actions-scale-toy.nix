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
# MEASURED 2026-08-11 ON A QUIET MACHINE, 22 cores. THESE ARE THE REAL NUMBERS:
#
#     n=64   7.00 s      n=128   9.49 s      n=256  14.12 s
#
#   64 -> 128    64 more producers, +2.50 s   0.039 s each
#   128 -> 256  128 more producers, +4.63 s   0.036 s each
#
# So about 0.037 s per emitted action. AT CIDER'S 1,474 GROUPS THAT IS ABOUT 55 SECONDS of
# build, against the ~12.95 s of evaluation that computing those derivations costs. Paid once
# per graph change rather than per invocation, because the producers are content addressed and
# only re-run when their own spec moves, so it breaks even after four or five evaluations.
# That makes #66's endgame clearly worth building. Even one producer per ACTION, 8,704 of them,
# would be about five and a half minutes rather than the 83 the first measurement implied.
#
# AND THE FIRST MEASUREMENT SAID 0.57 s, FIFTEEN TIMES TOO HIGH, which is worth keeping because
# of how it went wrong rather than for the number. It was taken alongside gate16, which had
# every core busy, so the producers could not overlap and the run measured contention. It came
# out convincingly LINEAR and gave 14 minutes at cider size, which would have argued the
# endgame does not pay for itself. Same fixture, same slope method, quiet machine, and the
# conclusion reverses.
#
# THE TELL WAS ALREADY IN THE DATA and was noticed before the re-run: n=4 measured SLOWER than
# n=16, which only happens if the producers were overlapping. A per-item cost that is really
# scheduling contention looks exactly like a per-item cost until you take the load away.
# NEVER PRICE A PARALLEL THING ON A BUSY MACHINE.
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
