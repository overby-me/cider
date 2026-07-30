#!/usr/bin/env python3
"""Make the materialized pins crawlable by buck2.

buck2 rejects two kinds of symlink outright, and both occur in the upstream trees:

  * a target with a "." component ("path contains platform-specific path separator"),
    e.g. corefoundation's CFArray.h -> include/CoreFoundation/./CFArray.h;
  * a target that leaves the cell ("expected a normalized path"), e.g. libnotify's
    darling/src/notify.defs -> ../../../../../darwin/.../usr/include/mach/notify.defs,
    which reaches back into the repo's SDK symlink farm.

Both are rewritten to point at the same file INSIDE buck-src: the SDK farm's own links
end in src/external/<pin>/..., which is exactly buck-src/<pin>/....

Run after scripts/buck-src.sh (it invokes this itself); safe to re-run.

Usage: scripts/buck-src-normalise.py [<tree> ...]
"""
from __future__ import annotations

import os
import stat
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUCK_SRC = os.path.join(REPO, "buck-src")


def in_tree_target(link: str, target: str) -> str | None:
    """Where a link should point instead, or None to leave it alone."""
    parts = [c for c in target.split("/") if c != "."]
    if len(parts) != len(target.split("/")):
        return "/".join(parts)

    if os.path.isabs(target):
        return None
    resolved = os.path.normpath(os.path.join(os.path.dirname(link), target))
    if resolved.startswith(BUCK_SRC + os.sep):
        return None  # already inside the tree
    if not resolved.startswith(REPO + os.sep):
        # The link escapes the repo entirely: it was written for a tree of a different
        # depth (libnotify's darling/src/notify.defs climbs five levels to reach what
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
    if not rel.startswith("src/external/"):
        return None
    inside = os.path.join(BUCK_SRC, rel[len("src/external/"):])
    if not os.path.exists(inside):
        return None
    return os.path.relpath(inside, os.path.dirname(link))


def main(argv: list[str]) -> int:
    roots = argv[1:] or [BUCK_SRC]
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
    if fixed or skipped:
        print(f"buck-src: re-pointed {fixed} symlink(s) into the tree"
              + (f", {skipped} could not be written" if skipped else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
