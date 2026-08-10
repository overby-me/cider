#!/usr/bin/env python3
"""Reduce the project to what the graph derivation actually reads.

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

Analysis alone would let EVERY file be emptied, since analysis cannot read a source at all.
It is not analysis alone: the derivation also materialises the in-process artifacts, and a
staged farm of GENERATED headers is only materialised by running its generator, which does
read real bytes. So the C family is emptied and everything else is copied whole -- see
_EMPTIABLE below for what that cost when it was learned the hard way.

The output is content addressed by its consumer, so editing a .c or a .h leaves it byte
identical and the graph derivation does not rerun at all. Editing a BUCK file, a .defs, a
grammar or a generator script changes it, and the graph correctly rebuilds.

The one thing that DOES need real contents is the include closure, which parses
#include "..." out of real bytes. That is not analysis and it does not belong here; it runs
as its own pass over the real tree.

THE GENERATOR INPUTS ARE NOW COVERED, which is what the skeleton was missing when it was
reverted. Emptying the C family outside src/external still emptied five files that are
compiled into generators this derivation RUNS, and an emptied generator does not fail, it
writes an empty output. scripts/buck-codegen-closure.py computes the set that must keep real
contents, 1,743 files of 74,621, and all but five are already covered by _NEVER_EMPTY. Those
five are listed below and can be replaced with a freshly computed list via --keep.

Usage:
  buck-skeleton.py <src> <out> [--keep <file of paths to never empty>]
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


# WHAT MAY BE EMPTIED, and it is a much smaller set than "everything that is not a build
# file". Emptying the whole tree looked right -- analysis reads no source -- but the graph
# derivation also MATERIALISES the in-process artifacts, and a staged farm of GENERATED
# headers can only be materialised by running the generator. Measured: with everything
# emptied, buck2 fails on root//src/external/ciderd:dserver_rpc, root//buck-src:
# mig_parser and root//buck-src:shell_cmds_find_getdate, which are the rpc wrapper script,
# a mig .defs and a yacc grammar.
#
# So only the C family is emptied. That is the bulk of the tree and it is what people edit,
# it is only ever COMPILED, and compiles no longer run here at all since buck/bxl/
# materialize.bxl stopped ensuring default outputs. Everything a generator might read --
# .defs, grammars, scripts, data -- keeps its real contents, so editing one correctly
# rebuilds the graph.
_EMPTIABLE = (
    ".c", ".cc", ".cpp", ".cxx", ".m", ".mm",
    ".h", ".hpp", ".hh", ".inc",
    ".s", ".S", ".asm",
)


# NEVER emptied, whatever the suffix. In the graph derivation these do not come from here
# at all: the pins are materialised from ciderSrc, the crates from the vendor derivation,
# and src/external is where the pins are planted. Emptying them in a hand run makes the run
# unrepresentative of the build, which is exactly how a test came back failing on
# buck-src:mig_parser for a reason that cannot happen in Nix.
_NEVER_EMPTY = ("buck-src/", "buck-rust/", "src/external/")


# THE FIVE FILES THE PREFIX LIST ABOVE DOES NOT COVER, and the reason the skeleton was
# reverted rather than fixed. These are C family and outside src/external, so they were
# emptied, and every one of them is compiled into a GENERATOR that this derivation then RUNS.
# An emptied rtsig.c does not fail: it compiles, links, runs, and writes an EMPTY header, so
# the graph comes out quietly wrong and the failure lands somewhere else entirely.
#
# NOT A GUESS AND NOT A HAND LIST. scripts/buck-codegen-closure.py computes which files must
# keep real contents, from the staged farms rather than from argv reachability, and says 1,743
# of 74,621. Intersecting that with may_empty leaves exactly these five: the other 1,738 are
# already covered by _NEVER_EMPTY.
#
# REGENERATE THIS, DO NOT EDIT IT BY HAND. Adding a codegen edge whose sources are not here
# reintroduces the silent failure above. Recompute with
#   scripts/buck-codegen-closure.py <graph.json> <graph-data> --sources <target-sources.json>
# and prefer --keep below, which takes a freshly computed list, over this baked default.
_NEVER_EMPTY_FILES = frozenset([
    "linux/libelfloader/wrapgen/wrapgen.cpp",
    "darwin/libsimple/include/libsimple/base.h",
    "darwin/libsimple/include/libsimple/lock.h",
    "darwin/libsimple/src/lock.c",
    "linux/startup/rtsig.c",
])

# Replaced wholesale by --keep when one is given.
_keep_files = _NEVER_EMPTY_FILES


def may_empty(rel: str) -> bool:
    return (
        rel.endswith(_EMPTIABLE)
        and not rel.startswith(_NEVER_EMPTY)
        and rel not in _keep_files
    )


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
    global _keep_files
    args = list(argv[1:])
    keep_path = ""
    if "--keep" in args:
        i = args.index("--keep")
        if i + 1 >= len(args):
            print("--keep needs a file of project-relative paths", file=sys.stderr)
            return 2
        keep_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    src, out = os.path.abspath(args[0]), os.path.abspath(args[1])

    if keep_path:
        with open(keep_path) as fh:
            fresh = {
                ln.strip() for ln in fh
                if ln.strip() and not ln.lstrip().startswith("#")
            }
        # The generated list is the DELTA against _NEVER_EMPTY, so union rather than replace:
        # the five below are inside src/ and would otherwise have to be restated in it.
        fresh |= set(_NEVER_EMPTY_FILES)
        # A keep list that empties one of the five below would reintroduce the silent failure,
        # so a fresh list REPLACES the default only after it is shown to cover it.
        missing = _NEVER_EMPTY_FILES - fresh
        if missing:
            print("skeleton: the --keep list drops files known to feed a generator:",
                  file=sys.stderr)
            for m in sorted(missing):
                print("    " + m, file=sys.stderr)
            print("  An emptied generator input does not fail, it produces an empty output.",
                  file=sys.stderr)
            return 2
        _keep_files = frozenset(fresh)
        print(f"skeleton: keeping {len(_keep_files)} file(s) from {keep_path}", file=sys.stderr)

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
            elif may_empty(rel) and not is_build_file(rel):
                # The NAME is the whole content that analysis needs, and nothing here reads
                # a C family file: compiles do not run in this derivation.
                open(dst, "wb").close()
                emptied += 1
            else:
                with open(p, "rb") as fh_in, open(dst, "wb") as fh_out:
                    fh_out.write(fh_in.read())
                copied += 1
            # THE MODE, which writing bytes does not carry. buck2 EXECUTES things out of this
            # tree -- mig.sh, generate-rpc-wrappers.py, configure scripts -- and an
            # executable that arrives without its +x bit fails at exec time, a long way from
            # here and with nothing pointing back at the skeleton. Applied to emptied files
            # too, so the tree differs from the original in CONTENT only.
            #
            # NOT FOR SYMLINKS, and that is not a nicety: os.stat FOLLOWS the link, this tree
            # is full of DANGLING ones (the SDK farm alone points at headers that projectSrc
            # does not contain), and the first run died on
            # AppKit.framework/Headers with FileNotFoundError. A symlink has no mode of its
            # own that survives being recreated anyway.
            if not os.path.islink(p):
                os.chmod(dst, os.stat(p).st_mode & 0o7777)

    print(f"skeleton: {copied} file(s) copied whole, {emptied} emptied, "
          f"{links} symlinks, {dirs} directories", file=sys.stderr)
    if copied == 0 or emptied == 0:
        raise SystemExit("skeleton: nothing was copied or nothing was emptied, "
                         "the filter is wrong")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
