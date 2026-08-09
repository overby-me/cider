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
  scripts/xnu-sys-portability.py                 # rank every glue file
  scripts/xnu-sys-portability.py --file misc.c   # explain one file
"""

import argparse
import glob
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OPAQUE = []
DT = os.path.join(ROOT, "src/external/ciderd/xnu-sys")

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


def generated_include_roots():
    """The GENERATED header trees, discovered under buck-out.

    WITHOUT THESE THE PREPROCESSOR FAILS AND THE TOOL REPORTS THE PARTIAL RESULT AS IF IT WERE
    THE ANSWER. Measured: debug.c and traps.c both died on ciderd/rpc.internal.h and
    host.c on mach/mach_host.h, and every one of them still produced thousands of macros for
    the columns to be computed from. That is how traps.c came to rank FIRST with zero blockers
    in every run: its one blocker, DSERVER_DTAPE_DEFS, is defined in rpc.internal.h, the very
    header that was not found.

    mig FIRST, matching the include order linux/server/BUCK documents: mach/task.h exists both
    as a MIG output and as a hand-written XNU header, and the generated one is the right one.
    """
    roots = []
    roots += sorted(glob.glob(os.path.join(
        ROOT, "buck-out/v2/art/root/*/src/external/ciderd/xnu-sys/__mig_*__/mig_*__gen")))
    roots += sorted(glob.glob(os.path.join(
        ROOT, "buck-out/v2/art/root/*/src/external/ciderd/__dserver_rpc__/*gen_include")))
    # thread.c reaches src/startup for rtsig.h, which linux/server/BUCK also lists.
    roots += sorted(glob.glob(os.path.join(
        ROOT, "buck-out/v2/art/root/*/src/startup/__rtsig_header__/*")))
    return [r for r in roots if os.path.isdir(r)]


def clang_args():
    incs = [f"-I{r}" for r in generated_include_roots()]
    incs += [f"-I{os.path.join(DT, r)}" for r in INCLUDE_ROOTS]
    incs.append(f"-I{os.path.join(ROOT, 'src/libsimple/include')}")
    incs.append(f"-I{os.path.join(ROOT, 'src/external/ciderd/include')}")
    return buck_list("DUCT_TAPE_DEFINES") + buck_list("DUCT_TAPE_FLAGS") + incs


def preprocesses_cleanly(path, args):
    """Did the preprocessor actually get through this file, or is the measurement partial?

    A check the tool did without for far too long. clang -E keeps going after a missing header
    and prints what it had, so a truncated run is indistinguishable from a clean one in the
    OUTPUT; the only signal is the exit status, which nothing was reading.
    """
    r = subprocess.run(["clang", "-E", "-dM", "-x", "c", *args, path],
                       capture_output=True, text=True)
    if r.returncode == 0:
        return None
    for line in r.stderr.splitlines():
        if "fatal error" in line:
            return line.strip().split("fatal error:")[-1].strip()
    return "preprocessing failed"


def macros_visible_to(path, args):
    """Every macro defined at the end of preprocessing THIS file, split by kind.

    Object-like macros are split again, into plain values and ones that EMIT CODE. bindgen
    binds a plain integer define, so those are not blockers; a macro whose body contains a
    brace or a semicolon expands to declarations or statements and bindgen cannot help at all.
    That distinction is what traps.c turns on: its single object-like macro,
    DSERVER_DTAPE_DEFS, expands to about 29 function DEFINITIONS, and while it was lumped in
    with the constants the file read as blocker-free in every run.
    """
    p = subprocess.run(["clang", "-E", "-dM", "-x", "c", *args, path],
                       capture_output=True, text=True)
    fn, ob, code = set(), set(), set()
    for line in p.stdout.splitlines():
        m = DEF_FN.match(line)
        if m:
            fn.add(m.group(1))
            continue
        m = DEF_OB.match(line)
        if m:
            ob.add(m.group(1))
            body = line.split(" ", 2)[2] if line.count(" ") >= 2 else ""
            if "{" in body or ";" in body:
                code.add(m.group(1))
    return fn, ob, code


# Where buck2 leaves the compiled glue objects. Present only after a buck2 build; the FFI
# columns are skipped when they are not there rather than making the whole tool need one.
OBJDIR = os.path.join(
    ROOT, "buck-out/v2/art/root/1ef78538d8598cb2/src/external/ciderd"
          "/xnu-sys/__dt_objects__/__objs/src")


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


def archive_defined_symbols():
    """Symbols the duct-tape archive DEFINES, for deciding whether a macro is really a blocker.

    A macro that merely forwards to a real function is not a blocker: Rust cannot DEFINE a C
    variadic but it can CALL one, which is how semaphore.rs calls panic. dtape_log_debug is the
    same shape,

        #define dtape_log_debug(format, ...) dtape_log(dtape_log_level_debug, format, ...)

    and dtape_log is T in the archive, so a port calls it and moves on. Counting it as a blocker
    kept init.c looking blocked when it is not.
    """
    a = os.path.join(ROOT, "buck-out/v2/art/root/1ef78538d8598cb2/linux/server"
                           "/__duct_tape_lib__/duct_tape_lib/libciderd_duct_tape.a")
    if not os.path.exists(a):
        return set()
    try:
        out = subprocess.run(["nm", "--defined-only", a],
                             capture_output=True, text=True).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return set(re.findall(r"^[0-9a-f]* [TDBRW] (\w+)$", out, re.M))


def macros_that_only_forward(path, args, macro_names, defined):
    """Of these macros, the ones whose expansion just calls a symbol that already exists."""
    if not macro_names or not defined:
        return set()
    p = subprocess.run(["clang", "-E", "-dM", "-x", "c", *args, path],
                       capture_output=True, text=True)
    bodies = {}
    for line in p.stdout.splitlines():
        m = re.match(r"#define (\w+)\([^)]*\)\s+(.*)", line)
        if m:
            bodies[m.group(1)] = m.group(2)
    out = set()
    for name in macro_names:
        body = bodies.get(name, "").strip()
        # A NO-OP is not a blocker either, and this is not a corner case: XNU compiles its
        # tracing away, so KERNEL_DEBUG(x,a,b,c,d,e) is literally `do {} while (0)`. A Rust port
        # omits the call and loses nothing. MACHDBG_CODE only ever appears as an ARGUMENT to
        # KERNEL_DEBUG, so it never evaluates either, but it was being counted all the same.
        if body in ("", "do {} while (0)", "do { } while (0)", "(void)0", "((void)0)"):
            out.add(name)
            continue
        called = set(re.findall(r"\b(\w+)\s*\(", body))
        if called & defined:
            out.add(name)
    return out


def keep_only_types(path, args, candidates):
    """Which of these identifiers are actually TYPES, asked of the compiler.

    THE OPAQUE PATTERNS ARE REGEXES OVER NAMES, so they match FUNCTIONS just as happily as
    types. `ipc_.*` was counting ipc_init, ipc_entry_lookup, ipc_mqueue_copyin,
    ipc_kmsg_queue_next and ipc_mqueue_set_gather_member_names as opaque TYPES a port would
    have to reopen. Every one of those is a function, which a port simply CALLS. The effect was
    not neutral: it inflated the apparent cost of init.c (23) and debug.c (13), the two files
    being deferred on exactly that number.

    Short of parsing C there is no way to tell from the text, so this asks clang. A probe
    translation unit includes the file itself, for its exact include context, and then tries
    `typedef <name> probe_N;` for each candidate. A non-type produces "unknown type name",
    which is read back off stderr. One clang run per file.
    """
    if not candidates:
        return []
    ordered = sorted(candidates)
    body = ['#include "%s"' % path]
    body += ["typedef %s dtape_probe_%d;" % (c, i) for i, c in enumerate(ordered)]
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as f:
        f.write("\n".join(body) + "\n")
        probe = f.name
    try:
        # -ferror-limit=0: clang stops at 20 errors by default, and every typedef of a
        # non-type is an error, so a file with more than 20 of them had the rest silently
        # KEPT as types. init.c is how that showed up: zone_create, a function, survived.
        r = subprocess.run(["clang", "-fsyntax-only", "-ferror-limit=0", "-x", "c", *args, probe],
                           capture_output=True, text=True)
        not_types = set(re.findall(r"unknown type name '([A-Za-z_][A-Za-z0-9_]*)'", r.stderr))
    except OSError:
        return ordered
    finally:
        try:
            os.unlink(probe)
        except OSError:
            pass
    return [c for c in ordered if c not in not_types]


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


# Lines inside a <copied from="xnu://..."> or <adapted from=...> block. duct-tape marks every
# region it lifted from XNU this way.
_XNU_OPEN = re.compile(r"<(?:copied|adapted) from=")
_XNU_CLOSE = re.compile(r"</(?:copied|adapted)>")


def adapted_xnu_lines(src):
    """How much of this file is TRANSCRIBED XNU rather than duct-tape glue.

    A different axis from every other column, and the one that would have stopped psynch.c
    being picked as the next port. Its blocker and opaque counts read cheap, and it is 678
    lines, but 460 of those are XNU's bsd/kern/kern_synch.c sleep path with its signal
    handling. That is not glue moving to Rust, it is a transcription where the semantics have
    to match exactly and nothing about the port gets easier for having done it.

    GLUE is lines minus this, and it is the number worth ranking on:
        thread.c 1397, memory.c 1175, task.c 771, kqchan.c 279, psynch.c 218
    """
    inside = False
    count = 0
    for line in src.split("\n"):
        if _XNU_OPEN.search(line):
            inside = True
            continue
        if _XNU_CLOSE.search(line):
            inside = False
            continue
        if inside:
            count += 1
    return count


def measure(path, args):
    src = open(path).read()
    dirty = preprocesses_cleanly(path, args)
    fn, ob, code_ob = macros_visible_to(path, args)
    calls = set(CALL.findall(src))
    words = set(WORD.findall(src))
    fn_used = sorted(calls & fn)
    # object-like only counts if it is not also function-like, else it double counts
    ob_used = sorted((words & ob) - fn)
    return {
        "lines": src.count("\n"),
        "adapted": adapted_xnu_lines(src),
        "dirty": dirty,
        "code_macros": sorted(words & code_ob),
        "variadic": sorted(m.group(0).split("(")[0].split()[-1]
                           for m in VARIADIC_DEF.finditer(src)),
        "fn_macros": fn_used,
        "ob_macros": ob_used,
        "ffi": ffi_surface(os.path.basename(path)),
        "opaque": keep_only_types(
            path, args, opaque_types_touched(own_code_after_expansion(path, args), OPAQUE)),
    }




def solved_macro_names_and_allowlist():
    """The macros already answered, and the types already bound.

    A module function rather than inline in the table path, because --file needs the same
    answer and did not have it: it printed a KeyError on r[solved] instead. That was hidden
    for one run by a grep filter over the output, which is a good reminder that filtering a
    command's output can hide its traceback.
    """

    # A macro is only a blocker while it has NO Rust equivalent. dtape_stub, dtape_stub_safe
    # and dtape_stub_unsafe live in linux/server/src/dtape_stub.rs and were ported precisely so
    # that the files calling them could be, yet they kept ranking as blockers for host.c and
    # processor.c and pushed both down the list. Read the crate for macro_rules! rather than
    # keeping a hand written list here, for the same reason PORTED_TO_RUST is read from the
    # generator: a second copy drifts, and this tool is only useful if it is trusted.
    # Macros solved by a C SHIM count as solved too. xnu-sys/src/dtape_rs_shims.c exports
    # macro-only operations as real symbols, named dtape_rs_<macro>, for the cases where a Rust
    # reimplementation would cost more than it saves: kalloc expands to a statement expression
    # holding a static vm_allocation_site_t, so writing it in Rust would mean un-opaquing part
    # of vm_.* for the whole crate. Read the shim rather than listing them here, same rule as
    # everywhere else in this file.
    have = set()
    shim = os.path.join(DT, "src/dtape_rs_shims.c")
    if os.path.exists(shim):
        have |= set(re.findall(r"^\w[\w \*]*\bdtape_rs_(\w+)\s*\(",
                               open(shim, errors="ignore").read(), re.M))

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

    return have, allowlisted


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="explain a single glue file")
    args_ns = ap.parse_args()

    cargs = clang_args()
    global OPAQUE
    OPAQUE = opaque_patterns()
    srcdir = os.path.join(DT, "src")
    files = sorted(f for f in os.listdir(srcdir) if f.endswith(".c"))
    # The macro shims are infrastructure this port ADDS, not upstream glue it has to move, so
    # they do not belong in the ranking or in the "N of 16" count. Read from the generator,
    # same rule as PORTED_TO_RUST.
    shim_names = set()
    _gen = os.path.join(ROOT, "scripts/gen-duct-tape-buck.py")
    if os.path.exists(_gen):
        _m = re.search(r"^RUST_SHIM_SOURCES = \[(.*?)^\]", open(_gen).read(), re.M | re.S)
        if _m:
            shim_names = {os.path.basename(x) for x in re.findall(r'"([^"]+)"', _m.group(1))}
    files = [f for f in files if f not in shim_names]
    if not files:
        sys.exit("no glue sources found; has the port finished, or is the path wrong?")

    if args_ns.file:
        if args_ns.file not in files:
            sys.exit(f"{args_ns.file} is not a glue source (have: {', '.join(files)})")
        have, _allowlisted = solved_macro_names_and_allowlist()
        r = measure(os.path.join(srcdir, args_ns.file), cargs)
        r["solved"] = [x for x in r["fn_macros"] if x in have]
        print(f"{args_ns.file}: {r['lines']} lines")
        print(f"  variadic definitions ({len(r['variadic'])}): {', '.join(r['variadic']) or 'none'}")
        print(f"  function-like macros ({len(r['fn_macros'])}): {', '.join(r['fn_macros']) or 'none'}")
        print(f"  object-like macros ({len(r['ob_macros'])}): {', '.join(r['ob_macros']) or 'none'}")
        print(f"  OPAQUE xnu types touched ({len(r['opaque'])}): {', '.join(r['opaque']) or 'none'}")
        if r["solved"]:
            # KNOWN OVER-REPORT, stated rather than silently wrong. This list is measured on the
            # C file after macro expansion, so a type reached ONLY through a macro that is now
            # shimmed still shows up, even though a Rust port calls the shim and never expands
            # it. processor.c is the live example: vm_allocation_site_t is listed, and it comes
            # entirely from the kalloc expansion, which dtape_rs_kalloc now absorbs.
            # Not corrected automatically because it needs types attributed to the macro that
            # introduced them. The obvious cheap fix does NOT work: passing -Dkalloc(a0)=... on
            # the command line changes nothing, because kern/kalloc.h redefines the macro
            # afterwards and the header wins. Measured, both ways came out identical.
            print(f"    NOTE: {', '.join(r['solved'])} already solved in Rust or by a shim, so"
                  f" any opaque type reached only through those is not this port's problem")
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
    have, allowlisted = solved_macro_names_and_allowlist()
    defined_syms = archive_defined_symbols()

    rows = []
    for f in files:
        r = measure(os.path.join(srcdir, f), cargs)
        r["ported"] = f in ported
        # The raw counts stay as measured; what changes is which of them still BLOCK.
        # A code-emitting object-like macro is as much a blocker as a function-like one, and
        # for traps.c it is the ONLY one: DSERVER_DTAPE_DEFS expands to about 29 function
        # definitions, so porting the file means writing a Rust emitter for that table.
        forwards = macros_that_only_forward(
            os.path.join(srcdir, f), cargs, r["fn_macros"], defined_syms)
        r["solved"] = [x for x in r["fn_macros"] if x in have or x in forwards]
        solved_here = have | forwards
        r["fn_blockers"] = ([m for m in r["fn_macros"] if m not in solved_here]
                            + [m for m in r["code_macros"] if m not in solved_here])
        rows.append((f, r))
    # cheapest first, ported files last: variadics are unfixable in Rust, so they dominate
    # Sort on BLOCKERS, not on the raw object-like count. That count is dominated by plain
    # integer constants, which bindgen binds perfectly well, and it was what kept traps.c
    # (1 blocker, 2 object-like macros) ahead of init.c (0 blockers, 5 constants). Variadic
    # DEFINITIONS still dominate everything, since Rust cannot express them at all.
    rows.sort(key=lambda kv: (kv[1]["ported"],
                              len(kv[1]["variadic"]) * 100 + len(kv[1]["fn_blockers"]),
                              len(kv[1]["opaque"])))

    print(f"{'FILE':<14}{'LINES':>7}{'GLUE':>7}{'VARIADIC':>9}{'FNMAC':>7}"
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
        if r["dirty"]:
            # LOUD, and it sorts nothing: a file whose preprocess died has no measurement at
            # all, and every column for it is whatever clang had got to before it stopped.
            note = f"MEASUREMENT INVALID: {r['dirty']}"
        ex = str(r["ffi"]["exports"]) if r["ffi"] else "-"
        co = str(r["ffi"]["calls"]) if r["ffi"] else "-"
        print(f"{f:<14}{r['lines']:>7}{r['lines'] - r['adapted']:>7}"
              f"{len(r['variadic']):>9}{len(r['fn_macros']):>7}{ex:>9}{co:>10}"
              f"{len(r['opaque']):>8}  {note}")
    if not any(r["ffi"] for _, r in rows):
        print("\n(EXPORTS/CALLSOUT need a buck2 build of //src/external/ciderd"
              "/xnu-sys:dt_objects)")
    bad = [f for f, r in rows if r["dirty"]]
    if bad:
        print(f"\n{len(bad)} file(s) DID NOT PREPROCESS, so their columns above mean nothing: "
              f"{', '.join(bad)}")
        print("  clang -E prints what it had and exits non-zero, so a truncated run looks "
              "exactly like a clean one\n  unless the exit status is read. Fix the include "
              "roots rather than reading the numbers.")
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
