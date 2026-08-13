# Codegen rules: bison/flex, MIG, and "run a host tool that writes a file".
#
# Everything here follows one idiom: a fixed runner script is emitted with
# `ctx.actions.write` (its text is a constant in this file, so there is no
# checked-in helper to keep in sync) and invoked with `bash`. That buys the two
# things `ctx.actions.run` cannot express on its own -- creating an output's
# parent directory, and shell redirection -- without hiding the real command,
# which stays visible in `buck2 log what-ran`.

load("//buck/rules:inproc.bzl", "InProcInfo")

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
        # `include/ciderd/rpc.h` is reachable as <ciderd/rpc.h>.
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
        # `include/ciderd/rpc.h` is reachable as <ciderd/rpc.h>.
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
arch="$7"; target="$8"; defs="$9"; links="${10}"; shift 10
mkdir -p "$outdir/$subdir"
# Alias links INSIDE the output dir, mirroring the cmake create_symlink() calls that
# put a generated header under a second name. libsecurityd is the case that needs it:
# consumers include <securityd_client/ucsp.h> while mig writes plain ucsp.h, and cmake
# bridges the two with mig/securityd_client/ucsp.h -> ../ucsp.h. The link is made BEFORE
# mig runs, which is fine: nothing reads it until the header exists.
if [ -n "$links" ]; then
  while IFS=$'\\t' read -r dest src; do
    [ -n "$dest" ] || continue
    mkdir -p "$outdir/$(dirname "$dest")"
    ln -sfn "$src" "$outdir/$dest"
  done <<< "$links"
