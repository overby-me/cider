#!/usr/bin/env python3
"""Generate src/external/darlingserver/duct-tape/BUCK from its CMakeLists.txt.

duct-tape is ~135 source paths, 45 MIG definitions and ~120 preprocessor
defines. Hand-transcribing that is error-prone and would drift on every upstream
bump, so the lists are extracted from the CMakeLists (the authority for this
target) and the BUCK file is generated. plan/buck2-port.md phase 2.1: generated
where it drifts, hand-authored where we iterate.

What is NOT in the CMakeLists, and is therefore spelled out below, is the flags
duct-tape inherits from parent scopes. Those were read off the configured
reference build.ninja (darling-graph's build.ninja, the exact DEFINES/FLAGS
ninja passes clang), not guessed -- reading only duct-tape/CMakeLists.txt would
miss -DDARLING, the four DSERVER_* defines and the -Wno-nullability group.

Usage:
  scripts/gen-duct-tape-buck.py            # write the BUCK file
  scripts/gen-duct-tape-buck.py --stdout   # print it instead
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DT = "src/external/darlingserver/duct-tape"
CMAKELISTS = os.path.join(REPO, DT, "CMakeLists.txt")
OUT = os.path.join(REPO, DT, "BUCK")

# Inherited from the top-level CMakeLists and src/external/darlingserver's, in
# the order the reference build passes them.
PARENT_DEFINES = [
    "-DDARLING",
    "-DDSERVER_ASAN=0",
    "-DDSERVER_UBSAN=0",
    "-DDSERVER_EXTENDED_DEBUG=0",
    "-DDSERVER_SINGLE_THREADED=1",
]

# Warning flags every Darling compile gets from the top-level CMakeLists, plus
# the -Wno-error=implicit-function-declaration that nix/lib/darling-graph.nix
# and nix/package.nix pass as CMAKE_C_FLAGS.
PARENT_FLAGS = [
    "-Wno-error=implicit-function-declaration",
    "-Wno-nullability-completeness",
    "-Wno-deprecated-declarations",
    "-Wno-availability",
    "-Wno-expansion-to-defined",
    "-Wno-elaborated-enum-base",
    "-Wno-undef-prefix",
]

# duct-tape's include_directories(), in order. Each becomes a cc_header_root.
# `bin:` prefixed entries are generated trees (mig output, rpc wrappers, rtsig)
# and are wired as deps instead.
HEADER_ROOTS = [
    ("dt_defines", "defines"),
    ("xnu_osfmk", "xnu/osfmk"),
    ("xnu_bsd", "xnu/bsd"),
    ("xnu_libkern", "xnu/libkern"),
    ("xnu_osfmk_libsa", "xnu/osfmk/libsa"),
    ("xnu_pexpert", "xnu/pexpert"),
    ("xnu_iokit", "xnu/iokit"),
    ("xnu_external_headers", "xnu/EXTERNAL_HEADERS"),
    ("xnu_root", "xnu"),
    ("dt_internal_include", "internal-include"),
    ("dt_include", "include"),
]


def read_cmakelists() -> str:
    with open(CMAKELISTS) as f:
        return f.read()


def parse_defines(text: str) -> list[str]:
    """The add_compile_definitions(...) block, in declaration order.

    Lines beginning with # inside the block are cmake comments (the CMakeLists
    has several commented-out defines that must NOT be passed).
    """
    m = re.search(r"add_compile_definitions\(\s*\n(.*?)\n\)", text, re.S)
    if not m:
        sys.exit("could not find add_compile_definitions block")
    defines = []
    for raw in m.group(1).split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        defines.append("-D" + line)
    return defines


def parse_compile_options(text: str) -> list[str]:
    """The first add_compile_options(...) block (the unconditional one)."""
    m = re.search(r"add_compile_options\(\s*\n(.*?)\n\)", text, re.S)
    if not m:
        sys.exit("could not find add_compile_options block")
    return [l.strip() for l in m.group(1).split("\n") if l.strip() and not l.strip().startswith("#")]


def parse_migs(text: str) -> list[dict]:
    """mig() calls with the suffix state that was in effect for each.

    cmake/mig.cmake reads MIG_{USER,SERVER}_SOURCE_SUFFIX / MIG_SERVER_HEADER_SUFFIX
    at call time, and the CMakeLists changes them partway through (UNDReply.defs
    uses the Xcode-style `User.c`/`Server.c`, everything after it uses Darling's
    `_user.c`/`_server.c`). Deduplicated: several definitions are listed twice.
    """
    state = {
        "user": "User.c",
        "server": "Server.c",
        "sheader": "Server.h",
        "header": ".h",
        "xtrace": "XtraceMig.c",
    }
    key_of = {
        "MIG_USER_SOURCE_SUFFIX": "user",
        "MIG_SERVER_SOURCE_SUFFIX": "server",
        "MIG_SERVER_HEADER_SUFFIX": "sheader",
        "MIG_USER_HEADER_SUFFIX": "header",
        "MIG_XTRACE_SUFFIX": "xtrace",
    }
    migs: dict[str, dict] = {}
    for line in text.split("\n"):
        line = line.strip()
        m = re.match(r'set\((MIG_\w+_SUFFIX)\s+"([^"]*)"\)', line)
        if m and m.group(1) in key_of:
            state[key_of[m.group(1)]] = m.group(2)
            continue
        m = re.match(r"mig\(([^)]+)\)", line)
        if m:
            defs = m.group(1).strip()
            # Two of the mig() calls name definitions that do not exist in the
            # vendored xnu (default_pager_{alerts,object}.defs). cmake tolerates
            # that because nothing consumes their output, so the custom command
            # is never run; buck2 resolves sources during analysis, so a target
            # for a missing file fails eagerly. Skip them, and say so.
            if not os.path.exists(os.path.join(REPO, DT, defs)):
                print(f"skipping mig({defs}): no such file (dead edge in cmake too)",
                      file=sys.stderr)
                continue
            if defs not in migs:
                migs[defs] = dict(state, defs=defs)
    return list(migs.values())


def parse_library_sources(text: str) -> list[str]:
    m = re.search(r"add_library\(darlingserver_duct_tape STATIC\s*\n(.*?)\n\)", text, re.S)
    if not m:
        sys.exit("could not find add_library(darlingserver_duct_tape STATIC ...)")
    srcs = []
    for raw in m.group(1).split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        srcs.append(line)
    return srcs


def mig_target_name(defs: str) -> str:
    stem = defs[: -len(".defs")]
    # xnu/osfmk/mach/notify.defs -> mig_mach_notify
    rel = stem[len("xnu/osfmk/") :] if stem.startswith("xnu/osfmk/") else stem
    return "mig_" + rel.replace("/", "_")


def main(argv: list[str]) -> int:
    text = read_cmakelists()
    defines = PARENT_DEFINES + parse_defines(text)
    flags = PARENT_FLAGS + parse_compile_options(text)
    migs = parse_migs(text)
    srcs = parse_library_sources(text)

    # Split the library's sources into hand-written ones and MIG output. The
    # generated ones are attributed back to the definition that produces them, so
    # each mig_gen compiles its own output (which keeps generated artifacts from
    # having to be projected across targets).
    gen_prefix = "${CMAKE_CURRENT_BINARY_DIR}/"
    own_srcs, gen_srcs = [], []
    for s in srcs:
        (gen_srcs if s.startswith(gen_prefix) else own_srcs).append(
            s[len(gen_prefix) :] if s.startswith(gen_prefix) else s
        )

    # pthread/kern_synch.c gets its own -I via set_source_files_properties, so it
    # is compiled as a separate object group and archived into the same .a.
    special = "pthread/kern_synch.c"
    own_srcs = [s for s in own_srcs if s != special]

    compile_map: dict[str, list[str]] = {m["defs"]: [] for m in migs}
    unclaimed = []
    for g in gen_srcs:
        for m in migs:
            stem = m["defs"][: -len(".defs")]
            for suffix_key in ("user", "server"):
                if g == stem + m[suffix_key]:
                    # Paths inside a mig_gen output dir are relative to out_base.
                    compile_map[m["defs"]].append(g[len("xnu/osfmk/") :])
                    break
            else:
                continue
            break
        else:
            unclaimed.append(g)
    if unclaimed:
        sys.exit(f"could not attribute generated sources to any mig(): {unclaimed}")

    out = []
    w = out.append
    w('load("//buck/rules:cc.bzl", "cc_header_root", "cc_objects", "cc_static_lib")')
    w('load("//buck/rules:codegen.bzl", "mig_gen")')
    w("")
    w("# GENERATED by scripts/gen-duct-tape-buck.py from CMakeLists.txt.")
    w("# Regenerate after an upstream bump; do not hand-edit.")
    w("#")
    w("# duct-tape is the kernel-emulation glue that compiles the vendored XNU")
    w("# (osfmk/bsd) into libdarlingserver_duct_tape.a, which the Rust daemon links")
    w("# via DUCT_TAPE_LIB. Host tier: native ELF, no cross toolchain, no Mach-O.")
    w("")
    w("DUCT_TAPE_DEFINES = [")
    for d in defines:
        w(f'    "{d}",')
    w("]")
    w("")
    w("DUCT_TAPE_FLAGS = [")
    for f in flags:
        w(f'    "{f}",')
    w("]")
    w("")
    for name, root in HEADER_ROOTS:
        w("cc_header_root(")
        w(f'    name = "{name}",')
        # .defs are staged alongside .h: MIG definitions #include each other
        # (mach/notify.defs pulls in mach/std_types.defs), so they are part of
        # the header surface as far as the preprocessor is concerned.
        w(f'    headers = glob(["{root}/**/*.h", "{root}/**/*.defs"]),')
        w(f'    root = "{root}",')
        w(")")
        w("")

    w("# One target carrying duct-tape's whole compile environment: the defines,")
    w("# the warning flags, and every include root, in the reference build's order.")
    w("# Everything that compiles duct-tape code depends on just this.")
    w("cc_header_root(")
    w('    name = "dt_env",')
    w("    exported_flags = DUCT_TAPE_DEFINES + DUCT_TAPE_FLAGS,")
    w("    deps = [")
    for name, _ in HEADER_ROOTS:
        w(f'        ":{name}",')
    w('        "//src/libsimple:libsimple_headers",')
    w('        "//src/external/darlingserver:dserver_headers",')
    w('        "//src/external/darlingserver:dserver_rpc",')
    w('        "//src/startup:rtsig_header",')
    w("    ],")
    w('    visibility = ["PUBLIC"],')
    w(")")
    w("")

    w("# MIG: one target per .defs. Each generates into its own output directory")
    w("# (which becomes an include root, so generated headers never merge with the")
    w("# hand-written xnu ones -- mach/notify.h exists as both) and compiles the")
    w("# generated sources the library needs.")
    for m in sorted(migs, key=lambda m: m["defs"]):
        name = mig_target_name(m["defs"])
        w("mig_gen(")
        w(f'    name = "{name}",')
        w(f'    defs = "{m["defs"]}",')
        w('    out_base = "xnu/osfmk",')
        w(f'    user_suffix = "{m["user"]}",')
        w(f'    server_suffix = "{m["server"]}",')
        w(f'    sheader_suffix = "{m["sheader"]}",')
        w(f'    header_suffix = "{m["header"]}",')
        w(f'    xtrace_suffix = "{m["xtrace"]}",')
        srcs_for = sorted(compile_map[m["defs"]])
        if srcs_for:
            w("    compile_srcs = [")
            for s in srcs_for:
                w(f'        "{s}",')
            w("    ],")
        w('    mig_sh = "//buck-src:mig.sh",')
        w('    migcom = "//buck-src:migcom",')
        w('    deps = [":dt_env"],')
        w(")")
        w("")

    w("cc_objects(")
    w('    name = "dt_objects",')
    w("    srcs = [")
    for s in sorted(own_srcs):
        w(f'        "{s}",')
    w("    ],")
    w("    deps = [")
    w('        ":dt_env",')
    for m in sorted(migs, key=lambda m: m["defs"]):
        w(f'        ":{mig_target_name(m["defs"])}",')
    w("    ],")
    w(")")
    w("")
    w("# The generated MIG sources, compiled in ONE target so every mig output root")
    w("# is on the include path: a generated stub reaches hand-written xnu headers")
    w("# that include other definitions' generated headers.")
    w("cc_objects(")
    w('    name = "dt_mig_objects",')
    w("    gen_srcs = [")
    for m in sorted(migs, key=lambda m: m["defs"]):
        if compile_map[m["defs"]]:
            w(f'        ":{mig_target_name(m["defs"])}",')
    w("    ],")
    w("    deps = [")
    w('        ":dt_env",')
    for m in sorted(migs, key=lambda m: m["defs"]):
        w(f'        ":{mig_target_name(m["defs"])}",')
    w("    ],")
    w(")")
    w("")
    w('# set_source_files_properties(pthread/kern_synch.c COMPILE_FLAGS "-I.../pthread")')
    w("cc_objects(")
    w('    name = "dt_pthread_objects",')
    w(f'    srcs = ["{special}"],')
    w('    headers = glob(["pthread/**/*.h"]),')
    w('    include_root = "pthread",')
    w("    deps = [")
    w('        ":dt_env",')
    for m in sorted(migs, key=lambda m: m["defs"]):
        w(f'        ":{mig_target_name(m["defs"])}",')
    w("    ],")
    w(")")
    w("")
    w("cc_static_lib(")
    w('    name = "darlingserver_duct_tape",')
    w('    lib_name = "darlingserver_duct_tape",')
    w("    objs = [")
    w('        ":dt_objects",')
    w('        ":dt_mig_objects",')
    w('        ":dt_pthread_objects",')
    w("    ],")
    w('    exported_headers = glob(["include/**/*.h"]),')
    w('    include_root = "include",')
    w("    deps = [")
    w('        "//src/libsimple:libsimple_darlingserver",')
    w("    ],")
    w('    linker_flags = [')
    w('        "-lpthread",')
    w('        "-ldl",')
    w('        "-lm",')
    w('        "-lrt",')
    w("    ],")
    w('    visibility = ["PUBLIC"],')
    w(")")
    w("")

    content = "\n".join(out)
    if "--stdout" in argv:
        print(content)
    else:
        with open(OUT, "w") as f:
            f.write(content)
        print(f"wrote {OUT}: {len(migs)} mig targets, {len(own_srcs)} sources, "
              f"{len(defines)} defines, {sum(len(v) for v in compile_map.values())} generated sources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
