# darling-base (#26): the shared foundation every per-component derivation
# compiles/links against -- built ONCE and cached. It is the Darling `core`
# COMPONENT scope: the cross-toolchain built from source (cctools ld64 + ar,
# bootstrap_cmds migcom), the SDK header staging (the now-race-free System/ +
# framework tree from #76, plus mig/rpc codegen), and the core libSystem runtime.
#
# The graph analysis (nix/lib/darling-graph.nix) shows these are precisely the
# most-depended-upon nodes: ld (86 dependents), migcom (44), ar (31), crt1 (18),
# and 111 header/codegen edges shared by everything.
#
# Configuration matches nix/package.nix exactly (darlingBuildInputs), and the
# source is placed in the store PATCHED (chmod +x + patchShebangs on the mig/rpc
# generators, like darlingNinja's ductapeMigFixSrc) so (a) `ninja` can run those
# generators and (b) the absolute paths CMake bakes into build.ninja are store
# paths that per-component derivations can mount and resolve. Output is the
# configured + built tree (the sysroot); per-component derivations mount it and
# `ninja` only their own target's edges on top.
{
  pkgs,
  src ? import ./darling-src.nix {
    inherit pkgs;
    baseSrc = ../../.;
  },
  # COMPONENTS scope. Configure WIDE (cli: core -> system -> cli userland) so every
  # per-component target exists in the one build.ninja that consumers reuse; then
  # build only the `baseTarget` subgraph below (= core). The graph analysis showed
  # cli is the full CLI userland minus GUI-only projects.
  components ? "cli",
  # The build handle for the shared foundation: the libSystem umbrella. Linking it
  # pulls in every core sublib (libsystem_c/kernel/pthread/malloc/dispatch/objc/...)
  # plus the from-source toolchain (ld/ar) and migcom as link/codegen deps -- i.e.
  # it builds core without enumerating its ~hundreds of targets.
  baseTarget ? "src/external/libsystem/libSystem.B.dylib",
}:
let
  inherit (pkgs) lib;
  di = pkgs.callPackage ../darlingBuildInputs.nix { };

  # Store-path source, patched the same way package.nix's postPatch does, so the
  # mig/rpc generator edges are executable + nix-resolvable when ninja runs them.
  # patchShebangs must see the generator interpreters (python3 etc.) on PATH to
  # rewrite `#!/usr/bin/env python3`; without them it leaves the shebang untouched
  # and the edge dies exit-126 in the sandbox. di.nativeBuildInputs is the darling
  # build's native toolset (same PATH package.nix's postPatch runs under).
  patchedSrc = pkgs.runCommand "darling-src-patched"
    { nativeBuildInputs = di.nativeBuildInputs; } ''
    cp -a --no-preserve=ownership ${src} $out
    chmod -R u+w $out
    chmod +x $out/src/external/bootstrap_cmds/migcom.tproj/mig.sh
    patchShebangs \
      $out/src/external/bootstrap_cmds/migcom.tproj/mig.sh \
      $out/src/external/darlingserver/scripts \
      $out/src/external/openssl_certificates/scripts
    substituteInPlace $out/src/external/basic_cmds/CMakeLists.txt --replace SETGID ""
    substituteInPlace $out/src/external/libnotify/CMakeLists.txt \
      --replace 'SOURCE_DIR}/Developer/Platforms' 'SOURCE_DIR}/darwin/Developer/Platforms'
  '';

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
pkgs.runCommand "darling-base-${components}"
  {
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
      pkgs.stdenv.cc
      di.ccWrapperBypass
      di.stdenv.cc
      di.stdenv.cc.bintools
      pkgs.coreutils
    ]
    ++ di.nativeBuildInputs;
    buildInputs = di.buildInputs;
    NIX_CFLAGS_COMPILE = di.nixCflags;
    LD_LIBRARY_PATH = di.ldLibraryPath;
    passthru = {
      inherit patchedSrc cmakeFlags;
      src = patchedSrc;
    };
  }
  ''
    echo "configuring darling-base (COMPONENTS=${components}, wide) ..."
    cmake -S ${patchedSrc} -B build -G Ninja ${lib.escapeShellArgs cmakeFlags} > configure.log 2>&1 \
      || { echo "configure FAILED"; tail -40 configure.log; exit 1; }
    echo "building the core foundation subgraph: ${baseTarget} ..."
    ninja -C build ${lib.escapeShellArg baseTarget}
    mkdir -p $out
    # The configured (wide) + core-built tree IS the reuse foundation: build.ninja
    # contains every per-component target, and the core sublibs/toolchain/headers
    # are already built. Per-component derivations mount this and `ninja <target>`.
    cp -a build $out/build
    du -sh $out/build 2>/dev/null | cut -f1 | xargs -I{} echo "base build tree size: {}"
  ''
