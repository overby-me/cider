#!/usr/bin/env python3
"""An environment variable we tell people to set must be read by something.

WHY THIS EXISTS. DARLING_XTRACE was named in nine places across five scripts: two of them
actually ran `env DARLING_XTRACE=1 cider shell ...` behind a --xtrace flag, the rest printed it
at the user as the way to get a syscall trace. Nothing read it. Not the loader, not the server,
not the launcher, not xtrace itself, not upstream. A search of all 289,836 files in the tree
found the name only in those scripts and in __PTK_DARLING_XTRACE_TLS, which is a pthread
TLS key in xnu, a different namespace entirely.

So the flag was inert. Someone triaging a failing syscall would pass --xtrace, get no trace,
and conclude the tracer was broken or that the syscall was never reached. The failure is silent
and it points the investigation the wrong way, which is the expensive kind.

This is the mirror image of buck-upstream-names-check.py. That one catches a rename that
ORPHANS a name upstream still uses. This one catches a name WE advertise that nothing
implements. Both are about the same underlying mistake, a name whose two ends do not meet.

THE CHECK. In our own namespace only -- CIDER_, CIDERD_, DARLING_, DARLINGSERVER_, XTRACE_ --
every name a user-facing file ADVERTISES must be READ somewhere in first-party code.

ADVERTISED is deliberately narrow: the name appears as an assignment (`NAME=`, with or without
a leading `env`) or as `$env.NAME`, in a file under a directory we use to talk to people or to
drive the build. A bare quoted string is NOT advertising, which is what keeps the upstream
names listed as DATA inside buck-upstream-names-check.py from being flagged.

READ is deliberately wide, because there are many ways to consume a variable and treating any
of them as unread produces a false positive:

    getenv("X")            C and Objective-C
    env::var("X")          Rust, Result
    env("X")               the bare helper in linux/server
    env!("X")              Rust compile-time, fed by the BUCK env attribute, NOT by build.rs
    os.environ / getenv    Python, both the .get and the subscript forms
    $env.X                 nushell
    $X, ${X}, ${X[@]}      POSIX expansion, including the ARRAY subscript form
    envp_set(.., "X")      xtrace propagating its settings into a child
    "X": in a BUCK file    the env attribute that feeds env!()
    #define X              not an environment variable at all, but a C macro sharing the
                           namespace: XTRACE_INLINE, XTRACE_HIDDEN, the include guards

WHY THE WIDTH MATTERS, measured rather than assumed. A first pass recognising only the first
four idioms reported 39 names, 38 of them false: C macros in darwin/xtrace, the CIDER_GIT_* pair
the launcher reads through env!(), and script-local names consumed by POSIX expansion. Widening
it left three, and TWO OF THOSE THREE WERE STILL FALSE, each for its own reason worth keeping:

  DARLING_CMD is a bash ARRAY. It is assigned as DARLING_CMD=(cider) and read as
  ${DARLING_CMD[@]}, so a ${NAME} pattern anchored on : or } misses it. The subscript is a read.

  DARLING_EMIT_TARGET_SOURCES is read by os.environ.get, a Python idiom absent from the first
  list entirely.

Both looked exactly like the real defect until the file was opened. That is the whole lesson:
an unrecognised idiom and an unimplemented variable are indistinguishable from the outside, so
every name this reports has to be read in its file before it is believed, and every idiom the
project actually uses has to be in the list above or the report is fiction of its own.

A check reporting 39 problems of which 38 are noise is a check nobody runs, and this project has
already been bitten by exactly that: buck-pin-rev-check.py flagged 143 unrelated trees in its
first form and its exit code proved nothing about the one defect planted in it.

THIS FILE EXCLUDES ITSELF from the advertising side, and that is not a convenience. Its
docstring has to name the fiction it hunts in order to explain it, which would make the check
report itself for ever and turn a green result into an impossibility. A check that cannot pass
is as worthless as one that cannot fail.

THE NEGATIVE CONTROL IS THE TREE ITSELF. Before the DARLING_XTRACE fix this check reported
exactly one name, the real one, and no others. That is a stronger control than a planted fault,
because the thing it caught was found independently and was the ONLY thing that fired. Use
--expect-fiction to assert that a named variable is still detected, which is what makes a
regression of the check itself visible.

Exit 0 if every advertised name is read, 1 otherwise.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OURS = re.compile(r"^(?:CIDER|CIDERD|DARLING|DARLINGSERVER|XTRACE)_[A-Z0-9_]+$")

# Where we talk to people or drive the build. src/, darwin/ and linux/ are deliberately absent:
# a C macro is not an advertisement, and those trees are where the macros live.
ADVERTISING_DIRS = ["scripts", "tests", "docs", "nix", "etc", "tools", "plan"]
ADVERTISING_FILES = ["PLAN.md", "README.md", "flake.nix"]

# Everything first-party, for the read side. Pins are excluded: they are upstream, they cannot
# implement a name we invented, and walking them costs far more than the check is worth.
READING_DIRS = ["src", "darwin", "linux", "scripts", "nix", "tests", "buck", "tools", "etc"]

SKIP_DIRS = {".jj", ".git", "buck-out", "target", "__pycache__", "node_modules",
             "result", "outputs", "build", "buck-rust", "buck-src"}
SKIP_PREFIX = ("src/external/",)

ADVERTISE = [
    re.compile(r"\b((?:CIDER|CIDERD|DARLING|DARLINGSERVER|XTRACE)_[A-Z0-9_]+)\s*="),
    re.compile(r"\$env\.((?:CIDER|CIDERD|DARLING|DARLINGSERVER|XTRACE)_[A-Z0-9_]+)"),
]

READS = [
    re.compile(r'getenv\s*\(\s*"([A-Z0-9_]+)"'),
    re.compile(r'env::var\s*\(\s*"([A-Z0-9_]+)"'),
    re.compile(r'\benv!\s*\(\s*"([A-Z0-9_]+)"'),
    re.compile(r'\benv\s*\(\s*"([A-Z0-9_]+)"'),
    re.compile(r'envp_set\s*\([^,]+,\s*"([A-Z0-9_]+)"'),
    re.compile(r'os\.environ(?:\.get)?\s*[\(\[]\s*"([A-Z0-9_]+)"'),
    re.compile(r"\$env\.([A-Z0-9_]+)"),
    re.compile(r"\$\{([A-Z0-9_]+)[:\}\[]"),     # ${X}, ${X:-}, and the ARRAY form ${X[@]}
    re.compile(r"\$([A-Z0-9_]+)\b"),
    re.compile(r'"([A-Z0-9_]+)"\s*:'),          # the BUCK env attribute that feeds env!()
    re.compile(r"^\s*#\s*(?:define|ifdef|ifndef)\s+([A-Z0-9_]+)", re.M),
]

MAX_BYTES = 2_000_000


def walk(bases, files=()):
    for base in bases:
        d = os.path.join(ROOT, base)
        if not os.path.isdir(d):
            continue
        for dp, dn, fn in os.walk(d):
            dn[:] = [x for x in dn if x not in SKIP_DIRS]
            rel_dir = os.path.relpath(dp, ROOT)
            if any(rel_dir.startswith(p) for p in SKIP_PREFIX):
                continue
            for f in fn:
                p = os.path.join(dp, f)
                if os.path.islink(p):
                    continue
                try:
                    if os.path.getsize(p) > MAX_BYTES:
                        continue
                    yield os.path.relpath(p, ROOT), open(
                        p, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
    for f in files:
        p = os.path.join(ROOT, f)
        if os.path.isfile(p):
            try:
                yield f, open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expect-fiction", metavar="NAME",
                    help="assert this name IS reported, to prove the check still fires")
    ap.add_argument("--list-read", action="store_true",
                    help="print every name found to be read, to inspect the read side")
    a = ap.parse_args()

    read = {}
    for rel, text in walk(READING_DIRS):
        for rx in READS:
            for m in rx.finditer(text):
                n = m.group(1)
                if OURS.match(n):
                    read.setdefault(n, set()).add(rel)

    me = os.path.relpath(os.path.abspath(__file__), ROOT)
    advertised = {}
    for rel, text in walk(ADVERTISING_DIRS, ADVERTISING_FILES):
        if rel == me:
            continue                             # see the docstring: it must name the fiction
        for rx in ADVERTISE:
            for m in rx.finditer(text):
                n = m.group(1)
                if OURS.match(n):
                    advertised.setdefault(n, set()).add(rel)

    if a.list_read:
        for n in sorted(read):
            print(f"  read: {n:34s} {sorted(read[n])[0]}")

    fiction = {n: v for n, v in advertised.items() if n not in read}

    print(f"names advertised in our namespace: {len(advertised)}; "
          f"read somewhere in first-party code: {len(read)}; "
          f"advertised but read by nothing: {len(fiction)}")

    if a.expect_fiction:
        if a.expect_fiction in fiction:
            print(f"PASS: {a.expect_fiction} is still detected as advertised-but-unread, "
                  f"so the check can fire")
            return 0
        why = "it is read somewhere" if a.expect_fiction in read else "it is not advertised"
        print(f"FAIL: expected {a.expect_fiction} to be reported and it was not, because "
              f"{why}. The check has stopped being able to detect this class.")
        return 1

    if not fiction:
        print("PASS: every advertised environment variable is read by something")
        return 0

    print(f"\n{len(fiction)} advertised names that nothing reads:")
    for n in sorted(fiction):
        where = ", ".join(sorted(fiction[n])[:4])
        print(f"  {n} -- set or documented in {where}")
    print("\nFAIL: setting one of these does nothing. A flag that silently has no effect sends "
          "an investigation the wrong way, which is how DARLING_XTRACE survived in nine places "
          "across five scripts without ever having been implemented.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
