#!/usr/bin/env python3
"""Rank a prefix's install entries by the build cost ONLY THEY pull in.

The minimal prefix is defined by SUBTRACTION: gen-prefix-min.py takes the full prefix and
removes what is on an exclusion list, so anything expensive is included BY DEFAULT and has to
be noticed one entry at a time. That is how `//buck-src:jsc` survived -- one line,
`libexec/darling/usr/bin/jsc`, that pulled 1,082 compiles of JavaScriptCore into a prefix
whose stated job is to boot, run bash and run nix. #70 was the same shape earlier: two bare
target names pulling in the guest cone. Noticing those by hand does not scale across 2,357
entries over an 8,000-target cone.

TWO THINGS THIS MEASURES CAREFULLY, because the obvious versions of both are useless:

COST IS ACTIONS, NOT TARGETS. `jsc` is 14 targets and 1,082 compiles: the target that does the
work, JavaScriptCore_obj, is ONE target holding 1,082 actions. A ranking by target count puts
jsc near the bottom and tells you nothing.

COST IS EXCLUSIVE, NOT TOTAL. Nearly every entry reaches libc, libsystem and dyld, so ranking
by total reachable cost puts everything within a few percent of everything else. What made jsc
stand out is that its cone is reachable from NO OTHER entry, so deleting the one line removes
all of it. Entries sharing a cone are reported with cost 0 here, correctly: removing one of
them saves nothing on its own.

Reads the graph dump the port already produces, so it needs no buck2 query and no build.

Usage:
  scripts/buck-prefix-cost.py                          # newest built graph, minimal prefix
  scripts/buck-prefix-cost.py --graph <graph.json>
  scripts/buck-prefix-cost.py --prefix buck/prefix/BUCK --top 40
"""

import argparse
import collections
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The right hand side of an install entry: "dest": "//pkg:name".
_LABEL = re.compile(r'"\s*:\s*"(//[^"]+)"')


def newest_graph():
    paths = glob.glob("/nix/store/*-darling-buck2-graph/graph.json")
    if not paths:
        sys.exit("no built graph found; pass --graph, or build .#darling-buck2-graph")
    return max(paths, key=os.path.getmtime)


def load_graph(path):
    """target -> action count, and target -> set of dependency targets.

    An action's `identity` is `<label> (<cfg>) (<action name>)`, so the label is everything
    before the first " (". Its `input_targets` are the target-level inputs, which is the edge
    set; unioned over a target's actions it gives that target's dependencies.
    """
    with open(path) as f:
        g = json.load(f)
    actions = g.get("actions") or []
    if not actions:
        sys.exit(f"{path} has no actions; is it a graph dump?")
    cost = collections.Counter()
    deps = collections.defaultdict(set)
    for a in actions:
        label = a["identity"].split(" (")[0]
        cost[label] += 1
        for d in a.get("input_targets") or []:
            if d != label:
                deps[label].add(d)
    return cost, deps


def entry_labels(prefix_buck):
    """Install entries, as label -> the destinations that name it.

    Several destinations can name one label (a binary installed twice), and the actionable
    unit is the LABEL, since that is what carries the cone.
    """
    dests = collections.defaultdict(list)
    with open(prefix_buck) as f:
        for line in f:
            m = _LABEL.search(line)
            if not m:
                continue
            d = re.match(r'^\s*"([^"]+)"\s*:', line)
            dests["root" + m.group(1)].append(d.group(1) if d else "?")
    return dests


def reachability(roots, deps, index):
    """reach[t] as an integer BITMASK over target indices, memoised, iterative.

    Bitmasks rather than sets: 2,300-odd targets each reaching up to 2,300 others is millions
    of entries as Python sets, and a few hundred kilobytes as ints.
    """
    reach = {}
    for start in roots:
        if start in reach:
            continue
        stack = [(start, False)]
        while stack:
            node, expanded = stack.pop()
            if node in reach:
                continue
            children = [c for c in deps.get(node, ()) if c not in reach]
            if children and not expanded:
                stack.append((node, True))
                stack.extend((c, False) for c in children)
                continue
            m = 1 << index.setdefault(node, len(index))
            for c in deps.get(node, ()):
                # A cycle would leave a child unresolved; buck2 graphs are DAGs, and treating
                # an unresolved child as empty keeps this total rather than crashing.
                m |= reach.get(c, 0)
            reach[node] = m
    return reach


