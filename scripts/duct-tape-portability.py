#!/usr/bin/env python3
"""Rank duct-tape's glue files by what Rust genuinely CANNOT express (#71).

The port keeps the ~300 XNU sources in C and moves the glue (16 files, 8,525 lines) to
Rust. Which file to take next is not a judgement call, it is measurable, because only two
things are hard blockers:

  VARIADIC   a C variadic function DEFINITION. Stable Rust cannot write extern "C" fn(...),
             so such a function has to keep a C shim no matter how the port goes.
  MACRO      a call to a macro. bindgen binds no macros at all, so each one needs either a
             reimplementation in Rust or a C shim exporting it as a real symbol.

Everything else (struct access, plain calls, globals, enums) bindgen handles: measured, with
duct-tape's own flags, bindgen parses the XNU internal headers and emits layout assertions.

WHY THIS SCRIPT EXISTS RATHER THAN A ONE-OFF GREP. The first version of this measurement was
wrong in two ways that both flattered the answer, and it picked the wrong file:

  * it dumped macros from ONE fixed header list and intersected every file against it. A file
    that includes more sees macros that list lacks, so init.c scored a false 0 when it really
    uses dtape_log_debug, and misc.c scored 3 object-like macros when it really uses 43.
  * it counted only function-like macros, so traps.c looked like a zero-blocker file when its
    last line is DSERVER_DTAPE_DEFS, a GENERATED object-like macro.

So each file is preprocessed WITH ITS OWN INCLUDES and both macro kinds are counted. The
ranking below is the corrected one; the earlier note in the task list that named misc.c as an
easy first file was measured wrong and is the opposite of true.

Usage:
  scripts/duct-tape-portability.py                 # rank every glue file
  scripts/duct-tape-portability.py --file misc.c   # explain one file
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DT = os.path.join(ROOT, "src/external/darlingserver/duct-tape")

# duct-tape's include roots, in the BUCK file's order (dt_env).
INCLUDE_ROOTS = [
    "defines", "xnu/osfmk", "xnu/bsd", "xnu/libkern", "xnu/osfmk/libsa",
    "xnu/pexpert", "xnu/iokit", "xnu/EXTERNAL_HEADERS", "xnu",
    "internal-include", "include",
]

# A definition, not a declaration: a "..." parameter list with a body brace after it.
VARIADIC_DEF = re.compile(r"^[A-Za-z_].*\(.*\.\.\.\)\s*\{", re.M)
CALL = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
DEF_FN = re.compile(r"^#define ([A-Za-z_][A-Za-z0-9_]*)\(")
DEF_OB = re.compile(r"^#define ([A-Za-z_][A-Za-z0-9_]*)[ \t]")


FLAGS_BZL = os.path.join(ROOT, "buck/generated/duct_tape_flags.bzl")


def buck_list(name):
    """Pull a flag list from the generated flags file rather than duplicating it here.

    These lived inline in the duct-tape BUCK file until the Rust port needed the identical
    set for bindgen; a BUCK file cannot be load()ed, so gen-duct-tape-buck.py now writes
    them to buck/generated/duct_tape_flags.bzl and both BUCK files load that.
    """
    if not os.path.exists(FLAGS_BZL):
        sys.exit(f"{FLAGS_BZL} is missing; run scripts/gen-duct-tape-buck.py")
    text = open(FLAGS_BZL).read()
    m = re.search(rf"^{name} = \[(.*?)^\]", text, re.M | re.S)
    if not m:
        sys.exit(f"could not find {name} in {FLAGS_BZL}")
    return re.findall(r'"([^"]+)"', m.group(1))


def clang_args():
    incs = [f"-I{os.path.join(DT, r)}" for r in INCLUDE_ROOTS]
    incs.append(f"-I{os.path.join(ROOT, 'src/libsimple/include')}")
    incs.append(f"-I{os.path.join(ROOT, 'src/external/darlingserver/include')}")
    return buck_list("DUCT_TAPE_DEFINES") + buck_list("DUCT_TAPE_FLAGS") + incs


def macros_visible_to(path, args):
    """Every macro defined at the end of preprocessing THIS file, split by kind."""
    p = subprocess.run(["clang", "-E", "-dM", "-x", "c", *args, path],
                       capture_output=True, text=True)
    fn, ob = set(), set()
    for line in p.stdout.splitlines():
        m = DEF_FN.match(line)
        if m:
            fn.add(m.group(1))
            continue
        m = DEF_OB.match(line)
        if m:
            ob.add(m.group(1))
    return fn, ob


def measure(path, args):
    src = open(path).read()
    fn, ob = macros_visible_to(path, args)
    calls = set(CALL.findall(src))
    words = set(WORD.findall(src))
    fn_used = sorted(calls & fn)
    # object-like only counts if it is not also function-like, else it double counts
    ob_used = sorted((words & ob) - fn)
    return {
        "lines": src.count("\n"),
        "variadic": sorted(m.group(0).split("(")[0].split()[-1]
                           for m in VARIADIC_DEF.finditer(src)),
        "fn_macros": fn_used,
        "ob_macros": ob_used,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="explain a single glue file")
    args_ns = ap.parse_args()

    cargs = clang_args()
    srcdir = os.path.join(DT, "src")
    files = sorted(f for f in os.listdir(srcdir) if f.endswith(".c"))
    if not files:
        sys.exit("no glue sources found; has the port finished, or is the path wrong?")

    if args_ns.file:
        if args_ns.file not in files:
            sys.exit(f"{args_ns.file} is not a glue source (have: {', '.join(files)})")
        r = measure(os.path.join(srcdir, args_ns.file), cargs)
        print(f"{args_ns.file}: {r['lines']} lines")
        print(f"  variadic definitions ({len(r['variadic'])}): {', '.join(r['variadic']) or 'none'}")
        print(f"  function-like macros ({len(r['fn_macros'])}): {', '.join(r['fn_macros']) or 'none'}")
        print(f"  object-like macros ({len(r['ob_macros'])}): {', '.join(r['ob_macros']) or 'none'}")
        return

    # Already ported files still EXIST on disk -- duct-tape is a submodule, so a port removes
    # the file from the BUILD (PORTED_TO_RUST in gen-duct-tape-buck.py) rather than deleting
    # upstream's copy. Read that list rather than keeping a second one here, or this tool
    # goes on recommending a file that is already Rust.
    ported = set()
    gen = os.path.join(ROOT, "scripts/gen-duct-tape-buck.py")
    if os.path.exists(gen):
        m = re.search(r"^PORTED_TO_RUST = \[(.*?)^\]", open(gen).read(), re.M | re.S)
        if m:
            ported = {os.path.basename(p) for p in re.findall(r'"([^"]+)"', m.group(1))}

    rows = []
    for f in files:
        r = measure(os.path.join(srcdir, f), cargs)
        r["ported"] = f in ported
        rows.append((f, r))
    # cheapest first, ported files last: variadics are unfixable in Rust, so they dominate
    rows.sort(key=lambda kv: (kv[1]["ported"],
                              len(kv[1]["variadic"]) * 100
                              + len(kv[1]["fn_macros"]) + len(kv[1]["ob_macros"])))

    print(f"{'FILE':<14}{'LINES':>7}{'VARIADIC':>10}{'FNMACRO':>9}{'OBJMACRO':>10}  blockers")
    for f, r in rows:
        top = ", ".join(r["fn_macros"][:4])
        note = "PORTED (Rust)" if r["ported"] else top
        print(f"{f:<14}{r['lines']:>7}{len(r['variadic']):>10}"
              f"{len(r['fn_macros']):>9}{len(r['ob_macros']):>10}  {note}")
    done = sum(1 for _, r in rows if r["ported"])
    print(f"\n{done} of {len(rows)} ported; next by this ranking: "
          f"{next((f for f, r in rows if not r['ported']), 'none left')}")


if __name__ == "__main__":
    main()
