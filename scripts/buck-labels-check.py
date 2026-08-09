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

TWO RULES, because a general target-existence check is not available cheaply:

  1  the PACKAGE directory must exist. Unambiguous, and it caught the 205.
  2  a label into a FIRST-PARTY package must not name a target containing
     darling. First-party code is Cider now; only pins keep the old name. This
     is narrow on purpose and has no false positives.

Rule 2 exists because rule 1 does not catch a package that still exists under a
target that was renamed inside it, which is how this failed twice:

    Unknown target `darling_config` from package `root//src/include`
    Unknown target `libsimple_darling` from package `root//src/libsimple`

Full target existence was measured and rejected: after expanding the two macro
shapes that can be resolved statically (the fw_* header roots from
FRAMEWORKS.items() and the per-pin export_file loops from EXPORTS.items()), 105
distinct targets remain unresolvable, all real. They come from elf_wrapper,
which synthesises <name>_wrap and <name>_dylib from a list local to the BUCK
file. Reporting those 105 as failures would make the check useless, so it does
not claim to check what it cannot see.

Verified both ways. Against the tree as the rename left it: 205 occurrences of
//src/external/darlingserver, 10 of //src/include:darling_config and 5 of
//src/libsimple:libsimple_darling. Clean now, except two labels ignored by name
below.

Exit 0 if every label resolves, 1 otherwise.
"""
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LABEL = re.compile(r'"//([A-Za-z0-9_./+-]*):([A-Za-z0-9_.+-]+)"')

# read_root_config(SECTION, key, default) reads .buckconfig.local, which both
# nix/lib/ciderBuck2Graph.nix and scripts/buck-setup.nu write under [cider].
# A section that does not match returns the DEFAULT, silently: the one
# read_root_config("darling", "elf_lib_dirs", "") left in buck-src/BUCK gave
# wrapgen an empty search path and it failed with
#   Cannot load libfuse.so: cannot open shared object file
# four minutes into the endpoint. No label and no path is involved, so nothing
# else here would have seen it.
CONFIG = re.compile(r'read_root_config\(\s*"([a-z_]+)"')
CONFIG_SECTION = "cider"

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
                key = f"no such package  //{pkg}:{name}"
            elif not pkg.startswith("buck-src") and "darling" in name:
                key = f"first-party target still named darling  //{pkg}:{name}"
            else:
                continue
            counts[key] += 1
            where[key].add(rel)

        for section in CONFIG.findall(text):
            checked += 1
            if section != CONFIG_SECTION:
                key = f"config section is not [{CONFIG_SECTION}]  read_root_config(\"{section}\")"
                counts[key] += 1
                where[key].add(rel)

    print(f"labels and config reads checked: {checked}")
    if not counts:
        print("PASS: every label names a package that exists, no first-party target is "
              "still named darling, and every config read is [cider]")
        return 0

    print(f"\n{sum(counts.values())} labels do not resolve:")
    for key, n in counts.most_common():
        files = sorted(where[key])
        print(f"  {n:5d}  {key}   in {len(files)} file(s): {', '.join(files[:3])}")
    print("\nFAIL: a label names something that is not there.")
    print("If a first-party package or target was renamed, buck-src/BUCK and")
    print("buck-src/<pin>/BUCK reference it too; those are generated files of ours,")
    print("not upstream code, and the Cider sweep skipped the whole buck-src tree.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