fi
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
        "\n".join(["%s\t%s" % (d, s) for d, s in ctx.attrs.alias_links.items()]),
    ])
    # mig runs the C preprocessor over the .defs, so it needs the SAME defines
    # and include roots as the compiles that consume its output. cmake achieves
    # this by scraping the directory's COMPILE_DEFINITIONS / INCLUDE_DIRECTORIES;
    # here it falls out of depending on the same targets.
    cmd.add(merged.exported_flags)
    for inc in merged.include_dirs:
        cmd.add(cmd_args(inc, format = "-I{}"))
    for extra in ctx.attrs.extra_defs:
        cmd.add(cmd_args(extra, parent = 1, format = "-I{}"))
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

    # The xtrace stub is exported through a SUBTARGET rather than alongside the
    # rest: each protocol's <stem>XtraceMig.c is compiled into its own little
    # dylib that xtrace loads at runtime, and adding it to compile_srcs would also
    # hand it to the protocol's real consumer, which must not have it.
    xtrace_srcs = [outdir.project(s) for s in ctx.attrs.xtrace_srcs]

    # The SERVER stub is a subtarget for the same reason, one level up: a protocol's two
    # ends are usually two different targets. tokend is the case -- SecurityTokend
    # implements the server and links tokendServer.cpp, while libsecurity_tokend_client
    # is the caller and must link only tokendClient.cpp. Putting both in compile_srcs
    # gives each end the other's stub and duplicate symbols follow.
    server_srcs = [outdir.project(s) for s in ctx.attrs.server_srcs]

    # And a third: the ALIASES. alias_links already gives a generated file a second name in
    # the output dir, mirroring cmake's create_symlink; this exports those names as sources.
    # ucsp is the case -- libsecurityd_client compiles mig/ucspClient.cpp as C++ while
    # libsecurityd_ucspc compiles mig/ucspClientC.c, which IS ucspClient.cpp under a name
    # that makes the compiler treat it as C. Same translation unit, two consumers, two
    # languages, so neither can take the other's spelling.
    alias_srcs = [outdir.project(s) for s in ctx.attrs.alias_srcs]

    return [
        DefaultInfo(default_output = outdir, sub_targets = {
            "xtrace": [
                DefaultInfo(default_outputs = xtrace_srcs),
                GeneratedSourcesInfo(sources = xtrace_srcs, headers = []),
                CcLibInfo(
                    include_dirs = merged.include_dirs + [outdir],
                    exported_flags = merged.exported_flags,
                    static_libs = [],
                    linker_flags = [],
                ),
            ],
            "server": [
                DefaultInfo(default_outputs = server_srcs),
                GeneratedSourcesInfo(sources = server_srcs, headers = []),
                CcLibInfo(
                    include_dirs = merged.include_dirs + [outdir],
                    exported_flags = merged.exported_flags,
                    static_libs = [],
                    linker_flags = [],
                ),
            ],
            "alias": [
                DefaultInfo(default_outputs = alias_srcs),
                GeneratedSourcesInfo(sources = alias_srcs, headers = []),
                CcLibInfo(
                    include_dirs = merged.include_dirs + [outdir],
                    exported_flags = merged.exported_flags,
                    static_libs = [],
                    linker_flags = [],
                ),
            ],
        }),
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
        # Extra names for generated files, as {link path: link target}, both relative to
        # the output dir. A port of cmake's create_symlink() in the same directory.
        "alias_links": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # Which of those alias_links are exported as SOURCES, through [alias] (see above).
        "alias_srcs": attrs.list(attrs.string(), default = []),
        "arch": attrs.string(default = "x86_64"),
        "compiler_flags": attrs.list(attrs.string(), default = []),
        # Generated files (relative to the output dir) exported as sources, for
        # a consumer to compile via cc_objects(gen_srcs = ...).
        "compile_srcs": attrs.list(attrs.string(), default = []),
        "defs": attrs.source(),
        "deps": attrs.list(attrs.dep(), default = []),
        # Definitions the main defs #includes. mig resolves those through the C
        # preprocessor, so each one's directory is added to the include path --
        # and declaring them here is what makes buck2 rebuild when they change.
        "extra_defs": attrs.list(attrs.source(), default = []),
        "header_suffix": attrs.string(default = ".h"),
        "mig_flags": attrs.list(attrs.string(), default = []),
        "mig_sh": attrs.source(),
        "migcom": attrs.dep(providers = [RunInfo]),
        # Output paths are relative to this package-relative dir, mirroring
        # cmake's CMAKE_CURRENT_BINARY_DIR layout.
        "out_base": attrs.string(default = ""),
        # Generated files exported through the [server] subtarget (see above).
        "server_srcs": attrs.list(attrs.string(), default = []),
        "server_suffix": attrs.string(default = "Server.c"),
        "sheader_suffix": attrs.string(default = "Server.h"),
        "target": attrs.string(default = "x86_64-apple-darwin20"),
        "user_suffix": attrs.string(default = "User.c"),
        # Generated files exported through the [xtrace] subtarget (see above).
        "xtrace_srcs": attrs.list(attrs.string(), default = []),
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
        # `include/ciderd/rpc.h` is reachable as <ciderd/rpc.h>.
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
        # `include/ciderd/rpc.h` is reachable as <ciderd/rpc.h>.
        "header_root": attrs.string(default = ""),
        "outs": attrs.list(attrs.string()),
        "script": attrs.source(),
        # Extra inputs the script reads (data files, imported modules).
        "srcs": attrs.list(attrs.source(), default = []),
    },
)

# ---------------------------------------------------------------------------
# configure_file: cmake's configure_file, for headers generated by substitution.
#
# darling-config.h is the case that needs it: src/darwin/include/darling-config.h.in
# carries ${CMAKE_INSTALL_PREFIX}-style and @VAR@-style placeholders plus
# #cmakedefine lines, and the syscall emulation layer includes the result.
# ---------------------------------------------------------------------------

_CONFIGURE_RUNNER = """import json, sys

src, dst = sys.argv[1], sys.argv[2]
values = json.load(open(sys.argv[3]))

FALSEY = ("", "0", "OFF", "FALSE", "NO")
out = []
for line in open(src):
    stripped = line.lstrip()
    if stripped.startswith("#cmakedefine"):
        rest = stripped[len("#cmakedefine"):].strip()
        name = rest.split()[0] if rest else ""
        tail = rest[len(name):]
        # cmake emits the #define only when the variable is set to something true.
        if values.get(name, "") not in FALSEY:
            out.append("#define " + name + tail + chr(10))
        else:
            out.append("/* #undef " + name + " */" + chr(10))
        continue
    for k, v in values.items():
        line = line.replace("${" + k + "}", v).replace("@" + k + "@", v)
    out.append(line)
open(dst, "w").write("".join(out))
"""

