#!/usr/bin/env python3
"""Move first-party subdirectories out of src/ into darwin/ or linux/, and repoint every
reference to them. Task #87 stage 1.

SAFE BY DEFAULT. This prints what it would do and changes nothing unless --apply is passed.
That is not politeness: a script in this repo with no argv parsing once treated --dry-run as
consent and wrote 98 files, so the default here has to be the harmless one.

WHY A SCRIPT RATHER THAN A SED SWEEP. The reference surface for the full move is 1,208
occurrences across 130 files, and the wrong ones are not obvious:

  patches/ is EXCLUDED and that was established by reading, not assumed. patches/xnu/0005 has
  a line reading "# include " then the OLD startup path then " for rtsig.h", with a LEADING
  SPACE, which makes it a CONTEXT line of a unified diff. Rewriting a context line stops the
  patch applying. It is also inert prose in an upstream cmake file, and cmake left in #82.

  src/external/ and buck-src/ are excluded for their CONTENT, because those are the 148 vendored
  upstreams and a pin tree is where a careless rewrite does the most damage. But a BUCK or .bzl
  file is OURS wherever it sits, and excluding those trees wholesale was wrong: the first run
  left 56 labels dangling in buck-src/BUCK, buck-src/ruby/BUCK, buck-src/xnu/BUCK and
  src/external/ciderd/tools/BUCK, all four of them tracked files of ours that name first-party
  targets. buck-labels-check.py caught every one, which is the whole reason it exists. So build
  files are rewritten everywhere and only upstream SOURCE is left alone.

  Longest name first. The lib, libm, libsimple and libelfloader directories all share a prefix,
  so the alternation is sorted by length descending and anchored with a trailing word boundary.
  Without that the shorter name eats the front of the longer one and produces darwin/lib + m
  where darwin/libm was meant.

  AND THIS FILE REWROTE ITS OWN DOCSTRING THE FIRST TIME IT RAN. It lives in scripts/, which is
  in scope, so prose QUOTING an old path was repointed along with real references and became a
  false statement about a file deliberately left alone. That is why the two paragraphs above now
  describe those paths instead of spelling them. A rewriting tool inside its own blast radius
  cannot quote what it is rewriting.

THE STRUCTURAL PART IS ALREADY SAFE, verified in nix/lib/ciderBuck2Lower.nix before moving
anything. stageProject symlinks every top-level entry of projectSrc into the staged tree except
buck-src, buck-out, src and buck-rust; src is excluded so that pins can be planted at
src/external/<pin>, which needs src/ to be a REAL directory rather than a store symlink. And
pinStageLines keys on the three-component src/external/<pin> shape. Stage 1 leaves src/external
alone, so both survive untouched, and the moved trees travel inside darwin/ and linux/, which
are already symlinked wholesale exactly as darwin/ is today.

Usage:
  scripts/buck-move-src-subdir.py --group linux            # dry run, the default
  scripts/buck-move-src-subdir.py --group linux --apply
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TO_LINUX = ["bsdln", "buildtools", "hosttools", "libelfloader", "startup", "native"]

TO_DARWIN = [
    "CoreAudio", "MobileKeyBag", "OpenDirectoryOld", "OpenScripting", "PlistBuddy",
    "VideoDecodeAcceleration", "clt", "crash", "dirserv", "diskutil", "ditto", "duct",
    "include", "launchd", "lib", "libDiagnosticMessagesClient", "libMobileGestalt",
    "libaccessibility", "libacm", "libaks", "libcache", "libcompression", "libcrashhandler",
    "libgcc", "libgmalloc", "libm", "libpmenergy", "libquit", "libsandbox", "libsimple",
    "libsysmon", "libsystem_coreservices", "networkextension", "opendirectory_internal",
    "pboard", "quarantine", "sandbox", "sandbox-exec", "shellspawn", "simd", "softlinking",
    "tools", "unxip", "vchroot", "xcselect", "xtrace",
]

GROUPS = {"linux": (TO_LINUX, "linux"), "darwin": (TO_DARWIN, "darwin")}

SKIP_DIRS = {".jj", ".git", "buck-out", "buck-src", "buck-rust", "target", "outputs",
             "build", "__pycache__", "result", "result-ld64", "result-graph-ref",
             "result-ducttape-ref", "node_modules", ".direnv"}

# Excluded from REWRITING, for the reasons in the docstring. Not excluded from moving.
SKIP_REL_PREFIX = ("patches/", "src/external/")

MAX_BYTES = 4_000_000


def rewrite_pattern(names):
    """src/<name> where src/ is a whole path component, not the tail of a longer one.

    THE LEADING LOOKBEHIND IS LOAD BEARING and a self-test caught its absence. Without it the
    pattern matches src/ INSIDE a longer token, so mysrc/libm became mydarwin/libm -- and far
    worse, buck-src/ ends in src/, so buck-src/<name> would have been rewritten to
    buck-darwin/<name> for any pin sharing a name with a moving directory. The linux group
    escaped that only by luck, since none of its six names is also a pin, but the darwin group
    has lib, include, tools, sandbox and crash, which are exactly the names a vendored tree
    tends to use.
    """
    alts = "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))
    return re.compile(r"(?<![\w.\-/])src/(" + alts + r")(?![\w.\-])")


def is_build_file(name):
    """Ours wherever it lives, including inside a pin. See the docstring."""
    return name == "BUCK" or name.endswith(".bzl")


def label_pattern(names):
    """Inside a PIN tree, only a LABEL is ours. A bare path there is PIN-RELATIVE.

    This cost a graph build. buck-src/BUCK carries both: labels like //src/<name>:target, which
    point at our packages and must move, and source attributes like <pin>/src/tools/c_hash,
    where src is the PIN's own directory and means nothing to us. The full pattern rewrote both,
    and buck2 stopped with a source file that does not exist as a member of the package.

    The leading anchor was not enough, because it only refuses src/ glued to the END of a longer
    token, and here the offending path has a whole pin component in front of it followed by a
    slash. Depth is the discriminator, not adjacency: repo-relative only means anything at the
    package root, and inside a pin nothing is repo-relative except a label.
    """
    alts = "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))
    return re.compile(r"(?<=//)src/(" + alts + r")(?![\w.\-])")


def iter_files():
    seen = set()
    for dp, dn, fn in os.walk(ROOT):
        # Descend into the excluded trees, but only to reach OUR build files inside them.
        excluded_here = [d for d in dn if d in SKIP_DIRS]
        dn[:] = [d for d in dn if d not in SKIP_DIRS]
        for f in fn:
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, ROOT)
            if os.path.islink(p):
                continue
            if rel.startswith(SKIP_REL_PREFIX) and not is_build_file(f):
                continue
            try:
                if os.path.getsize(p) > MAX_BYTES:
                    continue
            except OSError:
                continue
            seen.add(rel)
            yield p, rel
        for d in excluded_here:
            for dp2, dn2, fn2 in os.walk(os.path.join(dp, d)):
                for f in fn2:
                    if not is_build_file(f):
                        continue
                    p = os.path.join(dp2, f)
                    rel = os.path.relpath(p, ROOT)
                    if os.path.islink(p) or rel in seen:
                        continue
                    try:
                        if os.path.getsize(p) > MAX_BYTES:
                            continue
                    except OSError:
                        continue
                    seen.add(rel)
                    yield p, rel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", choices=sorted(GROUPS), required=True)
    ap.add_argument("--apply", action="store_true",
                    help="actually move and rewrite; without it nothing is changed")
    ap.add_argument("--rewrite-only", action="store_true",
                    help="skip the move, repoint references only, for a tree already moved")
    a = ap.parse_args()

    names, dest = GROUPS[a.group]
    pat = rewrite_pattern(names)

    missing = [n for n in names if not os.path.isdir(os.path.join(ROOT, "src", n))]
    if missing and not a.rewrite_only:
        print(f"FAIL: not in src/: {missing}. Refusing to run on a tree that does not match "
              f"the mapping this was written against.")
        return 1

    lpat = label_pattern(names)
    edits = {}
    for p, rel in iter_files():
        try:
            with open(p, encoding="utf-8", errors="strict") as fh:
                t = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        # A LABEL is ours anywhere. A BARE path is ours only where the path space is the repo,
        # and never inside a pin tree, where it is relative to the pin instead.
        n = len(lpat.findall(t))
        new = lpat.sub(rf"{dest}/\1", t)
        if not (rel.startswith(SKIP_REL_PREFIX) or rel.startswith("buck-src/")
                or is_build_file(os.path.basename(rel))):
            n += len(pat.findall(new))
            new = pat.sub(rf"{dest}/\1", new)
        if n:
            edits[rel] = (n, new)

    total = sum(n for n, _ in edits.values())
    print(f"group {a.group}: {len(names)} directories -> {dest}/")
    print(f"references to repoint: {total} in {len(edits)} files")
    for rel in sorted(edits, key=lambda r: -edits[r][0])[:12]:
        print(f"   {edits[rel][0]:5d}  {rel}")
    if len(edits) > 12:
        print(f"   ... and {len(edits) - 12} more files")

    if not a.apply:
        print("\nDRY RUN. Nothing was changed. Pass --apply to perform the move.")
        return 0

    if not a.rewrite_only:
        for n in names:
            src = os.path.join(ROOT, "src", n)
            dst = os.path.join(ROOT, dest, n)
            if os.path.exists(dst):
                print(f"FAIL: {dest}/{n} already exists, refusing to overwrite")
                return 1
            subprocess.run(["mv", src, dst], check=True)
            print(f"  moved src/{n} -> {dest}/{n}")

    # SYMLINK TARGETS ARE REFERENCES TOO, and missing them is what broke rung 1 the first time.
    # The rewrite pass skips symlinks so it never follows one out of the tree, but that also
    # meant their TARGETS were never repointed: three SDK links still pointed at the old startup
    # path, and buck2 failed with a File-not-found naming the OLD elfcalls threads header as
    # included in the SDK usr/include BUCK package. (Spelled out rather than quoted: this file
    # is inside its own blast radius, and the first version of this very comment quoted the
    # error and was rewritten by the next run into a false one.) The darwin group has 65 of
    # these against the linux group's 3, so this is the difference between working and not.
    #
    # Only the FIRST component changes, so the ../ depth is untouched and a relative target that
    # resolved before still resolves.
    # A SYMLINK TARGET IS RESOLVED, NOT PATTERN MATCHED, and that distinction is the whole
    # reason this is separate code. Targets are relative and full of ../, so src/ in one is
    # ALWAYS preceded by a slash -- the same slash the bare pattern must refuse in order to
    # leave pin-relative paths like <pin>/src/tools alone. Matching text here found 0 of the 65
    # links that needed moving while claiming success. Resolving the target against the link's
    # own directory and asking where it LANDS answers the question the pattern cannot.
    root_real = os.path.realpath(ROOT)
    relinked = 0
    for dp, dn, fn in os.walk(ROOT):
        dn[:] = [d for d in dn if d not in {".jj", ".git", "buck-out", "target", "outputs",
                                            "build", "__pycache__", "buck-rust"}]
        for f in fn + dn:
            p = os.path.join(dp, f)
            if not os.path.islink(p):
                continue
            try:
                t = os.readlink(p)
            except OSError:
                continue
            landing = t if os.path.isabs(t) else os.path.join(os.path.dirname(p), t)
            landing = os.path.normpath(landing)
            if not landing.startswith(root_real + os.sep):
                continue
            parts = landing[len(root_real) + 1:].split("/")
            if len(parts) < 2 or parts[0] != "src" or parts[1] not in names:
                continue
            # Only the first component changes, so the ../ depth stays correct.
            nt = t.replace("src/" + parts[1], f"{dest}/{parts[1]}", 1)
            if nt != t:
                os.remove(p)
                os.symlink(nt, p)
                relinked += 1
    print(f"  repointed {relinked} symlink target(s)")

    for rel, (_, newtext) in edits.items():
        # A moved file is now under its new path; rewrite there instead.
        target = rel
        for n in names:
            if rel.startswith(f"src/{n}/"):
                target = f"{dest}/" + rel[len("src/"):]
                break
        with open(os.path.join(ROOT, target), "w", encoding="utf-8") as fh:
            fh.write(newtext)
    print(f"\nrewrote {len(edits)} files, {total} references")

    # SELF CHECK, because five separate bugs in this tool were all the same mistake: matching the
    # TEXT of a path when the question was which path space it lives in. Each cost a build to
    # find, and each is cheap to detect here.
    #
    # A moved DIRECTORY reference is <dest>/<name> followed by a separator. <dest>/<name>.<ext>
    # is a FILE that merely shares the name, and rewriting one is always wrong: it produced
    # darwin/launchd.h out of a header in the launchd package's own src/, and darwin/lib.rs out
    # of a Rust crate root. buck2 reports these as a source file that does not exist as a member
    # of a package, which names the symptom rather than the rename that caused it.
    fileish = re.compile(r"(?<![\w.\-/])" + dest + r"/(" + "|".join(
        re.escape(n) for n in sorted(names, key=len, reverse=True)) + r")\.[A-Za-z]")
    suspect = []
    me = os.path.relpath(os.path.abspath(__file__), ROOT)
    for p, rel in iter_files():
        if rel == me:
            continue        # this file DESCRIBES the shape, so it necessarily contains it
        try:
            with open(p, encoding="utf-8", errors="strict") as fh:
                t = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        for mm in fileish.finditer(t):
            suspect.append((rel, mm.group(0)))
    if suspect:
        print(f"\nWARNING: {len(suspect)} reference(s) look like a FILE that shares a moved "
              f"directory name, which a rewrite must never touch:")
        for rel, s in suspect[:10]:
            print(f"  {rel}: {s}")
        return 1
    print("self check: no reference names a file that merely shares a moved directory name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
