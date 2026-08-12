# cider-graph-specs: the Rust rewrite of four python generators. #99 deleted three of them,
# buck2-graph-dump.py, buck_lowering.py and buck-graph-to-specs.py; buck2-graph-sources.py is
# still in the tree, off the build path, because two checks load it for read_trees.
#
# THREE BINARIES, one crate, because they share the parts that have to agree byte for byte:
#   cider-graph-dump      asks buck2 for the action graph and writes graph.json
#   cider-graph-specs     turns that into the per-group spec files and the builder template
#   cider-graph-sources   works out which project files each group reads
# See the crate headers for what has to be byte exact and why.
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

  # ON SINCE THE DUMP LANDED HERE. The crate had no tests when it was two binaries and its
  # evidence was the byte comparison recorded in the crate header (2,955 output files identical
  # to the python over the real graph). The dump brought three modules whose correctness is a
  # question of matching PYTHON exactly rather than of being reasonable: pat reimplements six
  # regexes, pypath four os.path functions, sha256 one hashlib call. Every expectation in those
  # tests was read out of python3, so running them here is what keeps a silent divergence from
  # reaching graph.json.
  doCheck = true;

  meta = with lib; {
    description = "Dump the buck2 action graph and render it into per-group specs (#99)";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cider-graph-specs";
  };
}
