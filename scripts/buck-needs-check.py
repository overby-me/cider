#!/usr/bin/env python3
"""Does the python port of needsOf give the SAME answer as the lowering it is replacing?

#66 is moving the builder script out of the evaluator and into the generator. The script is
assembled from `needs`: what a group copies from OTHER GROUPS (fromTargets) and what it restores
from STAGED DATA (fromStaged). So needsOf has to be ported, and a port of it is worth exactly as
much as the evidence that it agrees.

THE COMPARISON IS PER LABEL AND EXACT, not a total. needsOf is 3.3 s of a 12 s evaluation and
touches 389,452 input paths; a summary that says "22,473 edges both sides" would be satisfied by
two functions disagreeing about which group each edge belongs to.

ORDER IS COMPARED SEPARATELY FROM MEMBERSHIP, and it matters here rather than being tidiness:
the dep copies are `cp -a <dep>/. .` in list order, so two groups sharing a path let the LAST
one win. A set-equal, order-different answer is a real difference and is reported as one.

Usage: buck-needs-check.py <graph.json> <needs-from-nix.json> [--controls]
  The nix side comes from
    nix eval --json .#cider-buck2-prefix-min --apply \\
      'l: builtins.mapAttrs (n: d: { t = d.passthru.deps; s = d.passthru.stagedNeeds; }) l.drvs'
"""
from __future__ import annotations

import json
import sys


def target_of(identity: str) -> str:
    """The label out of a buck2 action identity. Mirrors targetOf in the lowering."""
    i = identity.find(" (")
    return identity[:i] if i > 0 else identity


def group_of_label(label: str, coarse_pin_of: dict) -> str:
    pin = coarse_pin_of.get(label)
    return label if pin is None else "root//buck-src:pin-" + pin


def uniq(xs):
    """Order preserving, which is what lib.unique is. Never sorted: see the header."""
    seen, out = set(), []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


class Needs:
    """The lowering's needsOf, in python. Field for field, so it can be diffed by eye."""

    def __init__(self, graph: dict, coarse_pins: bool = True):
        self.coarse_pin_of = graph.get("coarsePinOf", {}) if coarse_pins else {}
        self.staged = graph.get("staged", {})
        self.staged_trees = graph.get("stagedTrees", {})
        self.staged_tree_deps = graph.get("stagedTreeDeps", {})

        # targets = lib.groupBy groupOf g.actions
        self.targets: dict = {}
        for a in graph["actions"]:
            self.targets.setdefault(
                group_of_label(target_of(a["identity"]), self.coarse_pin_of), []).append(a)

        # producerTarget: which GROUP writes which artifact.
        self.producer: dict = {}
        for a in graph["actions"]:
            g = group_of_label(target_of(a["identity"]), self.coarse_pin_of)
            for o in a["outputs"]:
                self.producer[o] = g

        # known = producerTarget // staged // stagedTrees, membership only.
        self.known = set(self.producer) | set(self.staged) | set(self.staged_trees)

        # ATTRIBUTE NAMES COME OUT OF NIX SORTED, so the two halves are sorted separately and
        # then concatenated, exactly as `attrNames a ++ attrNames b` does. Feeding python dict
        # order here would produce the right SET with the wrong order, which is the failure
        # this file goes out of its way to be able to see.
        self.staged_names = sorted(self.staged) + sorted(self.staged_trees)
        self.staged_by_target: dict = {}
        for o in self.staged_names:
            self.staged_by_target.setdefault(self.producer.get(o, ""), []).append(o)

        self._owner_cache: dict = {}

    def owner_of(self, path: str, exact: bool = False):
        """The LONGEST known prefix of a path, or None. An input can be a file INSIDE a
        directory output, so exact matching is not enough: that is the difference between this
        and the cheaper producer lookup group_deps does."""
        if exact:
            return path if path in self.known else None
        hit = self._owner_cache.get(path)
        if hit is not None or path in self._owner_cache:
            return hit
        segs = path.split("/")
        got = None
        for n in range(len(segs), 0, -1):
            p = "/".join(segs[:n])
            if p in self.known:
                got = p
                break
        self._owner_cache[path] = got
        return got

    def of(self, label: str, break_rule: str = "") -> dict:
        """`break_rule` disables exactly ONE rule, for the controls. Breaking a rule here rather
        than mangling the result afterwards is the difference between a control that proves the
        rule is exercised by this graph and one that only proves the comparison can subtract."""
        acts = self.targets.get(label, [])
        ins = uniq(i for a in acts for i in a["inputs"])
        ex = break_rule == "exact"
        direct = uniq(o for o in (self.owner_of(i, ex) for i in ins) if o is not None)
        via = ([] if break_rule == "vialinks" else
               uniq(self.owner_of(t, ex)
                    for o in direct for t in self.staged_tree_deps.get(o, [])))
        owners = uniq(direct + [x for x in via if x is not None])

        declared = ([] if break_rule == "declared" else
                    uniq(group_of_label(t, self.coarse_pin_of)
                         for a in acts for t in a.get("input_targets", [])))
        declared_with_actions = [t for t in declared if t in self.targets]
        declared_staged = [o for t in declared for o in self.staged_by_target.get(t, [])]

        from_targets = uniq(
            t for t in ([self.producer.get(o) for o in owners] + declared_with_actions)
            if t is not None and t != label)
        from_staged = uniq(
            [o for o in owners if o in self.staged or o in self.staged_trees]
            + declared_staged)
        return {"t": from_targets, "s": from_staged}