def _configure_file_impl(ctx):
    runner = ctx.actions.write(ctx.label.name + "__configure.py", _CONFIGURE_RUNNER)
    out = ctx.actions.declare_output(ctx.attrs.out)

    # The values travel in a FILE, not as KEY=VALUE arguments, and that is not cosmetic.
    # aquery renders an action's command by joining its argv with ", ", and
    # src/linux/buildtools/graph-specs/src/dump.rs has to split that back apart, which is only sound while no
    # argument contains the separator. perl's versions.h breaks it: VERSIONS is the C
    # initializer ` "5.18", "5.28",`, so the one argument came back as two and the Nix
    # lowering died on
    #   ValueError: dictionary update sequence element #5 has length 1; 2 is required
    # while the host, which never round-trips through that rendering, was fine. Passing a
    # file removes the ambiguity at the source rather than teaching the dumper to guess.
    values = ctx.actions.write_json(ctx.label.name + "__values.json", ctx.attrs.values)
    cmd = cmd_args(["python3", runner, ctx.attrs.src, out.as_output(), values])
    ctx.actions.run(cmd, category = "configure_file", identifier = ctx.attrs.out)
    return _codegen_providers(ctx, [out], [], [out])

configure_file = rule(
    impl = _configure_file_impl,
    attrs = {
        "header_root": attrs.string(default = ""),
        "out": attrs.string(),
        "src": attrs.source(),
        "values": attrs.dict(attrs.string(), attrs.string(), default = {}),
    },
)

# ---------------------------------------------------------------------------
# stdout_gen: a generated file that is a tool's STDOUT.
#
# host_gen passes the output as the last argument and script_gen passes it as argv, which
# covers cmake's own generators; a plain shell redirect covers the rest. ICU's data file is
# the case that needs it -- the reference unpacks it with `xz -d -k -c <src> > icudt66l.dat`
# -- and the prefix cannot be laid out without it.
#
# The tool comes from PATH deliberately. The reference hardcodes the store path of the xz it
# was configured with, which is exactly the kind of machine-specific value the port keeps out
# of its rules; PATH is what both consumers already control (the dev shell here, the
# derivation's nativeBuildInputs in the Nix endpoint).
# ---------------------------------------------------------------------------

_STDOUT_GEN_RUNNER = '''set -euo pipefail
out="$1"; shift
mkdir -p "$(dirname "$out")"
exec "$@" > "$out"
'''

def _stdout_gen_impl(ctx):
    runner = ctx.actions.write(ctx.label.name + "__run.sh", _STDOUT_GEN_RUNNER, is_executable = True)
    out = ctx.actions.declare_output(ctx.attrs.out)
    cmd = cmd_args(["bash", runner, out.as_output(), ctx.attrs.tool])
    cmd.add(ctx.attrs.args)
    cmd.add(ctx.attrs.srcs)
    ctx.actions.run(cmd, category = "stdout_gen", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out), InProcInfo(artifacts = [runner])]

stdout_gen = rule(
    impl = _stdout_gen_impl,
    attrs = {
        # Arguments before the sources, since a tool's flags come first.
        "args": attrs.list(attrs.string(), default = []),
        "out": attrs.string(),
        # Input files, appended last and materialized for the action.
        "srcs": attrs.list(attrs.source(), default = []),
        "tool": attrs.string(),
    },
)

# ---- preprocess_gen: run the C preprocessor over a file ----

