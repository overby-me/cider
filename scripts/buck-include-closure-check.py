#!/usr/bin/env python3
"""Does the dumped source union cover every quoted include a COMPILED file makes?

The narrowed per-target source set (narrowSources) is built from what buck2 DECLARES, and
a quoted include resolves against the including file's own directory, which buck2 never
declares. Miss one and the narrowed build dies late with "file not found", 90 minutes in.
scripts/buck2-graph-dump.py closes that by taking the closure of quoted includes; this
checks the closure actually holds, in ten seconds, against a built graph.

The comment at projectSrc in the lowering used to claim only DEPFILES could answer this.
Measured, that is false for this tree: of the 64,903 C-family files in the union, 734 hold
a quoted ../ include and 93 were uncovered, of which 40 named a file that does not exist
(guarded out, cannot break a compile) and 48 of the surviving 53 belonged to vim, whose GUI
has ZERO compile actions here. The real gap was five files.

Usage:
  scripts/buck-include-closure-check.py <graph-store-path> <sources-store-path>

Two paths since #56: the graph holds the actions, and the source closure is its own
derivation over the real tree, because parsing a quoted include is the one thing here that
reads file CONTENTS and the graph is now dumped from a skeleton.

Exit 0 when every compiled file's quoted includes are covered, 1 when any is not, 2 on
infrastructure trouble.

VERIFIED BOTH WAYS, which is the only reason to trust it: run against a graph dumped
BEFORE the closure landed and it reports the five files (cctools/as/hppa-opcode.h,
i860-opcode.h and sparc-opcode.h for the three otool disassemblers, man/man/catopen/
catopen.c for gripes.c, which is a .c and not a header, and the OpenDirectory
generated-stubs.h); run it against one dumped after and it reports none.
"""
import json
import os
import re
import subprocess
import sys

C_FAMILY = (".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".h", ".hpp", ".hh", ".inc")
QUOTED = re.compile(rb'^[ \t]*#[ \t]*include[ \t]*"([^"]+)"', re.M)


def project_sources(sources: str) -> list:
    """The union, straight out of sources.json.

    It used to be sliced out of graph.json by line offset, because that file is 481 MB and
    parsing it to read one array was not worth it. Since #56 the union is a small file of
    its own, so it is just read.
    """
    path = os.path.join(sources, "sources.json")
    if not os.path.exists(path):
        print(f"no sources.json in {sources}; pass the cider-buck2-sources output, not "
              f"the graph", file=sys.stderr)
        raise SystemExit(2)
    with open(path) as fh:
        return json.load(fh)["projectSources"]


def compiled_basenames(graph: str) -> set:
    """Basenames that own a compile action, so a file nobody builds cannot fail the check.

    Count the identity FIELD, not a loose string match: the identity appears in more than
    one place per action and grepping loosely over-counts threefold.
    """
    path = os.path.join(graph, "graph.json")
    out = subprocess.run(
        ["grep", "-o", r'_compile [^"]*'], stdin=open(path), capture_output=True, text=True
    ).stdout
    names = set()
    for line in out.splitlines():
        tok = line.split(" ", 1)[1] if " " in line else ""
        tok = tok.rstrip(")")
        if tok:
            names.add(os.path.basename(tok))
    return names


def main(argv: list) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("usage: buck-include-closure-check.py <graph-store-path> <sources-store-path>",
              file=sys.stderr)
        return 2
    graph, sources = argv[1], argv[2]
    root = os.path.dirname(os.path.abspath(__file__))
    os.chdir(os.path.join(root, ".."))

    srcs = project_sources(sources)
    declared = set(srcs)
    # The filter also keeps the DIRECTORY of every declared file, so a sibling is covered.
    dirs = {os.path.dirname(p) for p in declared}
    compiled = compiled_basenames(graph)
    print(f"{len(srcs)} declared source(s), {len(compiled)} compiled basename(s)")

    gaps = []
    for rel in srcs:
        if not rel.endswith(C_FAMILY):
            continue
        if os.path.basename(rel) not in compiled:
            continue                      # never compiled, its includes cannot break a build
        try:
            with open(rel, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        base = os.path.dirname(rel)
        for m in QUOTED.finditer(data):
            target = m.group(1).decode("utf-8", "replace")
            res = os.path.normpath(os.path.join(base, target))
            if res.startswith(".."):
                continue                  # leaves the project: a system header by another name
            if res in declared or os.path.dirname(res) in dirs:
                continue
            if not os.path.exists(res):
                continue                  # guarded out by the preprocessor
            gaps.append((rel, res))

    if not gaps:
        print("PASS: every compiled file's quoted includes are in the union")
        return 0
    print(f"FAIL: {len(gaps)} quoted include(s) a COMPILED file makes are not in the union")
    for a, b in sorted(gaps):
        print(f"  {a}\n      needs {b}")
    print("")
    print("The dump should close these; see coarse target_sources and _quoted_includes in")
    print("scripts/buck2-graph-dump.py, and task #44.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
