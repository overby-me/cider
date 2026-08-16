# DOES specDir MODE ACTUALLY WORK? Nothing in the repo had ever produced a spec directory, so
# half of nix/lib/dyn-actions.nix had been evaluated and never built. This round-trips the same
# actions through both modes and checks they agree.
#
#   nix build --impure -f nix/lib/dyn-actions-specdir-toy.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# NOTHING CIDER-SHAPED IN HERE, deliberately, same as dyn-actions-toy.nix. If this file ever
# needs to know about pins, an SDK farm or this repo's layout to keep passing, the bridge has
# stopped being general and that is the bug rather than the test.
#
# WHY BOTH MODES IN ONE FIXTURE. The two are supposed to be the same function reached two ways:
# `actions` serialises each spec in the evaluator, `specDir` reads pre-serialised ones off disk
# so the evaluator never touches them. If they disagree, a consumer that develops against the
# convenient mode and ships the scalable one gets different derivations, which is the kind of
# difference that shows up as an unexplained full rebuild.
#
# THE STRONGEST CHECK HERE IS THE PATH EQUALITY, not the file contents: both modes must resolve
# to the SAME output path. Contents can match while the derivations differ, and it is the
# derivation identity that decides whether anything downstream rebuilds.
{pkgs ? import <nixpkgs> {}}: let
  # Bump to force fresh derivations rather than reading a cached answer.
  stamp = "sd1";

  toyActions = [
    {
      name = "sd-alpha-${stamp}";
      builder = "/bin/sh";
      args = ["-c" "echo ALPHA-${stamp} > $result"];
    }
    {
      # Carries env, because an action that cannot take env is not much of an action and the
      # env has to survive the extra hop through a file.
      name = "sd-beta-${stamp}";
      builder = "/bin/sh";
      args = ["-c" "printf 'BETA %s\\n' \"$FLAVOUR\" > $result"];
      env = {FLAVOUR = "via-${stamp}";};
    }
  ];

  viaActions = import ./dyn-actions.nix {
    inherit pkgs;
    actions = toyActions;
  };

  # The same list written out as specDir mode expects to read it back.
  specs = viaActions.mkSpecDir "dyn-actions-specdir-toy-specs";

  viaDir = import ./dyn-actions.nix {
    inherit pkgs;
    specDir = specs;
  };

  aName = "sd-alpha-${stamp}";
  bName = "sd-beta-${stamp}";
in {
  inherit specs;

  check = pkgs.runCommand "dyn-actions-specdir-toy" {} ''
    echo "--- specDir mode, alpha:"; cat ${viaDir.outputs.${aName}}
    echo "--- specDir mode, beta:";  cat ${viaDir.outputs.${bName}}

    # SAME OUTPUT PATH FROM BOTH MODES. This is the real assertion: equal contents would not
    # rule out two different derivations that happen to print the same thing.
    if [ "${viaActions.outputs.${aName}}" != "${viaDir.outputs.${aName}}" ]; then
      echo "FAIL: alpha differs between actions mode and specDir mode" >&2
      echo "  actions: ${viaActions.outputs.${aName}}" >&2
      echo "  specDir: ${viaDir.outputs.${aName}}" >&2
      exit 1
    fi
    if [ "${viaActions.outputs.${bName}}" != "${viaDir.outputs.${bName}}" ]; then
      echo "FAIL: beta differs between actions mode and specDir mode" >&2
      exit 1
    fi

    # And the env really did survive the round trip through the file.
    if ! grep -q "BETA via-${stamp}" ${viaDir.outputs.${bName}}; then
      echo "FAIL: env did not survive the spec dir round trip" >&2
      exit 1
    fi

    echo "OK both modes agree, and env survived" > $out
  '';
}
