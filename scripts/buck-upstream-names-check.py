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
and proved nothing. The name lives in linux/startup/mldr/elfcalls/threads.h; the loader
holds the SINGLE underscore struct fields. Breaking it there gives

    exit 1, pins use __darling_thread_create (8 times);
            our tree still spells it __cider_thread_create

and restoring gives exit 0. A control that cannot fail looks exactly like a passing check.

COST: about four minutes to read 100k pin files, so the token set is CACHED under
buck-out. This is an on-demand audit and is deliberately NOT wired into the gate, where it
would add minutes to every run for a rename that happens once.

THE CACHE IS BOUND TO THE MANIFEST THAT PRODUCED IT, and a mismatch REFUSES rather than
warns. This used to say "pins move only on a bump, pass --refresh then", which is an
instruction to a human, and this whole file exists because that is not good enough. After a
bump the cached tokens describe the PREVIOUS upstream revision, so the audit would compare
our tree against names it never read and report PASS. Now it exits 2 and says so.

Exit 0 if no upstream name has been orphaned, 1 if one has, 2 if the audit could not be
trusted at all (stale cache, or a table it could not find). Those are deliberately three
different exits: "no defect" and "cannot tell" must never look alike.
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINS = os.path.join(ROOT, "buck-src")
OURS = ("src", "linux", "darwin")
SRC_EXT = (".c", ".h", ".cpp", ".m", ".mm", ".S", ".rs")


def materialized_pins():
    """A PIN MATERIALIZED INSIDE OURS IS STILL UPSTREAM, and after the xnu de-vendoring one
    of them is. src/external/ciderd/xnu-sys/xnu used to be committed source; it is now a pin
    planted at its own path, which lands INSIDE the `src` tree this file treats as ours. It
    is also a NESTED pin, and a nested pin deliberately takes no buck-src alias, so scanning
    buck-src does not reach it either. Both halves were therefore wrong at once: its content
    counted as OURS, and its names were missing from the upstream token set.

    That produced a concrete mistake before this was fixed. DARLING_SDK_RELATIVE_PATH and
    DARLING_ROOT_RELATIVE_TO_SDK live ONLY in that tree, in two CMakeLists, and a rename plan
    listed both as ours to rename. They are Apple and Darling upstream.

    The manifest is the authority on what is a pin, so read it rather than hardcoding a path.
    Every entry whose directory exists on disk is upstream wherever it happens to sit."""
    manifest = os.path.join(ROOT, "nix", "submodules.json")
    try:
        with open(manifest, encoding="utf-8") as fh:
            entries = json.load(fh)
    except (OSError, ValueError):
        return []
    out = []
    for e in entries:
        rel = e.get("path") or ""
        full = os.path.join(ROOT, rel)
        if rel and os.path.isdir(full):
            out.append(os.path.normpath(full))
    return out


PIN_TREES = None  # filled in main(), so the cache key and the OURS filter agree

# . and - are IN the class on purpose; see trap 1 above.
#
# ALL-CAPS IS A THIRD SPELLING AND THIS PATTERN COULD NOT MATCH IT. [Dd]arling matches
# darling and Darling and nothing else, so every DARLING_* name upstream references was
# invisible: the cached token set held 54 names and not one of them was uppercase. The
# check would therefore have reported PASS through an uppercase rename that orphaned
# upstream code, which is the one thing it exists to prevent. The pins really do use these
# names -- DARLING_NW_STUB, DARLING_METAL_ENABLED and about a dozen more -- so this was a
# hole over a live class, not a theoretical one. Refresh the cache after changing this.
TOKEN = re.compile(r'[A-Za-z0-9_.-]*(?:DARLING|[Dd]arling)[A-Za-z0-9_.-]*')

# Bare project references and upstream's own org and product names: these are prose or
# upstream identity, not something we renamed a counterpart of.
IGNORE = {"darling", "Darling", "DARLING", "darlinghq", "darling.", "Darling.", "DARLING.",
          "darlingC"}


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


