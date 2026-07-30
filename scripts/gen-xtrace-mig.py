#!/usr/bin/env python3
"""Wire xtrace's per-protocol stub dylibs to the mig targets that generate them.

Every MIG protocol in the reference also produces a <stem>XtraceMig.c, compiled into its
own little dylib that xtrace dlopens to decode that protocol's messages. The source is
generated, so the stub cannot be generated from sources alone: this maps each
`*_xtrace_mig` object library to the mig_gen target whose output directory holds that
file, sets that target's `xtrace_srcs`, and records the gen: entry so
gen-buck-from-ninja.py can emit the object library and the dylib.

Usage: scripts/gen-xtrace-mig.py [--dry-run]
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = ("buck-out", ".git", ".jj", ".direnv", "build")


def load_gen():
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(REPO, "scripts", "gen-buck-from-ninja.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def mig_targets():
    """[(label, package, block start, block end, defs, out_base)] for every mig_gen."""
    found = []
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if "BUCK" not in filenames:
            continue
        pkg = os.path.relpath(dirpath, REPO)
        path = os.path.join(dirpath, "BUCK")
        text = open(path).read()
        for m in re.finditer(r"mig_gen\(\n(?:.*?\n)*?\)\n", text):
            blk = m.group(0)
            name = re.search(r'name = "([^"]+)"', blk)
            defs = re.search(r'defs = "([^"]+)"', blk)
            base = re.search(r'out_base = "([^"]*)"', blk)
            if not (name and defs):
                continue
            found.append({
                "label": f"//{pkg}:{name.group(1)}",
                "path": path,
                "span": (m.start(), m.end()),
                "defs": defs.group(1),
                "out_base": base.group(1) if base else "",
                "arch": re.search(r'arch = "([^"]+)"', blk).group(1) if 'arch = "' in blk else "",
                "multiarch": "-x86_64-" in blk or "-i386-" in blk,
            })
    return found


def main(argv: list[str]) -> int:
    g = load_gen()
    edges = g.read_edges()
    migs = mig_targets()

    # Which object libraries are xtrace stubs, and what file does each compile?
    stubs = {}
    for outs, _rule, inputs, _vars in edges:
        for o in outs:
            m = re.search(r"CMakeFiles/([A-Za-z0-9_.-]+_xtrace_mig)\.dir/", o)
            if not m or not o.endswith(".o"):
                continue
            for i in inputs:
                if i.endswith("XtraceMig.c"):
                    stubs.setdefault(m.group(1), set()).add(g.orig_repo_rel(i))

    extra = json.loads(open(os.path.join(REPO, "buck", "generated", "extra-deps.json")).read())
    wired, unmatched = [], []
    edits: dict[str, list] = {}
    for lib, srcs in sorted(stubs.items()):
        # The generated file, e.g. .../src/launchd/liblaunch/jobXtraceMig.c
        src = sorted(srcs)[0]
        stem = os.path.basename(src)
        # `src` is the full generated path (src/external/.../libsyscall/mach/taskXtraceMig.c);
        # the instance is the mig target whose out_base + relative stem lands exactly there.
        rel = src.removeprefix("src/external/")
        want_stem = stem.removesuffix("XtraceMig.c")
        cands = []
        for t in migs:
            if os.path.basename(t["defs"]).removesuffix(".defs") != want_stem:
                continue
            if t["multiarch"]:
                continue
            base = t["out_base"].rstrip("/")
            defs_rel = t["defs"]
            if base and defs_rel.startswith(base + "/"):
                out_rel = os.path.join(base, defs_rel[len(base) + 1:])
            else:
                out_rel = defs_rel
            out_rel = out_rel.removesuffix(".defs") + "XtraceMig.c"
            if out_rel == rel or out_rel.endswith("/" + rel) or rel.endswith("/" + out_rel):
                cands.append(t)
        if not cands:
            cands = [t for t in migs
                     if os.path.basename(t["defs"]).removesuffix(".defs") == want_stem
                     and not t["multiarch"]
                     and os.path.dirname(rel).endswith(os.path.dirname(t["defs"]).split("/")[-1])]
        if not cands:
            unmatched.append((lib, src))
            continue
        t = cands[0]
        # The name must be relative to the mig OUTPUT DIR, not a bare basename: the
        # runner writes $outdir/<stem><suffix>, and the stem keeps the protocol's own
        # subdirectory (mach/clockXtraceMig.c, not clockXtraceMig.c). out_base is
        # PACKAGE-relative, so the generated path has to be made package-relative first.
        pkg = os.path.relpath(os.path.dirname(t["path"]), REPO)
        if pkg == "buck-src":
            pkg_rel = src.removeprefix("src/external/")
        else:
            pkg_rel = src.removeprefix(pkg + "/")
        base = t["out_base"].rstrip("/")
        out_name = pkg_rel[len(base) + 1:] if base and pkg_rel.startswith(base + "/") else stem
        edits.setdefault(t["path"], []).append((t["span"], out_name))
        extra[lib] = [f"gen:{t['label']}[xtrace]", "//src/xtrace:xtrace_headers"]
        wired.append((lib, t["label"]))

    if "--dry-run" in argv:
        for lib, label in wired:
            print(f"  {lib:34} <- {label}")
        print(f"{len(wired)} wired, {len(unmatched)} unmatched")
        for lib, src in unmatched:
            print(f"  UNMATCHED {lib}: {src}")
        return 0

    # Apply the xtrace_srcs edits back-to-front so spans stay valid.
    for path, items in edits.items():
        text = open(path).read()
        for (start, end), stem in sorted(items, key=lambda i: -i[0][0]):
            blk = text[start:end]
            if "xtrace_srcs" in blk:
                blk = re.sub(r'    xtrace_srcs = \[[^\]]*\],\n', "", blk)
            blk = blk.replace("    mig_sh =", f'    xtrace_srcs = ["{stem}"],\n    mig_sh =', 1)
            text = text[:start] + blk + text[end:]
        open(path, "w").write(text)

    with open(os.path.join(REPO, "buck", "generated", "extra-deps.json"), "w") as f:
        json.dump(extra, f, indent=2)
        f.write("\n")
    print(f"wired {len(wired)} xtrace stubs; {len(unmatched)} unmatched")
    for lib, src in unmatched:
        print(f"  UNMATCHED {lib}: {src}")
    print("now run: scripts/gen-buck-from-ninja.py --write " + " ".join(l for l, _ in wired))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
