# cider-spec-fixup: the Rust rewrite of nix/lib/dyn-actions-spec-fixup.py, task #99.
#
# It runs inside a PRODUCER derivation, between the spec being written and `nix derivation add`
# reading it, and does the two things that can only be done there: make inputs.srcs
# store-dir-relative, and inject the dependency paths the outer Nix has just substituted into the
# producer's environment. See the crate header for why neither can happen in the evaluator.
#
# BUILT BY NIX RATHER THAN BY BUCK2, like the other #99 tools.
#
# IT LIVES IN nix/lib, NOT IN src/linux/buildtools WITH THE OTHER #99 TOOLS, and the reason is a
# checked property rather than taste: scripts/checks/buck-bridge-generality-check.nu requires every path
# a reusable bridge file names to land INSIDE the reusable set, which is what makes the set
# copyable into another project. Building this from src/linux/buildtools put two references outside
# it (../spec-fixup.nix and ../..) and the check failed, correctly. The crate sits beside this
# file as dyn-actions-spec-fixup/, so the whole bridge is still one directory.
#
#   nix build .#spec-fixup
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "cider-spec-fixup";
  version = "0.0.0";

  src = ./dyn-actions-spec-fixup;
  cargoLock.lockFile = ./dyn-actions-spec-fixup/Cargo.lock;

  # The two patterns it reimplements are a shell-variable name mangling and a store path scanner,
  # and both expectations were printed by python's re rather than reasoned about.
  doCheck = true;

  meta = with lib; {
    description = "Fix up an emitted derivation spec before nix derivation add (#99)";
    license = licenses.gpl3Plus;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "cider-spec-fixup";
  };
}
