#!/usr/bin/env python3
"""Do all the copies of the two name mappings agree, on the REAL labels?

There are two mappings and several implementations of each, in two languages:

  safe_name / specName   a group label to a store-safe file name, which is the key the spec
                         files are named by and the key a consumer looks a group up with
  dep_var / depVar       that name to a shell variable, which is how the bridge hands a
                         dependency path to an emitted action

A MISMATCH IS SILENT IN THE WORST WAY. A wrong spec name either finds nothing, which at least
errors, or finds ANOTHER GROUP's spec, which does not. A wrong variable name is worse: the
variable is simply never set, expands to empty, and the action copies from nothing and produces
a plausible, wrong result. That is exactly how the first version of the bridge shipped a clean
build that produced nothing.

CHECKED ON THE REAL LABELS, not on invented strings. A property test over random text would
miss that this graph's labels are the ones with the colons, slashes and dots in them, and a
hand-written table would only ever contain cases someone already thought of.

WHERE THE COPIES LIVE NOW. #99 moved the generator to Rust, so three of the four files this
used to load are gone: buck-graph-to-specs.py, buck_lowering.py and dyn-actions-spec-fixup.py.
A check cannot import a Rust binary, so the Rust side is judged THROUGH ITS ARTIFACT, which is
better evidence anyway: the spec files are NAMED by safe_name, so a generator whose mapping
disagreed with the lowering writes a file the lowering cannot find, and that is what is tested
here rather than a function returning the right string.

THE GENERATOR'S dep_var IS COVERED ELSEWHERE, deliberately and not by omission:
scripts/buck-script-check.py substitutes "$DYN_DEP_<name>" into every rendered script and
compares the sha256 against the lowering's own builderScript, so a disagreeing dep_var makes
every label with a dependency differ there. Duplicating it here would cost a read of 1,474 dyn
specs to learn the same thing.

Usage: buck-names-check.py <specs-dir> <from-nix.json> [--controls]
  The nix side comes from
    nix eval --json .#cider-buck2-prefix-min --apply \\
      'l: builtins.mapAttrs (n: _: { s = l.specName n; d = l.depVar n; }) l.drvs'
"""
from __future__ import annotations

import json
import os
import sys

import importlib.util  # noqa: E402


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def implementations():
    """Every remaining copy, by the file it lives in. Loaded rather than reimplemented here: a
    check that reimplements what it checks tests the check."""
    spc = _load(os.path.join(HERE, "buck-specs-check.py"), "spc")
    chk = _load(os.path.join(HERE, "buck-script-check.py"), "chk")
    return (
        {
            "buck-specs-check.py safe_name": spc.safe_name,
            "buck-script-check.py safe_name": chk.safe_name,
        },
        {
            "buck-script-check.py dep_var": chk.dep_var,
        },
    )

def main(argv: list) -> int:
    if len(argv) < 2:
        sys.exit(__doc__)
    specs_dir = argv[0]
    from_nix = json.load(open(argv[1]))
    controls = "--controls" in argv

    names, deps = implementations()
    labels = sorted(from_nix)
    print(f"== name mappings across {len(names) + 2} spec-name and {len(deps) + 1} "
          f"variable-name implementations, on {len(labels)} real labels ==")

    rc = 0
    bad = {}
    # THE GENERATOR, THROUGH THE NAMES IT WROTE. Nothing is computed here: the question is
    # whether a file exists at the name the lowering will look for, which is the whole
    # contract between the two.
    missing = [l for l in labels
               if not os.path.exists(os.path.join(specs_dir, from_nix[l]["s"] + ".json"))]
    print(f"  {'DIFFERS' if missing else 'agrees '} the generator's spec file names: "
          f"{len(missing)}")
    for label in missing[:3]:
        print(f"      {label}\n        nix wants {from_nix[label]['s']}.json, which is not there")
    if missing:
        rc = 1
    for label in labels:
        want_s = from_nix[label]["s"]
        want_d = from_nix[label]["d"]
        for what, f in names.items():
            got = f(label)
            if got != want_s:
                bad.setdefault(what, []).append((label, want_s, got))
        # THE VARIABLE NAME IS A COMPOSITION, dep_var after safe_name, and checking it on the
        # raw label instead would silently be testing a different function.
        for what, f in deps.items():
            got = f(want_s)
            if got != want_d:
                bad.setdefault(what, []).append((label, want_d, got))

    for what in list(names) + list(deps):
        n = len(bad.get(what, []))
        print(f"  {'DIFFERS' if n else 'agrees '} {what}: {n}")
        for label, want, got in bad.get(what, [])[:3]:
            print(f"      {label}\n        nix {want}\n        py  {got}")
        if n:
            rc = 1

    # THE LABELS ARE NOT ALL ALIKE, and a run where every label happened to be alphanumeric
    # would agree trivially. Count what the mapping actually has to do.
    changed = sum(1 for l in labels if from_nix[l]["s"] != l)
    chars = sorted({c for l in labels for c in l if not (c.isalnum() or c in "_.-")})
    print(f"  labels the mapping CHANGES: {changed} of {len(labels)}")
    print(f"  characters it has to map: {''.join(chars)!r}")
    if changed == 0:
        print("  FAIL: no label needs mapping, so this proves nothing")
        rc = 1

    if controls:
        print("\n== controls: each must FAIL ==")
        fails = 0
        for what, f, arg_is_name in (
            ("a spec name that keeps the colon", lambda s: s.replace("_", ":", 1), False),
            ("a variable name missing the prefix", lambda s: s.replace("DYN_DEP_", "", 1), True),
        ):
            n = 0
            for label in labels:
                want = from_nix[label]["d" if arg_is_name else "s"]
                if f(want) != want:
                    n += 1
            print(f"  {'FIRES ' if n else 'SILENT'} {what}: {n} label(s) would differ")
            if not n:
                fails += 1
        if fails:
            print(f"  {fails} control(s) did not fire")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
