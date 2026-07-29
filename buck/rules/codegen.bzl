# Codegen rules: bison/flex, MIG, and "run a host tool that writes a file".
#
# Everything here follows one idiom: a fixed runner script is emitted with
# `ctx.actions.write` (its text is a constant in this file, so there is no
# checked-in helper to keep in sync) and invoked with `bash`. That buys the two
# things `ctx.actions.run` cannot express on its own -- creating an output's
# parent directory, and shell redirection -- without hiding the real command,
# which stays visible in `buck2 log what-ran`.

load(
    ":cc.bzl",
    "CcLibInfo",
    "CcObjectsInfo",
    "GeneratedSourcesInfo",
    "compile_objects",
    "merge_dep_libs",
    "stage_include_root",
)
load("@toolchains//:cc.bzl", "CcToolchainInfo")

# ---------------------------------------------------------------------------
# bison / flex
# ---------------------------------------------------------------------------

def _codegen_providers(ctx, outs, sources, headers):
    """Providers every codegen rule returns.

    Generated headers are staged into an include root, so a consumer gets them
    the same way it gets any other declared header: by depending on this target.
    That matters for bison in particular -- cmake gets away with `#include
    "parser.h"` from the generated lexer because both land in the same binary
    dir, which is not true when each action has its own output dir.
    """
    include_dirs = []
    if headers:
        include_dirs.append(stage_include_root(
            ctx,
            ctx.label.name + "__gen_include",
            ctx.attrs.header_root,
            headers,
        ))
    return [
        DefaultInfo(default_outputs = outs),
        GeneratedSourcesInfo(sources = sources, headers = headers),
        CcLibInfo(
            include_dirs = include_dirs,
            exported_flags = [],
            static_libs = [],
            linker_flags = [],
        ),
    ]

def _bison_gen_impl(ctx):
    src = ctx.attrs.src
    out_c = ctx.actions.declare_output(ctx.attrs.out_c)
    out_h = ctx.actions.declare_output(ctx.attrs.out_h)
    ctx.actions.run(
        cmd_args([
            ctx.attrs.bison,
            # `--defines=<path>` rather than plain `-d`, so the header is a
            # declared output at a path buck2 chose (and thus bound to this
            # action) instead of appearing next to the parser by convention.
            cmd_args(out_h.as_output(), format = "--defines={}"),
            "-o",
            out_c.as_output(),
            src,
        ]),
        category = "bison",
        identifier = src.short_path,
    )
    return _codegen_providers(ctx, [out_c, out_h], [out_c], [out_h])

def _flex_gen_impl(ctx):
    src = ctx.attrs.src
    out_c = ctx.actions.declare_output(ctx.attrs.out_c)
    ctx.actions.run(
        cmd_args([ctx.attrs.flex, "-o", out_c.as_output(), src]),
        category = "flex",
        identifier = src.short_path,
    )
    return _codegen_providers(ctx, [out_c], [out_c], [])

bison_gen = rule(
    impl = _bison_gen_impl,
    attrs = {
        "bison": attrs.string(default = "bison"),
        # Prefix stripped from generated header paths when staging them, so
        # `include/darlingserver/rpc.h` is reachable as <darlingserver/rpc.h>.
        "header_root": attrs.string(default = ""),
        # `--defines=` needs the header's path as buck2 will place it, so both
        # output names are spelled out rather than derived.
        "out_c": attrs.string(),
        "out_h": attrs.string(),
        "src": attrs.source(),
    },
)

flex_gen = rule(
    impl = _flex_gen_impl,
    attrs = {
        "flex": attrs.string(default = "flex"),
        # Prefix stripped from generated header paths when staging them, so
        # `include/darlingserver/rpc.h` is reachable as <darlingserver/rpc.h>.
        "header_root": attrs.string(default = ""),
        "out_c": attrs.string(),
        "src": attrs.source(),
    },
)

# ---------------------------------------------------------------------------
# MIG (Mach Interface Generator)
# ---------------------------------------------------------------------------

