#!/usr/bin/env python3
"""Make the materialized pins crawlable by buck2.

buck2 rejects two kinds of symlink outright, and both occur in the upstream trees:

  * a target with a "." component ("path contains platform-specific path separator"),
    e.g. corefoundation's CFArray.h -> include/CoreFoundation/./CFArray.h;
  * a target that leaves the cell ("expected a normalized path"), e.g. libnotify's
    cider/src/notify.defs -> ../../../../../darwin/.../usr/include/mach/notify.defs,
    which reaches back into the repo's SDK symlink farm.

Both are rewritten to point at the same file INSIDE buck-src: the SDK farm's own links
end in src/external/<pin>/..., which is exactly buck-src/<pin>/....

Run after scripts/buck-src.nu (it invokes this itself); safe to re-run.

Usage: scripts/buck-src-normalise.py [<tree> ...]
"""
from __future__ import annotations

import os
import stat
import sys

# The project root. Derived from this file's location for a normal checkout, but
# overridable with --repo, because the Nix endpoint runs this script FROM THE STORE: there
# the script's parent directory is a store path with no project under it, and the rewrite
# that needs the project (an escaping link, resolved through the SDK farm) silently found
# nothing to point at while the "." case kept working.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUCK_SRC = os.path.join(REPO, "buck-src")


def set_repo(root: str) -> None:
    global REPO, BUCK_SRC
    REPO = os.path.abspath(root)
    BUCK_SRC = os.path.join(REPO, "buck-src")


# WE RENAMED FIRST-PARTY DIRECTORIES; UPSTREAM DID NOT, and a pin links into the
# layout upstream has. 2,078 links under buck-src/security/darling/submodules/xnu
# name src/external/darlingserver/duct-tape/xnu, which is where that tree lives in
# Darling and has not existed here since the Cider rename and the duct-tape to
# xnu-sys move.
#
# THIS CLASS IS INVISIBLE TO EVERY CONTENT SWEEP, and that is the whole lesson: a
# symlink TARGET is not file content, so grep does not read it and no rename script
# that rewrites files can reach it. It surfaced only as a buck2 package load failure
# four minutes into the endpoint, naming a path that appears nowhere in the tree:
#     File not found: root//buck-src/darlingserver/duct-tape/xnu
# Longest prefix first, so the duct-tape entry wins over the plain one.
FIRST_PARTY_RENAMES = [
    ("src/external/darlingserver/duct-tape", "src/external/ciderd/xnu-sys"),
    ("src/external/darlingserver", "src/external/ciderd"),
]


def rename_first_party(rel: str) -> str:
    """Translate an upstream-era first-party path to where it lives now."""
    for old, new in FIRST_PARTY_RENAMES:
        if rel == old or rel.startswith(old + os.sep):
            return new + rel[len(old):]
    return rel


def in_tree_target(link: str, target: str) -> str | None:
    """Where a link should point instead, or None to leave it alone."""
    parts = [c for c in target.split("/") if c != "."]
    if len(parts) != len(target.split("/")):
        return "/".join(parts)

    if os.path.isabs(target):
        return None
    # ABSOLUTE, because BUCK_SRC and REPO are: with a relative tree argument the
    # comparisons below silently never matched, and the in-tree cases fell through to the
    # escape handling.
    resolved = os.path.abspath(os.path.join(os.path.dirname(link), target))
    if resolved.startswith(BUCK_SRC + os.sep):
        if os.path.lexists(resolved):
            return None  # already inside the tree and resolving
        # Inside buck-src but DANGLING: the link names a sibling pin that is not
        # materialized here because it lives in the repo proper. security's
        # darling/submodules/xnu points at ciderd/xnu-sys/xnu that way, and
        # ciderd is at src/external/ciderd, not a pin. A dangling link is
        # not merely unused -- a glob that picks it up fails the whole package load.
        # And the name it uses is UPSTREAM's: this is where the security pin says
        # darlingserver/duct-tape/xnu, so the candidate goes through the rename table
        # too. In the Nix graph derivation these links resolve INSIDE buck-src rather
        # than to src/external, which is why fixing only the other branch left the
        # endpoint failing with the re-pointed count still at 103.
        rel = resolved[len(BUCK_SRC) + 1:]
        cand = os.path.join(REPO, rename_first_party(os.path.join("src", "external", rel)))
        if os.path.lexists(cand):
            return os.path.relpath(cand, os.path.dirname(link))
        return None
    if not resolved.startswith(REPO + os.sep):
        # The link escapes the repo entirely: it was written for a tree of a different
        # depth (libnotify's cider/src/notify.defs climbs five levels to reach what
        # is darwin/... from the repo root). Recover the intent by resolving what
        # follows the leading ../ run against the repo root.
        tail = target.lstrip("./")
        while tail.startswith("../"):
            tail = tail[3:]
        cand = os.path.normpath(os.path.join(REPO, tail))
        if not os.path.lexists(cand):
            # Task #68 moved the guest trees under darwin/, and a pin written before
            # that still says Developer/... from the repo root.
            cand = os.path.normpath(os.path.join(REPO, "darwin", tail))
        if not os.path.lexists(cand):
            return None
        resolved = cand

    # Follow the chain textually: the repo's SDK farm is itself symlinks into
    # src/external/<pin>, which is what buck-src holds a copy of.
    seen = set()
    cur = resolved
    while os.path.islink(cur) and cur not in seen:
        seen.add(cur)
        cur = os.path.normpath(os.path.join(os.path.dirname(cur), os.readlink(cur)))
    rel = os.path.relpath(cur, REPO)
    # A renamed first-party tree is in the REPO, not in buck-src, so it resolves here
    # rather than through the pin copy below.
    renamed = rename_first_party(rel)
    if renamed != rel:
        cand = os.path.join(REPO, renamed)
        if os.path.lexists(cand):
            return os.path.relpath(cand, os.path.dirname(link))
        return None
    if not rel.startswith("src/external/"):
        return None
    inside = os.path.join(BUCK_SRC, rel[len("src/external/"):])
    if not os.path.exists(inside):
        return None
    return os.path.relpath(inside, os.path.dirname(link))


