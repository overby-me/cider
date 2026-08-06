#!/usr/bin/env python3
"""How much of what a target reads does buck2 actually DECLARE? (task #69)

The port computes each target's source set in scripts/buck2-graph-sources.py, and that pass
is the one part of the graph that has to read source file CONTENTS. If everything it finds
were also declared by buck2, the pass could be deleted and the port would be generic: any
buck2 project would lower without a bespoke closure step. So the question is not "does the
closure work", it is "what does it add that buck2 did not already say".

The pass builds a target's set from four rules. Two of them are buck2 SPEAKING:

  argv       project-relative tokens in the target's own actions -- the .c and .defs files,
             the scripts a codegen edge runs, the .exp symbol lists a link reads.
  trees      the link TARGETS of every staged tree the target consumes, which is where the
             header cones live. buck2 does state these, via BXL rather than aquery.

The other two are the pass COMPENSATING, and they are the gap:

  roots      any project directory used as an include root, taken WHOLESALE, because a
             compile can read anything under one and no per-file set could know what.
  quoted     #include "..." resolved against the INCLUDING FILE own directory, to a
             fixpoint. buck2 never records this; the C preprocessor rule is not in the
             build definition at all.

This measures the last two against the current graph rather than trusting the numbers in
the generator docstrings, which were measured on an older one.

IT VERIFIES ITS OWN PARTITION. The four parts are recomputed here rather than instrumented
into the generator, so they could drift from what the generator really does and the answer
would look precise and be wrong. Every target's argv|trees|roots|quoted is compared against
the generator's own output for that target, and any mismatch is a hard failure. The import
is of the real module for the same reason: the helpers cannot be copies.

Usage:
  scripts/buck-declaration-gap.py <graph.json> <graph-data-dir>    (cwd = project root)
"""
from __future__ import annotations

import importlib.util
import os
import json
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_generator():
    """The real scripts/buck2-graph-sources.py, whose name is not an identifier."""
    path = os.path.join(HERE, "buck2-graph-sources.py")
    spec = importlib.util.spec_from_file_location("buck2_graph_sources", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv: list) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    graph_path, data = argv[1], argv[2]
    gs = _load_generator()

    with open(graph_path) as fh:
        graph = json.load(fh)
    trees = gs.read_trees(graph, data)
    actions, staged, producers = graph["actions"], graph["staged"], graph["producers"]
    print(f"{len(actions)} actions, {len(trees)} staged trees", file=sys.stderr)

    # The generator's own answer, which this partition has to reproduce exactly.
    truth = gs.target_sources(actions, trees, staged, producers)
    print(f"{len(truth)} targets in the closure", file=sys.stderr)

    known = set(producers) | set(staged) | set(trees)

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
    for a in actions:
        by_target.setdefault(a["identity"].split(" (")[0], []).append(a)

    root_dirs: dict = {}          # include root -> targets that take it wholesale
    root_files: set = set()       # files reached ONLY because of a wholesale root
    quoted_edges: set = set()     # (including file, included file) buck2 never declared
    quoted_files: set = set()
    targets_with_roots = 0
    targets_with_quoted = 0
    declared_total = 0
    union: set = set()
    mismatches = 0

    for label, acts in by_target.items():
        argv_srcs = set()
        roots_here = set()
        for a in acts:
            for tok in a["argv"]:
                for cand in gs._project_candidates(tok):
                    if os.path.lexists(cand):
                        argv_srcs.add(cand)
                        break
            for d in gs._include_roots(a["argv"]):
                if not d.startswith(("/", "@", "buck-out/")) and os.path.isdir(d):
                    roots_here.add(d)

        tree_side = set()
        owners = {o for o in (owner_of(i) for a in acts for i in a.get("inputs", [])) if o}
        for o in owners:
            if o in tree_srcs:
                tree_side |= tree_srcs[o]
                for dest in tree_srcs[o]:
                    sub = owner_of(dest)
                    if sub and sub in tree_srcs:
                        tree_side |= tree_srcs[sub]

        declared = argv_srcs | tree_side
        roots = set()
        for d in roots_here:
            roots |= under(d)
        roots -= declared

        # The fixpoint runs over declared|roots, exactly as the generator runs it over srcs.
        srcs = declared | roots
        quoted = set()
        pending = list(srcs)
        while pending:
            nxt = []
            for f in pending:
                for r in gs._quoted_includes(f):
                    if r not in srcs and r not in quoted:
                        quoted.add(r)
                        quoted_edges.add((f, r))
                        nxt.append(r)
            pending = nxt

        # THE CHECK THAT CAN FAIL: this partition must be the generator's set, exactly.
        if declared | roots | quoted != set(truth[label]):
            mismatches += 1
            if mismatches <= 3:
                mine, theirs = declared | roots | quoted, set(truth[label])
                print(f"MISMATCH {label}: +{len(mine - theirs)} -{len(theirs - mine)}",
                      file=sys.stderr)

        declared_total += len(declared)
        union |= declared | roots | quoted
        if roots:
            targets_with_roots += 1
            for d in roots_here:
                root_dirs.setdefault(d, 0)
                root_dirs[d] += 1
            root_files |= roots
        if quoted:
            targets_with_quoted += 1
            quoted_files |= quoted

    if mismatches:
        print(f"\nFAIL: {mismatches} target(s) do not match the generator. The partition below "
              f"does not describe the real pass, so none of it can be trusted.", file=sys.stderr)
        return 1

    print()
    print(f"partition verified against the generator on all {len(truth)} targets")
    print()
    print(f"union of everything the closure reaches: {len(union)} files")
    print()
    print("THE GAP, what buck2 did not declare:")
    print(f"  wholesale include roots : {len(root_dirs)} director(ies), "
          f"{len(root_files)} file(s) reached only that way, "
          f"used by {targets_with_roots} of {len(truth)} targets")
    for d, n in sorted(root_dirs.items(), key=lambda kv: -kv[1]):
        print(f"      {d}  ({len(under(d))} files, {n} target(s))")
    print(f"  quoted includes         : {len(quoted_files)} file(s) over "
          f"{len(quoted_edges)} edge(s), reached by {targets_with_quoted} target(s)")
    for src, dst in sorted(quoted_edges):
        print(f"      {src}\n        -> {dst}")
    gap = len(root_files | quoted_files)
    print()
    print(f"  total undeclared: {gap} of {len(union)} files "
          f"({100.0 * gap / max(1, len(union)):.3f} percent)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
