# Build a Darling CMake target with nix-ninja: one Nix derivation per Ninja
# edge, instead of the single monolithic build in nix/package.nix. Each edge is
# cached independently in the Nix store, so editing one source rebuilds only its
# object and that object's dependents: the fast incremental loop for iterating
# on Darling internals (darling.c, libSystem sources, …), and shareable via
# Cachix.
#
# Configure inputs (compiler bypass, tool/lib deps, cmake flags, env) come from
# ./darlingBuildInputs.nix (the same file nix/package.nix uses), so the
# per-edge build configures the tree byte-identically to the production build.
#
# nix-ninja itself lives in the overby.me monorepo (nix/lib/ninja); it is
# consumed through the `overby` flake input as a plain source tree
# (`flake = false`), and its one build tool (rust-ninja, a single-crate Ninja
# parser) is built here with nixpkgs' rustPlatform so none of overby's ~30
# transitive flake inputs leak into this lock.
{
  pkgs,
  overby,
  # The Darling source tree with submodules checked out (same source
  # nix/package.nix builds); defaults to the darling package's own source.
  src ? pkgs.darling.src,
}:
let
  inherit (pkgs) lib system;

  # package.nix's exact configure inputs (single source of truth).
  di = pkgs.callPackage ../darlingBuildInputs.nix { };

  # nix-ninja's entry point. VENDORED into this repo (nix/lib/nix-ninja/) rather
  # than pulled from the overby source, so its lowering can be fixed here (e.g. the
  # mig generated-header collision fix) and to reduce the external dependency — a
  # step toward this repo being self-contained. Evaluated against *this* flake's
  # pkgs (nixpkgs 26.05).
  buildNinjaProject =
    import ./nix-ninja/build/buildNinjaProject.nix { inherit pkgs; };

  # The Ninja-graph extraction tool. A standalone single-crate binary (only dep:
  # libc), built here so we need overby as source, not as an evaluated flake.
  rustNinja = pkgs.rustPlatform.buildRustPackage {
    pname = "rust-ninja";
    version = "0.1.0";
    src = "${overby}/rust/ninja";
    cargoLock.lockFile = "${overby}/rust/ninja/Cargo.lock";
  };
in
{
  inherit rustNinja buildNinjaProject;

  # Build a single Darling Ninja target (e.g. "src/startup/darling") edge by
  # edge. `target`/`targets` and `perFileIncremental` pass through to
  # buildNinjaProject; everything else is Darling's shared configure environment.
  buildTarget =
    {
      target ? null,
      targets ? null,
      perFileIncremental ? true,
      # Bake CMAKE_INSTALL_PREFIX so a nix-ninja-built launcher's compiled-in
      # INSTALL_PREFIX (it execs `INSTALL_PREFIX/bin/darlingserver`) points at an
      # existing monolithic `result` runtime — enabling seconds-fast launcher
      # iteration that reuses that runtime instead of a 40-min full rebuild.
      installPrefix ? null,
    }:
    buildNinjaProject {
      cmakeSource = src;
      inherit
        target
        targets
        perFileIncremental
        rustNinja
        ;

      cmakeFlags = di.cmakeFlags ++ [
        # Use the cc-wrapper bypass as the compiler so Darwin-target edges
        # (`-target *darwin*`) reach the unwrapped clang, exactly as
        # nix/package.nix does. Linux-target edges (e.g. the launcher) forward
        # to the wrapped clang.
        "-DCMAKE_C_COMPILER=${di.ccWrapperBypass}/bin/clang"
        "-DCMAKE_CXX_COMPILER=${di.ccWrapperBypass}/bin/clang++"
      ]
      ++ lib.optional (installPrefix != null) "-DCMAKE_INSTALL_PREFIX=${installPrefix}";

      configureNativeBuildInputs = di.nativeBuildInputs;
      configureBuildInputs = di.buildInputs;
      configureEnv = {
        NIX_CFLAGS_COMPILE = di.nixCflags;
        LD_LIBRARY_PATH = di.ldLibraryPath;
      };

      # Every edge runs the baked compiler path; give it the bypass clang plus
      # cmake (archive/link rules shell out to `cmake -E`) and coreutils.
      # Generator edges (bison/flex/gperf/mig, ...) bake the absolute store path
      # of the tool CMake found at configure time, but the graph JSON's string
      # context is stripped so Nix does not auto-mount them. Re-provide the
      # configure toolchain so those exact paths resolve in the edge sandbox.
      toolchain =
        [
          di.ccWrapperBypass
          pkgs.cmake
          pkgs.coreutils
        ]
        ++ di.nativeBuildInputs
        # The full graph (not just the launcher/kernel) has edges that compile
        # against configure buildInputs — e.g. src/bsdln needs libbsd's
        # <bsd/string.h>. The graph JSON's string context is stripped so Nix does
        # not auto-mount them, so re-provide the library deps in every edge's
        # sandbox (headers + link libs), exactly as nativeBuildInputs are.
        ++ di.buildInputs;
    };
}
