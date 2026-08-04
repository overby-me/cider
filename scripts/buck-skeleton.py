#!/usr/bin/env python3
"""Reduce the project to what buck2 ANALYSIS actually reads: the build definition, and the
NAMES of everything else.

Why this exists. The graph derivation took the whole project, so editing one .c file reran
it, 30 to 47 minutes, before a single compile could start. Under content addressing that is
not a cascade, the lowered derivations do not all rebuild afterwards, but it is a fixed tax
on every edit and it is the reason iteration on this port is slow.

It is unnecessary, because buck2 analysis CANNOT read source file contents. Analysis is a
pure function of the target graph and the configuration; source files are artifacts that
exist only at execution. Measured on the real dump to confirm it rather than assume it: the
data output is 6.9 MB of staged/ that is 166 rule generated scripts and value files
(rustc.sh, forward.py, configure.py, values.json), plus treelinks/ which is link names. Not
one byte of source content reaches either.

So the graph is a pure function of BUCK files, bzl rules, toolchains, configs and source
NAMES. This writes exactly that: build definition files verbatim, every other file present
but EMPTY so glob() still sees the same names, and every directory and symlink preserved
because buck2 resolves package boundaries through them.

The output is content addressed by its consumer, so editing a .c leaves this output byte
identical and the graph derivation does not rerun at all. Editing a BUCK file changes it and
the graph correctly rebuilds.

The one thing that DOES need real contents is the include closure, which parses
#include "..." out of real bytes. That is not analysis and it does not belong here; it runs
as its own pass over the real tree.

Usage:
  buck-skeleton.py <src> <out>
"""
from __future__ import annotations

import os
import sys

# Read by buck2 while loading and analysing, so their CONTENTS matter.
#
# Names first, then the whole of buck/, which holds this port's rules, toolchains and
# prelude glue. A rule file that arrived empty would not fail loudly, it would analyse to a
# DIFFERENT graph, so this list errs towards copying.
_BUILD_NAMES = frozenset([
    "BUCK", "BUCK.v2", "PACKAGE", "PACKAGE.v2",
    ".buckconfig", ".buckconfig.local", ".buckroot", ".buckignore",
])
_BUILD_SUFFIXES = (".bzl", ".bxl")
_BUILD_TREES = ("buck/",)


def is_build_file(rel: str) -> bool:
    base = os.path.basename(rel)
    return (
        base in _BUILD_NAMES
        or rel.endswith(_BUILD_SUFFIXES)
        or rel.startswith(_BUILD_TREES)
        # .buckconfig.d/ and friends: a config fragment is read the same as .buckconfig.
        or "/.buckconfig" in rel
        or rel.startswith(".buckconfig")
    )


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    src, out = os.path.abspath(argv[1]), os.path.abspath(argv[2])

    copied = emptied = links = dirs = 0
    for root, dirnames, filenames in os.walk(src, followlinks=False):
        rel_root = os.path.relpath(root, src)
        rel_root = "" if rel_root == "." else rel_root
        os.makedirs(os.path.join(out, rel_root), exist_ok=True)
        dirs += 1

        # Never walked, at any depth. The Nix filter feeding this already drops them, but
        # this script is also run by hand against a working tree, where .git alone is
        # bigger than everything it would have to skeletonise.
        if not rel_root:
            for d in (".git", ".jj", ".direnv", "buck-out"):
                if d in dirnames:
                    dirnames.remove(d)

        # A symlinked DIRECTORY is recreated as a symlink and not descended into, so the
        # skeleton keeps the same shape rather than expanding a farm into real directories.
        for d in list(dirnames):
            p = os.path.join(root, d)
            if os.path.islink(p):
                dirnames.remove(d)
                os.symlink(os.readlink(p), os.path.join(out, rel_root, d))
                links += 1

        for f in filenames:
            p = os.path.join(root, f)
            rel = os.path.join(rel_root, f) if rel_root else f
            dst = os.path.join(out, rel)
            if os.path.islink(p):
                # By its TARGET STRING, which is exactly how Nix hashes a symlink, so a
                # dangling one is preserved rather than resolved or dropped.
                os.symlink(os.readlink(p), dst)
                links += 1
            elif is_build_file(rel):
                with open(p, "rb") as fh_in, open(dst, "wb") as fh_out:
                    fh_out.write(fh_in.read())
                copied += 1
            else:
                # The NAME is the whole content that analysis needs.
                open(dst, "wb").close()
                emptied += 1

    print(f"skeleton: {copied} build files copied, {emptied} emptied, "
          f"{links} symlinks, {dirs} directories", file=sys.stderr)
    if copied == 0:
        raise SystemExit("skeleton: not one build file was copied, the filter is wrong")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
