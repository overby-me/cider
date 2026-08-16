#!/usr/bin/env python3
"""Which symbols a Mach-O binary needs that NOTHING in this prefix exports.

THE LIBRARIES LOADING IS NOT THE SAME AS THE APPLICATION RUNNING. macho-needs.py answers the first
question; this answers the second, and the second is where a port actually spends its time. dyld
reports one missing symbol per run, so finding thirty of them costs thirty runs unless the whole set
is computed at once.

Exports are read from every Mach-O under the runtime and prefix trees, which is what the two level
namespace will search, and the answer is the set difference. A symbol reported here is one dyld will
stop on, in some order nobody controls.

    scripts/macho-undefined.py <binary> [prefix] [runtime]

Needs llvm-nm: the host nm cannot read Mach-O and reports nothing at all for every file, which is a
check that cannot fail rather than a clean result.
"""
import os
import subprocess
import sys

NM = "/nix/store/0m6d7ckkm9wl4vbwdkyzicvb3wxm11m4-llvm-22.1.8/bin/llvm-nm"
MACHO_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def is_macho(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4) in MACHO_MAGIC
    except OSError:
        return False


def symbols(path, undefined):
    flag = "--undefined-only" if undefined else "--defined-only"
    try:
        out = subprocess.run([NM, flag, "--arch=x86_64", path],
                             capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    found = set()
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        name = parts[-1]
        if name.startswith("_"):
            found.add(name)
    return found


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    target = sys.argv[1]
    roots = sys.argv[2:] or ["/tmp/cider-appkit-1000/rt/libexec/cider",
                             "/tmp/cider-appkit-1000/prefix"]

    if not os.path.exists(NM):
        print(f"llvm-nm not at {NM}; the host nm cannot read Mach-O and would report nothing")
        return 2

    wanted = symbols(target, undefined=True)
    print(f"undefined={len(wanted)}")

    exported = set()
    scanned = 0
    for root in roots:
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not is_macho(path):
                    continue
                # The bundle under test exports its own symbols; counting them would hide
                # exactly the gaps this is for.
                if os.path.abspath(path) == os.path.abspath(target):
                    continue
                exported |= symbols(path, undefined=False)
                scanned += 1

    print(f"scanned={scanned} exported={len(exported)}")
    gap = sorted(wanted - exported)
    print(f"unresolved={len(gap)}")
    for name in gap:
        print(f"UNRESOLVED {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
