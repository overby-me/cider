#!/usr/bin/env python3
"""Resolve a perf profile of a guest process into Mach-O symbols.

perf cannot read Mach-O, so every frame of every guest stack comes out as a bare address and a
profile of this process says nothing at all. The mapping list in the perf data has the base address
of each image, and nm on the image has the symbols, so the two together are enough: this joins them.

The image paths recorded by the kernel are the ones the guest sees through its union mount, which do
not exist on the host. The runtime tree is where the files really are, so a path that is missing is
retried there before being given up on.
"""
import collections
import re
import subprocess
import sys

PERF = "/nix/store/kh90fg72bnm1qfqhsygyklr3iaz1ygan-perf-linux-7.1.7/bin/perf"
NM = "/nix/store/0m6d7ckkm9wl4vbwdkyzicvb3wxm11m4-llvm-22.1.8/bin/llvm-nm"
PREFIX = "/tmp/cider-appkit-1000/prefix"
RT = "/tmp/cider-appkit-1000/rt/libexec/cider"

data = sys.argv[1]

maps = []   # (start, end, pgoff, path)
mmap_re = re.compile(r"PERF_RECORD_MMAP2 \d+/\d+: \[(0x[0-9a-f]+)\((0x[0-9a-f]+)\) @ (\S+) .*?\]: \S+ (\S+)")
out = subprocess.run([PERF, "script", "-i", data, "--show-mmap-events", "-F", "comm,pid,tid,ip,dso"],
                     capture_output=True, text=True).stdout
for line in out.splitlines():
    m = mmap_re.search(line)
    if m:
        start = int(m.group(1), 16)
        size = int(m.group(2), 16)
        pgoff = int(m.group(3), 16) if m.group(3).startswith("0x") else int(m.group(3))
        maps.append((start, start + size, pgoff, m.group(4)))
maps.sort()

tables = {}
def table_for(path):
    if path in tables:
        return tables[path]
    real = path
    try:
        open(real, "rb").close()
    except OSError:
        real = path.replace(PREFIX, RT)
    syms = []
    try:
        res = subprocess.run([NM, "-n", "--defined-only", real], capture_output=True, text=True)
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[1].upper() == "T":
                try:
                    syms.append((int(parts[0], 16), parts[2]))
                except ValueError:
                    pass
    except OSError:
        pass
    syms.sort()
    tables[path] = syms
    return syms

def resolve(ip):
    for start, end, pgoff, path in maps:
        if start <= ip < end:
            syms = table_for(path)
            off = ip - start + pgoff
            best = None
            lo, hi = 0, len(syms)
            while lo < hi:
                mid = (lo + hi) // 2
                if syms[mid][0] <= off:
                    lo = mid + 1
                else:
                    hi = mid
            if lo:
                best = syms[lo - 1]
            name = path.rsplit("/", 1)[-1]
            if best:
                return f"{name}!{best[1]}"
            return f"{name}+{off:#x}"
    return "?"

# Samples, each a list of frames leaf first.
samples = []
current = []
for line in subprocess.run([PERF, "script", "-i", data], capture_output=True, text=True).stdout.splitlines():
    if not line.strip():
        if current:
            samples.append(current)
            current = []
        continue
    m = re.match(r"\s+([0-9a-f]+)\s", line)
    if m:
        current.append(int(m.group(1), 16))
if current:
    samples.append(current)

leaves = collections.Counter()
stacks = collections.Counter()
for frames in samples:
    named = [resolve(ip) for ip in frames[:14]]
    if not named:
        continue
    leaves[named[0]] += 1
    # The first frame that is not a memory primitive, which is the code doing the work.
    interesting = [n for n in named
                   if not re.search(r"platform_(memset|memmove|bzero)|memset_pattern", n)]
    if interesting:
        stacks[" <- ".join(interesting[:6])] += 1

total = len(samples)
print(f"samples={total}")
print("\n--- LEAF")
for name, count in leaves.most_common(12):
    print(f"{100.0*count/total:6.2f}%  {name}")
print("\n--- CALLERS, memory primitives folded away")
for name, count in stacks.most_common(14):
    print(f"{100.0*count/total:6.2f}%  {name}")
