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
OPAQUE = []
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


# Where buck2 leaves the compiled glue objects. Present only after a buck2 build; the FFI
# columns are skipped when they are not there rather than making the whole tool need one.
OBJDIR = os.path.join(
    ROOT, "buck-out/v2/art/root/1ef78538d8598cb2/src/external/darlingserver"
          "/duct-tape/__dt_objects__/__objs/src")


def ffi_surface(name):
    """How many symbols a Rust port of this file would have to export and to call out to.

    Read off the OBJECT, not the source, because that is the truth the linker sees: a
    definition the port must supply is a defined symbol, and every call it has to make across
    the FFI is an undefined one. This is a different axis from the macro count and it does
    not agree with it -- init.c has one macro and FORTY undefined symbols, which makes it a
    much bigger job than its line count or its blocker count suggests.
    """
    obj = os.path.join(OBJDIR, name + ".o")
    if not os.path.exists(obj):
        return None
    try:
        defined = subprocess.run(["nm", "--defined-only", obj],
                                 capture_output=True, text=True).stdout
        undef = subprocess.run(["nm", "-u", obj], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return None
    exports = sum(1 for l in defined.splitlines() if re.search(r" [TDBR] ", l))
    return {"exports": exports, "calls": len([l for l in undef.splitlines() if l.strip()])}


BUCK_SERVER = os.path.join(ROOT, "linux/server/BUCK")


# MEASURED COST OF REOPENING, so the OPAQUE column is read as a price and not a veto. Twice
# now I treated "it needs an opaque type reopened" as a blocker without measuring it, and both
# times the real number was small:
#   queue_.*, _?lck_.*, priority_queue.*  (what timer.c needed):  +9 structs, +7 KB
#   ipc_.*                                (what debug.c needs):  +21 structs, +27 KB
# Neither is "most of osfmk", which is what the first refusal claimed. The bindings are ~49 KB
# with the timer set reopened, so ipc roughly doubles them; that is a real cost to weigh, not
# a reason to stop.


def opaque_patterns():
    """The XNU types the shared bindings deliberately keep OPAQUE.

    Read from linux/server/BUCK so there is one source of truth. A file that dereferences
    fields of one of these cannot be ported without RELAXING that opacity, and the opacity is
    what stops struct task dragging most of osfmk into bindings the whole daemon reads. So
    this is a real cost, and it is invisible in both of the other columns.
    """
    if not os.path.exists(BUCK_SERVER):
        return []
    pats = re.findall(r'"--opaque-type=([^"]+)"', open(BUCK_SERVER).read())
    out = []
    for p in pats:
        try:
            out.append(re.compile(r"^(?:%s)(?:_t)?$" % p))
        except re.error:
            pass
    return out


def own_code_after_expansion(path, args):
    """The file's OWN code with macros expanded, and nothing from the headers.

    clang -E emits line markers naming the file each region came from, so the regions
    attributed to this .c are exactly its own text after expansion. Reading the raw source
    instead is WRONG here and was wrong when first written: timer.c never writes the name
    queue_entry, lck_mtx or priority_queue anywhere, yet mpqueue_init expands into field
    accesses on all three, so the raw-source version scored it 0 and recommended it as the
    cheapest file -- the exact file already ruled out for needing those types reopened.
    Keeping the whole -E output would be equally wrong the other way: every type in every
    header would count.
    """
    p = subprocess.run(["clang", "-E", "-x", "c", *args, path],
                       capture_output=True, text=True)
    own, keep = [], False
    target = os.path.realpath(path)
    for line in p.stdout.splitlines():
        if line.startswith("# "):
            m = re.match(r'# \d+ "([^"]*)"', line)
            if m:
                keep = os.path.realpath(m.group(1)) == target
            continue
        if keep:
            own.append(line)
    return "\n".join(own)


def opaque_types_touched(expanded, pats):
    """Distinct opaque XNU type names the file's own EXPANDED code names.

    A file that names one of these is dereferencing it, and porting it then means RELAXING
    that opacity in linux/server/BUCK. debug.c is the case that motivated the column: 4
    exports and 11 calls out, which reads cheap, while it walks ipc_space, ipc_entry,
    ipc_port, ipc_mqueue and ipc_kmsg fields.
    """
    hits = set()
    for word in set(WORD.findall(expanded)):
        base = word[:-2] if word.endswith("_t") else word
        for p in pats:
            if p.match(word) or p.match(base):
                hits.add(word)
                break
    return sorted(hits)


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
        "ffi": ffi_surface(os.path.basename(path)),
        "opaque": opaque_types_touched(own_code_after_expansion(path, args), OPAQUE),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="explain a single glue file")
    args_ns = ap.parse_args()

    cargs = clang_args()
    global OPAQUE
    OPAQUE = opaque_patterns()
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
        print(f"  OPAQUE xnu types touched ({len(r['opaque'])}): {', '.join(r['opaque']) or 'none'}")
        if r["opaque"]:
            print("    porting this means RELAXING those in linux/server/BUCK, which is what")
            print("    keeps struct task from dragging most of osfmk into the bindings")
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

    # A macro is only a blocker while it has NO Rust equivalent. dtape_stub, dtape_stub_safe
    # and dtape_stub_unsafe live in linux/server/src/dtape_stub.rs and were ported precisely so
    # that the files calling them could be, yet they kept ranking as blockers for host.c and
    # processor.c and pushed both down the list. Read the crate for macro_rules! rather than
    # keeping a hand written list here, for the same reason PORTED_TO_RUST is read from the
    # generator: a second copy drifts, and this tool is only useful if it is trusted.
    have = set()
    for dirpath, _, names in os.walk(os.path.join(ROOT, "linux/server/src")):
        for n in names:
            if n.endswith(".rs"):
                try:
                    have |= set(re.findall(r"^\s*macro_rules!\s+(\w+)",
                                           open(os.path.join(dirpath, n), errors="ignore").read(),
                                           re.M))
                except OSError:
                    pass

    # Types the bindings ALREADY allowlist, so they are bound and crossing today rather than
    # being work a port would have to do.
    allowlisted = set(re.findall(r'"--allowlist-type=([A-Za-z_][A-Za-z0-9_]*)"',
                                 open(BUCK_SERVER).read()))

    rows = []
    for f in files:
        r = measure(os.path.join(srcdir, f), cargs)
        r["ported"] = f in ported
        # The raw counts stay as measured; what changes is which of them still BLOCK.
        r["fn_blockers"] = [m for m in r["fn_macros"] if m not in have]
        r["solved"] = [m for m in r["fn_macros"] if m in have]
        rows.append((f, r))
    # cheapest first, ported files last: variadics are unfixable in Rust, so they dominate
    rows.sort(key=lambda kv: (kv[1]["ported"],
                              len(kv[1]["variadic"]) * 100
                              + len(kv[1]["fn_blockers"]) + len(kv[1]["ob_macros"])))

    print(f"{'FILE':<14}{'LINES':>7}{'VARIADIC':>9}{'FNMAC':>7}{'OBJMAC':>8}"
          f"{'EXPORTS':>9}{'CALLSOUT':>10}{'OPAQUE':>8}  blockers")
    for f, r in rows:
        top = ", ".join(r["fn_blockers"][:3])
        if r["solved"] and not r["ported"]:
            top += f" (+{len(r['solved'])} already in Rust)" if top else \
                   f"none ({len(r['solved'])} already in Rust)"
        # NAME the opaque types, do not just count them. The count alone reads as a minor
        # column, and it is not: for processor.c the two blockers are both cheap
        # (usimple_lock_init is a real symbol) while ONE of its five opaque types,
        # vm_allocation_site_t, is what makes the port expensive, because kalloc expands to a
        # statement expression that initialises one by field and vm_.* is deliberately opaque.
        # That was already visible under --file and got missed anyway, so it belongs in the
        # table where the decision is actually made. A macro CALL can hide a whole type family,
        # which makes the blocker count a lower bound on the work rather than an estimate.
        if r["opaque"] and not r["ported"]:
            # Types ALREADY allowlisted are not news: they are bound and crossing fine today.
            # Listing them first actively hides the ones that decide the cost -- the first cut
            # of this printed "host, host_t +3" for processor.c, burying vm_allocation_site_t
            # behind the +3, which is the single type that makes that port expensive.
            novel = [t for t in r["opaque"] if t not in allowlisted]
            shown = ", ".join(novel[:4]) or "all already bound"
            more = f" +{len(novel) - 4}" if len(novel) > 4 else ""
            top = f"{top} | opaque: {shown}{more}" if top else f"opaque: {shown}{more}"
        note = "PORTED (Rust)" if r["ported"] else top
        ex = str(r["ffi"]["exports"]) if r["ffi"] else "-"
        co = str(r["ffi"]["calls"]) if r["ffi"] else "-"
        print(f"{f:<14}{r['lines']:>7}{len(r['variadic']):>9}"
              f"{len(r['fn_macros']):>7}{len(r['ob_macros']):>8}{ex:>9}{co:>10}"
              f"{len(r['opaque']):>8}  {note}")
    if not any(r["ffi"] for _, r in rows):
        print("\n(EXPORTS/CALLSOUT need a buck2 build of //src/external/darlingserver"
              "/duct-tape:dt_objects)")
    done = sum(1 for _, r in rows if r["ported"])
    todo = [(f, r) for f, r in rows if not r["ported"]]
    print(f"\n{done} of {len(rows)} ported.")
    if todo:
        # The two axes disagree, so say so rather than printing one winner. Blockers say what
        # Rust CANNOT express; FFI surface says how big the job is. semaphore.c was small on
        # both, which is why it went first and worked.
        # A file touching opaque XNU types is not cheap however small its other columns
        # look, so it is not offered as the smallest-surface pick.
        by_ffi = sorted((x for x in todo if x[1]["ffi"] and not x[1]["opaque"]),
                        key=lambda kv: kv[1]["ffi"]["exports"] + kv[1]["ffi"]["calls"])
        print(f"  fewest blockers: {todo[0][0]}")
        if by_ffi:
            print(f"  smallest FFI surface: {by_ffi[0][0]} "
                  f"({by_ffi[0][1]['ffi']['exports']} exports, "
                  f"{by_ffi[0][1]['ffi']['calls']} calls out)")


if __name__ == "__main__":
    main()
