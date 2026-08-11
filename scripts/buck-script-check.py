#!/usr/bin/env python3
"""Does the python renderer produce the SAME builder script the lowering does? Byte for byte.

#66 moves the builder script out of the evaluator and into the graph derivation. The script is
the thing that actually runs, so a port of it that is merely equivalent-looking is worth nothing:
this compares the rendered text against ciderBuck2Lower.nix's own passthru.builderScript for
every label, by sha256 of the whole thing.

WHAT THE RENDERER CANNOT KNOW, and why comparing at all takes work. The generator runs inside
the graph derivation, long before any consumer exists, so the staging script, the staged tree
scripts, the data tree and the dependency outputs are not paths it can contain. It names them
as shell variables, which nix/lib/dyn-actions.nix fills in through extraEnv and DYN_DEP_*. This
check substitutes the consumer's real values back and then compares, which is exactly the
substitution the bridge performs at build time.

THE PLACEHOLDER EXPORTS ARE TAKEN FROM ONE REAL SCRIPT AND USED FOR ALL, and that is not an
assumption being smuggled in: `placeholders` is one attrset for the whole lowering, so if it
were somehow per label the labels that differ would FAIL here rather than pass quietly.

Usage: buck-script-check.py <graph.json> <specs-dir> <dump.json> [--controls]
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from buck_lowering import Needs, builder_script, dep_var  # noqa: E402


def from_full(full: dict, name: str, label: str, exports: str) -> str:
    """The generator's OWN full.json text, with the placeholder exports put back where the
    renderer puts them: immediately after the static harness.

    WHY READ THE FILE RATHER THAN CALL THE RENDERER AGAIN. Both would use the same function, so
    agreement would be guaranteed and would say nothing about what the graph derivation actually
    WROTE. A generator that rendered correctly and then wrote the wrong dict key, or truncated,
    or serialised something else, passes the function comparison and fails this one."""
    from buck_lowering import join_parts
    parts = full[name]
    if not isinstance(parts, list) or len(parts) % 2 == 0:
        raise SystemExit(f"the generator's template for {name} ({label}) is not an odd-length "
                         f"alternating list")
    return join_parts(parts, lambda v: exports if v == "EXPORTS" else '"$' + v + '"')


def render(n: Needs, label: str, group_script: str, exports: str, info: dict, data: str,
           full_text: bool = False) -> str:
    """Render, then put the consumer's values where the variables are. Same order the bridge
    resolves them in: the staging script and the data tree are one value each, the tree scripts
    are positional in fromStaged order, and the dependencies are keyed by the bridge's own
    variable name."""
    t = group_script if full_text else builder_script(n, label, group_script, exports)
    t = t.replace('"$CIDER_STAGE"', info["g"]).replace('"$CIDER_DATA"', data)
    for i, path in enumerate(info["r"]):
        t = t.replace('"$CIDER_TREE_%d"' % i, path)
    for dep, path in zip(info["d"], info["p"]):
        t = t.replace('"$' + dep_var(Needs.safe_name(dep)) + '"', path)
    return t


def run(n, scripts, dump, exports, mutate=None, full=None):
    """Returns (identical, [labels that differ]). `mutate` breaks one thing, for the controls."""
    ok, bad = 0, []
    for label, info in dump["drvs"].items():
        gs = (from_full(full, Needs.safe_name(label), label, exports) if full is not None
              else scripts[Needs.safe_name(label)])
        if mutate is not None:
            gs, info = mutate(label, gs, info)
        t = render(n, label, gs, exports, info, dump["data"], full_text=full is not None)
        if hashlib.sha256(t.encode()).hexdigest() == info["h"]:
            ok += 1
        else:
            bad.append(label)
    return ok, bad


def main(argv: list) -> int:
    if len(argv) < 3:
        sys.exit(__doc__)
    graph_path, specs_dir, dump_path = argv[0], argv[1], argv[2]
    controls = "--controls" in argv

    n = Needs(json.load(open(graph_path)))
    scripts = json.load(open(os.path.join(specs_dir, "scripts.json")))
    dump = json.load(open(dump_path))

    # The placeholder export block, lifted out of a real script by its own boundaries: it sits
    # between the static harness and this group's action script, both of which are known here.
    sample = dump.get("sample")
    if not sample:
        sys.exit("the dump has no `sample` script text to take the placeholder block from")
    b = sample.index("export CIDER_PH_")
    c = sample.index("\n", sample.rindex("export CIDER_PH_")) + 1
    exports = sample[b:c]

    total = len(dump["drvs"])
    # --from-full judges the ARTIFACT: the full.json the generator wrote, rather than a fresh
    # call to the same renderer.
    full = None
    if "--from-full" in argv:
        full = json.load(open(os.path.join(specs_dir, "full.json")))
    ok, bad = run(n, scripts, dump, exports, full=full)
    what = "the generator's full.json" if full is not None else "the python renderer"
    print(f"== builderScript: {what} against the lowering, {total} labels ==")
    print(f"  byte identical   {ok}")
    print(f"  differ           {len(bad)}")
    for label in bad[:8]:
        print(f"    {label}")
    rc = 0 if not bad else 1

    if controls:
        # EACH BREAKS ONE THING and must be caught. A comparison of two things that agree says
        # nothing about whether it could have disagreed, and this one compares hashes, where a
        # bug that renders the same wrong text on both sides is not even possible to see.
        print("\n== controls: each must FAIL ==")
        fails = 0

        def control(name, mutate):
            _, b2 = run(n, scripts, dump, exports, mutate, full=full)
            print(f"  {'FIRES ' if b2 else 'SILENT'} {name}: {len(b2)} label(s) differ")
            return 0 if b2 else 1

        # One byte into the action script, which is the part the generator already emits.
        fails += control("one byte changed in the group script",
                         lambda l, gs, i: (gs.replace("mkdir", "mkdir ", 1), i))
        # A dependency path pointing somewhere else: proves the dep copies are really compared
        # and not lost in the substitution.
        fails += control("one dependency path swapped",
                         lambda l, gs, i: (gs, dict(i, p=(["/nix/store/wrong"] + i["p"][1:])
                                                    if i["p"] else i["p"])))
        # The staging script, which is the per-group value extraEnv exists to carry.
        fails += control("the staging script path swapped",
                         lambda l, gs, i: (gs, dict(i, g="/nix/store/wrong-stage")))
        if fails:
            print(f"  {fails} control(s) did not fire, so the agreement above is not proven")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
