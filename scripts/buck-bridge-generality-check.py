#!/usr/bin/env python3
"""Could the bridge be lifted into another project as it stands?

GENERALITY IS THE REQUIREMENT for #66, not a nicety: the bridge is worth having for other
projects whatever it saves here, and cider is the first CONSUMER rather than the target. Every
file in the reusable half says so in a comment. A comment is not a check.

THE PROPERTY THAT IS ACTUALLY CHECKABLE is not the wording, it is the REFERENCES. A file can
say "nothing cider-shaped in here" and still import the lowering; comments cannot be tested and
paths can. So this reads every path a reusable file names and requires it to land inside the
reusable set. That is exactly the condition for copying the set into another repo and having it
work.

WHAT IS DELIBERATELY NOT CHECKED: the prose. Naming cider in a comment, to say what the rule is
or to record a measurement taken on it, is what the comments are FOR.

Usage: buck-bridge-generality-check.py [--controls]
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "nix", "lib")

# THE REUSABLE SET, by rule rather than by list, so a new toy joins it automatically and a new
# cider-specific file does not. dyn-* is the bridge and its fixtures; cider-* is the adapter.
REUSABLE_PREFIX = "dyn-"

# A nix path expression: ./x, ../x, or ../../x. Bare <nixpkgs> is a lookup, not a repo path.
_NIX_PATH = re.compile(r"(?<![\w/.])(\.{1,2}/[\w./-]+)")


def reusable_files() -> list:
    return sorted(f for f in os.listdir(LIB)
                  if f.startswith(REUSABLE_PREFIX) and (f.endswith(".nix") or f.endswith(".py")))


def strip_comments(text: str) -> str:
    """Comments blanked, keeping line numbers. The check is about references in CODE: a header
    that shows how to run the file, `nix build -f ./nix/lib/dyn-drv-probe.nix`, names a repo
    path and depends on nothing.

    NAIVE ON PURPOSE, and the direction it errs matters. A hash inside a string is treated as a
    comment, so this can only ever blank MORE than it should, which makes the check more
    permissive rather than less. A missed violation is possible; a false alarm is not.
    """
    out = []
    for line in text.split("\n"):
        i = line.find("#")
        out.append(line if i < 0 else line[:i])
    return "\n".join(out)


def check(files: list, extra_allowed=()) -> list:
    """Every path a reusable file names must resolve inside the reusable set."""
    allowed = set(files) | set(extra_allowed)
    problems = []
    for f in files:
        path = os.path.join(LIB, f)
        text = strip_comments(open(path).read())
        for m in _NIX_PATH.finditer(text):
            ref = m.group(1)
            # Resolve relative to nix/lib, then ask whether it is one of ours.
            target = os.path.normpath(os.path.join(LIB, ref))
            base = os.path.basename(target)
            inside = os.path.dirname(target) == LIB and base in allowed
            if not inside:
                line = text[:m.start()].count("\n") + 1
                problems.append((f, line, ref))
    return problems


def main(argv: list) -> int:
    files = reusable_files()
    print(f"== can the bridge be lifted out? {len(files)} reusable file(s) in nix/lib ==")
    for f in files:
        print(f"    {f}")
    problems = check(files)
    print(f"  references leaving the set: {len(problems)}")
    for f, line, ref in problems[:10]:
        print(f"    {f}:{line} names {ref}")
    rc = 0 if not problems else 1

    if "--controls" in argv:
        # A CHECK THAT CANNOT FAIL IS WORTH NOTHING. The set is discovered by prefix, so the
        # way to prove the walk works is to shrink the allowed set and watch the internal
        # references become violations: the toys DO reference dyn-actions.nix, and if they did
        # not this check would be inspecting files that name no paths at all.
        print("\n== controls: each must FAIL ==")
        fails = 0
        without_bridge = check([f for f in files if f != "dyn-actions.nix"])
        n = len([p for p in without_bridge if p[2].endswith("dyn-actions.nix")])
        print(f"  {'FIRES ' if n else 'SILENT'} dyn-actions.nix removed from the set: "
              f"{n} reference(s) become violations")
        if not n:
            fails += 1
        # And the walk must actually be finding paths at all.
        total = sum(len(_NIX_PATH.findall(strip_comments(open(os.path.join(LIB, f)).read())))
                    for f in files)
        print(f"  {'FIRES ' if total else 'SILENT'} path references found across the set: {total}")
        if not total:
            fails += 1
        if fails:
            print(f"  {fails} control(s) did not fire, so the zero above is not proven")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
