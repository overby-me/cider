# The Rust rewrite of the cider launcher (src/startup/cider.c), task #64. A plain
# libc-only binary crate -- no xnu-sys, no bindgen -- so it builds straight from the
# committed source via cargoLock vendoring. Installed as bin/cider by package.nix; it
# resolves the daemon (bin/ciderd) next to itself, so no prefix needs baking.
#
#   nix build .#launcher
{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "launcher";
  version = "0.0.0";

  src = src + "/linux/launcher";
  cargoLock.lockFile = src + "/linux/launcher/Cargo.lock";

  # No tests in the crate (it is a single [[bin]]).
  doCheck = false;

  meta = with lib; {
    description = "Rust rewrite of the cider launcher (src/startup/cider.c)";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cider";
  };
}
