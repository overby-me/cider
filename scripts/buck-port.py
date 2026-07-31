#!/usr/bin/env python3
"""Port cmake targets to buck2 and resolve their framework headers automatically.

scripts/gen-buck-from-ninja.py emits a block from the reference graph, but the block
it emits is not necessarily buildable: the reference puts darwin/framework-include on
every Darwin compile's path, while this port makes each target name the frameworks it
includes. So a freshly generated block fails on the first #include of a framework
header, and the fix is always the same -- add that framework's header root to
buck/generated/extra-deps.json and regenerate.

Doing that by hand costs one build per framework, and Security alone needed eighteen.
This does it in a loop: build, read the first missing header AND the target that failed,
add the root, regenerate, repeat until the target builds or fails for a reason that is
not a missing framework header.

Two details that make it correct rather than merely convenient:

  * The framework roots live in THREE packages -- //buck-src, //darwin/frameworks and
    //darwin/private-frameworks -- so the owner is looked up in a map built from all
    three rather than assumed. CoreAnalytics is private and Security needs it.

  * extra-deps.json is keyed by CMAKE target, and buck target names carry an _obj/_obj2
    suffix that cmake target names do not. The key is derived by testing candidates
    against CMakeFiles/<name>.dir in the reference graph, so a second-pass compile puts
    its framework on the target that actually compiles it.

Usage:
    scripts/buck-port.py --archives libsecurity_utilities libsecurity_cssm ...
    scripts/buck-port.py --dylibs Security
    scripts/buck-port.py --binaries curl
    scripts/buck-port.py --objects Security_obj
    scripts/buck-port.py --build-only //buck-src:Security_dylib

Run it inside `nix develop`, after `source scripts/buck-env.sh`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTRA = os.path.join(REPO, "buck", "generated", "extra-deps.json")
NINJA = os.path.join(REPO, "result-graph-ref", "build.ninja")
GEN = os.path.join(REPO, "scripts", "gen-buck-from-ninja.py")

# Every package that defines framework header roots. A framework is looked up in all of
# them: which one owns it is a fact about the SDK layout (public, Darwin-private, or
# built here), not something a caller should have to know.
FRAMEWORK_PACKAGES = [
    "//buck-src:",
    "//darwin/frameworks:",
    "//darwin/private-frameworks:",
]


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, errors="replace", **kw)


def framework_map() -> dict[str, str]:
    """Every fw_<name> target, by framework name."""
    p = run(["buck2", "targets", *FRAMEWORK_PACKAGES])
    out = {}
    # fw_ and fwp_: //buck-src holds both the public and the PRIVATE framework maps, so it
    # prefixes the private ones to keep the two from colliding on a shared name. Heimdal
    # exists only as fwp_Heimdal, and looking for fw_ alone reported it as unported.
    for m in re.finditer(r"(root)?(//[^\s:]+):(fwp?_[A-Za-z0-9_]+)", p.stdout):
        out.setdefault(m.group(3).split("_", 1)[1], f"{m.group(2)}:{m.group(3)}")
    if not out:
        sys.exit("no framework roots found -- is buck2 on PATH and buck-env sourced?")
    return out


def ninja_text() -> str:
    if not os.path.exists(NINJA):
        sys.exit(f"missing {NINJA} -- nix build .#darling-graph -o result-graph-ref")
    with open(NINJA, errors="replace") as fh:
        return fh.read()


def cmake_target_for(buck_target: str, nj: str) -> str | None:
    """The cmake target behind a buck target name.

    Object blocks are <cmake>_obj / <cmake>_obj2 when the generator adds the suffix, and
    <cmake>2 when the cmake target is itself named ..._obj. Both spellings occur in the
    same build, so candidates are tested against the graph rather than picked by rule.

    A candidate counts only if it has COMPILE edges. Merely finding CMakeFiles/<c>.dir is
    not enough: cmake also creates that directory for link-only targets, and CFNetwork has
    both -- CFNetwork.dir (the dylib) and CFNetwork_obj.dir (the sources). Matching the
    former put every framework dep on a target that compiles nothing, and the same header
    went missing sixty times in a row.
    """
    # The generator numbers flag groups <base>, <base>2, <base>3, ... so the trailing
    # digits are a group index, not part of any name.
    ungrouped = re.sub(r"\d+$", "", buck_target)
    for cand in (
        buck_target,
        ungrouped,
        ungrouped[: -len("_obj")] if ungrouped.endswith("_obj") else None,
        buck_target[: -len("_obj")] if buck_target.endswith("_obj") else None,
    ):
        if cand and re.search(r"CMakeFiles/%s\.dir/[^\s:]*\.o[:\s]" % re.escape(cand), nj):
            return cand
    return None


def add_extra_dep(key: str, label: str) -> None:
    with open(EXTRA) as fh:
        data = json.load(fh)
    data[key] = sorted(set(data.get(key, []) + [label]))
    with open(EXTRA, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def generate(target: str, mode: str | None) -> tuple[bool, str]:
    cmd = [sys.executable, GEN, "--write"]
    if mode:
        cmd.append(mode)
    cmd.append(target)
    p = run(cmd)
    return p.returncode == 0, (p.stdout + p.stderr).strip()


def package_from(msg: str) -> str | None:
    """The package the generator wrote into, from its own report.

    A block goes to the package that owns its SOURCES, which is not always //buck-src --
    libaks and libacm live under src/. Reading it back beats guessing, and beats making
    the caller pass --package per target.
    """
    m = re.search(r"wrote (\S+)/BUCK:", msg)
    return "//" + m.group(1) if m else None


def resolve(label: str, fwmap: dict[str, str], nj: str, rounds: int = 60) -> tuple[bool, str]:
    """Build `label`, adding framework roots until it builds or fails for another reason."""
    added = []
    for _ in range(rounds):
        p = run(["buck2", "build", label])
        blob = p.stdout + p.stderr
        if "BUILD SUCCEEDED" in blob or p.returncode == 0:
            return True, ", ".join(added)
        miss = re.search(r"fatal error: '([A-Za-z0-9_]+)/[^']*' file not found", blob)
        who = re.search(r"Action failed: root(//[^\s:]+):(\S+)", blob)
        if not miss or not who:
            return False, first_error(blob)
        fw = miss.group(1)
        if fw not in fwmap:
            return False, f"no framework root for {fw}"
        key = cmake_target_for(who.group(2), nj)
        if not key:
            return False, f"no cmake target behind {who.group(2)}"
        add_extra_dep(key, fwmap[fw])
        ok, msg = generate(key, None)
        if not ok:
            return False, f"regenerating {key}: {msg}"
        added.append(fw)
    return False, f"still failing after {rounds} rounds"


def first_error(blob: str) -> str:
    """The most specific line in a buck2 failure, for a one-line report."""
    for pat in (
        r"Unknown target `([^`]+)`",
        r"fatal error: ([^\n]+)",
        r"Undefined symbols[^\n]*",
        r"error: ([^\n]{0,120})",
        r"Required outputs are missing[^\n]*",
    ):
        m = re.search(pat, blob)
        if m:
            return m.group(0).strip()
    return "failed (no recognisable error)"


# mode -> (generator flag, label of the thing to build, whether the objects it links have
# to be generated first). An archive and a dylib are just a list of cc_objects targets, and
# the generator writes THOSE only in its default mode -- so both need two passes, objects
# then the library, or the library block references targets that do not exist.
MODES = {
    "archives": ("--archives", "{}", True),
    "dylibs": ("--dylibs", "{}_dylib", True),
    "binaries": ("--binaries", "{}", True),
    # An object block is named <cmake>_obj, except when the cmake target is already
    # called ..._obj and the generator leaves the name alone.
    "objects": (None, "{}_obj", False),
}


def object_label(target: str) -> str:
    return target if target.endswith("_obj") else target + "_obj"


def dylib_label(target: str) -> str:
    """<cmake>_dylib, with a cmake target already named ..._obj losing that suffix.

    Darling's object-library-plus-two-passes pattern means the cmake target that owns
    the sources is often Foo_obj while the dylib it feeds is libFoo.dylib, and the
    generator names the block after the LIBRARY.
    """
    return target.removesuffix("_obj") + "_dylib"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for m in MODES:
        ap.add_argument(f"--{m}", action="store_const", const=m, dest="mode")
    ap.add_argument("--build-only", action="store_true", help="resolve an existing target, do not generate")
    ap.add_argument("--package", default="//buck-src", help="package the generated targets land in")
    ap.add_argument("targets", nargs="+")
    args = ap.parse_args()

    if args.build_only:
        fwmap, nj = framework_map(), ninja_text()
        rc = 0
        for label in args.targets:
            ok, msg = resolve(label, fwmap, nj)
            print(f"{'ok  ' if ok else 'FAIL'} {label}" + (f"   [{msg}]" if msg else ""))
            rc |= 0 if ok else 1
        return rc

    if not args.mode:
        ap.error("one of --archives/--dylibs/--binaries/--objects is required")
    flag, label_fmt, needs_objs = MODES[args.mode]
    fwmap, nj = framework_map(), ninja_text()

    failed = []
    for t in args.targets:
        if needs_objs:
            ok, msg = generate(t, None)
            if not ok:
                print(f"FAIL {t}   [generate objects: {msg}]")
                failed.append(t)
                continue
        ok, msg = generate(t, flag)
        if not ok:
            print(f"FAIL {t}   [generate: {msg}]")
            failed.append(t)
            continue
        if args.mode == "objects":
            name = object_label(t)
        elif args.mode == "dylibs":
            name = dylib_label(t)
        else:
            name = label_fmt.format(t)
        label = f"{package_from(msg) or args.package}:{name}"
        ok, msg = resolve(label, fwmap, nj)
        print(f"{'ok  ' if ok else 'FAIL'} {t}" + (f"   [{msg}]" if msg else ""))
        sys.stdout.flush()
        if not ok:
            failed.append(t)

    print(f"\n{len(args.targets) - len(failed)}/{len(args.targets)} built")
    if failed:
        print("failed: " + " ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
