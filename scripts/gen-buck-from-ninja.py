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
between BEGIN/END markers so re-running replaces rather than duplicates.

What it cannot do, and says so instead of guessing: a source or include dir that
lives in the cmake BINARY dir is generated, and needs a codegen target (mig_gen,
script_gen, ...) wired by hand. Those are reported as TODO comments.
"""
from __future__ import annotations

import os
import re
import sys
from collections import OrderedDict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRAPH = os.path.join(REPO, "result-graph-ref", "build.ninja")
BUCK_SRC = "buck-src"

# The nix build's source and binary dirs, as they appear in build.ninja.
SRC_STORE_RE = re.compile(r"/nix/store/[a-z0-9]{32}-darling-cmake-src")
BIN_DIR = "/build/build"

# Flags and include roots //darwin:sdk_env already supplies, so a generated target
# does not repeat them. Keep in sync with darwin/BUCK.
ENV_FLAGS = {
    "-Wno-error=implicit-function-declaration",
    "-Wno-nullability-completeness",
    "-Wno-deprecated-declarations",
    "-Wno-availability",
    "-Wno-expansion-to-defined",
    "-Wno-elaborated-enum-base",
    "-Wno-undef-prefix",
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
    "-target",
    "x86_64-apple-darwin20",
    "-arch",
    "x86_64",
    "-mmacosx-version-min=11.0",
    "-isystem",
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
    # The C++ standard library. It MUST NOT be emitted per-target as well: two
    # copies of libcxx/include on one command line break #include_next, because
    # libcxx's stdint.h defers to the next stdint.h on the path and finds the other
    # staged copy of ITSELF instead of the SDK's -- so uint32_t ends up undefined.
    "src/external/libcxx/include",
    "darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/libxml2",
}


def read_edges():
    """Parse build.ninja into [(outputs, rule, inputs, vars)]."""
    with open(GRAPH) as f:
        text = f.read()
    edges = []
    cur = None
    for line in text.split("\n"):
        if line.startswith("build "):
            body = line[len("build "):]
            head, _, rest = body.partition(": ")
            rule, _, inputs = rest.partition(" ")
            outs = head.split(" | ")[0].split()
            cur = (outs, rule, inputs.split(), {})
            edges.append(cur)
        elif cur is not None and line.startswith("  ") and " = " in line:
            k, _, v = line.strip().partition(" = ")
            cur[3][k] = v
        elif line.strip() == "":
            cur = None
    return edges


def orig_repo_rel(p: str) -> str:
    """The path as it is relative to the repo root, whatever tree it lives in."""
    return SRC_STORE_RE.sub("", p).replace(BIN_DIR, "").lstrip("/")


def repo_path(p: str):
    """Map a build.ninja path to (kind, path).

    kind is "src" for a repo-relative source path, "buck-src" for one that has
    been rewritten into the materialized pins, or "generated" for anything in the
    cmake binary dir.
    """
    p = SRC_STORE_RE.sub("", p)
    if p.startswith(BIN_DIR):
        return ("generated", os.path.normpath(p[len(BIN_DIR):].lstrip("/")))
    p = os.path.normpath(p.lstrip("/"))
    if p.startswith("src/external/"):
        rel = p[len("src/external/"):]
        if os.path.exists(os.path.join(REPO, BUCK_SRC, rel)):
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


def collect(target: str, edges):
    """Everything build.ninja says about one cmake target."""
    obj_re = re.compile(r"CMakeFiles/" + re.escape(target) + r"\.dir/")
    srcs, defines, flags, includes = [], [], [], []
    link = None
    for outs, rule, inputs, vars in edges:
        if any(obj_re.search(o) for o in outs) and any(o.endswith(".o") for o in outs):
            for i in inputs:
                if i.startswith("|") or i.startswith("||"):
                    break
                if re.search(r"\.(c|cc|cpp|cxx|m|mm|S|s)$", i):
                    srcs.append(i)
            if not defines and "DEFINES" in vars:
                defines = split_flags(vars["DEFINES"])
            if not flags and "FLAGS" in vars:
                flags = split_flags(vars["FLAGS"])
            if not includes and "INCLUDES" in vars:
                includes = split_flags(vars["INCLUDES"])
        elif link is None:
            for o in outs:
                base = os.path.basename(o)
                if base in (target, "lib" + target + ".a", "lib" + target + ".dylib") or (
                    base.startswith("lib" + target) and base.endswith(".dylib")
                ):
                    link = (o, vars)
                    break
    return srcs, defines, flags, includes, link


def extra_deps(target: str) -> list[str]:
    """Hand-added deps for a target (frameworks, codegen), from a committed file.

    --write replaces a generated block wholesale, so a dep added by hand inside one
    would be lost on the next run. Keeping them in buck/generated/extra-deps.json
    makes them survive, and puts every such decision in one reviewable place.
    """
    import json
    f = os.path.join(REPO, "buck", "generated", "extra-deps.json")
    if not os.path.exists(f):
        return []
    with open(f) as fh:
        data = json.load(fh)
    return [d for d in data.get(target, []) if isinstance(d, str)]


def main(argv: list[str]) -> int:
    if not os.path.exists(GRAPH):
        sys.exit(f"no reference graph at {GRAPH}\nrun: nix build .#darling-graph -o result-graph-ref")
    args = [a for a in argv[1:] if not a.startswith("--")]
    edges = read_edges()

    if "--list" in argv:
        seen = set()
        pat = args[0] if args else ""
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

    write = "--write" in argv
    for target in args:
        # cmake object libraries are already called <thing>_obj; do not double it.
        obj_name = target if target.endswith("_obj") else target + "_obj"
        out_lines: list[str] = []

        def emit(line: str = ""):
            out_lines.append(line)

        srcs, defines, flags, includes, link = collect(target, edges)
        if not srcs:
            print(f"# no object edges found for cmake target {target}", file=sys.stderr)
            continue

        if "--explain" in argv:
            print(f"=== {target}")
            print("  srcs:", len(srcs))
            print("  defines:", " ".join(defines))
            print("  flags:", " ".join(flags))
            print("  includes:")
            for i in includes:
                if i in ("-isystem",):
                    continue
                print("   ", repo_path(i.removeprefix("-I")))
            if link:
                print("  link out:", link[0])
                print("  link flags:", link[1].get("LINK_FLAGS", "")[:400])
            continue

        # Sources, split by where they live.
        src_paths, gen_srcs, pkg_dirs = [], [], OrderedDict()
        for s in srcs:
            kind, p = repo_path(s)
            if kind == "generated":
                gen_srcs.append(p)
            else:
                src_paths.append((kind, p))
                pkg_dirs[os.path.dirname(p)] = True

        # The include dirs this target adds beyond the shared environment.
        own_includes, gen_includes = [], []
        for i in includes:
            if not i.startswith("-I"):
                continue
            if orig_repo_rel(i[2:]) in ENV_INCLUDES:
                continue
            kind, p = repo_path(i[2:])
            if kind == "generated":
                gen_includes.append(p)
            else:
                own_includes.append((kind, p))

        # -B and -isystem take a following argument, so both tokens have to go:
        # -B is a link concern and the resource dir comes from the toolchain.
        own_flags, skip_next = [], False
        for f in defines + flags:
            if skip_next:
                skip_next = False
                continue
            if f in ("-B", "-isystem"):
                skip_next = True
                continue
            if f in ENV_FLAGS or f in TOOLCHAIN_FLAGS:
                continue
            if "resource-root" in f:
                continue
            own_flags.append(f)

        install_name = ""
        is_dylib = False
        if link:
            lf = link[1].get("LINK_FLAGS", "")
            m = re.search(r"-Wl,-dylib_install_name,(\S+)", lf)
            if m:
                install_name = m.group(1)
            is_dylib = link[0].endswith(".dylib")

        emit(f"# GENERATED from the reference build.ninja by")
        emit(f"# scripts/gen-buck-from-ninja.py {target}   -- review before committing.")
        emit(f"# cmake target: {target}" + (f"  ->  {link[0]}" if link else ""))
        if gen_srcs:
            emit("# TODO these sources are GENERATED; wire a codegen target for each:")
            for g in gen_srcs:
                emit(f"#   {g}")
        if gen_includes:
            emit("# TODO these include dirs are GENERATED (codegen output):")
            for g in gen_includes:
                emit(f"#   {g}")
        emit()

        for idx, (kind, p) in enumerate(own_includes):
            name = target.removesuffix("_obj") + "_inc" + ("" if idx == 0 else str(idx))
            emit("cc_header_root(")
            emit(f'    name = "{name}",')
            emit(f'    headers = glob(["{p}/**/*.h"]),')
            emit(f'    root = "{p}",')
            emit(")")
            emit()

        emit("cc_objects(")
        emit(f'    name = "{obj_name}",')
        emit("    srcs = [")
        for kind, p in src_paths:
            emit(f'        "{p}",')
        emit("    ],")
        if own_flags:
            emit("    compiler_flags = [")
            for f in own_flags:
                emit(f'        "{f}",')
            emit("    ],")
        emit('    toolchain = "toolchains//:darwin_cc",')
        emit("    deps = [")
        for idx in range(len(own_includes)):
            emit(f'        ":{target.removesuffix("_obj")}_inc{"" if idx == 0 else idx}",')
        for d in extra_deps(target):
            emit(f'        "{d}",')
        emit('        "//darwin:sdk_env",')
        emit("    ],")
        emit(")")
        emit()

        if is_dylib:
            emit("darwin_dylib(")
            emit(f'    name = "{target}_firstpass",')
            emit(f'    dylib_name = "lib{target.replace("system_", "system_")}_firstpass.dylib",')
            emit("    firstpass = True,")
            emit(f'    install_name = "{install_name}",')
            emit(f'    objs = [":{obj_name}",],')
            emit('    toolchain = "toolchains//:darwin_cc",')
            emit('    deps = ["//darwin:sdk_env"],')
            emit('    visibility = ["PUBLIC"],')
            emit(")")
            emit()
        text = "\n".join(out_lines)
        if not write:
            print(text)
            continue

        # Which package owns this target? The one holding its sources: buck-src for
        # materialized pins, otherwise the committed tree they live in.
        kinds = {k for k, _ in src_paths}
        if kinds == {"buck-src"}:
            pkg = "buck-src"
        else:
            repo_srcs = [p for k, p in src_paths if k == "src"]
            depth = 3 if repo_srcs and repo_srcs[0].startswith("src/external/") else 2
            pkg = "/".join(repo_srcs[0].split("/")[:depth])
        # Sources and roots are emitted repo-relative, but a BUCK file addresses
        # its own package, so rebase onto it.
        if pkg != "buck-src":
            text = text.replace('"' + pkg + "/", '"')
        f = os.path.join(REPO, pkg, "BUCK")
        begin, end = f"# BEGIN generated: {target}", f"# END generated: {target}"
        block = begin + "\n" + text.rstrip() + "\n" + end + "\n"
        existing = ""
        if os.path.exists(f):
            existing = open(f).read()
        if begin in existing:
            pre, rest = existing.split(begin, 1)
            _, post = rest.split(end, 1)
            new = pre + block + post
        else:
            loads = ""
            if "load(\"//buck/rules:cc.bzl\"" not in existing:
                loads += 'load("//buck/rules:cc.bzl", "cc_header_root", "cc_objects")\n'
            if "darwin_dylib" in text and "load(\"//buck/rules:darwin.bzl\"" not in existing:
                loads += 'load("//buck/rules:darwin.bzl", "darwin_dylib")\n'
            new = (loads + existing).rstrip() + "\n\n" + block
        with open(f, "w") as fh:
            fh.write(new)
        print(f"wrote {pkg}/BUCK: {target} ({len(src_paths)} srcs)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