def manifest_fingerprint():
    """Everything the cached token set depends on, hashed together.

    Content, never mtime: jj operations touch submodules.json without changing it, and a
    spurious failure trains people to pass --refresh reflexively, which costs four minutes
    and defeats the point of caching.

    THE PATTERN IS IN HERE, NOT JUST THE MANIFEST, and that axis is not hypothetical: it is
    the one that already bit. TOKEN used to be [Dd]arling only, so every all-caps DARLING_*
    name was invisible and the cached set held 54 tokens with not one uppercase among them.
    The header for TOKEN still carries the instruction that came out of it, "refresh the
    cache after changing this", and an instruction is exactly what this file exists to stop
    relying on. Widening the pattern without refreshing would leave the check reporting PASS
    over the very class the widening was meant to catch.

    IGNORE is in here too, for the same reason one step milder: dropping a name from IGNORE
    should make it visible, and against a stale cache it would not be."""
    h = hashlib.sha256()
    try:
        with open(os.path.join(ROOT, "nix", "submodules.json"), "rb") as fh:
            h.update(fh.read())
    except OSError:
        h.update(b"no-manifest")
    h.update(b"\x00" + TOKEN.pattern.encode())
    h.update(b"\x00" + "\x00".join(sorted(IGNORE)).encode())
    return h.hexdigest()


def scan_pins():
    """Reading 100k pin files takes about four minutes, and pins only move on a bump,
    so the token set is cached. buck-out is gitignored, which is where it belongs:
    a stale cache after a pin bump is fixed by --refresh, and nothing else reads it.

    AND THE CACHE IS NOW BOUND TO THE MANIFEST THAT PRODUCED IT, because "pass --refresh
    after a bump" is an instruction to a human and this check exists precisely because
    humans miss things. A pin bump changes upstream code, so the token set it is audited
    against is the PREVIOUS revision, and the check reports PASS about a tree it never read.
    That is the same shape as every other silent failure here: not a wrong answer, an answer
    to a question nobody asked.

    Refusing rather than warning, and exiting 2 rather than 1, so "the audit failed" and "the
    audit could not be trusted" are never confused. The old flat cache format has no
    fingerprint and cannot be shown to match, so it is treated as untrusted too."""
    cache = os.path.join(ROOT, "buck-out", "upstream-name-tokens.json")
    want = manifest_fingerprint()
    if "--refresh" not in sys.argv and os.path.exists(cache):
        with open(cache, encoding="utf-8") as fh:
            blob = json.load(fh)
        got = blob.get("manifest") if isinstance(blob, dict) else None
        tokens = blob.get("tokens") if isinstance(blob, dict) else None
        if tokens is not None and got == want:
            return tokens, True
        why = ("was written by an older version that recorded no fingerprint"
               if tokens is None else
               f"was built from a DIFFERENT manifest or token pattern "
               f"({got[:12]}... not {want[:12]}...)")
        print(f"STALE CACHE: buck-out/upstream-name-tokens.json {why}.")
        print("Either the pins have moved or the pattern has widened since it was built, so "
              "auditing against it would compare our tree to the PREVIOUS upstream revision, "
              "or through the PREVIOUS pattern, and report PASS about names it never read. "
              "Re-run with --refresh (about four minutes).")
        sys.exit(2)
    tokens = {}
    for root in [PINS] + PIN_TREES:
        for path in walk(root):
            for tok in TOKEN.findall(read(path)):
                if tok not in IGNORE:
                    tokens[tok] = tokens.get(tok, 0) + 1
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    with open(cache, "w", encoding="utf-8") as fh:
        json.dump({"manifest": want, "tokens": tokens}, fh, sort_keys=True)
    return tokens, False


