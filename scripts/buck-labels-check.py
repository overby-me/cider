#!/usr/bin/env python3
"""Every buck2 label we write must name a package directory that exists.

Companion to buck-pin-paths-check.py. That one resolves the PATHS we record
into upstream pins; this one resolves the LABELS we write between packages.
Both are the same failure mode from opposite ends: a plain string naming
something that is not there, which nothing checks until buck2 is asked to build
it, an hour into a run.

WHAT IT CATCHES, and the reason it exists. buck-src/BUCK and buck-src/<pin>/BUCK
are OURS, generated from the reference build, even though they sit next to
upstream code. The Cider rename skipped the whole buck-src tree, correctly for
the pin paths inside it and WRONGLY for its 170 references back to first-party
packages. They kept naming //src/external/darlingserver after that package
became //src/external/ciderd. buck2 reported the first one only, as an analysis
error four minutes into the endpoint:

    Unknown target `darling_config` from package `root//src/include`
    Available targets: root//src/include:cider_config

One failure per run, and the next one only after another four minutes. This
reports all of them at once.

Package existence is the check, not target existence: targets are frequently
produced by macros and list comprehensions (the fw_* frameworks, the per-pin
export_file loops), so a name = "..." scan cannot see them and would report
hundreds of targets that are real. A missing DIRECTORY is unambiguous.

Verified both ways. Against the tree as the rename left it: 205 occurrences of
//src/external/darlingserver across buck-src/BUCK and buck-src/xnu/BUCK, plus
its symlink under buck-src/IOKitUser. Clean now, except two labels ignored by
name below.

Exit 0 if every label resolves, 1 otherwise.
"""
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LABEL = re.compile(r'"//([A-Za-z0-9_./+-]*):([A-Za-z0-9_.+-]+)"')

# Upstream Bazel files vendored inside a pin, using Bazel labels that are not
# ours to resolve. Matched as a path prefix, not by label text.
IGNORE_PREFIXES = ("buck-src/libcxx/utils/google-benchmark/",)


def buck_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".jj", ".git", "buck-out")]
        for name in filenames:
            if name == "BUCK" or name.endswith(".bzl"):
                rel = os.path.relpath(os.path.join(dirpath, name), ROOT)
                if rel.startswith(IGNORE_PREFIXES):
                    continue
                yield rel


def main():
    os.chdir(ROOT)
    counts = collections.Counter()
    where = collections.defaultdict(set)
    checked = 0
    for rel in buck_files():
        with open(rel, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for pkg, name in LABEL.findall(text):
            checked += 1
            if not os.path.isdir(pkg):
                counts[f"//{pkg}"] += 1
                where[f"//{pkg}"].add(rel)

    print(f"labels checked: {checked}")
    if not counts:
        print(f"PASS: every label names a package that exists")
        return 0

    print(f"\n{sum(counts.values())} labels name a package DIRECTORY that does not exist:")
    for pkg, n in counts.most_common():
        files = sorted(where[pkg])
        print(f"  {n:5d}  {pkg}   in {len(files)} file(s): {', '.join(files[:3])}")
    print("\nFAIL: a label names a package that is not there.")
    print("If a first-party package was renamed, buck-src/BUCK and buck-src/<pin>/BUCK")
    print("reference it too; they are generated files of ours, not upstream code.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
