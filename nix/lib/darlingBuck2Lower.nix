# Lower a dumped buck2 action graph to one Nix derivation per TARGET.
#
# The second half of "graph then lower" (plan/buck2-port.md phase 3). The first half
# (nix/lib/darlingBuck2Graph.nix) runs real buck2 in a pure derivation and writes
# graph.json; reading that file HERE is the one opt-in import-from-derivation, the same
# shape overby's nix/lib/cargo uses for crate metadata.
#
# PER TARGET, not per action. One derivation per action is the finer cache and was tried
# first, but the port has on the order of 15,000 actions, and Nix's per-derivation overhead
# -- an instantiation, a sandbox and a store round trip each -- is too much at that count.
# Targets number a couple of hundred, which Nix handles comfortably, and a target is the
# unit a person reasons about anyway. The trade is granularity: touching one source
# rebuilds its whole target rather than a single object file. That trade is cheap here,
# because the great majority of these targets are pinned upstream trees nobody edits.
#
# Every action arrives as the argv buck2 actually ran, so nothing about the port's flags,
# link order or MIG plumbing is re-derived. A target derivation only has to put the inputs
# where the argv expects them -- at their buck-out paths, relative to the working directory
# -- and run that target's actions in the order buck2 ran them.
{
  pkgs,
  graph,
  # The project, for the SOURCE paths an argv names (src/libsimple/src/lock.c and such).
  # FILTERED, the same way the graph derivation filters its own source. Unfiltered, every
  # lowered target took the whole project as an input, so editing a line of plan/ or of the
  # Nix that CONSUMES this graph invalidated all 259 derivations and rebuilt the port. For an
  # endpoint whose entire purpose is that people do not rebuild what they did not touch,
  # that was the most expensive bug in it -- and it cost a full relower after every commit
  # made while working on it.
  #
  # This is the coarse half of the fix. The precise version is to give each target only the
  # sources it reads, and scripts/buck-lower-srcdeps.py computes that set and measures it:
  # 306,019 project files today for EVERY target, against a median of 4,032 per target, or
  # 1.32%. CoreFoundation_obj, one of the two big header cones, comes to 5,317 files of which
  # 5,088 are headers.
  #
  # It does NOT come from staging-action argvs, which is what the task originally recorded.
  # A staging action arrives from aquery as kind `symlinkeddir` carrying four attributes and
  # no cmd at all, so there is no argv for a header to appear in; anything built that way
  # would have staged no headers and failed at compile time. The header cones come from the
  # stagedTrees link MAP below, which the dumper gets from BXL.
  #
  # Naming files is only safe because every include root is a staged tree whose contents that
  # map records exactly: 236,528 staged against 32 pointing into the project, and those 32
  # are two directories holding 26 files between them, which have to be taken wholesale.
  # Opt in to the per-target source union below. OFF because it is not correct yet; the two
  # kinds of input it drops are named where projectSrc is defined.
  narrowSources ? false,
  # Merge each buck-src pin's targets into ONE derivation (#53). OFF so the default path
  # stays byte-comparable against the prefix that is already built and verified; the
  # reasoning and the measurements are at groupOf below.
  coarsePins ? false,
  # Stage each target from the SOURCE GROUPS it reads instead of one shared tree (#54). OFF
  # so the default path stays byte-comparable; the rule is in buck2-graph-sources.py.
  sourceGroups ? false,
  srcRaw ? ../..,
  src ?
    builtins.path {
      name = "darling-buck2-lower-project";
      path = srcRaw;
      filter = path: _type: let
        rel = pkgs.lib.removePrefix (toString srcRaw + "/") (toString path);
        top = pkgs.lib.head (pkgs.lib.splitString "/" rel);
      in
        # tests/ cannot go wholesale -- buck2 has real targets under tests/buck2 -- but the
        # NixOS VM tests in there are Nix that buck2 never reads, and editing one of them
        # was relowering all 259 derivations.
        !(top == "tests" && pkgs.lib.hasSuffix ".nix" rel)
        && !(builtins.elem top [
          "plan"
          "docs"
          "nix"
          # The generators. They run BEFORE buck2 and write the BUCK files; buck2 itself
          # never opens one, and no action's argv names one -- the only mentions across
          # every BUCK and .bzl in the tree are comments saying which generator wrote the
          # block. (The scripts/*.exp symbol lists that DO get read are inside pins, at
          # buck-src/<pin>/scripts/, which arrive through `pins` rather than through here.)
          # Without this, editing any generator relowers all 259 derivations, and this port
          # is largely a matter of editing generators.
          "scripts"
          # Documentation and editor/tool state. PLAN.md is the one that matters: it is
          # 137K, it is edited in essentially every increment of this port, and until now
          # every one of those edits relowered all 259 derivations. Nothing reads any of
          # these -- the only mentions of PLAN.md across every BUCK and .bzl in the tree
          # are comments pointing a reader at it, there is no BUCK package at the repo
          # root, and a buck2 glob cannot escape its own package.
          "PLAN.md"
          "README.md"
          "CONTRIBUTORS.md"
          "LICENSE"
          ".vscode"
          ".claude"
          ".tangled"
          ".gdbinit"
          ".dfx-boot.log"
          ".git"
          ".jj"
          ".direnv"
          "buck-out"
          "result-graph-ref"
          "flake.nix"
          "flake.lock"
        ]);
    },
  # The pins, exactly as the graph derivation staged them: an argv that names
  # buck-src/<pin>/... has to find it here too.
  darlingSrc ? null,
  allPins ? false,
  pins ? [],
  # OPT-IN content addressing, the way nix/lib/cargo treats its one IFD exception: off by
  # default, because it needs `experimental-features = ca-derivations` on every machine that
  # builds OR substitutes these, and a binary cache that serves CA outputs -- and a cache
  # that cannot is fatal to the point of this endpoint, which is other people not rebuilding.
  #
  # What it buys, when it is on: early cutoff BETWEEN targets. A header edit that leaves a
  # target's output bit-identical stops propagating to that target's dependents, instead of
  # relinking the world. That is independent of how the graph itself is consumed.
  #
  # What it does NOT do on its own: make a source edit cheap. That needs the GRAPH
  # derivation to be content-addressed too, which is the CA-plus-IFD pairing of NixOS/nix
  # issue 5805 -- closed, but still tracked under the ca-derivations stabilisation milestone,
  # which sat at 65% in March 2026. `graphContentAddressed` is separate for that reason: take
  # the safe half without the experimental pairing.
  contentAddressed ? false,
  # Tools an argv names by ABSOLUTE store path -- Darling's own ld64, above all. The path
  # travels through graph.json as plain text, so its string context is gone and Nix cannot
  # see the dependency: it has to be declared, or the sandbox will not have it.
  extraTools ? [],
  # Darling's ld64, needed here by PATH as well as by name: the graph records it as a
  # placeholder, and this is what fills it back in.
  ld64 ? null,
}: let
  inherit (pkgs) lib;

  # The graph is portable, so the store paths an argv needs are named rather than baked in
  # (see scripts/buck2-graph-dump.py). Filling them back in is the consumer's job, from
  # ITS own inputs -- which is what lets one graph serve any machine.
  placeholders =
    {
      "@CLANG@" = "${pkgs.llvmPackages.clang-unwrapped}";
      "@RESOURCE_DIR@" = "${pkgs.clang}/resource-root";
    }
    // lib.optionalAttrs (ld64 != null) {"@LD64@" = "${ld64}";};

  fill = str: lib.replaceStrings (lib.attrNames placeholders) (lib.attrValues placeholders) str;

  # The context has to come off before parsing: an argv names its tools by absolute store
  # path, so the file's text refers to store paths, and fromJSON refuses a string that
  # does. Nothing is lost -- the dependency is re-declared as nativeBuildInputs below.
  g = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (builtins.readFile "${graph}/graph.json")
  );

  # A SECOND import-from-derivation, deliberately (#56). Which project files a target reads
  # is the one answer that depends on file CONTENTS rather than on the build definition,
  # because a quoted include is found by parsing #include "..." out of the file. Leaving it
  # in the graph forced the graph derivation to take the whole project, so editing one .c
  # cost a 30 to 47 minute buck2 rerun before any compile could start. It is now its own
  # derivation over the real tree, a 125 second python walk, and it is content addressed: a
  # .c edit changes no file NAME, so this output is byte identical and nothing here moves.
  #
  # Only the UNION is read here. The per-target breakdown is 10.5 million entries and sits
  # in target-sources.json beside it, parsed only when narrowing asks for it.
  srcClosure = builtins.fromJSON (
    builtins.unsafeDiscardStringContext
    (builtins.readFile "${graph.sources}/sources.json")
  );

  # One escape per DISTINCT argument rather than one per occurrence. Measured over a graph
  # dump: 208,515 argv entries across the actions and 5,193 of them distinct, so 97.5
  # percent are repeats -- the same compiler, the same -I flags, the same isysroot, once
  # per compile. Both fill and escapeShellArg are pure functions of the string, so the
  # emitted command line is identical either way; an eval profile put 12 percent of the
  # evaluation on that one map.
  escArgCache = builtins.listToAttrs (map (x: {
    name = x;
    value = lib.escapeShellArg (fill x);
  }) (lib.concatMap (a: a.argv) (g.actions or [])));
  # The fallback is for an argv that never appeared in g.actions, which should not happen
  # and must not become a silent evaluation error if it does.
  escArg = x: escArgCache.${x} or (lib.escapeShellArg (fill x));

  # The same crate sources the graph derivation analysed against, from the same lock files.
  rustVendor = import ./rust-vendor.nix {inherit pkgs;};

  manifest = builtins.fromJSON (builtins.readFile ../submodules.json);
  wantedPins =
    if allPins
    then map (e: e.path) (builtins.filter (e: lib.hasPrefix "src/external/" e.path) manifest)
    else pins;

  # ---- the graph, grouped the way this lowers it -------------------------

  # "root//buck-src:migcom (<unspecified>) (c_compile foo.c)" -> "root//buck-src:migcom"
  targetOf = a: lib.head (lib.splitString " (" a.identity);

  # ---- coarse pins (#53) --------------------------------------------------
  #
  # GRANULARITY SHOULD FOLLOW CHANGE FREQUENCY. buck-src is 16,255 of the 27,591 actions,
  # 58.9 percent, and nobody edits a file in there: it moves when a submodule pin is bumped,
  # as a whole new upstream release, and then it moves entirely. One derivation per target
  # buys nothing for code like that, and costs plenty -- evaluation scales with the action
  # count, the nix-daemon grows 8 to 9 MB per derivation built (#48), and each target
  # derivation pays a STAGING pass before it runs anything, which is what actually limits a
  # full rebuild.
  #
  # WHICH pins may be merged is decided in the DUMP, not here, because CONTRACTING A DAG CAN
  # CREATE CYCLES and this graph has them: 43 of 157 pins fall into one strongly connected
  # component covering the system cone (Libinfo, cctools, commoncrypto, compiler-rt, configd,
  # copyfile, corecrypto, corefoundation), mutually dependent at target level even though the
  # target graph itself is acyclic. Merging those is not suboptimal, it is invalid, and in Nix
  # it surfaces as a bare infinite recursion from the dependency staging line. coarse_pin_map
  # in scripts/buck2-graph-dump.py runs Tarjan over the contracted graph and offers only the
  # 114 pins that are in no cycle, JavaScriptCore among them.
  #
  # Regrouping is SAFE only because g.actions is globally topological, and that is measured
  # rather than assumed: walking the list while accumulating produced outputs finds 0 inputs
  # read before they are written, across all 27,591 actions and 27,619 artifacts, while the
  # same walk over the reversed list finds 112,213. lib.groupBy keeps the order of elements
  # within a group, so every group stays topological and the #52 concurrency stays correct.
  groupOfLabel = label: let
    pin =
      if coarsePins
      then (g.coarsePinOf or {}).${label} or null
      else null;
  in
    if pin == null
    then label
    else "root//buck-src:pin-" + pin;

  groupOf = a: groupOfLabel (targetOf a);

  targets = lib.groupBy groupOf g.actions;

  # Which GROUP writes which artifact, so a consumer resolves to the derivation that
  # actually contains it. This has to use the same key as `targets` above or a coarse
  # build looks up a derivation that no longer exists.
  producerTarget = lib.listToAttrs (lib.concatMap (a:
    map (o: {
      name = o;
      value = groupOf a;
    })
    a.outputs)
  g.actions);

  known = producerTarget // (g.staged or {}) // (g.stagedTrees or {});

  # Recreating a staged farm, from the table the dump wrote beside the graph. The link
  # VALUES are verbatim from buck2, so they resolve here exactly as they did there: the
  # directory sits at the same place in this working tree.
  #
  # NOTHING HERE IS PROPORTIONAL TO THE LINK COUNT, and that is the point. This used to
  # emit two escaped shell lines per link, across 5,282 trees holding 3,581,461 links, and
  # the eval profiler put about 40 percent of a 58 second evaluation on building those
  # strings. The script is now fixed size and reads a tab separated table, so the cost moved
  # to the dump, which writes it once.
  #
  # mapAttrs is lazy per attribute, so a tree nobody consumes is never scripted.
  stagedTreeScripts = lib.mapAttrs stagedTreeScriptFor (g.stagedTrees or {});
  stagedTreeScript = path: meta: stagedTreeScripts.${path} or (stagedTreeScriptFor path meta);

  # CONTENT ADDRESSED, and this is the whole of #55 (#50 finished the producer, not the
  # consumers). These scripts embed ${graph.data}/<table>, which under content addressing is a
  # DEFERRED PLACEHOLDER keyed on the producing DERIVATION rather than on its output. So any
  # edit anywhere moves the graph drv, moves every one of these scripts, and moves everything
  # downstream of them -- measured, a one line edit rebuilt all 6,490 derivations of the
  # minimal endpoint while the graph output was byte identical.
  #
  # Made CA, the resolved script text is the same text (the data path did not change), so it
  # collapses to the SAME output path and the consumers stop moving. The scripts still rerun;
  # what stops is the 1,188 compiles behind them.
  #
  # writeTextFile rather than writeShellScript because only the former takes derivationArgs.
  # The shebang is added by hand, which is all writeShellScript adds over it here.
  caShellScript = name: text:
    pkgs.writeTextFile {
      inherit name;
      executable = true;
      text = "#!" + pkgs.runtimeShell + "\n" + text;
      derivationArgs = {
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
      };
    };

  # `meta` is {n, table, dirs} from the graph, not a link map. A graph dumped before the
  # tables existed carried the links inline, and lowering one of those with this code would
  # silently stage an EMPTY farm, which surfaces an hour later as a header not found. So it
  # is a hard error, named.
  stagedTreeScriptFor = path: meta:
    if !(meta ? n)
    then throw ("buck2 lower: this graph carries staged tree links inline, which this "
      + "lowering no longer reads. Rebuild the graph derivation. Tree: " + path)
    else
      caShellScript "buck2-stage-tree" (''
        tree=${lib.escapeShellArg path}
        mkdir -p "$tree"
      '' + lib.optionalString (meta.n > 0) ''
        # The directories first and only once, so the link loop below runs no subshell at
        # all: a dirname per link is 3.5 million of them across the graph, paid at BUILD
        # time, and the dump already knows the answer.
        while IFS= read -r d; do
          mkdir -p "$tree/$d"
        done < ${graph.data}/${meta.dirs}
      '' + lib.optionalString (meta.n > 0 && meta ? k) ''
        # DERIVED TARGETS. The dump found this farm's targets to be exactly
        # ("../" * (k + the name's own depth)) + prefix + name, for every link, so the table
        # holds NAMES ONLY and the target is rebuilt here. Storing the target as well made
        # treelinks 467 MB when the names in it are 33 percent of that, and every staged
        # tree derivation references the whole thing to read one table out of it.
        #
        # The ../ runs are cached in an array rather than rebuilt per link, so this stays a
        # few parameter expansions per link, with no subshell, exactly as the two column
        # loop below is.
        pre=${lib.escapeShellArg meta.prefix}
        up=("");
        while IFS= read -r rel; do
          slashes=''${rel//[!\/]/}
          n=$(( ${toString meta.k} + ''${#slashes} ))
          while [ ''${#up[@]} -le "$n" ]; do up+=( "''${up[$(( ''${#up[@]} - 1 ))]}../" ); done
          ln -sfn "''${up[$n]}$pre$rel" "$tree/$rel"
        done < ${graph.data}/${meta.table}
      '' + lib.optionalString (meta.n > 0 && !(meta ? k)) ''
        # The fallback form, for a farm whose targets are NOT derivable from their names.
        # IFS= with an explicit split, NOT `IFS=$tab read rel target`: a tab is whitespace
        # to read, so a leading one would be swallowed and an EMPTY link name (which the
        # dump does emit, for a dangling symlink artifact) would take the target as its
        # name and stage the farm wrong.
        tab=$(printf '\t')
        while IFS= read -r line; do
          rel=''${line%%"$tab"*}
          ln -sfn "''${line#*"$tab"}" "$tree/$rel"
        done < ${graph.data}/${meta.table}
      '');

  # By walking the path's own prefixes, NOT by scanning every known artifact: an action's
  # output is often a DIRECTORY (mig writes a whole tree of generated sources) and a
  # consumer names a file inside it, so the owner is the longest known prefix. Scanning
  # every artifact per input is quadratic, which is the class of evaluation cost this
  # whole design exists to get away from.
  ownerOf = path: let
    segs = lib.splitString "/" path;
    prefixes =
      map (n: lib.concatStringsSep "/" (lib.take n segs))
      (lib.reverseList (lib.range 1 (lib.length segs)));
    hits = lib.filter (p: known ? ${p}) prefixes;
  in
    if hits == []
    then null
    else lib.head hits;

  # Every artifact the graph says exists, so a consumer that stops ASKING for one is caught.
  # Moving the staged farms from copies to link maps produced no error and no work: the
  # selector still tested the old field, so nothing was staged and a header simply went
  # missing at compile time. A gap of that shape should fail loudly at evaluation.
  unstageable = lib.filter (o:
    !((g.staged or {}) ? ${o} || (g.stagedTrees or {}) ? ${o} || producerTarget ? ${o}))
  (lib.attrNames (g.staged or {}) ++ lib.attrNames (g.stagedTrees or {}));

  # Where a staged farm's links POINT. Dereferencing used to hide this: a link can aim at
  # another buck2 output (rtsig_header's gen_include holds rtsig.h -> ../rtsig.h, and that
  # file is written by a command in another target), and recreating the link without staging
  # what it aims at leaves it dangling, which surfaces as a header not found.
  # PRECOMPUTED by the dump (stagedTreeDeps), not resolved here.
  #
  # This used to normalise every link value in Nix -- split on "/", fold "..") away with
  # lib.init, join back -- and it was the single most expensive thing in the evaluation:
  # roughly a quarter of it directly, plus most of the 21% that the profiler attributed to
  # primop isString, since lib.splitString is filter isString over builtins.split. The fold
  # was quadratic too, because lib.init copies. In the dumper the same thing is one
  # os.path.normpath per link.
  linkTargets = path: _links: (g.stagedTreeDeps or {}).${path} or [];

  # {producing target: [staged paths it owns]}, built once so needsOf can look up instead
  # of scanning every staged path per target.
  stagedByTarget =
    lib.groupBy (o: producerTarget.${o} or "")
    (lib.attrNames (g.staged or {}) ++ lib.attrNames (g.stagedTrees or {}));

  # What a target consumes from OUTSIDE itself.
  needsOf = label: let
    ins = lib.unique (lib.concatMap (a: a.inputs) targets.${label});
    directOwners = lib.unique (lib.filter (o: o != null) (map ownerOf ins));
    # Anything those farms link to, one level of indirection out.
    viaLinks = lib.unique (lib.concatMap (o: let
      links = (g.stagedTrees or {}).${o} or {};
    in
      map ownerOf (linkTargets o links))
    directOwners);
    owners = lib.unique (directOwners ++ lib.filter (x: x != null) viaLinks);
    # Targets the actions DECLARE as inputs, which the argv-derived owners above cannot
    # always find: an action that reads its inputs from a file names none of them on the
    # command line. The prefix is the case that needs it -- one manifest argument standing
    # for 5,537 inputs -- and aquery is where the declaration comes from.
    # THROUGH THE SAME GROUPING, which is not optional. These arrive from aquery as raw
    # target labels, while `targets` and `stagedByTarget` below are keyed by GROUP, so under
    # coarsePins an unmapped label matches NOTHING and the dependency disappears in silence.
    # That is exactly how the first coarse build died: the prefix declares its 5,537 inputs
    # rather than naming them in argv, so this is the only path that carries them, and it
    # failed with "cp: cannot stat .../python27exe_obj/.../python.c.o" an hour in.
    declared = lib.unique (map groupOfLabel
      (lib.concatMap (a: a.input_targets or []) targets.${label}));
    # Only the ones that RUN something. A declared input can be a target with no actions at
    # all -- a header root, a staged include tree -- and there is no derivation to copy for
    # those; what they own travels as staged data instead, picked up just below.
    declaredWithActions = lib.filter (t: targets ? ${t}) declared;
    # A lookup, not a scan. This used to test every one of the ~1,230 staged paths against
    # the declared list for every target; stagedByTarget inverts it once.
    declaredStaged = lib.concatMap (t: stagedByTarget.${t} or []) declared;
  in {
    fromTargets =
      lib.unique (lib.filter (t: t != null && t != label)
        (map (o: producerTarget.${o} or null) owners ++ declaredWithActions));
    # Either kind: a farm recorded as a link MAP, or content buck2 generated and the dump
    # copied out. Filtering on `staged` alone silently produced no farms at all once the
    # maps replaced the copies.
    fromStaged =
      lib.unique (
        lib.filter (o: (g.staged or {}) ? ${o} || (g.stagedTrees or {}) ? ${o}) owners
        ++ declaredStaged
      );
  };

  # ---- the working tree an action runs in --------------------------------

  # As SYMLINKS, and as a SHARED script: an action only reads project files, and copying
  # the repo (let alone 4 GB of pins) into every derivation would cost more than the build
  # being replaced. The script assumes the builder has already entered the working tree.
  # NARROWED to what the port actually reads, when the graph carries the per-target lists
  # scripts/buck2-graph-dump.py precomputes. The filtered project is 306,019 files; the union
  # of every target's sources is 16,106, so nineteen twentieths of what every lowered
  # derivation depended on was never opened by any action. Pin contents dominate the rest.
  #
  # A UNION rather than one source per target, and that is measured, not a shortcut. The 671
  # targets name 1,754,387 files between them, so each of those 16,106 appears in about 109
  # of them; a per-target lib.fileset.toSource, which is what task #11 originally proposed,
  # would copy the same small set into the store a hundred times over. Getting per-target
  # invalidation without that duplication needs one store path per distinct FILE, shared, with
  # a per-target manifest the builder reads -- a different design, still open.
  #
  # Falls back to the whole filtered source when targetSources is absent, so a graph dumped
  # before this field existed still lowers.
  srcUnion = let
    # NOT lib.unique, which is `foldl' (acc: e: if elem e acc then acc else acc ++ [e]) []`
    # and therefore quadratic twice over, once in the elem scan and once because `acc ++ [e]`
    # copies the accumulator every step. Measured: 292ms at 5k elements, 1125ms at 10k,
    # 4197ms at 20k, four times the work per doubling, and an eval profile of this very
    # expression puts 83 percent of its samples on that one line of lib/lists.nix. At the
    # 123,343 declared files here it ran for over 25 minutes without finishing.
    #
    # Nothing needs the list deduplicated: all three consumers below build an attrset out of
    # it with listToAttrs, and attribute names are unique by construction. (lib.uniqueStrings
    # is the O(n log n) one if a deduplicated LIST is ever actually needed.)
    # The UNION, which the dump now writes directly. It used to be flattened out of the
    # per-target map, and that map held the same paths 85 times over -- 10,512,996 entries
    # for 123,343 distinct files -- because it expanded each shared header farm once per
    # consumer. Since this was the only thing that ever read it, the per-target breakdown
    # moved to target-sources.json beside the graph, where narrowing can pick it up without
    # every evaluation parsing 651 MB it never looks at.
    files = srcClosure.projectSources;
    wanted = builtins.listToAttrs (map (p: {
      name = p;
      value = true;
    })
    files);
    # Every ancestor directory of a wanted file, as a SET. builtins.path filters top down and
    # never descends into what it rejected, so a directory has to be kept when anything under
    # it is wanted -- and answering that by scanning the file set per directory is 16,106
    # comparisons for each of 306,019 paths. Precomputing the ancestors makes it a lookup:
    # about 80,000 entries, built once.
    ancestors = builtins.listToAttrs (map (d: {
      name = d;
      value = true;
    })
    (lib.concatMap (p: let
        segs = lib.splitString "/" p;
      in
        map (n: lib.concatStringsSep "/" (lib.take n segs))
        (lib.range 1 (lib.length segs - 1)))
      files));
    # The DIRECTORY of every wanted file, as a set. A quoted include resolves against the
    # including file's own directory and buck2 never declares it, so keeping the file without
    # its neighbours is what stopped CarbonCore at "UserBreak.h file not found". Measured over
    # the all graph: 123,343 declared files live in 8,596 directories holding 131,048 files
    # between them, so this widens the union by six percent and still leaves 306,019 far
    # behind. It also picks up 383 headers named exactly like the source beside them, which is
    # a lower bound on how often the declared set was short.
    wantedDirs = builtins.listToAttrs (map (d: {
      name = d;
      value = true;
    })
    (map (p: builtins.dirOf p) files));
  in
    builtins.path {
      name = "darling-buck2-lower-sources";
      path = srcRaw;
      filter = path: type: let
        rel = lib.removePrefix (toString srcRaw + "/") (toString path);
      in
        if type == "directory"
        then ancestors ? ${rel}
        # A SYMLINK is neither, and asking only the two questions above dropped it: the filter
        # took the else branch, the symlink is not itself a declared file, and every path
        # THROUGH it vanished. Eight of them are ancestors of declared paths here, including
        # src/CoreAudio/AFAVFormatComponent/PublicUtility, whose whole tree the CoreAudio
        # targets compile.
        else if type == "symlink"
        then (ancestors ? ${rel}) || (wanted ? ${rel})
        else (wanted ? ${rel}) || (wantedDirs ? ${builtins.dirOf rel});
    };

  # OFF by default, because the narrowing is not correct yet and a wrong one fails the build
  # 90 minutes in. targetSources records what buck2 DECLARES, and that is not what a compile
  # READS. Two kinds of input are missing from it, both found by building the whole endpoint:
  #
  #   a quoted include next to its source. darwin/frameworks/CoreServices/src/CarbonCore/
  #   UserBreak.cpp does #include "UserBreak.h", which resolves against the including file's
  #   own directory; the .cpp is declared and the .h is not, so the union had one and not the
  #   other and clang stopped at "UserBreak.h file not found".
  #
  #   a symlinked ancestor. src/CoreAudio/AFAVFormatComponent/PublicUtility is a symlink to
  #   ../CoreAudioUtilityClasses/CoreAudio/PublicUtility, and the filter classified it as
  #   neither a wanted file nor a directory, so it was dropped and every path THROUGH it
  #   vanished, while the resolved tree sat in the union all along.
  #
  # BOTH of those are addressed by the filter above now, and the fix was measured offline
  # against the real tree before being written: the candidate keeps UserBreak.h, keeps all
  # eight symlinked ancestors, and costs six percent more files. What is still NOT covered is
  # an include that reaches OUT of its directory with ../, which only depfiles can answer.
  # So this stays OFF by default until a full endpoint build has run green with it, which
  # costs 90 minutes and has not been spent yet. Pass narrowSources = true to opt in.
  projectSrc =
    if narrowSources && srcClosure.projectSources != []
    then srcUnion
    else src;

  # ---- per-component source groups (#54) ----------------------------------
  #
  # projectSrc is ONE store path that every target stages, so a byte changing anywhere in it
  # moves the path and all 3,225 targets rebuild. narrowSources does not fix that; it shrinks
  # the path from 306,019 files to about 131,048 and it is STILL shared. This splits the part
  # that people actually edit so a target only depends on the groups it reads.
  #
  # MEASURED, which is what makes the split worth it: of 27,591 actions, 16,255 are pinned
  # upstream code, and NOT ONE of them reads darwin/frameworks. The 1,326 pin targets that
  # touch first-party files at all read only the SDK headers under darwin/Developer plus
  # about ten stable compatibility headers -- darwin/basic-headers, src/sandbox,
  # src/libsysmon. So editing a framework should leave every pin target cached, and today it
  # rebuilds all of them.
  #
  # buck-src/ and src/external/ are deliberately NOT grouped. 98,933 of the 123,343 declared
  # files are pins, already staged wholesale from darlingSrc by the pins section below and
  # keyed by pin revision; grouping them would collide with those symlinks. src/external is
  # where the pins are PLANTED, so a group there (src/external/darlingserver is 1,720 files)
  # would fight the same symlink.
  #
  # Three components, not two: darwin/frameworks alone is 17,223 files, so two would leave
  # every framework in one blob. Three gives 208 groups with none nested inside another,
  # plus 68 shallow files that belong to no group and travel individually.
  # WHICH GROUPS a target reads, precomputed. This used to read target-sources.json and work
  # the groups out here, and that file is 588 MB of 10.5 million entries for 124,055 distinct
  # files: it cost eval 21.4s to 75.6s and heap 1.76 to 3.40 GB, which is what kept source
  # groups switched off. The lowering never wanted the files, only the groups, so the closure
  # pass emits them directly. Measured: 2.06 MB against 588 MB, 285 times smaller, holding
  # 41,896 target-to-group edges over 195 groups plus 69 files that belong to none.
  targetGroups =
    if sourceGroups
    then
      builtins.fromJSON (builtins.unsafeDiscardStringContext
        (builtins.readFile "${graph.sources}/target-groups.json"))
    else {};

  # The grouping RULE itself lives in scripts/buck2-graph-sources.py now, beside the map it
  # is applied to, rather than being reimplemented here over a 588 MB file. That is also
  # where the three ungrouped prefixes are justified: buck-src and src/external are pins
  # staged wholesale by revision, and buck-rust is gitignored and comes from the vendor
  # derivation, so a builtins.path at one would fail with "not tracked by Git".

  # One store path per group, so the group is what moves when a file in it changes.
  groupStore = g:
    builtins.path {
      name = "darling-src-" + lib.strings.sanitizeDerivationName g;
      path = srcRaw + ("/" + g);
    };

  # And per FILE for the 68 that sit in no group; a whole-directory path would drag in
  # siblings the target does not read, which is the coupling this exists to remove.
  fileStore = p:
    builtins.path {
      name = "darling-srcfile-" + lib.strings.sanitizeDerivationName p;
      path = srcRaw + ("/" + p);
    };

  stageGroupsFor = label: let
    entry = targetGroups.${label} or {};
    groups = entry.groups or [];
    shallow = entry.shallow or [];
  in ''
    ${lib.concatMapStrings (g: ''
      mkdir -p ${lib.escapeShellArg (builtins.dirOf g)}
      ln -sfn ${groupStore g} ${lib.escapeShellArg g}
    '')
    groups}
    ${lib.concatMapStrings (p: ''
      mkdir -p ${lib.escapeShellArg (builtins.dirOf p)}
      ln -sfn ${fileStore p} ${lib.escapeShellArg p}
    '')
    shallow}
  '';

  # Under #54 a target stages ONLY its groups plus the pins. It deliberately references no
  # shared project path at all -- that is the whole point, since one shared input is what
  # makes every edit rebuild everything. The pins still come from darlingSrc, keyed by pin
  # revision, and src/external and buck-rust stay REAL directories because the pins are
  # planted inside them; the comment on stageProject records that losing that cost a whole
  # endpoint build.
  stageProjectFor = label:
    pkgs.writeShellScript "buck2-stage-project-grouped" ''
      ${stageGroupsFor label}
      mkdir -p buck-rust src/external buck-src
      for _c in ${rustVendor}/*/; do
        ln -sfn "$_c" "buck-rust/$(basename "$_c")"
      done
      ${lib.concatMapStrings (p: ''
        ln -sfn ${lib.escapeShellArg "${darlingSrc}/${p}"} ${lib.escapeShellArg "buck-src/${builtins.baseNameOf p}"}
        mkdir -p ${builtins.dirOf p}
        rm -f ${p}
        ln -sfn ${lib.escapeShellArg "${darlingSrc}/${p}"} ${lib.escapeShellArg p}
      '')
      wantedPins}
    '';

  stageProject = pkgs.writeShellScript "buck2-stage-project" ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
        ln -s ${lib.escapeShellArg "${projectSrc}/${name}"} ${lib.escapeShellArg name}
      # "src" belongs in this list and cost a whole endpoint build when it fell out of it:
      # the section below plants the pins at src/external/<pin>, which is only possible if
      # src/ is a real directory here rather than a symlink into the store. There is no
      # entry called "projectSrc" -- that was a rename of the "src" exclusion into a Nix
      # BINDING name, and it silently turned every lowered target into a permission error.
      '') (lib.filterAttrs (name: _:
        name != "buck-src" && name != "buck-out" && name != "src" && name != "buck-rust")
        (builtins.readDir projectSrc)))}

    # buck-rust/ is a REAL directory for the same reason src/ is: its BUCK file is
    # committed and travels in `projectSrc`, while the crate sources are gitignored and come from
    # the vendor derivation, so the two have to be planted side by side. Without it rustc
    # opens buck-rust/libc-0.2.189/src/lib.rs and finds nothing there.
    mkdir -p buck-rust
    ${lib.optionalString (builtins.pathExists (projectSrc + "/buck-rust")) (
      lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
          ln -s ${lib.escapeShellArg "${projectSrc}/buck-rust/${name}"} ${lib.escapeShellArg "buck-rust/${name}"}
        '') (builtins.readDir (projectSrc + "/buck-rust")))
    )}
    for _c in ${rustVendor}/*/; do
      ln -sfn "$_c" "buck-rust/$(basename "$_c")"
    done

    # src/ and src/external/ are REAL directories here, not symlinks into the store: the
    # pins get planted at src/external/<pin> so the SDK's symlink farm resolves, and
    # planting anything inside a store path is a permission error.
    mkdir -p src/external
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
        ln -s ${lib.escapeShellArg "${projectSrc}/src/${name}"} ${lib.escapeShellArg "src/${name}"}
      '') (lib.filterAttrs (name: _: name != "external") (builtins.readDir (projectSrc + "/src"))))}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
        ln -s ${lib.escapeShellArg "${projectSrc}/src/external/${name}"} ${lib.escapeShellArg "src/external/${name}"}
      '') (builtins.readDir (projectSrc + "/src/external")))}
    ${lib.optionalString (builtins.pathExists (projectSrc + "/buck-src")) ''
      mkdir -p buck-src
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
          ln -s ${lib.escapeShellArg "${projectSrc}/buck-src/${name}"} ${lib.escapeShellArg "buck-src/${name}"}
        '') (builtins.readDir (projectSrc + "/buck-src")))}
    ''}
    ${lib.concatMapStrings (p: ''
      ln -sfn ${lib.escapeShellArg "${darlingSrc}/${p}"} ${lib.escapeShellArg "buck-src/${builtins.baseNameOf p}"}
      mkdir -p ${builtins.dirOf p}
      rm -f ${p}
      ln -sfn ${lib.escapeShellArg "${darlingSrc}/${p}"} ${lib.escapeShellArg p}
    '') wantedPins}
  '';

  # ---- one derivation per target -----------------------------------------

  drvName = label:
    "buck2-" + lib.strings.sanitizeDerivationName (lib.last (lib.splitString ":" label));

  drvs = lib.mapAttrs (label: actions: let
    needs = needsOf label;
    outs = lib.unique (lib.concatMap (a: a.outputs) actions);
    # Which of this target's actions may run CONCURRENTLY. JavaScriptCore_obj is 1,088
    # cxx_compile actions in one derivation and ran them one at a time, 54 minutes with 21
    # cores idle, which was a quarter of the whole endpoint build for one target.
    #
    # The test is a set membership and needs no ordering pass: the actions are in buck2's
    # topological order, so an input produced by THIS target necessarily comes from an
    # earlier action. An action that reads none of its siblings' outputs therefore depends
    # on nothing already launched and is safe to run in the background; one that does reads
    # something a sibling wrote, so everything outstanding has to land first.
    #
    # Conservative in the safe direction: such an action waits for ALL outstanding work, not
    # just for the sibling it actually needs. For the shape this targets, many compiles and
    # then one archive or link, that costs nothing.
    ownOutputs = builtins.listToAttrs (lib.concatMap (a:
      map (o: {
        name = o;
        value = true;
      })
      a.outputs)
    actions);
    readsSibling = a: lib.any (i: ownOutputs ? ${i}) a.inputs;
  in
    pkgs.runCommand (drvName label) {
      nativeBuildInputs =
        [
          pkgs.clang
          # The guest compiler the graph derivation selected, named by absolute path in the
          # argv: its store path has no string context by the time it arrives here, so the
          # dependency has to be declared or the sandbox will not have it.
          pkgs.llvmPackages.clang-unwrapped
          pkgs.llvmPackages.bintools
          pkgs.python3
          pkgs.bison
          pkgs.flex
          pkgs.coreutils
          pkgs.bash
          # The Rust side: rustc compiles the daemon, launcher and loader, and bindgen
          # generates the daemon's dtape vtable. Both appear in the recorded argv as bare
          # command names, exactly as on the daemon path, so they have to be on PATH here.
          pkgs.rustc
          pkgs.rust-bindgen
        ]
        ++ extraTools
        ++ lib.optional (ld64 != null) ld64;
      # Same reason as the graph derivation: the argv is buck2's, and the wrapper's
      # hardening flags are not in it. -D_FORTIFY_SOURCE alone turns libc's own sprintf
      # into a macro over its own definition.
      hardeningDisable = ["all"];
      # Content addressing is per derivation, so it is one attribute here rather than a
      # different lowering.
      __contentAddressed = contentAddressed;
      outputHashMode =
        if contentAddressed
        then "recursive"
        else null;
      outputHashAlgo =
        if contentAddressed
        then "sha256"
        else null;
      passthru = {
        inherit label outs;
        deps = needs.fromTargets;
        actionCount = lib.length actions;
      };
    } ''
      mkdir -p work && cd work
      ${if sourceGroups then stageProjectFor label else stageProject}

      # What other targets built, at the paths this target's argv expects. Modes are
      # PRESERVED: a dependency can be a TOOL -- migcom is, and the port's every codegen
      # edge runs it -- and dropping the executable bit turns into "Permission denied"
      # inside mig.sh, a long way from here. Writability is restored afterwards instead,
      # because the store copy is read-only and later actions write next to it.
      ${lib.concatMapStrings (dep: ''
        cp -a ${drvs.${dep}}/. .
        # After EACH one, not at the end: the copy reproduces the store's read-only
        # directories, and two dependencies share parent directories under buck-out, so
        # the second copy cannot write into what the first one just created.
        find . -type d ! -perm -u+w -exec chmod u+w {} +
      '')
      needs.fromTargets}

      # And the artifacts buck2 made in-process rather than by running a command. A staged
      # include root is rebuilt from its link map; anything buck2 GENERATED rather than
      # linked was copied out and is restored from there.
      ${lib.concatMapStrings (o: let
        links = (g.stagedTrees or {}).${o} or null;
        # An entry with no links at all used to be spelled {} and is now {n = 0;}. Both
        # mean the same thing: there is no farm to rebuild, so only the copied data below
        # applies.
        hasLinks = links != null && (links.n or 0) > 0;
        data = (g.staged or {}).${o} or null;
      in
        lib.optionalString hasLinks ''
          ${stagedTreeScript o links}
        ''
        + lib.optionalString (data != null) (
          if hasLinks
          then ''
            # MERGED, not replaced: a tree can hold both links into the project and files
            # buck2 generated (rtsig.h is one), and copying over the farm with -T destroys
            # the links that were just made.
            cp -a ${graph.data}/${data}/. ${lib.escapeShellArg o}/
            chmod -R u+w ${lib.escapeShellArg o}
          ''
          else ''
            mkdir -p "$(dirname ${lib.escapeShellArg o})"
            cp -aT ${graph.data}/${data} ${lib.escapeShellArg o}
            chmod -R u+w ${lib.escapeShellArg o}
          ''
        ))
      needs.fromStaged}

      for _v in $(env | sed -n 's/^\(NIX_\(CFLAGS\|LDFLAGS\)[A-Za-z0-9_]*\)=.*/\1/p'); do
        unset "$_v"
      done
      export TMPDIR="$NIX_BUILD_TOP/tmp" BUCK_SCRATCH_PATH="$NIX_BUILD_TOP/scratch"
      mkdir -p "$TMPDIR" "$BUCK_SCRATCH_PATH"

      # This target's own actions, in the order buck2 ran them, which is a topological one:
      # buck2 only runs an action once its inputs exist. Independent ones run CONCURRENTLY,
      # bounded by NIX_BUILD_CORES the way any other builder is -- so balance this with
      # `--cores` alongside `--max-jobs`, since 6 jobs each allowed 22 cores is 132 compiles.
      _max=''${NIX_BUILD_CORES:-1}
      if [ "$_max" -lt 1 ]; then _max=1; fi
      _running=0
      # Checked EXPLICITLY, not left to set -e: a background job's failure does not abort the
      # shell, and an unnoticed one here means a target quietly missing an object and a link
      # error somewhere else entirely.
      _reap() {
        if ! wait -n; then
          echo "buck2 lower: an action of ${label} failed" >&2
          exit 1
        fi
        _running=$((_running - 1))
      }
      _spawn() {
        "$@" &
        _running=$((_running + 1))
        while [ "$_running" -ge "$_max" ]; do _reap; done
      }
      _drain() { while [ "$_running" -gt 0 ]; do _reap; done; }

      ${lib.concatMapStrings (a: ''
        ${lib.concatMapStrings (o: ''
          mkdir -p "$(dirname ${lib.escapeShellArg o})"
        '')
        a.outputs}
        echo "  ${a.identity}"
        ${
          if readsSibling a
          then ''
            _drain
            ${lib.concatStringsSep " " (map escArg a.argv)}
          ''
          else ''
            _spawn ${lib.concatStringsSep " " (map escArg a.argv)}
          ''
        }
      '')
      actions}
      _drain

      # Everything this target produced, at the SAME relative paths, so a consumer can
      # stage it exactly where its own argv expects it.
      ${lib.concatMapStrings (o: ''
        mkdir -p "$out/$(dirname ${lib.escapeShellArg o})"
        cp -aT ${lib.escapeShellArg o} "$out/${o}"
      '')
      outs}
    '')
  targets;

  # A target's DEFAULT outputs under their own names, which is what a person wants: the
  # derivations above keep everything at buck-out paths, which is what a consumer needs.
  named = lib.mapAttrs (label: outs:
    pkgs.runCommand "${drvName label}-out" {passthru = {inherit label outs;};} (''
        mkdir -p "$out"
      ''
      + lib.concatMapStrings (o: let
        # The same resolution the rest of the lowering uses. A target's DEFAULT output is
        # not always written by a command: some are produced in-process by buck2 (a staged
        # lib directory, say), and some are a file inside a directory another action wrote.
        owner = ownerOf o;
        prod =
          if owner == null
          then null
          else producerTarget.${owner} or null;
        st =
          if owner == null
          then null
          else (g.staged or {}).${owner} or null;
      in
        if prod != null
        then ''
          cp -a ${drvs.${prod}}/${o} "$out/${builtins.baseNameOf o}"
        ''
        else if st != null
        then ''
          cp -aT ${graph.data}/${st} "$out/${builtins.baseNameOf o}"
        ''
        else if owner != null && (g.stagedTrees or {}) ? ${owner}
        then ''
          ${stagedTreeScript (builtins.baseNameOf o) (g.stagedTrees.${owner})}
        ''
        else throw "buck2 lower: nothing produces ${label}'s output ${o}")
      outs))
  (g.targetOutputs or {});
in
  assert unstageable == [] || throw "buck2 lower: unstageable artifacts: ${toString unstageable}"; {
  inherit drvs named g;

  # The staging script on its own, so it can be checked without building anything that uses
  # it. scripts/buck-lowering-stage-check.nu reads it: a one-word regression here (src falling
  # out of the top-level exclusion list) failed all 1798 lowered targets and was only visible
  # 90 minutes into a build.
  inherit stageProject;

  # The single target's output, for the common case of asking for one thing.
  final = let
    all = lib.attrValues named;
  in
    if all != []
    then lib.head all
    else throw "buck2 lower: the graph names no target outputs";
}