# Entries allowed to be expensive, because they ARE the goal. dyld is the dynamic loader,
# bash is what the prefix exists to run, darlingserverd is the daemon under test. Removing any
# of them does not produce a smaller prefix, it produces no prefix.
EXEMPT = {
    "root//buck-src/dyld:dyld",
    "root//buck-src:bash",
    "root//linux/server:darlingserverd",
}

# --check fails when a non-exempt entry exclusively pulls in more than this many actions.
# Chosen from the measured distribution rather than picked round: the worst non-exempt entry
# today is secd at 738, and jsc was 1,298, so 800 sits between "what is already here" and
# "another jsc". Lowering it means first deciding what to do about secd.
DEFAULT_BUDGET = 800


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--graph", default=None)
    ap.add_argument("--prefix", default="buck/prefix-min/BUCK")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if a non-exempt entry exceeds the budget")
    ap.add_argument("--budget", type=int, default=DEFAULT_BUDGET)
    args = ap.parse_args()

    graph = args.graph or newest_graph()
    prefix = os.path.join(ROOT, args.prefix)
    if not os.path.exists(prefix):
        sys.exit(f"{prefix} does not exist")

    cost, deps = load_graph(graph)
    dests = entry_labels(prefix)
    print(f"graph:  {graph}")
    print(f"prefix: {args.prefix}: {len(dests)} distinct labels, "
          f"{sum(len(v) for v in dests.values())} entries")

    known = [l for l in dests if l in cost or l in deps]
    if not known:
        sys.exit("no prefix label appears in the graph; wrong graph for this prefix?")

    index = {}
    reach = reachability(known, deps, index)
    rev = {i: t for t, i in index.items()}

    # How many entries reach each target. A target reached by exactly one is exclusive to it.
    hits = collections.Counter()
    for label in known:
        m = reach.get(label, 0)
        while m:
            b = m & -m
            hits[b.bit_length() - 1] += 1
            m ^= b

    rows = []
    for label in known:
        m = reach.get(label, 0)
        excl_cost = excl_n = 0
        total = 0
        while m:
            b = m & -m
            i = b.bit_length() - 1
            t = rev[i]
            total += cost.get(t, 0)
            if hits[i] == 1:
                excl_cost += cost.get(t, 0)
                excl_n += 1
            m ^= b
        rows.append((excl_cost, excl_n, total, label))

    rows.sort(reverse=True)
    total_actions = sum(cost.values())

    if args.check:
        over = [r for r in rows if r[3] not in EXEMPT and r[0] > args.budget]
        print(f"budget: {args.budget} exclusive actions per non-exempt entry")
        for excl_cost, excl_n, total, label in over:
            print(f"  OVER: {label} pulls {excl_cost} actions ({excl_n} targets) that nothing "
                  f"else in this prefix needs")
            print(f"        installs at {dests[label][0]}")
        if over:
            print(f"\nFAIL: {len(over)} entry(ies) over budget. Either the prefix needs them "
                  f"(add to EXEMPT, with the reason) or they are dead weight (add to "
                  f"EXCLUDE_LABELS in scripts/gen-prefix-min.py).")
            sys.exit(1)
        worst = next((r for r in rows if r[3] not in EXEMPT), (0, 0, 0, "none"))
        print(f"PASS: worst non-exempt entry is {worst[3]} at {worst[0]} of {args.budget}")
        return

    print(f"total actions in graph: {total_actions}\n")
    print(f"{'EXCLUSIVE':>10}{'TARGETS':>9}{'TOTAL':>9}  LABEL / where it installs")
    shown = 0
    for excl_cost, excl_n, total, label in rows:
        if excl_cost == 0:
            break
        d = dests[label]
        where = d[0] + (f" (+{len(d)-1} more)" if len(d) > 1 else "")
        print(f"{excl_cost:>10}{excl_n:>9}{total:>9}  {label}\n{'':>28}{where}")
        shown += 1
        if shown >= args.top:
            break
    if not shown:
        print("  no entry has an exclusive cone: every label shares all of its cost")
    nonzero = sum(1 for r in rows if r[0])
    print(f"\n{nonzero} of {len(known)} labels have an exclusive cone; "
          f"the rest share every target they reach, so removing one alone saves nothing.")


if __name__ == "__main__":
    main()
