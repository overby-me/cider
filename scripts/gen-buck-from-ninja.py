#!/usr/bin/env python3
"""Emit Buck2 targets for a cmake target, read out of the reference build.ninja.

plan/buck2-port.md phase 2.1: bootstrap targets from the real build graph, then
hand-refine the ones we own. The configured build.ninja is the best source
available -- it holds the EXACT sources, defines, flags, include paths and link
command ninja passes, including everything a target inherits from parent cmake
scopes (which reading a CMakeLists cannot tell you).

Get the graph with:
    nix build .#darling-graph -o result-graph-ref

Usage:
    scripts/gen-buck-from-ninja.py <cmake-target> [...]          # print
    scripts/gen-buck-from-ninja.py --write <cmake-target> [...]  # into its package
    scripts/gen-buck-from-ninja.py --dylibs <cmake-target> [...]  # firstpass+final pair
    scripts/gen-buck-from-ninja.py --binaries <exe-name> [...]    # darwin_binary
    scripts/gen-buck-from-ninja.py --archives <archive> [...]      # cc_static_lib
    scripts/gen-buck-from-ninja.py --list [<substring>]     # what targets exist
    scripts/gen-buck-from-ninja.py --explain <cmake-target> # flags/includes as-is

--write appends the block to the BUCK file of the package that owns the sources,
between BEGIN/END markers so re-running replaces rather than duplicates. Deps
added by hand belong in buck/generated/extra-deps.json, not inside a block.

PER-SOURCE FLAGS: a cmake target does not necessarily compile every source the
same way. libc is the extreme case -- SET_SOURCE_FILES_PROPERTIES gives individual
files their own `-DLIBC_ALIAS_*` (which decides symbol aliasing) and their own
`-include` shim. So sources are grouped by their exact flag set and each group
becomes its own cc_objects target; the archive or dylib then takes all of them.
Reading flags off one edge and assuming they hold for the whole target would
silently produce a library with the wrong symbols.

What it cannot do, and says so instead of guessing: a source or include dir that
lives in the cmake BINARY dir is generated, and needs a codegen target (mig_gen,
script_gen, ...) wired by hand. Those are reported as TODO comments.
"""
from __future__ import annotations

import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRAPH = os.path.join(REPO, "result-graph-ref", "build.ninja")
BUCK_SRC = "buck-src"

# The nix build's source and binary dirs, as they appear in build.ninja.
SRC_STORE_RE = re.compile(r"/nix/store/[a-z0-9]{32}-darling-cmake-src")
BIN_DIR = "/build/build"

# Flags //darwin:sdk_env already supplies, so a generated target does not repeat
# them. Keep in sync with darwin/BUCK.
ENV_FLAGS = {
    "-Wno-error=implicit-function-declaration",
    "-Wno-nullability-completeness",
    "-Wno-deprecated-declarations",
    "-Wno-availability",
    "-Wno-expansion-to-defined",
    "-Wno-undef-prefix",
    "-Wno-elaborated-enum-base",
    "-DDARLING",
    "-DDARWIN",
    "-DPLATFORM_MacOSX",
    "-DTARGET_OS_MAC=1",
    "-D_DARWIN_C_SOURCE",
    "-D_POSIX_C_SOURCE",
    "-D__APPLE__",
    "-D__DYNAMIC__",
    "-D__MACH__",
}
# Flags the toolchain itself passes (buck/toolchains/BUCK).
TOOLCHAIN_FLAGS = {
    "-target", "x86_64-apple-darwin20", "-arch", "x86_64", "-mmacosx-version-min=11.0",
}
# Include dirs owned by another buck2 package, mapped to the target that already
# declares them. A glob in one package cannot reach into another, so without this
# the root would silently stage empty.
CROSS_PACKAGE_ROOTS = {
    "src/libsimple/include": "//src/libsimple:libsimple_headers",
    "src/external/darlingserver/include": "//src/external/darlingserver:dserver_headers",
    # launchd's own headers, needed by targets in OTHER packages: xtrace's per-protocol
    # stub for liblaunch's job.defs compiles a generated source whose imports reach
    # launchd's core.h. The root staged there covers src/ and liblaunch/ both.
    "src/launchd/src": "//src/launchd:launchd_inc_src_launchd",
    "src/launchd/liblaunch": "//src/launchd:launchd_inc_src_launchd",
}

# Force-included headers (-include) owned by another package, mapped to the target
# that exports them: prefix_headers needs a FILE, and a rule's sources must live in
# its own package.
CROSS_PACKAGE_FILES = {
    "src/duct/include/CrashReporterClient.h": "//src/duct:CrashReporterClient.h",
}

# Include dirs //darwin:sdk_env covers, relative to the repo root.
ENV_INCLUDES = {
    "src/include",
    "darwin/basic-headers",
    "darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include",
    "darwin/framework-include",
    "darwin/framework-private-include",
    "src/external/lkm/include",
    "src/libDiagnosticMessagesClient/include",
    "src/libMobileGestalt/include",
    "src/lib/include",
    "src/external/configd/dnsinfo",
    "darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/libxml2",
    # The C++ standard library. It MUST NOT also be emitted per-target: two copies
    # of libcxx/include on one command line break #include_next, because libcxx's
    # stdint.h defers to the next stdint.h on the path and finds the other staged
    # copy of ITSELF instead of the SDK's, leaving uint32_t undefined.
    "src/external/libcxx/include",
}


def read_edges():
    """Parse build.ninja into [(outputs, rule, inputs, vars)]."""
    with open(GRAPH) as f:
        text = f.read()
    edges, cur = [], None
    for line in text.split("\n"):
        if line.startswith("build "):
            head, _, rest = line[len("build "):].partition(": ")
            rule, _, inputs = rest.partition(" ")
            cur = (head.split(" | ")[0].split(), rule,
                   [i for i in inputs.split() if i not in ("|", "||")], {})
            edges.append(cur)
        elif cur is not None and line.startswith("  ") and " = " in line:
            k, _, v = line.strip().partition(" = ")
            # Undo NINJA's own escaping before anything else looks at the value: it
            # writes a literal $ as $$, and CoreFoundation's link carries
            # -Wl,-alias,_OBJC_CLASS_$___NSCFConstantString,... -- passing the escape
            # through hands ld64 a symbol name that does not exist.
            cur[3][k] = v.replace("$$", "$").replace("$:", ":")
        elif line.strip() == "":
            cur = None
    return edges


def orig_repo_rel(p: str) -> str:
    """The path as it is relative to the repo root, whatever tree it lives in."""
    return os.path.normpath(SRC_STORE_RE.sub("", p).replace(BIN_DIR, "").lstrip("/"))


def deref(rel: str) -> str:
    """Resolve a repo-relative path through symlinks, staying inside the repo.

    buck2 does NOT glob through a symlinked DIRECTORY: it treats it as one opaque
    entry, so a header root pointing at one stages EMPTY (while explicit sources
    through the same symlink still resolve, which is what made this confusing).
    The materialized pins contain 3861 symlinks, including
    xnu/darling/src/libsystem_kernel/libsyscall -> xnu/libsyscall, so roots have to
    name the real directory.
    """
    real = os.path.realpath(os.path.join(REPO, rel))
    out = os.path.relpath(real, REPO)
    return rel if out.startswith("..") else out


def repo_path(p: str):
    """Map a build.ninja path to (kind, path).

    "src" is a repo-relative source path, "buck-src" one rewritten into the
    materialized pins, "generated" anything in the cmake binary dir or otherwise
    absent from the working copy.
    """
    p = SRC_STORE_RE.sub("", p)
    if p.startswith(BIN_DIR):
        return ("generated", os.path.normpath(p[len(BIN_DIR):].lstrip("/")))
    p = os.path.normpath(p.lstrip("/"))
    # Task #68 moved the guest trees under darwin/. The reference graph predates
    # the nix substitution that rewrites them, so a pre-reorg path still shows up
    # (libnotify force-includes Developer/.../sys/fileport.h that way).
    if not os.path.exists(os.path.join(REPO, p)) and \
            p.split("/", 1)[0] in ("Developer", "framework-include", "framework-private-include",
                                   "basic-headers"):
        cand = os.path.join(REPO, "darwin", p)
        if os.path.lexists(cand):
            p = "darwin/" + p
            # The SDK tree is symlinks into the submodules, which are not checked
            # out here -- the pins are. Follow the link textually and let the
            # buck-src branch below place it.
            if os.path.islink(cand):
                tgt = os.path.normpath(os.path.join(os.path.dirname(p), os.readlink(cand)))
                if tgt.startswith("src/external/"):
                    p = tgt
    if p.startswith("src/external/"):
        rel = p[len("src/external/"):]
        if os.path.exists(os.path.join(REPO, BUCK_SRC, rel)):
            real = deref(os.path.join(BUCK_SRC, rel))
            if real.startswith(BUCK_SRC + "/"):
                rel = real[len(BUCK_SRC) + 1:]
            return ("buck-src", rel)
    if os.path.exists(os.path.join(REPO, p)):
        return ("src", p)
    return ("generated", p)


