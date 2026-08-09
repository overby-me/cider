#!/usr/bin/env python3
"""Which project files must keep their real CONTENTS for the graph dump to be correct? (#56)

THE BLOCKER THIS REMOVES. The graph derivation takes the whole project, so editing any C file
rebuilds it, currently about 18m34s, before anything else can start. The obvious fix is to feed
it a SKELETON (scripts/buck-skeleton.py: build files verbatim, every other file present but
empty), and that was tried and REVERTED, for a good reason recorded in
nix/lib/ciderBuck2Graph.nix: the dump does not only analyse. It materialises in-process
artifacts, and a staged farm of GENERATED headers is produced by RUNNING a generator that this
derivation builds from first-party C. An emptied rtsig.c compiles, links, runs, and writes an
EMPTY header. The graph comes out quietly wrong and the failure lands far away.

PLAN.md says what the skeleton needs first: the codegen input closure, so that exactly the
files this derivation compiles keep their contents. That is what this computes.

THE DEFINITION MATTERS, and the obvious one is useless. Taking "every target whose output is
named in another target's argv" gives 1,501 of 2,339 targets and 74,566 of 74,621 files, 99.9
percent, because that relation is the entire build graph: every object a link consumes, every
archive a dylib consumes. The dump does not build those.

What the dump actually materialises is what ends up INSIDE A STAGED FARM. So the roots are the
link targets of staged trees that point under buck-out/, meaning a generated artifact rather
than a project source, and the closure is those targets plus whatever generated inputs they
themselves consume.

MEASURED on the current graph:

  staged trees                                    4,175
  generated artifacts staged into them               44
  targets producing them                             43
  plus their transitive producers                    48   of 2,339
  their source files                              1,743   of 74,621  (2.3 percent)
    src 1,727, buck-rust 10, buck-src 5, linux 1

So 92 percent of the union is buck-src, and none of it needs real bytes.

VERIFIED WHERE IT COUNTS, both ways: src/startup/rtsig.c and
src/libelfloader/wrapgen/wrapgen.cpp, the two the revert was about, are BOTH in the closure,
while buck-src/adv_cmds/finger/finger.c and buck-src/vim/vim/src/main.c are both outside it.
--check runs exactly those four and fails if any answer flips.

AND THAT CHECK DEMONSTRABLY FAILS ON A WRONG DEFINITION, which is the only reason to keep it.
Under the argv-reachability definition above, the one that yields 74,566 files, finger.c and
vim main.c are both IN the closure, so --check reports the definition has widened. It is not a
check that can only pass.

TWO THINGS TO BE HONEST ABOUT BEFORE ANYONE BUILDS ON THIS:

  It is computed FROM A GRAPH, so it needs a previous one to bootstrap. PLAN.md already frames
  it that way. A first dump on a new tree has to run against the real project.

  IT MUST BE REGENERATED, NEVER HAND MAINTAINED. Adding a codegen edge whose sources are not in
  the list reintroduces exactly the silent wrongness the revert was about: an empty generator
  input does not fail, it produces an empty output. Anything consuming this should recompute it
  from the graph it is about to replace, and should refuse to run on a stale one.

Usage:
  scripts/buck-codegen-closure.py <graph.json> <graph-data-dir> [--sources <target-sources.json>]
  scripts/buck-codegen-closure.py ... --list      # print the files, one per line
  scripts/buck-codegen-closure.py ... --targets   # print the target labels
  scripts/buck-codegen-closure.py ... --check     # run the four spot checks, exit 1 on failure
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# The two the revert was about must be IN; two ordinary buck-src sources must be OUT. A closure
# that cannot fail this is not measuring anything.
# linux/server/wrapper.h is here because it ESCAPED the first version of this closure and cost
# a failed skeleton graph build to find. bindgen reads it, the daemon includes the result, and
# emptying it produced 83 rustc errors rather than anything pointing at the skeleton.
MUST_BE_REAL = (
    "src/startup/rtsig.c",
    "src/libelfloader/wrapgen/wrapgen.cpp",
    "linux/server/wrapper.h",
)
MUST_NOT_BE = ("buck-src/adv_cmds/finger/finger.c", "buck-src/vim/vim/src/main.c")


def _load_generator():
    """The real scripts/buck2-graph-sources.py, so read_trees cannot drift from it."""
    path = os.path.join(HERE, "buck2-graph-sources.py")
    spec = importlib.util.spec_from_file_location("buck2_graph_sources", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def action_category(identity: str) -> str:
    """The trailing "(category detail)" of an aquery identity, e.g. c_compile or bindgen."""
    parts = identity.rsplit("(", 1)
    return parts[1].split(" ")[0].rstrip(")") if len(parts) > 1 else ""


# EVERY CATEGORY THAT RUNS SOMETHING AND FEEDS SOMETHING ELSE. Taken from the port's own rules
# rather than guessed, and it is the complement of the four that only consume: c_compile,
# cxx_compile, darwin_link, archive, link, rustc, rustc_link.
#
# THE STAGED FARM ROOTS ALONE WERE NOT ENOUGH, and this is what proved it. The first version of
# this script rooted only artifacts a staged farm contains, which finds mig, the ELF wrappers
# and rtsig but MISSES bindgen: dtape_bindings is consumed by a cargo build through OUT_DIR and
# never lands in a farm. So linux/server/wrapper.h was emptied, bindgen wrote nothing, and the
# skeleton graph died with 83 rustc errors in sched.rs on an unresolved crate::bindings. The
# experiment is what found it; the closure did not.
_GENERATOR_CATEGORIES = frozenset([
    "mig", "elf_wrapper", "bison", "flex", "bindgen", "configure_file",
    "forwarded_headers", "stdout_gen", "script_gen", "host_gen", "preprocess",
    "prefix_gen_dir", "prefix_tree",
])


def codegen_targets(graph: dict, trees: dict) -> set:
    actions = graph["actions"]
    producer, by_target = {}, collections.defaultdict(list)
    for a in actions:
        label = a["identity"].split(" (")[0]
        by_target[label].append(a)
        for o in a.get("outputs") or []:
            producer[str(o)] = label

    # Root 1: artifacts a staged farm actually contains that came out of the build rather
    # than out of the project. buck2-graph-sources.py keeps the complement of this set, the
    # links that resolve to project sources.
    generated = set()
    for path, links in trees.items():
        for rel, tgt in links.items():
            dest = os.path.normpath(os.path.join(os.path.dirname(os.path.join(path, rel)), tgt))
            if dest.startswith("buck-out/"):
                generated.add(dest)

    need = {producer[d] for d in generated if d in producer}
    # Root 2: anything that RUNS a generator, whether or not its output is ever staged.
    need |= {
        a["identity"].split(" (")[0]
        for a in actions
        if action_category(a["identity"]) in _GENERATOR_CATEGORIES
    }
    frontier = set(need)
    while frontier:
        nxt = set()
        for label in frontier:
            for a in by_target.get(label, []):
                for tok in a.get("argv") or []:
                    p = producer.get(str(tok))
                    if p is not None and p not in need:
                        need.add(p)
                        nxt.add(p)
        frontier = nxt
    return need, len(generated), len(by_target)


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("graph")
    ap.add_argument("data")
    ap.add_argument("--sources", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--targets", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv[1:])

    gs = _load_generator()
    with open(args.graph) as fh:
        graph = json.load(fh)
    trees = gs.read_trees(graph, args.data)
    need, n_generated, n_targets = codegen_targets(graph, trees)
    del graph

    if args.targets:
        for t in sorted(need):
            print(t)
        return 0

    print(f"staged trees                     {len(trees):8d}", file=sys.stderr)
    print(f"generated artifacts staged in    {n_generated:8d}", file=sys.stderr)
    print(f"targets in the codegen closure   {len(need):8d}  of {n_targets}", file=sys.stderr)

    sources = args.sources
    if not sources:
        # Sits beside the graph in the sources derivation, not in the graph output.
        print("no --sources given, so only the target closure was computed", file=sys.stderr)
        return 0

    with open(sources) as fh:
        per_target = json.load(fh)
    union, every = set(), set()
    for label, files in per_target.items():
        every.update(files)
        if label in need:
            union.update(files)
    pct = 100.0 * len(union) / max(1, len(every))
    print(f"files that must stay REAL        {len(union):8d}  of {len(every)}  ({pct:.1f} percent)",
          file=sys.stderr)
    top = collections.Counter(f.split("/")[0] for f in union)
    for k, v in top.most_common(8):
        print(f"    {v:7d}  {k}", file=sys.stderr)

    if args.check:
        bad = []
        for p in MUST_BE_REAL:
            if p not in union:
                bad.append(f"MISSING from the closure, and blanking it fails SILENTLY: {p}")
        for p in MUST_NOT_BE:
            if p in union:
                bad.append(f"unexpectedly IN the closure, so the definition has widened: {p}")
        if bad:
            print("\nFAIL:", file=sys.stderr)
            for b in bad:
                print("  " + b, file=sys.stderr)
            return 1
        print("\ncheck: rtsig.c and wrapgen.cpp are in, finger.c and vim main.c are out",
              file=sys.stderr)

    if args.list:
        for f in sorted(union):
            print(f)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
