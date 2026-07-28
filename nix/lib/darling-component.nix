# darling-component (#26): build ONE Darling subproject target on top of the
# cached darling-base.
#
# SCOPE + LIMITATIONS (measured):
#  - LEAF components reuse base cleanly: bsdln = 2 edges, memberd = 3 edges, vs
#    ~4700 for the monolith. This works because base's own .ninja_log marks base's
#    outputs up-to-date.
#  - NON-LEAF components do NOT get dependency reuse: the overlaid dep delta stages
#    the artifacts, but Nix normalizes all mtimes to 1 and the dep's outputs are
#    absent from THIS build's .ninja_log, so ninja distrusts them and rebuilds the
#    dep (tput rebuilt ncurses: 170 edges). Merging ninja logs + mtimes is exactly
#    the bookkeeping a real per-edge build does.
#  - NO input isolation: this mounts base's whole build dir (which references the
#    full source), so editing ANY source rehashes base and every component. This is
#    a COLD-PARALLEL building block, not an incremental one.
#
# For input-isolated, incremental builds (edit one file -> rebuild only its edges)
# use nix-ninja per-edge (.#darling-ninja, task #39). The scoped design for isolated
# PER-COMPONENT builds (per-component minimal source + shared-header input + build-
# command root rewrite) is documented in task #26.
#
# Output layout:
#   $out/delta/...   -- exactly the files THIS component's ninja produced (its
#                       .o's + final lib/exe), relative to the build dir. This is
#                       what dependents and the final assembly overlay.
#   $out/<target>    -- the final artifact, for convenience / direct consumption.
#
# Delta capture: base + dep deltas are Nix outputs (mtime 1), so a marker at
# mtime 2 predates them all; `find -newer marker` after ninja is exactly the
# freshly built files (real mtimes >> 2). Robust, no timestamp race.
{
  pkgs,
  base,
  # The ninja target to build, e.g. "src/bsdln/bsdln".
  target,
  # Friendly derivation name; defaults to a sanitized target.
  name ? null,
  # Transitive dependency components (each a darling-component derivation). Their
  # $out/delta trees are overlaid onto the base build dir before this build.
  deps ? [ ],
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
    passthru = { inherit base target deps; };
  }
  ''
    cp -a ${base}/build build
    # Writable so the dep-delta overlay can write into base's read-only dirs.
    chmod -R u+w build

    # Overlay each (transitive) dependency component's delta so its target is
    # already built when ninja runs. cp -a preserves their mtime-1 stamps.
    ${lib.concatMapStringsSep "\n" (d: ''
      if [ -d ${d}/delta ]; then cp -a ${d}/delta/. build/; fi
    '') deps}

    # Re-assert writable: overlaid dep deltas are read-only Nix outputs, and ninja
    # must (over)write .ninja_log/.ninja_lock and its own outputs.
    chmod -R u+w build

    # Marker predating base + dep files (all Nix-output mtime 1); anything ninja
    # builds now gets a real, much-later mtime.
    touch -d @2 "$TMPDIR/marker"

    echo "=== ninja ${target}  (base + ${toString (builtins.length deps)} dep deltas) ==="
    ninja -C build ${lib.escapeShellArg target} 2>&1 | tee ninja.log | tail -30
    echo "edges run: $(grep -oE '^\[[0-9]+/[0-9]+\]' ninja.log | tail -1)"

    # This component's own delta = files newer than the marker, excluding ninja's
    # own bookkeeping (which every build rewrites and which must not be overlaid
    # read-only onto a dependent's build dir).
    mkdir -p $out/delta
    ( cd build && find . -newer "$TMPDIR/marker" \( -type f -o -type l \) \
        -not -name '.ninja_log' -not -name '.ninja_lock' -not -name '.ninja_deps' -print ) \
      | while read -r rel; do
          rel=''${rel#./}
          ( cd build && cp -a --parents "$rel" $out/delta/ )
        done
    echo "delta entries: $(find $out/delta \( -type f -o -type l \) 2>/dev/null | wc -l)"

    # Convenience copy of the final artifact.
    if [ -e "build/${target}" ]; then
      mkdir -p "$out/$(dirname "${target}")"
      cp -a "build/${target}" "$out/${target}"
    fi
  ''
