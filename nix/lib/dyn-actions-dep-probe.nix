# CAN ONE EMITTED DERIVATION CONSUME ANOTHER ONE'S OUTPUT? Measured 2026-08-11: NO, not as
# nix/lib/dyn-actions.nix stands. This is the probe that established it, kept in the repo
# rather than in a scratch directory because it is the thing standing between #66 and the
# endpoint binding through builtins.outputOf, and a claim like that has to stay re-runnable.
#
#   nix build --impure -f nix/lib/dyn-actions-dep-probe.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# WHAT HAPPENS. Two emitted actions, B naming A's output via a.outputs.<name>, which is
# builtins.outputOf. Both emit. Both build. A is realised BEFORE B, so something about the
# edge is honoured. And then B reports B-BLIND: A's output is not present inside B's build.
#
# WHY, and it is one line in dyn-actions.nix: specOf always writes `inputs.drvs = {}`. The
# emitted derivation therefore declares no dependency on anything. A gets realised only
# because the PRODUCER of B has A's outputOf string in its own args, and that string carries
# context, so Nix realises A to compute B's spec text. The emitted B never declares it, so the
# sandbox does not have it. Ordering is not the same thing as an input.
#
# WHAT WOULD FIX IT, from what the probe shows rather than from theory. The placeholder in B's
# args is already the right string: builtins.outputOf produces exactly the downstream
# placeholder the drv format wants. The missing half is `inputs.drvs`, which has to name A's
# EMITTED drv path and the output name. That path exists but is not currently kept: producerOf
# does `emitted=$(nix derivation add < spec.json); cp "$emitted" "$out"`, so its output is a
# COPY of the drv and the real path is thrown away. A producer that recorded it, and a
# dependent producer that took the dependency's producer as an input and patched its own spec
# before calling `derivation add`, would close it -- and would keep the per-action early
# cutoff, since an unchanged dependency leaves its producer's output unchanged.
#
# TWO EARLIER RUNS OF THIS PROBE PROVED NOTHING, and both failures were the probe's:
#   probe1  used bare `cat`, and the emitted sandbox has no PATH: "sh: cat: not found".
#   probe2  used ${pkgs.coreutils}/bin/cat, and the emitted sandbox does not have coreutils
#           either, because inputSrcs was never declared: same error with a full path.
# Only shell BUILTINS answer the question without dragging in something else that can fail.
# `[ -e ]` and `read` are builtins; nothing else here is.
{pkgs ? import <nixpkgs> {}}: let
  # Bump to re-run against fresh derivations rather than reading a cached answer.
  stamp = "probe3";

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
        # SHELL BUILTINS ONLY. Anything external confounds the question, as probes 1 and 2
        # showed. This answers exactly one thing: is the dependency's output PRESENT here?
        args = [
          "-c"
          "if [ -e ${aOut} ]; then read L < ${aOut}; echo \"B-SEES-A [$L]\" > $result; else echo B-BLIND > $result; fi"
        ];
      }
    ];
  };

  bOut = b.outputs."dep-b-${stamp}";
in {
  inherit aOut bOut;

  # Realising this forces B, which forces A if the edge is expressed at all. Prints what B
  # concluded. Currently B-BLIND; the day it says B-SEES-A, the bridge can express a DAG.
  check = pkgs.runCommand "dyn-actions-dep-probe" {} ''
    echo "--- B says:"
    cat ${bOut}
    cp ${bOut} $out
  '';
}
