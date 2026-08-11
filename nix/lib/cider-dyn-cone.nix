# A WHOLE DEPENDENCY CONE THROUGH THE BRIDGE, with nothing coming from the lowering.
#
#   nix build .#cider-buck2-dyn-cone --no-link -L \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# WHAT THIS ADDS OVER cider-dyn-one. That fixture emits ONE group and lets its dependencies
# come from the lowered derivations, which proves the script, PATH and output-variable
# adaptation and nothing about the DAG. Here every group in the transitive cone is emitted, and
# a dependency resolves to another EMITTED output. That is the arrangement the full adapter
# uses, so it is the one that has to be shown working before generating 1,474 of them.
#
# THE ONE THING THAT HAD TO CHANGE IN THE LOWERING is builderScriptWith. The lowered script
# bakes in `cp -a ${drvs.<dep>}/. .`, a LOWERED path, so it cannot simply be reused: an emitted
# cone has to copy from the emitted dependency instead. That is the only place a dependency
# path enters the script, so parameterising it is a one-line knob rather than a rewrite.
#
# THE KNOT IS TIED THROUGH `bridge` ITSELF: an action's script names bridge.outputs of its
# dependencies, and bridge is what that list defines. Nix is lazy so this resolves, and it
# resolves only because the group graph is ACYCLIC, which the generator checks. A cycle here
# surfaces as a bare infinite recursion naming neither group.
{
  pkgs,
  lowered,
  # SMALL AND REAL by default: proc-macro2 is one action over a cone of exactly one other
  # group, two actions in total. The smallest case that is not the empty cone cider-dyn-one
  # already covers.
  label ? "root//buck-rust:proc-macro2",
}: let
  inherit (pkgs) lib;

  actionName = l: "cider-cone-" + lib.strings.sanitizeDerivationName (lib.last (lib.splitString ":" l));

  # The transitive cone, the group itself last. Order does not matter to dyn-actions, which
  # takes a set and wires edges by name, but computing it explicitly is what makes the
  # membership check below possible.
  coneOf = l: let
    direct = lowered.drvs.${l}.passthru.deps;
  in
    lib.unique (lib.concatMap (d: coneOf d ++ [d]) direct);

  members = coneOf label ++ [label];

  # WHAT stdenv WOULD HAVE PUT ON PATH, same list and same reason as cider-dyn-one: passthru
  # tools is only what the lowering ADDS to stdenv, and an emitted action has no stdenv.
  stdenvBasics = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.gnutar
    pkgs.gzip
    pkgs.diffutils
    pkgs.patch
    pkgs.bash
  ];

  actionFor = l: let
    d = lowered.drvs.${l};
    # THE SUBSTITUTION THAT MAKES THIS A CONE: a dependency is the emitted output, not the
    # lowered derivation.
    script = d.passthru.builderScriptWith (dep: bridge.outputs.${actionName dep});
  in {
    name = actionName l;
    builder = "${pkgs.bash}/bin/bash";
    deps = map actionName d.passthru.deps;
    env.TMPDIR = "/build";
    args = [
      "-c"
      ''
        set -e
        export PATH=${lib.makeBinPath (d.passthru.tools ++ stdenvBasics)}
        export out="$result"
        set +e
        (
          set -e
          ${script}
        ) 2> >(tee "$TMPDIR/stderr.log" >&2)
        rc=$?
        set -e
        if [ "$rc" != 0 ]; then
          echo "cider-dyn-cone: ${l} failed with $rc" >&2
          exit "$rc"
        fi
        # A missing command must not pass quietly: it did once in cider-dyn-one, and the diff
        # still matched because the group did not depend on the step that failed.
        if grep -q "command not found" "$TMPDIR/stderr.log"; then
          echo "cider-dyn-cone: ${l} was missing something from PATH:" >&2
          grep "command not found" "$TMPDIR/stderr.log" >&2
          exit 1
        fi
      ''
    ];
  };

  bridge = import ./dyn-actions.nix {
    inherit pkgs;
    inferSrcs = true;
    actions = map actionFor members;
  };
in {
  inherit bridge members;

  check = pkgs.runCommand "cider-dyn-cone-check" {nativeBuildInputs = [pkgs.diffutils];} ''
    echo "--- cone members: ${toString (lib.length members)}"
    echo "--- lowered: ${lowered.drvs.${label}}"
    echo "--- emitted: ${bridge.outputs.${actionName label}}"
    if ! diff -r ${lowered.drvs.${label}} ${bridge.outputs.${actionName label}}; then
      echo "FAIL: the emitted cone did not reproduce the lowered output" >&2
      exit 1
    fi
    # THE CONE HAS TO BE MORE THAN THE GROUP, or this is cider-dyn-one under another name and
    # proves nothing new about dependencies.
    if [ "${toString (lib.length members)}" -lt 2 ]; then
      echo "FAIL: the cone is just the group itself, so no dependency was emitted" >&2
      exit 1
    fi
    n=$(find ${bridge.outputs.${actionName label}} -type f | wc -l)
    if [ "$n" -lt 1 ]; then
      echo "FAIL: the emitted output has no files, so diff proved nothing" >&2
      exit 1
    fi
    echo "OK emitted cone of ${toString (lib.length members)} matches lowered, $n file(s)" > $out
  '';
}
