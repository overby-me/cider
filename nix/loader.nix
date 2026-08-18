# The Rust rewrite of the Darling guest-side Mach-O loader (src/linux/startup/mldr/), task #65. A
# plain libc + goblin binary crate -- no xnu-sys, no bindgen, no build.rs -- so it builds
# straight from the committed source via cargoLock vendoring. Installed OVER the C mldr at
# libexec/cider/usr/libexec/cider/mldr by package.nix (and patchelf'd there in postFixup),
# so anything pointing DSERVER_MLDR_PATH at that path gets the Rust loader.
#
#   nix build .#loader
{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "loader";
  version = "0.0.0";

  src = src + "/src/darwin/loader";
  cargoLock.lockFile = src + "/src/darwin/loader/Cargo.lock";

  # No tests in the crate (it is a single [[bin]] named "mldr").
  doCheck = false;

  meta = with lib; {
    description = "Rust rewrite of the Cider guest Mach-O loader (src/linux/startup/mldr)";
    license = licenses.gpl3Plus;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "mldr";
  };
}
