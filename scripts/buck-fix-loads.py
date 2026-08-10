#!/usr/bin/env python3
"""Make every BUCK file load exactly the rules it uses.

Generated targets get appended to whatever BUCK file owns their sources
(scripts/gen-buck-from-ninja.py --write), and that file's `load` statements
rarely already name the rules the new block needs. Rather than teaching every
generator to merge load lines, this fixes them all after the fact.

Usage: scripts/buck-fix-loads.py [--check]
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Which .bzl provides which rule -- READ FROM THE RULE FILES, not listed here.
#
# This script STRIPS every //buck/rules: load and re-adds only the rules it knows about,
# so a rule missing from the map has its load silently deleted from any file the script
# touches. A hand-kept list guarantees that happens every time a rule is added: it took
# out buck/prefix/BUCK's prefix_tree load, and then darwin/tools' stdout_gen. Deriving the
# map from `<name> = rule(` in buck/rules/*.bzl cannot drift.
def _rules_map() -> dict:
    out = {}
    d = os.path.join(REPO, "buck", "rules")
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".bzl"):
            continue
        text = open(os.path.join(d, fn)).read()
        names = sorted(set(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*rule\(", text, re.M)))
        if names:
            out[f"//buck/rules:{fn}"] = names
    if not out:
        sys.exit("no rules found under buck/rules -- refusing to strip every load")
    return out


RULES = _rules_map()

SKIP_DIRS = ("buck-out", ".git", ".jj", ".direnv", "build")


def buck_files():
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if "BUCK" in filenames:
            yield os.path.join(dirpath, "BUCK")


def fix(path: str, check: bool) -> bool:
    with open(path) as f:
        text = f.read()
    # Strip ONLY the rule loads this script manages. A BUCK file may load other
    # things -- buck-src/BUCK loads the generated SDK header maps -- and dropping
    # those breaks it.
    body = re.sub(r'^load\("//buck/rules:[^)]*\)\n', "", text, flags=re.M)

    wanted: dict[str, list[str]] = {}
    for bzl, rules in RULES.items():
        used = sorted(r for r in rules if re.search(r"\b" + r + r"\s*\(", body))
        if used:
            wanted[bzl] = used

    loads = "".join(
        f'load("{bzl}", ' + ", ".join(f'"{r}"' for r in rules) + ")\n"
        for bzl, rules in sorted(wanted.items())
    )
    new = loads + ("\n" if loads else "") + body.lstrip("\n")
    if new == text:
        return False
    if not check:
        with open(path, "w") as f:
            f.write(new)
    return True


def main(argv: list[str]) -> int:
    check = "--check" in argv
    changed = [p for p in sorted(buck_files()) if fix(p, check)]
    for p in changed:
        print(("would fix " if check else "fixed ") + os.path.relpath(p, REPO))
    if check and changed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
