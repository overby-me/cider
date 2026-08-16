# ONE REAL CIDER GROUP THROUGH THE BRIDGE, artifact-compared against the lowered derivation.
#
# THIS IS THE ADAPTER SIDE and it is allowed to know about cider; nix/lib/dyn-actions.nix is
# the reusable half and must not. What it proves is the thing 1,474 groups will rest on: that a
# group's real builder script, taken verbatim, runs correctly inside an EMITTED derivation and
# produces the same bytes.
#
#   nix build .#cider-buck2-dyn-one --no-link -L
#
# WHY ONE GROUP FIRST. Generating specs for all 1,474 is mechanical once this works and
# pointless if it does not. libsimple_ciderd is the smallest honest case: 2 actions, 0
# dependencies, and a script whose store-path context is 4 entries.
#
# THE THREE THINGS AN EMITTED ACTION LACKS, all of which runCommand had supplied and none of
# which are defects in the bridge:
#
#   PATH     there is no stdenv, so nothing is on it. `tools` is NOT enough on its own, which
#            cost a false pass: the first run of this fixture reported OK while the build log
#            carried "find: command not found" and "sed: command not found" from the staging
#            preamble. nativeBuildInputs is only what the lowering ADDS to stdenv, and stdenv
#            quietly supplies findutils, gnused, gnugrep and the rest. They are listed here.
#   set -e   stdenv sets it. Without it a failing `cp` in the staging preamble would be
#            invisible and the failure would surface much later as a missing file.
#   out      the script writes to $out throughout, and an emitted action's output variable is
#            named by dyn-actions instead. Binding out to it is the whole adaptation.
#
# inferSrcs CARRIES THE INPUTS. The script names its staged tree and compilers inside the
# string, so they cannot be enumerated before the outer Nix substitutes them; see the flag's
# own toy. That is exactly the case it exists for.
{
  pkgs,
  # The lowering result: { drvs, ... }. Passed in rather than imported so this file does not
  # decide which endpoint it is talking about.
  lowered,
  # Small, real, and dependency-free. Overridable so the same fixture can be pointed at a
  # harder group once this one holds.
  label ? "root//src/darwin/libsimple:libsimple_ciderd",
}: let
  inherit (pkgs) lib;

  lowerDrv = lowered.drvs.${label};
  name = "cider-dyn-" + lib.strings.sanitizeDerivationName (lib.last (lib.splitString ":" label));

  # WHAT stdenv WOULD HAVE PUT ON PATH. nativeBuildInputs lists only what the lowering ADDS,
  # so taking it alone leaves the staging preamble without find, sed and friends. Kept as an
  # explicit list rather than pulling in stdenv, since the point of an emitted action is that
  # it does not have one.
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

  bridge = import ./dyn-actions.nix {
    inherit pkgs;
    inferSrcs = true;
    actions = [
      {
        inherit name;
        builder = "${pkgs.bash}/bin/bash";
        args = [
          "-c"
          ''
            set -e
            export PATH=${lib.makeBinPath (lowerDrv.passthru.tools ++ stdenvBasics)}
            export out="$result"

            # A MISSING COMMAND MUST NOT PASS QUIETLY. It did once: the staging preamble lost
            # find and sed, the build carried on, and the diff still matched because this
            # group's two output files did not depend on those steps. So the whole script runs
            # with its stderr teed, and a "command not found" anywhere in it is fatal even
            # though the shell was willing to continue.
            set +e
            (
              set -e
              ${lowerDrv.passthru.builderScript}
            ) 2> >(tee "$TMPDIR/stderr.log" >&2)
            rc=$?
            set -e
            if [ "$rc" != 0 ]; then
              echo "cider-dyn-one: the group script failed with $rc" >&2
              exit "$rc"
            fi
            if grep -q "command not found" "$TMPDIR/stderr.log"; then
              echo "cider-dyn-one: something was missing from PATH:" >&2
              grep "command not found" "$TMPDIR/stderr.log" >&2
              exit 1
            fi
          ''
        ];
        # The script writes into $TMPDIR and the sandbox provides one, but an emitted action
        # gets no stdenv to set it, so name it explicitly.
        env.TMPDIR = "/build";
      }
    ];
  };
in {
  inherit bridge lowerDrv;

  emitted = bridge.outputs.${name};

  # THE COMPARISON, and it is on CONTENT rather than on the output path. The two derivations
  # cannot share a path: one is a lowered runCommand and the other an emitted action with a
  # different builder and env. What must match is what they produce.
  check = pkgs.runCommand "cider-dyn-one-check" {nativeBuildInputs = [pkgs.diffutils];} ''
    echo "--- lowered: ${lowerDrv}"
    echo "--- emitted: ${bridge.outputs.${name}}"
    if ! diff -r ${lowerDrv} ${bridge.outputs.${name}}; then
      echo "FAIL: the emitted derivation did not reproduce the lowered output" >&2
      exit 1
    fi
    # Not just "diff found nothing": an empty tree on both sides would also pass that. Count
    # something that has to be there.
    n=$(find ${bridge.outputs.${name}} -type f | wc -l)
    if [ "$n" -lt 1 ]; then
      echo "FAIL: the emitted output has no files, so diff proved nothing" >&2
      exit 1
    fi
    echo "OK emitted matches lowered, $n file(s)" > $out
  '';
}
