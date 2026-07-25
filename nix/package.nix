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
    # Apply local submodule patches (patches/<submodule-dir-basename>/*.patch).
    # A dirty-tree flake build may already contain applied patches (the
    # init-submodules script applies them in the working tree), so detect
    # that case with a reverse dry-run and skip.
    for dir in patches/*/; do
      [ -d "$dir" ] || continue
      target="src/external/$(basename "$dir")"
      if [ ! -d "$target" ]; then
        echo "patches: no submodule dir for $dir" >&2
        exit 1
      fi
      for p in "$dir"*.patch; do
        [ -e "$p" ] || continue
        if patch -R -p1 -d "$target" --dry-run --force --silent < "$p" >/dev/null 2>&1; then
          echo "patch $p: already applied"
        else
          patch -p1 -d "$target" --force < "$p"
        fi
      done
    done

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

    # Stage 0 of the Rust host-side rewrite: export the duct-tape + libsimple
    # static libs so the darlingserver-rs crate can link the REAL duct-tape and
    # call dtape_init(&hooks) (plan/rust-rewrite-eval.md, plan/rust-spike-stage3.md).
    # Consumed via DUCT_TAPE_LIB. Best-effort; harmless if the archives move.
    mkdir -p $out/rust-consume/lib
    find . -name 'libdarlingserver_duct_tape.a' -exec cp -v {} $out/rust-consume/lib/ \; || true
    find . -name 'liblibsimple_darlingserver.a'  -exec cp -v {} $out/rust-consume/lib/ \; || true
    echo "rust-consume export:"; ls -la $out/rust-consume/lib/ || true
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
