#!/usr/bin/env python3
"""Which relative symlinks reach OUT of the tree they would be staged in?

This exists because the same mistake was made twice in one night, in two different places,
and neither the build nor the checks caught it until an hour of compiling had gone by.

  #54 staged each source GROUP as its own store path. darwin/frameworks/CoreServices/include/
  CoreServices/MacTypes.h is itself a link to ../../../../basic-headers/MacTypes.h. Under one
  shared projectSrc that resolved inside the same store path; under groups it resolved four
  levels above the CoreServices store path and dangled. 1,194 targets failed.

  Then per-PIN stores staged each submodule as its own store path. pins/IOKitUser/
  darling/submodules/xnu is a link to ../../../xnu/. Same shape, same failure, and the pin
  check passed anyway: it compared by NAR hash, and a NAR hash records a symlink TARGET as a
  STRING. Two identical strings that resolve to different places because the root moved look
  identical to it. A check that cannot fail is worth nothing.

So the property to test is not "are the bytes the same" but "is this subtree SELF CONTAINED":
every relative symlink inside it must land inside it, or it cannot be staged on its own.

PINS NEED THE ASSEMBLED TREE, NOT THE REPO, and this script reported a clean 0 for them until
that was noticed -- which would have been the very failure it exists to prevent. The 147
`pins/<pin>` directories are EMPTY MOUNT POINTS here; content is fetched by
nix/lib/cider-src.nix and only exists in the assembled store path. Walking the repo for them
walks nothing and finds nothing wrong. So pins mode requires --root and refuses to pass on a
boundary that held no symlinks at all.

COUNT THE EFFECT, NOT JUST THE CAUSE. `pins` finds 21 escaping links across 12 pins, which
sounds negligible. `resolve` on the same pin stores finds **143 dangling links of 3,861 across
15 pins**, because one escaping DIRECTORY link carries every file link under it: IOKitUser has
3 escapes and 117 dangling links, since darling/include/IOKit/*.h all point through
darling/submodules/xnu. Seven times the blast radius of the escape count. Quote the resolve
number when describing the damage.

Usage:
  buck-escape-check.py pins --root /nix/store/...-cider-src   # per-pin store boundary
  buck-escape-check.py groups                                   # the #54 source-group boundary
  buck-escape-check.py resolve <dir> ...                        # does a tree AS STAGED work
  buck-escape-check.py path <dir> ...                           # arbitrary boundaries

Find the assembled tree with:
  ls -d /nix/store/*-cider-src | tail -1

Exit 0 when every boundary is self contained, 1 when any is not, 2 on trouble.

VERIFIED on the tree it was written against, three ways:
  `groups`                     -> 2,306 escapes across 15 groups, matching an independent walk
  `pins --root <assembled>`    -> 21 across 12 pins, matching the same independent walk
  `pins` with no --root        -> REFUSES with exit 2 rather than reporting a clean 0
The third is the one that matters, because reporting 0 there is the exact bug this file is
about. `path darwin/basic-headers` was tried as a zero case and is NOT one: it reports 2, both
into pins (AvailabilityVersions.h and architecture). Left recorded rather than swapped for a
tidier example, because it is a real answer.
"""
from __future__ import annotations

import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# EXACTLY the rule in scripts/buck2-graph-sources.py, copied rather than approximated. An
# earlier version of this file guessed at it (frameworks three deep, everything else two) and
# reported 2,490 escapes across 8 groups where the real rule gives 2,306 across 15. Same
# conclusion, wrong numbers, and the numbers were quoted in a commit message.
_UNGROUPED = ("buck-src/", "pins/", "buck-rust/")


def group_of(rel: str):
    if rel.startswith(_UNGROUPED):
        return None
    segs = rel.split("/")
    return "/".join(segs[:3]) if len(segs) >= 4 else None


def escapes(boundary_of, roots, tree=None):
    """[(link, target, destination, boundary)] for links leaving their boundary.

    Returns (found, walked) so the caller can refuse to pass on a boundary it never saw.
    """
    tree = tree or REPO
    out = []
    walked = 0
    for r in roots:
        base = os.path.join(tree, r)
        if not os.path.isdir(base):
            continue
        for dp, dns, fns in os.walk(base, followlinks=False):
            dns[:] = [d for d in dns if d not in (".git", ".jj")]
            for n in dns + fns:
                p = os.path.join(dp, n)
                if not os.path.islink(p):
                    continue
                walked += 1
                t = os.readlink(p)
                if t.startswith("/"):
                    continue  # absolute, already root independent
                rel = os.path.relpath(p, tree)
                dest = os.path.relpath(os.path.normpath(os.path.join(dp, t)), tree)
                b = boundary_of(rel)
                if boundary_of(dest) != b:
                    out.append((rel, t, dest, b))
    return out, walked


