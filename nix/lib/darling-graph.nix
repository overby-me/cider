# Dump Darling's Ninja build graph as JSON, for the component-granularity build
# (#26): grouping these edges by their `CMakeFiles/<target>.dir/` output prefix
# yields the per-subproject DAG that drives darling-base + the per-component
# derivations. Mirrors nix/lib/darlingNinja.nix's configure exactly (same
# darlingBuildInputs flags, cc-wrapper bypass, COMPONENTS scoping), then runs
# rust-ninja `-t graph-json`. NOTHING is compiled -- `-t graph-json` only parses
# the generated manifest, so this is a cheap (~configure-time) artifact.
{
  pkgs,
  overby,
  # Off-submodules assembled tree (147 pins), same default as darlingNinja.nix.
  src ? import ./darling-src.nix {
    inherit pkgs;
    baseSrc = ../../.;
  },
  # Darling COMPONENTS scope (cmake/darling_parse_components.cmake). "system" is
  # the lean core runtime (core -> system); "cli" adds the CLI userland; "stock"
  # is the full GUI build. Smaller scope -> smaller, faster-to-read graph.
  components ? "system",
}:
let
  inherit (pkgs) lib;
  di = pkgs.callPackage ../darlingBuildInputs.nix { };
  rustNinja = pkgs.rustPlatform.buildRustPackage {
    pname = "rust-ninja";
    version = "0.1.0";
    src = "${overby}/rust/ninja";
    cargoLock.lockFile = "${overby}/rust/ninja/Cargo.lock";
  };
  cmakeSrcStore = builtins.path {
    path = src;
    name = "darling-cmake-src";
  };
  cmakeFlags = di.cmakeFlags ++ [
    "-DCMAKE_C_COMPILER=${di.ccWrapperBypass}/bin/clang"
    "-DCMAKE_CXX_COMPILER=${di.ccWrapperBypass}/bin/clang++"
    "-DCMAKE_C_FLAGS=-Wno-error=implicit-function-declaration"
    "-DCMAKE_CXX_FLAGS=-Wno-error=implicit-function-declaration"
    "-DCMAKE_AR=${di.stdenv.cc.bintools}/bin/ar"
    "-DCMAKE_RANLIB=${di.stdenv.cc.bintools}/bin/ranlib"
    "-DCOMPONENTS=${components}"
  ];
in
pkgs.runCommand "darling-ninja-graph-${components}"
  {
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
      pkgs.stdenv.cc
      di.ccWrapperBypass
      di.stdenv.cc
      di.stdenv.cc.bintools
      rustNinja
      pkgs.coreutils
    ]
    ++ di.nativeBuildInputs;
    buildInputs = di.buildInputs;
    NIX_CFLAGS_COMPILE = di.nixCflags;
    LD_LIBRARY_PATH = di.ldLibraryPath;
    passthru = { inherit rustNinja; };
  }
  ''
    mkdir -p $out
    echo "configuring darling (COMPONENTS=${components}, graph only) ..."
    cmake -S ${cmakeSrcStore} -B build -G Ninja ${lib.escapeShellArgs cmakeFlags} > $out/configure.log 2>&1 \
      || { echo "configure FAILED"; tail -40 $out/configure.log; exit 1; }
    cp build/build.ninja $out/build.ninja
    echo "extracting ninja graph (no compilation) ..."
    ( cd build && ${rustNinja}/bin/ninja -f build.ninja -t graph-json ) > $out/graph.json
    echo "graph.json bytes: $(wc -c < $out/graph.json)"
  ''
