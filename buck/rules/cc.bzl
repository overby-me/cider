# Darling's own C/C++ rules (no prelude). See plan/buck2-port.md.
#
# Design decisions worth knowing before editing:
#
# 1. ONE ACTION PER SOURCE FILE. The whole point of the port is a fast edit ->
#    rebuild loop, which needs per-object granularity. (Upstream's `no_prelude`
#    example compiles a whole target in one clang call; that would be a
#    regression from ninja.)
#
# 2. HEADERS ARE STAGED, NEVER GLOBBED ONTO -I. Each include root becomes a
#    `symlinked_dir` action holding exactly the declared headers, and consumers
#    get `-I<that staged dir>`. This is what kills nix-ninja's wall #1 (a source
#    `endian.h` on a broad `-I` path shadowing the SDK's system header): a
#    compile can only see headers someone declared for it. It also keeps every
#    include root SEPARATE, so overlapping roots (xnu, xnu/osfmk) resolve the way
#    the cmake build resolves them, instead of being merged into one flat dir.
#
# 3. Rules compose as objects -> archive, so a single archive can contain object
#    groups compiled with different flags (xnu-sys's pthread/kern_synch.c needs
#    its own -I but must land in libciderd_xnu_sys.a).

load("@toolchains//:cc.bzl", "CcToolchainInfo")

# What a C target hands to its consumers.
load("//buck/rules:inproc.bzl", "InProcInfo")

# x86-GUEST-ONLY COMPILE FLAGS, DROPPED FOR AN ARM64 GUEST (aarch64 port, task A4). The generated
# BUCK files carry the reference build's -msse* (and the -Dmovsxw shim libm's SSE inline asm
# needs); clang refuses them under -target arm64-apple-darwin20. -D_DARWIN_NO_64_BIT_INODE joins
# them for the same reason: arm64 never shipped a 32-bit-inode ABI, so __DARWIN_ONLY_64_BIT_INO_T
# is 1 and defining it is a hard #error in sys/cdefs.h; the frameworks that pass it (IOKit and the
# other vendor/src framework groups) just want the ordinary 64-bit stat, which is the only stat on
# arm64. (libc handles its own noinode64 *variant* targets by compiling nothing on arm64 instead;
# see vendor/src/libc/BUCK.) Rather than gate each of the 40-odd sites by hand, one filter over
# every compile drops them when the guest arch is arm64. On x86 the filter is inert, so the argv is
# byte-identical to before.
_M_GUEST_ARM = read_root_config("cider", "guest_arch", "x86_64") == "arm64"
_X86_ONLY_FLAG_PREFIXES = ["-msse", "-mmmx", "-mavx", "-mfpmath", "-Dmovsxw", "-D_DARWIN_NO_64_BIT_INODE"]

def _drop_x86_flags(flags):
    if not _M_GUEST_ARM:
        return flags
    kept = []
    for f in flags:
        # Only plain string flags can be filtered; anything else (cmd_args, artifacts) passes
        # through untouched. A flag is dropped when it starts with an x86-only prefix.
        if type(f) == type("") and [p for p in _X86_ONLY_FLAG_PREFIXES if f.startswith(p)]:
            continue
        kept.append(f)
    return kept

CcLibInfo = provider(fields = [
    # list[artifact]: staged include roots, passed as -I in order.
    "include_dirs",
    # list[str]: preprocessor/compile flags consumers inherit (-D, -f...).
    "exported_flags",
    # list[artifact]: static archives to put on a link line, dep order.
    "static_libs",
    # list[str]: flags a consumer's link needs (-lpthread, ...).
    "linker_flags",
])

# Object files, so an archive can be assembled from several compile groups.
CcObjectsInfo = provider(fields = ["objects"])

# What a codegen target produces: generated .c files a consumer must COMPILE
# (`gen_srcs`), separate from generated headers, which a consumer sees through
# the codegen target's CcLibInfo include root like any other dependency. Lives
# here rather than in codegen.bzl so cc.bzl needs no import from it.
GeneratedSourcesInfo = provider(fields = ["sources", "headers"])

