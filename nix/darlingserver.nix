# Build ONLY the darlingserver daemon (the Linux-side ELF), not the whole Darwin
# userland. darlingserver is where the perf work happens (P1 landed, P2/P6/P8 to
# come), and unlike the Mach-O sublibraries it is not cross-linked into the
# libSystem umbrella, so it can be built on its own and spliced into a full
# `result` runtime for fast iteration: ~5-10 min here vs ~40 min for the monolith.
#
# It reuses nix/package.nix's exact configure (darlingBuildInputs.nix), then runs
# `ninja darlingserver` (which pulls in only the daemon's deps: duct-tape, mig +
# the generated RPC code, libsimple). Regular ninja builds mig fine -- it is only
# nix-ninja's per-edge header scan that chokes on mig, which is why the
# darlingserver-ninja target does not work.
#
# Splice workflow (see scripts/splice-darlingserver.sh):
#   nix build .#darlingserver -> result-ds/bin/darlingserver
#   cp -rL result rt && chmod +w rt/bin && cp result-ds/bin/darlingserver rt/bin/
#   build the launcher with installPrefix=$(realpath rt); run it.
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
in
stdenv.mkDerivation {
  pname = "darlingserver";
  version = "unstable-2025";

  inherit src;

  # Identical configure prep to package.nix so the tree configures byte-for-byte
  # the same (patches, mig shebang, darlingserver scripts).
  postPatch = ''
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

    chmod +x src/external/bootstrap_cmds/migcom.tproj/mig.sh
    patchShebangs \
      src/external/bootstrap_cmds/migcom.tproj/mig.sh \
      src/external/darlingserver/scripts \
      src/external/openssl_certificates/scripts

    substituteInPlace src/startup/CMakeLists.txt --replace SETUID ""
    substituteInPlace src/external/basic_cmds/CMakeLists.txt --replace SETGID ""
  '';

  inherit nativeBuildInputs buildInputs cmakeFlags;

  dontFixCmake = true;
  cmakeBuildType = " ";
  env.NIX_CFLAGS_COMPILE = nixCflags;
  env.LD_LIBRARY_PATH = ldLibraryPath;
  dontPatchShebangs = true;

  # Build only the daemon target (+ its transitive deps), not `all`.
  buildFlags = [ "darlingserver" ];

  # darlingserver is a Linux ELF with correct store RPATHs from the cc-wrapper
  # link; it legitimately references the store (unlike the Darwin root), so no
  # postFixup store-ref check is needed -- just install the one binary.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp src/external/darlingserver/darlingserver $out/bin/darlingserver
    runHook postInstall
  '';

  dontCheckForBrokenSymlinks = true;

  meta = with lib; {
    description = "Darling's darlingserver daemon, built standalone for fast perf iteration";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "darlingserver";
  };
}