def compare(mine: dict, theirs: dict) -> dict:
    """Per label, split into three outcomes rather than one pass/fail: identical, same members
    in a different ORDER, and genuinely different members. They have different causes."""
    res = {"same": 0, "order": [], "diff": [], "missing": [], "extra": []}
    for label in theirs:
        if label not in mine:
            res["missing"].append(label)
            continue
        a, b = mine[label], theirs[label]
        if a["t"] == b["t"] and a["s"] == b["s"]:
            res["same"] += 1
        elif set(a["t"]) == set(b["t"]) and set(a["s"]) == set(b["s"]):
            res["order"].append(label)
        else:
            res["diff"].append(label)
    res["extra"] = [l for l in mine if l not in theirs]
    return res


def report(res: dict, mine: dict, theirs: dict, total: int) -> int:
    print(f"  identical          {res['same']} / {total}")
    print(f"  same set, reordered {len(res['order'])}")
    print(f"  different          {len(res['diff'])}")
    print(f"  absent from python {len(res['missing'])}")
    print(f"  absent from nix    {len(res['extra'])}")
    for label in res["diff"][:5]:
        a, b = mine[label], theirs[label]
        print(f"\n  {label}")
        for k, what in (("t", "fromTargets"), ("s", "fromStaged")):
            only_py = [x for x in a[k] if x not in set(b[k])]
            only_nix = [x for x in b[k] if x not in set(a[k])]
            if only_py or only_nix:
                print(f"    {what}: python has {len(a[k])}, nix has {len(b[k])}")
                if only_py:
                    print(f"      python only: {only_py[:4]}")
                if only_nix:
                    print(f"      nix only:    {only_nix[:4]}")
    bad = len(res["diff"]) + len(res["order"]) + len(res["missing"]) + len(res["extra"])
    return 0 if bad == 0 else 1


def main(argv: list) -> int:
    if len(argv) < 2:
        sys.exit(__doc__)
    graph = json.load(open(argv[0]))
    theirs = json.load(open(argv[1]))
    controls = "--controls" in argv

    n = Needs(graph)
    mine = {label: n.of(label) for label in n.targets}
    print(f"== needsOf: python against the lowering, {len(theirs)} labels from nix ==")
    rc = report(compare(mine, theirs), mine, theirs, len(theirs))

    # CONTROLS, because a comparison of two things that agree proves nothing about whether the
    # comparison could ever have DISAGREED. Each breaks one specific part of the port and the
    # check must fail; if any of these still passes, the corresponding rule is not being
    # exercised by this graph and the agreement above is weaker than it looks.
    if controls:
        print("\n== controls: each must FAIL ==")

        def control(name, broken):
            r = compare(broken, theirs)
            bad = len(r["diff"]) + len(r["order"]) + len(r["missing"]) + len(r["extra"])
            print(f"  {'FIRES ' if bad else 'SILENT'} {name}: {bad} label(s) differ")
            return 0 if bad else 1

        fails = 0
        # The one-level-out indirection through a staged farm's own links. This is the rule the
        # cheaper exact-match version of the edge set does not have.
        fails += control("viaLinks dropped",
                         {l: n.of(l, "vialinks") for l in n.targets})
        # input_targets: the DECLARED edges, which no argv mentions. Leaving these out is the
        # mistake that cost an hour-deep coarse build.
        fails += control("input_targets ignored",
                         {l: n.of(l, "declared") for l in n.targets})
        # ownerOf reduced to exact matching, so an input INSIDE a directory output resolves to
        # nothing.
        #
        # THIS ONE DOES NOT FIRE, and that is a measured fact about this graph rather than a
        # gap in the check, so it is reported and not counted. The prefix walk DOES run: 120 of
        # 12,135 distinct input paths resolve to a strict prefix, all of them a .c inside a mig
        # codegen directory. It changes no ANSWER because the group owning that directory is
        # already reached by another input of the same group. Checked rather than assumed: the
        # obvious explanation was that input_targets covers the same edges, and dropping BOTH
        # rules loses exactly what dropping the declared edges alone loses, 597 labels either
        # way, so the walk is worth 0 edges even with the declared edges gone.
        #
        # KEPT ANYWAY. The port has to match the lowering on graphs other than this one, and a
        # rule that is redundant today is not the same as a rule that is wrong.
        control("ownerOf exact only (informational, see the comment)",
                {l: n.of(l, "exact") for l in n.targets})
        # Order, since the comparison above claims to be order sensitive.
        fails += control("fromTargets reversed",
                         {l: {"t": list(reversed(v["t"])), "s": v["s"]}
                          for l, v in mine.items()})
        # The staged half on its own: without this, fromTargets agreeing would carry the verdict.
        fails += control("fromStaged emptied",
                         {l: {"t": v["t"], "s": []} for l, v in mine.items()})
        if fails:
            print(f"  {fails} of the 4 binding control(s) did not fire, so the agreement "
                  "above is not proven")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
