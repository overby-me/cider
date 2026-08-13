# Rust, driven by rustc directly.
#
# Three of Darling's components are Rust now: the ciderd daemon (src/linux/server), the
# launcher (src/linux/launcher, the `cider` binary) and the Mach-O loader (src/darwin/loader,
# mldr). Nix builds them with buildRustPackage today; this is the buck2 side, and it does
# what the rest of this port does with cmake -- read what the reference build actually runs,
# and run that, rather than shelling out to the other build system.
#
# So there is no cargo anywhere in the graph. cargo's three jobs are replaced by:
#
#   dependency resolution  ->  the Cargo.lock is already resolved; nix/devShell.nix unpacks
#                              every locked crate into $DARLING_RUST_VENDOR and
#                              scripts/buck-rust-vendor.nu materializes it into vendor/rust/,
#                              exactly as vendor/src/ holds the pinned C sources
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
load("//buck/rules:cc.bzl", "CcLibInfo", "CcObjectsInfo")
load("//buck/rules:inproc.bzl", "InProcInfo")

RustLibInfo = provider(fields = ["crate_name", "rlib", "transitive"])

_RUSTC = read_root_config("cider", "rustc", "rustc")
_BINDGEN = read_root_config("cider", "bindgen", "bindgen")

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

# rustc, through a runner that makes OUT_DIR absolute.
#
# buck2 hands out project-relative paths, and `include!(concat!(env!("OUT_DIR"), ...))`
# resolves a relative path against the FILE doing the include -- so the daemon's lib.rs went
# looking for the bindings under src/linux/server/src/buck-out/... Cargo always passes an
# absolute OUT_DIR, which is why the crate never had to care.
_RUSTC_RUNNER = """set -euo pipefail
# The compile-time environment travels in the ARGV, not in the action's env dict. Nothing
# outside buck2 can see that dict -- aquery does not report it -- so the Nix endpoint, which
# replays recorded command lines, compiled the launcher without CIDER_GIT_COMMIT and the
# crate failed on its own env!(). Putting it here keeps the command self-describing.
while [ "${1:-}" = "--env" ]; do export "$2"; shift 2; done
if [ -n "${OUT_DIR:-}" ]; then export OUT_DIR="$PWD/$OUT_DIR"; fi
exec "$@"
"""

