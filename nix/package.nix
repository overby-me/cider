{
  clangStdenv,
  lib,
  runCommandWith,
  writeShellScript,
  src,
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
  addDriverRunpath,
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
stdenv.mkDerivation {
  pname = "darling";
  version = "unstable-2025";

  # When building from the flake, `src` is the flake source directory.
  # All git submodules must be checked out:
  #   git submodule update --init --recursive
  inherit src;

  outputs = [
    "out"
    "sdk"
  ];

  postPatch = ''
    # Be careful -- patching everything indiscriminately
    # would affect Darwin scripts as well.
    chmod +x src/external/bootstrap_cmds/migcom.tproj/mig.sh
    patchShebangs \
      src/external/bootstrap_cmds/migcom.tproj/mig.sh \
      src/external/darlingserver/scripts \
      src/external/openssl_certificates/scripts

    substituteInPlace src/startup/CMakeLists.txt --replace SETUID ""
    substituteInPlace src/external/basic_cmds/CMakeLists.txt --replace SETGID ""
  '';

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

  buildInputs = wrappedLibs ++ [
    libbsd
    openssl
    stdenv.cc.libc.linuxHeaders
  ];

  # Breaks valid paths like
  # Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include
  dontFixCmake = true;

  # src/external/objc4 forces OBJC_IS_DEBUG_BUILD=1, which conflicts with NDEBUG
  cmakeBuildType = " ";

  cmakeFlags = [
    "-DTARGET_i386=OFF"
    "-DCOMPILE_PY2_BYTECODE=OFF"
    "-DDARLINGSERVER_XDG_USER_DIR_CMD=${xdg-user-dirs}/bin/xdg-user-dir"
  ];

  env.NIX_CFLAGS_COMPILE = "-Wno-macro-redefined -Wno-unused-command-line-argument";

  # Linux .so's are dlopen'd by wrapgen during the build
  env.LD_LIBRARY_PATH = lib.makeLibraryPath wrappedLibs;

  # Breaks shebangs of Darwin scripts
  dontPatchShebangs = true;

  postInstall = ''
    # Install the SDK as a separate output
    mkdir -p $sdk

    sdkDir=$(readlink -f ../Developer)

    while read -r path; do
      dst="$sdk/Developer/''${path#$sdkDir}"

      if [[ -L "$path" ]]; then
        target=$(readlink -m "$path")
        if [[ -e "$target" && "$target" == "$NIX_BUILD_TOP"* && "$target" != "$sdkDir"* ]]; then
          cp -r -L "$path" "$dst"
        elif [[ -e "$target" ]]; then
          cp -d "$path" "$dst"
        else
          >&2 echo "Ignoring symlink $path -> $target"
        fi
      elif [[ -f $path ]]; then
        cp "$path" "$dst"
      elif [[ -d $path ]]; then
        mkdir -p "$dst"
      fi
    done < <(find $sdkDir)

    mkdir -p $sdk/bin
    cp src/external/cctools-port/cctools/ld64/src/*-ld $sdk/bin
    cp src/external/cctools-port/cctools/ar/*-{ar,ranlib} $sdk/bin
  '';

  postFixup = ''
    echo "Checking for references to $NIX_STORE in Darling root..."

    set +e
    grep -r --exclude=mldr "$NIX_STORE" $out/libexec/darling
    ret=$?
    set -e

    if [[ $ret == 0 ]]; then
      echo "Found references to $NIX_STORE in Darling root (see above)"
      exit 1
    fi

    patchelf --add-rpath "${lib.makeLibraryPath wrappedLibs}:${addDriverRunpath.driverLink}/lib" \
      $out/libexec/darling/usr/libexec/darling/mldr
  '';

  dontCheckForBrokenSymlinks = true;

  meta = with lib; {
    description = "Open-source Darwin/macOS emulation layer for Linux";
    homepage = "https://www.darlinghq.org";
    changelog = "https://github.com/darlinghq/darling/releases";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "darling";
  };
}
