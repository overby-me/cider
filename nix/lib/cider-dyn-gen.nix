# THE ADAPTER, END TO END: build a real cider group from the specs the GENERATOR wrote, with
# nothing serialised in the evaluator, and diff the result against the lowered derivation.
#
#   nix build .#cider-buck2-dyn-gen --no-link -L
#
# WHAT IS NEW HERE, against nix/lib/cider-dyn-cone.nix which this replaces the tail of. That
# fixture proved a cone builds through specDir mode, but its spec dir came from mkSpecDir, which
# serialises every spec in the EVALUATOR. That is the exact cost #66 exists to remove, so it was
# a proof about the SHAPE and never about the arrangement. This one reads
# ${graph.specs}/dyn, written by scripts/buck-graph-to-specs.py inside the graph derivation.
#
# THE SPECS CONTAIN NO PATH THIS CONSUMER OWNS, which is what lets a generator write them at
# all. Everything consumer-side arrives through the bridge's extraEnv, per action:
#
#   CIDER_PATH        what stdenv would have put on PATH, since an emitted action has none
#   CIDER_STAGE       this group's staging script
#   CIDER_DATA        the tree of artifacts buck2 produced in-process
#   CIDER_TREE_<i>    the staged tree scripts, positionally
#   CIDER_PH_*        the placeholder values, straight into the env rather than as exports
#
# and the dependency edges arrive as DYN_DEP_<name>, from the generator's own deps.json, which
# is the bridge's mechanism rather than anything cider-specific.
{
  pkgs,
  lowered,
  # A small cone by default. The point is the arrangement, not the size.
  label ? "root//buck-src:unwind_static",
}: let
  inherit (pkgs) lib;

  # THE LOWERING'S OWN, not a sixth copy. This file had its own transcription of safe_name,
  # which is the mapping the spec files are named by, and a transcription that drifted would
  # not error: the name would simply not be found, or worse would find another group's spec.
  inherit (lowered) specName;

  # MEMOISED, through genericClosure, which dedups as it goes. The obvious recursion,
  # `unique (concatMap (d: coneOf d ++ [d]) direct)`, revisits every shared dependency once per
  # path that reaches it, so it is fine on a cone of four and is not something to discover on a
  # cone of several hundred. ORDER IS NOT PRESERVED and nothing here wants it: dyn-actions takes
  # a SET and wires the edges by name.
  coneOf = l:
    map (x: x.key) (lib.genericClosure {
      startSet = map (d: {key = d;}) lowered.drvs.${l}.passthru.deps;
      operator = x: map (d: {key = d;}) lowered.drvs.${x.key}.passthru.deps;
    });
  members = coneOf label ++ [label];

  # WHAT stdenv WOULD HAVE PUT ON PATH. tools is only what the lowering ADDS to stdenv, and an
  # emitted action has no stdenv: no setup hooks, no propagation. llvm-ar is the case that
  # proved it, reachable only through the bintools wrapper's setup hook, so the unwrapped
  # package is named here explicitly.
  # WHAT stdenv WOULD HAVE PUT ON PATH, taken from stdenv.initialPath rather than hand-picked.
  # An emitted action has no stdenv: no setup hooks, no propagation, no initialPath. The list
  # here used to be written out by hand and was missing xz, which surfaced 900 builders into a
  # full-graph build as "exec: xz: not found" in an icu action. Hand-picking asks someone to
  # know the whole of what stdenv supplies; naming initialPath asks nixpkgs.
  #
  # bintools.bintools IS STILL EXPLICIT, and separately. llvm-ar lives in the UNWRAPPED package
  # and reaches PATH only through the wrapper's setup hook, which an emitted action never runs;
  # lib.makeBinPath follows neither hooks nor propagation. Checked: closePropagation over the
  # 33 tools gives 53 packages and still no llvm.
  stdenvBasics = pkgs.stdenv.initialPath ++ [pkgs.llvmPackages.bintools.bintools];

  # THE SPEC DIR THE GENERATOR WROTE. No mkSpecDir, no toJSON in the evaluator, no per-group
  # anything: one store path holding all 1,474 specs, and the bridge reads the ones asked for.
  specDir = "${lowered.graphSpecs}/dyn";

  # Per action, keyed by the SPEC NAME because that is what the bridge asks about.
  byName = lib.listToAttrs (map (l: lib.nameValuePair (specName l) l) members);

  envFor = l: let
    d = lowered.drvs.${l};
  in
    {
      CIDER_PATH = lib.makeBinPath (d.passthru.tools ++ stdenvBasics);

      # WHAT stdenv SETS IN ITS SETUP SCRIPT RATHER THAN AS AN ATTRIBUTE, which is why it is
      # invisible in the lowered derivation env and was missed. nixpkgs setup line 593 reads
      # : "${SOURCE_DATE_EPOCH:=315532800}", and 315532800 is 1980-01-01 UTC.
      #
      # FOUND BY THE FULL-GRAPH DIFF and by nothing smaller: three binaries out of the whole
      # prefix embed __DATE__, and the emitted ones said Aug against the lowered Jan. An
      # emitted action has no setup script, so the compiler saw the real date. Everything else
      # in the prefix was already identical.
      SOURCE_DATE_EPOCH = "315532800";
      CIDER_STAGE = "${d.passthru.stageScript}";
      CIDER_DATA = "${lowered.graphData}";
    }
    // lib.listToAttrs (lib.imap0 (i: s:
      lib.nameValuePair ("CIDER_TREE_" + toString i) "${s}")
    d.passthru.treeScripts)
    # THE PLACEHOLDERS AS ENV RATHER THAN EXPORTS. The lowering exports them because a
    # runCommand had no other way to receive them; an emitted action takes them directly, so
    # the generator leaves that slot empty.
    // lowered.placeholderEnv;

  extraEnv = name: let
    l = byName.${name} or null;
  in
    if l == null
    then {}
    else envFor l;

  bridge = import ./dyn-actions.nix {
    inherit pkgs specDir extraEnv;
    # The scripts name their inputs inside the command rather than in a list, which is the case
    # inferSrcs exists for.
    inferSrcs = true;
  };
  # EVERY GROUP, for the scale question, and it BUILDS NOTHING. Forcing a producer's drvPath
  # instantiates that derivation in the evaluator, which is the cost that decides whether this
  # arrangement can carry 1,474 groups at all. Building them is a separate and much larger
  # question; this answers the cheap half first.
  #
  # extraEnv is asked per action here as everywhere, so this also forces the per-group staging
  # script, tree scripts and tool paths, which is most of what the lowering pays for too.
  allNames = lib.attrNames lowered.drvs;
  everything = import ./dyn-actions.nix {
    inherit pkgs specDir;
    inferSrcs = true;
    extraEnv = name: let
      l = allByName.${name} or null;
    in
      if l == null
      then {}
      else envFor l;
  };
  allByName = lib.listToAttrs (map (l: lib.nameValuePair (specName l) l) allNames);
  # EVERY GROUP, PAIRED WITH ITS LOWERED COUNTERPART, in a file rather than in the script.
  #
  # THE FILE IS NOT TIDINESS. 1,474 pairs of store paths is about 200 KB, and a runCommand
  # puts its script in the ENVIRONMENT, where Linux caps a single string at MAX_ARG_STRLEN,
  # 131,072 bytes. Writing the pairs into the script would fail to exec with "Argument list too
  # long", which is exactly the limit the bridge itself hit at 89 of these same groups.
  pairsFile = pkgs.writeText "cider-dyn-gen-pairs" (lib.concatMapStrings (l:
    specName l + "\t" + everything.outputs.${specName l} + "\t" + "${lowered.drvs.${l}}" + "\n")
  allNames);

