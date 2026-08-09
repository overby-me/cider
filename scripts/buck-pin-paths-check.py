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
import subprocess
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


def sdk_key_namespace():
    """The sdk maps have TWO sides, and only one of them was ever checked here.

    An entry is {staged include path: source}. The VALUE is a path or label into a pin,
    which the other sources above resolve. The KEY is the path the header is staged AT,
    and UPSTREAM code names that too: the xnu pin's own os/tsd.h does

        #include <darling/emulation/linux_premigration/linux-syscalls/linux.h>

    The Cider sweep rewrote 302 of those keys to cider/emulation, so the headers were
    staged where nothing looks for them, and 39 compiles failed an HOUR into the endpoint
    with the include not found. Restoring the values, which this file already did, left
    the keys wrong.

    CHECKED BY CONSISTENCY, not by a hardcoded name, because cider/ IS a legitimate SDK
    namespace elsewhere: usr/include/cider/mldr/elfcalls/dthreads.h is ours and resolves.
    The rule is that the key and the value must agree about whose namespace it is. If the
    key begins cider/ while the value names a darling_ target inside a pin, one of them is
    wrong, and it is the key.
    """
    for name, root in SDK_MAPS.items():
        path = os.path.join(GEN, name)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for key, value in re.findall(r'"([^"]+)":\s*"([^"]+)"', fh.read()):
                if key.startswith("cider/") and "darling" in value:
                    yield f"buck/generated/{name}", f"KEY {key} but VALUE {value}"


SDK_NAMESPACES = ("cider/", "darling/")


def first_party_includes():
    """And the THIRD side: what our own code asks for must be what gets staged.

    sdk_headers.bzl stages a header AT a key, and code includes it BY that key. The
    Cider sweep rewrote both, so restoring only the keys left our own sources asking
    for the other name and run 9 died at 2,829 builders on

        FSEventsImpl.m:26 fatal error:
          'cider/emulation/linux_premigration/ext/sys/inotify.h' file not found

    darling/ is the right namespace and that is measured, not preferred: the pins
    include it 1,839 times and we include it 16.

    Only the two namespaces staged through this map are checked, so an include that
    resolves through some other -I root is not dragged in. Negative control: with the
    sweep as it stood, all 16 were missing; a correct tree has none.
    """
    files = subprocess.run(["jj", "file", "list"], capture_output=True, text=True).stdout
    keys = set()
    with open(os.path.join(GEN, "sdk_headers.bzl"), encoding="utf-8") as fh:
        keys = set(re.findall(r'^\s*"([^"]+)":', fh.read(), re.M))
    inc = re.compile(r'#\s*include\s*<((?:' + "|".join(
        n.rstrip("/") for n in SDK_NAMESPACES) + r')/[^>]+)>')
    for rel in files.splitlines():
        if not rel.endswith((".c", ".h", ".m", ".mm", ".cpp")):
            continue
        if rel.startswith(("buck-src/", "patches/")):
            continue
        try:
            with open(rel, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        for path in inc.findall(text):
            if path not in keys:
                yield rel, f"includes <{path}>, which sdk_headers.bzl does not stage"


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
    # This one yields FINDINGS rather than candidate paths: the key and the value
    # disagree about whose namespace the header lives in, and there is nothing to stat.
    ns = list(sdk_key_namespace())
    print(f"{'sdk_key_namespace':18s} {len(ns):5d} disagreements")
    missing += ns
    fp = list(first_party_includes())
    print(f"{'first_party_incl':18s} {len(fp):5d} unstaged includes")
    missing += fp

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

    print(f"\nPASS: all {checked} pin paths resolve, and every sdk key agrees with its value")
    return 0


if __name__ == "__main__":
    sys.exit(main())
