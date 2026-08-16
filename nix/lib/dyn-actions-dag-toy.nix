# A THREE-LEVEL DAG THROUGH THE BRIDGE, using `deps` rather than hand-threaded outputOf
# strings. NOTHING CIDER-SHAPED IN HERE, same rule as the other toys.
#
#   nix build --impure -f nix/lib/dyn-actions-dag-toy.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# WHY A THIRD LEVEL. Two levels only prove an action can reach the thing directly beneath it.
# Cider's groups are deeper than that, and the interesting failure is TRANSITIVE: gamma must
# see beta, beta must see alpha, and gamma must NOT need to know alpha exists. A two-level
# fixture passes whether or not that holds.
#
# WHY `deps` RATHER THAN inputSrcs. Both work -- dyn-actions-dep-probe.nix uses inputSrcs and
# is the minimal statement of the mechanism. `deps` names other ACTIONS instead of store paths,
# and the bridge turns each into both a source AND a DYN_DEP_<name> entry in the emitted
# action's env, so the action can find its dependency without the caller interpolating
# anything. That matters most where the caller CANNOT interpolate: a spec read from a file.
#
# CONCATENATION, NOT ESCAPING, for the variable reference. `"$${x}"` does NOT give a dollar
# followed by an interpolation: Nix reads `$${` as an escape for a LITERAL `${`, so the emitted
# spec contained the text ${bridge.depVar a} and the action read an unset variable. It expands
# to empty rather than failing, so the build succeeded and produced nothing, which is why this
# fixture checks the CONTENT of the whole chain.
#
# THE ENV ROUTE IS WHAT IS BEING TESTED, deliberately. Each action reads $DYN_DEP_<dep> rather
# than a path baked into its args, because that is the route a generator-written spec has to
# use. Shell builtins only: an emitted action gets no PATH.
{pkgs ? import <nixpkgs> {}}: let
  # Bump to force fresh derivations rather than reading a cached answer.
  stamp = "dag1";

  a = "dag-alpha-${stamp}";
  b = "dag-beta-${stamp}";
  g = "dag-gamma-${stamp}";

  bridge = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [
      {
        name = a;
        builder = "/bin/sh";
        args = ["-c" "echo ALPHA > $result"];
      }
      {
        name = b;
        builder = "/bin/sh";
        # Reads alpha THROUGH THE ENV the bridge sets, not through an interpolated path.
        args = ["-c" ("read L < \"$" + bridge.depVar a + "\"; echo \"BETA saw $L\" > $result")];
        deps = [a];
      }
      {
        # Depends only on beta. If the bridge is doing its job, gamma reaches alpha's content
        # transitively through beta's output and never names alpha itself.
        name = g;
        builder = "/bin/sh";
        args = ["-c" ("read L < \"$" + bridge.depVar b + "\"; echo \"GAMMA saw [$L]\" > $result")];
        deps = [b];
      }
    ];
  };
in {
  inherit bridge;

  check = pkgs.runCommand "dyn-actions-dag-toy" {} ''
    got=$(cat ${bridge.outputs.${g}})
    echo "--- gamma says: $got"
    # The whole chain in one string: gamma saw beta saw alpha. Anything less means a level of
    # the DAG silently produced nothing, which an exit-code check would not notice because a
    # failed `read` still leaves a file behind.
    if [ "$got" != "GAMMA saw [BETA saw ALPHA]" ]; then
      echo "FAIL: the three-level chain did not carry through" >&2
      echo "  wanted: GAMMA saw [BETA saw ALPHA]" >&2
      echo "  got:    $got" >&2
      exit 1
    fi
    echo "OK three-level DAG: $got" > $out
  '';
}
