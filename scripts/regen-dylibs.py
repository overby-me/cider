#!/usr/bin/env python3
"""Regenerate every libSystem member's dylib block from the reference graph.

Two kinds of member, and getting them mixed up registers a target twice:

  * ones whose firstpass block was GENERATED live inside a `# BEGIN generated:
    <t> dylibs` marker, so the whole pair is regenerated together;
  * ones whose firstpass block is HAND-WRITTEN keep it, and only the final pass
    is generated (--final-only).

Run after changing how gen-buck-from-ninja.py emits dylibs.

Usage: scripts/regen-dylibs.py [--dry-run]
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = ("buck-out", ".git", ".jj", ".direnv", "build")
# Fixtures, not libSystem members.
NOT_MEMBERS = {"a", "b"}

# Nothing is hand-tuned any more: the two things that used to need it are now
# expressed in the generator (OBJLIB_ALIASES for object libraries whose sources
# this port compiles elsewhere) and in extra-deps.json (`objs:` and `dep:` entries
# for what the port adds, like the kernel's own flag group for the generated
# rpc.c). Keeping the set here for the next case that needs it.
HAND_TUNED: set = set()


def buck_files():
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if "BUCK" in filenames:
            yield os.path.join(dirpath, "BUCK")


def marker_spans(text):
    spans = []
    for m in re.finditer(r"^# BEGIN generated: (.+)\n", text, re.M):
        end = text.find(f"# END generated: {m.group(1)}\n", m.end())
        if end != -1:
            spans.append((m.start(), end))
    return spans


def members():
    """Every circular libSystem member, from the reference graph.

    Driven by the GRAPH rather than by what the BUCK files happen to contain: a
    member whose block was just deleted is exactly the one that needs regenerating,
    and scanning the files would skip it.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(REPO, "scripts", "gen-buck-from-ninja.py"))
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    found = set()
    for outs, _rule, _inputs, _vars in gen.read_edges():
        for o in outs:
            m = re.match(r"lib([A-Za-z0-9_.-]+)_firstpass\.dylib$", os.path.basename(o))
            if m and "/" in o:
                found.add(m.group(1))
    return sorted(found - NOT_MEMBERS - HAND_TUNED)


def generated_dylib_targets():
    """cmake targets that already own a `<t> dylibs` block.

    Libraries outside the circular cluster (libc++abi, libquarantine, ...) are not
    members, so enumerating members misses them -- and a stale label in one of their
    blocks breaks every consumer. The marker is the record of what generated it.
    """
    found = set()
    for f in buck_files():
        for m in re.finditer(r"^# BEGIN generated: (\S+) dylibs\n", open(f).read(), re.M):
            found.add(m.group(1))
    return found


def classify():
    """(targets to regenerate as a pair, targets where only the final is generated)."""
    hand = set()
    for f in buck_files():
        text = open(f).read()
        spans = marker_spans(text)
        for m in re.finditer(r'name = "([A-Za-z0-9_]+)_firstpass",', text):
            if not any(a <= m.start() < b for a, b in spans):
                hand.add(m.group(1))
    all_targets = set(members()) | generated_dylib_targets()
    return sorted(t for t in all_targets if t not in hand), sorted(hand & all_targets)


def main(argv: list[str]) -> int:
    pair, hand = classify()
    print(f"pair ({len(pair)}): {' '.join(pair)}")
    print(f"final-only ({len(hand)}): {' '.join(hand)}")
    if "--dry-run" in argv:
        return 0
    gen = os.path.join(REPO, "scripts", "gen-buck-from-ninja.py")
    # Iterate to a FIXPOINT, for the same reason the build itself needs two passes:
    # a target can only name siblings whose targets already exist, and each pass
    # both reads and writes the same files, so one round leaves whatever came later
    # in the order unresolved (with a TODO). Repeat until nothing changes.
    def snapshot():
        return {f: open(f).read() for f in buck_files()}

    before = snapshot()
    for pass_no in range(1, 6):
        for args, group in ((["--dylibs", "--write"], pair),
                            (["--dylibs", "--final-only", "--write"], hand)):
            if not group:
                continue
            r = subprocess.run([gen] + args + group, cwd=REPO, capture_output=True, text=True)
            if pass_no == 2:
                sys.stderr.write(r.stderr)
            if r.returncode != 0:
                # Loudly: a generator crash mid-list leaves the remaining members
                # untouched, which reads exactly like "nothing to do".
                sys.stderr.write(r.stderr)
                print(f"FAILED (pass {pass_no}): {' '.join(args + group)}", file=sys.stderr)
                return r.returncode
        after = snapshot()
        if after == before:
            print(f"converged after {pass_no} pass(es)", file=sys.stderr)
            break
        before = after
    subprocess.run([os.path.join(REPO, "scripts", "buck-fix-loads.nu")], cwd=REPO)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
