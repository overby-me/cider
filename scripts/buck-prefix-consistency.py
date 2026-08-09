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


def plist_source(label):
    """Where a plist label's source file actually lives.

    DERIVED FROM THE LABEL, not globbed, because globbing one directory silently skipped the
    most important plist in the prefix: shellspawn is `//src/shellspawn:...`, so a glob rooted
    at buck-src/ never found it, and shellspawn is what `cider shell` uses to spawn the guest
    shell. A check that quietly cannot see its most important case is worse than no check.

    Three forms, in order:
      //src/shellspawn:org.ciderhq.shellspawn.plist -> src/shellspawn/org.cider....plist
      //buck-src:security_OSX_sec_ipc_com.apple.secd.plist -> the name's underscores are path
          separators: buck-src/security/OSX/sec/ipc/com.apple.secd.plist
      anything else -> a repo-wide glob on the file name, as a last resort
    """
    pkg, _, name = label.lstrip("/").partition(":")
    direct = os.path.join(ROOT, pkg, name)
    if os.path.exists(direct):
        return direct
    # underscore-encoded path, peeled from the left so a dotted file name survives
    parts = name.split("_")
    for i in range(len(parts) - 1, 0, -1):
        cand = os.path.join(ROOT, pkg, *parts[:i], "_".join(parts[i:]))
        if os.path.exists(cand):
            return cand
    # Last resort, over the SOURCE roots only. A repo-wide `**` glob is not an option: it
    # walks buck-out, which is hundreds of thousands of build artifacts, and the first version
    # of this took the check from under a second to over ten MINUTES. Filtering buck-out out
    # of the results afterwards does not help, because the walk has already happened.
    # The label NAME is the underscore-encoded path, so the file on disk is only its last
    # component: `remote_cmds_talkd.tproj_ntalk.plist` is `.../talkd.tproj/ntalk.plist`.
    # Globbing the whole name finds nothing, which is how ntalk and tftp stayed "not checked"
    # even though both were sitting in the tree.
    leaf = name.split("_")[-1]
    for root in ("src", "buck-src", "darwin", "linux", "buck"):
        hits = glob.glob(os.path.join(ROOT, root, "**", leaf), recursive=True)
        if hits:
            return hits[0]
    return None


def plist_program(label):
    """The Program a launchd plist names, read from its source in the repo.

    A plist whose source cannot be found is REPORTED, not silently passed: an unreadable input
    is not evidence of correctness.
    """
    src = plist_source(label)
    if not src:
        return None, "source not found"
    text = open(src, errors="ignore").read()
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
