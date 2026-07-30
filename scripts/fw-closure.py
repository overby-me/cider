#!/usr/bin/env python3
"""Resolve the transitive framework closure for a set of seed frameworks.

Umbrella frameworks include each other: ApplicationServices.h pulls in
CoreServices/CoreServices.h, which pulls in CarbonCore, and so on. A target that
includes one umbrella therefore needs a whole set of framework header roots, and
adding them one compile error at a time is slow and stops at the first miss.

This reads the generated FRAMEWORKS maps (which say, per framework, what header
paths it exposes and which repo file backs each), scans those headers for
`#include <Framework/Header.h>` / `#import <...>`, and walks the graph.

Usage:
  scripts/fw-closure.py Foundation ApplicationServices        # labels to add
  scripts/fw-closure.py --json Foundation                     # for extra-deps
"""
from __future__ import annotations

import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(REPO, "buck", "generated")

# Which .bzl belongs to which package, and whether it is the private surface
# (those targets are named fwp_* rather than fw_*).
SOURCES = [
    ("sdk_framework_buck_src.bzl", "buck-src", "fw_"),
    ("sdk_framework_private_buck_src.bzl", "buck-src", "fwp_"),
    ("sdk_framework_darwin_frameworks.bzl", "darwin/frameworks", "fw_"),
    ("sdk_framework_private_darwin_private_frameworks.bzl", "darwin/private-frameworks", "fwp_"),
    ("sdk_framework_darwin_Developer.bzl", "darwin/Developer", "fw_"),
    ("sdk_framework_src_CoreAudio.bzl", "src/CoreAudio", "fw_"),
]

INCLUDE_RE = re.compile(r'^\s*#\s*(?:include|import)\s*<([A-Za-z0-9_]+)/([^>]+)>', re.M)


def load_maps():
    """framework -> [(label, {header: repo file}, package)], in declaration order."""
    out: dict[str, list] = {}
    for fname, pkg, prefix in SOURCES:
        path = os.path.join(GEN, fname)
        if not os.path.exists(path):
            continue
        text = open(path).read()
        # The file is a Starlark dict literal of dicts; ast.literal_eval handles it
        # once the assignment head is removed. Anchor on the assignment, not on the
        # first brace -- the leading comment block contains braces of its own.
        head = text.index("FRAMEWORKS = ")
        body = text[text.index("{", head):text.rindex("}") + 1]
        import ast
        data = ast.literal_eval(body)
        for name, hmap in data.items():
            out.setdefault(name, []).append((f"//{pkg}:{prefix}{name}", hmap, pkg))
    return out


def backed(hmap, pkg) -> bool:
    """Whether a framework's headers actually resolve in this working copy.

    The repo's SDK and Developer trees are symlinks into the submodules, which are
    not checked out (the pins under buck-src are what the port compiles against).
    A header_map full of dangling links does not even coerce, so such an entry is
    not a usable dep -- naming it fails analysis for every consumer.
    """
    items = list(hmap.items())
    if not items:
        return False
    # Map values are relative to the package that declares them, not to the repo.
    sample = items[:: max(1, len(items) // 20)][:20]
    have = sum(1 for _h, f in sample if os.path.isfile(os.path.join(REPO, pkg, f)))
    return have == len(sample)


def framework_edges(hmap, pkg, known) -> set:
    """Frameworks the headers of one framework include."""
    deps = set()
    for _hdr, repo_file in hmap.items():
        for base in (os.path.join(REPO, pkg, repo_file), os.path.join(REPO, repo_file)):
            if os.path.isfile(base):
                try:
                    text = open(base, errors="ignore").read()
                except OSError:
                    break
                for fw, _h in INCLUDE_RE.findall(text):
                    if fw in known:
                        deps.add(fw)
                break
    return deps


def main(argv: list[str]) -> int:
    seeds = [a for a in argv[1:] if not a.startswith("--")]
    if not seeds:
        sys.exit(__doc__)
    maps = load_maps()
    unknown = [s for s in seeds if s not in maps]
    if unknown:
        print("# unknown frameworks: " + " ".join(unknown), file=sys.stderr)

    closure, queue = set(), [s for s in seeds if s in maps]
    while queue:
        fw = queue.pop()
        if fw in closure:
            continue
        closure.add(fw)
        for entry in maps[fw]:
            for dep in framework_edges(entry[1], entry[2], maps):
                if dep not in closure:
                    queue.append(dep)

    # Prefer the pins when a framework is declared in more than one package: the
    # pinned copy is what the reference build compiles against. Entries whose
    # headers are not present are skipped, and said so rather than emitted.
    labels, unavailable = [], []
    for fw in sorted(closure):
        entries = [e for e in maps[fw] if backed(e[1], e[2])]
        if not entries:
            unavailable.append(fw)
            continue
        pinned = [e for e in entries if e[2] == "buck-src" and not e[0].endswith("fwp_" + fw)]
        labels.append((pinned or entries)[0][0])
    if unavailable:
        print("# not backed in this working copy, skipped: " + " ".join(unavailable),
              file=sys.stderr)

    if "--json" in argv:
        print(json.dumps(labels, indent=2))
    else:
        print(f"# {len(labels)} frameworks in the closure of {' '.join(seeds)}")
        for label in labels:
            print(f'    "{label}",')
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
