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
  # Feed the dump a SKELETON instead of the project (#56): every C family file outside
  # buck-src, buck-rust and src/external emptied, keeping the name and dropping the bytes,
  # except the five that feed a generator this derivation runs. OFF BY DEFAULT and an
  # EXPERIMENT until the resulting graph is shown equivalent to the one the project produces;
  # see packages.darling-buck2-graph-skeleton and scripts/buck-graph-equiv.py.
  skeleton ? false,
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
  # what scripts/buck-setup.nu therefore writes on the daemon path.
  di = pkgs.callPackage ../darlingBuildInputs.nix {};
  elfLibDirs = lib.concatStringsSep ":" (map (p: "${lib.getLib p}/lib") di.wrappedLibs);

  # Every host library the reference gives a compile an absolute -I for. The reference
  # build.ninja names 25 such directories across 23 packages, for AppKit, Onyx2D,
  # CoreGraphics, CoreText, iokitd, hdiutil, the X11 backends and the CoreAudio cone.
  #
  # wrappedLibs is the ELF set; hostHeaderLibs is the include-only set beside it, and both
  # live in darlingBuildInputs so this and the LOWERING cannot drift apart. They did drift
  # once, and it cost a build: the include-only packages were added here and not to the
  # lowering's extraTools, so fseventsd_obj went on failing on linux/types.h in the lowering
  # after the graph stage had stopped failing on it.
  hostIncludeLibs = di.wrappedLibs ++ di.hostHeaderLibs;

  # The VERSIONED subdirectories, which a plain include dir does not reach: freetype2 and
  # cairo put their headers one level down, and dbus splits over two outputs. These are
  # exactly the cases scripts/buck-setup.nu needs pkg-config for on the daemon path.
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
  # The project as Nix sees it, filtered to what the build can possibly read. BOTH
  # derivations take it whole: the graph dump and the source closure.
  #
  # This used to say buck2 gets a SKELETON instead. It does not, and there is no skeleton
  # derivation in this file: the attempt was reverted, for the reason recorded at `src =
  # projectSrc` below, and the same false claim survived in scripts/buck2-graph-sources.py
  # until it was corrected. It matters because it understates the cost of a source edit by an
  # entire graph build, about 18m34s, which is the number the scheduling decisions here get
  # made against. scripts/buck-skeleton.py is now five files short of correct rather than
  # conceptually wrong (#56), but adopting it is still an open change.
  projectSrc = builtins.path {
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
        # EVERY result symlink, not just result-graph-ref. .buckconfig's [project] ignore
        # already lists `result, result-*`, so buck2 does not read one; what they did do is
        # rehash this derivation whenever any of them was repointed, because builtins.path
        # hashes a symlink by its TARGET STRING and those targets are store paths. Rebuilding
        # ld64 therefore rebuilt the graph, 30 minutes, over a link buck2 ignores.
        && !(lib.hasPrefix "result" top)
        && !(builtins.elem top [
          "plan"
          "docs"
          "nix"
          # The prose. A PLAN.md edit cost a 30 minute graph rebuild and a full relowering
          # before this line: the lowering had already been taught to ignore it
          # (d8af37a70), the graph had not.
          "PLAN.md"
          "README.md"
          "CONTRIBUTORS.md"
          # The generators and the check suite. buck2 never opens one: the only path
          # starting with scripts/ in any BUCK file is darlingserver's
          # scripts/generate-rpc-wrappers.py, which is relative to ITS package and resolves
          # to src/external/darlingserver/scripts/, not here. The two scripts this
          # derivation does run, buck2-graph-dump.py and buck-src-normalise.py, arrive as
          # their own store paths through Nix path interpolation, so editing either still
          # rebuilds the graph, which is correct because both change its output.
          #
          # Without this, adding a check script rebuilds the whole graph derivation, 40
          # minutes, for a file nothing in the build reads. nix/lib/darlingBuck2Lower.nix
          # has excluded scripts/ for the same reason since the coarse filter went in; the
          # graph simply never got the same treatment.
          "scripts"
          ".git"
          ".jj"
          ".direnv"
          "buck-out"
          # The flake describes how this derivation is INVOKED, never what buck2 reads.
          # Leaving them in meant every edit to an unrelated flake output invalidated the
          # graph and re-ran a three-minute analysis plus the whole lowering behind it.
          "flake.nix"
          "flake.lock"
        ]);
    };

  # THE SKELETON (#56), used only when `skeleton` is set. The same tree with every C family
  # file emptied except those under buck-src, buck-rust and src/external and the five that
  # feed a generator this dump RUNS. scripts/buck-skeleton.py holds the rules and
  # scripts/buck-codegen-closure.py is what computed the five.
  #
  # CONTENT ADDRESSED, and that is the whole mechanism rather than a detail: editing a .c
  # changes no file NAME, so this output is byte identical, the graph derivation behind it
  # does not rerun, and the 18m34s disappears from that edit. Editing a BUCK file, a .defs, a
  # grammar or one of the five generator inputs DOES change it, and the graph correctly
  # rebuilds.
  #
  # It takes projectSrc, so it still rebuilds on any edit. That is fine and it is cheap: it
  # is a file copy, and only its OUTPUT feeds the expensive derivation.
  #
  # The pins are NOT skeletonised, because they never come through here: assembleProject
  # materialises them from darlingSrc after this tree is unpacked.
  skeletonSrc = pkgs.runCommand "darling-buck2-skeleton" {
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    python3 ${../../scripts/buck-skeleton.py} ${projectSrc} $out \
      --keep ${../../scripts/buck-codegen-keep.txt}
  '';

  # The tree BOTH passes work on: the pins materialised under buck-src, the vendored Rust
  # crates, and the symlink normalisation buck2 refuses to load without. Shared rather than
  # duplicated, because the graph and the source closure both need it and the two drifting
  # apart would show up as a missing header a long way from here.
  assembleProject = ''
      # buck2 writes buck-out INTO the project root, so the source has to be writable.
      chmod -R u+w .

      ${materializePins}

      # The Rust crate sources, the same set scripts/buck-rust-vendor.nu materializes for
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

      # The same normalisation scripts/buck-src.nu applies on the daemon path: the upstream
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
  '';

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
  graph = pkgs.stdenv.mkDerivation {
    name = "darling-buck2-graph";
    # TWO OUTPUTS, CONTENT ADDRESSED (#50). graph.json is read only by the EVALUATOR while
    # staged/ and treelinks/ are read only by the lowered BUILDERS, and sharing one store
    # path meant that changing a byte of the dump FORMAT moved the path every lowered
    # derivation references, so all of them rebuilt although not one build input had changed.
    # Split, and under content addressing the data output is addressed by its own content, so
    # a format-only change leaves it exactly where it was and the consumers do not rebuild.
    #
    # PROVEN on a two output toy before being pointed at a 481 MB graph: changing the builder
    # so only the first output differs leaves the data output path identical, and a consumer
    # reading only that output does NOT rebuild. Note the consumer drvPath DOES move, because
    # a deferred reference carries the producing drv, so "did the drvPath move" is the WRONG
    # check for a content addressed dependency and would report a false negative here. The
    # check is whether nix actually reruns the builder.
    outputs = ["out" "data"];
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    # Filtered: buck2 reads BUCK files, rules, toolchains, configs and sources, and
    # nothing else here. Without this, editing the plan or the Nix that CONSUMES this
    # graph invalidates the graph itself, which costs a full buck2 build to rediscover
    # commands that did not change. (Keying this on the build DEFINITION rather than on
    # file contents is the next step -- see plan/buck2-port.md.)
    # THE PROJECT, not a skeleton. Feeding this derivation a tree whose C family was
    # emptied was tried and REVERTED, and the reason is worth keeping: this derivation does
    # not only analyse. It materialises the in-process artifacts, and a staged farm of
    # GENERATED headers is produced by running a generator, which is a host tool this
    # derivation BUILDS from first-party C -- src/startup:rtsig and src/libelfloader:wrapgen
    # among them.
    #
    # An emptied rtsig.c does not fail to compile. It compiles cleanly, links, runs, and
    # writes an EMPTY header, so the graph comes out quietly wrong and the failure lands
    # somewhere far away. A mechanism whose failure mode is silence is worse than the cost
    # it was removing.
    #
    # scripts/buck-skeleton.py is kept: the idea is sound for the ANALYSIS half, and it is
    # verified to load the identical target graph. What it needs first is the codegen input
    # closure, so that exactly the files this derivation compiles keep their contents.
    #
    # THAT CLOSURE NOW EXISTS (#56, scripts/buck-codegen-closure.py): 1,743 files of 74,621
    # must keep real contents, and all but FIVE were already covered, the five being
    # rtsig.c, wrapgen.cpp and three libsimple files. buck-skeleton.py keeps them. Pass
    # skeleton = true to try it, which is what packages.darling-buck2-graph-skeleton does.
    # It stays OFF here until the graph it produces is shown equivalent by
    # scripts/buck-graph-equiv.py, because a wrong skeleton fails SILENTLY.
    src = if skeleton then skeletonSrc else projectSrc;

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

      ${assembleProject}

      # The machine-local config scripts/buck-setup.nu writes by hand, here from the
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

      # Split the two audiences apart. The dump records staged and treelinks paths RELATIVE
      # to its output directory, so moving the directories wholesale keeps every recorded
      # path valid; the lowering just resolves them against the data output instead.
      mkdir -p "$data"
      for d in staged treelinks; do
        if [ -e "$out/$d" ]; then mv "$out/$d" "$data/$d"; fi
      done

      runHook postBuild
    '';

    passthru = {
      inherit targets;
      # WHICH PROJECT FILES EACH TARGET READS (#56). Its own derivation, over the REAL tree,
      # because it is the only answer that depends on file CONTENTS: a quoted include is
      # found by parsing #include "..." out of the file. It is a python walk rather than a
      # buck2 build, 125 seconds measured, and it is content addressed, so editing a .c
      # changes no file NAME, the output is byte identical and nothing downstream moves.
      # Adding an include does change it, which is exactly when consumers should rebuild.
      sources = sourcesDrv;
    };
  };

  sourcesDrv = pkgs.stdenv.mkDerivation {
    name = "darling-buck2-sources";
    src = projectSrc;
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    nativeBuildInputs = [
      pkgs.python3
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.bash
    ];
    dontConfigure = true;
    dontInstall = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      ${assembleProject}
      mkdir -p "$out"
      python3 ${../../scripts/buck2-graph-sources.py} \
        ${graph}/graph.json ${graph.data} "$out"
      runHook postBuild
    '';
  };
in
  graph
