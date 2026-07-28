# server -- the darling host-side daemon (the Rust rewrite of darlingserver), built
# reproducibly. It CONSUMES the duct-tape + libsimple static libs exported by the
# standalone `duct-tape` package (DUCT_TAPE_LIB), never rebuilds them -- the
# "consume, don't build" model (proven first in a throwaway prototype, since removed).
# bindgen (via rustPlatform.bindgenHook) and the cc crate (fast_context.c, the P1
# switch) run at build time. The lib crate is named "darling". See plan/rust-rewrite-eval.md.
#
#   nix build .#server
{
  lib,
  runCommand,
  rustPlatform,
  clang,
  ductTape,
  src,
}:
let
  # Minimal source tree that MIRRORS the repo's real relative layout, so build.rs's
  # relative paths (crate -> duct-tape headers, fast_context.c, libsimple) resolve
  # identically here and in a dev `cargo build`. The Rust crate lives at linux/server;
  # the C++ duct-tape it links (+ fast_context.c) is still at src/external/darlingserver
  # and libsimple at src/libsimple, so all three are staged at their real repo paths.
  crateSrc = runCommand "server-src" { } ''
    mkdir -p $out/linux $out/src/external/darlingserver/duct-tape $out/src/external/darlingserver/src $out/src/libsimple
    cp -r ${src}/linux/server $out/linux/server
    cp -r ${src}/src/external/darlingserver/duct-tape/include $out/src/external/darlingserver/duct-tape/include
    cp ${src}/src/external/darlingserver/src/fast_context.c $out/src/external/darlingserver/src/fast_context.c
    cp -r ${src}/src/libsimple/include $out/src/libsimple/include
  '';
in
rustPlatform.buildRustPackage {
  pname = "server";
  version = "0.0.0";

  src = crateSrc;
  sourceRoot = "server-src/linux/server";
  cargoLock.lockFile = src + "/linux/server/Cargo.lock";

  # bindgenHook sets LIBCLANG_PATH + clang args for the dtape-hooks bindgen; clang
  # also backs the cc crate that compiles fast_context.c.
  nativeBuildInputs = [
    rustPlatform.bindgenHook
    clang
  ];

  # Link the prebuilt duct-tape from the standalone `duct-tape` build (committed source).
  DUCT_TAPE_LIB = "${ductTape}/rust-consume/lib";

  # The proofs are `[[bin]]`s (dtape-link-proof, stage3-spike, rpc_*_*, *_demo, the
  # daemon darlingserverd), not `#[test]`s, so there is nothing for `cargo test` to run.
  doCheck = false;

  meta = with lib; {
    description = "The darling host-side daemon in Rust (the darlingserver rewrite; lib crate 'darling')";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
