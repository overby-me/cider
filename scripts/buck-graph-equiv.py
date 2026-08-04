#!/usr/bin/env python3
"""Are two dumped graphs the SAME GRAPH, ignoring how they are encoded?

Written for #56, where the graph stopped being dumped from the project and started being
dumped from a skeleton (build files verbatim, every other file present but empty). The claim
that made that safe is that buck2 analysis cannot read a source file, and a claim like that
is worth exactly as much as the check behind it. So this compares the two dumps by MEANING:
every action with its argv, env, inputs and outputs; every staged artifact by content hash;
and every staged farm by its reconstructed links.

Reconstructed, because the tables have two encodings since #58: names only when the target
is derivable from the name, and two columns when it is not. Comparing the files byte for
byte would report a difference that is purely how it is written down, which is the kind of
false positive that trains you to ignore a check.

Keys the dump no longer writes are simply absent from both sides and are reported as such
rather than silently skipped, since "the key vanished" is a real answer.

Usage:
  buck-graph-equiv.py <old-graph> <old-data> <new-graph> <new-data>

Exit 0 when the graphs agree, 1 when they do not, 2 on infrastructure trouble.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys


def load(graph: str) -> dict:
    path = os.path.join(graph, "graph.json")
    if not os.path.exists(path):
        print(f"no graph.json in {graph}", file=sys.stderr)
        raise SystemExit(2)
    with open(path) as fh:
        return json.load(fh)


def links_of(g: dict, data: str) -> dict:
    """{farm: {name: target}}, from either table encoding."""
    out = {}
    for path, meta in g.get("stagedTrees", {}).items():
        links = {}
        if meta.get("n"):
            table = os.path.join(data, meta["table"])
            if not os.path.exists(table):
                print(f"missing table {table}", file=sys.stderr)
                raise SystemExit(2)
            with open(table) as fh:
                if "k" in meta:
                    k, pre = meta["k"], meta["prefix"]
                    for line in fh:
                        rel = line.rstrip("\n")
                        links[rel] = "../" * (k + rel.count("/")) + pre + rel
                else:
                    for line in fh:
                        name, _, target = line.rstrip("\n").partition("\t")
                        links[name] = target
        out[path] = links
    return out


def staged_hashes(data: str) -> dict:
    out = {}
    root = os.path.join(data, "staged")
    for dp, _dn, fs in os.walk(root):
        for f in fs:
            p = os.path.join(dp, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = hashlib.sha256(fh.read()).hexdigest()
    return out


def report(name: str, a, b) -> bool:
    """True when they differ. Prints a few concrete examples, never a wall of diff."""
    if a == b:
        print(f"  {name}: identical")
        return False
    if isinstance(a, dict) and isinstance(b, dict):
        only_a = sorted(set(a) - set(b))
        only_b = sorted(set(b) - set(a))
        changed = sorted(k for k in set(a) & set(b) if a[k] != b[k])
        print(f"  {name}: DIFFERS -- {len(only_a)} only in old, {len(only_b)} only in new, "
              f"{len(changed)} changed")
        for k in only_a[:3]:
            print(f"    - {k}")
        for k in only_b[:3]:
            print(f"    + {k}")
        for k in changed[:3]:
            print(f"    ~ {k}")
            print(f"        old: {str(a[k])[:160]}")
            print(f"        new: {str(b[k])[:160]}")
        return True
    print(f"  {name}: DIFFERS -- {str(a)[:200]} vs {str(b)[:200]}")
    return True


def main(argv: list) -> int:
    if len(argv) != 5:
        print("usage: buck-graph-equiv.py <old-graph> <old-data> <new-graph> <new-data>",
              file=sys.stderr)
        return 2
    og, od, ng, nd = argv[1], argv[2], argv[3], argv[4]
    a, b = load(og), load(ng)

    bad = False
    print("graph equivalence:")

    # Actions, keyed by identity so a reordering is not a difference. The identity is unique
    # per action by construction (it is what the dump derives its action ids from).
    def by_identity(g):
        out = {}
        for act in g["actions"]:
            out[act["identity"]] = {
                "argv": act["argv"],
                "env": act["env"],
                "inputs": sorted(act.get("inputs", [])),
                "outputs": sorted(act.get("outputs", [])),
            }
        return out

    bad |= report("actions", by_identity(a), by_identity(b))

    for key in ("kinds", "producers", "targetOutputs", "staged", "stagedTreeDeps",
                "coarsePinOf", "placeholders", "targets"):
        pa, pb = a.get(key, "<absent>"), b.get(key, "<absent>")
        if pa == "<absent>" and pb == "<absent>":
            print(f"  {key}: absent from both")
            continue
        bad |= report(key, pa, pb)

    bad |= report("staged farm links", links_of(a, od), links_of(b, nd))
    bad |= report("staged artifact contents", staged_hashes(od), staged_hashes(nd))

    print("VERDICT:", "DIFFERENT" if bad else "the same graph")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
