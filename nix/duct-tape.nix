# Build ONLY Darling's duct-tape + libsimple static libraries (the kernel-emulation
# glue the Rust `server` daemon links via DUCT_TAPE_LIB), not the whole Darwin
# userland. The C++ darlingserver daemon executable was removed -- the daemon is now
# the Rust `server` crate (linux/server) -- so this derivation exists only to produce
# those .a libs from the committed src/external/darlingserver source: ~5-10 min here
# vs ~40 min for the monolith, and cached so `.#server` and the full build reuse it.
#
# It reuses nix/package.nix's exact configure (darlingBuildInputs.nix), then runs
# `ninja darlingserver_duct_tape libsimple_darlingserver`. Regular ninja builds mig
# fine -- it is only nix-ninja's per-edge header scan that chokes on mig, which is why
# the darlingserver-ninja target does not work.
{
  lib,
  src,
  callPackage,
  # Optional CMAKE_INSTALL_PREFIX passthrough. Vestigial for this libs-only build
  # (it mattered when this package still produced the bin/darlingserver daemon).
  installPrefix ? null,
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
in
stdenv.mkDerivation {
  pname = "duct-tape";
  version = "unstable-2025";

  inherit src;

  # Identical configure prep to package.nix so the tree configures byte-for-byte
  # the same (patches, mig shebang, darlingserver scripts).
  postPatch = ''
    # Submodule patches are pre-applied by darling-src.nix; no patch loop needed here.

    chmod +x src/external/bootstrap_cmds/migcom.tproj/mig.sh
    patchShebangs \
      src/external/bootstrap_cmds/migcom.tproj/mig.sh \
      src/external/darlingserver/scripts \
      src/external/openssl_certificates/scripts

    substituteInPlace src/external/basic_cmds/CMakeLists.txt --replace SETGID ""
  '';

  inherit nativeBuildInputs buildInputs;

  cmakeFlags =
    cmakeFlags
    ++ lib.optionals (installPrefix != null) [ "-DCMAKE_INSTALL_PREFIX=${installPrefix}" ];

  dontFixCmake = true;
  cmakeBuildType = " ";
  env.NIX_CFLAGS_COMPILE = nixCflags;
  env.LD_LIBRARY_PATH = ldLibraryPath;
  dontPatchShebangs = true;

  # The C++ daemon target was REMOVED (the Rust rewrite is now the daemon); build just the shared
  # duct-tape + libsimple static libs the Rust daemon links (they no longer get pulled in as deps
  # of the deleted executable, so name them explicitly instead of relying on `all`).
  buildFlags = [ "darlingserver_duct_tape" "libsimple_darlingserver" ];

  installPhase = ''
    runHook preInstall

    # Export the duct-tape + libsimple static libs the Rust `server` daemon consumes via
    # DUCT_TAPE_LIB. Built from committed source here, so a pure `nix build .#server` works.
    mkdir -p $out/rust-consume/lib
    find . -name 'libdarlingserver_duct_tape.a' -exec cp -v {} $out/rust-consume/lib/ \; || true
    find . -name 'liblibsimple_darlingserver.a'  -exec cp -v {} $out/rust-consume/lib/ \; || true
    runHook postInstall
  '';

  dontCheckForBrokenSymlinks = true;

  meta = with lib; {
    description = "Darling's duct-tape + libsimple static libs (darlingserver kernel-emulation glue), built standalone";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