def _rustc(ctx, crate_type, out, deps):
    # inproc collects what buck2 makes without running a command: the written runner, and
    # the dependency farm below. They are returned so the rule can declare them through
    # InProcInfo -- the Nix endpoint carries them as data and nothing else can recreate them.
    inproc = []
    runner = ctx.actions.write(ctx.label.name + "__rustc.sh", _RUSTC_RUNNER, is_executable = True)
    inproc.append(runner)
    cmd = cmd_args(["bash", runner])
    for k in sorted(ctx.attrs.env):
        cmd.add("--env", "%s=%s" % (k, ctx.attrs.env[k]))
    if ctx.attrs.out_dir:
        cmd.add("--env", cmd_args(
            ctx.attrs.out_dir[DefaultInfo].default_outputs[0],
            format = "OUT_DIR={}",
        ))
    cmd.add([
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
        inproc.append(staged)
        cmd.add("-L", cmd_args(staged, format = "dependency={}"))

    # What cargo does for every dependency it did not write: a lint that becomes
    # deny-by-default in a later rustc must not break a pinned third-party crate. goblin's
    # closure hits dangerous_implicit_autorefs on rustc 1.95 exactly this way.
    if ctx.attrs.cap_lints:
        cmd.add("--cap-lints", ctx.attrs.cap_lints)

    # RELEASE settings, because the reference builds these crates with cargo --release and
    # the difference is not just speed: at rustc's defaults debug_assert! and overflow
    # checks are ON, and each of them PANICS. mldr is loaded into every guest process, its
    # panic aborts, and an abort surfaces as SIGILL -- which is exactly how a debug-built
    # mldr killed `nix` while bash and sw_vers, whose Mach-O headers never reach the
    # checked arithmetic, kept working. Listed before rustc_flags so a target can override.
    cmd.add(["-C", "opt-level=3", "-C", "debug-assertions=off", "-C", "overflow-checks=off"])

    cmd.add(ctx.attrs.rustc_flags)

    # Every other file of the crate. rustc reads them by following `mod` from the root, so
    # they are inputs without ever appearing on the command line -- and a crate that
    # recompiles when they change is the entire point of declaring them.
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    return cmd, inproc

def _rust_library_impl(ctx):
    crate = _crate_name(ctx)
    deps = _closure(ctx)

    # A proc-macro is a host dylib loaded BY the compiler, not linked into the target.
    is_proc_macro = ctx.attrs.proc_macro
    out = ctx.actions.declare_output("lib%s.so" % crate if is_proc_macro else "lib%s.rlib" % crate)
    cmd, inproc = _rustc(ctx, "proc-macro" if is_proc_macro else "rlib", out, deps)
    if is_proc_macro:
        cmd.add("--extern", "proc_macro")
    ctx.actions.run(cmd, category = "rustc", identifier = ctx.label.name)
    return [
        DefaultInfo(default_output = out),
        RustLibInfo(crate_name = crate, rlib = out, transitive = deps),
        InProcInfo(artifacts = inproc),
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
    cmd, inproc = _rustc(ctx, "bin", out, deps)

    # Static libraries from the C side of the port (xnu-sys, libsimple, the fast-context
    # shim), which the daemon links. -L native= says where to look and -l static= names
    # what to take, exactly as the crate's build.rs prints them; the search paths come from
    # the artifacts themselves, so nothing depends on a path outside the build.
    for d in ctx.attrs.link_dirs:
        cmd.add(cmd_args(d[DefaultInfo].default_outputs[0], format = "-Lnative={}"))

    # Archives handed to the LINKER by path, not to rustc by name. `-l static=x` places the
    # archive before the crate's own objects, and a static archive that comes before the
    # code referencing it contributes nothing -- every xnu_sys_* symbol came back undefined.
    # Passing the file as a link argument puts it after, where the linker can resolve
    # against it. This is also what the crate's build script effectively achieves through
    # cargo, which emits its link flags after the crate objects.
    for a in ctx.attrs.link_archives:
        cmd.add(cmd_args(a[DefaultInfo].default_outputs[0], format = "-Clink-arg={}"))
    cmd.add(ctx.attrs.link_flags)

    ctx.actions.run(cmd, category = "rustc_link", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out)), InProcInfo(artifacts = inproc)]

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
# The daemon binds the xnu-sys hooks vtable -- 36 function pointers -- from the real
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
        # A dep that already knows its own include roots is asked, rather than guessed at.
        # cc_header_root's default output IS its include root, so the fallback is right for
        # it -- but a code generator's is its FIRST DECLARED OUTPUT, which is a file. Taking
        # that gave -I<...>/ciderd/rpc.h, and the include next to it then failed to
        # resolve: rpc.internal.h not found, from a header that plainly sits beside it.
        if CcLibInfo in d:
            for inc in d[CcLibInfo].include_dirs:
                cmd.add(cmd_args(inc, format = "-I{}"))
        else:
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


# ---------------------------------------------------------------------------
# GUEST RUST (#102): a Mach-O STATIC LIBRARY, so the link path the project already has can
# take it unchanged.
#
# WHY A STATICLIB AND NOT AN OBJECT, measured rather than assumed. `--emit=obj` emits only the
# crate's own code: a std hello leaves 11 Rust symbols undefined, and `-C lto=fat` makes it
# worse rather than better (14, because the allocator shims join them). `--crate-type staticlib`
# bundles std into the archive: of the 191 symbols the archive cannot satisfy, ZERO are
# Rust-mangled. They are libSystem C symbols -- malloc, pthread_*, __NSGetArgv, dispatch_* --
# which is exactly the set every C guest binary already gets from //vendor/src:system_final.
#
# SO THERE IS NO -syslibroot AND NO BUILT PREFIX HERE, which is what route A needed. The archive
# goes into darwin_binary's `objs`, and dylibs arrive the way they always do, as
# -Wl,-dylib_file,<install_name>:<artifact>. That is also what makes them real buck2 edges.
#
# THE ENTRY POINT IS C, NOT RUST. A staticlib has no `main`; the crate must export
# `#[unsafe(no_mangle)] pub extern "C" fn main(argc, argv) -> c_int` so crt1.10.6 finds it.
# The consequence is honest and small: Rust's lang_start does not run, so there is no
# stack-overflow guard page message and no std-installed cleanup. std itself works, because on
# macOS args come from _NSGetArgv rather than from an init hook.
#
# -C embed-bitcode=no because the bitcode is dead weight here (we never LTO across the C
# boundary) and it breaks host tooling: llvm-nm 21 cannot parse bitcode emitted by rustc's
# LLVM 22 and fails the whole archive.
_DARWIN_RUSTC = read_root_config("cider", "darwin_rustc", "")
_DARWIN_RUST_SYSROOT = read_root_config("cider", "darwin_rust_sysroot", "")
_DARWIN_RUST_TARGET = read_root_config("cider", "darwin_rust_target", "x86_64-apple-darwin")

def _darwin_rust_staticlib_impl(ctx):
    if not _DARWIN_RUSTC or not _DARWIN_RUST_SYSROOT:
        # A missing toolchain must say WHICH half is missing and where it is configured.
        # Failing in the action instead would surface as a bare "rustc: not found".
        fail(("darwin_rust_staticlib: %s needs both [cider] darwin_rustc and " +
              "[cider] darwin_rust_sysroot in .buckconfig.local (rustc=%r sysroot=%r). " +
              "They must come from the SAME rust release: crate metadata matching is a " +
              "string compare, so the nixpkgs rustc cannot use the official darwin std.") %
             (ctx.label.name, _DARWIN_RUSTC, _DARWIN_RUST_SYSROOT))
    out = ctx.actions.declare_output("lib" + _crate_name(ctx) + ".a")
    cmd = cmd_args([
        _DARWIN_RUSTC,
        "--target",
        _DARWIN_RUST_TARGET,
        "--sysroot",
        _DARWIN_RUST_SYSROOT,
        "--edition",
        ctx.attrs.edition,
        "--crate-name",
        _crate_name(ctx),
        "--crate-type",
        "staticlib",
        "-C",
        "embed-bitcode=no",
        ctx.attrs.crate_root,
        "-o",
        out.as_output(),
    ])
    for f in ctx.attrs.features:
        cmd.add("--cfg", 'feature="%s"' % f)
    cmd.add(ctx.attrs.rustc_flags)

    # NO MULTI FILE CRATES HERE, and the reason is recorded because it is not obvious.
    # rustc finds a `mod` by following it from the crate root, so module files are HIDDEN inputs
    # that never appear in the argv, and `buck2 aquery` reports NO INPUT LIST AT ALL: the
    # attributes of an action are kind, category, identifier, cmd and executor knobs. The Nix
    # endpoint therefore stages what the argv names and nothing else, and a `mod` file simply is
    # not there, which surfaces as 205 compiler errors that say nothing about staging.
    #
    # Passing each src as an inert --cfg was tried and does NOT work: the path ends up embedded
    # inside `cider_module="..."` rather than being an argv token that IS a path.
    #
    # So a guest crate is ONE FILE until the endpoint can be taught about hidden inputs. The hidden
    # entry below is still correct for a direct buck2 build, where it drives rebuilds properly.
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    ctx.actions.run(cmd, category = "darwin_rust_staticlib", identifier = ctx.label.name)
    return [
        DefaultInfo(default_output = out),
        # CcObjectsInfo is what darwin_binary's `objs` consumes. An archive in the objects
        # position is fine for ld64, and it must come AFTER crt1.10.6 so the lazy archive
        # load has a reference to _main to resolve.
        CcObjectsInfo(objects = [out]),
    ]

darwin_rust_staticlib = rule(
    impl = _darwin_rust_staticlib_impl,
    attrs = {
        "crate_name": attrs.string(default = ""),
        "crate_root": attrs.source(),
        "edition": attrs.string(default = "2021"),
        "features": attrs.list(attrs.string(), default = []),
        "rustc_flags": attrs.list(attrs.string(), default = []),
        # Modules the crate root pulls in, which never appear on the command line.
        "srcs": attrs.list(attrs.source(), default = []),
    },
)
