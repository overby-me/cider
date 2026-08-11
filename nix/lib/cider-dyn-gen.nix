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

  # Mirrors safe_name in the generator and specName in the lowering, which is the key the spec
  # files are named by.
  specName = l: lib.stringAsChars (c:
    if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
    || c == "_" || c == "." || c == "-"
    then c
    else "_")
  l;

  coneOf = l: let
    direct = lowered.drvs.${l}.passthru.deps;
  in
    lib.unique (lib.concatMap (d: coneOf d ++ [d]) direct);
  members = coneOf label ++ [label];

  # WHAT stdenv WOULD HAVE PUT ON PATH. tools is only what the lowering ADDS to stdenv, and an
  # emitted action has no stdenv: no setup hooks, no propagation. llvm-ar is the case that
  # proved it, reachable only through the bintools wrapper's setup hook, so the unwrapped
  # package is named here explicitly.
  stdenvBasics = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.gnutar
    pkgs.gzip
    pkgs.diffutils
    pkgs.patch
    pkgs.bash
    pkgs.llvmPackages.bintools.bintools
  ];

  # THE SPEC DIR THE GENERATOR WROTE. No mkSpecDir, no toJSON in the evaluator, no per-group
  # anything: one store path holding all 1,474 specs, and the bridge reads the ones asked for.
  specDir = "${lowered.graphSpecs}/dyn";

  # Per action, keyed by the SPEC NAME because that is what the bridge asks about.
  byName = lib.listToAttrs (map (l: lib.nameValuePair (specName l) l) members);

  extraEnv = name: let
    l = byName.${name} or null;
  in
    if l == null
    then {}
    else let
      d = lowered.drvs.${l};
    in
      {
        CIDER_PATH = lib.makeBinPath (d.passthru.tools ++ stdenvBasics);
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

  bridge = import ./dyn-actions.nix {
    inherit pkgs specDir extraEnv;
    # The scripts name their inputs inside the command rather than in a list, which is the case
    # inferSrcs exists for.
    inferSrcs = true;
  };
in {
  inherit bridge members specDir;

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
    if ! diff -r "$emitted" "$lowered" > diff.txt 2>&1; then
      echo "FAIL: the emitted output differs from the lowered one" >&2
      head -40 diff.txt >&2
      exit 1
    fi
    n=$(find "$emitted" -type f | wc -l)
    echo "OK emitted from the generator's specs matches lowered, $n file(s)" > $out
  '';
}