def split_flags(s: str) -> list[str]:
    """Split a ninja flag string using SHELL quoting rules.

    ninja passes its command line to /bin/sh, so cmake's quoting is shell quoting,
    and the escapes are load-bearing rather than noise:

        -DEMULATED_OSPRODUCTVERSION=\\"14.4.1\\"
        -DEMULATED_VERSION="\\"Darwin Kernel Version 23.4.0\\""

    Both are ONE argument, and in both the double quotes are part of the macro
    VALUE (it expands to a C string literal). Dropping them, or splitting the
    second on its spaces, silently changes what the code compiles to.
    """
    out, cur, quote, started = [], "", None, False
    i = 0
    while i < len(s):
        ch = s[i]
        if quote == "'":
            if ch == "'":
                quote = None
            else:
                cur += ch
        elif quote == '"':
            if ch == "\\" and i + 1 < len(s) and s[i + 1] in '"\\$`':
                cur += s[i + 1]
                i += 1
            elif ch == '"':
                quote = None
            else:
                cur += ch
        elif ch == "\\" and i + 1 < len(s):
            cur += s[i + 1]
            i += 1
        elif ch in "'\"":
            quote = ch
            started = True
        elif ch.isspace():
            if cur or started:
                out.append(cur)
            cur, started = "", False
        else:
            cur += ch
        i += 1
    if cur or started:
        out.append(cur)
    return out


def collect(target: str, edges):
    """Per-source compile info for one cmake target, plus its link edge."""
    obj_re = re.compile(r"CMakeFiles/" + re.escape(target) + r"\.dir/")
    units, link = [], None
    for outs, rule, inputs, vars in edges:
        if any(obj_re.search(o) for o in outs) and any(o.endswith(".o") for o in outs):
            for i in inputs:
                if i.startswith("|"):
                    break
                if re.search(r"\.(c|cc|cpp|cxx|m|mm|S|s)$", i):
                    units.append({
                        "src": i,
                        "defines": split_flags(vars.get("DEFINES", "")),
                        "flags": split_flags(vars.get("FLAGS", "")),
                        "includes": split_flags(vars.get("INCLUDES", "")),
                    })
        elif link is None:
            for o in outs:
                base = os.path.basename(o)
                if base in (target, "lib" + target + ".a", "lib" + target + ".dylib") or (
                    base.startswith("lib" + target) and base.endswith(".dylib")
                ):
                    link = (o, vars)
                    break
    return units, link


UNRESOLVED_PREFIX: set = set()


def own_flags_of(unit):
    """Flags beyond the shared environment, and the -include headers, for one compile.

    -include is pulled out of the flags: its argument is a HEADER THIS TARGET NEEDS,
    and the reference spells it as an absolute nix store path. Passing that through
    would leak a store path into the build AND leave the header undeclared, so it
    becomes a prefix_headers entry. libc depends on this working: gen/__dirent.h is
    a #define shim renaming dd_* to __dd_*, force-included into every *dir.c, and
    without it the sources do not match the public dirent.h at all.
    """
    toks = unit["defines"] + unit["flags"]
    flags, prefix, skip = [], [], False
    for i, f in enumerate(toks):
        if skip:
            skip = False
            continue
        if f == "-include":
            skip = True
            if i + 1 < len(toks):
                arg = toks[i + 1]
                kind, hp = repo_path(arg)
                if kind != "generated":
                    if (kind, hp) not in prefix:
                        prefix.append((kind, hp))
                elif "/" not in arg:
                    # A bare NAME, not a path: `-include __dirent.h` is resolved
                    # through the include path (libc/gen, a declared root), so it
                    # stays a flag rather than becoming an artifact.
                    flags.extend(["-include", arg])
                else:
                    # Dropping a force-included header silently changes what the
                    # source compiles to, so record it for the block's TODO list.
                    UNRESOLVED_PREFIX.add(orig_repo_rel(arg))
            continue
        if f in ("-B", "-isystem"):
            skip = True
            continue
        if f in ENV_FLAGS or f in TOOLCHAIN_FLAGS or "resource-root" in f:
            continue
        flags.append(f)
    return flags, prefix


def includes_of(unit):
    """Ordered include roots for one compile, plus the generated dirs.

    The order is significant and is NOT "own roots first". The reference
    interleaves: some of a target's own dirs come BEFORE the shared environment
    (the SDK, basic-headers, frameworks) and others come AFTER it. libsyscall is
    the case that proves it -- `xnu/osfmk` sits after the SDK there, so
    <mach/mach.h> resolves to the SDK's GUEST copy; hoisting osfmk above the SDK
    instead picks up XNU's KERNEL mach_interface.h, which includes a header only
    the kernel-side MIG produces.

    So this returns a list of ("own", path) entries and a single ("env", None)
    marker at the position the environment block occupies.
    """
    ordered, gen, seen_env = [], [], False
    for i in unit["includes"]:
        if not i.startswith("-I"):
            continue
        if orig_repo_rel(i[2:]) in ENV_INCLUDES:
            if not seen_env:
                ordered.append(("env", None))
                seen_env = True
            continue
        kind, p = repo_path(i[2:])
        if kind == "generated":
            gen.append(p)
        else:
            ordered.append(("own", p))
    if not seen_env:
        ordered.append(("env", None))
    return ordered, gen


def extra_deps(target: str) -> list[str]:
    """Hand-added deps for a target (frameworks, codegen), from a committed file.

    --write replaces a generated block wholesale, so a dep added by hand inside one
    would be lost on the next run. Keeping them in buck/generated/extra-deps.json
    makes them survive, and puts every such decision in one reviewable place.
    """
    f = os.path.join(REPO, "buck", "generated", "extra-deps.json")
    if not os.path.exists(f):
        return []
    with open(f) as fh:
        data = json.load(fh)
    return [d for d in data.get(target, []) if isinstance(d, str)]


# Prefixes understood in extra-deps.json entries:
#   (none)     a normal dep
#   gen:       a codegen target whose generated sources this target compiles
#   ldflag:    a linker flag for this target's dylib


def starlark_str(v: str) -> str:
    """Quote a value for Starlark, escaping what the parser would choke on."""
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