# Every extension clang treats as C++. `.cp` is in the list because the reference compiles
# libsecurity_keychain/lib/CCallbackMgr.cp with CXX_COMPILER and -std=gnu++14; without it
# here the same file would be handed to the C driver and fail on the first `class`.
_CXX_EXTS = [".cpp", ".cc", ".cxx", ".cp", ".c++", ".C"]

def _is_cxx(src):
    for ext in _CXX_EXTS:
        if src.short_path.endswith(ext):
            return True
    return False

def merge_dep_libs(deps):
    """Transitively collect CcLibInfo from deps, preserving order, deduped."""
    include_dirs = []
    exported_flags = []
    static_libs = []
    linker_flags = []
    for dep in deps:
        info = dep[CcLibInfo]
        for d in info.include_dirs:
            if d not in include_dirs:
                include_dirs.append(d)
        for f in info.exported_flags:
            if f not in exported_flags:
                exported_flags.append(f)
        for l in info.static_libs:
            if l not in static_libs:
                static_libs.append(l)
        for f in info.linker_flags:
            if f not in linker_flags:
                linker_flags.append(f)
    return struct(
        include_dirs = include_dirs,
        exported_flags = exported_flags,
        static_libs = static_libs,
        linker_flags = linker_flags,
    )

def stage_include_root(ctx, name, root, headers, header_map = {}):
    """Symlink `headers` into a fresh dir, rooted at `root`.

    A header at package path `include/libsimple/lock.h` with root `include` is
    staged as `libsimple/lock.h`, so `#include <libsimple/lock.h>` resolves and
    nothing else in the source tree does.

    `header_map` gives the include path for a header explicitly, which is what
    Darwin SDK namespaces need: the SDK's `i386/` is a MERGE of xnu/bsd/i386 and
    xnu/osfmk/i386, and `mach/` keeps subdirectories, so no single prefix-strip
    reproduces the layout. cider-sdk-header-roots derives these maps
    from the repo's committed SDK symlink farm, which is the authority on it.
    """
    prefix = root + "/" if root else ""
    mapping = {}
    for h in headers:
        rel = h.short_path
        if prefix and rel.startswith(prefix):
            rel = rel[len(prefix):]
        mapping[rel] = h
    for staged, h in header_map.items():
        mapping[staged] = h
    return ctx.actions.symlinked_dir(name, mapping)

def compile_objects(ctx, tc, srcs, include_dirs, flags, out_prefix, prefix_headers = []):
    """One compile action per source; returns the list of object artifacts."""
    objects = []
    for src in srcs:
        is_cxx = _is_cxx(src)
        obj = ctx.actions.declare_output(out_prefix + "/" + src.short_path + ".o")
        cmd = cmd_args(tc.cxx if is_cxx else tc.cc)
        cmd.add(tc.cxxflags if is_cxx else tc.cflags)
        cmd.add(_drop_x86_flags(flags))
        for inc in include_dirs:
            cmd.add(cmd_args(inc, format = "-I{}"))
        # Force-included headers travel as artifacts, not as bare path strings,
        # so they are declared inputs of the compile.
        for ph in prefix_headers:
            cmd.add(["-include", ph])
        cmd.add(["-c", src, "-o", obj.as_output()])
        ctx.actions.run(
            cmd,
            category = "cxx_compile" if is_cxx else "c_compile",
            identifier = src.short_path,
        )
        objects.append(obj)
    return objects

def _archive(ctx, tc, name, objects):
    lib = ctx.actions.declare_output("lib" + name + ".a")
    cmd = cmd_args([tc.ar, "rcsD", lib.as_output()])
    cmd.add(objects)
    ctx.actions.run(cmd, category = "archive", identifier = name)
    return lib

# ---------------------------------------------------------------------------
# cc_header_root: stage one include root. A pure header dependency.
# ---------------------------------------------------------------------------

