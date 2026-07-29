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
            cur = (head.split(" | ")[0].split(), rule, inputs.split(), {})
            edges.append(cur)
        elif cur is not None and line.startswith("  ") and " = " in line:
            k, _, v = line.strip().partition(" = ")
            cur[3][k] = v
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
    """Split a ninja flag string, honoring the single quotes cmake emits."""
    out, cur, quote = [], "", None
    for ch in s:
        if quote:
            if ch == quote:
                quote = None
            else:
                cur += ch
        elif ch in "'\"":
            quote = ch
        elif ch.isspace():
            if cur:
                out.append(cur)
                cur = ""
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def link_object_libraries(target: str, edges):
    """The cmake OBJECT LIBRARIES a link edge pulls in, in the reference's order.

    A libSystem member is linked from object libraries rather than from its own
    sources (cmake's add_circular takes OBJECTS), and WHICH ones matters: libc
    ships alternates of the same sources -- the `_dyld` variants exist for
    libsystem_dyld -- so linking every libc-* group produces ~190 duplicate
    symbols. The link edge is the authority on the right subset.
    """
    for outs, rule, inputs, vars in edges:
        for o in outs:
            if os.path.basename(o) != target and not o.endswith("/" + target):
                continue
            libs, seen = [], set()
            for i in inputs:
                if i.startswith("|"):
                    break
                m = re.search(r"CMakeFiles/([^/]+)\.dir/", i)
                if m and i.endswith(".o") and m.group(1) not in seen:
                    seen.add(m.group(1))
                    libs.append(m.group(1))
            if libs:
                return libs, (o, vars)
    return [], None


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


def sanitize(path: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_")


def generate(target: str, edges):
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
    if not groups:
        return None

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
    if gen_includes:
        w("# TODO these include dirs are GENERATED (codegen output):")
        for g in sorted(set(gen_includes)):
            w(f"#   {g}")
    w("")

    # One header root per distinct include dir, shared across groups.
    root_name: dict[str, str] = {}
    for g in groups.values():
        for kind, p in g["inc"]:
            if kind != "own" or p in root_name:
                continue
            name = target.removesuffix("_obj") + "_inc_" + sanitize(p.split("/", 1)[-1])[-40:]
            root_name[p] = name
            w("cc_header_root(")
            w(f'    name = "{name}",')
            # BOTH patterns: buck2's "dir/**/*.h" does not match dir/x.h, so a
            # root whose headers sit directly in it would stage EMPTY.
            w(f'    headers = glob(["{p}/*.h", "{p}/**/*.h"]),')
            w(f'    root = "{p}",')
            w(")")
            w("")

    base = target if target.endswith("_obj") else target + "_obj"
    obj_names = []
    ordered = sorted(groups.values(), key=lambda g: (-len(g["srcs"]), g["srcs"][0][1]))
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
                w(f'        "{f}",')
            w("    ],")
        if g["prefix"]:
            w("    prefix_headers = [")
            for _, hp in g["prefix"]:
                w(f'        "{hp}",')
            w("    ],")
        w('    toolchain = "toolchains//:darwin_cc",')
        w("    deps = [")
        # Dep ORDER is the include order, and the environment sits where the
        # reference puts it -- not first, not last.
        for kind, p in g["inc"]:
            if kind == "env":
                w('        "//darwin:sdk_env",')
                for d in extra_deps(target):
                    # gen: and ldflag: entries are not deps.
                    if not d.startswith(("gen:", "ldflag:")):
                        w(f'        "{d}",')
            else:
                w(f'        ":{root_name[p]}",')
        w("    ],")
        gen = [d[len("gen:"):] for d in extra_deps(target) if d.startswith("gen:")]
        if gen and idx == 0:
            # Generated sources this target compiles. Only the first flag group
            # takes them: they are one set of files, not one per group.
            w("    gen_srcs = [")
            for d in gen:
                w(f'        "{d}",')
            w("    ],")
        w(")")
        w("")

    install_name, is_dylib = "", False
    if link:
        m = re.search(r"-Wl,-dylib_install_name,(\S+)", link[1].get("LINK_FLAGS", ""))
        install_name = m.group(1) if m else ""
        is_dylib = link[0].endswith(".dylib")
    ldflags = [d[len("ldflag:"):] for d in extra_deps(target) if d.startswith("ldflag:")]
    if is_dylib:
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

        result = generate(target, edges)
        if result is None:
            libs, link = link_object_libraries(target, edges)
            if not libs:
                print(f"# no object or link edges found for cmake target {target}", file=sys.stderr)
                continue
            m = re.search(r"-Wl,-dylib_install_name,(\S+)", link[1].get("LINK_FLAGS", ""))
            install_name = m.group(1) if m else ""
            print("# GENERATED from the reference build.ninja by")
            print(f"# scripts/gen-buck-from-ninja.py {target}   -- review before committing.")
            print(f"# Links {len(libs)} cmake object libraries, exactly the set the reference")
            print("# link edge names (libc ships alternates of the same sources, so the subset")
            print("# matters: linking all of them yields ~190 duplicate symbols).")
            print("darwin_dylib(")
            print(f'    name = "{target}",')
            print(f'    dylib_name = "lib{target}.dylib",')
            print(f'    firstpass = {"True" if "firstpass" in target else "False"},')
            print(f'    install_name = "{install_name}",')
            print("    objs = [")
            for lib in libs:
                # Each cmake object library can be SEVERAL targets here, one per
                # flag group. Naming only the first silently drops objects: the
                # dylib still links, but symbols defined in the other groups come
                # out undefined (which is how libsystem_pthread ended up with an
                # illegal text reloc to a symbol its own pthread.c defines).
                print(f"        # {lib}")
                base = lib if lib.endswith("_obj") else lib + "_obj"
                print(f'        ":{base}",  # plus :{base}2.. if it has more flag groups')
            print("    ],")
            print('    toolchain = "toolchains//:darwin_cc",')
            print('    deps = ["//darwin:sdk_env"],')
            print('    visibility = ["PUBLIC"],')
            print(")")
            continue
        text, src_paths = result

        if "--write" not in argv:
            print(text)
            continue

        # Which package owns this target? The one holding its sources: buck-src for
        # materialized pins, otherwise the committed tree they live in.
        kinds = {k for k, _ in src_paths}
        if kinds == {"buck-src"}:
            pkg = BUCK_SRC
        else:
            repo_srcs = [p for k, p in src_paths if k == "src"]
            depth = 3 if repo_srcs and repo_srcs[0].startswith("src/external/") else 2
            pkg = "/".join(repo_srcs[0].split("/")[:depth])
        # Paths are emitted repo-relative; a BUCK file addresses its own package.
        if pkg != BUCK_SRC:
            text = text.replace('"' + pkg + "/", '"')

        f = os.path.join(REPO, pkg, "BUCK")
        # Whole-line markers: a target name can be a PREFIX of another block's
        # name, and matching on the bare text splices into the wrong block.
        begin, end = f"# BEGIN generated: {target}\n", f"# END generated: {target}\n"
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
        print(f"wrote {pkg}/BUCK: {target} ({len(src_paths)} srcs)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
