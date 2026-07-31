#!/usr/bin/env python3
"""Copy a buck2-built prefix into a real, self-contained directory.

A prefix_tree is a farm of links: an installed artifact is an absolute symlink into buck-out,
while the links the reference itself installs are kept verbatim (etc -> private/etc,
private/etc/mtab -> /proc/self/mounts, Volumes/DarlingEmulatedDrive -> /). The container
cannot use the farm as it stands, because the daemon overlay-mounts it as the guest's root
and an absolute host path means nothing inside that root.

So the two kinds have to be told apart, and only one of them followed:

  * a link into buck-out is an INSTALLED FILE and is copied;
  * every other link is PART OF THE LAYOUT and is recreated exactly as it is.

Dereferencing indiscriminately is not an option, and not only for tidiness:
Volumes/DarlingEmulatedDrive points at `/`, so `cp -aL` walks the entire machine. That is how
this script came to exist.

Usage:
  scripts/buck-prefix-materialize.py <buck2 prefix> <destination>
"""
from __future__ import annotations

import os
import shutil
import sys


def layout_links(src: str) -> set:
    """The destinations the prefix declares as symlinks, from the manifest it carries.

    Guessing from the link VALUE does not work: an installed artifact points into buck-out
    or into the source tree, both absolute host paths, while a declared link may be relative
    (etc -> private/etc) or absolute in the GUEST (/proc/self/mounts, /dev/log, /). The
    manifest is the only thing that knows which is which.
    """
    path = os.path.join(src, ".prefix-manifest.tsv")
    if not os.path.isfile(path):
        sys.exit(f"{path} is missing -- is this a prefix_tree output?")
    out = set()
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[0] == "link":
            out.add(parts[1])
    return out


def materialize(src: str, dst: str) -> tuple[int, int, int]:
    files = links = dirs = 0
    src = os.path.abspath(src)
    declared = layout_links(src)
    for root, dirnames, filenames in os.walk(src, followlinks=False):
        rel = os.path.relpath(root, src)
        out = dst if rel == "." else os.path.join(dst, rel)
        os.makedirs(out, exist_ok=True)
        dirs += 1
        for name in list(dirnames):
            # os.walk lists a symlink to a directory under dirnames; recreating it here and
            # dropping it from the walk keeps the layout and avoids following it.
            p = os.path.join(root, name)
            if os.path.islink(p):
                dirnames.remove(name)
                _place(p, os.path.join(out, name), declared, _rel(src, p))
                links += 1
        for name in filenames:
            if rel == "." and name == ".prefix-manifest.tsv":
                continue
            p = os.path.join(root, name)
            if _place(p, os.path.join(out, name), declared, _rel(src, p)):
                links += 1
            else:
                files += 1
    return files, links, dirs


def _rel(root: str, path: str) -> str:
    return os.path.relpath(path, root)


def _place(src: str, dst: str, declared: set, rel: str) -> bool:
    """Copy or link src to dst. True when it was kept as a symlink."""
    if os.path.lexists(dst):
        os.remove(dst)
    if os.path.islink(src):
        if rel in declared:
            os.symlink(os.readlink(src), dst)
            return True
        # An installed artifact, so it is the CONTENT that has to end up here.
        shutil.copy2(src, dst, follow_symlinks=True)
        return False
    shutil.copy2(src, dst, follow_symlinks=False)
    return False


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.exit(__doc__)
    src, dst = argv[1], argv[2]
    if not os.path.isdir(src):
        sys.exit(f"not a directory: {src}")
    files, links, dirs = materialize(src, dst)
    print(f"materialized {files} file(s), {links} symlink(s), {dirs} director(ies) into {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
