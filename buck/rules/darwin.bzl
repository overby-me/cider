# Darwin/Mach-O linking: dylibs, install_name, reexport, and the firstpass
# machinery that breaks the libSystem cycle.
#
# HOW THE CYCLE IS ACTUALLY BROKEN (cmake/darling_lib.cmake's add_circular, and
# the -dylib_file list in cmake/use_ld64.cmake). This is the plan's "highest
# risk" item, and reading the reference makes it much less scary than it sounds:
#
#   objects ──┬──> X_firstpass.dylib   linked with -flat_namespace
#             │                        -undefined suppress, so unresolved
#             │                        symbols are simply allowed
#             └──> X.dylib             linked against its siblings'
#                                      *_firstpass.dylib
#
# Both passes are built from the SAME objects, and the firstpass pass resolves
# nothing, so the ARTIFACT graph is acyclic even though the libraries are
# mutually dependent. It is a plain DAG, which is all Buck2 needs.
#
# The one thing that does not survive the translation is putting both passes in
# one rule: if `libsystem_c` and `libsystem_kernel` each named the other, the
# TARGET graph would be cyclic and buck2 would reject it. So a circular library
# is TWO targets, exactly as cmake makes two targets, and the firstpass ones form
# a layer that depends on nothing but objects.
#
# `-dylib_file <install_name>:<path>` is how a link resolves an install_name to
# a file that is not where it will live at runtime. cmake keeps one global map of
# every firstpass dylib and passes the whole thing to every link; here each target
# contributes its own mapping through a provider, so a link only carries the
# mappings for libraries it actually depends on. Same effect, and the dependency
# edges stay honest.

load(":cc.bzl", "CcLibInfo", "CcObjectsInfo", "compile_objects", "merge_dep_libs", "stage_include_root")
load("@toolchains//:cc.bzl", "CcToolchainInfo")

DarwinDylibInfo = provider(fields = [
    # The -install_name this dylib will have at runtime.
    "install_name",
    # This target's dylib artifact.
    "dylib",
    # [(install_name, artifact)] for this dylib and everything it depends on,
    # rendered as -Wl,-dylib_file,<name>:<path> on a consumer's link line.
    "dylib_files",
])

def _merge_dylib_files(deps):
    """Transitive (install_name, artifact) pairs, first occurrence wins."""
    seen = {}
    out = []
    for dep in deps:
        info = dep.get(DarwinDylibInfo)
        if info == None:
            continue
        for name, art in info.dylib_files:
            if name not in seen:
                seen[name] = True
                out.append((name, art))
    return out

def _darwin_link(ctx, tc, out, objects, extra_flags, link_libs, dylib_files):
    cmd = cmd_args(tc.cc)
    cmd.add(tc.cflags)
    cmd.add(tc.ldflags)
    # The Mach-O linker is selected by -B plus the target triple: clang's driver
    # looks for `<triple>-ld` in the -B dirs, which is exactly why cctools names
    # it x86_64-apple-darwin20-ld. (-fuse-ld= would also work but only with an
    # ABSOLUTE path, which a Starlark rule cannot compute; set [darling] ld in
    # .buckconfig.local to an absolute path to use it instead.)
    for d in tc.ld_search_dirs:
        cmd.add(["-B", d])
    if tc.ld:
        cmd.add(cmd_args(tc.ld, format = "-fuse-ld={}"))
    cmd.add(extra_flags)
    cmd.add(["-o", out.as_output()])
    cmd.add(objects)
    cmd.add(link_libs)
    for name, art in dylib_files:
        cmd.add(cmd_args(art, format = "-Wl,-dylib_file," + name + ":{}"))
    ctx.actions.run(cmd, category = "darwin_link", identifier = ctx.label.name)

