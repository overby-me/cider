# cider-graph-specs: the Rust rewrite of scripts/buck_lowering.py and
# scripts/buck-graph-to-specs.py, task #99.
#
# It reads the buck2 action graph and writes the per-group spec files, the builder script
# template and the dependency edges the bridge reads back. See the crate header for what has to
# be byte exact and why.
#
# BUILT BY NIX RATHER THAN BY BUCK2, and that is a hard constraint: it runs inside the graph
# derivation, which is the tree buck2 was just run on, so buck2 building it would be circular.
# Same shape as nix/skeleton.nix, nix/launcher.nix and nix/loader.nix.
#
#   nix build .#specs-tool
{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "cider-graph-specs";
  version = "0.0.0";

  src = src + "/linux/buildtools/graph-specs";
  cargoLock.lockFile = src + "/linux/buildtools/graph-specs/Cargo.lock";

  # A single [[bin]] with no tests. What stands in for a test suite is the comparison recorded
  # in the crate header: 2,955 output files byte identical to the python over the real graph.
  doCheck = false;

  meta = with lib; {
    description = "Render the buck2 action graph into per-group specs (#99)";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cider-graph-specs";
  };
}
