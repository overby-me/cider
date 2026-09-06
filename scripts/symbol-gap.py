#!/usr/bin/env python3
"""Which symbols anything in a tree needs that NOTHING in that tree defines.

    scripts/symbol-gap.py <tree>        e.g. the built prefix's libexec/cider

macho-undefined.py answers this for ONE binary against the prefix; this answers it for the whole
tree at once, and groups the answer by who needs it, because the consumer decides whether a gap
can ever be reached.

BOTH llvm-nm line shapes have to be handled.

    0000000000005c10 T __platform_memset_pattern16     addr, type, name
                     I _memset_pattern4 (indirect for __platform_...)   type, name, prose
    _CGEventTapCreateForPSN                            undefined: BARE NAME, no type letter

Taking parts[-1] gets the indirect one wrong (it reads the target, so the alias looks undefined).
Taking the token after the type letter gets the bare one wrong (it returns nothing, so EVERY
undefined symbol disappears and the gap reads zero). Both mistakes were made here; hence the
self-check at the bottom, which fails loudly rather than printing a confident number.
"""
import os, subprocess, sys, collections
NM = "/nix/store/0m6d7ckkm9wl4vbwdkyzicvb3wxm11m4-llvm-22.1.8/bin/llvm-nm"
MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")

def is_macho(p):
    try:
        with open(p, "rb") as h: return h.read(4) in MAGIC
    except OSError: return False

def name_of(line):
    t = line.split()
    if not t: return None
    if len(t) == 1: return t[0]
    for i, tok in enumerate(t):
        if len(tok) == 1 and tok.isalpha() and i + 1 < len(t):
            return t[i + 1]
    return t[-1]

def syms(p, undef):
    flag = "--undefined-only" if undef else "--defined-only"
    try:
        out = subprocess.run([NM, flag, "--arch=x86_64", p], capture_output=True, text=True, timeout=120).stdout
    except Exception: return set()
    return {n for n in (name_of(l) for l in out.splitlines()) if n and n.startswith(("_", "$"))}

assert name_of("0000000000005c10 T __platform_memset_pattern16") == "__platform_memset_pattern16"
assert name_of("                 I _memset_pattern4 (indirect for __platform_memset_pattern4)") == "_memset_pattern4"
assert name_of("_CGEventTapCreateForPSN") == "_CGEventTapCreateForPSN"

root = sys.argv[1]
files = [os.path.join(d, n) for d, _, ns in os.walk(root) for n in ns
         if not os.path.islink(os.path.join(d, n)) and is_macho(os.path.join(d, n))]
defined, undefined = set(), collections.defaultdict(set)
for p in files:
    defined |= syms(p, False)
    for s in syms(p, True): undefined[s].add(p)
assert undefined, "no undefined symbols read at all: the parser is broken again"
gap = sorted(s for s in undefined if s not in defined)
def pyobjc(p): return "/PyObjC/" in p or "Python.framework" in p
rest = [s for s in gap if not all(pyobjc(p) for p in undefined[s])]
print(f"files {len(files)}; undefined names {len(undefined)}; defined names {len(defined)}")
print(f"gap {len(gap)}: PyObjC only {len(gap) - len(rest)}, rest {len(rest)}")
byfile = collections.Counter()
for s in rest:
    for p in undefined[s]:
        if not pyobjc(p): byfile[os.path.basename(p)] += 1
print("\nwho needs the rest:")
for name, n in byfile.most_common(20): print(f"  {n:4d}  {name}")
print("\nnon-Swift, non-Kerberos consumers:")
for s in rest:
    who = [os.path.basename(p) for p in undefined[s] if not pyobjc(p)]
    if all(("libswift" in w or "Kerberos" in w) for w in who): continue
    print(f"  {s}  <- {', '.join(sorted(set(who))[:3])}")
