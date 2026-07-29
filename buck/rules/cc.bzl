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
#    groups compiled with different flags (duct-tape's pthread/kern_synch.c needs
#    its own -I but must land in libdarlingserver_duct_tape.a).

load("@toolchains//:native.bzl", "NativeCcToolchainInfo")

# What a C target hands to its consumers.
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

_CXX_EXTS = [".cpp", ".cc", ".cxx", ".C"]

def _is_cxx(src):
    for ext in _CXX_EXTS:
        if src.short_path.endswith(ext):
            return True
    return False

def _merge_dep_libs(deps):
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

def _stage_include_root(ctx, name, root, headers):
    """Symlink `headers` into a fresh dir, rooted at `root`.

    A header at package path `include/libsimple/lock.h` with root `include` is
    staged as `libsimple/lock.h`, so `#include <libsimple/lock.h>` resolves and
    nothing else in the source tree does.
    """
    prefix = root + "/" if root else ""
    mapping = {}
    for h in headers:
        rel = h.short_path
        if prefix and rel.startswith(prefix):
            rel = rel[len(prefix):]
        mapping[rel] = h
    return ctx.actions.symlinked_dir(name, mapping)

def _compile_objects(ctx, tc, srcs, include_dirs, flags, out_prefix):
    """One compile action per source; returns the list of object artifacts."""
    objects = []
    for src in srcs:
        is_cxx = _is_cxx(src)
        obj = ctx.actions.declare_output(out_prefix + "/" + src.short_path + ".o")
        cmd = cmd_args(tc.cxx if is_cxx else tc.cc)
        cmd.add(tc.cxxflags if is_cxx else tc.cflags)
        cmd.add(flags)
        for inc in include_dirs:
            cmd.add(cmd_args(inc, format = "-I{}"))
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
    merged = _merge_dep_libs(ctx.attrs.deps)
    staged = _stage_include_root(
        ctx,
        ctx.label.name + "__include",
        ctx.attrs.root,
        ctx.attrs.headers,
    )
    return [
        DefaultInfo(default_output = staged),
        CcLibInfo(
            include_dirs = [staged] + merged.include_dirs,
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
        "headers": attrs.list(attrs.source(), default = []),
        # Package-relative dir the headers are exposed relative to ("" = the
        # package itself).
        "root": attrs.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# cc_objects: a group of objects sharing one set of flags.
# ---------------------------------------------------------------------------

def _cc_objects_impl(ctx):
    tc = ctx.attrs._cc_toolchain[NativeCcToolchainInfo]
    merged = _merge_dep_libs(ctx.attrs.deps)

    include_dirs = []
    if ctx.attrs.headers:
        include_dirs.append(_stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.include_root,
            ctx.attrs.headers,
        ))
    include_dirs.extend(merged.include_dirs)

    flags = merged.exported_flags + ctx.attrs.compiler_flags
    objects = _compile_objects(ctx, tc, ctx.attrs.srcs, include_dirs, flags, "__objs")

    return [
        DefaultInfo(default_outputs = objects),
        CcObjectsInfo(objects = objects),
        CcLibInfo(
            include_dirs = merged.include_dirs,
            exported_flags = merged.exported_flags,
            static_libs = merged.static_libs,
            linker_flags = merged.linker_flags,
        ),
    ]

_cc_objects_attrs = {
    "compiler_flags": attrs.list(attrs.string(), default = []),
    "deps": attrs.list(attrs.dep(), default = []),
    # Private headers: visible to this target's own compiles only.
    "headers": attrs.list(attrs.source(), default = []),
    "include_root": attrs.string(default = ""),
    "srcs": attrs.list(attrs.source(), default = []),
    "_cc_toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
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
    tc = ctx.attrs._cc_toolchain[NativeCcToolchainInfo]
    merged = _merge_dep_libs(ctx.attrs.deps)

    objects = []
    for group in ctx.attrs.objs:
        objects.extend(group[CcObjectsInfo].objects)
    lib = _archive(ctx, tc, ctx.attrs.lib_name or ctx.label.name, objects)

    exported_include_dirs = []
    if ctx.attrs.exported_headers:
        exported_include_dirs.append(_stage_include_root(
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
        # cmake target name (liblibsimple_darlingserver.a).
        "lib_name": attrs.string(default = ""),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "objs": attrs.list(attrs.dep(), default = []),
        "_cc_toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
    },
)

# ---------------------------------------------------------------------------
# cc_library: the common case, compile + archive in one target.
# ---------------------------------------------------------------------------

def _cc_library_impl(ctx):
    tc = ctx.attrs._cc_toolchain[NativeCcToolchainInfo]
    merged = _merge_dep_libs(ctx.attrs.deps)

    exported_include_dirs = []
    if ctx.attrs.exported_headers:
        exported_include_dirs.append(_stage_include_root(
            ctx,
            ctx.label.name + "__include",
            ctx.attrs.include_root,
            ctx.attrs.exported_headers,
        ))

    private_include_dirs = []
    if ctx.attrs.headers:
        private_include_dirs.append(_stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.private_include_root,
            ctx.attrs.headers,
        ))

    # Own exported headers come first: a target sees its own tree before a dep's.
    include_dirs = private_include_dirs + exported_include_dirs + merged.include_dirs
    flags = merged.exported_flags + ctx.attrs.exported_flags + ctx.attrs.compiler_flags

    objects = _compile_objects(ctx, tc, ctx.attrs.srcs, include_dirs, flags, "__objs")
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
        "headers": attrs.list(attrs.source(), default = []),
        "include_root": attrs.string(default = ""),
        "lib_name": attrs.string(default = ""),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "private_include_root": attrs.string(default = ""),
        "srcs": attrs.list(attrs.source(), default = []),
        "_cc_toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
    },
)

# ---------------------------------------------------------------------------
# cc_binary
# ---------------------------------------------------------------------------

def _cc_binary_impl(ctx):
    tc = ctx.attrs._cc_toolchain[NativeCcToolchainInfo]
    merged = _merge_dep_libs(ctx.attrs.deps)

    include_dirs = []
    if ctx.attrs.headers:
        include_dirs.append(_stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.include_root,
            ctx.attrs.headers,
        ))
    include_dirs.extend(merged.include_dirs)

    flags = merged.exported_flags + ctx.attrs.compiler_flags
    objects = _compile_objects(ctx, tc, ctx.attrs.srcs, include_dirs, flags, "__objs")
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
        "headers": attrs.list(attrs.source(), default = []),
        "include_root": attrs.string(default = ""),
        "link_cxx": attrs.bool(default = False),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "objs": attrs.list(attrs.dep(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
        "_cc_toolchain": attrs.toolchain_dep(default = "toolchains//:native_cc"),
    },
)