def _preprocess_gen_impl(ctx):
    """cmake's `clang -E -P` custom commands, as a rule.

    Security builds its exported-symbols list this way: Security.exp-in is a header that
    #includes CSSMOID.exp-in and expands, under the target's own defines, into the list of
    symbols the framework exports. The list is not cosmetic -- an -exported_symbols_list
    FORCES those symbols, which is what pulls libsecurity_ssl's members into the link.
    Without it the archive contributes nothing and every consumer of SSLRead is undefined.
    """
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    merged = merge_dep_libs(ctx.attrs.deps)
    out = ctx.actions.declare_output(ctx.attrs.out)
    cmd = cmd_args([tc.cc, "-E", "-Xpreprocessor", "-P"])
    if ctx.attrs.language:
        cmd.add(["-x", ctx.attrs.language])
    cmd.add(["-target", ctx.attrs.target])
    cmd.add(merged.exported_flags)
    for inc in merged.include_dirs:
        cmd.add(cmd_args(inc, format = "-I{}"))
    cmd.add(ctx.attrs.flags)
    # The includes it pulls in are declared, not discovered: buck2 has to know them to
    # rebuild when they change.
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    cmd.add([ctx.attrs.src, "-o", out.as_output()])
    ctx.actions.run(cmd, category = "preprocess", identifier = ctx.attrs.out)
    return [DefaultInfo(default_output = out)]

preprocess_gen = rule(
    impl = _preprocess_gen_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "flags": attrs.list(attrs.string(), default = []),
        # -x <language>; cmake passes objective-c so ObjC-only sections expand.
        "language": attrs.string(default = ""),
        "out": attrs.string(),
        "src": attrs.source(),
        # Files the input #includes.
        "srcs": attrs.list(attrs.source(), default = []),
        "target": attrs.string(default = "x86_64-apple-darwin20"),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:darwin_cc"),
    },
)

# ---------------------------------------------------------------------------
# elf_wrapper: cmake's wrap_elf(), the guest-side bridge to a HOST ELF library.
#
# Darling reaches host libraries (fuse, X11, the ffmpeg family) through
# libelfloader. The guest side of that bridge is a generated stub dylib per host
# library: wrapgen reads the ELF's dynamic symbol table and emits a C file whose
# every export forwards through libelfloader. This rule is only the CODEGEN half;
# the caller builds the result with darwin_dylib, because the install_name,
# siblings and reexports are the dylib rule's business, not this one's.
#
# The awkward part is that wrapgen dlopen()s the real .so AT BUILD TIME, so the
# library has to be findable by the loader. Passing a bare SONAME (which is what
# the reference does: wrap_elf(fuse libfuse.so)) fails unless its directory is on
# LD_LIBRARY_PATH -- the dev shell contains fuse but does not put it there. The
# directories come from [cider] elf_lib_dirs in .buckconfig.local, written by
# scripts/buck-setup.nu from pkg-config, the same way ld64_dir and
# clang_resource_dir are supplied.
#
# That makes this the one rule in the port whose OUTPUT depends on a file outside
# the build graph. It is unavoidable: the stub's whole purpose is to mirror
# whatever the host actually provides. Worth knowing when a wrapper's contents
# differ between machines.
# ---------------------------------------------------------------------------

_ELF_WRAPPER_RUNNER = '''set -euo pipefail
wrapgen="$1"; soname="$2"; out_c="$3"; out_h="$4"; libdirs="$5"
export LD_LIBRARY_PATH="$libdirs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$wrapgen" "$soname" "$out_c" "$out_h"
# wrapgen writes the vars header ONLY when the library exports data symbols, and
# most do not (fuse does not). Buck2 requires every declared output to exist, so
# an empty one stands in rather than making the header conditional at the rule
# level, where a consumer would have to know which case it is in.
[ -f "$out_h" ] || : > "$out_h"
'''

def _elf_wrapper_impl(ctx):
    runner = ctx.actions.write(ctx.label.name + "__wrap.sh", _ELF_WRAPPER_RUNNER, is_executable = True)
    out_c = ctx.actions.declare_output(ctx.attrs.name_base + ".c")
    out_h = ctx.actions.declare_output(ctx.attrs.name_base + "_vars.h")
    ctx.actions.run(
        cmd_args([
            "bash",
            runner,
            ctx.attrs.wrapgen[RunInfo],
            ctx.attrs.soname,
            out_c.as_output(),
            out_h.as_output(),
            ctx.attrs.lib_dirs,
        ]),
        category = "elf_wrapper",
        identifier = ctx.attrs.name_base,
        # The host .so is not a build input, so buck2 cannot know when it changes.
        local_only = True,
    )
    return _codegen_providers(ctx, [out_c, out_h], [out_c], [out_h])

