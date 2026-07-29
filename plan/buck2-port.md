# Buck2 port plan (gradual, direct-first then nix-integrated)

## Why, and what "done" means

`nix-ninja` (now upstreamed to overby.me) consumes Darling's existing CMake/ninja
graph and reconstructs isolation with heuristics. That is the right tool for
*building* the whole tree once and caching it, and it stays the build of record
for the stable upstream frameworks (Security, CoreFoundation, Foundation, the
CLI tools) that we never edit.

Buck2 is the right tool for the code we *iterate on*: it gets clean isolation by
construction (deps are declared and enforced), a persistent daemon for genuinely
fast incremental rebuilds, and it makes the `nix-ninja` "wall #1" (a source
`endian.h` shadowing the system header on a globbed `-I` path) impossible,
because every target's headers are declared, not globbed.

"Done" is NOT "all of Darling in Buck2." It is: **the subtree we actively
develop (first-party host/guest + the libSystem boundary + whatever framework we
happen to be patching) builds under Buck2 with a fast daemon loop, and that
build is reproducible under Nix for CI/sharing.** Everything else keeps using the
cached dense/nix-ninja build. The port is gradual and demand-driven: a project
enters Buck2 when we start iterating on it, not before.

Endpoint for Nix integration already exists: overby.me `nix/lib/buck2`
(`buildBuck2Project`, per-action lowering, sibling to `nix/lib/ninja`). Phase 3
points it at Darling.

## Guiding constraints (learned from the nix-ninja grind)

- The whole graph already builds green on the dense path, so there are **no
  source bugs to find** — only build-definition work. A Buck2 port is about
  expressing Darling's build *correctly and explicitly*, not fixing Darling.
- The genuinely hard parts to express in ANY system are: (1) MIG codegen, (2) the
  firstpass two-pass link that breaks the libSystem umbrella cycle, (3)
  reexport / `install_name` machinery, (4) the darwin SDK sysroot + cross-arch
  (`x86_64-apple-darwin20`) toolchain, (5) the darling header shims. Spike these
  before mass porting (Phase 1) — they decide feasibility.
- Hand-written BUCK for upstream code **drifts** on every Darling bump. Mitigate
  with a CMake/ninja -> BUCK *generator* (reuse `rust-ninja -t graph-json`) to
  bootstrap targets, then hand-refine the ones we own. Generated where it drifts,
  hand-authored where we iterate.

---

## Status log

Decisions taken 2026-07-29 (branch `buck2-port`):

- **Own rules, no prelude.** `buck/rules/cc.bzl` + `buck/toolchains/native.bzl`
  define everything. Meta's `buck2-prelude` is rejected because (a) the Nix
  endpoint (overby.me `nix/lib/buck2`) interprets the Starlark itself in Nix and
  lists the full prelude as an explicit non-goal, and (b) MIG / reexport /
  install_name / firstpass need custom rules regardless.
- **Direct `buck2` first, Nix integration deferred.** Phase 3 is not being built
  yet; the rules stay inside the surface overby's interpreter can grow to support
  (`run`/`write`/`copy`/`symlinked_dir`, no `select()`), so it stays reachable.
- **Host tier before guest tier.** The first real port is duct-tape/XNU (native
  ELF, no cross-compiler, no Mach-O, no firstpass), which yields
  `libdarlingserver_duct_tape.a` + `liblibsimple_darlingserver.a`, exactly what
  the Rust daemon consumes via `DUCT_TAPE_LIB`. This re-orders Phase 1/2 (the MIG
  spike still comes first, since duct-tape needs 45 `.defs` generated) but defers
  reexport/install_name/firstpass until the guest tier.

Progress:

- **Phase 0 DONE** (`buck2 build //src/libsimple:libsimple_darlingserver`).
  Produces `liblibsimple_darlingserver.a` (14 exported symbols) in ~1 s, from
  source, via one `clang -c` per file plus `ar`. Header-scoping model verified on
  the real command line: the only `-I` is the target's staged include dir, so no
  source directory is on the search path and wall #1 cannot happen by
  construction.
