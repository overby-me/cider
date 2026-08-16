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
  label ? "root//vendor/rust:proc-macro2",
  # Reach the same cone through specDir mode instead of `actions` mode.
  #
  # THIS IS THE ARRANGEMENT THAT SCALES, and the only one that does. `actions` mode serialises
  # every spec in the EVALUATOR, which is precisely the cost #66 exists to remove: fine for a
  # four-group cone, useless at 1,474. specDir reads pre-serialised specs off disk, so the
  # evaluator's whole job per group is one cheap producer.
  #
  # THE DIFFERENCE IS ONE RESOLVER. In `actions` mode a dependency resolves to the emitted
  # output path, interpolated into the script at eval. A spec read from a FILE cannot have
  # anything interpolated into it, so the dependency resolves to the SHELL VARIABLE the bridge
  # sets instead, and the path arrives at build time. That is what makes a generator able to
  # write these specs without knowing any output path.
  viaSpecDir ? false,
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
  # WHAT stdenv WOULD HAVE PUT ON PATH, taken from stdenv.initialPath rather than hand-picked.
  # An emitted action has no stdenv: no setup hooks, no propagation, no initialPath. The list
  # here used to be written out by hand and was missing xz, which surfaced 900 builders into a
  # full-graph build as "exec: xz: not found" in an icu action. Hand-picking asks someone to
  # know the whole of what stdenv supplies; naming initialPath asks nixpkgs.
  #
  # bintools.bintools IS STILL EXPLICIT, and separately. llvm-ar lives in the UNWRAPPED package
  # and reaches PATH only through the wrapper's setup hook, which an emitted action never runs;
  # lib.makeBinPath follows neither hooks nor propagation. Checked: closePropagation over the
  # 33 tools gives 53 packages and still no llvm.
  stdenvBasics = pkgs.stdenv.initialPath ++ [pkgs.llvmPackages.bintools.bintools];

  # MUST MATCH depVar IN dyn-actions.nix, and is written out rather than taken from the bridge
  # on purpose: a fixture that asks the thing under test what the answer is agrees with it by
  # construction. It is also needed BEFORE the bridge exists, since the scripts are what the
  # bridge is built from.
  depVarOf = name:
    "DYN_DEP_"
    + lib.stringAsChars (c:
      if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
      then c
      else "_")
    name;

  actionFor = l: let
    d = lowered.drvs.${l};
    # THE SUBSTITUTION THAT MAKES THIS A CONE. In actions mode a dependency is the emitted
    # output path, interpolated here. In specDir mode nothing can be interpolated into a spec
    # read from a file, so it is the shell variable the bridge sets and the path arrives at
    # build time. Same script otherwise, which is the point: a generator can write this.
    script =
      d.passthru.builderScriptWith (dep:
        if viaSpecDir
        then "\${" + depVarOf (actionName dep) + "}"
        else bridge.outputs.${actionName dep});
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

  authored = import ./dyn-actions.nix {
    inherit pkgs;
    inferSrcs = true;
    actions = map actionFor members;
  };

  # mkSpecDir serialises at EVAL, so it is the reference layout rather than the route a real
  # generator takes. At four groups that is irrelevant; at 1,474 it would hand back exactly the
  # cost specDir exists to avoid. What is being tested here is that the SPECS work when read
  # from a file, not how they got written.
  bridge =
    if viaSpecDir
    then
      import ./dyn-actions.nix {
        inherit pkgs;
        inferSrcs = true;
        specDir = authored.mkSpecDir "cider-dyn-cone-specs";
      }
    else authored;
in {
  inherit bridge members;

  # THE MODE IS IN THE NAME, and that is not cosmetic. The check references bridge.outputs,
  # which is a builtins.outputOf placeholder keyed on the producer NAME, and both modes name
  # their producers identically. So the two checks were BYTE IDENTICAL derivations: running the
  # specDir one reused the actions-mode result and its diff never executed, while reporting OK.
  # A check that another configuration can stand in for is not a check of this one.
  check = pkgs.runCommand "cider-dyn-cone-check-${
    if viaSpecDir
    then "specdir"
    else "actions"
  }" {nativeBuildInputs = [pkgs.diffutils];} ''
    echo "--- mode: ${
    if viaSpecDir
    then "specDir"
    else "actions"
  }"
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
