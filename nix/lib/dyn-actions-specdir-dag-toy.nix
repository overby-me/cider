# A DAG THROUGH specDir MODE, which is the combination a real consumer needs and the one that
# was impossible until the dependency injection moved into the producer.
#
#   nix build --impure -f nix/lib/dyn-actions-specdir-dag-toy.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# NOTHING CIDER-SHAPED IN HERE, same rule as the other toys.
#
# WHY THIS IS THE INTERESTING CASE. `actions` mode can express a DAG easily: the caller is
# writing Nix, so it can interpolate another action's outputOf string wherever it likes.
# specDir mode cannot. The spec is a FILE the producer copies without anyone parsing it, so
# there is no point at which the evaluator could inject a dependency into it. That is exactly
# the position a generator is in -- it writes specs inside a derivation, long before any
# consumer output path exists -- and it is the mode that scales, so it is the mode that matters.
#
# HOW IT IS SOLVED, and the shape a generator must copy: the edges live in a deps.json beside
# the specs, the bridge turns each into an env entry on the PRODUCER whose value is the
# dependency's outputOf placeholder, and dyn-actions-spec-fixup.py writes it into the spec as
# both a source and a DYN_DEP_<name> env entry once Nix has substituted the real path.
#
# A GENERATOR THAT FORGETS deps.json GETS A SET, NOT A DAG, silently: every action still emits
# and builds, in an order that looks plausible, and each one sees an empty dependency. That is
# why this fixture checks the CONTENT of the whole chain.
{pkgs ? import <nixpkgs> {}}: let
  # Bump to force fresh derivations rather than reading a cached answer.
  stamp = "sdd1";

  a = "sdd-alpha-${stamp}";
  b = "sdd-beta-${stamp}";

  # Built in `actions` mode purely to get a spec dir written in the right layout. A real
  # consumer writes this directory from its own generator instead; mkSpecDir is the reference
  # for the format, not the recommended route at scale.
  authored = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [
      {
        name = a;
        builder = "/bin/sh";
        args = ["-c" "echo SPECDIR-ALPHA > $result"];
      }
      {
        name = b;
        builder = "/bin/sh";
        args = ["-c" ("read L < \"$" + depVarOf a + "\"; echo \"SPECDIR-BETA saw $L\" > $result")];
        deps = [a];
      }
    ];
  };

  # Spelled out rather than taken from `authored`, because taking it from the thing under test
  # would make the fixture agree with itself by construction.
  depVarOf = name:
    "DYN_DEP_"
    + pkgs.lib.stringAsChars (c:
      if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
      then c
      else "_")
    name;

  specs = authored.mkSpecDir "dyn-actions-specdir-dag-specs";

  # THE ACTUAL SUBJECT: the same DAG reached only through the written directory.
  viaDir = import ./dyn-actions.nix {
    inherit pkgs;
    specDir = specs;
  };
in {
  inherit specs viaDir;

  check = pkgs.runCommand "dyn-actions-specdir-dag-toy" {} ''
    got=$(cat ${viaDir.outputs.${b}})
    echo "--- specDir beta says: $got"
    if [ "$got" != "SPECDIR-BETA saw SPECDIR-ALPHA" ]; then
      echo "FAIL: the dependency did not carry through specDir mode" >&2
      echo "  wanted: SPECDIR-BETA saw SPECDIR-ALPHA" >&2
      echo "  got:    $got" >&2
      exit 1
    fi

    # deps.json has to BE there, since its absence is the silent-failure mode.
    if [ ! -e ${specs}/deps.json ]; then
      echo "FAIL: mkSpecDir wrote no deps.json, so any DAG through it is a set" >&2
      exit 1
    fi

    echo "OK specDir DAG: $got" > $out
  '';
}