def _darwin_dylib_impl(ctx):
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    merged = merge_dep_libs(ctx.attrs.deps)

    include_dirs = []
    if ctx.attrs.headers:
        include_dirs.append(stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.include_root,
            ctx.attrs.headers,
        ))
    include_dirs.extend(merged.include_dirs)

    objects = compile_objects(
        ctx,
        tc,
        ctx.attrs.srcs,
        include_dirs,
        merged.exported_flags + ctx.attrs.compiler_flags,
        "__objs",
        ctx.attrs.prefix_headers,
    )
    for group in ctx.attrs.objs:
        objects.extend(group[CcObjectsInfo].objects)

    out = ctx.actions.declare_output(ctx.attrs.dylib_name or (ctx.label.name + ".dylib"))

    # -nostdlib: clang's Darwin driver would otherwise add -lSystem, and libSystem
    # is the very thing being built. The reference build passes it too (via
    # cmake/darling_lib.cmake), alongside -shared; -dynamiclib is the same request
    # spelled the Darwin way.
    flags = ["-dynamiclib", "-nostdlib"]
    if ctx.attrs.install_name:
        flags.append("-Wl,-dylib_install_name," + ctx.attrs.install_name)
    flags.extend(["-Wl,-compatibility_version," + ctx.attrs.compatibility_version])
    if ctx.attrs.current_version:
        flags.extend(["-Wl,-current_version," + ctx.attrs.current_version])
    if ctx.attrs.firstpass:
        # The whole point of a firstpass dylib: resolve nothing, so it can be
        # built before the libraries it will eventually need.
        flags.extend(["-Wl,-flat_namespace", "-Wl,-undefined,suppress"])
    flags.extend(ctx.attrs.linker_flags)

    # Siblings are linked through their FIRSTPASS dylib, which is what makes the
    # mutual dependency expressible.
    link_libs = []
    for sib in ctx.attrs.siblings:
        link_libs.append(sib[DarwinDylibInfo].dylib)
    for up in ctx.attrs.upward:
        # An upward dependency is loaded and initialized only after this library
        # is fully loaded; dyld requires it when a libSystem sublibrary depends on
        # something that itself depends on libSystem and has initializers.
        link_libs.append(cmd_args(up[DarwinDylibInfo].dylib, format = "-Wl,-upward_library,{}"))
    for r in ctx.attrs.reexport:
        link_libs.append(cmd_args(r[DarwinDylibInfo].dylib, format = "-Wl,-reexport_library,{}"))
    link_libs.extend(merged.static_libs)
    link_libs.extend(merged.linker_flags)

    dylib_files = _merge_dylib_files(
        ctx.attrs.siblings + ctx.attrs.upward + ctx.attrs.reexport + ctx.attrs.deps,
    )
    _darwin_link(ctx, tc, out, objects, flags, link_libs, dylib_files)

    own = []
    if ctx.attrs.install_name:
        own = [(ctx.attrs.install_name, out)]

    return [
        DefaultInfo(default_output = out),
        CcObjectsInfo(objects = objects),
        DarwinDylibInfo(
            install_name = ctx.attrs.install_name,
            dylib = out,
            dylib_files = own + dylib_files,
        ),
        CcLibInfo(
            include_dirs = merged.include_dirs,
            exported_flags = merged.exported_flags,
            static_libs = [],
            linker_flags = [],
        ),
    ]

_darwin_dylib_attrs = {
    "compatibility_version": attrs.string(default = "1.0.0"),
    "compiler_flags": attrs.list(attrs.string(), default = []),
    "current_version": attrs.string(default = ""),
    "deps": attrs.list(attrs.dep(), default = []),
    # Artifact name; defaults to <name>.dylib. Darling's dylib names rarely match
    # the cmake target name (libsystem_c.dylib vs libsystem_c_firstpass.dylib).
    "dylib_name": attrs.string(default = ""),
    # Link with unresolved symbols allowed, for the first of the two passes.
    "firstpass": attrs.bool(default = False),
    "headers": attrs.list(attrs.source(), default = []),
    "include_root": attrs.string(default = ""),
    "install_name": attrs.string(default = ""),
    "linker_flags": attrs.list(attrs.string(), default = []),
    "objs": attrs.list(attrs.dep(), default = []),
    "prefix_headers": attrs.list(attrs.source(), default = []),
    # Libraries whose symbols this dylib re-exports as its own (the umbrella
    # pattern: libSystem.B.dylib reexports every sublibrary).
    "reexport": attrs.list(attrs.dep(), default = []),
    # Mutually dependent libraries, linked through their firstpass dylib.
    "siblings": attrs.list(attrs.dep(), default = []),
    "srcs": attrs.list(attrs.source(), default = []),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:darwin_cc"),
    "upward": attrs.list(attrs.dep(), default = []),
}

darwin_dylib = rule(
    impl = _darwin_dylib_impl,
    attrs = _darwin_dylib_attrs,
)

# ---------------------------------------------------------------------------
# darwin_binary: a Mach-O executable.
# ---------------------------------------------------------------------------

def _darwin_binary_impl(ctx):
    tc = ctx.attrs.toolchain[CcToolchainInfo]
    merged = merge_dep_libs(ctx.attrs.deps)

    include_dirs = []
    if ctx.attrs.headers:
        include_dirs.append(stage_include_root(
            ctx,
            ctx.label.name + "__private_include",
            ctx.attrs.include_root,
            ctx.attrs.headers,
        ))
    include_dirs.extend(merged.include_dirs)

    objects = compile_objects(
        ctx,
        tc,
        ctx.attrs.srcs,
        include_dirs,
        merged.exported_flags + ctx.attrs.compiler_flags,
        "__objs",
        ctx.attrs.prefix_headers,
    )
    for group in ctx.attrs.objs:
        objects.extend(group[CcObjectsInfo].objects)

    out = ctx.actions.declare_output(ctx.attrs.exe_name or ctx.label.name)
    link_libs = []
    for lib in ctx.attrs.dylibs:
        link_libs.append(lib[DarwinDylibInfo].dylib)
    link_libs.extend(merged.static_libs)
    link_libs.extend(merged.linker_flags)
    dylib_files = _merge_dylib_files(ctx.attrs.dylibs + ctx.attrs.deps)

    _darwin_link(ctx, tc, out, objects, ctx.attrs.linker_flags, link_libs, dylib_files)
    return [DefaultInfo(default_output = out)]

darwin_binary = rule(
    impl = _darwin_binary_impl,
    attrs = {
        "compiler_flags": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "dylibs": attrs.list(attrs.dep(), default = []),
        "exe_name": attrs.string(default = ""),
        "headers": attrs.list(attrs.source(), default = []),
        "include_root": attrs.string(default = ""),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "objs": attrs.list(attrs.dep(), default = []),
        "prefix_headers": attrs.list(attrs.source(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:darwin_cc"),
    },
)
