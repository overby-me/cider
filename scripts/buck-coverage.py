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
    "x86_64-apple-darwin20-ld":
        "Darling's ld64 and cctools come from Nix (nix/lib/darling-ld64.nix, the ld64 "
        "input to darlingBuck2Graph); the port CONSUMES them through [darling] ld and "
        "ld64_dir rather than building them",
    "x86_64-apple-darwin20-ar":
        "same as x86_64-apple-darwin20-ld: supplied by the Nix-built cctools",
    "x86_64-apple-darwin20-ranlib":
        "same as x86_64-apple-darwin20-ld: supplied by the Nix-built cctools",
    # BY PATH, because the artifact name is ambiguous and the other one IS built and
    # installed: the reference builds lipo twice, and only src/external/cctools/misc/lipo
    # is installed. cctools-port's copy is a build-time tool, the same case as ld/ar/ranlib.
    "src/external/cctools-port/cctools/misc/lipo":
        "the second lipo: only cctools' copy is installed, and cctools-port's is a "
        "build-time tool supplied by the Nix-built cctools like ld, ar and ranlib",
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
        # ALSO the exe_name a rule installs under, which is often not its target name. An
        # edge is matched by the artifact's basename, so without this the port looks like
        # it is missing 92 cli executables it in fact builds: curl is the target curlexe,
        # and clang, git, bison, Rez and the Carbon resource tools are xcselect SHIMS,
        # which is what the reference INSTALLS under those names. A coverage number that
        # counts those as gaps hides the handful of real ones behind naming noise.
        for m in re.finditer(r'exe_name = "([A-Za-z0-9_.+-]+)"', text):
            exe_names.add(m.group(1))
        for m in re.finditer(r'dylib_name = "([A-Za-z0-9_.+-]+\.so)"', text):
            module_names.add(m.group(1))

    kinds = {"dylib": [], "exe": [], "archive": [], "module": []}
    # An artifact name the reference builds at more than one path. Resolving such an edge
    # by NAME cannot distinguish the two, so it is counted but reported separately: the
    # number is the size of what this metric still takes on trust, and it must not grow.
    paths_by_name = {}
    for outs, rule, inputs, vars in edges:
        if not any(i.endswith(".o") for i in inputs) or rule.split("__")[0] == "phony":
            continue
        for o in outs:
            if "/" in o:
                paths_by_name.setdefault((rule.split("__")[0], os.path.basename(o)), set()).add(o)
                break
    ambiguous = {k for k, v in paths_by_name.items() if len(v) > 1}
    soft = []
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
            # KEYED BY PATH, not by basename. An artifact name does not identify a
            # library: the reference builds 79 names at more than one path -- perl's
            # 5.18 and 5.28 module sets, the cctools tools next to their xcselect shims,
            # and the nine dev-stub frameworks, whose AppKit is called AppKit exactly
            # like the real one. Collapsing those onto one entry answered "ported" for a
            # pair as soon as EITHER half was, which is how nine unported frameworks sat
            # inside a metric that read 100%.
            #
            # The port already says which target builds which reference PATH: every
            # generated dylib and binary block carries a `buck-registry: <path> =
            # <target>` pragma, and final_registry() keys those by path. So resolve by
            # path first and fall back to the artifact name, which still covers the
            # blocks that predate the pragma.
            if kind.endswith("STATIC_LIBRARY_LINKER"):
                kinds["archive"].append((o, base, o in arch_reg or base in arch_reg))
            elif kind.endswith("SHARED_LIBRARY_LINKER"):
                if base.endswith(".so"):
                    # A loadable MODULE: -shared, no -dylib_install_name. zsh's 35.
                    kinds["module"].append((o, base, o in final_reg or base in module_names))
                else:
                    ported = o in final_reg or base in final_reg or base.removeprefix(
                        "lib").removesuffix(".dylib").removesuffix("_firstpass") in reg
                    kinds["dylib"].append((o, base, ported))
            elif kind.endswith("EXECUTABLE_LINKER"):
                kinds["exe"].append((o, base, o in final_reg or base in exe_names))
            else:
                unclassified.append(f"{base} ({kind})")
            if ((kind, base) in ambiguous and o not in final_reg and o not in arch_reg
                    and o not in OUT_OF_SCOPE and base not in OUT_OF_SCOPE):
                soft.append(o)
            break

    total = done = 0
    for kind in ("dylib", "exe", "archive", "module"):
        items, label = {}, {}
        for path, name, ported in kinds[kind]:
            items[path] = items.get(path, False) or ported
            label[path] = name
        # OUT_OF_SCOPE is written by artifact name, since that is how the reasons read.
        # Keyed by PATH as well as by name: where two artifacts share a name and only one
        # is out of scope, a name-only check would drop both.
        skipped = {k for k in items if k in OUT_OF_SCOPE or label[k] in OUT_OF_SCOPE}
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
    if soft:
        print(f"{'by-name':10} {len(soft):4d}       (ambiguous artifact name, no "
              f"`buck-registry: <path>` pragma: counted on the NAME alone)")
        if "--missing" in argv:
            for s in sorted(soft):
                print(f"    ~ {s}")
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
