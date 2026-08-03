# The port's ACTION GRAPH, dumped by real buck2 inside a pure derivation.
#
# This is the "graph then lower" endpoint (plan/buck2-port.md phase 3): one opt-in
# import-from-derivation, the shape overby's nix/lib/cargo uses -- a pure derivation
# extracts the metadata, Nix reads that single file, and everything after it is ordinary
# Nix. It replaces interpreting the project's Starlark in Nix, which measured 82.5s of
# evaluator CPU and 47.7M values for one small target and does not extrapolate to 206 link
# edges.
#
# `buck2 log what-ran --format json` is the interface, because it is the only one that
# gives a faithful command: aquery and BXL both render it as a Rust debug string, which is
# lossy for any argument holding a comma or a space, and this port passes plenty of both
# (see buck/bxl/probe.bxl). The cost is that what-ran reports what EXECUTED, so this
# derivation runs a real build -- the actions are then re-run once each as their own
# derivations, so a graph change pays for the work twice. That is the deliberate trade:
# what it buys is a per-action Nix cache that a binary cache can serve.
{
  pkgs,
  # The project. Gitignored content (the materialized pins) is deliberately NOT here:
  # the pins arrive from the nix-assembled tree instead, which is what makes this pure.
  src ? ../..,
  # The assembled pin tree (`nix build .#darling-src`), and which of its subtrees to
  # materialize under buck-src/. Only what the targets actually load is needed, and
  # copying all 147 costs 3.8 GB.
  darlingSrc ? null,
  pins ? [],
  # Every pinned tree. Loading buck-src/BUCK COERCES the SDK maps, 3,591 source paths
  # across 70 pins, so any target in that package needs all of them present -- there is no
  # partial version of it. The list comes from the manifest rather than from reading the
  # assembled tree, which would be a second import-from-derivation.
  allPins ? false,
  # Darling's own ld64, which the link rules invoke by absolute path.
  ld64 ? null,
  targets,
}: let
  inherit (pkgs) lib;
  triplet = "x86_64-apple-darwin20";

  # The host ELF libraries wrapgen dlopen()s WHILE THE GRAPH IS BEING TAKEN. wrap_elf is the
  # one rule whose output depends on a file outside the build graph (buck/rules/codegen.bzl
  # says so): the stub it emits mirrors whatever the real .so actually exports, so the
  # library has to be loadable here, not merely named.
  #
  # Reusing darlingBuildInputs' wrappedLibs rather than restating the list, because it is
  # already the single source of truth that nix/package.nix and the nix-ninja path share.
  # getLib, not the default output: fontconfig, dbus and ffmpeg all keep their .so in a
  # separate `lib` output, which is what the dev shell's own -L directories resolve to and
  # what scripts/buck-setup.sh therefore writes on the daemon path.
  di = pkgs.callPackage ../darlingBuildInputs.nix {};
  elfLibDirs = lib.concatStringsSep ":" (map (p: "${lib.getLib p}/lib") di.wrappedLibs);

  # Every host library the reference gives a compile an absolute -I for. The reference
  # build.ninja names 25 such directories across 23 packages, for AppKit, Onyx2D,
  # CoreGraphics, CoreText, iokitd, hdiutil, the X11 backends and the CoreAudio cone.
  #
  # wrappedLibs is the ELF set; these four are include-only and appear in no wrap_elf:
  # xorgproto is where X11/X.h lives, libXrender and libXdmcp arrive through libX11's own
  # headers, and zlib through ruby's zlib module.
  #
  # linuxHeaders is not a library at all. fseventsd is a Darwin guest binary that bridges to
  # Linux fanotify, so it includes kernel UAPI headers: fanotify.h reaches for
  # <linux/types.h> and nothing else in this list carries it. The daemon path gets it by
  # accident, through the dev shell -isystem sweep scripts/buck-setup.sh does for giflib,
  # and the reference does not name it either -- every -I on its fseventsd edge is a project
  # path, so both builds lean on the compiler default that this derivation deliberately
  # removes.
  hostIncludeLibs =
    di.wrappedLibs
    ++ [pkgs.xorg.xorgproto pkgs.xorg.libXrender pkgs.xorg.libXdmcp pkgs.zlib]
    ++ [pkgs.linuxHeaders];

  # The VERSIONED subdirectories, which a plain include dir does not reach: freetype2 and
  # cairo put their headers one level down, and dbus splits over two outputs. These are
  # exactly the cases scripts/buck-setup.sh needs pkg-config for on the daemon path.
  hostIncludeDirs = lib.concatStringsSep ":" (
    [
      "${lib.getDev pkgs.dbus}/include/dbus-1.0"
      "${lib.getLib pkgs.dbus}/lib/dbus-1.0/include"
      "${lib.getDev pkgs.freetype}/include/freetype2"
      "${lib.getDev pkgs.cairo}/include/cairo"
    ]
    ++ map (p: "${lib.getDev p}/include") hostIncludeLibs
  );
  manifest = builtins.fromJSON (builtins.readFile ../submodules.json);
  wantedPins =
    if allPins
    then map (e: e.path) (builtins.filter (e: lib.hasPrefix "src/external/" e.path) manifest)
    else pins;
  # As a SCRIPT, not inline: 147 pins of shell in the builder's environment is
  # "Argument list too long" before it is anything else.
  materializePins = pkgs.writeShellScript "materialize-pins" (
  lib.concatMapStrings (p: let
        name = builtins.baseNameOf p;
      in ''
        echo "materializing buck-src/${name}"
        # CONTENTS, not the directory: buck-src/<pin>/BUCK is committed since the per-pin
        # split, so the destination already exists and `cp -a src dest` would nest the
        # whole tree one level down as buck-src/<pin>/<pin>.
        mkdir -p buck-src/${name}
        cp -a --reflink=auto ${darlingSrc}/${p}/. buck-src/${name}/
        chmod -R u+w buck-src/${name}
        # And where the SDK expects it. Darling's SDK is a farm of ~1,900 committed
        # symlinks into src/external/<pin>, and this flake is built WITHOUT git submodules,
        # so in the source those all dangle: the staged headers come out empty and the
        # failure lands somewhere far away (libc's vsprintf.c, on a __va_list that no
        # longer has a typedef). One relative symlink per pin makes the farm resolve, and
        # points at the copy that is already there rather than a second one.
        mkdir -p ${builtins.dirOf p}
        rmdir ${p} 2>/dev/null || true
        ln -sfn ../../buck-src/${name} ${p}
      '') wantedPins
  );
  # The vendored Rust crates, which buck-rust/BUCK globs and which are gitignored like the
  # pins: without them the analysis fails on the first crate it loads, since a source
  # attribute has to name a file that exists.
  rustVendor = import ./rust-vendor.nix {inherit pkgs;};

  # As a LIST built in Nix, not as an inline fragment: an optional piece inside the shell
  # line leaves a dangling continuation when it is empty, and the targets end up on a line
  # of their own where the dumper never sees them.
  placeholderArgs =
    [
      "--placeholder"
      "CLANG=${pkgs.llvmPackages.clang-unwrapped}"
      "--placeholder"
      "RESOURCE_DIR=${pkgs.clang}/resource-root"
    ]
    ++ lib.optionals (ld64 != null) ["--placeholder" "LD64=${ld64}"];
