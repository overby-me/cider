# End-to-end proof of the "build each project separately, consume from build.rs"
# model (see plan/rust-rewrite-eval.md). Three independent derivations:
#   1. duct-tape (a C project) built ON ITS OWN into libdtape.a
#   2. darlingserver-rs (a cargo crate) whose build.rs CONSUMES (1) at link time
#   3. an ASSEMBLY derivation that stages the prebuilt projects into a darling
#      prefix -- this, NOT build.rs, is where the macOS dylibs get placed.
#
# Build + run:
#   nix build --impure -f proto.nix darling --print-out-paths
#   result=$(nix build --impure -f proto.nix darlingserver --print-out-paths --no-link)
#   $result/bin/darlingserver     # -> "linked prebuilt duct-tape, dtape_init(8) = 17"
{
  pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.x86_64-linux,
}:
let
  # ---- PROJECT 1: duct-tape, built separately (stands in for the real C glue) --
  ductTape = pkgs.runCommand "duct-tape-stub" { nativeBuildInputs = [ pkgs.stdenv.cc pkgs.binutils ]; } ''
    mkdir -p $out/lib $out/include
    cp ${./duct-tape-stub/dtape.h} $out/include/dtape.h
    cc -c ${./duct-tape-stub/dtape.c} -I${./duct-tape-stub} -o dtape.o
    ar rcs $out/lib/libdtape.a dtape.o
  '';

  # ---- PROJECT 2: darlingserver-rs, consumes ductTape via build.rs -------------
  darlingserver = pkgs.rustPlatform.buildRustPackage {
    pname = "darlingserver-rs";
    version = "0.0.0";
    src = ./darlingserver-rs;
    cargoLock.lockFile = ./darlingserver-rs/Cargo.lock;
    # the ONLY wiring the consumer needs: where the prebuilt project lives.
    DUCT_TAPE_LIB = "${ductTape}/lib";
  };

  # ---- ASSEMBLY: stage prebuilt projects into the darling prefix ---------------
  # In the real thing this also stages the nix-ninja-built macOS dylibs
  # (libSystem.B.dylib, frameworks) into usr/lib for dyld to load at runtime.
  darling = pkgs.runCommand "darling-prefix" { } ''
    mkdir -p $out/libexec/darling/bin $out/libexec/darling/usr/lib
    cp ${darlingserver}/bin/darlingserver $out/libexec/darling/bin/darlingserver
    # placeholder for a prebuilt macOS dylib staged from its own project:
    echo "would stage libSystem.B.dylib (nix-ninja output) here" \
      > $out/libexec/darling/usr/lib/README.staging
  '';
in
{
  inherit ductTape darlingserver darling;
}
