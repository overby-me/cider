# cider-src-normalise: the Rust rewrite of the python normaliser (buck-src-normalise.py,
# deleted by #99).
#
# It re-points the two kinds of symlink buck2 refuses (a "." component, a target that leaves the
# cell) at the same file inside buck-src, and expands a symlinked DIRECTORY into a real one of
# per-file links, because buck2's globs do not descend into the former. See the crate header for
# the three failure modes each case was found through.
#
# BUILT BY NIX RATHER THAN BY BUCK2, and that is a hard constraint: this tool prepares the tree
# buck2 is then run on, so building it with buck2 would be circular. Same shape as
# nix/skeleton.nix and nix/graph-specs.nix.
#
#   nix build .#src-normalise
{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "cider-src-normalise";
  version = "0.0.0";

  src = src + "/linux/buildtools/src-normalise";
  cargoLock.lockFile = src + "/linux/buildtools/src-normalise/Cargo.lock";

  # ON, unlike the other two #99 tools, because this crate HAS tests and they are the reason to
  # trust it: pypath reimplements four os.path functions Rust's std does not have, and every
  # expectation in that module was read out of python3 rather than reasoned about.
  doCheck = true;

  meta = with lib; {
    description = "Make the materialized pins crawlable by buck2 (#99)";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cider-src-normalise";
  };
}
