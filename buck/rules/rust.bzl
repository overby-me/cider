# Rust, driven by rustc directly.
#
# Three of Darling's components are Rust now: the darlingserver daemon (linux/server), the
# launcher (linux/launcher, the `darling` binary) and the Mach-O loader (darwin/loader,
# mldr). Nix builds them with buildRustPackage today; this is the buck2 side, and it does
# what the rest of this port does with cmake -- read what the reference build actually runs,
# and run that, rather than shelling out to the other build system.
#
# So there is no cargo anywhere in the graph. cargo's three jobs are replaced by:
#
#   dependency resolution  ->  the Cargo.lock is already resolved; nix/devShell.nix unpacks
#                              every locked crate into $DARLING_RUST_VENDOR and
#                              scripts/buck-rust-vendor.sh materializes it into buck-rust/,
#                              exactly as buck-src/ holds the pinned C sources
#   feature flags          ->  the `features` attribute, which becomes --cfg feature="x"
#   build.rs               ->  the `env` attribute for the `cargo:rustc-env=` lines, and the
#                              port's own cc rules for anything a build script compiles
#
# The last one is the interesting case: the launcher's build.rs bakes an install prefix and
# the git branch and commit. Running git from inside a build action would make the output
# depend on the checkout, so this passes the same fallback the build script itself uses when
# git is unavailable ("unknown"), and takes the prefix from configuration.

# What a Rust library hands to whatever links it.
#
# `transitive` is the whole closure, not just this crate: rustc needs --extern for every
# crate that appears in the dependency graph, direct or not, and passing them all by name is
# simpler than reconstructing -L search directories from artifact paths.
RustLibInfo = provider(fields = ["crate_name", "rlib", "transitive"])

_RUSTC = read_root_config("darling", "rustc", "rustc")

def _crate_name(ctx):
    # A crate name is a Rust identifier, so a target named mldr-rs compiles as mldr_rs.
    return ctx.attrs.crate_name or ctx.label.name.replace("-", "_")

def _closure(ctx):
    """{crate name: rlib artifact} over the whole dependency graph."""
    deps = {}
    for d in ctx.attrs.deps:
        info = d[RustLibInfo]
        deps[info.crate_name] = info.rlib
        for name, art in info.transitive.items():
            deps[name] = art
    return deps

def _rustc(ctx, crate_type, out, deps):
    cmd = cmd_args([
        _RUSTC,
        "--edition",
        ctx.attrs.edition,
        "--crate-name",
        _crate_name(ctx),
        "--crate-type",
        crate_type,
        ctx.attrs.crate_root,
        "-o",
        out.as_output(),
    ])
    for f in ctx.attrs.features:
        cmd.add("--cfg", 'feature="%s"' % f)
    for name in sorted(deps):
        cmd.add("--extern", cmd_args(deps[name], format = name + "={}"))

    # --extern binds a crate for DIRECT use; it does not tell rustc where to find the
    # crates its dependencies were themselves built against. Those are resolved through the
    # library search path, and without one rustc reaches the sysroot -- where it finds the
    # copy of unicode_ident that rustc ships for its own use and rejects proc_macro2 with
    # E0460, "found possibly newer version of crate unicode_ident". So every rlib in the
    # closure is farmed into one directory that goes on the search path.
    if deps:
        farm = ctx.actions.declare_output(ctx.label.name + "__deps", dir = True)
        staged = ctx.actions.symlinked_dir(farm, {
            deps[name].basename: deps[name]
            for name in deps
        })
        cmd.add("-L", cmd_args(staged, format = "dependency={}"))

    # What cargo does for every dependency it did not write: a lint that becomes
    # deny-by-default in a later rustc must not break a pinned third-party crate. goblin's
    # closure hits dangerous_implicit_autorefs on rustc 1.95 exactly this way.
    if ctx.attrs.cap_lints:
        cmd.add("--cap-lints", ctx.attrs.cap_lints)

    cmd.add(ctx.attrs.rustc_flags)

    # Every other file of the crate. rustc reads them by following `mod` from the root, so
    # they are inputs without ever appearing on the command line -- and a crate that
    # recompiles when they change is the entire point of declaring them.
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    return cmd

def _rust_library_impl(ctx):
    crate = _crate_name(ctx)
    deps = _closure(ctx)

    # A proc-macro is a host dylib loaded BY the compiler, not linked into the target.
    is_proc_macro = ctx.attrs.proc_macro
    out = ctx.actions.declare_output("lib%s.so" % crate if is_proc_macro else "lib%s.rlib" % crate)
    cmd = _rustc(ctx, "proc-macro" if is_proc_macro else "rlib", out, deps)
    if is_proc_macro:
        cmd.add("--extern", "proc_macro")
    ctx.actions.run(cmd, category = "rustc", identifier = ctx.label.name, env = ctx.attrs.env)

    return [
        DefaultInfo(default_output = out),
        RustLibInfo(crate_name = crate, rlib = out, transitive = deps),
    ]

rust_library = rule(
    impl = _rust_library_impl,
    attrs = {
        # "allow" for a vendored crate, empty for first-party code.
        "cap_lints": attrs.string(default = ""),
        "crate_name": attrs.string(default = ""),
        # The lib.rs. Separate from srcs because rustc compiles a crate from one root.
        "crate_root": attrs.source(),
        "deps": attrs.list(attrs.dep(providers = [RustLibInfo]), default = []),
        "edition": attrs.string(default = "2021"),
        # Compile-time environment, standing in for a build script's cargo:rustc-env lines.
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "features": attrs.list(attrs.string(), default = []),
        # Compiled for the host and dlopened by rustc itself.
        "proc_macro": attrs.bool(default = False),
        "rustc_flags": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)

def _rust_binary_impl(ctx):
    deps = _closure(ctx)
    out = ctx.actions.declare_output(ctx.attrs.binary_name or ctx.label.name)
    cmd = _rustc(ctx, "bin", out, deps)

    # Static libraries from the C side of the port (duct-tape, libsimple), which the daemon
    # links. -l static= names the library, -L native= says where to look; both come from the
    # artifacts themselves so nothing depends on a path outside the build.
    for lib in ctx.attrs.link_libs:
        cmd.add(cmd_args(lib, format = "-Lnative={}"))
    cmd.add(ctx.attrs.link_flags)

    ctx.actions.run(cmd, category = "rustc_link", identifier = ctx.label.name, env = ctx.attrs.env)
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

rust_binary = rule(
    impl = _rust_binary_impl,
    attrs = {
        # The installed name, when it differs from the target name.
        "binary_name": attrs.string(default = ""),
        "cap_lints": attrs.string(default = ""),
        "crate_name": attrs.string(default = ""),
        "crate_root": attrs.source(),
        "deps": attrs.list(attrs.dep(providers = [RustLibInfo]), default = []),
        "edition": attrs.string(default = "2021"),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "features": attrs.list(attrs.string(), default = []),
        # Directories holding static libraries to link, and the -l flags naming them.
        "link_flags": attrs.list(attrs.string(), default = []),
        "link_libs": attrs.list(attrs.source(), default = []),
        "rustc_flags": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)
