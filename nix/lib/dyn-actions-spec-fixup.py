#!/usr/bin/env python3
"""Fix up one emitted derivation spec, at PRODUCER BUILD TIME, just before `nix derivation add`.

Two things can only be done here rather than in the evaluator, and both were learned the hard
way. See nix/lib/dyn-actions-dep-probe.nix for the measurements.

1. inputs.srcs MUST BE STORE-DIR-RELATIVE. The version 4 format wants `<hash>-<name>`, and
   given a full path `nix derivation add` fails with
       store path '/nix/store/xxx-foo' contains illegal base-32 character '/'
   The bridge cannot pre-strip them, because an entry may be another action's output, which at
   eval time is a builtins.outputOf PLACEHOLDER. The outer Nix substitutes the real path only
   when this producer runs, and it matches the placeholder TEXT exactly, so taking a basename
   or discarding the context mangles it and the emitted drv names a path that "is not valid".

2. DEPENDENCIES ON OTHER ACTIONS, for the same reason and one more. In specDir mode the spec is
   a FILE the bridge copies without parsing, so nothing in the evaluator can inject a
   dependency into it. The bridge instead hands this script the dependency paths through the
   environment, where Nix has already substituted them, and it writes them into the spec: as a
   source, so the sandbox has the file, AND as an env entry, so the action can find it without
   anyone interpolating a path into its args.

BOTH MODES GO THROUGH HERE, deliberately. Doing deps in specOf for `actions` mode and here for
`specDir` mode would be two implementations of one rule, and they would drift.

Usage: dyn-actions-spec-fixup.py <spec.json>
  DYN_DEP_NAMES  space separated action names this action depends on
  <depVar>       one per name, holding the dependency's already-substituted output path
"""
from __future__ import annotations

import json
import os
import re
import sys

# MUST MATCH depVar IN dyn-actions.nix. A shell variable name is [A-Za-z_][A-Za-z0-9_]*, and
# action names are free-form, so every other character becomes an underscore. Getting this
# wrong does not fail: the variable is simply unset and expands to EMPTY, which is how the
# first version of this shipped a clean build that produced nothing.
_UNSAFE = re.compile(r"[^A-Za-z0-9]")


def dep_var(name: str) -> str:
    return "DYN_DEP_" + _UNSAFE.sub("_", name)


def main(argv: list) -> int:
    if len(argv) != 1:
        sys.exit(__doc__)
    path = argv[0]
    with open(path) as f:
        spec = json.load(f)

    spec.setdefault("inputs", {}).setdefault("srcs", [])
    spec.setdefault("env", {})

    deps = os.environ.get("DYN_DEP_NAMES", "").split()
    for name in deps:
        var = dep_var(name)
        value = os.environ.get(var)
        if not value:
            # LOUD, because the silent version of this is an action that runs happily against
            # an empty path and produces a plausible, wrong, empty result.
            print(f"dyn-actions: dependency {name!r} has no {var} in the environment",
                  file=sys.stderr)
            return 1
        spec["inputs"]["srcs"].append(value)
        spec["env"][var] = value

    # LAST, so it also catches the dependency paths just added. Everything in srcs is a store
    # path by now: the outer Nix has substituted every placeholder.
    spec["inputs"]["srcs"] = [s.rsplit("/", 1)[-1] for s in spec["inputs"]["srcs"]]

    with open(path, "w") as f:
        json.dump(spec, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
