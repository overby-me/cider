#!/usr/bin/env python3
"""How much of the reference build does the Buck2 port cover?

Counts every LINK EDGE in the reference build.ninja (dylibs, executables, archives) and
reports which ones have a buck2 target, so progress is measured against the graph rather
than against a hand-kept list.

Usage:
  scripts/buck-coverage.py            # summary
  scripts/buck-coverage.py --missing  # also list what is not ported yet
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_gen():
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(REPO, "scripts", "gen-buck-from-ninja.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Deliberately not ported, with the reason. Counted separately so "what is left" stays
# an honest number rather than a permanent three.
OUT_OF_SCOPE = {
    "libsystem_kernel_static32.a":
        "the i386 slice: its libsyscall_32 compiles the -i386-User.c mig stubs, and this "
        "port targets x86_64 only",
}


def main(argv: list[str]) -> int:
    g = load_gen()
    edges = g.read_edges()
    reg, final_reg, arch_reg = g.firstpass_registry(), g.final_registry(), g.archive_registry()

    # Buck target names, so executables can be looked up by name.
    exe_names = set()
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in ("buck-out", ".git", ".jj", ".direnv", "build")]
        if "BUCK" not in filenames:
            continue
        text = open(os.path.join(dirpath, "BUCK")).read()
        for m in re.finditer(r'darwin_binary\(\s*\n\s*name = "([A-Za-z0-9_.-]+)"', text):
            exe_names.add(m.group(1))

    kinds = {"dylib": [], "exe": [], "archive": []}
    for outs, _rule, inputs, vars in edges:
        lf = vars.get("LINK_FLAGS", "")
        if not any(i.endswith(".o") for i in inputs):
            continue
        for o in outs:
            if "/" not in o:
                continue
            base = os.path.basename(o)
            if base.endswith(".a"):
                kinds["archive"].append((base, base in arch_reg))
            elif base.endswith(".dylib") or "-dylib_install_name" in lf:
                ported = base in final_reg or base.removeprefix("lib").removesuffix(
                    ".dylib").removesuffix("_firstpass") in reg
                kinds["dylib"].append((base, ported))
            elif "." not in base and lf:
                kinds["exe"].append((base, base in exe_names))
            break

    total = done = 0
    for kind in ("dylib", "exe", "archive"):
        items = {}
        for name, ported in kinds[kind]:
            items[name] = items.get(name, False) or ported
        skipped = {k for k in items if k in OUT_OF_SCOPE}
        for k in skipped:
            items.pop(k)
        n, d = len(items), sum(1 for v in items.values() if v)
        total += n
        done += d
        note = f"   ({len(skipped)} out of scope)" if skipped else ""
        print(f"{kind + 's':10} {d:4d} / {n:4d}{note}")
        if "--missing" in argv:
            miss = sorted(k for k, v in items.items() if not v)
            for m in miss:
                print(f"    - {m}")
    print(f"{'total':10} {done:4d} / {total:4d}  ({100 * done // max(total, 1)}%)")
    if "--missing" in argv and OUT_OF_SCOPE:
        print("out of scope:")
        for name, why in sorted(OUT_OF_SCOPE.items()):
            print(f"    - {name}: {why}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