def expand_dir_links(root: str) -> int:
    """Replace a symlinked DIRECTORY with a real one holding a link per file.

    buck2's globs do not descend into a symlinked directory, so a header behind one is
    invisible: security ships cider/include/macOS/security_libDER/libDER as a link to
    ../libDER, and `macOS/**/*.h` staged everything EXCEPT what lived behind it. The
    compile then failed on security_libDER/libDER/libDER.h while the file was plainly
    there on disk.

    A directory of per-file links is the shape the repo's own SDK farm uses -- roughly
    1,900 of them -- and buck2 globs and stages those without trouble.
    """
    changed = 0
    for dirpath, dirnames, _files in os.walk(root, followlinks=False):
        for name in list(dirnames):
            link = os.path.join(dirpath, name)
            if not os.path.islink(link):
                continue
            target = os.path.realpath(link)
            if not os.path.isdir(target) or not os.path.exists(target):
                continue
            # A link pointing at its OWN ancestor is a cycle, and expanding one walks into
            # the tree it is itself creating. JavaScriptCore has exactly one --
            # DerivedSources/JavaScriptCore/JavaScriptCore -> ../.. -- and running this over
            # it turned 13 directories at 5 levels into 1147 at 266 before ENAMETOOLONG
            # stopped it. The `except OSError: pass` below then swallowed that, so the
            # function reported expanding nothing while having wrecked the tree; buck2
            # crawls what is left and `aquery` dies with "File name too long". That is what
            # broke the Nix endpoint while the host, whose buck-src still held the plain
            # symlink, kept building.
            here = os.path.join(os.path.realpath(dirpath), name)
            if here == target or here.startswith(target + os.sep):
                print(f"buck-src: left cyclic dir link alone: "
                      f"{os.path.relpath(link, root)} -> {os.readlink(link)}")
                dirnames.remove(name)
                continue
            try:
                os.chmod(dirpath, os.stat(dirpath).st_mode | stat.S_IWUSR)
                os.remove(link)
                for sub, _d, fs in os.walk(target):
                    rel = os.path.relpath(sub, target)
                    dest = os.path.join(link, rel) if rel != "." else link
                    os.makedirs(dest, exist_ok=True)
                    for f in fs:
                        # NEVER MIRROR A BUCK FILE. buck2 reads one as a PACKAGE
                        # definition, so a mirror that carries it defines the whole
                        # target set a SECOND time under the nested path, and both
                        # copies then get built. Measured 2026-08-10: the two mirrors
                        # here contributed 91 duplicate ruby dylib targets and 4
                        # duplicate xnu ones, which is the entire growth in the dylib
                        # count since 08-09. .buckconfig sets [buildfile] name = BUCK,
                        # so that one name is the whole rule.
                        #
                        # THE NUMBER TO EXPECT AFTERWARDS IS 564, not the 568 this said
                        # first. 659 minus 95 is 564, and a suite run on 2026-08-10
                        # measured exactly that, along with exes 415 to 414 and firstpass
                        # dylibs 48 to 47, all from the same duplicates. Confirmed against
                        # the targets rather than the arithmetic: uquery over darwin_dylib
                        # gives 792 targets with 792 DISTINCT names, and ruby appears 91
                        # times rather than 182.
                        if f == "BUCK":
                            continue
                        d = os.path.join(dest, f)
                        if not os.path.lexists(d):
                            os.symlink(os.path.relpath(os.path.join(sub, f), dest), d)
                changed += 1
            except OSError:
                pass
            dirnames.remove(name)
    return changed


def main(argv: list[str]) -> int:
    argv = argv[1:]
    if "--repo" in argv:
        i = argv.index("--repo")
        set_repo(argv[i + 1])
        del argv[i:i + 2]
    roots = argv or [BUCK_SRC]
    fixed = skipped = 0
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            for name in dirnames + filenames:
                path = os.path.join(dirpath, name)
                if not os.path.islink(path):
                    continue
                target = os.readlink(path)
                new = in_tree_target(path, target)
                if new is None or new == target:
                    continue
                try:
                    d = os.path.dirname(path)
                    os.chmod(d, os.stat(d).st_mode | stat.S_IWUSR)
                    os.remove(path)
                    os.symlink(new, path)
                    fixed += 1
                except OSError:
                    skipped += 1
    expanded = sum(expand_dir_links(r) for r in roots)
    if expanded:
        print(f"buck-src: expanded {expanded} symlinked director(ies) into per-file links")
    if fixed or skipped:
        print(f"buck-src: re-pointed {fixed} symlink(s) into the tree"
              + (f", {skipped} could not be written" if skipped else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