def _cc_header_root_impl(ctx):
    merged = merge_dep_libs(ctx.attrs.deps)
    staged = stage_include_root(
        ctx,
        ctx.label.name + "__include",
        ctx.attrs.root,
        ctx.attrs.headers,
        ctx.attrs.header_map,
    )
    # Sibling include dirs staged as ONE tree, with -I pointing at each subdir
    # inside it. A header staged alone cannot satisfy its own `#include "../lib/x.h"`
    # -- a quoted include resolves relative to the INCLUDING FILE, which is the
    # staged copy, so the sibling has to be present in the same tree.
    dirs = [
        staged if s == "." else staged.project(s)
        for s in ctx.attrs.include_subdirs
    ] or [staged]
    return [
        DefaultInfo(default_output = staged),
        CcLibInfo(
            include_dirs = dirs + merged.include_dirs,
            exported_flags = ctx.attrs.exported_flags + merged.exported_flags,
            static_libs = merged.static_libs,
            linker_flags = merged.linker_flags,
        ),
    ]

cc_header_root = rule(
    impl = _cc_header_root_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "exported_flags": attrs.list(attrs.string(), default = []),
        # {include path -> header file}, for roots whose layout is not a plain
        # prefix strip (the Darwin SDK namespaces).
        "header_map": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "headers": attrs.list(attrs.source(), default = []),
        # Subdirectories of the staged tree to put on the include path, instead of
        # the tree itself. Used when sibling dirs must stay siblings (see above).
        "include_subdirs": attrs.list(attrs.string(), default = []),
        # Package-relative dir the headers are exposed relative to ("" = the
        # package itself).
        "root": attrs.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# cc_objects: a group of objects sharing one set of flags.
# ---------------------------------------------------------------------------

def gen_sources(gen_deps):
    """Generated .c files contributed by codegen targets listed in `gen_srcs`."""
    srcs = []
    for g in gen_deps:
        srcs.extend(g[GeneratedSourcesInfo].sources)
    return srcs

def _cc_objects_impl(ctx):
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    # A codegen target in `gen_srcs` contributes BOTH its generated sources and
    # its generated-header include root, so it never has to be listed twice.
    merged = merge_dep_libs(ctx.attrs.deps + ctx.attrs.gen_srcs)

    # inproc: made without running a command, so it has to be declared. The private
    # include farm is NOT in the exported CcLibInfo (that is the point of private), so
    # nothing else would reach it.
    inproc = []
    include_dirs = []
    if ctx.attrs.headers:
        private_root = stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.include_root,
            ctx.attrs.headers,
        )
        inproc.append(private_root)
        include_dirs.append(private_root)
    include_dirs.extend(merged.include_dirs)

    flags = merged.exported_flags + ctx.attrs.compiler_flags
    srcs = ctx.attrs.srcs + gen_sources(ctx.attrs.gen_srcs)
    objects = compile_objects(
        ctx, tc, srcs, include_dirs, flags, "__objs", ctx.attrs.prefix_headers,
    )

    return [
        DefaultInfo(default_outputs = objects),
        CcObjectsInfo(objects = objects),
        CcLibInfo(
            include_dirs = merged.include_dirs,
            exported_flags = merged.exported_flags,
            static_libs = merged.static_libs,
            linker_flags = merged.linker_flags,
        ),
        InProcInfo(artifacts = inproc),
    ]

_cc_objects_attrs = {
    "compiler_flags": attrs.list(attrs.string(), default = []),
    "deps": attrs.list(attrs.dep(), default = []),
    # Codegen targets whose generated sources this target compiles.
    "gen_srcs": attrs.list(attrs.dep(), default = []),
    # Private headers: visible to this target's own compiles only.
    "headers": attrs.list(attrs.source(), default = []),
    "include_root": attrs.string(default = ""),
    # Headers force-included into every source (-include).
    "prefix_headers": attrs.list(attrs.source(), default = []),
    "srcs": attrs.list(attrs.source(), default = []),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
}

cc_objects = rule(
    impl = _cc_objects_impl,
    attrs = _cc_objects_attrs,
)

