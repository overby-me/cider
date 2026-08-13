# cider-skeleton: the Rust rewrite of the python skeletoniser (buck-skeleton.py, deleted by
# #99).
#
# It reduces the project to what the graph derivation actually reads, which is the thing that
# stops editing one .c file rerunning a 30-to-47 minute graph build. See the crate header for
# what may be emptied and why the list is so much smaller than "everything that is not a build
# file".
#
# BUILT BY NIX RATHER THAN BY BUCK2, and that is a hard constraint: this tool produces the tree
# buck2 is then run on, so building it with buck2 would be circular. Same shape as
# nix/launcher.nix and nix/loader.nix, which already take this route.
#
#   nix build .#skeleton
{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "cider-skeleton";
  version = "0.0.0";

  src = src + "/src/linux/buildtools/skeleton";
  cargoLock.lockFile = src + "/src/linux/buildtools/skeleton/Cargo.lock";

  # std only, no dependencies, and a single [[bin]] with no tests.
  doCheck = false;

  meta = with lib; {
    description = "Reduce the project to what the buck2 graph derivation reads (#99)";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cider-skeleton";
  };
}