def main():
    os.chdir(ROOT)

    global PIN_TREES
    PIN_TREES = materialized_pins()

    pin_tokens, cached = scan_pins()
    if cached:
        print("pin tokens read from cache, fingerprint verified against the manifest and the "
              "token pattern")
    print(f"pin trees materialized inside our tree: {len(PIN_TREES)}")

    ours = []
    skipped = 0
    for top in OURS:
        if os.path.isdir(top):
            for path in walk(top):
                # A materialized pin sits INSIDE `src`, so walking `src` reaches upstream
                # code. Counting it as ours is how DARLING_SDK_RELATIVE_PATH ended up on a
                # list of names to rename when it is Apple and Darling upstream.
                full = os.path.normpath(os.path.join(ROOT, path))
                if any(full.startswith(t + os.sep) for t in PIN_TREES):
                    skipped += 1
                    continue
                ours.append(read(path))
    ours = "\n".join(ours)
    print(f"files under {'/'.join(OURS)} skipped as materialized pin content: {skipped}")

    orphaned = []
    for tok, uses in sorted(pin_tokens.items(), key=lambda kv: -kv[1]):
        # DARLING last and separately: the two lowercase substitutions cannot touch an
        # all-caps name, so without this an uppercase token maps to itself, hits the
        # `cider == tok` skip below, and is dropped before any comparison happens.
        cider = (tok.replace("darling", "cider")
                    .replace("Darling", "Cider")
                    .replace("DARLING", "CIDER"))
        if cider == tok:
            continue
        # THE RULE IS "no Cider form AT ALL", not "no Cider form unless a Darling one
        # also survives", and the difference is a negative control that did not fail.
        # Re-breaking __darling_thread_create in ONE of its two files left the other
        # spelling intact, so the weaker rule reported PASS while the build was broken.
        # If upstream references a name, every definition of ours must use it.
        # MACH-O PUTS AN EXTRA UNDERSCORE ON C SYMBOLS, and that hole cost a full endpoint
        # run. The pin defines the hook slots in ASSEMBLY, where the symbol is written
        # __darling_mach_syscall_entry, while our C source declares the same object as
        # _darling_mach_syscall_entry, one underscore fewer. Comparing only the literal
        # token looked for __cider_... in our tree, never found it, and reported PASS while
        # xtracelib_dylib could not link. So an assembly token is also checked with one
        # leading underscore stripped, which is the form C spells it.
        # THE TRAILING BOUNDARY IS LOAD BEARING once the stripped form is in play, and
        # leaving it out produced six false alarms in one run. Our OWN trampolines are
        # _cider_bsd_syscall_entry_trampoline, so a prefix-only search for the stripped
        # _cider_bsd_syscall_entry matches them and reports an orphan that is not one. The
        # original single-form search never hit this because it looked for the DOUBLE
        # underscore, which our C never writes. Match whole identifiers only.
        # AND THE LEADING BOUNDARY HAS ITS OWN HOLE, in the opposite direction from the
        # trailing one above: it cannot match a -D COMPILE DEFINITION. In -DNAME the
        # character before NAME is the D of -D, which IS a word character, so the negative
        # lookbehind refuses. Measured: the plain pattern reports 0 matches on a BUCK file
        # containing -DLIBSIMPLE_DARLING=1 three times, so every -D definition in the tree
        # was invisible to this check and a rename could orphan one while it reported PASS.
        # That is not hypothetical: it happened on 2026-08-10. LIBSIMPLE_DARLING was renamed
        # in lock.c, the -D definition in darwin/libsimple/BUCK was left behind because a
        # rename sweep with this same pattern could not see it, and the guest target died an
        # hour into the endpoint with "linux_futex not implemented for this platform".
        # Allowing -D as a boundary keeps every existing protection: the trailing boundary
        # still rejects _cider_bsd_syscall_entry_trampoline, and a glued prefix like
        # MY_CIDER_NW_STUB is still not a match.
        # THE SUBSTRING TEST FIRST, AND IT IS WHERE ALL THE TIME WENT. This regex opens on an
        # alternation of LOOKBEHINDS, so the engine tests one at every position of `ours`,
        # which is 39 MB. Doing that once per token, 120 times, was the whole cost of this
        # check: 235 s of a 217 to 223 s run. Only SIX of the 120 tokens have their cider form
        # present as a plain substring at all, so 114 full scans could never have matched.
        #
        # SOUND, not merely faster: the regex requires `f` as a substring PLUS the boundary
        # conditions, so a substring miss cannot be a regex hit. Measured both ways over the
        # real tree, 235.3 s against 11.9 s, twenty times faster with IDENTICAL results.
        #
        # Do NOT simplify the pattern itself to speed it up. Both boundaries are load bearing
        # and each was paid for: the trailing one stops _cider_bsd_syscall_entry matching our
        # own _cider_bsd_syscall_entry_trampoline, and the -D lookbehind exists because
        # -DLIBSIMPLE_DARLING=1 was invisible without it and cost an hour-long endpoint run.
        forms = [cider]
        if cider.startswith("__"):
            forms.append(cider[1:])
        hit = next((f for f in forms
                    if f in ours
                    and re.search(r'(?:(?<![A-Za-z0-9_])|(?<=-D))' + re.escape(f)
                                  + r'(?![A-Za-z0-9_])', ours)), None)
        if hit:
            orphaned.append((tok, hit, uses))

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
