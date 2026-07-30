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
    "libstdc++.6.dylib":
        "GCC 4.2.1's vendored libstdc++ headers do not compile against this SDK with "
        "clang at the -std=c++14 the reference itself passes (const-correctness of "
        "memchr/strchr and conflicting using-declarations); nothing links the result -- "
        "only the aggregate `all` target names it",
    "x86_64-apple-darwin20-ld":
        "Darling's ld64 and cctools come from Nix (nix/lib/darling-ld64.nix, the ld64 "
        "input to darlingBuck2Graph); the port CONSUMES them through [darling] ld and "
        "ld64_dir rather than building them",
    "x86_64-apple-darwin20-ar":
        "same as x86_64-apple-darwin20-ld: supplied by the Nix-built cctools",
    "x86_64-apple-darwin20-ranlib":
        "same as x86_64-apple-darwin20-ld: supplied by the Nix-built cctools",
    "libsystem_kernel_static32.a":
        "the i386 slice: its libsyscall_32 compiles the -i386-User.c mig stubs, and this "
        "port targets x86_64 only",
}


def main(argv: list[str]) -> int:
    g = load_gen()
    edges = g.read_edges()
    reg, final_reg, arch_reg = g.firstpass_registry(), g.final_registry(), g.archive_registry()

    # Buck target names, so executables can be looked up by name.
    module_names = set()
    exe_names = set()
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in ("buck-out", ".git", ".jj", ".direnv", "build")]
        if "BUCK" not in filenames:
            continue
        text = open(os.path.join(dirpath, "BUCK")).read()
        # cc_binary as well as darwin_binary: the HOST tools the reference links (migcom,
        # rtsig) are built by the port too, just for this machine rather than for Darwin.
        for m in re.finditer(
                r'(?:darwin_binary|cc_binary)\(\s*\n\s*name = "([A-Za-z0-9_.-]+)"', text):
            exe_names.add(m.group(1))
        for m in re.finditer(r'dylib_name = "([A-Za-z0-9_.+-]+\.so)"', text):
            module_names.add(m.group(1))

    kinds = {"dylib": [], "exe": [], "archive": [], "module": []}
    # Everything that matched no category, kept rather than dropped. Silence is how 70
    # module edges came to be missing from a metric that read 100%.
    unclassified = []
    for outs, rule, inputs, vars in edges:
        if not any(i.endswith(".o") for i in inputs):
            continue
        # Classify by the ninja RULE, which is cmake's own statement of what the edge is,
        # rather than by guessing from the output name. Guessing is what went wrong twice:
        # .so outputs fell through every branch, and requiring LINK_FLAGS to recognise an
        # executable dropped the host tools, which cmake links without any.
        kind = rule.split("__")[0]
        if kind == "phony":
            # An OBJECT library: cmake aggregates its .o files behind a phony, and nothing
            # is linked. Not a link edge, so not part of this denominator.
            continue
        for o in outs:
            if "/" not in o:
                continue
            base = os.path.basename(o)
            if kind.endswith("STATIC_LIBRARY_LINKER"):
                kinds["archive"].append((base, base in arch_reg))
            elif kind.endswith("SHARED_LIBRARY_LINKER"):
                if base.endswith(".so"):
                    # A loadable MODULE: -shared, no -dylib_install_name. zsh's 35.
                    kinds["module"].append((base, base in module_names))
                else:
                    ported = base in final_reg or base.removeprefix("lib").removesuffix(
                        ".dylib").removesuffix("_firstpass") in reg
                    kinds["dylib"].append((base, ported))
            elif kind.endswith("EXECUTABLE_LINKER"):
                kinds["exe"].append((base, base in exe_names))
            else:
                unclassified.append(f"{base} ({kind})")
            break

    total = done = 0
    for kind in ("dylib", "exe", "archive", "module"):
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
    if unclassified:
        # Not fatal, but never silent: an edge nothing recognises is an edge nobody is
        # counting, which is how this metric came to report 100% while missing 70 of them.
        names = sorted(set(unclassified))
        print(f"UNCLASSIFIED link outputs (counted nowhere): {len(names)}")
        for n in names[:10]:
            print(f"    ? {n}")
    if "--missing" in argv and OUT_OF_SCOPE:
        print("out of scope:")
        for name, why in sorted(OUT_OF_SCOPE.items()):
            print(f"    - {name}: {why}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
