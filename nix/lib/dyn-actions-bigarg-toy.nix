# CAN AN ACTION HAVE A SCRIPT TOO LONG TO PASS AS AN ARGUMENT? Linux caps a single argv string
# at MAX_ARG_STRLEN, 32 pages, 131,072 bytes. That is NOT ARG_MAX, which is the 2 MB total: a
# command well under the total still fails with
#
#   error: executing '/bin/sh': Argument list too long
#
#   nix build --impure -f nix/lib/dyn-actions-bigarg-toy.nix check --no-link \
#     --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"
#
# NOTHING CIDER-SHAPED IN HERE, same rule as the other toys.
#
# WHY THIS EXISTS AS A TOY AT ALL. It was found by a real consumer, not here: 89 of one
# consumer's 1,474 actions are over the limit and the largest is 5.1 MB, while the largest
# script in every other fixture beside this one is a few kilobytes. A property nothing small
# can reach is exactly the property that needs a fixture built to reach it.
#
# THE SIZE IS ASSERTED, not assumed. If the padding below ever fell under the limit the action
# would pass without the spill ever running, and the file would test nothing.
{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) lib;

  stamp = "big1";

  # Comfortably over 131,072 bytes, built from a repeated line so the script stays valid shell.
  padding = lib.concatStrings (lib.genList (i: "# padding line ${toString i}, here to push this command over MAX_ARG_STRLEN\n") 2200);

  script = ''
    ${padding}
    echo BIGARG-RAN > $result
  '';

  bridge = import ./dyn-actions.nix {
    inherit pkgs;
    actions = [
      {
        name = "bigarg-${stamp}";
        builder = "/bin/sh";
        args = ["-c" script];
      }
    ];
  };
in {
  inherit bridge;

  check = pkgs.runCommand "dyn-actions-bigarg-toy" {} ''
    # THE ARGUMENT REALLY IS OVER THE LIMIT. Without this the whole file could be passing
    # because the padding shrank, and the spill would never have been exercised.
    n=${toString (builtins.stringLength script)}
    limit=131072
    echo "--- script is $n bytes, limit is $limit"
    if [ "$n" -le "$limit" ]; then
      echo "FAIL: the script is under MAX_ARG_STRLEN, so nothing here is being tested" >&2
      exit 1
    fi

    got=$(cat ${bridge.outputs."bigarg-${stamp}"})
    echo "--- got: $got"
    if [ "$got" != "BIGARG-RAN" ]; then
      echo "FAIL: an over-long command did not run, got: $got" >&2
      exit 1
    fi
    echo "OK an argument of $n bytes, over the $limit byte per-argument limit, ran: $got" > $out
  '';
}