- Gotcha found: buck2's default `notify` file watcher registers one recursive
  watch on the project root BEFORE `[project] ignore` applies, so it walks the
  `result-*` symlinks into the nix store and dies on a mode-000 dir inside a
  built prefix. Fixed with `[buck2] file_watcher = fs_hash_crawler`, which honors
  the ignore list (and, being content-hashing, also ignores pure `touch`es).
- **Parity check passed**: the buck2-built `liblibsimple_darlingserver.a` is
  **byte-identical** to the one the reference nix/cmake build produces.
- **MIG toolchain DONE** (`buck2 build //buck-src:migcom`, runs, reports 1.0).
  bison + flex + 14 compiles + link, ~1 s incremental. `mig.sh` is used as-is
  (it accepts `-cc`/`-migcom`), so the cmake build's awk-generated `build-mig`
  wrapper is not needed.

- **MIG codegen DONE** (Phase 1.1). 35 `.defs` generate under buck2 (two of the
  CMakeLists' 45 `mig()` calls name files that do not exist -- dead edges cmake
  tolerates because nothing consumes them, which buck2 rejects eagerly at
  analysis, so the generator skips them and says so).
  - The `notify.h` collision the nix-ninja notes describe is REAL and confirmed
    here: mig re-emits `mach/notify.h` with 0 `MACH_NOTIFY_*` defines while the
    hand-written source header has 11. Under buck2 it needs no fix: each mig
    target generates into its OWN directory, which becomes its own include root
    ordered after the source roots, so `<mach/notify.h>` keeps resolving to the
    authoritative source header. nix-ninja needed a source-restore hack because
    its merged `$out` cannot hold both.
  - Generated sources must be compiled by a target that sees EVERY mig root at
    once (a generated stub reaches hand-written xnu headers that include other
    definitions' generated headers, e.g. `restartable_server.c` ->
    `kern/restartable.h` -> generated `mach/task.h`). So `mig_gen` exports its
    generated sources rather than compiling them, and one `cc_objects` target
    compiles them all. cmake gets this for free by dumping every mig output into
    one binary dir.
- **duct-tape DONE**: `buck2 build //src/external/darlingserver/duct-tape:darlingserver_duct_tape`
  produces `libdarlingserver_duct_tape.a` -- 93 members (66 hand-written + 26
  generated + 1 for `pthread/kern_synch.c`, which needs its own `-I`), 2777
  defined symbols. The BUCK file is
  GENERATED by `scripts/gen-duct-tape-buck.py` from the CMakeLists (135 paths, 45
  mig calls, 108 defines: exactly the drift-prone transcription the plan says to
  generate).
- **duct-tape parity vs the reference nix/cmake build: SEMANTICALLY IDENTICAL.**
  Same 93 members with the same names, same 2777 defined symbols, **zero**
  difference in the symbol sets. The archives differ by 2768 bytes, and that is
  fully explained: 55 objects contain XNU assertion strings that embed the source
  path, and the reference records its build-sandbox path
  (`/build/darling-src/src/.../condvar.c`) where buck2 records the
  project-relative one (`src/.../condvar.c`). Nothing else differs. buck2's form
  is arguably the better one, being independent of where the tree lives.
- `//linux/server:duct_tape_lib` stages both archives into the single directory
  the Rust daemon's `build.rs` expects in `DUCT_TAPE_LIB`.
