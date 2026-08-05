# Build ONLY Darling's in-tree ld64 (the classic cctools Mach-O linker) as a
# standalone, cached nix derivation -- "Path B" of the cctools de-vendoring
# (PLAN.md). The monolith builds this ld64 as an in-tree cmake
# subtree every time; extracting it lets `use_ld64.cmake` point `-fuse-ld` at a
# cached store path instead, so the ~40-min monolith and the per-edge nix-ninja
# build both reuse one ld64 rather than rebuilding it.
#
# Why not nixpkgs' cctools ld64? Its cross build fails on x86_64-linux for lack of
# macOS SDK headers (libkern/OSByteOrder.h, mach/vm_prot.h). Darling's own
# cctools-port builds fine on Linux precisely because Darling vendors those darwin
# headers -- so we reuse Darling's sources, just built once and cached.
#
# It reuses nix/package.nix's exact configure (darlingBuildInputs.nix), then runs
# `ninja x86_64-apple-darwin20-ld` (+ the misc cctools the link's `-B` path needs).
{
  lib,
  src,
  callPackage,
}:
let
  inherit
    (callPackage ./darlingBuildInputs.nix { })
    stdenv
    nativeBuildInputs
    buildInputs
    cmakeFlags
    ldLibraryPath
    nixCflags
    ;
  triplet = "x86_64-apple-darwin20";
in
stdenv.mkDerivation {
  pname = "darling-ld64";
  version = "unstable-2025";

  inherit src;

  # CONTENT ADDRESSED, because `src` is the whole assembled project and this linker is not.
  # It builds four binaries out of src/external/cctools-port, so editing one ObjC file in
  # darwin/frameworks moves `src`, rebuilds this, and then moves every lowered target that
  # names the linker -- which is all of them. MEASURED: the two ld64 outputs built from the
  # clean tree and from a tree with one comment appended to darwin/frameworks/Accounts/src/
  # ACAccount.m are BIT IDENTICAL, sha256-tHH+BndVNL2V8g9iM7++iD/aGY3Pz5AirmcwEqJSblc=, so
  # under content addressing they collapse to one path and the consumers stop moving.
  #
  # This does NOT stop the 28 minute rebuild itself, which needs the source narrowed to what
  # the linker reads (task #64). It stops that rebuild from propagating.
  __contentAddressed = true;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";

  # Identical configure prep to package.nix so the tree configures byte-for-byte
  # the same (patches, mig shebang, darlingserver scripts).
  postPatch = ''
    # Submodule patches are pre-applied by darling-src.nix; no patch loop needed here.

    chmod +x src/external/bootstrap_cmds/migcom.tproj/mig.sh
    patchShebangs \
      src/external/bootstrap_cmds/migcom.tproj/mig.sh \
      src/external/darlingserver/scripts \
      src/external/openssl_certificates/scripts

    # The mig macro/driver create output dirs with absolute /bin/mkdir and
    # /bin/rmdir, which the nix build sandbox lacks (only /bin/sh). nix-ninja
    # tolerates this because its lowering pre-creates the dirs; a plain
    # stdenv.mkDerivation build like this one does not.
    # mig.cmake is parsed by CMake: a bare `mkdir` in an add_custom_command COMMAND
    # would bind to Darling's own `mkdir` target (it builds a Darwin coreutils
    # mkdir) and create an emulation->mkdir->libSystem dependency CYCLE. Use the
    # absolute coreutils path there so CMake sees a program, not a target. mig.sh
    # is a plain shell script, so PATH-resolved names are fine.
    substituteInPlace cmake/mig.cmake --replace-quiet '/bin/mkdir' "$(command -v mkdir)"
    substituteInPlace src/external/bootstrap_cmds/migcom.tproj/mig.sh \
      --replace-quiet '/bin/rmdir' 'rmdir' \
      --replace-quiet '/bin/mkdir' 'mkdir'

    substituteInPlace src/external/basic_cmds/CMakeLists.txt --replace SETGID ""

    # task #68: libnotify (reached as a dependency of the ld64 subgraph) hardcodes
    # the PRE-move SDK path for its `-include` of sys/fileport.h; repoint it at
    # darwin/Developer. package.nix and duct-tape.nix already do this; without it
    # here, `nix build .#darling-ld64` fails compiling libnotify's
    # notify_ipcUser.c with a `-include` of a path that no longer exists.
    substituteInPlace src/external/libnotify/CMakeLists.txt \
      --replace 'SOURCE_DIR}/Developer/Platforms' 'SOURCE_DIR}/darwin/Developer/Platforms'
  '';

  inherit nativeBuildInputs buildInputs;

  inherit cmakeFlags;

  dontFixCmake = true;
  cmakeBuildType = " ";
  env.NIX_CFLAGS_COMPILE = nixCflags;
  env.LD_LIBRARY_PATH = ldLibraryPath;
  dontPatchShebangs = true;

  # Build only the ld64 target (+ its deps: libstuff, the misc cctools like
  # install_name_tool/lipo/nmedit that the darwin link's `-B .../misc/` invokes).
  buildFlags = [
    "${triplet}-ld"
    "install_name_tool"
    "lipo"
    "nmedit"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp src/external/cctools-port/cctools/ld64/src/${triplet}-ld $out/bin/
    # the misc cctools the link references via -B .../misc/
    for t in install_name_tool lipo nmedit; do
      f=$(find src/external/cctools-port/cctools/misc -maxdepth 2 -name "$t" -type f 2>/dev/null | head -1)
      [ -n "$f" ] && cp "$f" $out/bin/ || echo "note: $t not built"
    done
    runHook postInstall
  '';

  dontCheckForBrokenSymlinks = true;

  meta = with lib; {
    description = "Darling's in-tree ld64 (cctools Mach-O linker), built standalone";
    license = licenses.apsl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "${triplet}-ld";
  };
}
