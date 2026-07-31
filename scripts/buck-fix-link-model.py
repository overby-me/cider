#!/usr/bin/env python3
"""Make every darwin_dylib's LINK MODEL match the reference: order, and upward deps.

ld64 records LC_LOAD_DYLIB in the order the libraries appear on the command line, and dyld
initializes depth-first through that order. So the order is not cosmetic: it decides which
image's initializer runs FIRST, and dyld aborts the process if that image is not libSystem
("initializer in image ... that does not link with libSystem.dylib", which is what it says
when an initializer runs before libSystem's).

The port had libsystem_trace naming libplatform before libobjc where the reference names
libobjc first, because the generator followed the ninja edge's input order rather than
LINK_LIBRARIES. That was enough to send dyld into libc++ ahead of libSystem, and the guest
died at every boot.

It does two things, both of which decide dyld's behaviour rather than the linker's:

  * ORDER. See above.
  * UPWARD dependencies. dyld links an upward library but does not descend into it when
    running initializers, which is the only reason libSystem's own initializer can run
    first: five of its sublibraries (libdispatch, libsystem_trace, libxpc, libsystem_malloc,
    libdyld) depend on libobjc or libsystem_c, which sit ABOVE libSystem. The reference
    passes -Wl,-upward_library for exactly those; the port had never emitted an upward
    dependency at all, so the walk reached libc++ first and every boot died.

This rewrites those two properties of existing blocks and nothing else. Regenerating the blocks
would be the obvious alternative and is not safe here: the generator cannot yet reproduce
some of what the committed blocks carry (libcxx's symbol-list flags, cross-package labels),
which is the generator/tree fixpoint debt in plan/buck2-port.md.

Usage:
  scripts/buck-fix-sibling-order.py [--check]
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLOCK = re.compile(r"darwin_dylib\(\n(?:.*?\n)*?\)\n")
SIBLINGS = re.compile(r"(    siblings = \[\n)((?:        \"[^\"]+\",\n)+)(    \],\n)")


def load_gen():
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(REPO, "scripts", "gen-buck-from-ninja.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def upward_sets(gen) -> dict:
    """{dylib name: {label}} from the reference's -Wl,-upward_library flags."""
    reg, final_reg = gen.firstpass_registry(), gen.final_registry()
    out = {}
    for outs, _rule, _inputs, vars in gen.read_edges():
        labels, _missing = gen.upwards_of((outs, _inputs, vars), reg, final_reg)
        if labels:
            out.setdefault(os.path.basename(outs[0]), set()).update(labels)
    return out


def link_order(gen) -> dict:
    """{dylib name: {sibling label: position}} from the reference's LINK_LIBRARIES."""
    reg, final_reg = gen.firstpass_registry(), gen.final_registry()
    out = {}
    for outs, _rule, _inputs, vars in gen.read_edges():
        libs = vars.get("LINK_LIBRARIES")
        if not libs:
            continue
        produced = os.path.basename(outs[0])
        ranks = {}
        for n, tok in enumerate(libs.split()):
            base = os.path.basename(tok)
            if not base.endswith(".dylib"):
                continue
            m = re.match(r"lib([A-Za-z0-9_.-]+)_firstpass\.dylib$", base)
            label = reg.get(m.group(1)) if m else final_reg.get(base)
            if label and label not in ranks:
                ranks[label] = n
        if ranks:
            out.setdefault(produced, ranks)
    return out


def main(argv: list[str]) -> int:
    gen = load_gen()
    orders = link_order(gen)
    upwards = upward_sets(gen)
    check = "--check" in argv
    changed, stale = 0, []

    for dirpath, dirnames, files in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in ("buck-out", ".git", ".jj", ".direnv", "build")]
        if "BUCK" not in files:
            continue
        path = os.path.join(dirpath, "BUCK")
        text = open(path).read()
        new_text = text
        for block in BLOCK.findall(text):
            name = re.search(r'dylib_name = "([^"]+)"', block)
            sibs = SIBLINGS.search(block)
            if not name or not sibs:
                continue
            dylib = name.group(1)
            ranks = orders.get(dylib)
            up = upwards.get(dylib, set())
            if not ranks and not up:
                continue
            ranks = ranks or {}
            labels = re.findall(r'"([^"]+)"', sibs.group(2))
            # Anything the reference does not name keeps its position at the end, in the
            # order it already had, so this only ever moves what the reference orders.
            order = sorted(range(len(labels)),
                           key=lambda i: (ranks.get(labels[i], 1 << 30), i))
            kept = [labels[i] for i in order if labels[i] not in up]
            moved = [labels[i] for i in order if labels[i] in up]
            if kept == labels and not moved:
                continue
            body = "".join(f'        "{l}",\n' for l in kept)
            new_sibs = sibs.group(1) + body + sibs.group(3)
            if moved:
                new_sibs += ("    upward = [\n"
                             + "".join(f'        "{l}",\n' for l in moved)
                             + "    ],\n")
            new_block = block.replace(sibs.group(0), new_sibs)
            new_text = new_text.replace(block, new_block)
            changed += 1
        if new_text != text:
            if check:
                stale.append(os.path.relpath(path, REPO))
            else:
                open(path, "w").write(new_text)

    if check:
        for s in stale:
            print(f"  STALE {s}")
        print(f"{len(stale)} file(s) whose link model differs from the reference")
        return 1 if stale else 0
    print(f"fixed the link model of {changed} dylib target(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
