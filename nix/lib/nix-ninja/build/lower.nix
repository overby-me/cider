# Lower a Ninja build graph (from `rust-ninja -t graph-json`) to Nix
# derivations: one derivation per edge, no import-from-derivation beyond the
# single graph-extraction step. A sibling to nix/lib/buck2/build/lower.nix.
#
# Model: a virtual build tree rooted at the Ninja build directory. Every edge
# output has a stable build-dir-relative path (exactly the string Ninja uses).
# Each edge's derivation stages its inputs into a working tree — a producer
# edge's whole `$out` tree is symlinked in (cp -rs, so transitive files and
# symlink targets travel along and large trees are never copied), while source
# inputs are copied as real files so relative `#include` and sibling lookups
# resolve — then runs the fully-expanded command (which references build-dir-
# relative paths) and exports the resulting tree as `$out`. Dependencies flow
# through store-path interpolation in the staging commands only, so an edge
# that merely names a peer's path creates no derivation dependency.
#
# mkLower { pkgs; src; toolchain; } -> { lowerGraph }
# lowerGraph graph -> { drvForOutput; producerOf; edgeDrvs; ... }
{
  pkgs,
  src,
  # Packages placed on PATH for every edge command. CMake-generated Ninja uses
  # absolute compiler paths so needs little; hand-written fixtures invoking
  # `cc`/`ar`/... need a toolchain here.
  toolchain ? [pkgs.stdenv.cc pkgs.coreutils],
  # Store paths every edge must have mounted (e.g. the configured build dir),
  # for absolute references we do not rewrite. Needed because we discard the
  # graph JSON's string context (see buildNinjaProject).
  extraInputs ? [],
  # Store paths CMake baked absolute references to (the source tree, and the
  # configured build dir for generated headers). For each, an edge's absolute
  # references under it are rewritten to build-dir-relative paths and the
  # individual files / include dirs are staged content-addressed, so a compile
  # depends only on the sources it actually reads — editing one `.c` rebuilds
  # only its object, not its siblings. When empty (hand-written manifests),
  # relative source inputs are staged instead.
  rewriteRoots ? [],
  # Whole-tree store-path substitutions applied to each command, as a list of
  # { from; to } strings. Used for the configured build dir: `from` is CMake's
  # build-dir store path (which changes on every reconfigure), `to` a
  # content-addressed copy of it (stable when only sources change), mounted via
  # `extraInputs`. Generated headers under `-I<builddir>` thus resolve while
  # staying cached across source edits.
  subs ? [],
  # Store paths (real source tree + configured build dir) to mount whole for the
  # per-compile dependency scan. When non-empty, compile edges (deps=gcc/msvc)
  # are staged depfile-precisely: a `-M` preprocess scan with these mounted
  # discovers the exact headers read (including source-relative `#include`s that
  # `-I` cannot express), and only those individual files are staged. Requires
  # `rewriteRoots` to cover the same trees. Empty = the include-dir heuristic.
  scanMounts ? [],
}: let
  inherit (pkgs) lib;
  inherit (builtins) filter concatMap listToAttrs elemAt length genList elem;

  esc = lib.escapeShellArg;

  # Derivation names must not carry string context. Graph strings inherit the
  # graph-json readFile's context (which transitively references the configured
  # build dir), so strip it before using a path as a name; the command strings
  # keep their context so Nix still mounts the referenced store paths.
  sanDrv = s:
    "ninja-"
    + lib.strings.sanitizeDerivationName
    (builtins.replaceStrings ["/" ":"] ["-" "-"]
      (builtins.unsafeDiscardStringContext s));

  indices = xs: genList (i: i) (length xs);

  # A source artifact: a build-dir-relative path not produced by any edge.
  # Turn it into a content-addressed store path so edits re-key only its
  # consumers.
  srcStorePath = rel:
    builtins.path {
      path = src + "/${rel}";
      name = "ninja-src-" + lib.strings.sanitizeDerivationName rel;
    };

  # CMake (and generated wrappers like mig) hardcode a handful of host tool
  # paths (/bin/mkdir, /usr/bin/env, ...) that do not exist in the pure edge
  # sandbox. Rewrite them to PATH-relative so the edge toolchain provides them.
  # /bin/sh is intentionally left alone (Nix mounts it). rmdir is listed before
  # rm so the longer path wins the left-to-right replaceStrings scan.
  toolPathSubs = concatMap (t: [
    {
      from = "/usr/bin/${t}";
      to = t;
    }
    {
      from = "/bin/${t}";
      to = t;
    }
  ]) ["mkdir" "rmdir" "rm" "mv" "cp" "ln" "cat" "chmod" "chown" "touch" "test" "true" "false" "env" "sed"];