- **END-TO-END VERIFIED BY EXECUTION.** With `DUCT_TAPE_LIB` pointed at that
  staged dir, `cargo build` links `darlingserverd` (4.3 MB, 105 `dtape_*` symbols,
  plus XNU's `ipc_kmsg_send` and `libsimple_lock_lock`), and the crate's
  `dtape-link-proof` bin RUNS the buck2-built duct-tape: it walks the whole init
  path (`ipc_init`, `waitq_bootstrap`, `mig_init` with 281 kobjects, `clock_init`,
  `turnstiles_init`, `thread_call_initialize`) and prints
  `STAGE0_OK: linked real duct-tape and ran dtape_init via the sched lib`,
  exit 0. (The "Trying to lock mutex without an active thread!" lines are
  expected: phase 1 of duct-tape's two-phase init runs off a kernel microthread.)

### Guest tier (Darwin/Mach-O) started

- **Phase 1.4 (cross-arch + SDK) PROVEN for compile + archive.**
  `buck2 build //src/libsimple:libsimple_darling` cross-compiles the SAME
  `src/lock.c` for Darwin and archives it: the member is a
  `Mach-O 64-bit x86_64 object` exporting `_libsimple_lock_lock` (Darwin's
  leading-underscore mangling), i.e. the toolchain really targeted Darwin.
- A toolchain here turned out to need no new provider: `cc_toolchain` is a bundle
  of tools plus flags, and `darwin_cc` differs from `native_cc` only in its
  values (`-target x86_64-apple-darwin20 -arch x86_64
  -mmacosx-version-min=11.0`, and a Mach-O archiver). The rules' `toolchain`
  attribute is what a target picks; keeping the two as separate targets is what
  makes it impossible for a host compile to inherit guest flags or header roots.
- The reference build passes `-B <cctools misc>` to guest COMPILES as well; with
  clang's integrated assembler a `-c` compile never shells out, so it is treated
  as a link-time flag here.
- `//darwin:sdk_env` is the guest compile environment (the Darwin defines plus the
  SDK include roots in the reference build's order), so a guest target depends on
  one target rather than restating it.
- Two SDK findings while wiring it:
  - The farm is not all symlinks: **32 headers are real files committed inside the
    SDK tree** (`sys/_symbol_aliasing.h`, `sys/_posix_availability.h`, `float.h`,
    ...) against 1987 symlinks. They belong to the SDK directory's own buck2
    package, so the generator emits them as a separate list consumed by a header
    root there.
  - Three trees under `src/external` are COMMITTED rather than pinned
    (`darlingserver`, `libtrace`, `libpthread_workqueue`), so SDK links into them
    (e.g. `os/log.h`) must not be rewritten into `buck-src`. The generator now
    verifies each mapped path exists and reports what it skipped, grouped by
    owning tree -- 111 headers across ~20 packages, to be declared on demand.
- `scripts/buck-src.sh --all` materializes all 147 pinned trees (3.8 GB) out of
  the nix-assembled tree in one step, which is what the SDK root needs.
- Open: the Mach-O archiver is `llvm-ar` (overridable via `[darling] darwin_ar`).
  The reference uses cctools' `x86_64-apple-darwin20-ar`, which
  `nix/cctools-port.nix` does not export yet; it exports ld/lipo only
  (install_name_tool and nmedit report "not built").

### Phases 1.2 and 1.3 ANSWERED: the biggest risk is not a problem

The plan's go/no-go gate was whether the firstpass two-pass link can be expressed
in Buck2 at all, with the fallback being to keep libSystem on nix-ninja and start
Buck2 above it. **That fallback is not needed.** Both idioms are proven, with real
Mach-O output, by `tests/buck2/firstpass` (a fixture of two mutually dependent
dylibs plus an umbrella) and `buck/rules/darwin.bzl`:

- **Reading the reference dissolved most of the difficulty.** `add_circular` in
  `cmake/darling_lib.cmake` builds each library TWICE from the SAME objects: a
  firstpass linked `-Wl,-flat_namespace -Wl,-undefined,suppress` (resolving
  nothing), then the real one linked against its siblings' firstpass dylibs. So
  the ARTIFACT graph is already acyclic. There is no two-pass protocol to invent,
  only a flag and a dependency edge.
- The single translation constraint: a circular library must be TWO TARGETS, not
  one rule emitting both passes. With one rule, `a` naming `b` and `b` naming `a`
  is a cyclic TARGET graph, which buck2 rejects even though the artifacts are
  fine. cmake makes two targets for the same reason.
- **Verified in the output**, which is the part that matters: `liba.dylib` links
  against `libb_firstpass.dylib` but records `LC_LOAD_DYLIB =
  /usr/lib/system/libb.dylib`, the sibling's INSTALL_NAME. That is the entire
  trick of the mechanism, and it works: `_b_value` is a normal two-level import
  that resolves to the real libb at runtime.
- **install_name** flows through as `LC_ID_DYLIB` (`-Wl,-dylib_install_name`), and
  **reexport** produces real `LC_REEXPORT_DYLIB` entries: the fixture's umbrella
  reexports both members and comes out `NOUNDEFS|DYLDLINK|TWOLEVEL`, which is the
  shape of `libSystem.B.dylib`.
- `-dylib_file <install_name>:<path>` is what lets a link resolve an install_name
  to a file that is not where it will live. cmake keeps ONE GLOBAL map of every
  firstpass dylib and passes the whole thing to every link; here each target
  contributes its own mapping through a provider, so a link carries only the
  mappings for libraries it actually depends on. Same effect, honest dependency
  edges.

Three concrete things that had to be learned by running it:

1. `-fuse-ld=` accepts a linker NAME or an ABSOLUTE path only, and a Starlark rule
   cannot compute the project root. `-B <dir>` alone does not work either: clang
   looks for plain `ld` there, while cctools installs `x86_64-apple-darwin20-ld`,
   so the link silently fell through to the host linker (which then rejected every
   Mach-O flag). Fixed by `scripts/buck-setup.sh` writing the nix store path into
   `.buckconfig.local`, which is machine-local and gitignored. Store paths are
   immutable, so it only needs regenerating when the derivation changes.
2. `-nostdlib` is required: clang's Darwin driver adds `-lSystem` otherwise, and
   libSystem is the thing being built. The reference passes it too.
3. Any cross-dylib call needs `dyld_stub_binder` in the link, and the real symbol
   has NO leading underscore (`.globl dyld_stub_binder` in dyld's
   `src/dyld_stub_binder.S`), so a plain C function is the wrong symbol. The real
   build gets it via the `-dylib_file` map pointing at the built libSystem; the
   fixture supplies its own with an asm label. `-Wl,-bind_at_load` does NOT avoid
   the need for it.

### Phase 2 under way: the libSystem tier

`scripts/gen-buck-from-ninja.py` emits Buck2 targets for a cmake target straight
out of the reference `build.ninja` (exact sources, defines, flags, include roots,
link command, including everything inherited from parent cmake scopes), with
`--write` placing each block in the package that owns its sources. That is what
makes the tier tractable: 286 cmake targets exist, and transcribing them by hand
is not a plan. It reports what it cannot know rather than guessing -- sources and
include dirs that live in the cmake BINARY dir are generated and come out as TODO
comments.

Ported so far as **firstpass** dylibs, each verified as a Mach-O dylib carrying
the reference `install_name`:

| Member | Sources | Note |
|---|---|---|
| `libsystem_blocks` | 3 | first one; C + Objective-C + C++ in one library |
| `libkeymgr` | 1 | |
| `libsystem_pthread` | 13 | includes hand-written assembly; 191 exports |
| `libsystem_malloc` | 19 | |
| `libsystem_duct` | 8 | |
| `libsystem_coreservices` | 3 | |
| `libsystem_trace` | 8 | needs the Foundation + CoreFoundation frameworks |
| `libsystem_asl` | 14 | needs GUEST-side MIG (`asl_ipc.defs`) |
| `libsystem_coretls` | 31 | needs the Security + CoreFoundation frameworks |
| **`libsystem_c`** | **641 objects, 43 object libraries** | 1359 exported symbols, 1.35 MB |

Only firstpass, and that is not a shortcut: a firstpass link resolves nothing by
design, so it is exactly the pass that can be built before its siblings exist.
A FINAL pass now needs only `libsystem_kernel` (MIG plus syscall-stub generation),
since `libsystem_c` is done.

**`libsystem_c` took three findings, each of which would have produced a subtly
wrong library rather than a build error:**

1. **Per-source flags are load-bearing.** A cmake target does not compile every
   source the same way: `SET_SOURCE_FILES_PROPERTIES` gives individual libc files
   their own `-DLIBC_ALIAS_*` (which decides SYMBOL ALIASING) and their own
   `-include` shim. `libc-gen` alone is 108 sources in **25 distinct flag groups**.
   Reading flags off one edge -- the obvious implementation -- would have compiled
   and linked, and produced a libc with the wrong symbols. The generator now groups
   sources by their exact flag set, and each group becomes its own `cc_objects`
   target; the dylib takes them all. That fixed 26 of the 30 libc failures at once.
2. **A `-include` argument is a header the target NEEDS.** The reference spells it
   as an absolute nix store path, so passing the flag through verbatim both leaks a
   store path into the build and leaves the header undeclared. They become
   `prefix_headers` (real artifacts) instead. libc depends on this: `gen/__dirent.h`
   is a `#define` shim renaming `dd_*` to `__dd_*`, force-included into every
   `*dir.c`, and without it those sources do not match the public `dirent.h`
   (66 `no member named 'dd_td'` errors). A bare NAME rather than a path
   (`-include __dirent.h`) is different again: it resolves through the include path,
   so it stays a flag.
3. **WHICH object libraries a dylib links is not "all of them".** libc ships
   ALTERNATES of the same sources -- the `_dyld` variants exist for
   libsystem_dyld -- so linking every `libc-*` group gives **190 duplicate
   symbols**. The reference link edge is the authority on the subset, and the
   generator now resolves a dylib's object libraries from it.

### libsystem_kernel (libsyscall): 548 of 562 sources compile

The last member gating a FINAL pass. 562 sources in 5 flag groups, and 56 MIG
targets, all of which generate.

- **MIG here runs the same definitions THREE times** with different suffix sets
  (headers, then per-arch sources, then `_internal.h` headers), and pass 2 is
  MULTIARCH (`i386` + `x86_64`). That needed no rule support at all: the arch
  infix rides in the suffix (`-x86_64-User.c`), so `mig_gen` expresses it as-is.
  `scripts/gen-mig-from-ninja.py` derives all 56 from the reference's own edges by
  subtracting the stem from each output name, rather than re-deriving the three
  passes from the CMakeLists.
- **The include ORDER finding, which matters for every target.** The reference does
  NOT put a target's own include dirs first. It interleaves: some come BEFORE the
  shared environment (SDK, basic-headers, frameworks) and others AFTER it.
  libsyscall proves why that is load-bearing: `xnu/osfmk` sits after the SDK there,
  so `<mach/mach.h>` resolves to the SDK's GUEST copy. Hoisting all own roots above
  the env -- which is what the rules did -- picked up XNU's KERNEL
  `mach_interface.h`, which includes `<mach/clock_reply_server.h>`, a header only
  the kernel-side (duct-tape) MIG produces. That single ordering fix took libsyscall
  from 68 failures to 14, and it changes header precedence for every generated
  target (the whole suite was re-verified after it).
- Remaining 14 failures are three missing include roots (`tsd.h`,
  `stack_logging_internal.h`, `CoreFoundation/CoreFoundation.h`), i.e. the same
  demand-driven "declare what this target includes" work, not a new class.

**KNOWN FAILURE: `libsystem_pthread`'s firstpass dylib no longer links.** Its 13
object groups all compile, but the link hits `illegal text reloc in
'_pthread_key_delete' to '__pthread_list_lock'`. This appeared when the generator
started honoring the reference's PER-SOURCE flags -- previously every source got
the first edge's flags, which is wrong but happened to avoid it. The reference does
not hit it despite identical compile AND link flags, so its objects differ in a way
not yet understood, and `-Wl,-read_only_relocs,suppress` is not available on
x86_64. Recorded rather than papered over: the test suite asserts the objects
compile and does not assert the dylib links.

Open: `libkqueue` (the 44th object library libsystem_c links) does not compile.
Its XNU-emulation headers need an include ordering this port has not worked out
(`struct kevent64_s` comes out incomplete, `uint16_t` undeclared). libsystem_c is
otherwise complete, and the firstpass dylib links without it.

All three of the failures recorded earlier are now fixed, and each turned out to
be a real finding:

1. **The framework surface.** `#include <Foundation/NSString.h>` resolves through
   `darwin/framework-include`, whose entries are symlinks named after the
   framework, chaining `Foundation.framework/Headers` -> `Versions/C/Headers` ->
   the pinned tree. 17,399 framework headers in all. They are staged as **one root
   per framework** (~200 targets, generated by three lines of Starlark per
   package), NOT as one big root: the reference build puts all 141 frameworks on
   every Darwin compile's path, whereas here a target names the ones it includes
   and so cannot silently start depending on a framework it never declared.
2. **`libsystem_asl` was not missing `-fblocks`** (blocks are on by default for a
   Darwin target; the reference does not pass it either). The real error was
   `uint32_t` undeclared, and the cause was **`libcxx/include` appearing TWICE on
   the command line** -- once from the generator, once from `sdk_env`. libcxx's
   `stdint.h` defers to the next `stdint.h` on the path via `#include_next`, and
   with two staged copies of the same directory it found ITSELF instead of the
   SDK's, so the integer types were never defined. Duplicate include roots are not
   merely redundant, they break `include_next` chains.
3. `libsystem_coretls` needed the Security and CoreFoundation frameworks, not a
   corecrypto fix.

Also: asl's `<asl_ipc.h>` is generated by GUEST-side MIG (the default
`cmake/mig.cmake` suffixes and the Darwin compile environment, as against the XNU
one duct-tape uses). That include is exactly where nix-ninja's full-graph build
stalls -- its `-I` for `asl_ipc.h` resolves at subgraph scope but comes back empty
at full-graph scope. Under Buck2 it is just a dependency edge, and the header is
only on the include path of targets that declare it.

Two workflow lessons for the generator:

- `--write` replaces a generated block wholesale, so hand-added deps inside one are
  lost on the next run. They live in `buck/generated/extra-deps.json` instead,
  which also puts every "this target needs that framework" decision in one
  reviewable place.
- `scripts/buck-fix-loads.py` must strip ONLY the `//buck/rules` loads it manages.
  An earlier version stripped every load and removed the generated-SDK-map and
  toolchain loads; the test suite caught it immediately.

**The loop, measured** (this is what the port is for):

| Action | fs_hash_crawler | **watchman** | commands run |
|---|---|---|---|
| no-op | 2.9 s | **0.01 s** | 0 |
| edit one `.c` (1 of 93 objects) | 2.6 s | **0.32 s** | 1 |
| edit `duct-tape.h` (full fan-out) | 4.8 s | **2.59 s** | 128 |

Today's equivalent inner loop is the coarse `packages.darlingserver` nix build at
~5-6 minutes for any edit. So a one-file change goes from minutes to **0.32 s**.

The file watcher turned out to matter as much as the build graph. All three
backends were tried: `notify` (buck2's default) cannot even start here, because
it registers one recursive watch on the project root before `[project] ignore`
applies and walks the `result-*` symlinks into the nix store (EACCES on a
mode-000 dir inside a built prefix); `fs_hash_crawler` works but re-hashes the
tree every command, which cost ~2.9 s once `buck-src` held 107 MB of materialized
pins (real build inputs, so they cannot be ignored); watchman does not descend
into symlinks and keeps state between commands. See `.watchmanconfig`.

Also worth recording: a comment-only edit to migcom's `utils.c` re-ran exactly
ONE action. The recompile produced a byte-identical `.o`, so buck2's
content-based dependencies correctly did not re-link migcom, re-run any of the 35
MIG codegens, or recompile the 26 generated sources.

Two structural findings, both about source availability rather than Buck2:

1. **The working copy is not a complete source tree.** 147 upstream trees are nix
   pins with no checkout, so a direct `buck2 build` cannot see them.
   `scripts/buck-src.sh` materializes the ones we need into `buck-src/<name>/`
   (gitignored, same pinned rev+hash nix uses, `patches/<name>/*.patch` applied
   the same way `darling-src.nix` does). `buck-src` and `buck-out` are excluded
   from `darling-src.nix`'s source filter, or every nix build would rehash on
   hundreds of MB of buck2 scratch.
2. **The SDK symlink farm cannot be reused as-is, and should not be.**
   `darwin/Developer/.../MacOSX.sdk/usr/include` is ~1900 committed relative
   symlinks into `src/external/<pin>/...`; in the working copy 1909 of them
   dangle. They are also not reproducible by any prefix rule, because the SDK
   MERGES trees (`i386/` = xnu/bsd/i386 + xnu/osfmk/i386; `libkern/` = xnu +
   libplatform + libc). So `scripts/gen-sdk-header-roots.py` reads that farm (it
   is the authority on the layout) and emits explicit `{include path -> source
   file}` maps, consumed by `cc_header_root(header_map = ...)`. 613 mappings so
   far (mach, i386, machine, libkern, sys). This scales to the guest tier by
   generating more namespaces, with no hand-derivation and no giant
   materialization.

   Note this is also where wall #1 dies for real: the SDK namespaces are staged
   as their own roots, so a project source dir is never on the same `-I` path,
   and a host tool only gets the four `sys/` entries the reference gives it
   rather than all of Darwin's `sys/*.h` shadowing glibc's.

## Phase 0 — Buck2 stands up, builds one real library, directly (no Nix)

Goal: prove the toolchain end-to-end on one leaf, fast, outside Nix.

1. **Get buck2 + a prelude.** Use `buck2` from nixpkgs (`pkgs.buck2`) via a
   devshell so it is on `PATH` — no need to vendor a binary. Add a minimal
   prelude (or fork the prelude's cxx rules), a `.buckconfig` at the repo root,
   and iterate with `buck2 build` directly. The nixpkgs binary is the same
   `buck2` Phase 3 reuses under Nix, so the toolchain is reproducible from day 1
   even while we iterate outside a derivation.
2. **Define the Darling toolchain as Buck2 rules.** This is where wall #1 dies.
   - the cross clang targeting `x86_64-apple-darwin20`, with the darwin SDK as an
     explicit `--sysroot`/`-isysroot` (NOT a globbed `-I`), so system `<endian.h>`
     resolves to the SDK, never a project header;
   - `system_lib`/`exported_headers` boundaries so project headers are visible
     only to declared consumers;
   - the darling `-D` defines + the platform/arch selects.
3. **Port ONE leaf target by hand** to exercise the toolchain. Candidate:
   `libsimple` or a small `system_cmds` tool (few files, no MIG, no firstpass).
   Write its `BUCK` (`cxx_library`/`cxx_binary`, `srcs`, `headers`,
   `exported_headers`, `deps`). Get `buck2 build //path:target` green from source.

Deliverable: `buck2 build` produces one real Darling artifact from source, and
the toolchain + header-scoping model is proven. This is the go/no-go gate.

## Phase 1 — Spike the hard machinery (feasibility before scale)

Each is a focused, throwaway-ok spike proving Buck2 can express the pattern.
Do them in this order (increasing risk):

1. **MIG codegen.** A `genrule` (or custom rule) running `build-mig` over a
   `.defs` to emit `*_user.c`/`*_server.c`/headers; wire the outputs as `srcs` +
   `exported_headers` of the consuming library. Verify a duct-tape-style consumer
   compiles against the generated `mach/notify.h` (note: keep the hand-written
   source `notify.h` and the mig user header at DISTINCT header roots — Buck2's
   per-target header maps make this natural, unlike nix-ninja's merged `$out`).
2. **Reexport / install_name.** Prove `-reexport_library`, `-install_name`,
   `-umbrella` flow through `cxx_library` linker_flags (or a thin linker
   wrapper). Small: one lib reexporting one other.
3. **Firstpass two-pass link (HIGHEST RISK).** The libSystem umbrella cycle:
   express `X_firstpass.dylib` stubs (link with stubbed/`-undefined
   dynamic_lookup` symbols), the umbrella `libSystem.B.dylib` reexporting all
   firstpass libs, and final `X.dylib` linking the umbrella. This is a real DAG
   once firstpass != final are distinct targets, so Buck2 should handle it — but
   it is the thing most likely to need a custom rule. Spike with libSystem +
   2-3 sub-libs (libc, libnotify) before trusting the pattern.
4. **Cross-arch + SDK.** Confirm the toolchain select builds `x86_64` (and later
   `arm64`) with the right sysroot and codesign/lipo steps if needed.

Deliverable: a documented Buck2 idiom for each of MIG, reexport, firstpass, and
cross-arch. If firstpass cannot be expressed cleanly, that is the signal to keep
libSystem on nix-ninja and start Buck2 above it.

## Phase 2 — Gradual project porting, iterating with Buck2 directly

Port demand-first, dependency-order within each demand.

1. **Bootstrap with a generator, refine by hand.** Write a `graph-json -> BUCK`
   emitter (reuse `rust-ninja -t graph-json`, already in overby) that produces a
   first-cut `BUCK` per CMake target (srcs, the declared deps, the command's real
   `-I`/link flags). It will be imperfect (the same undeclared deps nix-ninja
   guesses), but it turns "author 100 files" into "review + fix N files."
   Hand-refine the targets we own into clean, explicit `cxx_library`s.
2. **Order:** the libSystem tier first (it is everyone's dep and the boundary we
   care about), then only the projects we actually develop. Leave the rest on the
   dense build.
3. **Keep the fallback.** Everything not yet in Buck2 keeps building via
   dense/nix-ninja; the two coexist (Buck2 artifacts can consume nix-built
   prebuilt dylibs as `prebuilt_cxx_library` at the boundary). This is what makes
   the port gradual instead of all-or-nothing.
4. **Fast loop:** `buck2 build` with the daemon; edit a `.c`, rebuild only its
   action + dependents. This is the payoff — validate it feels fast on the
   first-party subtree before widening.

Deliverable: the actively-developed subtree (first-party + libSystem) builds and
rebuilds fast under a direct `buck2` daemon; the boundary to the cached dense
build is a set of `prebuilt_cxx_library` targets.

## Phase 3 — Integrate with Nix

Now make the Buck2 build reproducible/cacheable without giving up the daemon.

1. **Point overby `buildBuck2Project` at Darling.** overby's `nix/lib/buck2`
   already lowers Buck2 actions to per-action Nix derivations (the Buck2 analog
   of what we just upstreamed for ninja). Feed it Darling's BUCK targets ->
   `nix build .#darling-buck2` yields the same artifacts, per-action cached +
   shared via Cachix, no `buck2` daemon needed in CI.
2. **Two-mode dev:** local = `buck2` daemon (fast, incremental); CI/shared =
   Nix-lowered (hermetic, cached). Same BUCK definitions feed both.
3. **Retire nix-ninja for the ported subtree**, keep it for the un-ported dense
   tail until (if ever) that tail is worth porting.

Deliverable: one BUCK source of truth; `buck2` for local iteration, Nix-lowered
Buck2 for reproducible/cached builds; nix-ninja scoped to the unported remainder.

---

## Sequencing summary

| Phase | Outcome | Gate |
|---|---|---|
| 0 | Toolchain + one leaf lib green under `buck2`, direct | header-scoping model works |
| 1 | MIG / reexport / firstpass / cross-arch idioms proven | firstpass expressible? |
| 2 | Actively-developed subtree fast under `buck2` daemon | daemon loop feels fast |
| 3 | Same BUCK reproducible/cached via overby `buildBuck2Project` | parity with dense artifacts |

## Explicit non-goals

- Porting the stable upstream framework tier (Security/CF/Foundation/CLI tools)
  wholesale. Cache the dense build for those; port on demand only.
- Maintaining a hand-written BUCK definition for code we do not edit (it drifts).
  Generated-and-refined only.
- Replacing the dense `.#default` build, which stays the whole-tree build of
  record until the Buck2 port demonstrably covers what we need.

## Biggest risk

The **firstpass two-pass link** (Phase 1.3). It is the one Darling idiom that is
genuinely awkward in any explicit build system. Spike it before committing to the
port; if it resists a clean Buck2 expression, draw the Buck2/nix-ninja boundary
*above* libSystem and port only the tiers that iterate.
