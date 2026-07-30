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
_BINDGEN = read_root_config("darling", "bindgen", "bindgen")

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

def _env(ctx):
    """The action's environment, with OUT_DIR filled in from the generated-code target."""
    env = dict(ctx.attrs.env)
    if ctx.attrs.out_dir:
        env["OUT_DIR"] = cmd_args(ctx.attrs.out_dir[DefaultInfo].default_outputs[0])
    return env

# rustc, through a runner that makes OUT_DIR absolute.
#
# buck2 hands out project-relative paths, and `include!(concat!(env!("OUT_DIR"), ...))`
# resolves a relative path against the FILE doing the include -- so the daemon's lib.rs went
# looking for the bindings under linux/server/src/buck-out/... Cargo always passes an
# absolute OUT_DIR, which is why the crate never had to care.
_RUSTC_RUNNER = """set -euo pipefail
if [ -n "${OUT_DIR:-}" ]; then export OUT_DIR="$PWD/$OUT_DIR"; fi
exec "$@"
"""

def _rustc(ctx, crate_type, out, deps):
    runner = ctx.actions.write(ctx.label.name + "__rustc.sh", _RUSTC_RUNNER, is_executable = True)
    cmd = cmd_args([
        "bash",
        runner,
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

    # A build script's OUT_DIR, for a crate that include!()s generated code. The daemon's
    # dtape bindings arrive this way, so the directory has to exist before rustc reads
    # lib.rs -- naming it here is what makes it an input.
    if ctx.attrs.out_dir:
        out_dir = ctx.attrs.out_dir[DefaultInfo].default_outputs[0]
        cmd.add(cmd_args(hidden = out_dir))

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
    ctx.actions.run(cmd, category = "rustc", identifier = ctx.label.name, env = _env(ctx))

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
        # A target whose output directory becomes OUT_DIR (generated code to include!).
        "out_dir": attrs.option(attrs.dep(), default = None),
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

    # Static libraries from the C side of the port (duct-tape, libsimple, the fast-context
    # shim), which the daemon links. -L native= says where to look and -l static= names
    # what to take, exactly as the crate's build.rs prints them; the search paths come from
    # the artifacts themselves, so nothing depends on a path outside the build.
    for d in ctx.attrs.link_dirs:
        cmd.add(cmd_args(d[DefaultInfo].default_outputs[0], format = "-Lnative={}"))

    # Archives handed to the LINKER by path, not to rustc by name. `-l static=x` places the
    # archive before the crate's own objects, and a static archive that comes before the
    # code referencing it contributes nothing -- every dtape_* symbol came back undefined.
    # Passing the file as a link argument puts it after, where the linker can resolve
    # against it. This is also what the crate's build script effectively achieves through
    # cargo, which emits its link flags after the crate objects.
    for a in ctx.attrs.link_archives:
        cmd.add(cmd_args(a[DefaultInfo].default_outputs[0], format = "-Clink-arg={}"))
    cmd.add(ctx.attrs.link_flags)

    ctx.actions.run(cmd, category = "rustc_link", identifier = ctx.label.name, env = _env(ctx))
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
        # Targets whose output is a DIRECTORY of static libraries, and the -l flags that
        # name what to take from them.
        "link_archives": attrs.list(attrs.dep(), default = []),
        "link_dirs": attrs.list(attrs.dep(), default = []),
        "link_flags": attrs.list(attrs.string(), default = []),
        "out_dir": attrs.option(attrs.dep(), default = None),
        "rustc_flags": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)


# ---------------------------------------------------------------------------
# bindgen: the C contract a crate binds to, generated.
#
# The daemon binds the duct-tape hooks vtable -- 36 function pointers -- from the real
# headers rather than transcribing it, which is what keeps the Rust side honest when the C
# side changes. Its build.rs calls the bindgen LIBRARY; this calls the same generator as a
# tool, so the port does not have to build bindgen and its thirty dependencies to produce
# one file.
# ---------------------------------------------------------------------------

def _bindgen_impl(ctx):
    # A DIRECTORY, because the consuming crate include!()s it through OUT_DIR, which is what
    # cargo hands a build script.
    out = ctx.actions.declare_output(ctx.label.name + "__out", dir = True)
    generated = out.project(ctx.attrs.out)

    # Through a runner, because buck2 creates the declared directory's PARENT but not the
    # directory itself, and bindgen will not create the path it is told to write to.
    runner = ctx.actions.write(
        ctx.label.name + "__run.sh",
        '''set -euo pipefail
out="$1"; tool="$2"; header="$3"; shift 3
mkdir -p "$(dirname "$out")"
# -o goes here, not at the end: everything after the `--` separator belongs to clang, and
# an -o that lands there is silently taken as clang's output and bindgen writes nothing.
exec "$tool" "$header" -o "$out" "$@"
''',
        is_executable = True,
    )
    cmd = cmd_args(["bash", runner, generated.as_output(), _BINDGEN, ctx.attrs.header])
    cmd.add(ctx.attrs.flags)
    cmd.add("--")
    for d in ctx.attrs.include_dirs:
        cmd.add(cmd_args(d[DefaultInfo].default_outputs[0], format = "-I{}"))
    cmd.add(ctx.attrs.clang_flags)
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    ctx.actions.run(cmd, category = "bindgen", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

bindgen_gen = rule(
    impl = _bindgen_impl,
    attrs = {
        "clang_flags": attrs.list(attrs.string(), default = []),
        "flags": attrs.list(attrs.string(), default = []),
        "header": attrs.source(),
        # Targets whose output directory goes on the include path.
        "include_dirs": attrs.list(attrs.dep(), default = []),
        "out": attrs.string(),
        # Headers the entry point pulls in, which never appear on the command line.
        "srcs": attrs.list(attrs.source(), default = []),
    },
)
