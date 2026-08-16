# Buck2 rules for Darling

Darling's Buck2 build defines all of its own rules. Buck2 ships no rules at all
(every rule name is a Starlark function someone wrote), and Meta's
`buck2-prelude` is deliberately not used here: the Nix endpoint for this port
(overby.me `nix/lib/buck2`) interprets the Starlark itself in Nix and cannot eat
the prelude, and Darling's linking (MIG, reexport, `install_name`, the firstpass
umbrella) needs custom rules regardless. See `plan/buck2-port.md`.

Quick start (inside `nix develop`, which provides `buck2` + `watchman`):

```console
scripts/buck-setup.nu        # pinned sources + the absolute ld64 path
buck2 build //vendor/pins/ciderd/xnu-sys:ciderd_xnu_sys
scripts/buck-test.nu         # regression test for everything ported so far
```

`scripts/buck-setup.nu --all` materializes ALL 147 pinned trees (~3.8 GB), which
the guest (Darwin) tier needs: its include path is the SDK tree, ~1987 symlinks
into those trees.

## Layout

| Path | What |
|---|---|
| `.buckconfig`, `.buckroot` | project root, cells (`root`, `toolchains`), file watcher |
| `.watchmanconfig` | watchman ignores (`.jj`, `buck-out`, ...) |
| `buck/toolchains/` | `cc_toolchain`, instantiated as `native_cc` (host/ELF) and `darwin_cc` (guest/Mach-O) |
| `buck/rules/cc.bzl` | `cc_header_root`, `cc_objects`, `cc_static_lib`, `cc_library`, `cc_binary`, `cc_lib_dir` |
| `buck/rules/codegen.bzl` | `bison_gen`, `flex_gen`, `mig_gen`, `host_gen`, `script_gen` |
| `buck/rules/darwin.bzl` | `darwin_dylib`, `darwin_binary` (install_name, reexport, firstpass) |
| `buck/rules/files.bzl` | `export_file` |
| `buck/generated/` | header maps derived from the SDK symlink farm |
| `tests/buck2/firstpass` | the two-mutually-dependent-dylibs fixture |
| `vendor/src/` | pinned upstream trees, materialized (gitignored) + the BUCK file over them |

## The two ideas that matter

**One action per source file.** The point of the port is a fast edit/rebuild
loop, which needs per-object granularity. (Upstream's `no_prelude` example
compiles a whole target in one `clang` call; that would be a regression from
ninja.)

**Headers are staged, never globbed onto `-I`.** Every include root becomes a
`symlinked_dir` holding exactly the declared headers, and consumers get
`-I<that staged dir>`. Three things fall out of this:

- A compile can only see headers someone declared for it, so a source-tree
  `endian.h` cannot shadow the SDK's system header (nix-ninja's "wall #1").
- Overlapping roots stay separate. xnu-sys puts both `xnu` and `xnu/osfmk` on
  the path, and MIG re-emits a `mach/notify.h` that also exists as a hand-written
  source header; separate ordered roots resolve both exactly the way cmake's
  include order does, with no merge and no fixup.
- A host tool gets only the Darwin headers the reference build gives it, instead
  of all of Darwin's `sys/*.h` shadowing glibc's.

## Rules

`cc_header_root(name, headers, root, header_map, exported_flags, deps)`
: Stage one include root. `root` is a package-relative prefix stripped from each
  header's path; `header_map` gives `{include path: header}` explicitly, for
  roots that are not a prefix strip (the Darwin SDK namespaces, whose maps come
  from `cider-sdk-header-roots`). With no headers it is a pure
  flags-and-deps bundle: `dt_env` carries xnu-sys's 108 defines plus all its
  include roots, so everything that compiles xnu-sys depends on one target.

`cc_objects(name, srcs, gen_srcs, headers, compiler_flags, deps)`
: A group of objects sharing one set of flags. `gen_srcs` names codegen targets
  whose generated sources this target compiles (and whose generated headers it
  sees). Exists so one archive can hold object groups compiled differently:
  xnu-sys's `pthread/kern_synch.c` needs its own `-I`.

`cc_static_lib(name, objs, lib_name, exported_headers, deps)`
: Archive object groups into one `.a`. `lib_name` covers targets whose artifact
  name differs from the target name (`liblibsimple_ciderd.a`).

`cc_library` / `cc_binary`
: Compile + archive, and compile + link, for the common cases.

`cc_lib_dir(name, deps)`
: Collect a dep graph's archives into one directory, which is the shape
  `XNU_SYS_LIB` wants (see `//src/linux/server:xnu_sys_lib`).

`mig_gen(name, defs, out_base, *_suffix, compile_srcs, mig_sh, migcom, deps)`
: Run one MIG definition. Invokes Darling's own `mig.sh` (through `bash`: its
  `#!/bin/bash` shebang does not resolve on NixOS) with `-cc`/`-migcom`, so no
  `build-mig` wrapper has to be generated, and feeds it the same defines and
  include roots as the compiles that consume its output. Output is ONE directory
  per definition, because which of the five files MIG writes depends on the
  definition. Generated sources are exported for a consumer to compile, not
  compiled here: a generated stub reaches hand-written xnu headers that include
  OTHER definitions' generated headers.

`darwin_dylib(name, srcs|objs, install_name, firstpass, siblings, upward, reexport, ...)`
: A Mach-O dylib. `firstpass = True` links with `-flat_namespace
  -undefined suppress`, resolving nothing, which is how Darling breaks the
  libSystem cycle: each circular library is built twice from the same objects, and
  the final pass links its siblings' FIRSTPASS dylibs. A circular library is
  therefore two targets, not one -- one rule emitting both passes would make the
  target graph cyclic. `DarwinDylibInfo` carries `(install_name, artifact)` pairs
  transitively, rendered as `-Wl,-dylib_file` on a consumer's link line.

`bison_gen` / `flex_gen` / `host_gen` / `script_gen`
: Parser/scanner generation; run a just-built host tool that writes a file
  (`rtsig`); run a checked-in generator script (the RPC wrappers). Each stages
  its generated headers as an include root, so consumers reach them by
  depending on the target.

## Conventions

- Flags come from the reference build's configured `build.ninja`
  (`nix build .#cider-graph-stock`), not from reading `CMakeLists.txt`. The
  CMakeLists does not contain what a target inherits from parent scopes.
- Where a target's lists are large and upstream-owned, the BUCK file is
  GENERATED by `gen-xnu-sys-buck`, which is DELETED: its input CMakeLists went with cmake
  (#82), so the file is hand-maintained now and the generator is in git history.
  Hand-authored BUCK is for the code we iterate on.
- New pinned upstream tree to compile? Add it to `scripts/buck-src.nu` and give
  it targets in `vendor/src/BUCK`.