# Runs Darling's own mig.sh (the bootstrap_cmds fork) exactly the way
# cmake/mig.cmake does, so the generated code cannot diverge from the reference
# build. mig.sh is invoked through `bash` rather than executed, because its
# `#!/bin/bash` shebang does not resolve on NixOS.
#
# $1 outdir  $2 subdir-inside-outdir  $3 mig.sh  $4 stem  $5 migcom  $6 cc
# $7 arch    $8 target-triplet        $9 defs    ${10}+ cpp flags
_MIG_RUNNER = '''set -euo pipefail
outdir="$1"; subdir="$2"; migsh="$3"; stem="$4"; migcom="$5"; cc="$6"
arch="$7"; target="$8"; defs="$9"; shift 9
mkdir -p "$outdir/$subdir"
# The xtrace output is passed (and pre-created) for the same reason cmake
# touches it: mig only writes it for definitions that produce one, and a
# missing file would look like a failed action.
: > "$outdir/${stem}@XTRACE@"
exec bash "$migsh" \\
  -arch "$arch" -target "$target" -cc "$cc" -migcom "$migcom" \\
  -user "$outdir/${stem}@USER@" \\
  -header "$outdir/${stem}@HEADER@" \\
  -server "$outdir/${stem}@SERVER@" \\
  -sheader "$outdir/${stem}@SHEADER@" \\
  -xtracemig "$outdir/${stem}@XTRACE@" \\
  "$@" "$defs"
'''

def _mig_stem(defs, base):
    """`xnu/osfmk/mach/notify.defs` with base `xnu/osfmk` -> `mach/notify`."""
    rel = defs.short_path
    prefix = base + "/" if base else ""
    if prefix and rel.startswith(prefix):
        rel = rel[len(prefix):]
    if not rel.endswith(".defs"):
        fail("mig source must be a .defs file: " + defs.short_path)
    return rel[:-len(".defs")]

def _mig_gen_impl(ctx):
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    merged = merge_dep_libs(ctx.attrs.deps)

    stem = _mig_stem(ctx.attrs.defs, ctx.attrs.out_base)
    subdir = stem.rsplit("/", 1)[0] if "/" in stem else "."

    runner = ctx.actions.write(
        ctx.label.name + "__mig.sh",
        _MIG_RUNNER
            .replace("@USER@", ctx.attrs.user_suffix)
            .replace("@HEADER@", ctx.attrs.header_suffix)
            .replace("@SERVER@", ctx.attrs.server_suffix)
            .replace("@SHEADER@", ctx.attrs.sheader_suffix)
            .replace("@XTRACE@", ctx.attrs.xtrace_suffix),
        is_executable = True,
    )

    # One directory output, not five file outputs: which of the five files mig
    # actually writes depends on the definition, and a directory lets the ones
    # that do not appear simply be absent instead of failing the action.
    outdir = ctx.actions.declare_output(ctx.label.name + "__gen", dir = True)

    cmd = cmd_args([
        "bash",
        runner,
        outdir.as_output(),
        subdir,
        ctx.attrs.mig_sh,
        stem,
        ctx.attrs.migcom[RunInfo],
        tc.cc,
        ctx.attrs.arch,
        ctx.attrs.target,
        ctx.attrs.defs,
    ])
    # mig runs the C preprocessor over the .defs, so it needs the SAME defines
    # and include roots as the compiles that consume its output. cmake achieves
    # this by scraping the directory's COMPILE_DEFINITIONS / INCLUDE_DIRECTORIES;
    # here it falls out of depending on the same targets.
    cmd.add(merged.exported_flags)
    for inc in merged.include_dirs:
        cmd.add(cmd_args(inc, format = "-I{}"))
    cmd.add(ctx.attrs.mig_flags)
    ctx.actions.run(cmd, category = "mig", identifier = stem)

    # Generated sources are EXPORTED, not compiled here. They have to be
    # compiled by a target that can see every mig output at once: a generated
    # server stub includes hand-written xnu headers which in turn include OTHER
    # definitions' generated headers (mach/restartable_server.c reaches
    # kern/restartable.h, which needs the generated mach/task.h). The cmake build
    # gets that for free by dumping all mig output into one binary dir; here the
    # consumer collects the roots through its gen_srcs deps.
    exported_srcs = [outdir.project(s) for s in ctx.attrs.compile_srcs]

    return [
        DefaultInfo(default_output = outdir),
        GeneratedSourcesInfo(sources = exported_srcs, headers = []),
        # The generated dir is an include root for consumers, and it comes
        # BEFORE nothing: it is appended after the dep roots, so a hand-written
        # source header of the same name (xnu's mach/notify.h) keeps winning,
        # which is what the cmake include order does too.
        CcLibInfo(
            include_dirs = merged.include_dirs + [outdir],
            exported_flags = merged.exported_flags,
            static_libs = merged.static_libs,
            linker_flags = merged.linker_flags,
        ),
    ]

