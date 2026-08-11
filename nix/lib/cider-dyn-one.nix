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
#   PATH     there is no stdenv, so nothing is on it. `tools` is the same list the lowered
#            derivation puts in nativeBuildInputs, so the commands resolve identically.
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
  label ? "root//darwin/libsimple:libsimple_ciderd",
}: let
  inherit (pkgs) lib;

  lowerDrv = lowered.drvs.${label};
  name = "cider-dyn-" + lib.strings.sanitizeDerivationName (lib.last (lib.splitString ":" label));

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
            export PATH=${lib.makeBinPath lowerDrv.passthru.tools}
            export out="$result"
            ${lowerDrv.passthru.builderScript}
          ''
        ];
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
