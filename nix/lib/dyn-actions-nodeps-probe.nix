# Does a spec dir with NO deps.json work? The doc says it is optional and that its absence
# means no dependencies rather than an error. This checks that rather than trusting the guard.
{pkgs ? import <nixpkgs> {}}: let
  specs = pkgs.runCommand "dyn-actions-nodeps-specs" {} ''
    mkdir -p "$out"
    cat > "$out/nodeps-a.json" <<'JSON'
    {"name":"nodeps-a","builder":"/bin/sh","args":["-c","echo NODEPS-RAN > $result"]}
    JSON
    printf 'nodeps-a\n' > "$out/names"
    # DELIBERATELY NO deps.json.
  '';
  bridge = import ./dyn-actions.nix {inherit pkgs; specDir = specs;};
in {
  inherit specs bridge;
  check = pkgs.runCommand "dyn-actions-nodeps-check" {} ''
    if [ -e ${specs}/deps.json ]; then
      echo "FAIL: the spec dir has a deps.json, so this proves nothing" >&2
      exit 1
    fi
    got=$(cat ${bridge.outputs.nodeps-a})
    if [ "$got" != "NODEPS-RAN" ]; then
      echo "FAIL: got $got" >&2
      exit 1
    fi
    echo "OK a spec dir with no deps.json builds: $got" > $out
  '';
}
