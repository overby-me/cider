#!/usr/bin/env python3
"""Rank a prefix's install entries by the build cost ONLY THEY pull in.

The minimal prefix is defined by SUBTRACTION: gen-prefix-min.nu takes the full prefix and
removes what is on an exclusion list, so anything expensive is included BY DEFAULT and has to
be noticed one entry at a time. That is how `//buck-src:jsc` survived -- one line,
`libexec/cider/usr/bin/jsc`, that pulled 1,082 compiles of JavaScriptCore into a prefix
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

WHICH GRAPH IS NOT OPTIONAL. This used to pick the "newest" dump out of the store, which was
not a choice at all: Nix pins every store path's mtime to the epoch, so all 27 of them tie and
max() returns whatever the glob yields first. Worse, all four graph attributes (the
single-target demo, -all, -min and -min-skeleton) build a derivation with the SAME NAME, so the
glob cannot tell a 5,709 action demo from a 17,552 action minimal graph. It drew the small one
and printed a ranking that looked perfectly sensible. So: --graph is required, and the coverage
of the prefix's labels is asserted on every run.

Usage:
  scripts/buck-prefix-cost.py --graph <path>           # required; a dir or a graph.json
  scripts/buck-prefix-cost.py                          # lists the candidates and exits
  scripts/buck-prefix-cost.py --graph <path> --prefix buck/prefix/BUCK --top 40
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


# Minimum share of a prefix's labels a graph must resolve before its numbers mean anything.
# MEASURED, not picked round. Against a correct min graph the current prefix resolves 601 of
# 899 labels, 67 percent. The 298 it does not are all ACTION-LESS targets -- plists, bashrc,
# profile, newsyslog.conf -- installed by an export_file rule that never runs a build action,
# so they are legitimately absent from an ACTION graph. The wrong graph that motivated this
# guard resolved 128 of 899, 14 percent. Half sits well clear of both.
MIN_COVERAGE = 0.50


def candidate_graphs():
    """Every built graph dump with its SIZE, largest first.

    ALL FOUR graph attributes -- the single-target demo, -all, -min and -min-skeleton --
    build a derivation NAMED cider-buck2-graph, so nothing in the store path says which
    is which and a glob matches all of them.

    SIZE, not action count, and that is a deliberate downgrade. The first version of this
    counted actions, which meant reading every candidate end to end: 27 dumps, some of them
    1.6 GB, about 8 GB of I/O to print a 12 line list, while a build was running on the same
    box. Size is a stat, it is free, and it separates them just as well in practice:

        ~455 MB   -all           (about 27,600 actions)
        ~294 MB   -min           (17,552)
        smaller   a demo, a skeleton, or a dump from an older target list

    The listing only has to be good enough to choose from. What actually protects the numbers
    is the coverage assertion below, which runs on whichever graph gets picked.
    """
    out = []
    for p in glob.glob("/nix/store/*-cider-buck2-graph/graph.json"):
        try:
            out.append((os.path.getsize(p), p))
        except OSError:
            continue
    out.sort(reverse=True)
    return out


def refuse_to_guess():
    """Print the candidates and exit, rather than picking one.

    This replaces max(paths, key=os.path.getmtime), which was not a selection at all: Nix
    pins every store path's mtime to the epoch, so all 27 dumps tie and max() returns
    whichever the glob happened to yield first. That drew a 5,709 action graph, resolved
    128 of 899 prefix labels, and still printed a ranking that looked entirely reasonable --
    libsyscall on top, sensible percentages, nothing visibly wrong. A measurement whose
    input is chosen at random is worse than no measurement, because it gets quoted.
    """
    print("REFUSING TO GUESS which graph to read.\n")
    print("Every graph attribute emits the same derivation NAME, so the store cannot tell")
    print("them apart, and their mtimes are all the epoch. Pick the one you mean")
    print("(about 455 MB is -all, 294 MB is -min, smaller is a demo or a skeleton):\n")
    for n, p in candidate_graphs()[:12]:
        print(f"  {n / 1e6:>7.0f} MB  {p}")
    sys.exit("\npass --graph <path>, or build the one you want:\n"
             "  nix build .#cider-buck2-graph-min --print-out-paths --no-link   (minimal)\n"
             "  nix build .#cider-buck2-graph-all --print-out-paths --no-link   (full)")


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
# bash is what the prefix exists to run, ciderd is the daemon under test. Removing any
# of them does not produce a smaller prefix, it produces no prefix.
EXEMPT = {
    "root//buck-src/dyld:dyld",
    "root//buck-src:bash",
    "root//linux/server:ciderd",
}

# --check fails when a non-exempt entry exclusively pulls in more than this many actions.
# Taken from the measured distribution, not picked round.
#
# It was 800 while secd was still here, then 150 once the security daemons went. Now 60.
#
# Each drop follows the measured distribution rather than taste, and the distribution has
# stopped moving: the three costliest entries are exactly the three EXEMPT ones (dyld 644,
# bash 182, ciderd 136), which are the goal rather than dead weight, and the worst
# non-exempt is iokitd at 32, then grep 30 and nghttp2 24. 60 keeps about 2x headroom over
# iokitd while catching anything jsc-shaped (1,298) or secd-shaped (738) the moment it appears.
#
# Tightening matters more now than it did, because the SEARCH is over: with the prefix at 853
# entries every remaining large target is shared base (libsyscall 453 pulled by 547 entries,
# icucore 446 by 178, XNU emulation 288 by 546), so nothing sizeable can be removed by dropping
# entries any more. From here this guard is a ratchet against regression, not a search tool.
DEFAULT_BUDGET = 60


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--graph", default=None)
    ap.add_argument("--prefix", default="buck/prefix-min/BUCK")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if a non-exempt entry exceeds the budget")
    ap.add_argument("--budget", type=int, default=DEFAULT_BUDGET)
    ap.add_argument("--expensive", type=int, metavar="N", default=0,
                    help="the N costliest TARGETS in the cone, and which entries pull each")
    args = ap.parse_args()

    if not args.graph:
        refuse_to_guess()
    graph = args.graph
    if os.path.isdir(graph):
        graph = os.path.join(graph, "graph.json")
    if not os.path.exists(graph):
        sys.exit(f"{graph} does not exist")
    prefix = os.path.join(ROOT, args.prefix)
    if not os.path.exists(prefix):
        sys.exit(f"{prefix} does not exist")

    cost, deps = load_graph(graph)
    dests = entry_labels(prefix)
    print(f"graph:  {graph}")
    print(f"prefix: {args.prefix}: {len(dests)} distinct labels, "
          f"{sum(len(v) for v in dests.values())} entries")

    known = [l for l in dests if l in cost or l in deps]
    # THE GUARD THAT WOULD HAVE CAUGHT IT. Refusing to guess stops the tool choosing a wrong
    # graph; this stops it staying quiet about one it was HANDED. Every number below is a cone
    # measured from these labels, so a graph that resolves few of them does not produce a small
    # answer, it produces a confident answer about a different question.
    coverage = len(known) / len(dests) if dests else 0.0
    print(f"resolved: {len(known)} of {len(dests)} labels ({100 * coverage:.0f} percent) "
          f"appear in this graph")
    if coverage < MIN_COVERAGE:
        print()
        for n, p in candidate_graphs()[:12]:
            print(f"  {n / 1e6:>7.0f} MB  {p}")
        sys.exit(f"\nthis graph resolves only {100 * coverage:.0f} percent of the prefix's "
                 f"labels, below the {100 * MIN_COVERAGE:.0f} percent floor.\nIt is the wrong "
                 f"graph for this prefix: a demo, a skeleton, or a dump from another target "
                 f"list.\nPick one of the above with --graph.")
    if not known:
        sys.exit("no prefix label appears in the graph; wrong graph for this prefix?")

    index = {}
    reach = reachability(known, deps, index)
    rev = {i: t for t, i in index.items()}

    if args.expensive:
        # The OTHER question, and the one the exclusive ranking cannot answer: what is
        # expensive, and who is asking for it. AppKit and CoreImage were 752 actions pulled by
        # pbcopy, pbpaste and open, and NONE of the three showed up in the exclusive ranking,
        # because the cost is shared between them so no single entry owns it. Finding that by
        # hand meant writing a reverse BFS; it belongs here instead.
        in_cone = set()
        for label in known:
            m = reach.get(label, 0)
            while m:
                b = m & -m
                in_cone.add(rev[b.bit_length() - 1])
                m ^= b
        pullers = collections.defaultdict(list)
        for label in known:
            m = reach.get(label, 0)
            while m:
                b = m & -m
                pullers[rev[b.bit_length() - 1]].append(label)
                m ^= b
        cone_total = sum(cost.get(t, 0) for t in in_cone)
        print(f"cone: {len(in_cone)} targets, {cone_total} actions\n")
        for t in sorted(in_cone, key=lambda x: -cost.get(x, 0))[:args.expensive]:
            c = cost.get(t, 0)
            if not c:
                break
            who = pullers[t]
            print(f"{c:>6} {100*c/cone_total:>5.1f}%  {t}")
            # Few pullers means it is removable by dropping them; many means it is base.
            if len(who) <= 6:
                for w in sorted(who):
                    print(f"{'':>14}<- {w}")
            else:
                print(f"{'':>14}<- {len(who)} entries (shared base, not removable this way)")
        return

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
                  f"EXCLUDE_LABELS in scripts/gen-prefix-min.nu).")
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