elf_wrapper = rule(
    impl = _elf_wrapper_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "header_root": attrs.string(default = ""),
        # Directories to put on LD_LIBRARY_PATH so the SONAME resolves.
        "lib_dirs": attrs.string(default = ""),
        # Stem of the generated files: <base>.c and <base>_vars.h.
        "name_base": attrs.string(),
        # The host library as the loader knows it, e.g. "libfuse.so".
        "soname": attrs.string(),
        "wrapgen": attrs.dep(providers = [RunInfo]),
    },
)

# ---------------------------------------------------------------------------
# forwarded_headers: one-line #include shims, namespaced under a directory.
# ---------------------------------------------------------------------------

# JavaScriptCore is the only target in the graph that needs this. Its cmake
# defines setup_forwarded_headers(), which writes `#include <API/JSContext.h>`
# into build/public/JavaScriptCore/JSContext.h so that a source can say
# <JavaScriptCore/JSContext.h> without a framework ever being assembled -- a
# framework header namespace made of text files instead of symlinks. cmake does
# it at CONFIGURE time, which has no counterpart here, so it becomes a rule.
#
# The header list is read from the cmake file itself rather than transcribed
# into the BUCK file: there are 624 of them across the two lists, and a
# transcription would be one more thing to keep in sync with the pin.
#
# 17 of the private entries name a path that does not exist (DerivedSources/
# without its JavaScriptCore/ level, and a handful of headers deleted upstream).
# The reference writes those shims too, and they are equally broken there; a
# shim only has to resolve if something includes it, and nothing includes these.
_FORWARDED_HEADERS_PY = '''
import os, re, sys

out, subdir, cmakelists = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(cmakelists).read()
# A cmake comment runs to end of line; without stripping them first, `.split()`
# would turn every word of a comment into a header name.
text = re.sub(r"#[^\\n]*", "", text)
dest = os.path.join(out, subdir)
os.makedirs(dest, exist_ok=True)
for name in sys.argv[4:]:
    m = re.search(r"set\\s*\\(\\s*" + re.escape(name) + r"\\b([^)]*)\\)", text)
    if not m:
        sys.exit("forwarded_headers: no cmake list named " + name)
    for item in m.group(1).split():
        with open(os.path.join(dest, os.path.basename(item)), "w") as fh:
            fh.write("// generated by forwarded_headers; edit the cmake list instead\\n")
            fh.write("#include <%s>\\n" % item)
'''

def _forwarded_headers_impl(ctx):
    script = ctx.actions.write(ctx.label.name + "__forward.py", _FORWARDED_HEADERS_PY)
    out = ctx.actions.declare_output(ctx.label.name + "__include", dir = True)
    cmd = cmd_args([
        "python3",
        script,
        out.as_output(),
        ctx.attrs.subdir,
        ctx.attrs.cmake_lists,
    ])
    cmd.add(ctx.attrs.lists)
    ctx.actions.run(cmd, category = "forwarded_headers", identifier = ctx.label.name)
    return [
        DefaultInfo(default_output = out),
        CcLibInfo(
            include_dirs = [out],
            exported_flags = [],
            static_libs = [],
            linker_flags = [],
        ),
    ]

forwarded_headers = rule(
    impl = _forwarded_headers_impl,
    attrs = {
        # The cmake file the lists are read from.
        "cmake_lists": attrs.source(),
        # Names of the `set(...)` lists in it holding the header paths.
        "lists": attrs.list(attrs.string()),
        # Directory the shims are written under, i.e. the namespace a consumer
        # includes them through.
        "subdir": attrs.string(),
    },
)
