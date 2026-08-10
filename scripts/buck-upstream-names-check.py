#!/usr/bin/env python3
"""Anything UPSTREAM references keeps its old name. Only names used solely by us are Cider.

That one rule covers every class the Cider rename broke, and this check enforces it
mechanically instead of waiting for a build to trip over each one.

HOW THE BREAKS LOOK. A pin names something Darling-flavoured, we renamed our side to
Cider, and nothing connects them any more:

    #include <darlingserver/rpc.h>          we shipped ciderd/rpc.h
    #include <darling/emulation/...>        we staged cider/emulation/...
    #include <darling-config.h>             we generated cider-config.h
    __darling_thread_create(...)            we defined __cider_thread_create
    darling_thread_create_callbacks_t       we defined cider_..._callbacks_t

None of these is a compile error in OUR tree. They fail only where an upstream file is
compiled against our headers, which on the nix endpoint is an hour in, one at a time,
each costing a full rebuild. Three of them were found by this check in minutes.

THE TEST: for every token a pin references that contains darling, compute the Cider
form. If our tree contains that Cider form AT ALL, upstream has been orphaned and the
name must go back.

The rule is deliberately "at all" rather than "unless a Darling spelling also survives",
and that distinction came from a negative control that FAILED TO FAIL. Re-breaking
__darling_thread_create in one of its two files left the other spelling intact, so the
weaker rule reported PASS while the build was broken. A name upstream references must be
spelled its way EVERYWHERE, so any Cider spelling of it is a defect.

TWO TRAPS BUILT IN, both of which cost real time:

  1  HYPHENS AND DOTS COUNT. A pattern of [A-Za-z0-9_]* stops at the hyphen in
     darling-config.h, so that break hid inside the 184,642 bare "darling" hits that
     get discarded as noise. The token class here includes . and - deliberately.

  2  grep -r INTO buck-src RETURNS ZERO INSTANTLY AND NEVER SCANS. The grep on this box
     is ugrep honouring ignore files, and buck-src is untracked build input. There is no
     error, the exit code is 1, and it looks exactly like a real negative. This walks the
     tree itself rather than shelling out to grep.

NEGATIVE CONTROL, and it took THREE attempts to build a valid one, which is the point of
insisting on them. Breaking __darling_thread_create in darwin/loader/src/elfcalls.rs
reported PASS twice; the file contains ZERO occurrences of it, so the control was a no-op
and proved nothing. The name lives in src/startup/mldr/elfcalls/threads.h; the loader
holds the SINGLE underscore struct fields. Breaking it there gives

    exit 1, pins use __darling_thread_create (8 times);
            our tree still spells it __cider_thread_create

and restoring gives exit 0. A control that cannot fail looks exactly like a passing check.

COST: about four minutes to read 100k pin files, so the token set is CACHED under
buck-out. Pins move only on a bump; pass --refresh then. This is an on-demand audit and
is deliberately NOT wired into the gate, where it would add minutes to every run for a
rename that happens once.

Exit 0 if no upstream name has been orphaned, 1 otherwise.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINS = os.path.join(ROOT, "buck-src")
OURS = ("src", "linux", "darwin")
SRC_EXT = (".c", ".h", ".cpp", ".m", ".mm", ".S", ".rs")

# . and - are IN the class on purpose; see trap 1 above.
TOKEN = re.compile(r'[A-Za-z0-9_.-]*[Dd]arling[A-Za-z0-9_.-]*')

# Bare project references and upstream's own org and product names: these are prose or
# upstream identity, not something we renamed a counterpart of.
IGNORE = {"darling", "Darling", "darlinghq", "darling.", "Darling.", "darlingC"}


def read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".jj", "buck-out")]
        for name in filenames:
            if name.endswith(SRC_EXT):
                yield os.path.join(dirpath, name)


def scan_pins():
    """Reading 100k pin files takes about four minutes, and pins only move on a bump,
    so the token set is cached. buck-out is gitignored, which is where it belongs:
    a stale cache after a pin bump is fixed by --refresh, and nothing else reads it."""
    cache = os.path.join(ROOT, "buck-out", "upstream-name-tokens.json")
    if "--refresh" not in sys.argv and os.path.exists(cache):
        with open(cache, encoding="utf-8") as fh:
            return json.load(fh), True
    tokens = {}
    for path in walk(PINS):
        for tok in TOKEN.findall(read(path)):
            if tok not in IGNORE:
                tokens[tok] = tokens.get(tok, 0) + 1
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    with open(cache, "w", encoding="utf-8") as fh:
        json.dump(tokens, fh, sort_keys=True)
    return tokens, False


def main():
    os.chdir(ROOT)

    pin_tokens, cached = scan_pins()
    if cached:
        print("pin tokens read from cache; pass --refresh after a pin bump")

    ours = []
    for top in OURS:
        if os.path.isdir(top):
            for path in walk(top):
                ours.append(read(path))
    ours = "\n".join(ours)

    orphaned = []
    for tok, uses in sorted(pin_tokens.items(), key=lambda kv: -kv[1]):
        cider = tok.replace("darling", "cider").replace("Darling", "Cider")
        if cider == tok:
            continue
        # THE RULE IS "no Cider form AT ALL", not "no Cider form unless a Darling one
        # also survives", and the difference is a negative control that did not fail.
        # Re-breaking __darling_thread_create in ONE of its two files left the other
        # spelling intact, so the weaker rule reported PASS while the build was broken.
        # If upstream references a name, every definition of ours must use it.
        has_cider = re.search(r'(?<![A-Za-z0-9_])' + re.escape(cider), ours) is not None
        if has_cider:
            orphaned.append((tok, cider, uses))

    print(f"pin tokens containing darling: {len(pin_tokens)}")
    if not orphaned:
        print("PASS: no upstream name has been orphaned by the rename")
        return 0

    print(f"\n{len(orphaned)} upstream names have no counterpart in our tree:")
    for tok, cider, uses in orphaned:
        print(f"  pins use {tok} ({uses} times); our tree still spells it {cider}")
    print("\nFAIL: upstream keeps its own names, so ours must match where it references us.")
    print("Rename our side back, or provide the name upstream asks for.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