in {
  lowerGraph = graph: let
    inherit (graph) edges;

    edgeOutputs = e: e.outputs ++ e.implicit_outputs;
    edgeInputs = e: e.inputs ++ e.implicit_inputs ++ e.order_only_inputs;

    # An edge with no command produces nothing to run: `phony` aliases and
    # CMake's ordering helper edges (e.g. `cmake_object_order_depends_*`). We
    # flatten these away when resolving a consumer's dependencies rather than
    # giving them a derivation.
    isNoOp = e: e.phony || e.command == null || e.command == "";

    # Absolute paths (store paths for sources/toolchains, as CMake bakes) are
    # available in every edge's sandbox automatically once the command string
    # references them — Nix mounts referenced store paths. Only *relative*
    # inputs are project sources we must stage. `.` (the build dir) and other
    # non-file order-only markers are ignored.
    isAbsolute = p: lib.hasPrefix "/" p;
    isStageableSource = p: !(isAbsolute p) && p != "." && p != "";

    # output path -> producing edge index
    producerOf = listToAttrs (concatMap (i:
      map (o: {
        name = o;
        value = i;
      }) (edgeOutputs (elemAt edges i)))
    (indices edges));

    isProduced = p: producerOf ? ${p};

    # Resolve an input to the set of *real* (command-bearing) producer edge
    # indices it depends on, flattening no-op aliases/ordering edges.
    realProducers = p:
      if !(isProduced p)
      then []
      else let
        i = producerOf.${p};
        e = elemAt edges i;
      in
        if isNoOp e
        then lib.unique (concatMap realProducers (edgeInputs e))
        else [i];

    # Relative source inputs to stage, flattening through no-op edges.
    realSources = p:
      if isProduced p
      then let
        e = elemAt edges producerOf.${p};
      in
        if isNoOp e
        then lib.unique (concatMap realSources (edgeInputs e))
        else []
      else lib.optionals (isStageableSource p) [p];

    # ---- content-addressed rewriting of CMake's absolute references --------
    # The rewrite roots are disjoint store paths (source tree, configured build
    # dir), so an absolute path is under at most one.
    rootFor = p: let
      hits = filter (r: lib.hasPrefix (toString r + "/") p) rewriteRoots;
    in
      if hits == []
      then null
      else builtins.head hits;
    underAnyRoot = p: rootFor p != null;
    relUnder = p: lib.removePrefix (toString (rootFor p) + "/") p;

    # An individual content-addressed copy of the file/dir at absolute path `p`,
    # so an edge depends only on the specific inputs it reads.
    indivOf = p:
      builtins.path {
        # unsafeDiscardStringContext: the path is built from `rootFor p` (a rewrite
        # root, e.g. cmakeSrcStore), whose string context would otherwise propagate
        # into this content-addressed copy -- making the whole source tree an input
        # of every edge/group derivation and defeating per-input isolation. The file
        # still exists at eval time, so builtins.path imports it fresh with no ref
        # back to the containing store path.
        path = builtins.unsafeDiscardStringContext (toString (rootFor p) + "/" + relUnder p);
        name = "src-" + lib.strings.sanitizeDerivationName (relUnder p);
      };

    # True if `p` is itself a symlink. `builtins.readFileType` follows symlinks
    # (so it never returns "symlink"); the parent's `readDir` is lstat-based and
    # does report "symlink". Staging a symlink via `builtins.path` aborts eval,
    # so callers skip these — the real target is reachable under its own path.
    # `builtins.path`/`readFileType` *abort* (and NOT tryEval-catchable — the
    # error propagates through `tryEval`) when any component of the path is a
    # symlink. CMake produces such paths (e.g. `.../libsyscall/foo` where
    # `libsyscall` is a symlink to the top-level libsyscall). So detect symlink
    # components without ever traversing one: walk from the (real) rewrite root
    # down via `readDir` of real dirs, stopping at the first symlink.
    hasSymlinkComponent = p: let
      root = rootFor p;
      parts = filter (x: x != "") (lib.splitString "/" (relUnder p));
      walk = dir: ps:
        if ps == []
        then false
        else let
          h = builtins.head ps;
          entries = builtins.readDir dir;
        in
          if !(entries ? ${h})
          then false # missing; pathExists handles it
          else if entries.${h} == "symlink"
          then true
          else if entries.${h} == "directory"
          then walk (dir + "/${h}") (builtins.tail ps)
          else false; # regular file component
    in
      if root == null
      then false
      else walk (toString root) parts;

    # Stageable via `builtins.path` only if it exists and neither it nor any
    # ancestor is a symlink; `safeRegular` additionally requires a regular file.
    safeNotSymlink = p: builtins.pathExists p && !(hasSymlinkComponent p);
    safeRegular = p: safeNotSymlink p && builtins.readFileType p == "regular";

    # The Mach/kernel RPC interface directories in an SDK `usr/include`: their
    # `.defs` and `.h` are symlinks into the tree's osfmk, which a mig edge reads
    # through `<mach/...>` / `<device/...>` includes but whose target dir it does
    # not itself stage as an -I.
    ifaceDirs = ["mach" "mach_debug" "device" "servers" "machine"];
    # Relative paths of every symlink under one of `ifaceDirs` in real dir `base`
    # (walking real dirs only, lstat readDir, never following a symlink). We stage
    # the *followed* content of just these in place — scoping to the interface
    # dirs (a couple hundred files) rather than the whole SDK (thousands of
    # framework symlinks), and using content-addressed `builtins.path` rather than
    # a cp -rL of the tree, keeps fine-grained caching intact. Other headers a
    # compile edge reads are found by the depfile scan; mig edges (no scan)
    # resolve their `<mach/*>` includes here.
    ifaceSymlinksUnder = base: let
      collectAll = sub: let
        dir = toString base + "/${sub}";
        entries = builtins.readDir dir;
      in
        concatMap (
          n: let
            rel = "${sub}/${n}";
            t = entries.${n};
          in
            if t == "symlink"
            then [rel]
            else if t == "directory"
            then collectAll rel
            else []
        )
        (builtins.attrNames entries);
      top = builtins.readDir (toString base);
    in
      concatMap (
        n:
          if (top.${n} or "") == "directory" && elem n ifaceDirs
          then collectAll n
          else []
      )
      (builtins.attrNames top);

    # Rewrite every root prefix in a command to the edge's own `$out` (the
    # merged working tree the edge runs in): `<root>/x` -> `$out/x`, and a bare
    # `<root>` (e.g. `-I<builddir>`) -> `$out`. The `/` form is listed first so
    # it wins where both could match. Using the absolute `$out` (expanded by the
    # builder shell) rather than a relative "" keeps output paths and `cd`
    # targets consistent: CMake custom commands that `cd` into a subdirectory
    # before writing a build-root-relative output would otherwise have that
    # output resolved against the subdirectory and doubled
    # (`sub/dir/sub/dir/out`). `$out`-absolute paths are immune to the `cd`.
    stripRoots = cmd:
      builtins.replaceStrings
      (concatMap (r: [(toString r + "/") (toString r)]) rewriteRoots)
      (concatMap (_: ["$out/" "$out"]) rewriteRoots)
      cmd;

    # Absolute include directories the command references under a root
    # (`-I<root>/...`, joined form as CMake emits).
    incAbsDirs = cmd:
      lib.unique (
        filter underAnyRoot
        (map (t: lib.removePrefix "-I" t)
          (filter (t: lib.hasPrefix "-I/" t) (lib.splitString " " cmd)))
      );

    # ---- depfile-precise header discovery (compile edges) ------------------
    depfilePrecise = scanMounts != [];
    # A compile edge: emits a depfile, declares a gcc/msvc deps mode, and takes
    # a source file as input. The source-input test excludes link edges, which
    # (in CMake) also carry a gcc deps mode and a `link.d` depfile but take
    # object/archive inputs, so a `-M` scan of them is meaningless.
    sourceExts = [".c" ".cc" ".cpp" ".cxx" ".c++" ".m" ".mm" ".s" ".S"];
    hasSourceInput = e:
      lib.any (i: lib.any (ext: lib.hasSuffix ext i) sourceExts) (edgeInputs e);
    isCompile = e:
      e.depfile
      != null
      && e.depfile != ""
      && (e.deps == "gcc" || e.deps == "msvc")
      && hasSourceInput e;

    # Turn a compile command into a preprocess-only `-M` dependency scan: drop
    # the object-output and codegen flags, append `-M -MF "$DEPS_OUT"`.
    scanDropArg = ["-o" "-MF" "-MT" "-MQ" "-MJ"];
    scanDrop = ["-c" "-MD" "-MMD" "-MP" "-M" "-MM" "-MG"];
    scanCommand = cmd: let
      toks = filter (t: t != "") (lib.splitString " " cmd);
      step = acc: t:
        if acc.skip
        then {
          inherit (acc) out;
          skip = false;
        }
        else if elem t scanDropArg
        then {
          inherit (acc) out;
          skip = true;
        }
        else if elem t scanDrop
        then acc
        else {
          out = acc.out ++ [t];
          skip = false;
        };
      kept =
        (builtins.foldl' step {
            out = [];
            skip = false;
          }
          toks).out;
    in
      builtins.concatStringsSep " " (kept ++ ["-M" "-MF" ''"$DEPS_OUT"'']);

    # Parse a makefile-style depfile (`target.o: a.h b.h \` + continuations)
    # into its prerequisite paths. Assumes no spaces in paths (the common case).
    parseDepfile = content: let
      joined = builtins.replaceStrings ["\\\n"] [" "] content;
      parts = lib.splitString ":" joined;
      afterColon =
        if length parts < 2
        then ""
        else builtins.concatStringsSep ":" (lib.drop 1 parts);
      toks =
        lib.splitString " "
        (builtins.replaceStrings ["\n" "\r" "\t"] [" " " " " "] afterColon);
    in
      lib.unique (filter (t: t != "" && t != "\\") toks);

    # A generated header may be `#include <...>`d by a compile edge that does not
    # declare a dependency on it: the monolithic build only satisfies the ordering
    # by luck of build order, which the ninja graph never encodes (e.g. libsyscall's
    # mach_init.c includes the generated `darlingserver/rpc.h`, yet the libsyscall
    # target's order-only barrier lists no darlingserver output). Collect once,
    # across the whole graph, every generated header's containing directories (each
    # ancestor up to the producing derivation's root) as -I flags, so any compile
    # scan can resolve such an include whatever prefix names it. clang ignores -I
    # dirs that do not exist, so the (deliberate) over-inclusion is harmless.
    headerExts = [".h" ".hpp" ".hxx" ".hh" ".ipp" ".inc" ".def" ".defs"];
    isHeaderPath = o: lib.any (ext: lib.hasSuffix ext o) headerExts;
    # True if edge `i` reaches a compile edge through its real producers. A
    # compile edge's derivation forces a scan that itself references
    # `generatedHeaderIncs`, so a header producer that transitively depends on one
    # (e.g. a mig edge, via migcom) cannot appear in that set without forming an
    # eval cycle. This is pure graph analysis (indices only, never a derivation),
    # so it is itself cycle-free. Pure generators (a python/awk codegen reading
    # only sources — e.g. the darlingserver rpc.h generator) are false, and their
    # headers are exactly the undeclared ones the scan cannot otherwise resolve;
    # a mig header, by contrast, already resolves through its declared producer.
    dependsOnCompileMemo = listToAttrs (map (i: {
        name = toString i;
        value = let
          e = elemAt edges i;
        in
          isCompile e
          || lib.any (j: dependsOnCompileMemo.${toString j})
          (concatMap realProducers (edgeInputs e));
      })
      (indices edges));
    generatedHeaderIncs = lib.unique (concatMap (
        i: let
          e = elemAt edges i;
          pdrv = edgeDrvs.${toString i};
        in
          concatMap (
            o: let
              rel =
                if underAnyRoot o
                then relUnder o
                else o;
              dirs = lib.init (filter (x: x != "") (lib.splitString "/" rel));
              ancestors =
                lib.genList (n: builtins.concatStringsSep "/" (lib.take n dirs))
                (length dirs + 1);
            in
              map (a: "-I${pdrv}" + lib.optionalString (a != "") "/${a}") ancestors
          )
          (filter isHeaderPath (edgeOutputs e))
      )
      (filter
        (i:
          !(isNoOp (elemAt edges i))
          && !dependsOnCompileMemo.${toString i}
          && lib.any isHeaderPath (edgeOutputs (elemAt edges i)))
        (indices edges)));

    # A generated mig header may be `#include <...>`d by a compile in the same
    # source module without the ninja graph declaring the dependency, and (unlike
    # rpc.h) without the compile even carrying a literal `-I` to the mig output dir
    # (cmake wires it via object-library/target includes, e.g. syslog's asl.c ->
    # <asl_ipc.h> generated in aslcommon). `generatedHeaderIncs` excludes mig headers
    # to avoid an eval cycle, and the per-edge `genIncs` only covers *declared*
    # producers, so neither resolves it. Fix: give each compile the mig-header dirs
    # from producers *in its own source module* (src/external/<m> or src/<m>). Far
    # lighter than a graph-wide set (a compile depends only on its module's mig
    # edges), and it keys on the module rather than a literal -I dir.
    migHeaderProducerIdxs = filter
      (i:
        !(isNoOp (elemAt edges i))
        && dependsOnCompileMemo.${toString i}
        && lib.any isHeaderPath (edgeOutputs (elemAt edges i)))
      (indices edges);
    # The source-module key of a build-dir-relative path: src/external/<m>, src/<m>,
    # or the first component. Used to relate a compile to mig headers near it.
    moduleKey = p: let
      cs = filter (x: x != "") (lib.splitString "/" p);
      n = length cs;
    in
      if n >= 3 && elemAt cs 0 == "src" && elemAt cs 1 == "external"
      then "src/external/" + elemAt cs 2
      else if n >= 2 && elemAt cs 0 == "src"
      then "src/" + elemAt cs 1
      else if n >= 1
      then elemAt cs 0
      else "";
    # Map: source module -> [{ p = mig producer index; dir = header's build-dir-rel
    # dir }]. Pure string/index analysis over declared outputs (references no drvs).
    migHeadersByModule = lib.foldl' (
        acc: i:
          lib.foldl' (
            acc2: o: let
              rel = if underAnyRoot o then relUnder o else o;
              mod = moduleKey rel;
            in
              acc2 // {${mod} = (acc2.${mod} or []) ++ [{p = i; dir = builtins.dirOf rel;}];}
          )
          acc (filter isHeaderPath (edgeOutputs (elemAt edges i)))
      ) {}
      migHeaderProducerIdxs;
    # Per-mig-producer FULL transitive input closure (data + order-only). nix-ninja
    # stages order-only inputs as real derivation deps too, so any of them can close
    # a Nix eval cycle. Memoized per producer index; the BFS is over the acyclic
    # ninja graph so it terminates.
    #
    # Cycle to avoid: giving compile i the flag -I<M> makes edgeDrvs.i depend on
    # edgeDrvs.M; if M transitively depends on i that is
    # edgeDrvs.i -> edgeDrvs.M -> ... -> edgeDrvs.i (infinite recursion). So i may
    # take producer M's mig -I only if i is NOT in M's closure -- exactly the unsafe
    # set. History: a global "any mig producer reaches i" exclusion was correct for
    # the migcom cycle but, at full-graph scope, over-excluded compiles a far
    # producer merely order-only-reached (syslog asl.c lost its aslcommon inc and
    # could not find generated <asl_ipc.h>); a data-only variant fixed asl.c but let
    # an order-only cycle back in. Per-pair against the full closure does both.
    migProducerClosure = let
      producersOf = j: concatMap realProducers (edgeInputs (elemAt edges j));
      closureOf = m: let
        go = frontier: acc:
          if frontier == []
          then acc
          else let
            fresh = filter (j: !(acc ? ${toString j})) (lib.unique (concatMap producersOf frontier));
          in
            go fresh (acc // listToAttrs (map (j: {name = toString j; value = true;}) fresh));
      in
        go [m] {};
    in
      listToAttrs (map (m: {name = toString m; value = closureOf m;}) migHeaderProducerIdxs);
    # Mig-header -I flags for compile edge i: the dirs of mig headers produced in i's
    # own source module, minus any producer whose closure contains i (cycle safety).
    migHeaderIncsFor = i: let
      outs = edgeOutputs (elemAt edges i);
      mod =
        if outs == []
        then ""
        else moduleKey (let o = builtins.head outs; in if underAnyRoot o then relUnder o else o);
      safe = filter
        (h: !((migProducerClosure.${toString h.p} or {}) ? ${toString i}))
        (migHeadersByModule.${mod} or []);
    in
      lib.unique (map (h: "-I${edgeDrvs.${toString h.p}}/${h.dir}") safe);

    # The exact project files (under a rewrite root) a compile edge reads,
    # discovered by scanning. System headers (toolchain store paths) are already
    # mounted and need no staging, so they are filtered out here.
    #
    # A generated input (a source/header produced by another edge, e.g. a bison
    # `parser.c` or a mig header) exists in neither mounted tree — it is built,
    # not configured — so the raw command's absolute `<root>/<gen>` reference
    # would be a missing file and the scan would abort. Rewrite each such
    # reference to the producing edge's output (which the string then pulls in
    # as a dependency) so the preprocessor can read it. Non-generated inputs are
    # untouched and still resolve through the mounted source/configured trees.
    scanDrvOf = i: let
      e = elemAt edges i;
      # Each generated input (produced by another edge), normalised to the
      # build-dir-relative path the producer writes plus that producer's drv.
      # An input may be listed absolutely (`<root>/rel`, CMake's usual form and
      # also the producer's implicit output) or relatively (`rel`).
      genPairs =
        concatMap (
          g: let
            ids = realProducers g;
          in
            lib.optionals (ids != []) [
              {
                rel =
                  if underAnyRoot g
                  then relUnder g
                  else g;
                pdrv = edgeDrvs.${toString (builtins.head ids)};
              }
            ]
        )
        (filter isProduced (edgeInputs e));
      # (a) Rewrite every `<root>/rel` the command could use to the producer's
      # copy, so a generated file referenced by path resolves (and the string
      # pulls the producer in as a dependency).
      genSubs =
        concatMap (
          x:
            map (r: {
              from = toString r + "/" + x.rel;
              to = "${x.pdrv}/" + x.rel;
            })
            rewriteRoots
        )
        genPairs;
      # (b) Add producer output directories as include paths so a generated
      # header pulled in by name resolves during the preprocess:
      #   - directly next to another producer output (`#include "parser.h"`, a
      #     bison `-d` header beside a flex `lexer.c`), and
      #   - via `<...>` by mirroring the compile's own under-root -I dirs onto
      #     each *declared* producer of this edge (flattening phony order-only
      #     barriers, so a mig header like `<mach/mach_port_internal.h>` resolves
      #     from the mig edge that wrote it). This stays a DAG — an edge's own
      #     declared producers are upstream of it — so unlike the graph-wide
      #     `generatedHeaderIncs` it needs no compile-dependency filter. clang
      #     ignores -I dirs that do not exist.
      genDrvs =
        lib.unique (map (i: edgeDrvs.${toString i})
          (concatMap realProducers (filter isProduced (edgeInputs e))));
      genIncs = lib.unique (
        (map (x: "-I${x.pdrv}/" + builtins.dirOf x.rel) genPairs)
        ++ concatMap
        (pd: map (d: "-I${pd}/${relUnder d}") (filter underAnyRoot (incAbsDirs e.command)))
        genDrvs
      );
      scanCmd =
        builtins.replaceStrings
        (map (s: s.from) genSubs) (map (s: s.to) genSubs)
        (scanCommand e.command);
      scanDrv =
        pkgs.runCommand "ninja-scan-${sanDrv (builtins.head (edgeOutputs e))}" {
          nativeBuildInputs = toolchain ++ scanMounts;
        } ''
          export DEPS_OUT=$out
          ${scanCmd} ${lib.concatStringsSep " " (genIncs ++ generatedHeaderIncs ++ migHeaderIncsFor i)}
        '';
    in
      scanDrv;

    # NOTE on parallelism: each per-edge scan is an import-from-derivation, and Nix's
    # evaluator forces IFDs serially, so at CMake scale the scans dominate first-build
    # wall-clock. They cannot simply be batched into one parallel realization, though:
    # a compile's scan must resolve `<generated.h>` includes, which requires that
    # header's PRODUCER edge to be built first, and when that producer is itself a
    # compile its build needs ITS scan -- so the scans form a genuine build-order DAG
    # (forcing them all up front closes a scan -> producer-edge -> scan cycle). Nix
    # DOES schedule the real build graph in parallel; only this eval-time discovery is
    # serial, and every scan is content-addressed so it is paid once and then cached.
    # Eliminating it for grouped builds (resolve headers at group-build time instead
    # of scanning) is the real fix -- tracked separately.
    scanDepsOf = i:
      # unsafeDiscardStringContext: the depfile paths are substrings of the scan
      # derivation's OUTPUT, whose string context transitively references the mounted
      # source tree (cmakeSrcStore). That context would otherwise ride along on every
      # `relUnder p` substring (via `esc (relUnder p)` in the staging script) and make
      # the WHOLE source tree an inputSrc of each consuming edge/group derivation --
      # silently defeating per-input isolation (an edit to any source rehashes every
      # edge). indivOf re-imports each header content-addressed via `rootFor`, so the
      # real per-file dependency is preserved without the whole-tree reference.
      filter underAnyRoot
        (parseDepfile (builtins.unsafeDiscardStringContext (builtins.readFile (scanDrvOf i))));

    # ---- one derivation per (non-phony) edge -------------------------------
    mkEdge = i: let
      e = elemAt edges i;
      ins = edgeInputs e;
      depIds = lib.unique (concatMap realProducers ins);
      outs = edgeOutputs e;

      # Files to stage individually under a rewrite root. For compile edges with
      # a depfile scan available, that is the exact set the compiler reads
      # (source + all headers, including source-relative ones); otherwise the
      # explicit inputs plus a copy of each `-I` directory.
      useScan = depfilePrecise && isCompile e;
      relSrcs = lib.unique (filter
        (r: safeNotSymlink (src + "/${r}"))
        (concatMap realSources ins));
      # An `-I` dir or explicit input can point at a path that is absent from the
      # store copy of a root (an empty dir Nix does not preserve, or an optional
      # include CMake emits unconditionally). Staging it via `builtins.path`
      # would abort eval, so skip anything that no longer exists; clang tolerates
      # a missing `-I` dir.
      rootSrcs =
        if useScan
        then filter builtins.pathExists (scanDepsOf i)
        else
          # Declared under-root inputs, plus under-root *files named in the
          # command* that CMake did not declare (custom commands often reference
          # a helper script/template like `awk -f .../mig.awk` without listing it
          # in DEPENDS; a linker names an alias list inside a comma-joined
          # `-Wl,-alias_list,<path>` token, so split on commas as well as spaces).
          # Directories and not-yet-produced outputs are excluded.
          lib.unique (
            (filter (p: underAnyRoot p && safeNotSymlink p) ins)
            ++ (filter
              (p: underAnyRoot p && safeRegular p)
              (concatMap (lib.splitString ",") (lib.splitString " " e.command)))
          );
      # `builtins.path` aborts on a symlink root, and some CMake `-I` dirs are
      # symlinks (e.g. libsystem_kernel/libsyscall -> the top-level libsyscall);
      # skip them — the real directory is reachable and staged under its own path.
      rootIncs =
        if useScan
        then []
        else filter safeNotSymlink (incAbsDirs e.command);
      # -I dirs, inputs and command-named paths that traverse a symlink
      # (`.../libsyscall/mach/x.defs`, libsyscall -> ../../../libsyscall). The
      # symlink they go through is otherwise pruned as broken (its target is not
      # staged), so the reference dangles. `builtins.path` (via indivOf) *does*
      # follow symlinks whose target exists, so stage the followed real content
      # directly at the reference's own path (only when it exists — a broken
      # symlink would abort eval, so pathExists filters those out).
      symlinkTargets = lib.unique (filter
        (p: underAnyRoot p && hasSymlinkComponent p && builtins.pathExists p)
        (incAbsDirs e.command
          ++ ins
          ++ concatMap (lib.splitString ",") (lib.splitString " " e.command)));

      command = let
        stripped =
          if rewriteRoots == []
          then e.command
          else stripRoots e.command;
        withSubs =
          builtins.replaceStrings (map (s: s.from) subs) (map (s: s.to) subs) stripped;
        base =
          builtins.replaceStrings
          (map (s: s.from) toolPathSubs) (map (s: s.to) toolPathSubs)
          withSubs;
      in
        # A compile may `#include <generated/header.h>` (a generated
        # `darlingserver/rpc.h`) that ninja never declared as a dependency, so it
        # is not staged into $out and the command's own $out-relative -I cannot
        # find it. Append the producer-output include dirs (the same set the scan
        # uses) so the compiler reads it straight from the producer; the store
        # path in the flag makes Nix mount that output.
        base
        + lib.optionalString (useScan && generatedHeaderIncs != [])
        (" " + lib.concatStringsSep " " generatedHeaderIncs)
        + lib.optionalString (useScan && migHeaderIncsFor i != [])
        (" " + lib.concatStringsSep " " (migHeaderIncsFor i));

      # `cp -rs` each producer's whole output tree in. A path one producer
      # provides as a real dir may already be a symlink (or under a symlinked
      # parent) from an earlier producer — cp cannot overwrite a non-dir with a
      # dir. For each dir this producer contributes whose dest is currently a
      # non-dir, realize_writable it first (de-symlinks the path, re-linking the
      # content) so cp merges into a real dir; the exit is tolerated for any
      # residual conflict. The test is cheap and realize_writable runs only on
      # the rare conflict.
      stageDeps =
        lib.concatMapStringsSep "\n"
        (id: let
          d = edgeDrvs.${toString id};
        in ''
          (cd ${d} && find . -mindepth 1 -type d) | while IFS= read -r sub; do
            s=''${sub#./}
            if [ -L "$s" ] || { [ -e "$s" ] && [ ! -d "$s" ]; }; then realize_writable "$s"; fi
          done
          cp -rsf --no-preserve=mode ${d}/. ./ || true
          # Replace staged executable *tools* (not libraries) with real copies: a
          # tool that resolves its own argv[0] and execs a sibling by that resolved
          # dir would otherwise look inside the producer store path, which lacks
          # siblings staged from other producers (cctools `ar` execs a co-located
          # `ranlib`, built by a separate edge). Libraries are excluded — they are
          # linked, not run, and are large.
          (cd ${d} && find . -type f -perm -u+x ! -name '*.dylib' ! -name '*.so' ! -name '*.so.*' ! -name '*.a' ! -name '*.o') | while IFS= read -r f; do
            g=''${f#./}
            if [ -L "$g" ]; then
              t=$(readlink -f "$g" 2>/dev/null) || continue
              [ -f "$t" ] && { rm -f "$g"; cp --no-preserve=mode "$t" "$g" && chmod +x "$g"; } || true
            fi
          done
        '')
        depIds;
      # Skip if the path is already staged: the same header can be both a scanned
      # input here and a producer output copied in by stageDeps (a source header
      # `install`ed into the SDK, e.g. darling/emulation/*.h), whose read-only
      # symlinked parent then makes a second `install` fail "cannot remove". The
      # first copy is authoritative, so leave it. Preserve the execute bit (a
      # command may run a staged file directly, the rpc.h generator is
      # `.../generate-rpc-wrappers.py <args>`); `builtins.path` keeps the source's
      # exec bit, so test the content-addressed copy.
      stageRelSrcs =
        lib.concatMapStringsSep "\n"
        (s: ''
          if [ ! -e ${esc s} ]; then
            install -Dm644 ${srcStorePath s} ${esc s}
            if [ -x ${srcStorePath s} ]; then chmod +x ${esc s}; ${shebangSed (esc s)} fi
          fi
        '')
        relSrcs;
      stageRootSrcs =
        lib.concatMapStringsSep "\n"
        (p: ''
          if [ ! -e ${esc (relUnder p)} ]; then
            install -Dm644 ${indivOf p} ${esc (relUnder p)}
            if [ -x ${indivOf p} ]; then chmod +x ${esc (relUnder p)}; ${shebangSed (esc (relUnder p))} fi
          fi
        '')
        rootSrcs;
      stageIncs =
        lib.concatMapStringsSep "\n"
        (p: ''
          # A prior dir copy (a peer `-I` whose tree contains this path as a
          # child symlink) may have recreated this target as a dangling symlink;
          # `mkdir -p` then fails "File exists". Drop it first (only if it is a
          # broken symlink — never a real dir or a valid link).
          if [ -L ${esc (relUnder p)} ] && [ ! -e ${esc (relUnder p)} ]; then rm -f ${esc (relUnder p)}; fi
          mkdir -p ${esc (relUnder p)}
          # A real dir already staged here (e.g. a producer output tree under
          # `libsyscall`, or another -I copy) must win over an incoming symlink of
          # the same name; cp reports that one conflict but still copies the rest,
          # so tolerate its exit (diagnostics stay visible) rather than abort.
          cp -rsf --no-preserve=mode ${indivOf p}/. ${esc (relUnder p)}/ || true
          # `cp -rs` turns each *source symlink* in the tree into a link into the
          # read-only content-addressed copy, whose own relative target then points
          # outside that copy and dangles (an SDK `mach/*.defs` -> the tree's
          # osfmk, a `libsyscall` -> the top-level one). Re-create those links with
          # their *original* relative target so they resolve against the merged
          # $out tree, where the target is itself staged by another -I copy — and
          # so the later broken-link prune does not delete them. A path already
          # present as a real dir wins (never replaced by a link).
          (cd ${indivOf p} && find . -type l 2>/dev/null) | while IFS= read -r l; do
            d=${esc (relUnder p)}/"$l"
            if [ -d "$d" ] && [ ! -L "$d" ]; then continue; fi
            t=$(readlink "${indivOf p}/$l" 2>/dev/null) || continue
            ln -sfn "$t" "$d" 2>/dev/null || true
          done
        '')
        rootIncs;
      # Stage the followed real content of each Mach/kernel interface file reached
      # through a symlink whose osfmk target dir this edge does not itself stage,
      # so a mig `<mach/...>` / `<device/...>` include resolves. builtins.path
      # follows the link and is content-addressed, keeping fine-grained caching (a
      # cp -rL of the whole dir would pull in the entire source tree). Runs after
      # the prune and the -I copies so its real files win over a peer -I's
      # dangling symlink of the same name. Only the source tree (first rewrite
      # root) is walked — the configured tree's interface dirs hold symlinks to
      # not-yet-generated headers (a mig `clock.h`) that `builtins.path` aborts on.
      stageIfaceDeref =
        lib.concatMapStringsSep "\n"
        (p:
          lib.optionalString (rewriteRoots != [] && rootFor p == builtins.head rewriteRoots)
          (lib.concatMapStringsSep "\n" (
              rel: let
                orig = toString (rootFor p) + "/" + relUnder p + "/" + rel;
                content = builtins.path {
                  path = orig;
                  name = "iref-" + lib.strings.sanitizeDerivationName rel;
                };
              in
                lib.optionalString
                (builtins.pathExists orig && builtins.readFileType content == "regular")
                ''
                  rm -f ${esc (relUnder p + "/" + rel)}
                  install -Dm644 ${content} ${esc (relUnder p + "/" + rel)}
                ''
            )
            (ifaceSymlinksUnder (toString (rootFor p) + "/" + relUnder p))))
        rootIncs;
      # Stage the followed real content of each symlinked *file* reference (e.g.
      # a mig `.defs`) at its own through-symlink path, replacing the pruned
      # dangling symlink with a real file. `indivOf` follows the symlink;
      # readFileType on its (symlink-free) store path tells file from dir.
      #
      # Directories are deliberately NOT staged wholesale: a symlinked include
      # dir often holds child symlinks that point outside it (so a store copy of
      # the dir carries them as *broken* links), and cp -rs'ing that over the
      # tree would clobber real files the header scan already staged. Compile
      # edges get their exact headers from the scan (rootSrcs); other edges get
      # each file they name here.
      stageSymlinkTargets =
        lib.concatMapStringsSep "\n"
        (p: let
          r = relUnder p;
          cp = indivOf p;
        in
          lib.optionalString (builtins.readFileType cp == "regular") ''
            if [ -L ${esc r} ]; then rm -f ${esc r}; fi
            install -Dm644 ${cp} ${esc r}
            if [ -x ${cp} ]; then chmod +x ${esc r}; ${shebangSed (esc r)} fi
          '')
        symlinkTargets;
      mkOutDirs =
        lib.concatMapStringsSep "\n"
        (o: ''
          realize_writable "$(dirname ${esc o})"
          # The output path itself may be a staged read-only symlink: a checked-in
          # source file (e.g. a committed mig `X.h`) that maps to the same merged
          # $out path as this edge's generated output. Drop the symlink so the
          # command writes a fresh real file instead of following the link into the
          # read-only store (mig's fopen would otherwise fail EACCES).
          if [ -L ${esc o} ]; then rm -f ${esc o}; fi
        '')
        outs;
      rspStage = lib.optionalString (e.rspfile != null && e.rspfile != "") ''
        mkdir -p "$(dirname ${esc e.rspfile})"
        printf '%s' ${esc (e.rspfile_content or "")} > ${esc e.rspfile}
      '';
      rspClean =
        lib.optionalString (e.rspfile != null && e.rspfile != "")
        ''rm -f ${esc e.rspfile}'';
      # Rewrite a script's absolute shebang to the toolchain's: `#!/bin/bash` and
      # `#!/usr/bin/env bash` -> the toolchain bash, `#!/usr/bin/env <x>` -> the
      # toolchain `env` (which then finds <x> on the edge PATH). The pure edge
      # sandbox provides neither /bin/bash nor /usr/bin/env; `/bin/sh` is left
      # alone (Nix mounts it). A direct sed, not `patchShebangs`, which silently
      # leaves the line when it cannot resolve the interpreter in the minimal
      # PATH. `p` is a shell-quoted path expression; no-op for non-scripts.
      shebangSed = p: ''
        if [ -f ${p} ] && [ "$(head -c2 ${p} 2>/dev/null)" = "#!" ]; then
          chmod u+w ${p} 2>/dev/null || true
          sed -i \
            -e "1s|^#! *\(/usr\)\?/bin/bash|#!${pkgs.bash}/bin/bash|" \
            -e "1s|^#! */usr/bin/env  *bash|#!${pkgs.bash}/bin/bash|" \
            -e "1s|^#! */usr/bin/env  *|#!${pkgs.coreutils}/bin/env |" \
            ${p}
        fi
      '';
      # A generated script output (e.g. the mig `build-mig` wrapper) carries such
      # a shebang; rewrite each. Absolute `$out/<rel>` because the edge command
      # may have cd'd into a WORKING_DIRECTORY subdir and not returned.
      patchOutShebangs =
        lib.concatMapStringsSep "\n"
        (o: let
          rel =
            if underAnyRoot o
            then relUnder o
            else o;
        in
          shebangSed ''"$out/${rel}"'')
        outs;
      # A ninja link/archive command whose linker step fails does not abort the
      # edge (the body has no `set -e`, and cmake link rules often end `&& :`), so
      # it exits 0 having produced no artifact; the miss then surfaces only far
      # downstream. Fail such an edge in place when it did not produce a declared
      # FINAL artifact (a dylib/archive, or an executable — a basename with no
      # extension, excluding CMake bookkeeping), so the real linker error is
      # visible in *this* edge's log. Object files / depfiles / generated sources
      # (with extensions) are left alone, so edges that skip an implicit output
      # are not tripped.
      checkOutputs =
        lib.concatMapStringsSep "\n"
        (o: let
          rel =
            if underAnyRoot o
            then relUnder o
            else o;
          base = builtins.baseNameOf o;
          isFinal =
            lib.hasSuffix ".dylib" o
            || lib.hasSuffix ".a" o
            || (!(lib.hasInfix "." base) && !(lib.hasInfix "CMakeFiles" o));
        in
          lib.optionalString isFinal ''
            if [ ! -e "$out/${rel}" ]; then
              echo "nix-ninja: edge produced no output ${rel}" >&2
              exit 1
            fi
          '')
        e.outputs;
    in
      pkgs.runCommand (sanDrv (builtins.head outs)) {
        nativeBuildInputs = toolchain ++ extraInputs;
        # Ninja commands are plain shell; keep the working tree as $out.
        preferLocalBuild = true;
        passthru = {edgeIndex = i;};
      } ''
        mkdir -p $out
        cd $out
        # Make an output directory real and writable. cp -rs stages -I dirs as
        # read-only symlinks into the source/configured store; when an edge (e.g.
        # mig) both reads inputs from and writes outputs into such a dir, writing
        # fails EACCES. Walk the path, and for each symlinked component replace it
        # with a real dir that re-links the original target's content (inputs stay
        # readable, new outputs are writable).
        realize_writable() {
          local p="$1" cur="" comp tgt oldIFS="$IFS"
          IFS='/'; set -- $p; IFS="$oldIFS"
          for comp in "$@"; do
            [ -z "$comp" ] && continue
            if [ -z "$cur" ]; then cur="$comp"; else cur="$cur/$comp"; fi
            if [ -L "$cur" ]; then
              tgt="$(readlink -f "$cur" 2>/dev/null || true)"
              rm -f "$cur"; mkdir -p "$cur"
              if [ -n "$tgt" ] && [ -d "$tgt" ]; then
                cp -rsf --no-preserve=mode "$tgt"/. "$cur"/ 2>/dev/null || true
              fi
            else
              mkdir -p "$cur"
            fi
          done
        }
        ${stageDeps}
        ${stageRelSrcs}
        ${stageRootSrcs}
        ${stageIncs}
        # Prune broken symlinks the cp -rs staging carried in from copied dir
        # trees (a child symlink whose target was not itself staged); left in
        # place they break the edge command's own mkdir/cd on those paths.
        find . -xtype l -delete 2>/dev/null || true
        ${stageIfaceDeref}
        ${stageSymlinkTargets}
        ${mkOutDirs}
        ${rspStage}
        ${command}
        ${patchOutShebangs}
        ${rspClean}
        ${checkOutputs}
      '';

    # Memoized derivations, keyed by stringified edge index. No-op edges
    # (phony / commandless ordering edges) get no derivation.
    edgeDrvs = listToAttrs (map (i: {
        name = toString i;
        value = mkEdge i;
      })
      (filter (i: !(isNoOp (elemAt edges i))) (indices edges)));

    # The derivation that produces a given output path (resolving phony).
    drvForOutput = p: let
      ids = realProducers p;
    in
      if ids == []
      then throw "nix-ninja: no edge produces '${p}'"
      else edgeDrvs.${toString (builtins.head ids)};

    # Whether `p` is produced by a phony / no-op edge -- an aggregate alias
    # like the top-level `all`, which has no file of its own but transitively
    # names every real target.
    isPhonyTarget = p: isProduced p && isNoOp (elemAt edges producerOf.${p});

    # The real file outputs to stage for target `p`, as `{ path; drv; }`. For a
    # real output that is just `p` from its producer; for a phony aggregate it is
    # every declared output of every real edge the phony resolves to (e.g. `all`
    # -> each sublibrary/tool's final artifact). Lets a caller materialize a
    # whole-graph build (`target = null` -> `default` -> `all`) instead of
    # trying to `cp` a nonexistent file named after the phony.
    realOutputsForTarget = p:
      lib.concatMap
        (i: map (o: {
          path = o;
          drv = edgeDrvs.${toString i};
        }) (edgeOutputs (elemAt edges i)))
        (realProducers p);

    # ---- grouped lowering (per-component): one derivation per edge GROUP -----
    # A group is a set of edges (a CMake subproject, from component-dag). Its
    # internal producer->consumer order and internal generated headers (mig/rpc)
    # are resolved by an emitted mini `build.ninja` run inside the group, so the
    # per-edge generated-header/cycle bridging is unnecessary here. Isolation
    # comes from staging only: the group's own declared sources, the include dirs
    # its commands name, and its EXTERNAL dependency groups' outputs (symlinked).
    #   groupOf : edgeIndex(int) -> groupId(string).  `groupOf = toString` recovers
    #   the per-edge behaviour (each edge its own group).
    lowerGroupsBy = groupOf: let
      realIds = filter (i: !(isNoOp (elemAt edges i))) (indices edges);
      # groupOf receives the EDGE (has .rule/.outputs/.command) so a caller can group
      # by rule or output path. The grouping MUST be acyclic across groups: a group
      # drv depends on its external dependency groups' drvs, so a cycle is an infinite
      # Nix-eval recursion (component-dag condenses SCCs to guarantee this).
      gidOf = listToAttrs (map (i: {name = toString i; value = groupOf (elemAt edges i);}) realIds);
      gid = i: gidOf.${toString i};
      groupIds = lib.unique (map gid realIds);
      idsInGroup = listToAttrs (map (g: {
          name = g;
          value = filter (i: gid i == g) realIds;
        })
        groupIds);
      groupOfOutput = p: let ids = realProducers p; in
        if ids == [] then null else gid (builtins.head ids);
      shebangSedG = p: ''
        if [ -f ${p} ] && [ "$(head -c2 ${p} 2>/dev/null)" = "#!" ]; then
          chmod u+w ${p} 2>/dev/null || true
          sed -i -e "1s|^#! *\(/usr\)\?/bin/bash|#!${pkgs.bash}/bin/bash|" \
                 -e "1s|^#! */usr/bin/env  *bash|#!${pkgs.bash}/bin/bash|" \
                 -e "1s|^#! */usr/bin/env  *|#!${pkgs.coreutils}/bin/env |" ${p}
        fi
      '';
      ninjaEsc = s: builtins.replaceStrings [" " ":" "$" "\n"] ["$ " "$:" "$$" " "] s;
      mkGroup = g: let
        myIds = idsInGroup.${g};
        mySet = listToAttrs (map (i: {name = toString i; value = true;}) myIds);
        allIns = concatMap (i: edgeInputs (elemAt edges i)) myIds;
        extProducerIds = lib.unique (filter (i: !(mySet ? ${toString i}))
          (concatMap realProducers allIns));
        extGroupDrvs = lib.unique (map (i: groupDrvs.${gid i}) extProducerIds);
        relSrcs = lib.unique (filter (r: safeNotSymlink (src + "/${r}"))
          (concatMap (i: concatMap realSources (edgeInputs (elemAt edges i))) myIds));
        # For compile edges use the depfile scan (mkEdge's approach): it stages the
        # EXACT headers a compile reads, following symlink-dirs like the SDK/mach
        # tree that coarse -I staging misses. Content-addressed, so the group stays
        # isolated. Non-compile edges use declared under-root inputs + command paths.
        rootSrcs = lib.unique (concatMap (i: let e = elemAt edges i; in
            if depfilePrecise && isCompile e
            then filter builtins.pathExists (scanDepsOf i)
            else (filter (p: underAnyRoot p && safeNotSymlink p) (edgeInputs e))
                 ++ (filter (p: underAnyRoot p && safeRegular p)
                      (concatMap (lib.splitString ",") (lib.splitString " " e.command))))
          myIds);
        # Only NON-compile edges contribute -I dir staging. Compile edges use the
        # scan (rootSrcs) for exact headers; staging their -I dirs would cp -rsf the
        # shim symlinks over the scan's real headers (mkEdge sets rootIncs=[] for
        # useScan edges for exactly this reason).
        rootIncs = lib.unique (filter safeNotSymlink
          (concatMap (i: let e = elemAt edges i; in
            if depfilePrecise && isCompile e then [] else incAbsDirs e.command) myIds));
        symlinkTargets = lib.unique (filter
          (p: underAnyRoot p && hasSymlinkComponent p && builtins.pathExists p)
          (concatMap (i: let e = elemAt edges i; in
            incAbsDirs e.command ++ edgeInputs e
            ++ concatMap (lib.splitString ",") (lib.splitString " " e.command)) myIds));
        # cp -rs each -I dir, then re-create its source symlinks with their original
        # targets so they resolve against the merged tree (mkEdge's stageIncs).
        stageIncs = lib.concatMapStringsSep "\n" (p: ''
          if [ -L ${esc (relUnder p)} ] && [ ! -e ${esc (relUnder p)} ]; then rm -f ${esc (relUnder p)}; fi
          mkdir -p ${esc (relUnder p)}
          cp -rsf --no-preserve=mode ${indivOf p}/. ${esc (relUnder p)}/ || true
          (cd ${indivOf p} && find . -type l 2>/dev/null) | while IFS= read -r l; do
            d=${esc (relUnder p)}/"$l"
            # Skip if a real file OR dir is already here: the depfile scan staged the
            # exact (deref'd) header at this path, and it must win over the shim
            # symlink (which would re-chain to an unstaged SDK path and dangle).
            if [ -e "$d" ] && [ ! -L "$d" ]; then continue; fi
            t=$(readlink "${indivOf p}/$l" 2>/dev/null) || continue
            ln -sfn "$t" "$d" 2>/dev/null || true
          done
        '') rootIncs;
        # Deref the Mach/kernel interface symlinks (mach/*.h etc.) to real content
        # so a `<mach/boolean.h>` include resolves (mkEdge's stageIfaceDeref).
        stageIfaceDeref = lib.concatMapStringsSep "\n" (p:
          lib.optionalString (rewriteRoots != [] && rootFor p == builtins.head rewriteRoots)
          (lib.concatMapStringsSep "\n" (rel: let
              orig = toString (rootFor p) + "/" + relUnder p + "/" + rel;
              content = builtins.path {path = orig; name = "iref-" + lib.strings.sanitizeDerivationName rel;};
            in lib.optionalString (builtins.pathExists orig && builtins.readFileType content == "regular") ''
                rm -f ${esc (relUnder p + "/" + rel)}
                install -Dm644 ${content} ${esc (relUnder p + "/" + rel)}
              '')
            (ifaceSymlinksUnder (toString (rootFor p) + "/" + relUnder p))))
          rootIncs;
        stageSymlinkTargets = lib.concatMapStringsSep "\n" (p: let r = relUnder p; cp = indivOf p; in
          lib.optionalString (builtins.readFileType cp == "regular") ''
            if [ -L ${esc r} ]; then rm -f ${esc r}; fi
            install -Dm644 ${cp} ${esc r}
            if [ -x ${cp} ]; then chmod +x ${esc r}; ${shebangSedG (esc r)} fi
          '') symlinkTargets;
        # topological order of the group's internal edges (producers first). The
        # group is acyclic (SCC-condensed), so this terminates; the ready==[] arm
        # is a defensive residue-dump, not expected.
        topo = let
          go = remaining: done: order:
            if remaining == [] then order
            else let
              intDeps = i: filter (j: mySet ? ${toString j})
                (concatMap realProducers (edgeInputs (elemAt edges i)));
              ready = filter (i: lib.all (d: done ? ${toString d}) (intDeps i)) remaining;
              batch = if ready == [] then remaining else ready;
              nd = done // listToAttrs (map (i: {name = toString i; value = true;}) batch);
            in go (filter (i: !(lib.elem i batch)) remaining) nd (order ++ batch);
        in go myIds {} [];
        relOf = o: if underAnyRoot o then relUnder o else o;
        # Run one internal edge DIRECTLY (not via ninja): stripRoots gives
        # $out-absolute paths (cd-immune, and $out is the shell env var here --
        # no ninja `$out` variable to collide with). Reuses mkEdge's command
        # construction; internal generated headers are already produced by earlier
        # edges in this topo order, so no generated-header -I bridging is needed.
        runEdge = i: let
          e = elemAt edges i;
          outs = edgeOutputs e;
          rsp = e.rspfile or null;
          cmd = let
            stripped = if rewriteRoots == [] then e.command else stripRoots e.command;
            withSubs = builtins.replaceStrings (map (s: s.from) subs) (map (s: s.to) subs) stripped;
          in builtins.replaceStrings (map (s: s.from) toolPathSubs) (map (s: s.to) toolPathSubs) withSubs;
        in ''
          # Subshell resetting to $out: edges run sequentially in one shell, and a
          # compile command that `cd`s into its WORKING_DIRECTORY (and does not
          # return) would otherwise leave the next edge -- e.g. a link with a
          # relative -o and no cd of its own -- writing to a doubled path.
          ( cd "$out"
          ${lib.concatMapStringsSep "\n" (o: ''
            realize_writable "$(dirname ${esc (relOf o)})"
            if [ -L ${esc (relOf o)} ]; then rm -f ${esc (relOf o)}; fi'') outs}
          ${lib.optionalString (rsp != null && rsp != "") ''
            mkdir -p "$(dirname ${esc rsp})"
            printf '%s' ${esc (e.rspfile_content or "")} > ${esc rsp}''}
          ${cmd}
          ${lib.concatMapStringsSep "\n" (o: shebangSedG ''"$out/${relOf o}"'') outs}
          ${lib.optionalString (rsp != null && rsp != "") "rm -f ${esc rsp}"} )
        '';
      in
        pkgs.runCommand "ninja-group-${lib.strings.sanitizeDerivationName g}" {
          nativeBuildInputs = toolchain ++ extraInputs;
          preferLocalBuild = true;
          passthru = {groupId = g; edgeIndices = myIds;};
        } ''
          mkdir -p $out; cd $out
          realize_writable() {
            local p="$1" cur="" comp tgt oldIFS="$IFS"
            IFS='/'; set -- $p; IFS="$oldIFS"
            for comp in "$@"; do
              [ -z "$comp" ] && continue
              if [ -z "$cur" ]; then cur="$comp"; else cur="$cur/$comp"; fi
              if [ -L "$cur" ]; then
                tgt="$(readlink -f "$cur" 2>/dev/null || true)"; rm -f "$cur"; mkdir -p "$cur"
                if [ -n "$tgt" ] && [ -d "$tgt" ]; then cp -rsf --no-preserve=mode "$tgt"/. "$cur"/ 2>/dev/null || true; fi
              else mkdir -p "$cur"; fi
            done
          }
          ${lib.concatMapStringsSep "\n" (d: "cp -rsf --no-preserve=mode ${d}/. ./ 2>/dev/null || true") extGroupDrvs}
          ${lib.concatMapStringsSep "\n" (s: ''
            if [ ! -e ${esc s} ]; then install -Dm644 ${srcStorePath s} ${esc s}; if [ -x ${srcStorePath s} ]; then chmod +x ${esc s}; ${shebangSedG (esc s)} fi; fi'') relSrcs}
          ${lib.concatMapStringsSep "\n" (p: ''
            if [ ! -e ${esc (relUnder p)} ]; then install -Dm644 ${indivOf p} ${esc (relUnder p)}; if [ -x ${indivOf p} ]; then chmod +x ${esc (relUnder p)}; ${shebangSedG (esc (relUnder p))} fi; fi'') rootSrcs}
          ${stageIncs}
          find . -xtype l -delete 2>/dev/null || true
          ${stageIfaceDeref}
          ${stageSymlinkTargets}
          ${lib.concatMapStringsSep "\n" runEdge topo}
        '';
      groupDrvs = listToAttrs (map (g: {name = g; value = mkGroup g;}) groupIds);
      groupDrvForOutput = p: groupDrvs.${groupOfOutput p};
      # Group-aware realOutputsForTarget: every real output of the edges a (possibly
      # phony) target resolves to, paired with the GROUP derivation that produces it.
      # Lets buildOne materialize a whole-graph build (`all`) from group drvs instead
      # of per-edge drvs -- each final output's group (and its dependency groups) is
      # built transitively, so cp-ing them all yields the full staged tree.
      realOutputsForTargetG = p:
        lib.concatMap
          (i: map (o: {path = o; drv = groupDrvForOutput o;}) (edgeOutputs (elemAt edges i)))
          (realProducers p);
    in {inherit groupDrvs groupDrvForOutput idsInGroup realOutputsForTargetG;};
  in {
    inherit producerOf edgeDrvs drvForOutput edges;
    inherit isPhonyTarget realOutputsForTarget lowerGroupsBy;
    inherit (graph) defaults;
  };
}