in
  pkgs.stdenv.mkDerivation {
    name = "darling-buck2-graph";
    # Filtered: buck2 reads BUCK files, rules, toolchains, configs and sources, and
    # nothing else here. Without this, editing the plan or the Nix that CONSUMES this
    # graph invalidates the graph itself, which costs a full buck2 build to rediscover
    # commands that did not change. (Keying this on the build DEFINITION rather than on
    # file contents is the next step -- see plan/buck2-port.md.)
    src = builtins.path {
      name = "darling-buck2-project";
      path = src;
      filter = path: _type: let
        rel = lib.removePrefix (toString src + "/") (toString path);
        top = lib.head (lib.splitString "/" rel);
      in
        # Same exclusion as the lowering: buck2 has targets under tests/buck2, but the NixOS
        # VM tests are Nix it never reads, and editing one changed the graph -- and so every
        # derivation lowered from it.
        !(top == "tests" && lib.hasSuffix ".nix" rel)
        && !(builtins.elem top [
          "plan"
          "docs"
          "nix"
          ".git"
          ".jj"
          ".direnv"
          "buck-out"
          "result-graph-ref"
          # The flake describes how this derivation is INVOKED, never what buck2 reads.
          # Leaving them in meant every edit to an unrelated flake output invalidated the
          # graph and re-ran a three-minute analysis plus the whole lowering behind it.
          "flake.nix"
          "flake.lock"
        ]);
    };

    nativeBuildInputs =
      [
        pkgs.buck2
        pkgs.clang
        # The Rust side of the port: rustc for the three crates, bindgen for the daemon's
        # dtape vtable. Both are TOOLS here, exactly as on the daemon path.
        pkgs.rustc
        pkgs.rust-bindgen
        pkgs.bison
        pkgs.flex
        pkgs.python3
        pkgs.llvmPackages.bintools
        pkgs.coreutils
        pkgs.gnused
        pkgs.gnugrep
        pkgs.findutils
        pkgs.bash
      ]
      ++ lib.optional (ld64 != null) ld64;

    # nixpkgs' cc wrapper injects hardening flags, and -D_FORTIFY_SOURCE turns libc's own
    # sprintf into a macro over __builtin___sprintf_chk -- which then rewrites the
    # DEFINITION of sprintf in libc's sources and fails to parse. The reference build has
    # no such flags, and this endpoint's whole point is running the argv buck2 ran.
    hardeningDisable = ["all"];

    # buck2 builds an HTTP client while starting its daemon, before it knows whether
    # anything will be fetched, and dies without a CA bundle ("failed to read PEM from
    # file ... /no-cert-file.crt"). Nothing is fetched -- the sandbox has no network.
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

    # No network, no reference to the build machine: buck2 reads the project, the pins and
    # the toolchains, and nothing else.
    dontConfigure = true;
    dontInstall = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      # buck2 writes buck-out INTO the project root, so the source has to be writable.
      chmod -R u+w .

      ${materializePins}

      # The Rust crate sources, the same set scripts/buck-rust-vendor.sh materializes for
      # the daemon path. Copied rather than symlinked, because buck2 reads them as package
      # files and a glob across a link into the store either misses them or drags the
      # closure in.
      mkdir -p buck-rust
      for c in ${rustVendor}/*/; do
        name=$(basename "$c")
        mkdir -p "buck-rust/$name"
        cp -a --reflink=auto "$c"/. "buck-rust/$name/"
      done
      chmod -R u+w buck-rust
      echo "buck-rust: $(ls buck-rust | wc -l) crate(s)"

      # The same normalisation scripts/buck-src.sh applies on the daemon path: the upstream
      # trees contain symlinks with a "." component and ones whose relative target leaves
      # the cell, and buck2 refuses both. Without it the analysis dies on libnotify's
      # notify.defs, whose link was written for src/external/<pin> and reaches one level
      # above the root from buck-src/<pin>.
      #
      # AFTER every pin, not per pin: the rewrite follows the SDK farm's own links to find
      # what the escaping link means, and those point into src/external/<pin>, which only
      # exists once the pin loop has made all of them.
      # --repo: the script runs from the store here, so it cannot find the project by
      # looking above itself, and the rewrite that needs it would quietly do nothing.
      python3 ${../../scripts/buck-src-normalise.py} --repo "$PWD" buck-src/*

      # The machine-local config scripts/buck-setup.sh writes by hand, here from the
      # store paths this derivation was given -- the whole point of running in Nix.
      cat > .buckconfig.local <<EOF
      # GENERATED by nix/lib/darlingBuck2Graph.nix.
      #
      # buck2 watches the project through watchman by default and refuses to start without
      # it. Nothing changes under a build sandbox, so the in-process watcher is both enough
      # and one less daemon to get running in here.
      [buck2]
      file_watcher = notify
      [darling]
      ${lib.optionalString (ld64 != null) ''
        ld = ${ld64}/bin/${triplet}-ld
        ld64_dir = ${ld64}/bin
      ''}
      clang_resource_dir = $(clang -print-resource-dir)
      darwin_cc = ${pkgs.llvmPackages.clang-unwrapped}/bin/clang
      darwin_cxx = ${pkgs.llvmPackages.clang-unwrapped}/bin/clang++
      elf_lib_dirs = ${elfLibDirs}
      host_include_dirs = ${hostIncludeDirs}
      EOF

      # The nixpkgs cc/bintools wrappers inject flags for THIS platform through NIX_CFLAGS_*
      # and NIX_LDFLAGS*, and a Darwin link then gets a Linux -dynamic-linker=<glibc> that
      # Darling's ld64 rejects outright. The argv from buck2 is complete on its own -- it
      # carries -nostdinc, the resource root and the whole link line -- so the wrapper has
      # nothing to add here.
      for _v in $(env | sed -n 's/^\(NIX_\(CFLAGS\|LDFLAGS\)[A-Za-z0-9_]*\)=.*/\1/p'); do
        unset "$_v"
      done

      export HOME="$TMPDIR/home"
      export XDG_CACHE_HOME="$TMPDIR/cache"
      mkdir -p "$HOME" "$XDG_CACHE_HOME"

      mkdir -p "$out"

      # NO full build here. The graph comes out of ANALYSIS: aquery renders every action's
      # command line without executing it, `targets --show-full-output` names each target's
      # output, and only the targets owning artifacts buck2 makes in-process get built --
      # about 4% of the commands. Dumping from `log what-ran` instead is what used to force
      # a complete build before Nix could learn anything, and that was the whole of the
      # double-build cost (plan/buck2-port.md phase 3).
      # what-ran alone is not the whole graph: it says nothing about the actions buck2
      # performs in-process, and no argv says which of its paths are OUTPUTS. This asks
      # the other two interfaces and writes graph.json.
      # Named placeholders for the three store paths an argv can carry, so the graph is
      # portable: a dump full of this machine's store paths is worthless as a committed
      # artifact and misses the cache everywhere else.
      # One line: inside a Nix indented string a backslash is literal, not an
      # escape, so a continuation would be two backslashes and cut the command.
      python3 ${../../scripts/buck2-graph-dump.py} nix "$out" ${lib.escapeShellArgs placeholderArgs} ${lib.escapeShellArgs targets}
      buck2 --isolation-dir nix kill || true

      runHook postBuild
    '';

    passthru = {inherit targets;};
  }