def sanitize(path: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_")


def generate(target: str, edges):
    UNRESOLVED_PREFIX.clear()
    units, link = collect(target, edges)
    if not units:
        return None

    # Group sources by their exact flag set; each group becomes one cc_objects.
    groups: dict[tuple, dict] = {}
    gen_srcs, gen_includes = [], []
    for unit in units:
        kind, srcp = repo_path(unit["src"])
        if kind == "generated":
            gen_srcs.append(srcp)
            continue
        flags, prefix = own_flags_of(unit)
        ordered_inc, gi = includes_of(unit)
        gen_includes.extend(gi)
        key = (tuple(flags), tuple(prefix), tuple(ordered_inc))
        groups.setdefault(key, {"flags": flags, "prefix": prefix, "inc": ordered_inc, "srcs": []})
        groups[key]["srcs"].append((kind, srcp))
    if not groups and gen_srcs:
        # EVERY source is generated (xtrace's per-protocol stubs are one generated
        # XtraceMig.c and nothing else). The flags and include roots still come from
        # the reference; only the sources come from a gen: entry in extra-deps.json.
        flags, prefix = own_flags_of(units[0])
        ordered_inc, _gi = includes_of(units[0])
        groups[("gen",)] = {"flags": flags, "prefix": prefix, "inc": ordered_inc, "srcs": []}
    if not groups:
        return None

    # Which package this block will be written into, needed BEFORE emitting: a file
    # attribute has to be package-relative when this package owns the file and a label
    # when another one does.
    pkg_for_files = package_of([sp for g in groups.values() for sp in g["srcs"]])

    out: list[str] = []
    w = out.append
    w("# GENERATED from the reference build.ninja by")
    w(f"# scripts/gen-buck-from-ninja.py {target}   -- review before committing.")
    w(f"# cmake target: {target}" + (f"  ->  {link[0]}" if link else ""))
    if len(groups) > 1:
        w(f"# {len(units)} sources in {len(groups)} flag groups: cmake gives individual")
        w("# files their own defines and -include shims, and those decide symbol aliasing.")
    if gen_srcs:
        w("# TODO these sources are GENERATED; wire a codegen target for each:")
        for g in sorted(set(gen_srcs)):
            w(f"#   {g}")
    if UNRESOLVED_PREFIX:
        w("# TODO these headers are FORCE-INCLUDED (-include) but could not be")
        w("# resolved to a file in this tree; the sources need them:")
        for g in sorted(UNRESOLVED_PREFIX):
            w(f"#   {g}")
    if gen_includes:
        w("# TODO these include dirs are GENERATED (codegen output):")
        for g in sorted(set(gen_includes)):
            w(f"#   {g}")
    w("")

    # One header root per distinct include dir, shared across groups -- except that
    # SIBLING dirs are staged as one tree (see below), because a staged header's
    # own `#include "../sibling/x.h"` resolves relative to the staged copy.
    own_roots: list[str] = []
    for g in groups.values():
        for kind, p in g["inc"]:
            if kind == "own" and p not in own_roots and p not in CROSS_PACKAGE_ROOTS:
                own_roots.append(p)
    def root_dir(rel: str) -> str:
        """Where an include root actually lives: pin roots are buck-src-relative."""
        direct = os.path.join(REPO, rel)
        if os.path.isdir(direct):
            return direct
        return os.path.join(REPO, BUCK_SRC, rel)

    def extensionless_headers(rel: str) -> bool:
        """Whether a root's headers have NO extension.

        The C++ standard library's are exactly that shape (`vector`, `ext/rope`), so a
        root globbing only *.h stages nothing they need -- and the failure reads as a
        missing file rather than a missing pattern. Detected rather than listed, because
        any tree with the same shape needs the same treatment.
        """
        base = root_dir(rel)
        if not os.path.isdir(base):
            return False
        for _dirpath, _dirs, files in os.walk(base):
            for f in files:
                if "." not in f and not f.startswith("."):
                    return True
        return False

    # Extensions that are unmistakably headers-by-another-name in this tree.
    UNUSUAL_HEADER_EXTS = (".mdh", ".mdhi", ".mdhs", ".pro", ".epro", ".tcc")

    def unusual_header_exts(rel: str) -> bool:
        base = root_dir(rel)
        if not os.path.isdir(base):
            return False
        for _dirpath, _dirs, files in os.walk(base):
            if any(f.endswith(UNUSUAL_HEADER_EXTS) for f in files):
                return True
        return False

    def has_headers(rel: str) -> bool:
        """Whether an include dir actually holds headers in this tree.

        A merged root projects one subdir per member, and buck2 errors out on a
        projection that does not exist -- which is what an include dir with no
        headers of its own produces (launchd's `support` is on the include path but
        holds only sources).
        """
        base = root_dir(rel)
        if not os.path.isdir(base):
            return False
        for _dirpath, _dirs, files in os.walk(base):
            if any(f.endswith((".h", ".hpp", ".hh", ".inc", ".defs")) for f in files):
                return True
        return False

    # Group roots that must share ONE staged tree: siblings (a header reaching its
    # neighbour with ../other/x.h) and ancestor/descendant pairs (zsh's Src headers
    # reaching ../config.h in the tree above them). Either way the escape only resolves
    # if both live in the same staged copy.
    by_parent: dict[str, list[str]] = {}
    for p in own_roots:
        if not has_headers(p):
            continue
        ancestor = next((q for q in own_roots
                         if q != p and p.startswith(q + "/") and has_headers(q)), None)
        if ancestor:
            by_parent.setdefault(ancestor, []).append(p)
            continue
        parent = os.path.dirname(p)
        if parent:
            by_parent.setdefault(parent, []).append(p)
    # A group keyed by an actual root must include that root itself.
    for anc in list(by_parent):
        if anc in own_roots and anc not in by_parent[anc]:
            by_parent[anc].insert(0, anc)
    merged_parent = {p: parent for parent, ps in by_parent.items() if len(ps) > 1 for p in ps}

    root_name: dict[str, str] = {}
    for parent, ps in sorted(by_parent.items()):
        if len(ps) < 2:
            continue
        name = target.removesuffix("_obj") + "_inc_" + sanitize(parent)[-44:]
        n = 2
        while name in root_name.values():
            name, n = f"{name}_{n}", n + 1
        # "." is the staged tree itself, which is what an ancestor root becomes.
        subs = [os.path.relpath(p, parent) for p in ps]
        for p in ps:
            root_name[p] = name
        w("# Sibling include dirs, staged as ONE tree with -I into each: headers here")
        w('# reach each other with `#include "../<dir>/x.h"`, which only resolves if')
        w("# the sibling is in the same staged tree.")
        w("cc_header_root(")
        w(f'    name = "{name}",')
        w("    headers = glob([")
        for p in ps:
            # Same detection as an individual root: a tree whose headers carry no
            # extension, or one no fixed pattern would guess, is staged whole.
            if extensionless_headers(p) or unusual_header_exts(p):
                w(f'        "{p}/**/*",')
            else:
                w(f'        "{p}/*.h",')
                w(f'        "{p}/**/*.h",')
                w(f'        "{p}/*.c",')
        w("    ]),")
        w(f'    root = "{parent}",')
        w("    include_subdirs = [")
        for sub in subs:
            w(f'        "{sub}",')
        w("    ],")
        w('    visibility = ["PUBLIC"],')
        w(")")
        w("")

    for g in groups.values():
        for kind, p in g["inc"]:
            if kind != "own" or p in root_name:
                continue
            if p in CROSS_PACKAGE_ROOTS:
                root_name[p] = CROSS_PACKAGE_ROOTS[p]
                continue
            # Name from the FULL path, and disambiguate: dropping the first
            # component collapsed cctools/include and cctools-port/include onto one
            # name, which buck2 rejects as a duplicate target.
            base = target.removesuffix("_obj") + "_inc_" + sanitize(p)[-48:]
            name, n = base, 2
            while name in root_name.values():
                name = f"{base}_{n}"
                n += 1
            root_name[p] = name
            w("cc_header_root(")
            w(f'    name = "{name}",')
            # BOTH patterns: buck2's "dir/**/*.h" does not match dir/x.h, so a
            # root whose headers sit directly in it would stage EMPTY.
            if extensionless_headers(p) or unusual_header_exts(p):
                # Everything: the headers here carry no extension (libstdc++) or an
                # extension no fixed pattern would guess (zsh's .mdh/.pro).
                w(f'    headers = glob(["{p}/**/*"]),')
            else:
                # *.c at the root level too: some sources are #included rather than
                # compiled (ncurses' capdefaults.c, libedit's history.c), and they
                # resolve through an -I of the source dir like any header.
                w(f'    headers = glob(["{p}/*.h", "{p}/**/*.h", "{p}/*.c"]),')
            w(f'    root = "{p}",')
            w('    visibility = ["PUBLIC"],')
            w(")")
            w("")

    base = target if target.endswith("_obj") else target + "_obj"
    obj_names = []
    # A group can legitimately have NO srcs of its own (every source generated), so the
    # sort key cannot index into it.
    ordered = sorted(groups.values(),
                     key=lambda g: (-len(g["srcs"]), g["srcs"][0][1] if g["srcs"] else ""))
    for idx, g in enumerate(ordered):
        name = base if idx == 0 else f"{base}{idx + 1}"
        obj_names.append(name)
        w("cc_objects(")
        w(f'    name = "{name}",')
        w("    srcs = [")
        for _, p in sorted(g["srcs"]):
            w(f'        "{p}",')
        w("    ],")
        if g["flags"]:
            w("    compiler_flags = [")
            for f in g["flags"]:
                w(f"        {starlark_str(f)},")
            w("    ],")
        if g["prefix"]:
            w("    prefix_headers = [")
            for _, hp in g["prefix"]:
                w(f'        "{file_label(hp, pkg_for_files)}",')
            w("    ],")
        w('    toolchain = "toolchains//:darwin_cc",')
        w("    deps = [")
        # Dep ORDER is the include order, and the environment sits where the
        # reference puts it -- not first, not last.
        seen_dep = set()
        for kind, p in g["inc"]:
            if kind == "env":
                w('        "//darwin:sdk_env",')
                for d in extra_deps(target):
                    # Only a LABEL is a dep here. The other entries are typed
                    # instructions for the LINK blocks -- gen: sources, ldflag:, objs:,
                    # dep:, dylib: -- and buck2 reads a `dylib:` prefix as a cell alias.
                    if not d.startswith(("//", ":")) or d in seen_dep:
                        continue
                    seen_dep.add(d)
                    w(f'        "{d}",')
            else:
                # Merged sibling roots share one target, so the same label can come
                # up more than once.
                name = root_name[p]
                if name in seen_dep:
                    continue
                seen_dep.add(name)
                w(f'        "{name}",' if name.startswith("//") else f'        ":{name}",')
        w("    ],")
        gen = [d[len("gen:"):] for d in extra_deps(target) if d.startswith("gen:")]
        if gen and idx == 0:
            # Generated sources this target compiles. Only the first flag group
            # takes them: they are one set of files, not one per group.
            w("    gen_srcs = [")
            for d in gen:
                w(f'        "{d}",')
            w("    ],")
        # Object groups are linked by dylib targets in OTHER packages (a dylib in
        # buck-src links libm's objects), so they have to be visible.
        w('    visibility = ["PUBLIC"],')
        w(")")
        w("")

    install_name, is_dylib = "", False
    if link:
        m = re.search(r"-Wl,-dylib_install_name,(\S+)", link[1].get("LINK_FLAGS", ""))
        install_name = m.group(1) if m else ""
        is_dylib = link[0].endswith(".dylib")
    ldflags = [d[len("ldflag:"):] for d in extra_deps(target) if d.startswith("ldflag:")]
    if is_dylib and dylib_edges(target, edges)[1] is not None:
        w("darwin_dylib(")
        w(f'    name = "{target}_firstpass",')
        w(f'    dylib_name = "lib{target}_firstpass.dylib",')
        w("    firstpass = True,")
        w(f'    install_name = "{install_name}",')
        w("    objs = [")
        for n in obj_names:
            w(f'        ":{n}",')
        w("    ],")
        if ldflags:
            w("    linker_flags = [")
            for f in ldflags:
                w(f'        "{f}",')
            w("    ],")
        w('    toolchain = "toolchains//:darwin_cc",')
        w('    deps = ["//darwin:sdk_env"],')
        w('    visibility = ["PUBLIC"],')
        w(")")
        w("")

    all_srcs = [s for g in groups.values() for s in g["srcs"]]
    return "\n".join(out), all_srcs


# Splitting the materialized pins into one package PER PIN shrinks what the Nix-lowered
# path has to parse: a 32k-line BUCK file costs more memory than the machine has, while
# a 13.5k-line one is comfortable. There is no flag for it -- buck/generated/split-pins.txt
# IS the switch, one pin at a time, so a pin's blocks land in its own package exactly when
# that package exists. A subpackage takes OWNERSHIP of its files, so everything outside it
# (the SDK header maps in buck-src/BUCK, another pin's force-included header) must name
# those files by LABEL; scripts/buck-exports.py backs every such label with an export_file.
def migrated_pins() -> set:
    """Pins that already have their own package (scripts/buck-split-pins.py keeps this).

    A file's owner is buck-src/<pin> only once that package exists; until then the pin's
    files still belong to the one big buck-src package, and naming a label into a
    non-existent package is just a broken reference.
    """
    f = os.path.join(REPO, "buck", "generated", "split-pins.txt")
    if not os.path.exists(f):
        return set()
    return {l.strip() for l in open(f) if l.strip() and not l.startswith("#")}


def export_target_name(rel_in_pkg: str) -> str:
    """The export_file target name for a file, flattened: bsd/sys/fileport.h -> that
    path with separators replaced, so the label is unambiguous and slash-free."""
    return re.sub(r"[^A-Za-z0-9_.+-]+", "_", rel_in_pkg)


def file_label(path: str, pkg: str) -> str:
    """How `pkg` refers to a file: package-relative when it owns it, else a label.

    Files are addressed relative to the package that declares them, so a pin package can
    only name its own. Anything else has to come through an export_file in the owning
    package -- the shape CROSS_PACKAGE_FILES already encodes by hand.
    """
    if path in CROSS_PACKAGE_FILES:
        return CROSS_PACKAGE_FILES[path]
    if path.startswith("src/"):
        owner = package_of([("src", path)])
    else:
        pin = path.split("/")[0]
        owner = BUCK_SRC + "/" + pin if pin in migrated_pins() else BUCK_SRC
    if owner == pkg:
        return path
    if owner.startswith(BUCK_SRC + "/"):
        rel = path[len(owner) - len(BUCK_SRC) :].lstrip("/")
        return f"//{owner}:{export_target_name(rel)}"
    if owner == BUCK_SRC:
        return path if pkg == BUCK_SRC else f"//{BUCK_SRC}:{export_target_name(path)}"
    rel = path[len(owner) + 1:] if path.startswith(owner + "/") else path
    return f"//{owner}:{export_target_name(rel)}"


def package_of(src_paths) -> str:
    """The BUCK package that owns a target: the one holding its sources."""
    repo_srcs = [q for k, q in src_paths if k == "src"]
    if repo_srcs:
        depth = 3 if repo_srcs[0].startswith("src/external/") else 2
        return "/".join(repo_srcs[0].split("/")[:depth])
    pin_srcs = [q for k, q in src_paths if k == "buck-src"]
    if pin_srcs and pin_srcs[0].split("/")[0] in migrated_pins():
        return BUCK_SRC + "/" + pin_srcs[0].split("/")[0]
    return BUCK_SRC


def dylib_edges(target: str, edges):
    """The (final, firstpass) link edges of a cmake dylib target.

    By EXACT output name, not a prefix match: lib<t>_firstpass.dylib also starts
    with lib<t>, so a prefix match picks whichever edge ninja happens to emit
    first and can hand back the firstpass edge as if it were the final one.
    The top-level alias edges (bare libxpc.dylib, no flags) are skipped.
    """
    final = first = None
    dylibs = []
    for outs, _rule, inputs, vars in edges:
        # A FRAMEWORK binary is a Mach-O dylib with no extension at all
        # (CoreFoundation, DirectoryService), so the install_name flag is what
        # identifies a dylib link -- not the file name.
        is_dylib_link = "-dylib_install_name" in vars.get("LINK_FLAGS", "")
        for o in outs:
            base = os.path.basename(o)
            if "/" not in o or not (base.endswith(".dylib") or is_dylib_link):
                continue
            if base == f"lib{target}.dylib" and final is None:
                final = (o, inputs, vars)
            elif base == f"lib{target}_firstpass.dylib" and first is None:
                first = (o, inputs, vars)
            else:
                dylibs.append((o, inputs, vars))
    if final is None and first is not None:
        # The final pass is not always lib<target>.dylib: libSystem's is
        # libSystem.B.dylib, libobjc's is libobjc.A.dylib, libcache's drops the
        # doubled prefix. It IS the other dylib in the same directory built from
        # the same objects, which is what this matches on.
        want = set(objlibs_of(first))
        d = os.path.dirname(first[0])
        for cand in dylibs:
            base = os.path.basename(cand[0])
            if os.path.dirname(cand[0]) != d or "_firstpass" in base:
                continue
            if set(objlibs_of(cand)) == want:
                final = cand
                break
    if final is None and first is None:
        # A library OUTSIDE the circular cluster has no firstpass at all, and its
        # dylib is often named nothing like its cmake target (system_copyfile builds
        # libcopyfile.dylib, cxxabi_obj builds libc++abi.dylib). Match on the object
        # library instead, which is the one name that is always shared.
        want = {target, target.removesuffix("_obj"), target + "_obj"}
        for cand in dylibs:
            if "_firstpass" in os.path.basename(cand[0]):
                continue
            if want & set(objlibs_of(cand)):
                final = cand
                break
    return final, first


# cmake object libraries with no buck target of their own, because this port
# compiles their sources elsewhere. An empty list means "already covered": both of
# these hold ONLY mig-generated sources, which the sibling object library compiles
# through gen_srcs, so emitting a target for them would double the objects up.
OBJLIB_ALIASES = {
    "libsyscall_64": [],   # -x86_64-User.c stubs, compiled by libsyscall
    "asl_ipc_user": [],    # asl_ipcUser.c, compiled by system_asl_obj
    "asl_ipc_server": [],  # asl_ipcServer.c, compiled by syslogd
}


def objlibs_of(edge) -> list[str]:
    """The cmake object libraries a link edge consumes, from its object inputs."""
    names = []
    for i in edge[1]:
        m = re.search(r"CMakeFiles/([^/]+)\.dir/", i)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return names


def obj_groups(lib: str, edges):
    """[(target name, [source paths])] for one cmake object library, and its package.

    One entry per FLAG GROUP, in the SAME order generate() emits them, so the names
    line up with the targets that actually exist. Naming only the first would drop
    objects from a link: the library still builds, but symbols defined by the other
    groups come out undefined.
    """
    units, _ = collect(lib, edges)
    groups: dict[tuple, list] = {}
    srcs = []
    for unit in units:
        kind, srcp = repo_path(unit["src"])
        if kind == "generated":
            continue
        flags, prefix = own_flags_of(unit)
        inc, _gi = includes_of(unit)
        groups.setdefault((tuple(flags), tuple(prefix), tuple(inc)), []).append((kind, srcp))
        srcs.append((kind, srcp))
    base = lib if lib.endswith("_obj") else lib + "_obj"
    ordered = sorted(groups.values(), key=lambda g: (-len(g), sorted(g)[0][1]))
    out = [(base if i == 0 else f"{base}{i + 1}", [p for _k, p in g])
           for i, g in enumerate(ordered)]
    if not out:
        out = [(base, [])]
    return out, package_of(srcs)


def obj_targets(lib: str, edges):
    """(buck target names, owning package) for one cmake object library."""
    groups, pkg = obj_groups(lib, edges)
    return [name for name, _srcs in groups], pkg


def explicit_objects(edge, edges):
    """Objects passed ON THE LINK LINE rather than as edge inputs.

    Every Darwin executable is linked with csu's start.S.o named directly in
    LINK_FLAGS (the rest of crt1.10.6 stays in its archive), so the object has to be
    resolved to the flag group that holds that one source -- not to the library's
    first group, which is a different object entirely.
    """
    found = []
    for tok in edge[2].get("LINK_FLAGS", "").split():
        m = re.search(r"CMakeFiles/([^/]+)\.dir/(.+)\.o$", tok)
        if not m:
            continue
        lib, src = m.group(1), m.group(2)
        groups, pkg = obj_groups(lib, edges)
        for name, srcs in groups:
            if any(p.endswith(src) for p in srcs):
                found.append((pkg, name, lib))
                break
    return found


def firstpass_registry() -> dict:
    """cmake target -> buck label, for every firstpass dylib already declared.

    Read out of the committed BUCK files rather than assumed: a sibling can only be
    named if its target exists, and pretending otherwise produces a block that does
    not parse.
    """
    reg = {}
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in ("buck-out", ".git", ".jj", ".direnv", "build")]
        if "BUCK" not in filenames:
            continue
        pkg = os.path.relpath(dirpath, REPO)
        with open(os.path.join(dirpath, "BUCK")) as fh:
            for m in re.finditer(r'name = "([A-Za-z0-9_.-]+)_firstpass"', fh.read()):
                reg[m.group(1)] = f"//{pkg}:{m.group(1)}_firstpass"
    return reg


