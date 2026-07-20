# Shared Darling CMake-configure inputs: the compiler bypass, tool and library
# dependency lists, cmake flags and build env used to configure and compile the
# Darling tree.
#
# Single source of truth for both the canonical single-derivation build
# (`nix/package.nix`) and the per-edge nix-ninja build (`nix/lib/darlingNinja.nix`,
# via the overby.me flake input). Keeping them here means the incremental build
# uses byte-identical configure inputs to the production build, no drift.
#
# A pure function of named packages (call via `callPackage ./darlingBuildInputs.nix {}`).
{
  clangStdenv,
  lib,
  runCommandWith,
  writeShellScript,
  freetype,
  libjpeg,
  libpng,
  libtiff,
  giflib,
  libX11,
  libXext,
  libXrandr,
  libXcursor,
  libxkbfile,
  cairo,
  libglvnd,
  fontconfig,
  dbus,
  libGLU,
  fuse,
  ffmpeg,
  pulseaudio,
  makeWrapper,
  python3,
  cmake,
  ninja,
  pkg-config,
  bison,
  flex,
  libbsd,
  openssl,
  xdg-user-dirs,
  systemdLibs,
  expat,
  libXau,
  libXdmcp,
}:
let
  stdenv = clangStdenv;

  # The build system invokes clang to compile Darwin executables.
  # In this case, our cc-wrapper must not be used -- if we detect a
  # `-target *darwin*` flag we call the *unwrapped* compiler so that
  # nixpkgs' cc-wrapper doesn't inject Linux-specific flags.
  ccWrapperBypass =
    runCommandWith
      {
        inherit stdenv;
        name = "cc-wrapper-bypass";
        runLocal = false;
        derivationArgs = {
          template = writeShellScript "template" ''
            for (( i=1; i<=$#; i++)); do
              j=$((i+1))
              if [[ "''${!i}" == "-target" && "''${!j}" == *"darwin"* ]]; then
                # their flags must take precedence
                exec @unwrapped@ "$@" $NIX_CFLAGS_COMPILE
              fi
            done
            exec @wrapped@ "$@"
          '';
        };
      }
      ''
        unwrapped_bin=${stdenv.cc.cc}/bin
        wrapped_bin=${stdenv.cc}/bin

        mkdir -p $out/bin

        unwrapped=$unwrapped_bin/$CC wrapped=$wrapped_bin/$CC \
          substituteAll $template $out/bin/$CC
        unwrapped=$unwrapped_bin/$CXX wrapped=$wrapped_bin/$CXX \
          substituteAll $template $out/bin/$CXX

        chmod +x $out/bin/$CC $out/bin/$CXX
      '';

  # Linux libraries whose .so's Darling's wrapgen dlopen's during the build, and
  # which the produced binaries link against (added to LD_LIBRARY_PATH + rpath).
  wrappedLibs = [
    freetype
    libjpeg
    libpng
    libtiff
    giflib
    libX11
    libXext
    libXrandr
    libXcursor
    libxkbfile
    cairo
    libglvnd
    fontconfig
    dbus
    libGLU
    fuse
    ffmpeg
    pulseaudio
  ];
in
{
  inherit stdenv ccWrapperBypass wrappedLibs;

  nativeBuildInputs = [
    bison
    ccWrapperBypass
    cmake
    flex
    makeWrapper
    ninja
    pkg-config
    python3
  ];

  buildInputs =
    wrappedLibs
    ++ [
      libbsd
      openssl
      stdenv.cc.libc.linuxHeaders
      # nixpkgs 26.05's dbus-1.pc has `Requires.private: libsystemd`; without
      # this, pkg-config fails to resolve dbus-1 at CMake configure time.
      systemdLibs
      # fontconfig.pc has `Requires.private: expat`, which nixpkgs does not
      # propagate; pkg-config needs expat.pc to resolve fontconfig.
      expat
      # xcb.pc has `Requires.private: xau xdmcp` (also not propagated).
      libXau
      libXdmcp
    ];

  cmakeFlags = [
    "-DTARGET_i386=OFF"
    "-DCOMPILE_PY2_BYTECODE=OFF"
    "-DDARLINGSERVER_XDG_USER_DIR_CMD=${xdg-user-dirs}/bin/xdg-user-dir"
  ];

  # wrapgen dlopen's these Linux .so's during the build.
  ldLibraryPath = lib.makeLibraryPath wrappedLibs;

  nixCflags = "-Wno-macro-redefined -Wno-unused-command-line-argument";
}