mig_gen = rule(
    impl = _mig_gen_impl,
    attrs = {
        "arch": attrs.string(default = "x86_64"),
        "compiler_flags": attrs.list(attrs.string(), default = []),
        # Generated files (relative to the output dir) exported as sources, for
        # a consumer to compile via cc_objects(gen_srcs = ...).
        "compile_srcs": attrs.list(attrs.string(), default = []),
        "defs": attrs.source(),
        "deps": attrs.list(attrs.dep(), default = []),
        "header_suffix": attrs.string(default = ".h"),
        "mig_flags": attrs.list(attrs.string(), default = []),
        "mig_sh": attrs.source(),
        "migcom": attrs.dep(providers = [RunInfo]),
        # Output paths are relative to this package-relative dir, mirroring
        # cmake's CMAKE_CURRENT_BINARY_DIR layout.
        "out_base": attrs.string(default = ""),
        "server_suffix": attrs.string(default = "Server.c"),
        "sheader_suffix": attrs.string(default = "Server.h"),
        "target": attrs.string(default = "x86_64-apple-darwin20"),
        "user_suffix": attrs.string(default = "User.c"),
        "xtrace_suffix": attrs.string(default = "XtraceMig.c"),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
    },
)

# ---------------------------------------------------------------------------
# host_gen: build-host probe -- run a binary we just built, it writes a file.
# ---------------------------------------------------------------------------

_HOST_GEN_RUNNER = '''set -euo pipefail
out="$1"; shift
mkdir -p "$(dirname "$out")"
exec "$@" "$out"
'''

def _host_gen_impl(ctx):
    runner = ctx.actions.write(ctx.label.name + "__run.sh", _HOST_GEN_RUNNER, is_executable = True)
    out = ctx.actions.declare_output(ctx.attrs.out)
    cmd = cmd_args(["bash", runner, out.as_output(), ctx.attrs.tool[RunInfo]])
    cmd.add(ctx.attrs.args)
    ctx.actions.run(cmd, category = "host_gen", identifier = ctx.attrs.out)
    return _codegen_providers(ctx, [out], [], [out])

host_gen = rule(
    impl = _host_gen_impl,
    attrs = {
        "args": attrs.list(attrs.string(), default = []),
        "out": attrs.string(),
        # Prefix stripped from generated header paths when staging them, so
        # `include/darlingserver/rpc.h` is reachable as <darlingserver/rpc.h>.
        "header_root": attrs.string(default = ""),
        "tool": attrs.dep(providers = [RunInfo]),
    },
)

# ---------------------------------------------------------------------------
# script_gen: run a checked-in script (python, shell) that writes N files.
# ---------------------------------------------------------------------------

_SCRIPT_GEN_RUNNER = '''set -euo pipefail
interp="$1"; script="$2"; shift 2
for out in "$@"; do
  case "$out" in --*) continue;; esac
  mkdir -p "$(dirname "$out")"
done
exec "$interp" "$script" "$@"
'''

def _script_gen_impl(ctx):
    runner = ctx.actions.write(ctx.label.name + "__run.sh", _SCRIPT_GEN_RUNNER, is_executable = True)
    outs = [ctx.actions.declare_output(o) for o in ctx.attrs.outs]
    cmd = cmd_args(["bash", runner, ctx.attrs.interpreter, ctx.attrs.script])
    for o in outs:
        cmd.add(o.as_output())
    cmd.add(ctx.attrs.args)
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    ctx.actions.run(cmd, category = "script_gen", identifier = ctx.label.name)

    headers = []
    sources = []
    for i in range(len(outs)):
        if ctx.attrs.outs[i].endswith(".c") or ctx.attrs.outs[i].endswith(".cpp"):
            sources.append(outs[i])
        else:
            headers.append(outs[i])
    return _codegen_providers(ctx, outs, sources, headers)

script_gen = rule(
    impl = _script_gen_impl,
    attrs = {
        # Trailing arguments after the declared outputs (the generators here take
        # their outputs as positional argv, cmake-style).
        "args": attrs.list(attrs.string(), default = []),
        "interpreter": attrs.string(default = "python3"),
        # Prefix stripped from generated header paths when staging them, so
        # `include/darlingserver/rpc.h` is reachable as <darlingserver/rpc.h>.
        "header_root": attrs.string(default = ""),
        "outs": attrs.list(attrs.string()),
        "script": attrs.source(),
        # Extra inputs the script reads (data files, imported modules).
        "srcs": attrs.list(attrs.source(), default = []),
    },
)