def final_registry() -> dict:
    """dylib basename -> buck label, for every final-pass dylib already declared.

    Keyed by ARTIFACT name rather than target name: the umbrella names its
    reexports by path (libSystem.B.dylib reexports libsystem_duct.dylib), and the
    dylib name and the cmake target name differ often enough that guessing between
    them is how a reexport list ends up naming something that does not exist.
    """
    reg = {}
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in ("buck-out", ".git", ".jj", ".direnv", "build")]
        if "BUCK" not in filenames:
            continue
        pkg = os.path.relpath(dirpath, REPO)
        text = open(os.path.join(dirpath, "BUCK")).read()
        for m in re.finditer(r'name = "([A-Za-z0-9_.-]+)_(final|dylib)",\s*\n\s*dylib_name = "([^"]+)"', text):
            # Keep the suffix the target actually uses: a single-pass library is
            # <base>_dylib, and naming it <base>_final does not resolve.
            reg[m.group(3)] = f"//{pkg}:{m.group(1)}_{m.group(2)}"
    return reg


# Link flags the darwin_dylib rule already derives from its own attrs, or that
# belong to the toolchain rather than the target.
_LINK_FLAG_HANDLED = (
    "-Wl,-dylib_install_name,", "-Wl,-compatibility_version,", "-Wl,-current_version,",
    "-Wl,-dylib_file,", "-Wl,-reexport_library", "-Wl,-upward_library", "-Wl,-rpath",
    "-Wl,-sdk_version", "-Wl,-Z", "-Wl,-syslibroot",
)