def report(title, found, walked, total_hint=""):
    from collections import Counter
    print(f"{title}: {len(found)} escaping symlink(s) of {walked} walked{total_hint}")
    if walked == 0:
        print("  REFUSING: no symlink was walked at all, so this proved nothing.")
        print("  The pins pin directories are empty mount points in the repo;")
        print("  point --root at an assembled cider-src instead.")
        return 2
    if not found:
        print("  self contained, safe to stage standalone")
        return 0
    for b, n in Counter(f[3] for f in found).most_common():
        print(f"  {n:6d}  {b}")
    print("  first few:")
    for rel, t, dest, _ in found[:6]:
        print(f"    {rel}\n      -> {t}   (lands {dest})")
    print("  NOT self contained: staging any of these on its own dangles those links.")
    return 1


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    mode = argv[1]
    rest = argv[2:]
    tree = REPO
    if "--root" in rest:
        i = rest.index("--root")
        tree = rest[i + 1]
        rest = rest[:i] + rest[i + 2:]

    if mode == "pins":
        manifest = json.load(open(os.path.join(REPO, "nix", "submodules.json")))
        pins = [e["path"] for e in manifest if e["path"].startswith("pins/")]
        pinset = set(pins)

        def boundary(rel):
            p = rel.split(os.sep)
            cand = os.sep.join(p[:3])
            return cand if cand in pinset else "<outside any pin>"

        found, walked = escapes(boundary, pins, tree)
        found = [f for f in found if f[3] != "<outside any pin>"]
        return report("pins", found, walked, f" over {len(pins)} pins")

    if mode == "groups":
        # A link whose OWN path is in no group travels individually as a shallow file, so it
        # has no boundary to escape from and is not a finding.
        def boundary(rel):
            return group_of(rel) or "<no group>"

        found, walked = escapes(boundary, ["darwin", "src", "linux"], tree)
        found = [f for f in found if f[3] != "<no group>"]
        return report("groups", found, walked)

    if mode == "resolve":
        # The OTHER half of the question. `groups` and `pins` ask whether a subtree could be
        # staged on its own; this asks whether a tree AS STAGED actually works, by following
        # every symlink in it. That is what a compiler does, and it is the check to run on a
        # pin farm or a staged group once the escapes have been rewritten.
        roots = rest or ["."]
        dangling, walked = [], 0
        for r in roots:
            base = r if os.path.isabs(r) else os.path.join(tree, r)
            # A HAND WALK THAT DESCENDS THROUGH SYMLINKED DIRECTORIES, keeping the LOGICAL
            # path. os.walk with followlinks=False stops at a symlinked directory, and on a
            # linkFarm every entry IS one, so it walked 147 links and reported a clean 0 for a
            # farm holding thousands. That is the third false pass of the night from the same
            # mistake: a check has to be pointed at the thing it claims to measure.
            #
            # followlinks=True instead would loop on a cyclic symlink, and this tree has had
            # one (#20, JavaScriptCore), so the realpath set is the cycle guard.
            seen = set()
            stack = [base]
            while stack:
                d = stack.pop()
                real = os.path.realpath(d)
                if real in seen:
                    continue
                seen.add(real)
                try:
                    entries = os.listdir(d)
                except OSError:
                    continue
                for n in entries:
                    if n in (".git", ".jj"):
                        continue
                    p = os.path.join(d, n)
                    if os.path.islink(p):
                        walked += 1
                        if not os.path.exists(p):  # exists FOLLOWS, lexists would not
                            dangling.append((os.path.relpath(p, base), os.readlink(p)))
                            continue
                    if os.path.isdir(p):
                        stack.append(p)
        print(f"resolve {' '.join(roots)}: {len(dangling)} dangling of {walked} symlinks")
        if walked == 0:
            print("  REFUSING: no symlink was walked, so this proved nothing")
            return 2
        if not dangling:
            print("  every symlink resolves where it is")
            return 0
        for rel, t in dangling[:10]:
            print(f"    {rel}  ->  {t}")
        if len(dangling) > 10:
            print(f"    ... and {len(dangling) - 10} more")
        return 1

    if mode == "path":
        roots = rest
        if not roots:
            sys.exit("path mode needs at least one directory")
        rootset = {r.rstrip("/") for r in roots}

        def boundary(rel):
            for r in rootset:
                if rel == r or rel.startswith(r + os.sep):
                    return r
            return "<outside>"

        found, walked = escapes(boundary, roots, tree)
        found = [f for f in found if f[3] != "<outside>"]
        return report(" ".join(roots), found, walked)

    sys.exit(f"unknown mode {mode!r}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
