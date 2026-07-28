# darling-component (#26): build ONE Darling subproject target on top of the
# cached darling-base, reusing base's toolchain + core libSystem + staged headers
# instead of rebuilding them. This is the per-component node of the component-
# granularity build: editing one component rebuilds only that component (+ its
# dependents), not the ~40-min monolith.
#
# Mechanism: darling-base is the tree configured WIDE (so every target is in
# build.ninja) with the core subgraph already built. We mount it writable and
# `ninja <target>` -- ninja sees core up-to-date (mtimes preserved by cp -a) and
# builds only this target's own edges. The baked build.ninja paths point into
# base's patchedSrc, which is in base's closure and thus mounted here.
{
  pkgs,
  base,
  # The ninja target to build, e.g. "src/bsdln/bsdln" or a phony alias like "bash".
  target,
  # Optional friendly name for the derivation; defaults to a sanitized target.
  name ? null,
  # Extra output paths (relative to the build dir) to collect beyond `target`.
  extraOutputs ? [ ],
}:
let
  inherit (pkgs) lib;
  di = pkgs.callPackage ../darlingBuildInputs.nix { };
  drvName =
    "darling-component-"
    + (if name != null then name else lib.strings.sanitizeDerivationName target);
in
pkgs.runCommand drvName
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
    passthru = { inherit base target; };
  }
  ''
    echo "mounting darling-base (core + toolchain + staged headers) ..."
    cp -a ${base}/build build
    chmod -R u+w build

    echo "=== ninja ${target} (core reused from base; only this component's edges should build) ==="
    ninja -C build -d explain ${lib.escapeShellArg target} 2>&1 | tee ninja.log | tail -40
    echo "=== edge count actually run ==="
    grep -oE '^\[[0-9]+/[0-9]+\]' ninja.log | tail -1 || echo "(no edges -> already built)"

    mkdir -p $out
    for o in ${lib.escapeShellArg target} ${lib.escapeShellArgs extraOutputs}; do
      if [ -e "build/$o" ]; then
        mkdir -p "$out/$(dirname "$o")"
        cp -a "build/$o" "$out/$o"
      fi
    done
    echo "component outputs:"; find $out -type f -o -type l | head
  ''
