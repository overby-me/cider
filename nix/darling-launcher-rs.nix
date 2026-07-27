# The Rust rewrite of the darling launcher (src/startup/darling.c), task #64. A plain
# libc-only binary crate -- no duct-tape, no bindgen -- so it builds straight from the
# committed source via cargoLock vendoring. Installed as bin/darling by package.nix; it
# resolves the daemon (bin/darlingserver) next to itself, so no prefix needs baking.
#
#   nix build .#darling-launcher-rs
{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "darling-launcher-rs";
  version = "0.0.0";

  src = src + "/src/external/darling-launcher-rs";
  cargoLock.lockFile = src + "/src/external/darling-launcher-rs/Cargo.lock";

  # No tests in the crate (it is a single [[bin]]).
  doCheck = false;

  meta = with lib; {
    description = "Rust rewrite of the darling launcher (src/startup/darling.c)";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "darling";
  };
}
