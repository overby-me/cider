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
  # The Darling source tree. Defaults to the nix-assembled off-submodules tree
  # (nix/lib/darling-src.nix overlays the 147 fetchFromGitHub-pinned submodules
  # onto this repo's tree and applies patches/), so `nix build .#*-ninja` needs no
  # `?submodules=1` and no git submodule step. Pass `pkgs.darling.src` (built with
  # `?submodules=1`) to fall back to git submodules.
  src ? import ./darling-src.nix {
    inherit pkgs;
    baseSrc = ../../.;
  },
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

  # darlingserver's duct-tape mig user-stubs pick their message send via
  # `#if __MigKernelSpecificCode` <- `_MIG_KERNEL_SPECIFIC_CODE_`, which
  # osfmk/mach/mig.h sets to 1 under MACH_KERNEL -- but only if that header is
  # reached through the include chain. nix-ninja merges the source tree and the
  # configured build dir into one $out, and the hand-written source
  # `osfmk/mach/notify.h` (which does not reach mig.h) can shadow mig's generated
  # same-named user header (which does), so a stub compiles the userspace
  # `mach_msg` branch and the darlingserver link fails with undefined `mach_msg`.
  # The duct-tape IS the kernel, so define `_MIG_KERNEL_SPECIFIC_CODE_` explicitly,
  # scoped to just the duct-tape directory (harmless in the monolith, where mig.h
  # already sets it to the same value). See plan/nix-ninja-componentization.md.
  ductapeMigFixSrc = pkgs.runCommand "darling-src-migkernelfix" { } ''
    # cp -a preserves mode (crucially the +x on scripts the build runs, e.g.
    # generate-rpc-wrappers.py and mig.sh) and symlinks; drop only ownership
    # (unset-table as non-root). Then add write for the sed below -- chmod u+w
    # keeps the execute bits. (A plain --no-preserve=mode copy strips +x and the
    # rpc.h generator fails "Permission denied".)
    cp -a --no-preserve=ownership ${src} $out
    chmod -R u+w $out
    # Add, to the duct-tape's directory-scoped compile definitions: the
    # kernel-specific-code selector, plus the three `*_from_kernel` redirects that
    # osfmk/kern/ipc_mig.h defines (send/rpc/destroy -> the `_proper` symbols,
    # defined in ipc_mig.c). nix-ninja's merged tree does not always deliver those
    # kernel mach headers to a mig user-stub's per-edge compile, so a stub calls
    # the un-redirected `mach_msg_send_from_kernel` and the link fails undefined.
    # These mirror ipc_mig.h exactly and only apply to the duct-tape, so they are
    # a no-op in the monolith build. See plan/nix-ninja-componentization.md.
    ${pkgs.gnused}/bin/sed -i \
      's/^add_compile_definitions($/&\n\t_MIG_KERNEL_SPECIFIC_CODE_=1\n\tmach_msg_send_from_kernel=mach_msg_send_from_kernel_proper\n\tmach_msg_rpc_from_kernel=mach_msg_rpc_from_kernel_proper\n\tmach_msg_destroy_from_kernel=mach_msg_destroy_from_kernel_proper/' \
      $out/src/external/darlingserver/duct-tape/CMakeLists.txt
  '';
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
      # Per-component grouping (task #26/#78): edgeIndex -> groupId, or null for
      # the per-edge lowering.
      grouping ? null,
      # Bake CMAKE_INSTALL_PREFIX so a nix-ninja-built launcher's compiled-in
      # INSTALL_PREFIX (it execs `INSTALL_PREFIX/bin/darlingserver`) points at an
      # existing monolithic `result` runtime — enabling seconds-fast launcher
      # iteration that reuses that runtime instead of a 40-min full rebuild.
      installPrefix ? null,
      # Which Darling components to configure into the graph (Darling's own
      # COMPONENTS mechanism, cmake/darling_parse_components.cmake). The default
      # `cli` expands to core -> system -> cli: the full CLI userland WITHOUT any
      # GUI-only projects (drops the `dev_gui_*`, `gui`, `jsc`, `webkit` groups --
      # AppKit, CoreImage, AVFoundation, WebKit, cocotron, CoreAudio, ...). That is
      # a much smaller graph than the monolith's `stock` default and is all the
      # campaign (bootstrap toolchain + hello) needs. Set to "stock"/"all" for a
      # full GUI build, or "system" for the leanest core runtime.
      components ? "cli",
    }:
    buildNinjaProject {
      cmakeSource = ductapeMigFixSrc;
      inherit
        target
        targets
        perFileIncremental
        grouping
        rustNinja
        ;

      cmakeFlags = di.cmakeFlags ++ [
        # Use the cc-wrapper bypass as the compiler so Darwin-target edges
        # (`-target *darwin*`) reach the unwrapped clang, exactly as
        # nix/package.nix does. Linux-target edges (e.g. the launcher) forward
        # to the wrapped clang.
        "-DCMAKE_C_COMPILER=${di.ccWrapperBypass}/bin/clang"
        "-DCMAKE_CXX_COMPILER=${di.ccWrapperBypass}/bin/clang++"
        # The per-edge builds bypass the cc-wrapper and do not inherit the
        # monolith's NIX_CFLAGS_COMPILE, so some XNU duct-tape mig user-stubs hit
        # `-Werror=implicit-function-declaration` (e.g. mach_msg, which message.h
        # guards behind #ifndef KERNEL) that the monolith tolerates. Bake the
        # tolerance into every compile command so the per-edge build matches.
        "-DCMAKE_C_FLAGS=-Wno-error=implicit-function-declaration"
        "-DCMAKE_CXX_FLAGS=-Wno-error=implicit-function-declaration"
        # Pin the Linux-side archiver to the clang stdenv's bintools (which IS in
        # the edge toolchain) instead of whatever gcc-wrapper cmake auto-detects on
        # the configure PATH — that wrapper's baked absolute path isn't mounted in
        # the per-edge sandbox (its context is stripped), giving `ar: No such file`.
        "-DCMAKE_AR=${di.stdenv.cc.bintools}/bin/ar"
        "-DCMAKE_RANLIB=${di.stdenv.cc.bintools}/bin/ranlib"
        # Scope the configured graph to the requested components. `cli` (default)
        # excludes all GUI-only projects; the monolith default is `stock` (GUI on).
        "-DCOMPONENTS=${components}"
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
          # The Linux-side archive/link edges (libsimple.a, duct-tape.a, the
          # darlingserver link) bake the darling stdenv cc-wrapper's absolute
          # `ar`/`ranlib`/`ld` paths (a gcc-wrapper whose `ar` symlinks into
          # binutils-wrapper). Its string context is stripped from the graph JSON,
          # so re-provide the wrapper + its bintools closure or those paths dangle.
          di.stdenv.cc
          di.stdenv.cc.bintools
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
