# DOES inferSrcs FIND WHAT THE COMMAND NAMES, and does it stay off when it is off? Both halves
# in one build, because the interesting failure is a flag that does nothing and a flag that
# does something unconditionally, and neither is visible from one run.
#
#   nix build --impure -f nix/lib/dyn-actions-infer-toy.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# NOTHING CIDER-SHAPED IN HERE, same rule as the other toys.
#
# WHAT IT IS FOR. A caller assembling an action out of an EXISTING build script has its input
# paths inside the string rather than in a list. Nix string context carries them, the outer Nix
# substitutes real paths when the producer runs, and there is no earlier point at which the
# caller could enumerate them: at eval they are outputOf placeholders, and mangling that text to
# extract them is what makes the substitution stop happening. inferSrcs reads them back out of
# the finished args instead.
#
# THE TWO ACTIONS ARE IDENTICAL EXCEPT FOR THE FLAG. Neither declares inputSrcs and neither
# declares deps; each names the dependency's output in its args and nowhere else. So the flag
# is the only thing that can account for a difference, which is what makes this a control
# rather than a demonstration.
{pkgs ? import <nixpkgs> {}}: let
  # Bump to force fresh derivations rather than reading a cached answer.
  stamp = "inf3";

  a = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [
      {
        name = "infer-src-${stamp}";
        builder = "/bin/sh";
        args = ["-c" "echo INFERRED-${stamp} > $result"];
      }
    ];
  };
  aOut = a.outputs."infer-src-${stamp}";

  # Shell builtins only: an emitted action gets no PATH, so anything external confounds it.
  reader = name:
    "if [ -e ${aOut} ]; then read L < ${aOut}; echo \"SAW $L\" > $result; else echo BLIND > $result; fi";

  off = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [
      {
        name = "infer-off-${stamp}";
        builder = "/bin/sh";
        args = ["-c" (reader "off")];
      }
    ];
  };

  on = import ./dyn-actions.nix {
    inherit pkgs;
    inferSrcs = true;
    actions = [
      {
        name = "infer-on-${stamp}";
        builder = "/bin/sh";
        args = ["-c" (reader "on")];
      }
    ];
  };
in {
  check = pkgs.runCommand "dyn-actions-infer-toy" {} ''
    offSaid=$(cat ${off.outputs."infer-off-${stamp}"})
    onSaid=$(cat ${on.outputs."infer-on-${stamp}"})
    echo "--- inferSrcs off: $offSaid"
    echo "--- inferSrcs on:  $onSaid"

    # ON must find it, and find the CONTENT: a path can exist and be empty.
    if [ "$onSaid" != "SAW INFERRED-${stamp}" ]; then
      echo "FAIL: inferSrcs did not make the named path available" >&2
      exit 1
    fi
    # OFF must NOT. Without this the flag could be doing nothing and the test would still pass,
    # because dyn-actions might be declaring everything anyway.
    if [ "$offSaid" != "BLIND" ]; then
      echo "FAIL: the path was available WITHOUT inferSrcs, so the flag proves nothing" >&2
      echo "  off said: $offSaid" >&2
      exit 1
    fi
    echo "OK inferSrcs: on=$onSaid off=$offSaid" > $out
  '';
}
