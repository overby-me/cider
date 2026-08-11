#!/usr/bin/env python3
"""Every materialized pin tree must be at the revision the manifest asks for.

WHY THIS EXISTS. buck-src.nu is supposed to guarantee this, and on 2026-08-10 it did not: it
printed "configd already materialized from the assembled tree" while the tree on disk was the
PREVIOUS revision. Its second skip honoured a marker file on presence alone, with no
comparison, so once a tree had been materialized by --all that marker skipped it for ever.

The consequence is the expensive kind. The bump was verified by building
//darwin/frameworks:SystemConfiguration_dylib, which compiles configd. With a stale tree that
build compiles the OLD code and passes, so the bisect target reports success about a revision
it never saw. A green build proving nothing.

That specific bug is fixed. This exists because the FIX lives in the same script that had the
bug, and a bump is exactly when nobody looks. This checks the RESULT on disk instead of
trusting the process that produced it.

THE CHECK: for every manifest entry with a hash, work out where it materializes, and if that
directory exists require a .buck-src-rev stamp equal to the manifest rev. A tree that is not
materialized at all is fine and is reported separately, because most of the 148 pins are only
materialized on demand.

THE DESTINATION RULE IS COPIED FROM buck-src.nu AND IS NOT A DETAIL. A pin directly under
pins goes to buck-src/<basename>; anything deeper materializes IN PLACE at its own
path. Basenames are not unique -- pins/xnu and pins/ciderd/xnu-sys/xnu both end
in xnu -- and collapsing them into buck-src/xnu is a collision that has already broken this
project once through materializePins.

A MISSING STAMP IS REPORTED, NOT FAILED, AND THAT DISTINCTION WAS LEARNED IMMEDIATELY. The
first version of this treated an unstamped tree as a defect. Run against the real repo it
reported 143 of 148 materialized pins as problems, because every one of them was placed by an
older --all that wrote only .buck-src-assembled. That is not 143 defects, it is the ordinary
state of this tree, and a check that fails on the ordinary state gets ignored or silenced.

Worse, it made the negative control worthless: a planted stale rev DID make it exit 1, but so
did the 143 unstamped trees, so the exit code proved nothing about stale detection. The control
only became real once stale was the ONLY thing that fails.

So: a mismatched stamp is a FAILURE, because it is a definite statement that the tree is the
wrong revision. An absent stamp is COUNTED and named, because it means provenance is unknown
rather than known-bad, and the honest remedy is one --all that will stamp them all.

Exit 0 if no materialized pin contradicts the manifest, 1 if any does.
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


PIN_ROOT = "pins"
PIN_ROOT_DEPTH = len(PIN_ROOT.split("/"))


def directly_under_pin_root(path):
    """The test is DIRECTLY UNDER THE PIN ROOT, which is not the same thing as a fixed depth.

    It read `== 3` while the root was src/external (NO-PIN-REWRITE), and writing `== 2` for pins/ would just
    reseat the same landmine one rename later. Expressed against the root, it survives the
    next move without anyone having to remember this comment.
    """
    return len(path.split("/")) == PIN_ROOT_DEPTH + 1


def dest_for(path):
    """Where buck-src.nu materializes this entry. Same rule, deliberately duplicated: if the
    two ever disagree, this check is measuring a directory nothing writes."""
    if directly_under_pin_root(path):
        return os.path.join(ROOT, "buck-src", os.path.basename(path))
    return os.path.join(ROOT, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(ROOT, "nix", "submodules.json"),
                    help="point at a copy to negative-control this without touching the repo")
    a = ap.parse_args()

    entries = [e for e in json.load(open(a.manifest, encoding="utf-8"))
               if e.get("hash")]

    materialized = stale = unstamped = 0
    problems = []
    for e in entries:
        dest = dest_for(e["path"])
        if not os.path.isdir(dest):
            continue
        materialized += 1
        stamp = os.path.join(dest, ".buck-src-rev")
        if not os.path.exists(stamp):
            unstamped += 1
            continue
        got = open(stamp, encoding="utf-8").read().strip()
        if got != e["rev"]:
            stale += 1
            problems.append(
                f"{e['path']} is at {got[:12]} but the manifest asks for {e['rev'][:12]}. "
                f"The tree is STALE and anything compiled from it tests the wrong revision.")

    print(f"manifest entries with a hash: {len(entries)}; materialized on disk: "
          f"{materialized}; stale: {stale}; unstamped: {unstamped}")
    if unstamped:
        print(f"note: {unstamped} materialized trees carry no .buck-src-rev, so their "
              f"revision cannot be established from disk. They were placed by an --all that "
              f"predates the stamp. Not a failure, and one scripts/buck-src.nu --all stamps "
              f"them all. Only a stamp that CONTRADICTS the manifest fails below.")

    if not problems:
        print("PASS: no materialized pin contradicts the manifest")
        return 0

    print(f"\n{len(problems)} materialized pins contradict the manifest:")
    for p in problems:
        print(f"  {p}")
    print("\nFAIL: a build against a stale pin compiles the PREVIOUS upstream revision and "
          "passes, which is why this is checked on disk rather than trusted from the script "
          "that materializes it.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
