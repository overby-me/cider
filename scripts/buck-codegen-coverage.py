#!/usr/bin/env python3
"""Is every file the reference GENERATES accounted for by the port?

buck-coverage.nu counts LINK edges. The reference also has thousands of CUSTOM_COMMAND
edges -- mig, bison, flex, configure_file, script generators -- and the worry recorded
against them was that a generated file which nothing compiles could be silently absent,
with no check anywhere that would notice.

This tests that worry rather than restating it. Every generated output is classified:

  compiled   an input to a compile or link edge. A missing one FAILS THE BUILD, and
             `buck2 build //...` is green, so these are covered -- by implication, but
             the implication is sound.
  installed  named by an install entry. gen-install-from-manifests.py resolves every one
             of those to a target and reports UNMAPPED otherwise, currently 0.
  header     a .h/.hpp/.def/.defs/.modulemap. Reached by #include rather than by name, so
             it has no edge pointing at it -- but a missing one fails the compile of
             whatever includes it, and again the build is green.
  neither    the actual risk set: generated, not built against, not installed. These are
             the only ones where absence would be silent.

Usage:  scripts/buck-codegen-coverage.py [--list]
"""
from __future__ import annotations

import importlib.util
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HEADER_SUFFIXES = (".h", ".hpp", ".hh", ".inc", ".def", ".defs", ".modulemap", ".pch")

# cmake's own targets, emitted as CUSTOM_COMMAND but not files any build produces:
# edit_cache, rebuild_cache, install, and CTest's Nightly/Continuous/Experimental set.
# 3345 of the 4035 "generated outputs" are these, and counting them as a coverage gap is
# what made the first version of this number meaningless.
CMAKE_TARGETS = ("CMakeFiles/uninstall", "CMakeFiles/xcproj_symlinks")


def is_cmake_bookkeeping(path: str) -> bool:
    if path.endswith(".util") or path in CMAKE_TARGETS:
        return True
    base = os.path.basename(os.path.dirname(path)) + "/" + os.path.basename(path)
    return base.startswith("CMakeFiles/") and any(
        os.path.basename(path).startswith(p)
        for p in ("Nightly", "Continuous", "Experimental"))


def load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, "scripts", path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv: list[str]) -> int:
    gen = load("gen", "gen-buck-from-ninja.py")
    inst = load("inst", "gen-install-from-manifests.py")

    # PARSED HERE rather than through gen.read_edges(), which keeps ORDER-ONLY deps in its
    # input list. That distinction is the whole measurement: cmake gives every target a
    # `cmake_object_order_depends_target_X` phony that lists EVERY generated file the
    # target might use, and those arrive after `||`. Counting them as consumption made all
    # 4035 outputs look consumed and the metric say nothing at all.
    #
    # Ninja's grammar is `build outs | implicit_outs: rule ins | implicit_deps || order_only`.
    # Explicit and implicit inputs are things the command actually reads. Order-only is
    # sequencing, and a file that appears ONLY there is not evidence of use.
    generated: set = set()
    consumed: set = set()
    with open(gen.GRAPH) as f:
        for line in f:
            if not line.startswith("build "):
                continue
            head, _, rest = line[len("build "):].rstrip("\n").partition(": ")
            rule, _, deps = rest.partition(" ")
            outs = head.split(" | ")[0].split()
            real = deps.split(" || ")[0]
            if rule == "CUSTOM_COMMAND":
                generated.update(outs)
            if rule != "phony":
                # NORMALIZED, because the two sides spell the same file differently: a
                # CUSTOM_COMMAND declares its output relative to the build dir
                # (pins/WTF/...), while the compile edge that reads it names the
                # same file absolutely (/build/build/src/external/WTF/...). Comparing them
                # raw put all but one generated source in the wrong bucket.
                for i in real.split():
                    if i == "|":
                        continue
                    consumed.add(i[len("/build/build/"):] if i.startswith("/build/build/") else i)

    # Install sources are absolute build-dir paths; the graph names them relative.
    installed: set = set()
    for dest, _kind, files, _ex in inst.read_entries(inst.graph_dir([])):
        for src in files:
            rel = inst.build_rel(src) if src else None
            if rel:
                installed.add(rel)

    buckets = {"consumed": [], "installed": [], "header": [], "cmake": [], "unconsumed": []}
    for g in sorted(generated):
        if g in consumed:
            buckets["consumed"].append(g)
        elif g in installed:
            buckets["installed"].append(g)
        elif g.endswith(HEADER_SUFFIXES):
            buckets["header"].append(g)
        elif is_cmake_bookkeeping(g):
            buckets["cmake"].append(g)
        else:
            buckets["unconsumed"].append(g)

    print(f"generated outputs: {len(generated)}")
    for k in ("consumed", "installed", "header", "cmake", "unconsumed"):
        print(f"  {k:12} {len(buckets[k]):5d}")
    if "--list" in argv:
        for n in buckets["unconsumed"]:
            print(f"    ? {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