in {
  inherit bridge members specDir pairsFile;

  # THE PAIRS DATA, counted at EVALUATION so the file can be checked without building anything
  # that reads it. A malformed pairs file would make checkAll compare fewer groups than it
  # claims, and it reports its own count, so this is what makes that count trustworthy.
  pairsShape = let
    text = lib.concatMapStrings (l:
      specName l + "\t" + everything.outputs.${specName l} + "\t" + "${lowered.drvs.${l}}" + "\n")
    allNames;
    lines = lib.filter (x: x != "") (lib.splitString "\n" text);
    fields = map (l: lib.length (lib.splitString "\t" l)) lines;
  in
    "lines=" + toString (lib.length lines)
    + " expected=" + toString (lib.length allNames)
    + " minfields=" + toString (lib.foldl' lib.min 99 fields)
    + " maxfields=" + toString (lib.foldl' lib.max 0 fields);

  # nix eval .#cider-buck2-prefix-min --apply ... is awkward for this, so it is an attribute:
  #   nix eval --raw -f ... scaleProbe
  # It returns the number of producers whose derivation was instantiated.
  scaleProbe = let
    forced = map (l: builtins.seq everything.producers.${specName l}.drvPath 1) allNames;
  in
    toString (lib.foldl' (a: b: a + b) 0 forced);

  # THE SAME COUNT ON THE OTHER ROUTE, so the two can be compared at all. Forcing producer
  # drvPaths against forcing lowered outPaths is not the same traversal, and quoting the two
  # timings side by side without this would be comparing a measurement to a different one.
  #
  # BOTH SIDES NOW FORCE the derivation AND the consumer-supplied inputs: outPath on a lowered
  # derivation pulls in its staging script and staged tree scripts, and the producer side pulls
  # the same values through extraEnv.
  loweredProbe = let
    forced = map (l: builtins.seq lowered.drvs.${l}.outPath 1) allNames;
  in
    toString (lib.foldl' (a: b: a + b) 0 forced);

  # THE WHOLE GRAPH THROUGH THE EMITTED ROUTE, which is the scale question the cones cannot
  # answer. It uses `everything` rather than coneOf: that walk is not memoised, which is fine
  # for four groups and is not something to find out about at 1,474.
  #
  # THE COMPARISON IS THE POINT. Building 1,474 emitted groups only shows they build; diffing
  # the top target against the lowered one is what says the two routes agree, and that is the
  # question the endpoint decision turns on.

  checkAll = pkgs.runCommand "cider-dyn-gen-all" {} ''
    echo "--- ${toString (lib.length allNames)} groups, specs from ${specDir}"

    # DIFFED PER GROUP, not only at the top target. A single diff of the prefix says the two
    # routes disagree and nothing about WHERE, and it can only see a difference that propagates
    # that far: a group whose output differs in something the prefix does not install would
    # pass. Both outputs are realised either way, so this costs IO and no build.
    same=0
    differ=0
    while IFS="$(printf '\t')" read -r name emitted lowered; do
      if diff -r --no-dereference "$emitted" "$lowered" > one.txt 2>&1; then
        same=$((same + 1))
      else
        differ=$((differ + 1))
        if [ "$differ" -le 5 ]; then
          echo "DIFFERS: $name" >&2
          head -20 one.txt >&2
        fi
      fi
    done < ${pairsFile}

    echo "--- identical $same, differ $differ"
    if [ "$differ" != 0 ]; then
      echo "FAIL: $differ group(s) built differently through the emitted route" >&2
      exit 1
    fi
    if [ "$same" != ${toString (lib.length allNames)} ]; then
      echo "FAIL: compared $same groups, expected ${toString (lib.length allNames)}" >&2
      exit 1
    fi
    echo "OK the whole graph emitted, all $same group(s) match the lowered route" > $out
  '';


  check = pkgs.runCommand "cider-dyn-gen-check" {} ''
    echo "--- cone of ${toString (lib.length members)}: ${lib.concatStringsSep " " members}"
    echo "--- specs came from ${specDir}"
    if [ ${toString (lib.length members)} -lt 2 ]; then
      echo "FAIL: a cone of one is cider-dyn-one under another name" >&2
      exit 1
    fi

    emitted=${bridge.outputs.${specName label}}
    echo "--- emitted $emitted"
    lowered=${lowered.drvs.${label}}

    # DIFFED, not merely built. A group that builds and produces the wrong bytes is the failure
    # this whole exercise is trying to rule out.
    if ! diff -r --no-dereference "$emitted" "$lowered" > diff.txt 2>&1; then
      echo "FAIL: the emitted output differs from the lowered one" >&2
      head -40 diff.txt >&2
      exit 1
    fi
    n=$(find "$emitted" -type f | wc -l)
    echo "OK emitted from the generator's specs matches lowered, $n file(s)" > $out
  '';
}
