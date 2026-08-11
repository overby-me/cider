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

# A store path as it appears once Nix has substituted it: the store directory, a 32 character
# base-32 hash, a dash, then the name. Anchored on the hash length so a path-shaped string in
# ordinary text cannot match. Trailing path components are deliberately NOT captured: srcs
# names a store OBJECT, and /nix/store/xxx-foo/bar is the object xxx-foo.
_STORE_PATH = re.compile(r"/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+")


# MAX_ARG_STRLEN. Kept a little under 32 pages because the kernel counts the terminating NUL
# and the pointer, and being exactly at the edge is not worth the argument.
_MAX_ARG = 120 * 1024


def _spill(text: str, name: str):
    """Put an over-long argument in the store and return its path, or None on failure."""
    import subprocess
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, name + ".sh")
        with open(f, "w") as fh:
            fh.write(text)
        # add-path rather than add-file: it is the spelling available on the nix this runs
        # against, and a regular file goes in as a regular file either way.
        r = subprocess.run(
            ["nix", "--extra-experimental-features", "nix-command", "store", "add-path", f],
            capture_output=True, text=True)
        if r.returncode != 0:
            print(f"dyn-actions: could not spill a {len(text)} byte argument of {name!r} to the "
                  f"store: {r.stderr.strip()}", file=sys.stderr)
            return None
        return r.stdout.strip()


def dep_var(name: str) -> str:
    return "DYN_DEP_" + _UNSAFE.sub("_", name)


