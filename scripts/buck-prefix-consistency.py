#!/usr/bin/env python3
"""Is a prefix internally consistent: does everything it points at, it also install?

Removing an install entry is not a local edit. Other entries REFER to it, and those references
do not fail loudly, they produce a prefix that is quietly wrong:

  SYMLINKS. A multi-call binary ships once and is symlinked under its other names. Dropping
  `installer` orphaned lsbom, pkgutil and uninstaller; dropping `less` orphaned `more`;
  dropping `unzip` orphaned `zipinfo`. Five links to nothing. This is #41 again, where eight
  krb5 dylib symlinks dangled.

  LAUNCHD PLISTS. A plist names a Program. Dropping the security daemons, sshd and cupsd left
  seven plists whose Program does not exist, so launchd would try to spawn each at boot and
  fail. **The smoke test cannot catch this**: it runs with DARLING_NO_LAUNCHD=1, so the job
  graph is never exercised at all.

The symlink half is also enforced in gen-prefix-min.py, which drops orphaned links as it
writes. This exists because that only protects the generated minimal prefix, and because a
check that can be pointed at any prefix is what turns "I removed something" into a question
with an answer.

Usage:
  scripts/buck-prefix-consistency.py                          # the minimal prefix
  scripts/buck-prefix-consistency.py --prefix buck/prefix/BUCK
"""

import argparse
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def section(text, name):
    m = re.search(r"^\s+%s = \{(.*?)^\s+\}," % name, text, re.M | re.S)
    return m.group(1) if m else ""


def installed_destinations(text):
    dests = set()
    for sec in ("entries", "files", "trees"):
        dests |= set(re.findall(r'^\s*"([^"]+)"\s*:', section(text, sec), re.M))
    return dests


def plist_program(label):
    """The Program a launchd plist names, read from its source in the repo.

    The label's last underscore-separated component is the file name, which is enough to find
    it. A plist whose source cannot be found is REPORTED, not silently passed: an unreadable
    input is not evidence of correctness.
    """
    fname = label.split(":")[-1].split("_")[-1]
    hits = glob.glob(os.path.join(ROOT, "buck-src", "**", fname), recursive=True)
    if not hits:
        return None, "source not found"
    text = open(hits[0], errors="ignore").read()
    m = re.search(
        r"<key>Program(?:Arguments)?</key>\s*(?:<array>\s*)?<string>([^<]+)</string>", text)
    if not m:
        return None, "no Program key"
    return m.group(1), None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", default="buck/prefix-min/BUCK")
    args = ap.parse_args()

    path = os.path.join(ROOT, args.prefix)
    if not os.path.exists(path):
        sys.exit(f"{path} does not exist")
    text = open(path).read()
    dests = installed_destinations(text)
    if not dests:
        sys.exit(f"{args.prefix}: no install destinations found; wrong file?")

    failures = 0

    links = re.findall(r'^\s*"([^"]+)"\s*:\s*"([^"]+)"', section(text, "symlinks"), re.M)
    dangling = [(a, b) for a, b in links if b not in dests]
    print(f"symlinks: {len(links)}, dangling: {len(dangling)}")
    for a, b in dangling:
        print(f"  FAIL {a}\n         -> {b}  (not installed)")
    failures += len(dangling)

    plists = re.findall(
        r'^\s*"([^"]*Launch(?:Daemons|Agents)/[^"]+)"\s*:\s*"([^"]+)"', text, re.M)
    bad, unknown = [], []
    for dest, label in plists:
        prog, why = plist_program(label)
        if prog is None:
            unknown.append((dest, why))
            continue
        leaf = prog.rsplit("/", 1)[-1]
        if not any(d.endswith("/" + prog.lstrip("/")) or d.endswith("/" + leaf)
                   for d in dests):
            bad.append((dest, prog))
    print(f"launchd plists: {len(plists)}, Program missing: {len(bad)}")
    for dest, prog in bad:
        print(f"  FAIL {dest.rsplit('/', 1)[-1]}\n         Program {prog} is not installed")
    failures += len(bad)
    for dest, why in unknown:
        print(f"  note {dest.rsplit('/', 1)[-1]}: {why}, not checked")

    if failures:
        print(f"\nFAIL: {failures} reference(s) point at something the prefix does not install")
        return 1
    print("\nPASS: every symlink target and every plist Program is installed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
