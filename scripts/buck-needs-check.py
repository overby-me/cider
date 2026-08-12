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

IT READS THE ARTIFACT NOW. It used to compute the answer with a python port of needsOf and
compare that; #99 moved the generator to Rust, so what it compares is the needs.json the graph
derivation WROTE, which is a better question anyway: the python port was never what the build
used, and a generator that computes correctly and writes the wrong file passes the function
comparison and fails this one.

TWO OF THE FOUR CONTROLS ARE GONE WITH IT, and saying which matters. The two that remain break
the DATA (reverse fromTargets, empty fromStaged) and prove the comparison can fail. The two that
are gone broke a RULE inside needsOf (drop the one-level-out indirection through a staged farm's
links, ignore the declared input_targets edges), and there is no second implementation left to
break them in. Restoring them means giving cider-graph-specs a debug mode that writes a
deliberately weakened needs.json, which is the same shape the python had; it is not done here.

Usage: buck-needs-check.py <specs-dir> <needs-from-nix.json> [--controls]
  The nix side comes from
    nix eval --json .#cider-buck2-prefix-min --apply \\
      'l: builtins.mapAttrs (n: d: { t = d.passthru.deps; s = d.passthru.stagedNeeds; }) l.drvs'
"""
from __future__ import annotations

import json
import os
import re
import sys


def safe_name(group: str) -> str:
    """specName in the lowering, safe_name in the generator: the key needs.json is written under.
    Copied rather than imported, like the ones in buck-script-check.py, because the generator is
    Rust now. scripts/buck-names-check.py is what proves every copy still agrees."""
    return re.sub(r"[^A-Za-z0-9_.-]", "_", group)


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
    specs_dir = argv[0]
    theirs = json.load(open(argv[1]))
    controls = "--controls" in argv

    # THE FILE THE GENERATOR WROTE. Its extra `trees` key is ignored here rather than dropped:
    # this check is about fromTargets and fromStaged, and a key it does not read cannot make it
    # pass or fail.
    #
    # KEYED BY SAFE NAME, WHILE THE NIX SIDE IS KEYED BY LABEL, and joining them the wrong way
    # round is not a subtle failure: the first version of this compared the two dicts directly
    # and reported 1,474 labels absent from each side, which is what a total key mismatch looks
    # like. The join goes label -> safe_name because safe_name is not invertible.
    raw = json.load(open(os.path.join(specs_dir, "needs.json")))
    mine = {}
    for label in theirs:
        v = raw.get(safe_name(label))
        if v is not None:
            mine[label] = {"t": v.get("t", []), "s": v.get("s", [])}
    print(f"== needs: the generator's needs.json against the lowering, {len(theirs)} labels "
          f"from nix ==")
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
        # THE TWO RULE-LEVEL CONTROLS ARE NOT HERE, and the docstring says why: breaking a rule
        # inside needsOf needs a second implementation, and since #99 there is only the Rust
        # one. What follows breaks the DATA instead, which still answers the question the
        # controls exist for: can this comparison fail at all?
        #
        # The rules they covered, for whoever restores them through a tool debug mode: the
        # one-level-out indirection through a staged farm's own links, and the DECLARED
        # input_targets edges that no argv mentions, which is the omission that cost an
        # hour-deep coarse build.
        #
        # A THIRD ONE WAS ALREADY INFORMATIONAL and is worth keeping as a measurement rather
        # than as code: reducing ownerOf to exact matching did NOT fire on this graph. The
        # prefix walk does run, 120 of 12,135 distinct input paths resolve to a strict prefix,
        # all of them a .c inside a mig codegen directory, but it changes no ANSWER because the
        # group owning that directory is already reached by another input of the same group.
        # Dropping BOTH that rule and the declared edges loses exactly what dropping the
        # declared edges alone loses, 597 labels either way.
        #
        # Order, since the comparison above claims to be order sensitive.
        fails += control("fromTargets reversed",
                         {l: {"t": list(reversed(v["t"])), "s": v["s"]}
                          for l, v in mine.items()})
        # The staged half on its own: without this, fromTargets agreeing would carry the verdict.
        fails += control("fromStaged emptied",
                         {l: {"t": v["t"], "s": []} for l, v in mine.items()})
        if fails:
            print(f"  {fails} of the 2 binding control(s) did not fire, so the agreement "
                  "above is not proven")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