# ---------------------------------------------------------------------------
# cc_static_lib: archive object groups (possibly compiled with different flags)
# into one .a, and re-export the dep graph's include roots.
# ---------------------------------------------------------------------------

def _cc_static_lib_impl(ctx):
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    merged = merge_dep_libs(ctx.attrs.deps)

    objects = []
    for group in ctx.attrs.objs:
        objects.extend(group[CcObjectsInfo].objects)

    # An archive with no members is never what anyone meant, and it is SILENT: ar writes a
    # valid 8-byte file, buck2 calls the target built, and the mistake only surfaces at some
    # later link as "ld: file too small (length=8)", naming a library the person was not
    # working on. It happens when every source of an archive is GENERATED and the generated
    # sources were never wired -- libsecurityd_server and libsecurityd_ucspc were both
    # exactly that. A survey of the 126 archives this port builds found no legitimate empty
    # one, so failing here costs nothing and moves the diagnosis to where the cause is.
    if not objects:
        fail("cc_static_lib: %s would archive ZERO objects. Its object groups (%s) are " %
             (ctx.label, ", ".join([str(g.label) for g in ctx.attrs.objs])) +
             "empty, which usually means the target's sources are all GENERATED and no " +
             "gen_srcs entry supplies them (see buck/generated/extra-deps.json).")

    lib = _archive(ctx, tc, ctx.attrs.lib_name or ctx.label.name, objects)

    exported_include_dirs = []
    if ctx.attrs.exported_headers:
        exported_include_dirs.append(stage_include_root(
            ctx,
            ctx.label.name + "__include",
            ctx.attrs.include_root,
            ctx.attrs.exported_headers,
        ))

    return [
        DefaultInfo(default_output = lib),
        CcObjectsInfo(objects = objects),
        CcLibInfo(
            include_dirs = exported_include_dirs + merged.include_dirs,
            exported_flags = ctx.attrs.exported_flags + merged.exported_flags,
            static_libs = [lib] + merged.static_libs,
            linker_flags = ctx.attrs.linker_flags + merged.linker_flags,
        ),
    ]

cc_static_lib = rule(
    impl = _cc_static_lib_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "exported_flags": attrs.list(attrs.string(), default = []),
        "exported_headers": attrs.list(attrs.source(), default = []),
        "include_root": attrs.string(default = ""),
        # Archive basename without the lib prefix / .a suffix; defaults to the
        # target name. Darling has targets whose artifact name differs from the
        # cmake target name (liblibsimple_ciderd.a).
        "lib_name": attrs.string(default = ""),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "objs": attrs.list(attrs.dep(), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
    },
)

# ---------------------------------------------------------------------------
# cc_library: the common case, compile + archive in one target.
# ---------------------------------------------------------------------------

def _cc_library_impl(ctx):
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    merged = merge_dep_libs(ctx.attrs.deps + ctx.attrs.gen_srcs)

    exported_include_dirs = []
    if ctx.attrs.exported_headers:
        exported_include_dirs.append(stage_include_root(
            ctx,
            ctx.label.name + "__include",
            ctx.attrs.include_root,
            ctx.attrs.exported_headers,
        ))

    private_include_dirs = []
    if ctx.attrs.headers:
        private_include_dirs.append(stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.private_include_root,
            ctx.attrs.headers,
        ))

    # Own exported headers come first: a target sees its own tree before a dep's.
    include_dirs = private_include_dirs + exported_include_dirs + merged.include_dirs
    flags = merged.exported_flags + ctx.attrs.exported_flags + ctx.attrs.compiler_flags

    srcs = ctx.attrs.srcs + gen_sources(ctx.attrs.gen_srcs)
    objects = compile_objects(
        ctx, tc, srcs, include_dirs, flags, "__objs", ctx.attrs.prefix_headers,
    )
    lib = _archive(ctx, tc, ctx.attrs.lib_name or ctx.label.name, objects)

    return [
        DefaultInfo(default_output = lib),
        CcObjectsInfo(objects = objects),
        CcLibInfo(
            include_dirs = exported_include_dirs + merged.include_dirs,
            exported_flags = ctx.attrs.exported_flags + merged.exported_flags,
            static_libs = [lib] + merged.static_libs,
            linker_flags = ctx.attrs.linker_flags + merged.linker_flags,
        ),
    ]

