#!/usr/bin/env python3
"""Every symbol LibreOffice needs from the SYSTEM that Cider does not export.

Discovering these one container run at a time costs a run per symbol, and dyld reports exactly
one before aborting. This answers the whole question at once: collect what the app's Mach-O
files leave undefined, subtract everything the app itself defines, and subtract everything the
prefix defines. What remains is the gap, grouped by the library dyld would look in.
"""
import os
import subprocess
import sys
from collections import defaultdict

APP = sys.argv[1]
PREFIX = sys.argv[2]


def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
    except OSError:
        return False


def macho_files(root, limit_dirs=None):
    out = []
    for dirpath, _dirnames, filenames in os.walk(root):
        if limit_dirs and not any(d in dirpath for d in limit_dirs):
            continue
        for name in filenames:
            p = os.path.join(dirpath, name)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            if is_macho(p):
                out.append(p)
    return out


def symbols(path):
    """(undefined, defined) for one Mach-O, from llvm-nm."""
    try:
        r = subprocess.run(["llvm-nm", "--no-sort", path], capture_output=True, text=True, timeout=120)
    except Exception:
        return set(), set()
    und, dfn = set(), set()
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "U":
            und.add(parts[1])
        elif len(parts) == 3 and parts[1] in "TDSBRCtdsbr":
            dfn.add(parts[2])
        elif len(parts) == 2 and parts[0] in "TDSBRCtdsbr":
            dfn.add(parts[1])
    return und, dfn


app_files = macho_files(APP)
print(f"app Mach-O files: {len(app_files)}", file=sys.stderr)

app_und, app_def = set(), set()
for p in app_files:
    u, d = symbols(p)
    app_und |= u
    app_def |= d

wanted = app_und - app_def
print(f"symbols wanted from outside the bundle: {len(wanted)}", file=sys.stderr)

prefix_files = macho_files(PREFIX, limit_dirs=["/usr/lib", "/System/Library"])
print(f"prefix Mach-O files: {len(prefix_files)}", file=sys.stderr)

prefix_def = set()
by_lib = {}
for p in prefix_files:
    _u, d = symbols(p)
    prefix_def |= d
    by_lib[p] = d

missing = sorted(wanted - prefix_def)
print(f"\nMISSING: {len(missing)} of {len(wanted)}\n")

# Group by the library each one is most plausibly expected in, using the app's own load records.
groups = defaultdict(list)
for s in missing:
    if s.startswith("_kCT") or s.startswith("_CT"):
        groups["CoreText"].append(s)
    elif s.startswith("_kCF") or s.startswith("_CF"):
        groups["CoreFoundation"].append(s)
    elif s.startswith("_NS") or s.startswith("_kNS"):
        groups["Foundation/AppKit"].append(s)
    elif s.startswith("_CG") or s.startswith("_kCG"):
        groups["CoreGraphics"].append(s)
    elif s.startswith("_OBJC_CLASS_$_"):
        groups["ObjC classes"].append(s)
    elif s.startswith("_objc_") or s.startswith("_class_") or s.startswith("_sel_"):
        groups["ObjC runtime"].append(s)
    else:
        groups["other"].append(s)

for name in sorted(groups, key=lambda k: -len(groups[k])):
    items = groups[name]
    print(f"== {name}: {len(items)}")
    for s in items[:40]:
        print(f"     {s}")
    if len(items) > 40:
        print(f"     ... and {len(items) - 40} more")
    print()
