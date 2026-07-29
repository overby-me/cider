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

# Which .bzl provides which rule.
RULES = {
    "//buck/rules:cc.bzl": [
        "cc_header_root", "cc_objects", "cc_static_lib", "cc_library",
        "cc_binary", "cc_lib_dir",
    ],
    "//buck/rules:codegen.bzl": [
        "bison_gen", "flex_gen", "mig_gen", "host_gen", "script_gen",
    ],
    "//buck/rules:darwin.bzl": ["darwin_dylib", "darwin_binary"],
    "//buck/rules:files.bzl": ["export_file"],
}

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
