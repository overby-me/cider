#!/usr/bin/env python3
"""Stage the built darling-testsuite cases into a container prefix (task #123).

The suite is a regression net for AppKit and libc, and it lives in the container rather than in
buck-out: the cases are guest binaries, so they have to be run through `cider shell`. Re-creating
that staging by hand costs an hour and gets one detail wrong every time, which is what this is for.

Two details are the ones that get lost:

RESOURCES KEEP THEIR PATHS. A case asks for its resource by the path it has in the source tree:

    grab_full_resource_path(c, "testsuite/usr/lib/system/libsystem_kernel.dylib/read/resources/read_hello_world.txt")

so DARLING_TESTSUITE_RESOURCE_PATH must point at a directory that still has `testsuite/...` under
it. Copying every `resource`/`resources` directory into one flat directory makes `test_read_file`
fail its `fd >= 0` assertion, which reads exactly like a libc defect and is not one.

THE RUNNER MUST NOT EAT THE CASE OUTPUT. An AppKit case prints two lines of backend greeting before
anything of its own, so a runner that keeps the first two lines keeps nothing that matters. A case
that prints on its happy path then looks as silent as one that never ran.

Usage: scripts/stage-testsuite.py [--prefix /tmp/cider-appkit-1000/prefix]
       Build first: buck2 build --keep-going --show-output $(targets) > outputs.txt
       or let this run buck2 itself with --build.
"""
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = "vendor/src/darling-testsuite"

RUNNER = """#!/bin/sh
DARLING_TESTSUITE_RESOURCE_PATH=/tmp/dts-res
export DARLING_TESTSUITE_RESOURCE_PATH
cd /tmp/dts-res
for f in /tmp/dts/dts_*; do
  [ -x "$f" ] || continue
  out=$("$f" 2>&1)
  code=$?
  echo "DTSRESULT $code $(basename $f)"
  echo "$out" | grep -v "^cider-wayland" | head -3 | sed 's/^/DTSOUT /'
done
echo DTSDONE
"""


def case_targets():
    body = open(os.path.join(REPO, "vendor/src/BUCK"), errors="replace").read()
    names = re.findall(r'name = "(dts_[A-Za-z0-9_]*)"', body)
    return ["//vendor/src:" + n for n in names if not n.endswith("_obj")]


def build(targets):
    """--keep-going, because the libxpc group does not build and the rest still should."""
    out = subprocess.run(
        ["buck2", "build", "--keep-going", "--show-output"] + targets,
        cwd=REPO, capture_output=True, text=True,
    ).stdout
    return [l.split(None, 1)[1] for l in out.split("\n") if l.startswith("root//") and " " in l]


def stage(prefix, paths):
    dts = os.path.join(prefix, "tmp/dts")
    res = os.path.join(prefix, "tmp/dts-res")
    os.makedirs(dts, exist_ok=True)
    if os.path.exists(res):
        shutil.rmtree(res)
    os.makedirs(res)

    staged = 0
    for p in paths:
        full = os.path.join(REPO, p)
        if not os.path.isfile(full):
            continue
        shutil.copy2(full, os.path.join(dts, os.path.basename(full)))
        staged += 1

    dirs = 0
    for root, _sub, _files in os.walk(os.path.join(REPO, SUITE)):
        if os.path.basename(root) not in ("resource", "resources"):
            continue
        rel = os.path.relpath(root, os.path.join(REPO, SUITE))
        target = os.path.join(res, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copytree(root, target, symlinks=True)
        dirs += 1

    runner = os.path.join(dts, "run.sh")
    open(runner, "w").write(RUNNER)
    os.chmod(runner, 0o755)
    return staged, dirs


def main():
    prefix = "/tmp/cider-appkit-1000/prefix"
    if "--prefix" in sys.argv:
        prefix = sys.argv[sys.argv.index("--prefix") + 1]
    targets = case_targets()
    print(f"{len(targets)} case targets")
    paths = build(targets)
    print(f"{len(paths)} built")
    staged, dirs = stage(prefix, paths)
    print(f"staged {staged} binaries and {dirs} resource directories into {prefix}/tmp")
    print("run it with scratchpad/run-dts-wayland.sh, NEVER headless: an AppKit case dies at its")
    print("first use of a display that correctly declined to exist, which reads as a crash in us.")


if __name__ == "__main__":
    main()
