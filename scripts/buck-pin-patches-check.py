#!/usr/bin/env python3
"""Every patch set must reach exactly the pin it was written for, and nothing else.

THE WHOLE MECHANISM IS A pathExists AND A BASENAME, which is two silent failure modes in
three lines. From nix/lib/cider-src.nix:

    patchSub   = patchesDir + ("/" + (e.patches or base));   # base is baseNameOf e.path
    hasPatches = builtins.pathExists patchSub;

So a patch directory is applied when it happens to exist and is skipped when it does not.
Nothing anywhere says which pins are SUPPOSED to be patched, and that gap has three shapes:

  1  A `patches` field naming a directory that is not there. Rename patches/xnu-sys-xnu, or
     typo the field, and hasPatches goes false and the pin is silently the RAW upstream fetch.
     For that entry specifically that means the 51-file vendored delta vanishes and the
     duct-tape build compiles against unmodified XNU.

  2  An ORPHAN patch directory that no manifest entry maps to. It looks like maintained,
     applied local delta and is dead weight that has never been applied to anything.

  3  A BASENAME COLLISION, which is the one that has already bitten. Patches key on
     baseNameOf, and two different pins here really are both called `xnu`:

         pins/xnu                       darlinghq/darling-xnu, the GUEST syscall tree
         pins/ciderd/xnu-sys/xnu        the same repo, the duct-tape KERNEL subset

     patches/xnu holds NINE guest syscall patches that touch
     darling/src/libsystem_kernel/emulation only. Without an explicit override the de-vendored
     kernel subset would receive all nine, because it is spelled `xnu` too. cider-src.nix
     documents this and the manifest does carry `patches: xnu-sys-xnu`. This asserts it rather
     than trusting the comment, and it fires for any FUTURE collision as well: the moment a
     second pin shares a basename with a patch directory and has no override, it is wrong.

NONE OF THE THREE IS A BUILD ERROR. An unpatched or wrongly patched pin compiles, and says so
much later as a mismatched signature or a missing member, an hour into an endpoint. This costs
about ten milliseconds.

DELIBERATELY NOT CHECKED: whether the patches still apply. That needs the fetched store paths
and belongs to buck-pin-store-check.nu, which already diffs a per-pin store against the
assembled tree. This is purely about the WIRING, which is the part with no owner.

Exit 0 if every patch set reaches exactly its intended pin, 1 otherwise.
"""
import argparse
import collections
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(ROOT, "nix", "submodules.json"),
                    help="point at a mutated COPY to negative-control this without touching "
                         "the working copy, which matters while a gate is running")
    ap.add_argument("--patches", default=os.path.join(ROOT, "patches"))
    a = ap.parse_args()

    entries = json.load(open(a.manifest, encoding="utf-8"))
    dirs = {d for d in os.listdir(a.patches)
            if os.path.isdir(os.path.join(a.patches, d))}

    # Mirror the nix exactly: explicit field first, basename otherwise.
    mapped = collections.defaultdict(list)
    by_basename = collections.defaultdict(list)
    for e in entries:
        base = os.path.basename(e["path"])
        by_basename[base].append(e["path"])
        mapped[e.get("patches") or base].append(e)

    problems = []

    for e in entries:
        want = e.get("patches")
        if want and want not in dirs:
            problems.append(
                f"{e['path']} asks for patches/{want}, which does not exist, so it is "
                f"silently the RAW upstream fetch with no local delta at all")

    for d in sorted(dirs - set(mapped)):
        n = len(os.listdir(os.path.join(a.patches, d)))
        problems.append(
            f"patches/{d} ({n} patches) is an ORPHAN: no manifest entry names it and no pin "
            f"basename matches it, so it has never been applied to anything")

    for base, paths in sorted(by_basename.items()):
        if len(paths) < 2 or base not in dirs:
            continue
        # A collision only matters where the shared basename also names a patch directory:
        # then every colliding entry without an override silently inherits those patches.
        victims = [p for p in paths
                   if not next(e.get("patches") for e in entries if e["path"] == p)]
        if len(victims) > 1:
            problems.append(
                f"basename {base} is shared by {len(paths)} pins and patches/{base} exists, "
                f"so these would all receive the SAME patch set with no override: "
                f"{', '.join(victims)}")

    print(f"manifest entries {len(entries)}, patch directories {len(dirs)}")
    for d in sorted(dirs):
        who = [e["path"] for e in mapped.get(d, [])]
        n = len(os.listdir(os.path.join(a.patches, d)))
        print(f"  patches/{d}: {n} patches -> {', '.join(who) if who else 'NOTHING'}")

    if not problems:
        print("PASS: every patch set reaches exactly the pin it was written for")
        return 0

    print(f"\n{len(problems)} problems with the patch wiring:")
    for p in problems:
        print(f"  {p}")
    print("\nFAIL: patches key on a basename behind a pathExists, so all of these are SILENT. "
          "An unpatched or wrongly patched pin builds, and reports as a mismatched signature "
          "an hour into an endpoint.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
