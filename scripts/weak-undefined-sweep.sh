#!/usr/bin/env bash
# WEAK UNDEFINED SYMBOLS THAT NOTHING DEFINES, which is the silent half of the symbol gap.
#
# A HARD undefined symbol stops dyld and names itself. A WEAK one binds to NULL, the process runs,
# and the first code path that calls or dereferences it faults at address 0x0 with nothing
# attached. That is why DYLD_BIND_AT_LAUNCH=1 can come back CLEAN while symbols are missing: on
# 2026-09-20 iTerm2 bound cleanly while libswiftFoundation had 21 unresolved Combine symbols, every
# one of them marked "(undefined) weak external". Task #238.
#
#   scripts/weak-undefined-sweep.sh            # count, ranking, and the full list
#   scripts/weak-undefined-sweep.sh --quiet    # just the count, for a gate
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
QUIET=""
[ "${1:-}" = "--quiet" ] && QUIET=1

RT=$(ls -dt "$REPO"/buck-out/v2/art/root/*/buck/prefix/__cider_prefix__/cider_prefix__prefix 2>/dev/null | head -1)
[ -n "$RT" ] || { echo "no built prefix: run buck2 build //buck/prefix:cider_prefix" >&2; exit 3; }
RT="$RT/libexec/cider"

NM=$(command -v llvm-nm || ls -d /nix/store/*llvm-binutils*/bin/llvm-nm 2>/dev/null | head -1)
[ -x "$NM" ] || { echo "no llvm-nm; plain nm reads nothing useful in a Mach-O tree" >&2; exit 3; }

export RT NM QUIET
python3 - <<'PY'
import os, subprocess, collections, sys

RT=os.environ["RT"]; NM=os.environ["NM"]; quiet=bool(os.environ.get("QUIET"))

# A FRAMEWORK BINARY IS A SYMLINK (X.framework/X -> Versions/Current/X), so `find -type f` skips
# every one of them and `find -L` loops on Versions/Current. Walk without following links and take
# the real file under Versions/A, which is what the symlinks point at.
libs=set()
for dirpath, dirnames, filenames in os.walk(RT, followlinks=False):
    for fn in filenames:
        p=os.path.join(dirpath, fn)
        if os.path.islink(p):
            continue
        if fn.endswith(".dylib"):
            libs.add(p)
            continue
        fw=[x for x in dirpath.split(os.sep) if x.endswith(".framework")]
        if fw and fn == fw[-1][:-len(".framework")]:
            libs.add(p)
libs=sorted(libs)

def nm(args, path):
    try:
        return subprocess.run([NM]+args+[path], capture_output=True, text=True, timeout=120).stdout
    except Exception:
        return ""

defined=set()
for f in libs:
    for line in nm(["-gU"], f).splitlines():
        parts=line.split()
        if parts: defined.add(parts[-1])

# THE CONTROL. If a symbol that certainly exists is missing from the defined set, the set is wrong
# and every absence below is noise.
for control in ("_CFRetain", "_NSLog", "_objc_msgSend"):
    if control not in defined:
        print(f"CONTROL FAILED: {control} is not in the defined set, so the scan is wrong", file=sys.stderr)
        raise SystemExit(3)

weak=collections.defaultdict(set)
for f in libs:
    for line in nm(["-m"], f).splitlines():
        if "(undefined)" in line and "weak external" in line:
            sym=line.split("weak external",1)[1].strip().split(" (from")[0].strip()
            if sym and sym not in defined:
                weak[sym].add(os.path.basename(f))

print(f"{len(libs)} Mach-O files, {len(defined)} defined symbols, "
      f"{len(weak)} weak undefined symbols nothing defines")
if quiet:
    raise SystemExit(0)

per=collections.Counter()
for sym, refs in weak.items():
    for r in refs: per[r]+=1
print("\nby referencing library:")
for lib, n in per.most_common():
    print(f"  {n:5d}  {lib}")
print("\nsymbol, then who references it:")
for sym in sorted(weak):
    print(f"  {sym}\t{','.join(sorted(weak[sym]))}")
PY
