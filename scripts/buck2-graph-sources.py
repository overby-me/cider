#!/usr/bin/env python3
"""Which project files each target actually reads, computed against the REAL tree.

This is the ONE part of the graph that depends on source file CONTENTS rather than on the
build definition, because a quoted include is resolved by parsing #include "..." out of the
file. Everything else buck2 reports is analysis, which cannot read a source at all.

That is why it lives here instead of in buck2-graph-dump.py. The dump now runs against a
skeleton (scripts/buck-skeleton.py: build files verbatim, every other file present but
empty), so editing a .c cannot rerun it, 30 to 47 minutes saved on every edit. This pass
does need the real bytes, but it is a python walk rather than a buck2 build, and its output
is content addressed: editing a .c changes no FILE NAME, so the output is byte identical and
nothing downstream moves. Adding an include changes it, which is exactly when the consumers
should rebuild.

It reads the graph for the actions and the staged farms, and the farms themselves from the
link tables in the graph data output, since the dump stopped putting links in graph.json.

Usage:
  buck2-graph-sources.py <graph.json> <graph-data-dir> <out-dir>     (cwd = project root)
"""
from __future__ import annotations

import json
import os
import re
import sys


# The project files each TARGET reads, precomputed here for the same reason stagedTreeDeps
# is: nix/lib/buck2-srcdeps.nix computes exactly this and takes 158 seconds, against a
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


def _include_roots(argv: list):
    for i, t in enumerate(argv):
        if t in ("-I", "-isystem", "-F", "-iquote") and i + 1 < len(argv):
            yield argv[i + 1]
        elif t.startswith(("-I", "-F")) and len(t) > 2:
            yield t[2:]


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
            if not res.startswith("..") and os.path.exists(res):
                found.append(res)
    _quoted_cache[rel] = found
    return found


def target_sources(ran: list, trees: dict, staged: dict, producer: dict) -> dict:
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

    by_target = {}
    for a in ran:
        by_target.setdefault(a["identity"].split(" (")[0], []).append(a)

    out = {}
    for label, acts in by_target.items():
        srcs = set()
        for a in acts:
            for tok in a["argv"]:
                for cand in _project_candidates(tok):
                    if os.path.lexists(cand):
                        srcs.add(cand)
                        break
            for d in _include_roots(a["argv"]):
                if not d.startswith(("/", "@", "buck-out/")) and os.path.isdir(d):
                    srcs |= under(d)
        owners = {o for o in (owner_of(i) for a in acts for i in a.get("inputs", [])) if o}
        for o in owners:
            if o in tree_srcs:
                srcs |= tree_srcs[o]
                for dest in tree_srcs[o]:
                    sub = owner_of(dest)
                    if sub and sub in tree_srcs:
                        srcs |= tree_srcs[sub]
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
        pending = list(srcs)
        while pending:
            nxt = []
            for f in pending:
                for r in _quoted_includes(f):
                    if r not in srcs:
                        srcs.add(r)
                        nxt.append(r)
            pending = nxt
        out[label] = sorted(srcs)
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
    os.makedirs(outdir, exist_ok=True)
    with open(graph_path) as fh:
        graph = json.load(fh)

    trees = read_trees(graph, data)
    per_target = target_sources(graph["actions"], trees, graph["staged"], graph["producers"])
    union = sorted({p for v in per_target.values() for p in v})

    # TWO FILES, for the same reason the dump split this out of graph.json: the per-target
    # breakdown is 10.5 million entries and only the narrowSources path ever looks at it,
    # while every evaluation wants the union. Parsing both together cost 651 MB of heap for
    # data the default path never touched.
    with open(os.path.join(outdir, "sources.json"), "w") as fh:
        json.dump({"projectSources": union}, fh, sort_keys=True)
        fh.write("\n")
    with open(os.path.join(outdir, "target-sources.json"), "w") as fh:
        json.dump(per_target, fh, sort_keys=True)
        fh.write("\n")

    print(f"sources: {len(union)} distinct project source(s), from "
          f"{sum(len(v) for v in per_target.values())} per-target entries across "
          f"{len(per_target)} target(s)")
    if not union:
        raise SystemExit("sources: the union is empty, which cannot be right")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
