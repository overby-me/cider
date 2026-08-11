# CAN A SPEC DIR BE WRITTEN BY SOMETHING THAT IS NOT THIS BRIDGE? That is the whole claim of
# specDir mode, and until this existed it was untested: every spec dir in the repo came from
# mkSpecDir, so the mode was only ever shown reading files the bridge itself had written.
#
#   nix build --impure -f nix/lib/dyn-actions-minimal-spec-toy.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# NOTHING CIDER-SHAPED IN HERE, same rule as the other toys.
#
# THE SPEC HOLDS THREE FIELDS: name, builder, args. No system, no version, no outputs, and no
# env. A generator cannot supply those honestly: the output placeholder is a Nix construction
# and the system belongs to whoever is building, not to whoever wrote the graph. The bridge
# fills them in when the producer runs.
#
# THE FILES ARE WRITTEN WITH toJSON AND NOTHING FROM dyn-actions.nix, on purpose. Using
# mkSpecDir here would test the bridge against its own output again and prove nothing new.
{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) lib;

  stamp = "min2";

  # THE MINIMUM A GENERATOR CAN KNOW. Note it names its output through $result, which is the
  # bridge's outputName: an emitted action has no `out`.
  minimalSpec = name: text:
    builtins.toJSON {
      inherit name;
      builder = "/bin/sh";
      args = ["-c" text];
    };

  a = "min-a-${stamp}";
  b = "min-b-${stamp}";

  specs = pkgs.runCommand "dyn-actions-minimal-specs-${stamp}" {} ''
    mkdir -p "$out"
    cat > "$out/${a}.json" <<'JSON'
    ${minimalSpec a "echo MINIMAL-A > $result"}
    JSON
    cat > "$out/${b}.json" <<'JSON'
    ${minimalSpec b "read L < \"$DYN_DEP_${builtins.replaceStrings ["-"] ["_"] a}\"; echo \"B-SAW $L\" > $result"}
    JSON
    printf '%s\n%s\n' ${lib.escapeShellArg a} ${lib.escapeShellArg b} > "$out/names"
    cat > "$out/deps.json" <<'JSON'
    ${builtins.toJSON {${a} = []; ${b} = [a];}}
    JSON
  '';

  bridge = import ./dyn-actions.nix {
    inherit pkgs;
    specDir = specs;
  };
in {
  inherit specs bridge;

  check = pkgs.runCommand "dyn-actions-minimal-spec-toy" {} ''
    # THE SPEC REALLY IS MINIMAL, checked rather than described. If a later change made the
    # generator side write full specs again, this toy would keep passing while testing nothing,
    # which is the failure mode the whole file exists to avoid.
    for f in ${specs}/${a}.json ${specs}/${b}.json; do
      for field in system version outputs env; do
        if grep -q "\"$field\"" "$f"; then
          echo "FAIL: $f already carries $field, so this proves nothing about a generator" >&2
          exit 1
        fi
      done
    done

    a=$(cat ${bridge.outputs.${a}})
    b=$(cat ${bridge.outputs.${b}})
    echo "--- a: $a"
    echo "--- b: $b"
    if [ "$a" != "MINIMAL-A" ]; then
      echo "FAIL: the minimal spec did not build, got: $a" >&2
      exit 1
    fi
    # THE EDGE TOO, since a lone action would not show that deps.json still works when the
    # spec files carry no env of their own for the fixup to add to.
    if [ "$b" != "B-SAW MINIMAL-A" ]; then
      echo "FAIL: the dependency did not reach the second action, got: $b" >&2
      exit 1
    fi
    echo "OK minimal specs: a=$a b=$b, and neither spec named system, version, outputs or env" > $out
  '';
}