def link_flag_files(link_vars, pkg) -> tuple:
    """({flag: package-relative file}, flags whose file is elsewhere).

    A linker flag can carry a FILE, and dropping it changes the dylib's symbols:
    libplatform defines _platform_strcmp and answers to _strcmp only through
    -Wl,-alias_list. The file has to be a source in the declaring package, so any
    that is not gets reported instead of being emitted wrong.
    """
    files, elsewhere = {}, []
    for tok in split_flags(link_vars.get("LINK_FLAGS", "")):
        # -dylib_file and friends carry paths too, but the rule derives those from
        # its own deps; listing them here buried the real ones (an alias list) under
        # a hundred lines of framework mappings.
        if tok.startswith(_LINK_FLAG_HANDLED):
            continue
        m = re.match(r"(-Wl,-[a-z_]+),(/\S+)$", tok)
        if not m:
            continue
        flag, path = m.group(1), m.group(2)
        kind, rel = repo_path(path)
        if kind == "generated":
            elsewhere.append(tok)
            continue
        if kind == "buck-src" and pkg == BUCK_SRC:
            files[flag] = rel
        elif kind == "src" and rel.startswith(pkg + "/"):
            files[flag] = rel[len(pkg) + 1:]
        else:
            elsewhere.append(f"{flag},{rel}")
    return files, elsewhere


def semantic_link_flags(link_vars) -> tuple:
    """(-Wl flags that change link SEMANTICS, flags naming a path we cannot pass).

    Darling does not use one link model for the whole cluster: libunwind's FINAL
    pass is linked -flat_namespace -undefined suppress, exactly like its firstpass,
    while libsystem_kernel's is not. Tying that to `firstpass = True` in the rule
    left every such member's final pass undefined against symbols that live in a
    library it never names (memset, in libsystem_platform).
    """
    flags, paths = [], []
    for tok in split_flags(link_vars.get("LINK_FLAGS", "")):
        if not tok.startswith("-Wl,") or tok.startswith(_LINK_FLAG_HANDLED):
            continue
        if "/" in tok:
            if tok not in paths:
                paths.append(tok)
            continue
        if tok not in flags:
            flags.append(tok)
    return flags, paths


def reexports_of(edge, reg):
    """(reexport labels, unported dylib names) from -Wl,-reexport_library flags."""
    # BOTH spellings: cmake emits `-Wl,-reexport_library -Wl,<path>` for some targets and
    # `-Wl,-reexport_library,<path>` for others. Matching only the first form silently
    # demoted libc++abi from a reexport of libc++ to an ordinary dependency, which dyld
    # then refused at runtime -- an initializer running before libSystem's.
    flags = edge[2].get("LINK_FLAGS", "") + " " + edge[2].get("LINK_LIBRARIES", "")
    paths = re.findall(r"-Wl,-reexport_library[,\s]+(?:-Wl,)?(\S+)", flags)
    labels, missing = [], []
    for path in paths:
        base = os.path.basename(path)
        if base in reg:
            if reg[base] not in labels:
                labels.append(reg[base])
        elif base not in missing:
            missing.append(base)
    return labels, missing


