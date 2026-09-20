#!/usr/bin/env bash
# WEAK UNDEFINED SYMBOLS THAT NOTHING DEFINES, which is the silent half of the symbol gap.
#
# A HARD undefined symbol stops dyld and names itself. A WEAK one binds to NULL, the process runs,
# and the first code path that calls or dereferences it faults at address 0x0 with nothing
# attached. That is why DYLD_BIND_AT_LAUNCH=1 can come back CLEAN while symbols are missing: on
# 2026-09-20 iTerm2 bound cleanly while libswiftFoundation had 21 unresolved Combine symbols, every
# one of them marked "(undefined) weak external". Task #238.
#
# THE APPLICATIONS ARE SCANNED TOO, and until 2026-09-20 they were not. Scanning only the runtime
# tree answers "what do our own libraries fail to resolve", which is a different question from "what
# does a real application ask for and not get". The loader trace added in vendor/patches/dyld/0010
# caught three in iTerm2's main binary that this script reported zero of, because the binary was
# never opened. Every staged prefix is included now.
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

APPS=$(ls -d /tmp/cider-*-1000/prefix/Applications 2>/dev/null | tr '\n' ':')

export RT NM QUIET APPS
python3 - <<'PY'
import os, subprocess, collections, sys

RT=os.environ["RT"]; NM=os.environ["NM"]; quiet=bool(os.environ.get("QUIET"))
APPS=[d for d in os.environ.get("APPS","").split(":") if d]

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

# The applications, kept apart from the runtime tree because they are the QUESTION, not the answer:
# nothing they fail to resolve can be blamed on them, and a symbol only they want still counts.
apps=set()
for root in APPS:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if "/Contents/MacOS" not in dirpath and not dirpath.endswith(".framework/Versions/A"):
            continue
        for fn in filenames:
            p=os.path.join(dirpath, fn)
            if os.path.islink(p) or not os.access(p, os.X_OK):
                continue
            with open(p, "rb") as fh:
                if fh.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                    continue
            apps.add(p)
apps=sorted(apps)

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

# An application's own frameworks define symbols its main binary imports, so they join the defined
# set. They are NOT added for the runtime tree's benefit: a runtime library that resolved against an
# application bundle would be a defect, and none does.
for f in apps:
    for line in nm(["-gU"], f).splitlines():
        parts=line.split()
        if parts: defined.add(parts[-1])

weak=collections.defaultdict(set)
appweak=collections.defaultdict(set)
for f, bucket in [(f, weak) for f in libs] + [(f, appweak) for f in apps]:
    for line in nm(["-m"], f).splitlines():
        if "(undefined)" in line and "weak external" in line:
            sym=line.split("weak external",1)[1].strip().split(" (from")[0].strip()
            if sym and sym not in defined:
                bucket[sym].add(os.path.basename(f))

print(f"{len(libs)} runtime Mach-O files and {len(apps)} application binaries, "
      f"{len(defined)} defined symbols, "
      f"{len(weak)} weak undefined in the runtime and {len(appweak)} in applications "
      f"that nothing defines")
if quiet:
    raise SystemExit(0)

for title, table in (("runtime", weak), ("applications", appweak)):
    if not table:
        print(f"\n{title}: none")
        continue
    per=collections.Counter()
    for sym, refs in table.items():
        for r in refs: per[r]+=1
    print(f"\n{title}, by referencing binary:")
    for lib, n in per.most_common():
        print(f"  {n:5d}  {lib}")
    print(f"\n{title}, symbol then who references it:")
    for sym in sorted(table):
        print(f"  {sym}\t{','.join(sorted(table[sym]))}")
PY
