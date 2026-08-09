#!/usr/bin/env python3
"""Every path we record INTO an upstream pin must exist on disk.

buck-src/<pin> is an upstream darlinghq repo, and 43 of those pins carry their
own darling/ subdirectory (plus cfnetwork/darling-framework and the darling-dmg
pin itself). We name paths inside them from four places, all of them generated
or hand-maintained tables of plain strings:

    buck/generated/exports_<pin>.bzl    {export target: pin-relative path}
    buck/generated/sdk_headers.bzl      {SDK header: buck-src-relative path}
    buck/generated/sdk_framework*.bzl   same, per framework
    nix/submodules.json                 the pin fetch manifest

Strings are not checked by anything until something stages them, so a bad one
survives evaluation, survives every compile, and fails only when a pin is
actually fetched or a header actually staged. The Cider rename wrote 1,700 of
them at once: it rewrote our references to the pins' darling/ directories while
leaving the pins themselves untouched, and the first thing that noticed was the
overnight endpoint failing to patch xnu.

NEGATIVE CONTROL, measured rather than assumed: run against the tree as the
rename left it, this reported 1,477 missing exports srcs, 35 missing framework
paths and 1 unresolvable submodule path. It is not a check that cannot fail.

Exit 0 if every path resolves, 1 otherwise, listing what does not.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "buck", "generated")

# {"key": "value"} on one line is what every one of these tables emits.
PAIR = re.compile(r'":\s*"([^"]+)"')


def exports_srcs():
    """exports_<pin>.bzl values are relative to the pin, exports_buck_src.bzl
    to buck-src itself: that file is the //buck-src root package, not a pin."""
    for name in sorted(os.listdir(GEN)):
        m = re.fullmatch(r"exports_(.+)\.bzl", name)
        if not m:
            continue
        pin = m.group(1)
        base = "buck-src" if pin == "buck_src" else os.path.join("buck-src", pin)
        with open(os.path.join(GEN, name), encoding="utf-8") as fh:
            for src in PAIR.findall(fh.read()):
                yield f"buck/generated/{name}", os.path.join(base, src)


# Each sdk map is rooted somewhere different; the file name is the only thing
# that says where, so the root belongs beside the name rather than guessed.
SDK_MAPS = {
    "sdk_headers.bzl": "buck-src",
    "sdk_framework_buck_src.bzl": "buck-src",
    "sdk_framework_private_buck_src.bzl": "buck-src",
    "sdk_framework_darwin_Developer.bzl": "darwin/Developer",
}


def sdk_paths():
    """The sdk maps hold paths and //buck2 labels side by side; only the paths
    are ours to resolve, and each file is rooted at its own tree."""
    for name, root in SDK_MAPS.items():
        path = os.path.join(GEN, name)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for val in PAIR.findall(fh.read()):
                if val.startswith("//") or val.startswith(":"):
                    continue
                yield f"buck/generated/{name}", os.path.join(root, val)


def submodule_paths():
    """The manifest keys a pin by its src/external path; the last component is
    the buck-src directory the pin is checked out as."""
    with open(os.path.join(ROOT, "nix", "submodules.json"), encoding="utf-8") as fh:
        for entry in json.load(fh):
            p = entry["path"]
            yield "nix/submodules.json", os.path.join("buck-src", p.split("/")[-1])


def present(path):
    """lexists, not exists, and the difference is the whole point.

    darwin/Developer is a tree of symlinks written for the STAGED layout, where
    pins live at src/external/<pin>; in a checkout they live at buck-src/<pin>,
    so 2,002 of its 2,636 links dangle here and resolve in the build. Following
    them would report a couple of thousand false failures. What this check is
    for is whether the path we RECORDED is a real entry, and a path mangled by a
    rename is not an entry at all: the 1,477 the rename produced all fail
    lexists too.
    """
    return os.path.lexists(path)


def main():
    os.chdir(ROOT)
    checked = 0
    missing = []
    for source in (exports_srcs, sdk_paths, submodule_paths):
        n = 0
        bad = []
        for origin, path in source():
            n += 1
            if not present(path):
                bad.append((origin, path))
        print(f"{source.__name__:18s} {n:5d} paths, {len(bad)} missing")
        checked += n
        missing += bad

    if missing:
        print(f"\n{len(missing)} of {checked} pin paths do not exist:")
        for origin, path in missing[:40]:
            print(f"  {origin}: {path}")
        if len(missing) > 40:
            print(f"  ... and {len(missing) - 40} more")
        print("\nFAIL: a reference names a directory inside a pin that is not there.")
        print("Pins are upstream and keep their darling/ subdirectories; only our own")
        print("code is Cider. Check any recent rename against buck-src/<pin>/.")
        return 1

    print(f"\nPASS: all {checked} pin paths resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
