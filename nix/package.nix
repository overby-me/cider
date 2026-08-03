{
  lib,
  src,
  callPackage,
  addDriverRunpath,
}:
let
  # Configure inputs (compiler bypass, tool/lib deps, cmake flags, env) are
  # shared with the per-edge nix-ninja build via ./darlingBuildInputs.nix, so
  # both builds configure the tree identically.
  inherit
    (callPackage ./darlingBuildInputs.nix { })
    stdenv
    nativeBuildInputs
    buildInputs
    cmakeFlags
    ldLibraryPath
    nixCflags
    ;

  # The C++ daemon was removed; build the Rust `server` daemon (and the standalone
  # `duct-tape` libs it links) so postInstall can install it as bin/darlingserver.
  ductTapeStandalone = callPackage ./duct-tape.nix { inherit src; };
  serverRust = callPackage ./server.nix {
    inherit src;
    ductTape = ductTapeStandalone;
  };
  # task #64: the Rust launcher, installed as bin/darling (the flip).
  launcherRust = callPackage ./launcher.nix { inherit src; };
  # task #65: the Rust guest Mach-O loader, installed OVER the C mldr (the flip).
  loaderRust = callPackage ./loader.nix { inherit src; };
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
    # Submodule patches (patches/<name>/*) are pre-applied by darling-src.nix when it
    # assembles the source tree (this package's src), so no patch loop is needed here.

    # Be careful -- patching everything indiscriminately
    # would affect Darwin scripts as well.
    chmod +x src/external/bootstrap_cmds/migcom.tproj/mig.sh
    patchShebangs \
      src/external/bootstrap_cmds/migcom.tproj/mig.sh \
      src/external/darlingserver/scripts \
      src/external/openssl_certificates/scripts

    substituteInPlace src/external/basic_cmds/CMakeLists.txt --replace SETGID ""

    # task #68: libnotify (a fetched pin, so not covered by the committed-tree move)
    # hardcodes the pre-move SDK path for its -include of sys/fileport.h; repoint it
    # at darwin/Developer.
    substituteInPlace src/external/libnotify/CMakeLists.txt \
      --replace 'SOURCE_DIR}/Developer/Platforms' 'SOURCE_DIR}/darwin/Developer/Platforms'
  '';

  inherit nativeBuildInputs buildInputs;

  # Breaks valid paths like
  # Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include
  dontFixCmake = true;

  # src/external/objc4 forces OBJC_IS_DEBUG_BUILD=1, which conflicts with NDEBUG
  cmakeBuildType = " ";

  inherit cmakeFlags;

  env.NIX_CFLAGS_COMPILE = nixCflags;

  # Linux .so's are dlopen'd by wrapgen during the build
  env.LD_LIBRARY_PATH = ldLibraryPath;

  # Breaks shebangs of Darwin scripts
  dontPatchShebangs = true;

  postInstall = ''
    # Install the SDK as a separate output
    mkdir -p $sdk

    # The guest SDK source tree moved under darwin/ (task #68); the split-out $sdk
    # output keeps the macOS-convention Developer/ layout (dst below is unchanged).
    sdkDir=$(readlink -f ../darwin/Developer)

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

    # Stage 0 of the Rust host-side rewrite: export the duct-tape + libsimple
    # static libs so the server crate can link the REAL duct-tape and
    # call dtape_init(&hooks) (PLAN.md).
    # Consumed via DUCT_TAPE_LIB. Best-effort; harmless if the archives move.
    mkdir -p $out/rust-consume/lib
    find . -name 'libdarlingserver_duct_tape.a' -exec cp -v {} $out/rust-consume/lib/ \; || true
    find . -name 'liblibsimple_darlingserver.a'  -exec cp -v {} $out/rust-consume/lib/ \; || true
    echo "rust-consume export:"; ls -la $out/rust-consume/lib/ || true

    # The C++ darlingserver was REMOVED; install the Rust rewrite as bin/darlingserver (the launcher
    # execs INSTALL_PREFIX/bin/darlingserver; the plain name keeps /proc/<pid>/comm "darlingserver"
    # so getInitProcess() recognizes the container init).
    mkdir -p $out/bin
    cp ${serverRust}/bin/darlingserverd $out/bin/darlingserver

    # task #64: override the cmake-installed C launcher with the Rust one. It resolves
    # bin/darlingserver next to itself, so no prefix baking is needed.
    install -m 0755 ${launcherRust}/bin/darling $out/bin/darling

    # task #65: override the cmake-installed C mldr (the guest Mach-O loader) with the Rust one.
    # The daemon's DSERVER_MLDR_PATH points at this path, so replacing the binary flips the guest
    # loader to Rust. postFixup patchelf's this path for the container's glibc/driver rpath.
    install -m 0755 ${loaderRust}/bin/mldr $out/libexec/darling/usr/libexec/darling/mldr
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

    patchelf --add-rpath "${ldLibraryPath}:${addDriverRunpath.driverLink}/lib" \
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