def siblings_of(edge, reg, final_reg):
    """(sibling labels, unported names) from a link edge's dylib inputs.

    Not every sibling is a FIRSTPASS dylib: libsystem_notify's and
    libsystem_sandbox's final passes link the FINAL libsystem_c.dylib and
    libsystem_kernel.dylib, because by then those are already built. Matching only
    the _firstpass spelling silently dropped them, and the link then failed on
    symbols as basic as _free.
    """
    sibs, missing = [], []
    for i in edge[1]:
        base = os.path.basename(i)
        # A framework binary has NO extension (CoreFoundation, DirectoryService), and
        # it is as much a library input as any .dylib -- memberd's _ds* symbols live in
        # one. Anything with a different extension (.o, .a) is not a library here.
        if not base.endswith(".dylib") and "." in base:
            continue
        m = re.match(r"lib([A-Za-z0-9_.-]+)_firstpass\.dylib$", base)
        if m:
            t = m.group(1)
            label = reg.get(t)
            name = f"lib{t}_firstpass.dylib"
        else:
            label = final_reg.get(base)
            if label is None and not base.endswith(".dylib"):
                # Extensionless and unknown: a tool or a phony, not a library.
                continue
            name = base
        if label:
            if label not in sibs:
                sibs.append(label)
        elif name not in missing:
            missing.append(name)
    return sibs, missing


def generate_dylibs(target: str, edges, only: str = ""):
    """The firstpass/final dylib pair for a cmake target, and its package.

    Darling links every circular library twice from the same objects (see
    cmake/darling_lib.cmake add_circular): once with undefined symbols suppressed,
    then again against the siblings' firstpass dylibs. Both edges are in the graph,
    so both the object set and the sibling set are read rather than guessed.
    """
    final, first = dylib_edges(target, edges)
    if final is None and first is None:
        return None
    ref = first or final
    libs = objlibs_of(ref)
    if not libs:
        return None

    objs, pkgs = [], {}
    aliased = []
    for lib in libs:
        if lib in OBJLIB_ALIASES:
            for label in OBJLIB_ALIASES[lib]:
                objs.append((None, label, lib))
            aliased.append(lib)
            continue
        names, pkg = obj_targets(lib, edges)
        pkgs[pkg] = pkgs.get(pkg, 0) + len(names)
        for n in names:
            objs.append((pkg, n, lib))
    pkg = max(pkgs, key=lambda k: pkgs[k])

    def obj_label(op, on):
        if op is None:
            return on
        return f":{on}" if op == pkg else f"//{op}:{on}"

    install_name = ""
    versions = {}
    for edge in (final, first):
        if not edge:
            continue
        lf = edge[2].get("LINK_FLAGS", "")
        m = re.search(r"-Wl,-dylib_install_name,(\S+)", lf)
        if m and not install_name:
            install_name = m.group(1)
        for key in ("current_version", "compatibility_version"):
            m = re.search(r"-Wl,-" + key + r",(\S+)", lf)
            if m:
                versions.setdefault(key, m.group(1))

    reg, final_reg = firstpass_registry(), final_registry()
    # A dylib can link static archives too, and the order LINK_LIBRARIES names them is
    # the resolution order: libcrypto's _explicit_bzero lives in libressl's compat
    # archive, and without it the link fails on a symbol nothing else provides.
    arch_reg = archive_registry()
    dylib_archives, missing_a = [], []
    for edge in (final, first):
        if not edge:
            continue
        for path in re.findall(r"(\S+\.a)\b", edge[2].get("LINK_LIBRARIES", "")):
            base = os.path.basename(path)
            a_label = arch_reg.get(base)
            if a_label and a_label not in dylib_archives:
                dylib_archives.append(a_label)
            elif not a_label and base not in missing_a:
                missing_a.append(base)
    # BOTH passes link siblings, and the firstpass ones matter as much: libc's
    # firstpass links libplatform's, which is how a client of libsystem_c resolves
    # _strcmp -- ld64 finds it in the INDIRECT dylib. Emitting siblings only on the
    # final pass left 14 members' finals undefined against the string routines.
    sibs, missing = siblings_of(final, reg, final_reg) if final else ([], [])
    sibs_first, missing_first = siblings_of(first, reg, final_reg) if first else ([], [])
    reex, reex_missing = reexports_of(final, final_reg) if final else ([], [])
    # A library named BOTH as a sibling and as a reexport gets linked twice, and the
    # plain mention wins: libSystem came out with 27 LC_LOAD_DYLIBs and no
    # LC_REEXPORT_DYLIB at all, which is the opposite of what an umbrella is for.
    # The match is per LIBRARY, not per label: the reference lists libsystem_malloc's
    # FIRSTPASS among the umbrella's inputs and reexports its FINAL, and those are two
    # labels for one install_name -- comparing labels left the reexport dropped, so
    # libc++abi could not resolve _malloc through libSystem.
    def _lib_of(label):
        name = label.rsplit(":", 1)[-1]
        for suffix in ("_firstpass", "_final", "_dylib"):
            if name.endswith(suffix):
                return name[: -len(suffix)]
        return name

    reex_libs = {_lib_of(r) for r in reex}
    sibs = [s for s in sibs if _lib_of(s) not in reex_libs]
    ldflags = [d[len("ldflag:"):] for d in extra_deps(target) if d.startswith("ldflag:")]
    # Object groups this port adds that no cmake object library corresponds to: the
    # kernel's generated rpc.c needs its own flag group (dserver-rpc-defs.h forced
    # in), and it is as load-bearing as any of the graph's own objects.
    extra_objs = [d[len("objs:"):] for d in extra_deps(target) if d.startswith("objs:")]
    extra_dylib_deps = [d[len("dep:"):] for d in extra_deps(target) if d.startswith("dep:")]
    # Libraries this port names explicitly where the reference relies on ld64 finding
    # them as an INDIRECT dylib (ICU's C++ ABI vtables live in libc++abi, reached in
    # the reference through libc++'s load command alone).
    for d in extra_deps(target):
        if d.startswith("dylib:"):
            sib_label = d[len("dylib:"):]
            if sib_label not in sibs:
                sibs.append(sib_label)
    final_flags, _ = semantic_link_flags(final[2]) if final else ([], [])
    first_flags, _ = semantic_link_flags(first[2]) if first else ([], [])
    final_files, final_elsewhere = link_flag_files(final[2], pkg) if final else ({}, [])
    first_files, first_elsewhere = link_flag_files(first[2], pkg) if first else ({}, [])

    out = []
    w = out.append
    w("# GENERATED from the reference build.ninja by")
    w(f"# scripts/gen-buck-from-ninja.py --dylibs {target}   -- review before committing.")
    w(f"# Links {len(libs)} cmake object library/ies, {len(objs)} flag groups in total.")
    for pass_name, names in (("final", missing), ("firstpass", missing_first)):
        if names:
            w(f"# TODO the {pass_name} pass also links these siblings, not ported yet:")
            for t in names:
                w(f"#   {t}")
    for pass_name, toks in (("final", final_elsewhere), ("firstpass", first_elsewhere)):
        if toks:
            w(f"# TODO the {pass_name} link passes these file-bearing flags whose file is")
            w("# not a source of this package:")
            for f in sorted(set(toks)):
                w(f"#   {f}")
    if missing_a:
        w("# TODO it also links these static archives, not ported yet:")
        for a in missing_a:
            w(f"#   {a}")
    if reex_missing:
        w(f"# TODO the final pass REEXPORTS {len(reex_missing)} more dylibs whose final")
        w("# pass is not ported yet; without them its symbol surface is incomplete:")
        for t in reex_missing:
            w(f"#   {t}")
    w("")

    single = first is None
    for kind in ("firstpass", "final"):
        if kind == "firstpass" and (first is None or only == "final"):
            continue
        if kind == "final" and only == "firstpass":
            continue
        if kind == "final" and final is None:
            continue
        w("darwin_dylib(")
        base = target.removesuffix("_obj")
        w(f'    name = "{base}_{"dylib" if single else kind}",')
        # The ARTIFACT name from the edge, not a guess: libSystem's final pass is
        # libSystem.B.dylib and libobjc's is libobjc.A.dylib.
        edge = first if kind == "firstpass" else final
        w(f'    dylib_name = "{os.path.basename(edge[0])}",')
        if kind == "firstpass":
            w("    firstpass = True,")
        w(f'    install_name = "{install_name}",')
        for key, val in sorted(versions.items()):
            w(f'    {key} = "{val}",')
        w("    objs = [")
        last = None
        for op, on, lib in objs:
            if lib != last:
                w(f"        # {lib}")
                last = lib
            w(f'        "{obj_label(op, on)}",')
        for extra in extra_objs:
            w(f'        "{extra}",  # added by this port (buck/generated/extra-deps.json)')
        w("    ],")
        kind_sibs = sibs if kind == "final" else sibs_first
        if kind_sibs:
            w("    siblings = [")
            for sl in kind_sibs:
                w(f'        "{sl}",')
            w("    ],")
        if kind == "final" and reex:
            w("    reexport = [")
            for rl in reex:
                w(f'        "{rl}",')
            w("    ],")
        # The firstpass rule adds -flat_namespace/-undefined,suppress itself; the rest
        # of the reference's semantic flags apply to whichever pass carries them.
        own = final_flags if kind == "final" else [
            f for f in first_flags if f not in ("-Wl,-flat_namespace", "-Wl,-undefined,suppress")]
        kind_flags = list(ldflags) + own
        if kind_flags:
            w("    linker_flags = [")
            for f in kind_flags:
                w(f"        {starlark_str(f)},")
            w("    ],")
        if dylib_archives and not extra_dylib_deps:
            extra_dylib_deps = list(dylib_archives)
        elif dylib_archives:
            extra_dylib_deps = extra_dylib_deps + [a for a in dylib_archives
                                                   if a not in extra_dylib_deps]
        kind_files = final_files if kind == "final" else first_files
        if kind_files:
            w("    link_flag_files = {")
            for flag, rel in sorted(kind_files.items()):
                w(f'        "{flag}": "{rel}",')
            w("    },")
        w('    toolchain = "toolchains//:darwin_cc",')
        if extra_dylib_deps:
            w("    deps = [")
            w('        "//darwin:sdk_env",')
            for d in extra_dylib_deps:
                w(f'        "{d}",')
            w("    ],")
        else:
            w('    deps = ["//darwin:sdk_env"],')
        w('    visibility = ["PUBLIC"],')
        w(")")
        w("")

    if aliased:
        out.insert(3, "# Object libraries whose sources are compiled elsewhere in this port, so "
                      "they\n# contribute no target here: " + ", ".join(aliased))
    return "\n".join(out).rstrip() + "\n", pkg


