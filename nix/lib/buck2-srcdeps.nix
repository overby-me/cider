# Which project files does each lowered target actually read?
#
# nix/lib/darlingBuck2Lower.nix gives every target the whole filtered project, so editing one
# source relowers all of them. The precise fix (task #11) needs this set per target, and this
# computes it from the graph the lowering already reads. It is SEPARATE from the lowering on
# purpose: the cost of computing it is the open question, and a module that can be evaluated
# and timed on its own answers that without disturbing an endpoint that took a lot of work to
# get to 9 seconds of CPU.
#
# The rule, which scripts/buck-lower-srcdeps.py measures the same way and audits:
#
#   * the project-relative tokens in a target's own action argvs -- the .c and .defs files,
#     the scripts a codegen edge runs, the .exp symbol lists a link reads;
#   * plus every link TARGET of each staged tree it consumes, which is where the header cones
#     live. NOT the staging actions' argvs: those actions are kind symlinkeddir and carry no
#     command at all, which is the premise the task originally had backwards.
#
# Tree ownership is the lowering's own ownerOf: longest known prefix of an input path,
# because an action's output is often a directory and consumers name files inside it.
#
# MEASURED, and the answer is that this must not stay in Nix. Against the 671-target graph
# it agrees with scripts/buck-lower-srcdeps.py -- 671 targets, median 4,032 files, max 5,749,
# union 16,100 against Python's 16,101 -- and it takes 158 seconds to evaluate. The whole
# lowering currently evaluates in about 14 seconds wall, 9 of CPU, and that number was fought
# for: link normalisation was about a quarter of it before the dumper started precomputing
# stagedTreeDeps. Wiring this in as it stands would undo that eleven times over, to compute
# something that is a pure function of a graph.json Nix has already read.
#
# So the same answer as last time: PRECOMPUTE IT IN THE DUMPER. Python does this set in
# seconds (buck-lower-srcdeps.py is the proof), the graph is already the place where derived
# facts live, and the lowering would then just read a list per target. This file stays as the
# specification and the cross-check for that, not as the implementation.
#
# The one-file difference from the Python is not noise worth ignoring: Python decides a token
# is a project path with os.path.lexists and additionally takes the two project include roots
# WHOLESALE (src/xtrace/include and src/launchd/src, 26 files), while this uses a
# first-component prefix rule, because an existence check per token is a filesystem call and
# there are millions of tokens. Reconcile those before the precomputed version is trusted.
{
  lib,
  graph,
}: let
  g = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (builtins.readFile "${graph}/graph.json")
  );

  # A token is a project path when its first component is a directory the project stages.
  # By PREFIX rather than by builtins.pathExists: an existence check is a filesystem call per
  # token, and there are millions of tokens across the graph.
  ROOTS = ["buck-src" "src" "darwin" "buck-rust" "tests" "linux" "etc" "misc" "cmake"];

  targetOf = a: lib.head (lib.splitString " (" a.identity);
  targets = lib.groupBy targetOf g.actions;

  producerTarget = lib.listToAttrs (lib.concatMap (a:
    map (o: {
      name = o;
      value = targetOf a;
    })
    a.outputs)
  g.actions);

  stagedTrees = g.stagedTrees or {};
  known = producerTarget // (g.staged or {}) // stagedTrees;

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

  # A flag can carry its path in the same token (-Ifoo), so strip the ones that do.
  GLUED = ["-I" "-F" "-L" "-iquote"];
  unglue = tok:
    lib.foldl' (acc: p:
      if acc == tok && lib.hasPrefix p tok && tok != p
      then lib.removePrefix p tok
      else acc)
    tok
    GLUED;

  isProject = tok:
    tok != ""
    && !(lib.hasPrefix "/" tok)
    && !(lib.hasPrefix "@" tok)
    && !(lib.hasPrefix "buck-out/" tok)
    && builtins.elem (lib.head (lib.splitString "/" tok)) ROOTS;

  argvSources = acts:
    lib.filter isProject (map unglue (lib.concatMap (a: a.argv) acts));

  # PRECOMPUTED per tree, not per consumer: a staged farm is consumed by many targets, and
  # resolving its links once per consumer is the shape that already cost this endpoint a
  # quarter of its evaluation before stagedTreeDeps existed.
  treeSources =
    lib.mapAttrs (path: links:
      lib.filter isProject (
        lib.mapAttrsToList (rel: tgt: let
          dir = lib.concatStringsSep "/" (lib.init (lib.splitString "/" "${path}/${rel}"));
        in
          normalise "${dir}/${tgt}")
        links
      ))
    stagedTrees;

  # ".." folding, textually. The dumper does this for stagedTreeDeps with one normpath per
  # link; here it is needed for the link VALUES themselves.
  normalise = p:
    lib.concatStringsSep "/" (lib.foldl' (acc: seg:
      if seg == "." || seg == ""
      then acc
      else if seg == ".."
      then (if acc == [] then [] else lib.init acc)
      else acc ++ [seg])
    [] (lib.splitString "/" p));

  sourcesFor = label: let
    acts = targets.${label};
    ins = lib.unique (lib.concatMap (a: a.inputs) acts);
    owners = lib.unique (lib.filter (o: o != null) (map ownerOf ins));
    fromTrees = lib.concatMap (o: treeSources.${o} or []) owners;
  in
    lib.unique (argvSources acts ++ fromTrees);
in {
  inherit sourcesFor targets;

  # Everything the port reads, which is what a single shared filter could be narrowed to if
  # per-target proves too expensive.
  union = lib.unique (lib.concatMap sourcesFor (lib.attrNames targets));

  # For measuring: {target = count;}, cheap to print and to compare against
  # scripts/buck-lower-srcdeps.py, which computes the same sets in Python.
  counts = lib.mapAttrs (label: _: lib.length (sourcesFor label)) targets;
}