def main(argv: list) -> int:
    if len(argv) != 1:
        sys.exit(__doc__)
    path = argv[0]
    with open(path) as f:
        spec = json.load(f)

    spec.setdefault("inputs", {}).setdefault("srcs", [])
    spec.setdefault("inputs", {}).setdefault("drvs", {})
    spec.setdefault("env", {})

    # WHAT ONLY THE BRIDGE KNOWS, filled in here so a spec dir can be written by a GENERATOR
    # that has never heard of Nix placeholders. Before this, specDir mode required a fully
    # formed version 4 derivation, which in practice meant it could only read what mkSpecDir
    # wrote: the bridge reading its own files back, which is not what the mode is for.
    #
    # ANYTHING ALREADY PRESENT IS LEFT ALONE. mkSpecDir writes complete specs and they must
    # keep working byte for byte.
    #
    # THE PLACEHOLDER IS NOT DERIVABLE OUTSIDE NIX. builtins.placeholder is a hash of a fixed
    # string with the output NAME in it, and reimplementing that in a generator would be a
    # second copy of an internal encoding. It arrives in the environment instead.
    out_name = os.environ.get("DYN_OUTPUT_NAME")
    placeholder = os.environ.get("DYN_OUTPUT_PLACEHOLDER")
    system = os.environ.get("DYN_SYSTEM")
    if out_name and placeholder and system:
        spec.setdefault("system", system)
        spec.setdefault("version", 4)
        spec.setdefault("outputs", {})
        spec["outputs"].setdefault(out_name, {"hashAlgo": "sha256", "method": "nar"})
        env = spec["env"]
        env.setdefault("name", spec.get("name", ""))
        env.setdefault("builder", spec.get("builder", ""))
        env.setdefault(out_name, placeholder)
        env.setdefault("outputHashAlgo", "sha256")
        env.setdefault("outputHashMode", "recursive")
        env.setdefault("system", system)

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

    # CONSUMER SUPPLIED PATHS, the same route as a dependency and for the same reason: a spec
    # read from a file cannot have a store path interpolated into it, because the generator that
    # wrote it ran before any consumer path existed. Each becomes an env entry so the script can
    # name it, and a source so the sandbox actually has it.
    #
    # SEPARATE FROM DYN_DEP_NAMES because a dependency is also an EDGE and this is not: the
    # value is already a realised path rather than another action's output.
    for name in os.environ.get("DYN_EXTRA_NAMES", "").split():
        value = os.environ.get(name)
        if not value:
            print(f"dyn-actions: extraEnv {name!r} is not in the environment", file=sys.stderr)
            return 1
        spec["env"][name] = value
        # EVERY STORE PATH THE VALUE NAMES, not the value itself, and the difference is not
        # theoretical: a PATH is a colon-joined list of <store path>/bin entries, and appending
        # the whole string made `nix derivation add` fail with "bin is too short to be a valid
        # store path" once the basename step below took its last component.
        #
        # A caller may legitimately pass a plain string with no path in it. That is carried in
        # the env and simply declares nothing.
        for m in _STORE_PATH.finditer(value):
            spec["inputs"]["srcs"].append(m.group(0))

    # INFERRED SOURCES: every store path the command itself names.
    #
    # WHY THIS CAN ONLY HAPPEN HERE, and why it is worth having. A caller assembling an action
    # from an existing build script has the paths in the SCRIPT rather than in a list: the
    # string carries Nix string context, the outer Nix substitutes real paths into it when this
    # producer runs, and there is no point before that at which the caller could enumerate
    # them. Reading them back out of the finished args is the only place the information is
    # both present and concrete.
    #
    # OVER-DECLARING IS SAFE AND UNDER-DECLARING IS NOT, which is what makes this a reasonable
    # default to offer: a path named in a comment merely puts something extra in the sandbox,
    # whereas a missing one is a command running against a file that is not there. It is still
    # opt-in, because a caller that knows its inputs exactly should say so and get an error
    # when it is wrong.
    if os.environ.get("DYN_INFER_SRCS"):
        text = json.dumps(spec.get("args", [])) + json.dumps(spec.get("builder", ""))
        for m in _STORE_PATH.finditer(text):
            spec["inputs"]["srcs"].append(m.group(0))

    # AN ARGUMENT CAN BE TOO LONG TO PASS AT ALL, and this is not a tuning knob: Linux caps a
    # SINGLE argv or env string at MAX_ARG_STRLEN, 32 pages, 131,072 bytes. It is not ARG_MAX,
    # which is the 2 MB total and would not have been reached. execve fails with E2BIG and the
    # builder reports "executing /bin/sh: Argument list too long".
    #
    # FOUND BY A REAL CONSUMER, and it could not have been found by a toy: the largest fixture
    # script here is a few kilobytes, while 89 of one consumer's 1,474 actions are over the
    # limit and the largest is 5.1 MB. Three exceed even the 2 MB total, so no amount of
    # trimming elsewhere would have carried them.
    #
    # THE SPILL IS TO A STORE FILE, which the producer can do because recursive-nix is already
    # what it runs `nix derivation add` with. The file becomes a source, so the sandbox has it.
    #
    # ONLY A SHELL COMMAND STRING IS REWRITTEN, and that is the whole reason this is safe: an
    # argument after -c IS a shell script, and sourcing a file containing it is exactly
    # equivalent. For any other over-long argument there is no rewrite that preserves meaning,
    # so that is a named error rather than a guess.
    args = spec.get("args", [])
    for i, arg in enumerate(args):
        if not isinstance(arg, str) or len(arg) <= _MAX_ARG:
            continue
        if i == 0 or args[i - 1] != "-c":
            print(f"dyn-actions: argument {i} of {spec.get('name')!r} is {len(arg)} bytes, over "
                  f"the {_MAX_ARG} byte limit on a single argument, and is not a -c command "
                  f"string, so there is no equivalent rewrite", file=sys.stderr)
            return 1
        # NOT `path`: that name is the SPEC FILE this function writes back at the end, and
        # reusing it here sent the finished spec to the spilled script instead, which surfaced
        # as PermissionError on a read-only store file rather than as anything about shadowing.
        spilled = _spill(arg, spec.get("name", "action"))
        if spilled is None:
            return 1
        args[i] = ". " + spilled
        spec["inputs"]["srcs"].append(spilled)

    # LAST, so it also catches the dependency and inferred paths just added. Everything in srcs
    # is a store path by now: the outer Nix has substituted every placeholder.
    seen, srcs = set(), []
    for s in spec["inputs"]["srcs"]:
        base = s.rsplit("/", 1)[-1]
        if base not in seen:
            seen.add(base)
            srcs.append(base)
    spec["inputs"]["srcs"] = srcs

    with open(path, "w") as f:
        json.dump(spec, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