def archive_edge(name: str, edges):
    """The archive link edge producing `name` (libfoo_static.a, or just foo_static)."""
    cands = {name, f"lib{name}.a", f"{name}.a"}
    for outs, _rule, inputs, vars in edges:
        for o in outs:
            if "/" in o and os.path.basename(o) in cands and any(i.endswith(".o") for i in inputs):
                return (o, inputs, vars)
    return None


def archive_target_name(artifact: str) -> str:
    """libsystem_kernel_static64.a -> system_kernel_static64.

    Object-library targets always end in _obj, so this can never collide with one
    (the archive libsystem_blocks_static.a is built FROM the object library
    system_blocks_static, whose target is system_blocks_static_obj).
    """
    base = os.path.basename(artifact)
    return base.removeprefix("lib").removesuffix(".a")


# Archives this port already builds under a different artifact name. The name is
# just a path on the link line, so only the mapping matters: libsimple's Darwin
# archive is libsimple_darling.a here and liblibsimple_darling.a in the reference
# (cmake doubles the "lib" for a target already called libsimple_darling).
ARCHIVE_ALIASES = {
    "liblibsimple_darling.a": "//src/libsimple:libsimple_darling",
    # The host tier, ported before cc_static_lib existed (both are cc_library targets
    # whose archive the Rust daemon consumes through DUCT_TAPE_LIB).
    "libdarlingserver_duct_tape.a":
        "//src/external/darlingserver/duct-tape:darlingserver_duct_tape",
    "liblibsimple_darlingserver.a": "//src/libsimple:libsimple_darlingserver",
}


def archive_registry() -> dict:
    """archive artifact name -> buck label, for every static library declared."""
    reg = dict(ARCHIVE_ALIASES)
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in ("buck-out", ".git", ".jj", ".direnv", "build")]
        if "BUCK" not in filenames:
            continue
        pkg = os.path.relpath(dirpath, REPO)
        text = open(os.path.join(dirpath, "BUCK")).read()
        for m in re.finditer(
                r'cc_static_lib\(\s*\n\s*name = "([A-Za-z0-9_.-]+)",'
                r'(?:\s*\n\s*lib_name = "([^"]+)",)?', text):
            artifact = m.group(2) or f"lib{m.group(1)}.a"
            reg[artifact] = f"//{pkg}:{m.group(1)}"
    return reg


def generate_archive(name: str, edges):
    """A cc_static_lib for one archive, and its package."""
    edge = archive_edge(name, edges)
    if edge is None:
        return None
    libs = objlibs_of(edge)
    if not libs:
        return None
    objs, pkgs, aliased = [], {}, []
    for lib in libs:
        if lib in OBJLIB_ALIASES:
            for label in OBJLIB_ALIASES[lib]:
                objs.append((None, label, lib))
            aliased.append(lib)
            continue
        names, pkg = obj_targets(lib, edges)
        pkgs[pkg] = pkgs.get(pkg, 0) + len(names)
        for n in names:
            objs.append((pkg, n, lib))
    if not pkgs:
        return None
    pkg = max(pkgs, key=lambda k: pkgs[k])
    artifact = os.path.basename(edge[0])
    target = archive_target_name(artifact)
    # Object groups this port adds that no cmake object library corresponds to, keyed
    # by ARTIFACT name (the static kernel needs the generated rpc.c in its own group).
    extra_objs = [x[len("objs:"):] for x in extra_deps(artifact) if x.startswith("objs:")]

    out = []
    w = out.append
    w("# GENERATED from the reference build.ninja by")
    w(f"# scripts/gen-buck-from-ninja.py --archives {name}   -- review before committing.")
    w(f"# Archives {len(libs)} cmake object library/ies, {len(objs)} flag groups.")
    if aliased:
        w("# Object libraries whose sources are compiled elsewhere in this port: "
          + ", ".join(aliased))
    w("")
    w("cc_static_lib(")
    w(f'    name = "{target}",')
    w(f'    lib_name = "{artifact}",')
    w("    objs = [")
    last = None
    for op, on, lib in objs:
        if lib != last:
            w(f"        # {lib}")
            last = lib
        w(f'        "{on if op is None else (":" + on if op == pkg else "//" + op + ":" + on)}",')
    for extra in extra_objs:
        w(f'        "{extra}",  # added by this port (buck/generated/extra-deps.json)')
    w("    ],")
    w('    toolchain = "toolchains//:darwin_cc",')
    w('    visibility = ["PUBLIC"],')
    w(")")
    return "\n".join(out).rstrip() + "\n", pkg


def exe_edge(target: str, edges):
    """The executable link edge that produces `target`.

    An executable has no extension and no -dylib_install_name, and it links object
    files; that is enough to tell it from the dylib and utility edges.
    """
    for outs, _rule, inputs, vars in edges:
        lf = vars.get("LINK_FLAGS", "")
        if not lf or "dylib_install_name" in lf:
            continue
        for o in outs:
            if "/" not in o or os.path.basename(o) != target or "." in os.path.basename(o):
                continue
            if any(i.endswith(".o") for i in inputs):
                return (o, inputs, vars)
    return None


