#!/usr/bin/env python3
"""#87 stage 2: move src/external to pins/, rewriting ONLY what is genuinely a reference.

DRY RUN IS THE DEFAULT AND --apply IS PARSED EXPLICITLY. An earlier script in this repo
treated an unrecognised --dry-run as consent and wrote 98 files, so unknown arguments are a
hard error here rather than something to guess at.

THE RULE IS LABEL-FIRST, NOT PATH-FIRST, and that is the whole point of this file.

A blanket rewrite of the string "src/external" corrupts far more than it fixes. Measured on
this tree: buck-src/ alone carries 1,854 mentions and only 172 of them are ours.

     979   # cmake target: X  ->  src/external/...     FROZEN pragma      LEAVE
     699   #   src/external/...                        the provenance source list that
                                                       follows each pragma                LEAVE
     172   "//src/external/ciderd:dserver_headers"     REAL BUCK2 LABEL   REWRITE
       4   "/build/build/src/external/SecurityTokend/mig"
                                                       cmake BINARY DIR   LEAVE

Rewriting those 1,682 frozen lines would break nothing at build time and would silently stop
coverage finding its reference paths, which is the expensive kind of failure. So this script
rewrites four specific things and reports everything it declines to touch:

  1. LABELS          //src/external/<x>  ->  //pins/<x>          (also root//src/external/...)
  2. MANIFEST        the "path" field of nix/submodules.json, handled as JSON, not as text
  3. LIVE PATHS      a quoted or bare src/external/<x> in .nix, .py, .nu, .sh, .rs, .json
                     and .gitignore, EXCLUDING the frozen and historical lines below
  4. nothing else

NEVER TOUCHED:
  untracked files          materialized pins (.gitignore:115) and linux/server/target
                           (linux/server/.gitignore:1). Asking the repo what it tracks
                           excludes these by construction. A filesystem walk reported 945
                           references where the repo holds 545, because one generated file,
                           xnu/gen/bsdsyscalls/stubs.list, holds 430 of them by itself.
  "# cmake target:" and "buck-registry:"    the FROZEN REFERENCE path space
  "previously the submodule"                VENDORED.md sentences about the PAST
  "/build/build/"                           the cmake BINARY DIR path space
  PLAN.md                                   34 hits mixing current layout with past failures;
                                            only a reader can tell which is which
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OLD, NEW = "src/external", "pins"
MANIFEST = os.path.join("nix", "submodules.json")

# THIS FILE EXCLUDES ITSELF, and that is not a convenience. Its docstring has to quote the
# old spelling in order to explain which lines are frozen and why, so a sweep that rewrote it
# would destroy the explanation of what the sweep does. Same reason buck-env-names-check.py
# excludes itself from its own advertising side.
SELF = os.path.join("scripts", os.path.basename(__file__))

SKIP_FILES = {"PLAN.md", MANIFEST, SELF}
SKIP_REL_PREFIX = ("linux/server/target/",)

# Lines that mention the string but must keep the old spelling.
FROZEN_LINE = re.compile(r"#\s*cmake target:|buck-registry:|/build/build/|previously the submodule")

LABEL = re.compile(r"(root)?//" + re.escape(OLD) + r"(?=[/:])")
PATH = re.compile(r"(?<![\w/.-])" + re.escape(OLD) + r"(?=[/\"'\s:,)\]}]|$)")

REWRITE_EXT = {".nix", ".py", ".nu", ".sh", ".rs", ".json", ".md", ".toml", ".bzl", ""}


def tracked_files() -> list[str]:
    r = subprocess.run(["jj", "file", "list"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAIL: could not list tracked files: {r.stderr.strip()[:200]}")
    rels = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    if not rels:
        sys.exit("FAIL: the tracked file list is EMPTY, refusing to report a vacuous zero")
    return rels


def rewrite_line(line: str, is_build: bool) -> tuple[str, int, int]:
    """Return (new_line, labels_rewritten, paths_rewritten)."""
    if FROZEN_LINE.search(line):
        return line, 0, 0
    new, nlab = LABEL.subn(lambda m: (m.group(1) or "") + "//" + NEW, line)
    npath = 0
    # A bare path inside a BUCK or bzl file is PACKAGE relative, so only labels move there.
    if not is_build:
        new, npath = PATH.subn(NEW, new)
    return new, nlab, npath


def main(argv: list[str]) -> int:
    apply = False
    for a in argv:
        if a == "--apply":
            apply = True
        elif a in ("--dry-run", "-n"):
            apply = False
        else:
            print(f"FAIL: unrecognised argument {a!r}. Only --apply or --dry-run.",
                  file=sys.stderr)
            return 2

    labels = paths = 0
    left_frozen = 0
    touched: list[tuple[str, int, int]] = []

    for rel in tracked_files():
        p = os.path.join(ROOT, rel)
        if os.path.islink(p) or not os.path.isfile(p) or rel in SKIP_FILES:
            continue
        if any(rel.startswith(pref) for pref in SKIP_REL_PREFIX):
            continue
        ext = os.path.splitext(rel)[1]
        base = os.path.basename(rel)
        is_build = base == "BUCK" or ext == ".bzl"
        if not (is_build or ext in REWRITE_EXT):
            continue
        try:
            text = open(p, errors="ignore").read()
        except Exception:
            continue
        if OLD not in text:
            continue
        out, flab, fpath = [], 0, 0
        for line in text.split("\n"):
            if FROZEN_LINE.search(line) and OLD in line:
                left_frozen += 1
            new, a_, b_ = rewrite_line(line, is_build)
            out.append(new)
            flab += a_
            fpath += b_
        if flab or fpath:
            touched.append((rel, flab, fpath))
            labels += flab
            paths += fpath
            if apply:
                open(p, "w").write("\n".join(out))

    # The manifest, as JSON so that only a real path field moves.
    mrel, mp = MANIFEST, os.path.join(ROOT, MANIFEST)
    mcount = 0
    if os.path.exists(mp):
        data = json.load(open(mp))
        for e in data:
            if isinstance(e, dict) and e.get("path", "").startswith(OLD + "/"):
                mcount += 1
                if apply:
                    e["path"] = NEW + e["path"][len(OLD):]
        if apply and mcount:
            open(mp, "w").write(json.dumps(data, indent=2) + "\n")

    verb = "REWROTE" if apply else "would rewrite"
    print(f"{verb}: {labels} label(s), {paths} live path(s), {mcount} manifest entry(ies)")
    print(f"LEFT ALONE: {left_frozen} frozen / historical / binary-dir line(s)")
    print(f"files affected: {len(touched)}")
    for rel, a_, b_ in sorted(touched, key=lambda x: -(x[1] + x[2]))[:20]:
        print(f"    labels={a_:4d} paths={b_:4d}  {rel}")
    if not apply:
        print("\nDRY RUN. Nothing was written. PLAN.md and the manifest text are excluded; "
              "pass --apply to write.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
