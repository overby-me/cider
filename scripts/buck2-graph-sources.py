#!/usr/bin/env python3
# OFF THE BUILD PATH SINCE #99. nix/lib/ciderBuck2Graph.nix runs cider-graph-sources, the second
# binary of linux/buildtools/graph-specs, and no derivation reads this file any more. It is kept
# ONLY because scripts/buck-codegen-closure.py LOADS it, for read_trees, so that its copy of that
# function cannot drift from this one.
#
# THAT IS THE SAME DRIFT RISK AS buck_lowering.py AND IT IS NAMED RATHER THAN LEFT: two
# implementations of the same source-narrowing now exist, and a change to one that is not made to
# the other would leave the check verifying the wrong thing while every build used the other. The
# resolution is to delete this: read_trees is a small function over stagedTrees and the graph data
# tables, and buck-codegen-closure.py should either carry it or read what the Rust already writes.
# Until then, ANY EDIT HERE MUST BE MADE IN linux/buildtools/graph-specs/src/sources.rs TOO, and
# the comparison that proves they agree is in that file header.
"""Which project files each target actually reads, computed against the REAL tree.

This is the ONE part of the graph that depends on source file CONTENTS rather than on the
build definition, because a quoted include is resolved by parsing #include "..." out of the
file. Everything else buck2 reports is analysis, which cannot read a source at all.

That is why it lives here instead of in buck2-graph-dump.py.

THIS PARAGRAPH USED TO SAY THE DUMP RUNS AGAINST A SKELETON, so that editing a .c could not
rerun it and 30 to 47 minutes were saved on every edit. THAT IS NOT TRUE AND WAS NEVER LEFT
IN PLACE. The skeleton was tried and REVERTED; nix/lib/ciderBuck2Graph.nix passes
`src = projectSrc` to BOTH cider-buck2-graph and cider-buck2-sources, and the comment
above it says why: this derivation does not only analyse, it also runs first-party generators
it builds itself, and an emptied rtsig.c compiles, links, runs and writes an EMPTY header, so
the graph comes out quietly wrong. A mechanism whose failure mode is silence is worse than
the cost it removes. the skeletoniser (linux/buildtools/skeleton) is kept because the idea is sound for the
ANALYSIS half, but it needs the codegen input closure first.

So editing a .c DOES rerun both derivations. What is true, and is the part worth keeping, is
that this pass is a python walk rather than a buck2 build and its output is CONTENT
ADDRESSED: editing a .c changes no FILE NAME, so the output is byte identical and nothing
downstream of it moves. Adding an include does change it, which is exactly when the consumers
should rebuild.

It reads the graph for the actions and the staged farms, and the farms themselves from the
link tables in the graph data output, since the dump stopped putting links in graph.json.

Usage:
  buck2-graph-sources.py <graph.json> <graph-data-dir> <out-dir>     (cwd = project root)
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys


# The project files each TARGET reads, precomputed here for the same reason stagedTreeDeps
# is: the Nix implementation of exactly this took 158 seconds (deleted, see history), against a
# lowering whose whole evaluation is about 14. Python does it in a second or two, and it is a
# pure function of what this dump already holds.
#
# Every lowered target currently depends on the whole filtered project, 306,019 files, so a
# one-line source edit relowers all of them. With this the median target names 4,032.
#
# The rule, and scripts/buck-lower-srcdeps.py audits its completeness:
#   * project-relative tokens in the target's own argvs;
#   * plus every link TARGET of each staged tree it consumes, which is where the header cones
#     live -- NOT the staging actions' argvs, since those actions carry no command at all;
#   * plus, WHOLESALE, any project directory used as an include root, because a compile can
#     read anything under one and no per-file set could know what. There are two of those in
#     the whole port, 26 files between them.
_GLUED = ("-I", "-F", "-L", "-iquote")


def _project_candidates(tok: str):
    if not tok or tok.startswith(("/", "@", "buck-out/")):
        return
    yield tok
    for g in _GLUED:
        if tok.startswith(g) and len(tok) > len(g):
            rest = tok[len(g):]
            if not rest.startswith(("/", "@", "buck-out/")):
                yield rest
    # A COMMA JOINED -Wl, TOKEN HIDES A FILE. darwin.bzl emits link_flag_files as
    # `<flag>,<path>` in ONE argv token, so `-Wl,-alias_list,darwin/libm/Exports/x.alias`
    # never matched anything and the alias file stayed out of the narrowed union. The
    # link then died with `ld: can't open alias file: ...`, naming a path that is right
    # there in the tree. Splitting is safe: a part that is not a path simply does not
    # exist and is dropped by the lexists test at the call site.
    if tok.startswith("-Wl,") and "," in tok[4:]:
        for part in tok[4:].split(","):
            if part and not part.startswith(("/", "@", "buck-out/", "-")):
                yield part


def _include_roots(argv: list):
    for i, t in enumerate(argv):
        if t in ("-I", "-isystem", "-F", "-iquote") and i + 1 < len(argv):
            yield argv[i + 1]
        elif t.startswith(("-I", "-F")) and len(t) > 2:
            yield t[2:]


# EVERY PATH TEST MEMOISED. target_sources is 27.9 s of the 64 s sources derivation, and the
# cost is not parsing (1.1 s for the 481 MB graph), not writing (1.9 s for 357 MB), not reading
# contents (4.2 s for all 106,770 C-family files) and not the include fixpoint (1.2 s over
# 6,419,328 pairs). It is the sheer NUMBER of path tests: 27,591 actions of roughly 90 argv
# tokens each, every token yielding up to five candidates, so on the order of ten million
# lexists at about 1.25 microseconds apiece.
#
# The same candidate string recurs constantly across actions, since flags, include roots and
# shared headers repeat, so a dict collapses those millions of syscalls to one per DISTINCT
# path. Safe because nothing writes to the tree while this runs: the derivation's source is a
# read-only store path.
_lex_cache: dict = {}
_dir_cache: dict = {}


def _lexists(p: str) -> bool:
    hit = _lex_cache.get(p)
    if hit is None:
        hit = os.path.lexists(p)
        _lex_cache[p] = hit
    return hit


def _isdir(p: str) -> bool:
    hit = _dir_cache.get(p)
    if hit is None:
        hit = os.path.isdir(p)
        _dir_cache[p] = hit
    return hit


_C_FAMILY = (".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".h", ".hpp", ".hh", ".inc")
_QUOTED_INCLUDE = re.compile(rb'^[ \t]*#[ \t]*include[ \t]*"([^"]+)"', re.M)
_quoted_cache: dict = {}


def _quoted_includes(rel: str) -> list:
    """Existing project files that a quoted include in `rel` resolves to.

    Resolved against the INCLUDING FILE own directory, which is what the C preprocessor
    does for the quoted form and what no buck2 declaration records. Cached per file,
    because a file's includes do not depend on which target is reading it, and every
    target's source set otherwise rescans the same headers.

    Only existing targets are returned: an include that names nothing is guarded out by
    the preprocessor and cannot affect a build, and 40 of the 93 uncovered ones here are
    exactly that (RELEASE_PPC artifacts, win32 headers).
    """
    hit = _quoted_cache.get(rel)
    if hit is not None:
        return hit
    found = []
    if rel.endswith(_C_FAMILY):
        try:
            with open(rel, "rb") as fh:
                data = fh.read()
        except OSError:
            data = b""
        base = os.path.dirname(rel)
        for m in _QUOTED_INCLUDE.finditer(data):
            target = m.group(1).decode("utf-8", "replace")
            res = os.path.normpath(os.path.join(base, target))
            # Escaping the project entirely is a system header by another name.
            if res.startswith("..") or not os.path.lexists(res):
                continue
            found.append(res)
            # LEXISTS, AND THE DESTINATION TOO. This test used to be os.path.exists, which
            # FOLLOWS the link, so a header that is a symlink to a sibling subtree reads as
            # absent whenever the staged tree the closure runs over does not carry the
            # destination, and the header is dropped. That is exactly
            # darwin/frameworks/DirectoryServices/src/DirectoryService.h, a link to
            # ../include/DirectoryService/DirectoryService.h, and losing it failed
            # DirectoryService_obj with `fatal error: 'DirectoryService.h' file not found`
            # after 1,500 builders. Recording the link alone would stage something pointing
            # at nothing, so record BOTH.
            if os.path.islink(res):
                dest = os.path.normpath(os.path.join(os.path.dirname(res), os.readlink(res)))
                if not dest.startswith(("..", "/")) and os.path.lexists(dest):
                    found.append(dest)
    _quoted_cache[rel] = found
    return found


def _staged_file(data: str, path: str) -> str:
    """Where scripts/buck2-graph-dump.py parked a staged artifact. Same rule as the dump."""
    return os.path.join(data, "staged", re.sub(r"[^A-Za-z0-9_.-]+", "_", path))


_manifest_cache: dict = {}


def _manifest_sources(data: str, path: str) -> list:
    """Project files a staged TSV names, for an action that reads its inputs from a FILE.

    A SOURCE ONLY TARGET IS INVISIBLE EVERYWHERE ELSE. The prefix installs
    //etc:resolv.conf, an export_file over a plain source, and buck2 reports 763 declared
    inputs for that action of which every one is an artifact WITH a producing action:
    resolv.conf appears neither in buck.all_ineligible_for_dedup_inputs nor in the cmd. So
    argv scraping cannot see it, the declared-input scrape cannot see it, and the narrowed
    union dropped it, which failed the prefix on `cp: cannot stat 'etc/resolv.conf'` at the
    very last derivation of a 2,333 builder run.

    The manifest itself does carry it, as `file<TAB>libexec/.../etc/resolv.conf<TAB>etc/resolv.conf`,
    and the dump already stages the manifest as DATA because it is an in-process write. So
    read it. Any column that names an existing project file counts, which also covers the
    two column farm tables without needing to know which form a given TSV is in.
    """
    hit = _manifest_cache.get(path)
    if hit is not None:
        return hit
    found = []
    try:
        with open(_staged_file(data, path)) as fh:
            for line in fh:
                for col in line.rstrip("\n").split("\t"):
                    if (col and not col.startswith(("/", "@", "buck-out/"))
                            and not col.startswith("..") and os.path.lexists(col)):
                        found.append(col)
    except OSError:
        found = []
    _manifest_cache[path] = found
    return found


def target_sources(ran: list, trees: dict, staged: dict, producer: dict, data: str) -> dict:
    known = set(producer) | set(staged) | set(trees)

    def owner_of(path: str):
        segs = path.split("/")
        for n in range(len(segs), 0, -1):
            pfx = "/".join(segs[:n])
            if pfx in known:
                return pfx
        return None

    tree_srcs = {}
    for path, links in trees.items():
        out = set()
        for rel, tgt in links.items():
            dest = os.path.normpath(os.path.join(os.path.dirname(os.path.join(path, rel)), tgt))
            if not dest.startswith("buck-out/") and not dest.startswith("/"):
                out.add(dest)
        tree_srcs[path] = out

    whole = {}

    def under(d: str) -> set:
        if d not in whole:
            found = set()
            for dp, _dn, fs in os.walk(d):
                found.update(os.path.join(dp, f) for f in fs)
            whole[d] = found
        return whole[d]

    # ONCE PER OWNER, NOT ONCE PER TARGET. This used to walk every destination of every farm a
    # target consumes, calling owner_of on each, and owner_of is itself a segment-by-segment
    # prefix search. With 2,339 targets sharing a few hundred farms that repeated the same work
    # thousands of times over: SUBPHASE trees measured 10.8 s of the 25.2 s in this function.
    # The closure of a farm is a property of the FARM, so it is computed once and reused.
    _closure_cache: dict = {}

    def _tree_closure(o):
        hit = _closure_cache.get(o)
        if hit is None:
            hit = set(tree_srcs[o])
            for dest in tree_srcs[o]:
                sub = owner_of(dest)
                if sub and sub in tree_srcs:
                    hit |= tree_srcs[sub]
            _closure_cache[o] = hit
        return hit

    by_target = {}
    for a in ran:
        by_target.setdefault(a["identity"].split(" (")[0], []).append(a)

    out = {}
    import time as _tm
    _acc = {"argv": 0.0, "roots": 0.0, "rustc": 0.0, "manifest": 0.0, "trees": 0.0, "fixpoint": 0.0}
    for label, acts in by_target.items():
        srcs = set()
        _t = _tm.time()
        for a in acts:
            for tok in a["argv"]:
                for cand in _project_candidates(tok):
                    if _lexists(cand):
                        srcs.add(cand)
                        break
        _acc["argv"] += _tm.time() - _t
        _t = _tm.time()
        for a in acts:
            for d in _include_roots(a["argv"]):
                if not d.startswith(("/", "@", "buck-out/")) and _isdir(d):
                    srcs |= under(d)
        _acc["roots"] += _tm.time() - _t
        # A RUST CRATE NAMES ONLY ITS ROOT, so narrowing used to hand rustc one file.
        # rustc gets lib.rs (or main.rs) in argv and finds everything else through `mod`
        # declarations. The scanner above cannot see those: it parses #include "...", which
        # is a C construct. Measured before this went in: of 77,709 recorded project sources
        # the whole server crate contributed exactly ONE, linux/server/src/lib.rs, and the
        # narrowed endpoint died with
        #   error[E0583]: file not found for module `xnu`  --> linux/server/src/lib.rs:42
        # after 1,462 green builders. That was the ONLY failure in the narrowed endpoint.
        #
        # Take the crate directory WHOLESALE, exactly as an include root is taken. Cheaper
        # than teaching the scanner Rust, and it cannot miss a module: mod paths are
        # relative to the crate root directory, so everything reachable is under it. A
        # rust_library glob is src/**/*.rs anyway, so this is the set buck2 already declares.
        _t = _tm.time()
        for a in acts:
            if "(rustc " not in a["identity"]:
                continue
            for tok in a["argv"]:
                if tok.endswith(".rs") and not tok.startswith(("/", "@", "buck-out/")):
                    d = os.path.dirname(tok)
                    if d and _isdir(d):
                        srcs |= under(d)
        _acc["rustc"] += _tm.time() - _t
        _t = _tm.time()
        for a in acts:
            # An action that reads its inputs from a FILE, see _manifest_sources.
            for i in a.get("inputs", []):
                if i.endswith(".tsv") and i in staged:
                    srcs.update(_manifest_sources(data, i))
        _acc["manifest"] += _tm.time() - _t
        _t = _tm.time()
        owners = {o for o in (owner_of(i) for a in acts for i in a.get("inputs", [])) if o}
        for o in owners:
            if o in tree_srcs:
                srcs |= _tree_closure(o)
        # A quoted include resolves against the INCLUDING FILE own directory, which buck2
        # never declares, so it has to be recovered here or the narrowed source set drops a
        # header the compile really reads and the build dies late. To a fixpoint, because
        # headers include headers.
        #
        # The comment at projectSrc in the lowering said this case needs depfiles. It does
        # not, for this tree, and that was measured rather than assumed: of the 64,903 C
        # family files in the union, 734 hold a quoted dot dot include, 93 are not already
        # covered, 40 of those name a file that does not exist and so are guarded out, and
        # 48 of the surviving 53 belong to vim, whose GUI has ZERO compile actions here.
        # The whole real gap is five files: the three otool disassemblers reaching for
        # cctools/as/*-opcode.h, gripes.c reaching for catopen/catopen.c, which is a .c and
        # not a header, and CFOpenDirectory.c reaching for its generated-stubs.h.
        _acc["trees"] += _tm.time() - _t
        _t = _tm.time()
        pending = list(srcs)
        while pending:
            nxt = []
            for f in pending:
                for r in _quoted_includes(f):
                    if r not in srcs:
                        srcs.add(r)
                        nxt.append(r)
            pending = nxt
        _acc["fixpoint"] += _tm.time() - _t
        out[label] = sorted(srcs)
    for k, v in sorted(_acc.items(), key=lambda kv: -kv[1]):
        print(f"  SUBPHASE {k}: {v:.1f}s", file=sys.stderr)
    return out

# Grouping (#54). Every target stages ONE shared source path today, so a byte changing
# anywhere in it moves that path and all 3,225 targets rebuild. Source groups fix that by
# giving a target only the subtrees it reads -- but the lowering used to work them out by
# parsing the per-target map, 10.5 million entries for 124,055 distinct files, which cost
# eval 21.4s to 75.6s and heap 1.76 to 3.40 GB. It never needed the FILES, only the GROUPS,
# and that is 3,225 targets times a few entries. It is computed here, where the map is
# already in hand, so the lowering reads a small file and never parses the big one.
#
# buck-src, pins and buck-rust are deliberately ungrouped, each for its own reason:
# the first two are pins staged wholesale by revision and a group there would collide with
# those symlinks, and buck-rust is gitignored and comes from the vendor derivation, so a
# builtins.path at one would fail with "not tracked by Git".
_UNGROUPED = ("buck-src/", "pins/", "buck-rust/")


def group_of(p: str):
    if p.startswith(_UNGROUPED):
        return None
    segs = p.split("/")
    return "/".join(segs[:3]) if len(segs) >= 4 else None


def target_groups(per_target: dict) -> dict:
    """{target: {groups, shallow}} -- the subtrees it reads, plus the files in no group.

    os.path.exists and NOT lexists, to match the builtins.pathExists this replaces: a
    dangling symlink is false to Nix, and staging one would point at nothing.
    """
    out = {}
    for label, files in per_target.items():
        groups = sorted({g for g in (group_of(p) for p in files) if g})
        shallow = sorted(
            p for p in files
            if not p.startswith(_UNGROUPED)
            and group_of(p) is None
            and p != "."
            and os.path.exists(p)
        )
        out[label] = {"groups": groups, "shallow": shallow}
    return out


def read_trees(graph: dict, data: str) -> dict:
    """{staged tree: {link name: link target}} back out of the per farm tables.

    Two forms, because the dump writes names only when a target is derivable from its name
    and falls back to the explicit two columns when it is not. Reading the wrong one would
    not fail, it would silently resolve every link to nonsense, so the form is taken from
    the index rather than guessed from the line.
    """
    trees = {}
    for path, meta in graph.get("stagedTrees", {}).items():
        links = {}
        if meta.get("n"):
            with open(os.path.join(data, meta["table"])) as fh:
                if "k" in meta:
                    k, pre = meta["k"], meta["prefix"]
                    for line in fh:
                        rel = line.rstrip("\n")
                        links[rel] = "../" * (k + rel.count("/")) + pre + rel
                else:
                    for line in fh:
                        name, _, target = line.rstrip("\n").partition("\t")
                        links[name] = target
        trees[path] = links
    return trees


def main(argv: list) -> int:
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    graph_path, data, outdir = argv[1], argv[2], argv[3]
    import time as _t
    _t0 = _t.time()
    def _phase(name):
        nonlocal _t0
        now = _t.time()
        print(f"PHASE {name}: {now - _t0:.1f}s", file=sys.stderr)
        _t0 = now
    os.makedirs(outdir, exist_ok=True)
    with open(graph_path) as fh:
        graph = json.load(fh)
    _phase("load graph.json")

    trees = read_trees(graph, data)
    _phase("read_trees")
    per_target = target_sources(graph["actions"], trees, graph["staged"], graph["producers"], data)
    _phase("target_sources")
    union = sorted({p for v in per_target.values() for p in v})
    _phase("union")

    # TWO FILES, for the same reason the dump split this out of graph.json: the per-target
    # breakdown is 10.5 million entries and only the narrowSources path ever looks at it,
    # while every evaluation wants the union. Parsing both together cost 651 MB of heap for
    # data the default path never touched.
    with open(os.path.join(outdir, "sources.json"), "w") as fh:
        json.dump({"projectSources": union}, fh, sort_keys=True)
        fh.write("\n")
    # 357 MB THAT NOTHING AUTOMATED READS, and nix has to hash it and copy it into the store on
    # every run. The lowering reads target-groups.json (1.5 MB); the only references to this
    # file are comments plus an optional --sources flag on scripts/buck-codegen-closure.py,
    # which a person runs by hand. Measured: the script's own phases are 19 s of a 53 s
    # derivation, so the rest is nix moving data, and this file is 87 percent of the output.
    #
    # Set CIDER_EMIT_TARGET_SOURCES=1 when a hand-run tool wants it. This one is read out of
    # the ENVIRONMENT, so the DARLING_ spelling keeps working for anything that already sets it.
    if (os.environ.get("CIDER_EMIT_TARGET_SOURCES")
            or os.environ.get("DARLING_EMIT_TARGET_SOURCES")) != "1":
        print("  skipping target-sources.json (set CIDER_EMIT_TARGET_SOURCES=1 to emit)",
              file=sys.stderr)
    else:
      with open(os.path.join(outdir, "target-sources.json"), "w") as fh:
          json.dump(per_target, fh, sort_keys=True)
          fh.write("\n")

    # PER-TARGET FILE LISTS AS FILES, and an INDEX naming them (#54). The lowering builds one
    # source subset per target, and it must not learn those lists through Nix: 2,339 targets
    # times a median of 4,048 files is 9.5 million entries, which is the same shape that made
    # the staged-tree scripts 40 percent of evaluation before #47 moved them into tables.
    # Written here, the lowering carries ONE string per target, the path to its list.
    #
    # Named by content, like the treelinks tables since #63, so targets that read exactly the
    # same set share a file. Measured on this graph: it collapses 2,339 lists to far fewer.
    subdir = os.path.join(outdir, "subsets")
    os.makedirs(subdir, exist_ok=True)
    written, index = {}, {}
    for label, files in per_target.items():
        text = "".join(p + "\n" for p in sorted(files))
        rel = written.get(text)
        if rel is None:
            rel = "subsets/" + hashlib.sha256(text.encode()).hexdigest()[:16] + ".txt"
            written[text] = rel
            with open(os.path.join(outdir, rel), "w") as fh:
                fh.write(text)
        index[label] = rel
    with open(os.path.join(outdir, "target-subsets.json"), "w") as fh:
        json.dump(index, fh, sort_keys=True)
        fh.write("\n")
    print(f"  {len(index)} target subset(s) sharing {len(written)} distinct list file(s)")

    groups = target_groups(per_target)
    with open(os.path.join(outdir, "target-groups.json"), "w") as fh:
        json.dump(groups, fh, sort_keys=True)
        fh.write("\n")
    print(f"  {sum(len(v['groups']) for v in groups.values())} target-to-group edge(s) over "
          f"{len({g for v in groups.values() for g in v['groups']})} distinct group(s), and "
          f"{len({p for v in groups.values() for p in v['shallow']})} file(s) in no group")

    print(f"sources: {len(union)} distinct project source(s), from "
          f"{sum(len(v) for v in per_target.values())} per-target entries across "
          f"{len(per_target)} target(s)")
    if not union:
        raise SystemExit("sources: the union is empty, which cannot be right")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