cc_library = rule(
    impl = _cc_library_impl,
    attrs = {
        "compiler_flags": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "exported_flags": attrs.list(attrs.string(), default = []),
        "exported_headers": attrs.list(attrs.source(), default = []),
        "gen_srcs": attrs.list(attrs.dep(), default = []),
        "headers": attrs.list(attrs.source(), default = []),
        "include_root": attrs.string(default = ""),
        "lib_name": attrs.string(default = ""),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "prefix_headers": attrs.list(attrs.source(), default = []),
        "private_include_root": attrs.string(default = ""),
        "srcs": attrs.list(attrs.source(), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
    },
)

# ---------------------------------------------------------------------------
# cc_binary
# ---------------------------------------------------------------------------

def _cc_binary_impl(ctx):
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    merged = merge_dep_libs(ctx.attrs.deps + ctx.attrs.gen_srcs)

    include_dirs = []
    if ctx.attrs.headers:
        include_dirs.append(stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.include_root,
            ctx.attrs.headers,
        ))
    include_dirs.extend(merged.include_dirs)

    flags = merged.exported_flags + ctx.attrs.compiler_flags
    srcs = ctx.attrs.srcs + gen_sources(ctx.attrs.gen_srcs)
    objects = compile_objects(
        ctx, tc, srcs, include_dirs, flags, "__objs", ctx.attrs.prefix_headers,
    )
    for group in ctx.attrs.objs:
        objects.extend(group[CcObjectsInfo].objects)

    out = ctx.actions.declare_output(ctx.attrs.exe_name or ctx.label.name)
    cmd = cmd_args(tc.cxx if ctx.attrs.link_cxx else tc.cc)
    cmd.add(tc.ldflags)
    cmd.add(["-o", out.as_output()])
    cmd.add(objects)
    cmd.add(merged.static_libs)
    cmd.add(merged.linker_flags)
    cmd.add(ctx.attrs.linker_flags)
    ctx.actions.run(cmd, category = "link", identifier = ctx.label.name)

    return [
        DefaultInfo(default_output = out),
        RunInfo(args = cmd_args(out)),
    ]

cc_binary = rule(
    impl = _cc_binary_impl,
    attrs = {
        "compiler_flags": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "exe_name": attrs.string(default = ""),
        "gen_srcs": attrs.list(attrs.dep(), default = []),
        "headers": attrs.list(attrs.source(), default = []),
        "include_root": attrs.string(default = ""),
        "link_cxx": attrs.bool(default = False),
        "prefix_headers": attrs.list(attrs.source(), default = []),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "objs": attrs.list(attrs.dep(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
    },
)

# ---------------------------------------------------------------------------
# cc_lib_dir: collect the static libs of a dep graph into one directory.
#
# The Rust daemon consumes xnu-sys through XNU_SYS_LIB, an env var naming a
# directory that holds libciderd_xnu_sys.a and
# liblibsimple_ciderd.a. Each archive is its own buck2 artifact in its own
# output dir, so this stages them together into the shape the consumer expects.
# ---------------------------------------------------------------------------

def _cc_lib_dir_impl(ctx):
    merged = merge_dep_libs(ctx.attrs.deps)
    mapping = {}
    for lib in merged.static_libs:
        mapping[lib.basename] = lib
    staged = ctx.actions.symlinked_dir(ctx.label.name, mapping)
    return [
        DefaultInfo(default_output = staged),
        # The staged directory IS this target result, made in-process.
        InProcInfo(artifacts = [staged]),
        CcLibInfo(
            include_dirs = merged.include_dirs,
            exported_flags = merged.exported_flags,
            static_libs = merged.static_libs,
            linker_flags = merged.linker_flags,
        ),
    ]

cc_lib_dir = rule(
    impl = _cc_lib_dir_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
    },
)
