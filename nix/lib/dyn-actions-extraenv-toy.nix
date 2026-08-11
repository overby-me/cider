# CAN A specDir ACTION USE A STORE PATH ITS SPEC NEVER NAMES? That is what a generator needs:
# it writes the specs long before any consumer path exists, so a toolchain, a staging script or
# a data tree cannot be interpolated into them.
#
#   nix build --impure -f nix/lib/dyn-actions-extraenv-toy.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# NOTHING CIDER-SHAPED IN HERE, same rule as the other toys.
#
# THE SPEC IS WRITTEN WITHOUT THE PATH, which is the whole point and is enforced rather than
# described: the action's script says ${TOY_DATA} and the toy asserts that the store path does
# NOT appear anywhere in the spec file it hands to specDir mode. If it leaked in, the test would
# pass for the wrong reason and prove nothing about a generator.
#
# ASSERTED IN BOTH DIRECTIONS. With extraEnv the action reads the file; without it the variable
# is unset and the action reports BLIND. A flag that does nothing and a flag that fires
# unconditionally both pass a one-sided test.
{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) lib;

  # Bump to force fresh derivations rather than reading a cached answer.
  stamp = "xe1";

  # Stands in for whatever a consumer supplies and a generator cannot know.
  payload = pkgs.writeText "toy-payload-${stamp}" "PAYLOAD-${stamp}";

  action = name: {
    inherit name;
    builder = "/bin/sh";
    # Shell builtins only: an emitted action gets no PATH.
    args = [
      "-c"
      ''
        if [ -n "$TOY_DATA" ] && [ -e "$TOY_DATA" ]; then
          read L < "$TOY_DATA"
          echo "SAW $L" > $result
        else
          echo BLIND > $result
        fi
      ''
    ];
  };

  authored = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [(action "xe-with-${stamp}")];
  };
  specs = authored.mkSpecDir "dyn-actions-extraenv-specs-${stamp}";

  withEnv = import ./dyn-actions.nix {
    inherit pkgs;
    specDir = specs;
    extraEnv.TOY_DATA = "${payload}";
  };

  authoredOff = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [(action "xe-without-${stamp}")];
  };
  specsOff = authoredOff.mkSpecDir "dyn-actions-extraenv-specs-off-${stamp}";

  withoutEnv = import ./dyn-actions.nix {
    inherit pkgs;
    specDir = specsOff;
  };
in {
  inherit specs withEnv withoutEnv;

  check = pkgs.runCommand "dyn-actions-extraenv-toy" {} ''
    on=$(cat ${withEnv.outputs."xe-with-${stamp}"})
    off=$(cat ${withoutEnv.outputs."xe-without-${stamp}"})
    echo "--- extraEnv on:  $on"
    echo "--- extraEnv off: $off"

    # THE SPEC MUST NOT CONTAIN THE PATH. Without this the whole thing could be passing because
    # mkSpecDir happened to bake it in, which is exactly what a generator cannot do.
    if grep -q "${payload}" ${specs}/*.json; then
      echo "FAIL: the spec names the payload path, so this proves nothing about specDir" >&2
      exit 1
    fi

    if [ "$on" != "SAW PAYLOAD-${stamp}" ]; then
      echo "FAIL: extraEnv did not make the path readable, got: $on" >&2
      exit 1
    fi
    if [ "$off" != "BLIND" ]; then
      echo "FAIL: the path was readable WITHOUT extraEnv, so the mechanism proves nothing" >&2
      echo "  off said: $off" >&2
      exit 1
    fi
    echo "OK extraEnv: on=$on off=$off, and the spec never named the path" > $out
  '';
}