def generate_binary(target: str, edges):
    """A darwin_binary for one executable, and its package.

    The object libraries and the libraries it links both come from the edge, the same
    way the dylib pair does -- an executable is just a link with no install_name.
    """
    edge = exe_edge(target, edges)
    if edge is None:
        return None
    libs = objlibs_of(edge)
    if not libs:
        return None

    objs, pkgs, aliased = [], {}, []
    for lib in libs:
        if lib in OBJLIB_ALIASES:
            for label in OBJLIB_ALIASES[lib]:
                objs.append((None, label, lib))
            aliased.append(lib)
            continue
        names, pkg = obj_targets(lib, edges)
        pkgs[pkg] = pkgs.get(pkg, 0) + len(names)
        for n in names:
            objs.append((pkg, n, lib))
    for op, on, lib in explicit_objects(edge, edges):
        pkgs[op] = pkgs.get(op, 0) + 1
        if (op, on, lib) not in objs:
            objs.append((op, on, lib))
    if not pkgs:
        return None
    pkg = max(pkgs, key=lambda k: pkgs[k])

    reg, final_reg = firstpass_registry(), final_registry()
    dylibs, missing = siblings_of(edge, reg, final_reg)
    # Static archives, in the order LINK_LIBRARIES names them: for archives the order
    # IS the resolution order, so preserving it is part of being faithful.
    arch_reg = archive_registry()
    archives, missing_a = [], []
    ordered = re.findall(r"(\S+\.a)\b", edge[2].get("LINK_LIBRARIES", "")) or \
        [i for i in edge[1] if i.endswith(".a")]
    for path in ordered:
        base = os.path.basename(path)
        label = arch_reg.get(base)
        if label:
            if label not in archives:
                archives.append(label)
        elif base not in missing_a:
            missing_a.append(base)
    missing = missing + missing_a
    flags, _ = semantic_link_flags(edge[2])
    files, elsewhere = link_flag_files(edge[2], pkg)
    extra_objs = [d[len("objs:"):] for d in extra_deps(target) if d.startswith("objs:")]
    extra_dylib_deps = [d[len("dep:"):] for d in extra_deps(target) if d.startswith("dep:")]
    # Libraries this port has to name explicitly where the reference relies on ld64
    # finding them as an INDIRECT dylib (otool's __cxa_demangle lives in libc++abi,
    # which the reference reaches through libc++'s load command alone).
    for d in extra_deps(target):
        if d.startswith("dylib:") and d[len("dylib:"):] not in dylibs:
            dylibs.append(d[len("dylib:"):])

    out = []
    w = out.append
    w("# GENERATED from the reference build.ninja by")
    w(f"# scripts/gen-buck-from-ninja.py --binaries {target}   -- review before committing.")
    w(f"# Links {len(libs)} cmake object library/ies, {len(objs)} flag groups in total.")
    if aliased:
        w("# Object libraries whose sources are compiled elsewhere in this port, so they")
        w("# contribute no target here: " + ", ".join(aliased))
    if missing:
        w("# TODO it also links these libraries, not ported yet:")
        for t in missing:
            w(f"#   {t}")
    if elsewhere:
        w("# TODO file-bearing link flags whose file is not a source of this package:")
        for f in sorted(set(elsewhere)):
            w(f"#   {f}")
    w("")
    w("darwin_binary(")
    w(f'    name = "{target}",')
    w("    objs = [")
    last = None
    for op, on, lib in objs:
        if lib != last:
            w(f"        # {lib}")
            last = lib
        w(f'        "{on if op is None else (":" + on if op == pkg else "//" + op + ":" + on)}",')
    for extra in extra_objs:
        w(f'        "{extra}",  # added by this port (buck/generated/extra-deps.json)')
    w("    ],")
    if dylibs:
        w("    dylibs = [")
        for d in dylibs:
            w(f'        "{d}",')
        w("    ],")
    if flags:
        w("    linker_flags = [")
        for f in flags:
            w(f"        {starlark_str(f)},")
        w("    ],")
    if files:
        w("    link_flag_files = {")
        for flag, rel in sorted(files.items()):
            w(f'        "{flag}": "{rel}",')
        w("    },")
    w('    toolchain = "toolchains//:darwin_cc",')
    w("    deps = [")
    w('        "//darwin:sdk_env",')
    for a in archives:
        w(f'        "{a}",')
    for d in extra_dylib_deps:
        w(f'        "{d}",')
    w("    ],")
    w('    visibility = ["PUBLIC"],')
    w(")")
    return "\n".join(out).rstrip() + "\n", pkg


def write_block(pkg: str, marker: str, text: str) -> None:
    """Splice a generated block into a package's BUCK file, replacing any old one."""
    f = os.path.join(REPO, pkg, "BUCK")
    begin, end = f"# BEGIN generated: {marker}\n", f"# END generated: {marker}\n"
    block = begin + text.rstrip() + "\n" + end
    existing = open(f).read() if os.path.exists(f) else ""
    if begin in existing:
        pre, rest = existing.split(begin, 1)
        _, post = rest.split(end, 1)
        new = pre + block + post
    else:
        new = existing.rstrip() + ("\n\n" if existing.strip() else "") + block
    with open(f, "w") as fh:
        fh.write(new)


def main(argv: list[str]) -> int:
    if not os.path.exists(GRAPH):
        sys.exit(f"no reference graph at {GRAPH}\nrun: nix build .#darling-graph -o result-graph-ref")
    args = [a for a in argv[1:] if not a.startswith("--")]
    edges = read_edges()

    if "--list" in argv:
        seen, pat = set(), args[0] if args else ""
        for outs, _, _, _ in edges:
            for o in outs:
                m = re.search(r"CMakeFiles/([^/]+)\.dir/", o)
                if m and pat in m.group(1):
                    seen.add(m.group(1))
        for t in sorted(seen):
            print(t)
        return 0

    if not args:
        sys.exit(__doc__)

    for target in args:
        if "--explain" in argv:
            units, link = collect(target, edges)
            print(f"=== {target}: {len(units)} sources")
            groups: dict[tuple, list[str]] = {}
            for u in units:
                flags, prefix = own_flags_of(u)
                groups.setdefault((tuple(flags), tuple(p for _, p in prefix)), []).append(u["src"])
            print(f"  flag groups: {len(groups)}")
            for (flags, prefix), srcs in list(groups.items())[:6]:
                print(f"    {len(srcs):4d} srcs  {' '.join(flags)[:110]}")
                if prefix:
                    print(f"          -include {list(prefix)}")
            if units:
                own, gen = includes_of(units[0])
                print("  ordered include roots:", own)
                print("  generated include dirs:", gen)
            if link:
                print("  link out:", link[0])
            continue

        if "--archives" in argv:
            pair = generate_archive(target, edges)
            if pair is None:
                print(f"# no archive edge for {target}", file=sys.stderr)
                continue
            text, pkg = pair
            if "--write" not in argv:
                print(text)
                continue
            write_block(pkg, target + " archive", text)
            print(f"wrote {pkg}/BUCK: {target} archive", file=sys.stderr)
            continue

        if "--binaries" in argv:
            pair = generate_binary(target, edges)
            if pair is None:
                print(f"# no executable link edge for {target}", file=sys.stderr)
                continue
            text, pkg = pair
            if "--write" not in argv:
                print(text)
                continue
            write_block(pkg, target + " binary", text)
            print(f"wrote {pkg}/BUCK: {target} binary", file=sys.stderr)
            continue

        if "--dylibs" in argv:
            only = "final" if "--final-only" in argv else (
                "firstpass" if "--firstpass-only" in argv else "")
            pair = generate_dylibs(target, edges, only)
            if pair is None:
                print(f"# no dylib link edge for cmake target {target}", file=sys.stderr)
                continue
            text, pkg = pair
            if "--write" not in argv:
                print(text)
                continue
            # ONE marker per target, whichever kinds the block holds: a suffixed
            # variant would register the same target twice.
            marker = target + " dylibs"
            write_block(pkg, marker, text)
            print(f"wrote {pkg}/BUCK: {marker}", file=sys.stderr)
            continue

        result = generate(target, edges)
        if result is None:
            print(f"# no object edges for cmake target {target}; "
                  f"try --dylibs if it is a link-only target", file=sys.stderr)
            continue
        text, src_paths = result

        if "--write" not in argv:
            print(text)
            continue

        # Which package owns this target? The one holding its sources: buck-src for
        # materialized pins, otherwise the committed tree they live in.
        pkg = package_of(src_paths)
        # Paths are emitted repo-relative; a BUCK file addresses its own package. A
        # pin package's sources are already pin-relative (libc/gen/x.c), so what has
        # to come off is the pin name, not the whole package path.
        if pkg.startswith(BUCK_SRC + "/"):
            pin = pkg[len(BUCK_SRC) + 1:]
            text = text.replace('"' + pin + "/", '"')
            # The pin DIRECTORY itself, which the trailing-slash form cannot match: an
            # include root or a mig out_base can be exactly the pin, and package-relative
            # that is the package itself.
            text = re.sub(r'^(\s*(?:root|out_base) = )"' + re.escape(pin) + '"',
                          r'\1""', text, flags=re.M)
        elif pkg != BUCK_SRC:
            text = text.replace('"' + pkg + "/", '"')

        # Whole-line markers: a target name can be a PREFIX of another block's
        # name, and matching on the bare text splices into the wrong block.
        write_block(pkg, target, text)
        print(f"wrote {pkg}/BUCK: {target} ({len(src_paths)} srcs)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
