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
  source bugs to find** -- only build-definition work. A Buck2 port is about
  expressing Darling's build *correctly and explicitly*, not fixing Darling.
- The genuinely hard parts to express in ANY system are: (1) MIG codegen, (2) the
  firstpass two-pass link that breaks the libSystem umbrella cycle, (3)
  reexport / `install_name` machinery, (4) the darwin SDK sysroot + cross-arch
  (`x86_64-apple-darwin20`) toolchain, (5) the darling header shims. Spike these
  before mass porting (Phase 1) -- they decide feasibility.
- Hand-written BUCK for upstream code **drifts** on every Darling bump. Mitigate
  with a CMake/ninja -> BUCK *generator* (reuse `rust-ninja -t graph-json`) to
  bootstrap targets, then hand-refine the ones we own. Generated where it drifts,
  hand-authored where we iterate.

---

## Status log

### 2026-07-30 -- the whole circular cluster links, and libSystem closes over it

29 circular members, both passes, all generated from the reference graph:
`scripts/regen-dylibs.py` enumerates the members out of build.ninja, generates the
firstpass/final pair for each, and iterates to a fixpoint (a pass can only name
siblings whose targets already exist). Every hand-written dylib block is gone.

  * 30 firstpass dylibs link (29 members + libsystem_coreservices)
  * 28 finals link, including **libSystem.B.dylib**, which reexports 26 members
  * 2 finals are blocked on libraries OUTSIDE the cluster, and only those:
    `objc_final` (libc++, libc++abi) and `resolv-darwin_final` (libsystem_dnssd,
    libsystem_configuration). Both are asserted as still-blocked by the suite, so
    the list cannot rot.

What had to become generator features, each one a class of silent wrongness:

  * **Siblings on BOTH passes.** libc's firstpass links libplatform's, which is how
    a client of libsystem_c resolves `_strcmp` -- ld64 finds it in the indirect
    dylib. Emitting siblings only on the final pass left 14 members undefined.
  * **Siblings are not always firstpass dylibs.** libsystem_notify's and
    libsystem_sandbox's finals link the FINAL libsystem_c/libsystem_kernel.
  * **`-Wl,-alias_list` and friends.** libplatform defines `_platform_strcmp` and
    answers to `_strcmp` only through its alias list; the flag carries a FILE, so
    `darwin_dylib` gained `link_flag_files` and the file travels as an input.
  * **Link semantics come from the edge, not from `firstpass`.** libunwind's and
    libclosure's FINAL passes are linked `-flat_namespace -undefined,suppress` in
    the reference; the rule assumed only firstpasses were.
  * **A reexport implies the load.** Naming a library as both sibling and reexport
    made ld64 keep the plain mention: libSystem came out with 27 LC_LOAD_DYLIBs and
    zero LC_REEXPORT_DYLIBs.
  * **Names carry hyphens and dots** (`resolv-darwin_firstpass`, `libresolv.9.dylib`).
    `[A-Za-z0-9_]+` silently dropped those siblings.
  * **Object libraries with no target of their own** (`libsyscall_64`, `asl_ipc_user`
    hold only mig-generated sources their sibling compiles) -> `OBJLIB_ALIASES`;
    object groups this port adds (the kernel's `emulation_rpc_obj`) -> `objs:` and
    `dep:` entries in extra-deps.json.
  * **Sibling include dirs must stay siblings.** A staged header's own
    `#include "../lib/x.h"` resolves relative to the staged copy, so
    `cc_header_root` gained `include_subdirs` (one tree, -I into each subdir).
  * **The SDK map dropped directory symlinks into committed repo trees**, silently
    losing the whole `opendirectory/` namespace that Libinfo includes.

84 checks pass.

### 2026-07-30 (later) -- the layer outside the cluster, and every dylib links

libc++, libc++abi, libsystem_dnssd, libsystem_configuration, libquarantine,
libremovefile, libcopyfile and libsystem_networkextension are ported, which closes
the last two finals: **72 of 72 dylib targets link, nothing is expected to fail.**
libobjc.A.dylib defines `_objc_msgSend`, and libSystem.B.dylib reexports 33 members.

Three more generator features, same pattern (each one silently wrong before):

  * **Single-pass libraries.** A library outside the cluster has no firstpass edge
    and its dylib is often named nothing like its cmake target (`system_copyfile`
    builds libcopyfile.dylib, `cxxabi_obj` builds libc++abi.dylib), so the edge is
    matched by OBJECT LIBRARY. Its target is `<base>_dylib`, not `<base>_final` --
    there is no second pass to distinguish it from.
  * **Sibling-vs-reexport is matched per LIBRARY, not per label.** The reference
    lists libsystem_malloc's FIRSTPASS among the umbrella's inputs and reexports its
    FINAL; comparing labels left both on the line, the plain mention won, and
    libc++abi could not resolve `_malloc` through libSystem.
  * **`regen-dylibs.py` regenerates everything with a `<t> dylibs` marker**, not just
    the graph's members: a stale label inside a non-member's block (libcopyfile
    naming `system_quarantine_final`) breaks every consumer of it.

Also: `Kernel/sys/decmpfs.h` joined the SDK ALIASES (copyfile includes it whenever
`VOL_CAP_FMT_DECMPFS_COMPRESSION` is defined, and darling's farm has no `Kernel/`),
and `-Wl,-dylib_file` is excluded from the file-bearing-flag report, which had buried
the real one (an alias list) under a hundred framework mappings.

83 checks pass.

### 2026-07-30 (later still) -- the first guest EXECUTABLES

`--binaries` generates a `darwin_binary` from an executable link edge the same way
`--dylibs` does a pair. Four link and are real Mach-O x86_64 `EXECUTE` images with
`NOUNDEFS`: **vchroot, notifyutil, launchproxy, opendirectoryd**.

Two things an executable needs that a dylib does not:

  * **csu's `start.S.o`, named directly on the link line.** It is passed in the
    reference's LINK_FLAGS, not among the edge inputs, and it is ONE source out of
    crt1.10.6's two flag groups -- so the generator resolves an explicitly-passed
    object to the group that actually contains that source (`obj_groups` exposes the
    per-group source lists for exactly this).
  * **`-nostdlib`**, for the same reason the dylib link needs it: clang's Darwin
    driver would otherwise reach for an `-lSystem` that no `-L` holds. The executable
    does need libSystem, and gets it as an explicit artifact through `dylibs`.

Two more infrastructure fixes, both silent-wrongness class:

  * buck2 refuses a symlink whose target has a `.` component ("path contains
    platform-specific path separator"), and corefoundation ships them
    (`CFArray.h -> include/CoreFoundation/./CFArray.h`). `scripts/buck-src.sh` now
    normalises those targets when materialising, and the existing trees were fixed.
  * A merged sibling include root projects one subdir per member, and buck2 errors on
    a projection that does not exist -- which is what an include dir holding no
    headers produces (launchd's `support`). Those are dropped from the merge now.

**Blocked, and only these two:** `dyld` links 17 `*_static*.a` archives (a whole
parallel static tier: libc_static, libsystem_kernel_static64, libcxx_static, ...),
and `plconvert` needs the CoreFoundation dylib. Both are asserted as still-blocked.

89 checks pass.

### 2026-07-30 (still later) -- the static tier, and dyld

**dyld links**: a Mach-O `DYLINKER` with `NOUNDEFS` that defines `__dyld_start`. It is
linked against no dylib at all -- the loader runs before any dylib is mapped -- so it
takes 17 static archives instead, and `--archives` generates a `cc_static_lib` from
each archive edge the same way the other modes do.

  * 16 archives generated (the 17th, libsimple's Darwin archive, already existed under
    a different artifact name: cmake doubles the "lib" for a target already called
    libsimple_darling, so `ARCHIVE_ALIASES` maps it).
  * 9 new object libraries for the static variants (cxx_static, platform_static64,
    pthread_static, emulation_dyld at 293 sources, system_m_static at 118, ...).
  * For archives the LINK ORDER is the resolution order, so a binary's `deps` are
    emitted in the order LINK_LIBRARIES names them.
  * The static kernel needs the generated rpc.c in a flag group of its OWN, exactly as
    the dylib tier does; `emulation_dyld_rpc_obj` is derived from the generated
    emulation_dyld block so its flags cannot drift from it.

One test-harness bug worth recording, because it made a symbol that IS present read as
missing: under `set -o pipefail`, `printf '%s\n' "$syms" | grep -q X` returns 141 once
the list outgrows the 64K pipe buffer -- grep exits on the first match and printf dies
of SIGPIPE. Small symbol lists happened to fit, so it only surfaced on dyld's 6703.
Every such check is a herestring now.

92 checks pass.

### 2026-07-30 (dawn) -- 29 executables, and the cctools suite

**29 guest executables link with nothing undefined**, plus dyld. The unlock was one
archive: `liblibstuff.a` (cctools' libstuff, 41 sources) alone blocked 20 of them, so
porting it turned 12 ready executables into 32. What links now includes the whole
cctools tool suite -- `strip`, `nm`, `otool`, `lipo`, `install_name_tool`, `libtool`,
`size`, `strings`, `segedit`, `pagestuff`, `redo_prebinding`, ... -- plus `syslog`,
`newsyslog`, `shellspawn`, `periodic-wrapper`, `vtool`.

  * memberd needed its own MIG (memberd.defs, both stubs compiled) and the
    DirectoryService header closure.
  * otool needed libc++abi named explicitly: `__cxa_demangle` lives there and the
    reference reaches it as an INDIRECT dylib through libc++'s load command alone. A
    `dylib:` entry in extra-deps.json says so out loud rather than relying on it.

**Blocked, and only these two:** memberd and plconvert, both on a FRAMEWORK BINARY
that is not ported (DirectoryService, CoreFoundation).

The suite's sweeps are by RULE KIND now (`kind('darwin_dylib', ...)`,
`kind('darwin_binary', ...)`) rather than by target name: `check_dylib` is an
executable whose name ends in `_dylib`, and the name match swept it into the dylib
checks. Kind queries also mean a new target of either shape is covered the moment it
exists.

91 checks pass.

### 2026-07-30 (morning) -- CoreFoundation, and nothing is blocked

**CoreFoundation links**, with the right framework install_name, and so do ICU
(libicucore.A.dylib, 446 sources) and the DirectoryService framework. With those three
in, **no target is blocked any more**: 74 dylibs and 31 executables, all with nothing
undefined.

A framework binary is a Mach-O dylib with NO extension at all, which broke two things
that keyed on the file suffix:

  * the edge matcher skipped it, so `--dylibs DirectoryService` found no link edge; a
    dylib link is now identified by its `-dylib_install_name` flag rather than by name.
  * `siblings_of` dropped it as an input, so memberd came out undefined against the
    `_ds*` functions that live in it.

And two escaping layers had to be peeled, in the right order, for CoreFoundation's
constant strings to work at all. `CFSTR()` references `___CFConstantStringClassReference`,
which nothing defines: the reference creates it on the link line with
`-Wl,-alias,_OBJC_CLASS_$___NSCFConstantString,___CFConstantStringClassReference`. In
build.ninja that is written `\$$`, because

  * ninja escapes a literal `$` as `$$` -- undone now for every var value in
    read_edges (exactly one occurrence in the whole graph, and it was this one), and
  * the shell then strips the backslash, so LINK_FLAGS has to be split with the
    SHELL-aware splitter, not `.split()`.

Passing either escape through hands ld64 a symbol name that does not exist, and the
alias silently does nothing.

93 checks pass.

### 2026-07-30 (later morning) -- 45 executables, 93 dylibs

Nine more libraries (libz, libbsm, libbz2, liblzma, libncurses, libcharset, libiconv,
libedit, libarchive) unblocked the rest of the tool tree: **45 guest executables link
with nothing undefined, and 93 dylibs**. New arrivals include launchctl, syslogd,
aslmanager, tcsh, bsdtar, cpio, bzip2, xz, and the terminfo tools (tic, infocmp, tput,
tset, toe, clear).

Three fixes worth recording:

  * **Sources included as headers.** ncurses' `include/capdefaults.c` and libedit's
    `local/historyn.c` doing `#include "./history.c"` both resolve through an -I of the
    SOURCE dir, so an include root that stages only `*.h` stages nothing they need.
    Root-level `*.c` is staged now (recursive would drag thousands of files into
    libc-sized roots).
  * **ninja's dependency markers are not inputs.** `|` and `||` were being read as
    library inputs once framework binaries (extensionless) became legal, so every
    executable reported them as missing libraries. They are stripped at parse time, and
    an extensionless input now counts as a library only when the registry knows it --
    a tool like `x86_64-apple-darwin20-ld` is not one.
  * **Two protocols can generate the same header.** liblaunch's `job.defs` and
    launchd's own `src/job.defs` both produce a bare `job.h`; naming both let the wrong
    one win by include order, which surfaced as `unknown type name 'job_t'`.

xnu's `mach/notify.defs` and `mach/mach_exc.defs` now have mig targets in buck-src (a
mig_gen's defs must be a source of the declaring package, and those live in the pins).

**Blocked:** launchd alone. Its MIG-generated server stubs use `job_t` from its own
core.h, and the include roots staged for the generated sources are not right yet. zsh
also needs its own codegen chain (`zsh.mdh`), and notifyd needs one more mig.

94 checks pass.

### 2026-07-30 (mid-morning) -- launchd and notifyd, the two MIG servers

**launchd links** (a Mach-O EXECUTE with NOUNDEFS, PIE), and so does **notifyd**: 47
executables and 93 dylibs. Neither was a matter of missing libraries -- both are MIG
SERVERS, and that surfaced two things a generator cannot guess:

  * **Which generated stub a protocol contributes is per-consumer.** launchd compiles
    `jobServer.c` (it serves that protocol) but `job_forwardUser.c` (it calls out on
    that one), and `internal.defs` contributes BOTH. Exporting both sides everywhere
    pulled in code needing types the includer never sees -- job_forwardServer.c wants
    `job_t`, which vproc_internal.h only declares once `job_MSG_COUNT` is defined. The
    reference's own unit list is the authority, and each mig_gen's `compile_srcs` now
    matches it exactly.
  * **The same .defs run twice is two targets.** notifyd generates `mach/notify.defs`
    with its own server prefix (`do_`), so it cannot share launchd's mig target: the
    subsystem symbol differs (`_do_notify_subsystem`).

And one more materialisation rule: buck2 also rejects a symlink whose target LEAVES the
cell, and libnotify ships `darling/src/notify.defs` pointing five levels up into the
repo's SDK farm -- a depth that only made sense in a different tree. Those are
re-pointed at the same file inside buck-src now (scripts/buck-src-normalise.py, which
buck-src.sh calls), together with the "." -component case.

95 checks pass.

### 2026-07-30 (late morning) -- 83% of the reference's link edges, measured

`scripts/buck-coverage.py` counts every LINK EDGE in the reference build.ninja and reports
which ones have a buck2 target, so progress is measured against the graph rather than a
hand-kept list: **107/120 dylibs, 48/51 executables, 18/37 archives -- 173/208 (83%)**.

The 28 xtrace stub dylibs were the bulk of the dylib gap. Each compiles exactly one
generated `<stem>XtraceMig.c` into its own little dylib that xtrace dlopens to decode
that protocol's messages, which needed three things:

  * **An [xtrace] SUBTARGET on mig_gen.** The stub source cannot go in `compile_srcs`,
    because that set is handed to the protocol's real consumer, which must not compile it.
  * **All-generated object libraries.** `generate()` used to give up when every source of
    a target was generated; it now keeps the reference's flags and include roots and takes
    the sources from a `gen:` entry. That is exactly the shape of an xtrace stub.
  * **Matching each stub to the right mig INSTANCE.** The same .defs is run by several
    targets (libsyscall runs mach/task.defs three times, duct-tape once for the kernel
    side), so only the output path identifies which one produces the stub -- and the name
    is relative to that target's output dir, keeping the protocol's own subdirectory
    (`mach/clockXtraceMig.c`). scripts/gen-xtrace-mig.py does that mapping; 28 of 31
    matched, and the 3 that did not need mig targets that do not exist yet (libdispatch's
    firehose pair and launchd's notify.defs instance).

Two smaller corrections: the legacy object-library path emitted a `_firstpass` dylib for
any target with a dylib edge, which for a single-pass library is a second link of the same
objects under a name nothing uses (it is emitted only when the reference HAS a firstpass
edge now); and these stubs have NO install_name at all in the reference, so the suite
asserts the Mach-O type for them instead.

95 checks pass, 121 dylibs and 47 executables link.

### 2026-07-30 (midday) -- 97% of the reference's link edges

**202 of 208 link edges are ported** (116/120 dylibs, 50/51 executables, 36/37 archives),
and the suite asserts that floor, so a regression that drops targets cannot pass
unnoticed. 129 dylibs and 49 executables link.

This round: csu's whole crt family (crt0, crt1, crt1.10.5/10.6, dylib1, dylib1.10.5,
lazydylib1, bundle1), libdispatch_static, libressl (libcrypto 543 sources, libssl, libtls)
and its compat archive, bash with its own bison grammar, openssl, the ncurses add-ons
(form, menu, panel), libcoretls, libobjc-trampolines and libgcc_s.

Two fixes:

  * **A dylib can link static archives too**, and the order LINK_LIBRARIES names them is
    the resolution order. libcrypto's `_explicit_bzero` lives in libressl's compat
    archive; without it the link fails on a symbol nothing else provides. Archives were
    only wired into binaries before.
  * The nested `label()` helper in the dylib generator is now `obj_label()`: three
    separate patches shadowed it with a local and turned it into a str mid-function.
    Renaming it removes the trap rather than fixing the third instance.

Coverage also stopped under-reporting the HOST tier: libdarlingserver_duct_tape.a and
liblibsimple_darlingserver.a are ported as cc_library targets that predate cc_static_lib,
so ARCHIVE_ALIASES maps them.

**What is left, and why:** libstdc++.6 (needs GCC's own libstdc++ header layout, including
its generated config headers), zsh (its own `zsh.mdh` codegen chain), the firehose pair and
launchd's notify.defs xtrace stubs (three mig instances that do not exist yet), and
libsystem_kernel_static32 (the i386 data-model variant; this port is x86_64-only).

96 checks pass.

### 2026-07-30 (afternoon) -- PHASE 3 starts: a Darling target built through Nix

`nix build .#darling-buck2-libsimple` produces `liblibsimple_darlingserver.a` with real
symbols, built by overby's `nix/lib/buck2`: the BUCK files are evaluated at Nix
evaluation time and every Buck2 ACTION becomes its own derivation. No buck2 daemon, no
import-from-derivation. This is the endpoint the port's hand-written, prelude-free rules
were kept reachable from, and the first proof it actually is.

Three gaps in overby's interpreter, found by lowering a real target rather than by
reading its code (pushed on that repo's `nix-lib-buck2` bookmark):

  * `read_root_config` / `read_config` were not defined at all. The port uses them for
    the toolchain's machine-local paths, so `.buckconfig` sections are threaded from
    analyze.nix through the loader to the globals, with `.buckconfig.local` layered on
    top the way buck2 layers it.
  * `ctx.actions.symlinked_dir` was missing, which is the action the whole header-staging
    design rests on.
  * `ctx.actions.copy_file` was serialized but never lowered, so it threw at build time.

Plus the archivers: a `cc_library`'s archive step runs bare `ar`, which is not the C
compiler and so was not in the toolchain map. overby's own four no_prelude checks still
pass.

The smoke target is deliberately the smallest real one (one C source, one include root,
one archive action). Scaling it up is the next step, and the guest tier will need the
Darwin toolchain's store paths to reach the lowered actions.

**Scaling it up hit an evaluator wall, and finding it took four fixes.** Anything that
loads the generated SDK maps (a 4178-entry dict) or lives in the 32k-line `buck-src/BUCK`
overflowed the Nix stack, because the interpreter ran one Nix function call per element
and Nix has no tail-call elimination. Now iterative, on overby's `nix-lib-buck2`:

  * the lexer's driver (one step per token) runs in bounded chunks;
  * the parser's dict-entry and statement-list loops use the same chunked iterator;
  * the evaluator's list, keyword-argument and dict literals use `foldl'`;
  * dict LOOKUP carried a recursive linear scan -- a dict now has a lazy index of its
    string keys, so repeated lookups are O(1) and recurse not at all.

Parsing and evaluating the 4300-line SDK map works after that. A target that pulls the
whole `//darwin:sdk_env` closure still does not, and the remaining suspect is the
O(n^2) list-append representation used while accumulating tokens and entries -- forcing
that chain is what overflows now, with no trace to name it. `nix build
.#darling-buck2-libsimple` is the target that works end to end today.

**A caution for the next iteration:** run these evaluations under a memory cap
(`systemd-run --user --scope -p MemoryMax=8G nix build ...`). An unbounded one was
OOM-killed twice here, which also takes the buck2 daemon with it -- and the daemon comes
back with whatever PATH restarted it, so `clang`/`bison`/`flex` must be on it (the dev
shell's PATH) or every action fails with "Failed to spawn a process".

### 2026-07-30 (later) -- what the Nix path actually needs, measured

Chunked token accumulation in the lexer landed (a growing `tokens ++ [tok]` is O(n^2) in
time and memory; tokens now accumulate per chunk and are joined once). It was not enough:
under an 8 GB cap, a 4.3k-line file evaluates comfortably and the 32k-line
`buck-src/BUCK` still does not. The AST of a 1.2 MB source file simply does not fit in
Nix values at that size.

So the fix is to stop asking it to: split the pins into one package each. That was tried
here and REVERTED, because it exposed the actual prerequisite --

  **a subpackage takes ownership of its files.** The moment `buck-src/ncurses/BUCK`
  exists, every file under `buck-src/ncurses/` belongs to that package, and the SDK
  header maps in `buck-src/BUCK` -- which name thousands of headers across every pin --
  can no longer reference them. They stop coercing, and with them every target that
  depends on `//darwin:sdk_env`.

`scripts/buck-split-pins.py` does the mechanical part (regenerate a pin's targets into
`buck-src/<pin>` and drop what is left behind), and `SPLIT_PINS` in the generator is the
switch, off until the prerequisite is met. Sizes, for planning: libc 11k lines, xnu 5.1k,
toolchains 4.3k, everything else under 1.2k.

`--pin-roots` does the first of those now: one `cc_header_root` per pin, declared inside
`buck-src/<pin>`, covering that pin's share of the SDK surface. 70 pins carry SDK headers
(xnu alone has 1289). `--apply` writes them; nothing is wired yet, because pointing
`//darwin:sdk_env` at 70 roots instead of the three monolithic maps changes the include
ORDER, which several targets depend on.

`scripts/buck-env.sh` is the other thing this needed: the buck2 daemon inherits the PATH
of whatever starts it, and a daemon that came back from an OOM without clang/bison/flex
fails every action with "Failed to spawn a process", which reads like a build error.
Source it before any buck2 command.

Migrating one pin end to end showed what the unit really is, and where it stops:

  * **Content-wise the split is safe.** No include path in the pinned SDK maps is claimed
    by two pins, and the 614 paths that appear in more than one map always name the same
    source, so per-pin roots cannot change what an include resolves to.
  * **A pin moves as one unit**: its SDK root, its generated blocks, its HAND-WRITTEN
    blocks (the mig targets naming its .defs), its removal from the monolithic maps, and
    every reference to the moved targets repointed. `scripts/buck-split-pins.py` does all
    of that now, and `buck/generated/split-pins.txt` records what has moved so
    `gen-sdk-header-roots.py` leaves those pins out of the monolithic maps.
  * **What still blocks it: cross-pin FILE references.** libsystem_notify force-includes
    xnu's `sys/fileport.h`; once libnotify is its own package that path no longer resolves
    from there. Every such reference needs an `export_file` in the owning package and a
    label -- the generator already has `CROSS_PACKAGE_FILES` for exactly this shape, so
    the fix is to populate it automatically during a migration.

`SPLIT_PINS` is off again and the trial reverted. 96 checks pass.

### 2026-07-30 (late morning) -- 99%: two targets left, one of them out of scope

**205 of 207 in-scope link edges** (119/120 dylibs, 50/51 executables, 36/36 archives).
All 31 xtrace stubs build now: the last three needed mig INSTANCES that did not exist --
libdispatch's firehose pair (nothing else compiles their stubs, so the targets exist for
the `[xtrace]` subtarget alone) and launchd's notify.defs, which reuses the buck-src
instance because the launchd-side `.defs` is a symlink into a submodule that is not
checked out here.

`libsystem_kernel_static32.a` is **out of scope, not missing**: its `libsyscall_32`
compiles the `-i386-User.c` mig stubs, and this port targets x86_64 only. The coverage
tool counts it separately with that reason, so "what is left" stays honest.

### 2026-07-30 (midday) -- 100% of the in-scope link edges

**206 of 206.** zsh links, and the two that do not are out of scope with the reason
recorded in `scripts/buck-coverage.py`:

  * `libstdc++.6.dylib` -- GCC 4.2.1's vendored headers do not compile against this SDK
    with clang at the `-std=c++14` the reference itself passes (const-correctness of
    memchr/strchr, conflicting using-declarations). Nothing links the result: only the
    aggregate `all` target names it.
  * `libsystem_kernel_static32.a` -- the i386 slice; its `libsyscall_32` compiles the
    `-i386-User.c` mig stubs and this port targets x86_64.

zsh needed no codegen after all: darling pre-generates `zsh.mdh` and friends into the pin
(`zsh/gen/Src`), so what was missing was STAGING, and it turned out to be two gaps in how
include roots are staged, both now detected rather than listed:

  * **Headers whose extension no fixed pattern would guess** (`.mdh`, `.pro`, `.epro`,
    `.tcc`) or that have NO extension at all (the C++ standard library's `vector`,
    `ext/rope`): such a root is staged whole.
  * **An ancestor root and a root inside it must share ONE staged tree.** zsh's
    `Src` headers reach `../config.h` in the tree above them, which only resolves if both
    live in the same staged copy -- the same rule that already applied to siblings.
    `include_subdirs` takes `"."` for the ancestor itself now.

### 2026-07-30 (early afternoon) -- the split needs a big bang, not a pin at a time

Cross-package FILE references are handled now: `file_label()` decides whether a file
attribute is package-relative or a label, consulting `buck/generated/split-pins.txt` so a
label never points at a package that does not exist yet, and `buck-split-pins.py` creates
the backing `export_file` in the owning package (verified: libnotify's migration produced
`//buck-src:xnu_bsd_sys_fileport.h` for the header libsystem_notify force-includes).

But migrating **one pin at a time does not work**, and this is the finding: a
dylib/archive/binary block names only LABELS, so it carries no path to recognise its pin
by -- and regenerating those blocks is GLOBAL. Running it after moving one pin moved all
47 dylib blocks into pin packages while their object blocks were still in buck-src, which
leaves every label dangling. Reverted; 96 checks pass.

So the split has to be a BIG BANG: flip `SPLIT_PINS`, regenerate every block, emit all 70
per-pin SDK roots, repoint `//darwin:sdk_env`, create every `export_file`, and drop what
moved -- all in one commit, iterating until the suite is green. That belongs in a
scratch WORKTREE rather than the live tree, since intermediate states do not build.

### 2026-07-30 (afternoon) -- the big bang, in flight

Measured first, because it decides whether the split achieves anything: **a 12k-line
package parses and evaluates inside 8 GB**, while the 32k-line `buck-src/BUCK` does not.
libc's package would be ~13.5k, the largest. So per-pin packages do fit.

Running in a jj workspace at `../darling-split` (its own 3.8 GB copy of the pins -- they
are gitignored, so a workspace does not get them, and hardlinks are refused because the
pins are read-only and the kernel has protected_hardlinks). It needs `.buckconfig.local`
and a `result-graph-ref` symlink copied in, both gitignored.

`scripts/buck-split-pins.py --all` moves **450 blocks into 81 pin packages** (libc 13.5k
lines, xnu 4.7k, everything else under 1.4k). One package still fails to parse, and the
cause is the same class each time: a **monolithic header map in buck-src/BUCK naming files
that now belong to a subpackage**. Four remain -- `sdk_basic_headers_pins`,
`sdk_darling_include`, `sdk_darling_include_mach`, and the framework roots.

The facade the split was waiting on turned out to be unnecessary. **A `header_map` value is
an `attrs.source()`, and a source coerces from a LABEL as readily as from a path.** So the
maps stay whole, stay in `buck-src/BUCK`, and keep staging ONE SDK tree in one include
order; only the spelling of a migrated pin's value changes:

    "stdio.h": "libc/include/stdio.h"
    "stdio.h": "//buck-src/libc:include_stdio.h"

Proved on a scratch package before anything moved (`cc_header_root` with a single
cross-package label value builds and stages a symlink to the real file). That kills the
per-pin roots, the key transformations, and the sdk_env repointing all at once.

### 2026-07-30 (evening) -- the split, landed

`buck-src/BUCK`: **33,161 lines -> 8,924**, with 172 blocks and 49 hand-written targets in
**42 pin packages** (libc 12.4k lines, xnu 4.1k, the rest under 1.2k). Suite green at 96
checks, coverage unchanged at 206/206 in-scope link edges.
(Corrected later: that denominator was wrong, and it was wrong every time it was
quoted. See "The coverage metric had a blind spot" at the end of this file.)

It MOVES blocks rather than regenerating them, and that was the pivotal decision: the
committed tree is **not a fixpoint of its own generator** -- regenerating every block
rewrites 216 of 367, because they were written by older versions of it. Some of those
rewrites do not compile (libc's separate include roots come back merged into one staged
tree with `.` on the path, and `libc-features.h` then fails its own feature check). Mixing
that with the split would have made a bad diff worse, so each block travels verbatim with
only the rewrites a package change forces. Making the tree a fixpoint again is real work,
and it is now written down as such rather than discovered mid-migration.

What the move has to get right, each learned from a failure:

- **Escaped quotes.** `"([^"]+)"` desynchronises on the first `\"`, and the flag lists are
  full of them (`-DMIG_VERSION=\"1.0\"`); after that its "strings" are the text BETWEEN
  strings. 4,976 quoted strings scanned down to 4 candidate paths, so almost nothing was
  seen as a path. Every scanner here now uses one escape-aware `STRING` regex.
- **Which pin owns a block** is the DOMINANT pin among its paths, not the first one seen:
  an xtrace stub compiles nothing from the tree, and its eight include roots all point into
  xnu. First-seen put those blocks in whichever pin sorted first.
- **Globs cannot cross a package**, so a block that globs a sibling pin stays behind (44
  do), and a header root inside one that globs a MIGRATED pin travels alone as a target
  (49 do). Individual FILE references are not blocking: those become labels.
- **`root` and `out_base` are not sources.** Labelling a directory turned libcxx's root
  into `root = "//buck-src/libcxx:include"`, which stages nothing and silently takes the
  C++ standard library off the search path. And the exact-pin rewrite has to run BEFORE the
  prefix strip, or a pin holding a directory of its own name loses it (libunwind's root is
  `libunwind/libunwind`).
- **mig names its outputs from `defs.short_path` minus `out_base`**, and a source's
  short_path is relative to the package that DECLARES it. Once `defs` is a label into a
  pin, `out_base` has to lose the same prefix, or every output keeps a directory no
  consumer names (`asl_ipcUser.c` became `libsystem_asl.tproj/asl_ipcUser.c`).
- **Visibility cuts both ways**: a moved target needs `PUBLIC` to stay reachable from
  buck-src, and a target that stayed needs it the moment a pin package names it.
- **The suite holds labels too**, unquoted, so the repointer rewrites `scripts/buck-test.sh`
  as well -- a stale label there reads as a regression rather than as a rename. Its
  kind-sweeps became recursive (`//buck-src/...`), or they miss every moved dylib.
- **A label needs an export_file in the owner.** `scripts/buck-exports.py` keeps those
  lists: one line per file in `buck/generated/exports_<pin>.bzl`, declared by a
  comprehension in the pin's BUCK. One 5-line `export_file` block per file would have added
  ~30k lines and put the biggest pins back over the evaluator's budget. Resolving a name
  back to its file has to follow symlinked DIRECTORIES (libunwind reaches part of its own
  tree that way) with a BRANCH-local loop guard, since a pin reaches the same files under
  two names and a label minted from either spelling has to resolve. buck-src itself cannot
  be indexed by walking it, so whoever mints a label into it records the path in
  `buck/generated/export-hints.json`.
- `buck-src/.gitignore` had to un-ignore `/*/` and `/*/BUCK`, anchored -- unanchored, the
  `!.gitignore` exception swept in all 59 of the pins' own ignore files.

Found on the way, NOT caused by the split and left alone: `//darwin/Developer:` has never
parsed. Its `fw_*` roots name files that are symlinks into `src/libacm` and friends, and
buck2 rejects a source whose symlink leaves the package. Nothing depends on those targets,
which is why the suite is green without them.

Still to do here: 44 blocks that glob a sibling pin (cctools/libcxxabi, libcxx/libcxxabi
both ways, libarchive/icu, corefoundation/foundation) could move once their foreign glob
becomes a dep on a root in the owning pin; and the generator should learn to emit a
cross-pin include root as a separate target in the owning package, so regenerating a
migrated pin's block does not undo the split.

### 2026-07-30 (evening) -- phase 3 changes course: ONE opt-in IFD

Measured, since it decides the architecture (`NIX_SHOW_STATS`, `MemoryMax=8G`, IFD off):

| target | evaluator CPU | values | calls | GC heap reported |
| --- | --- | --- | --- | --- |
| `//src/libsimple:libsimple_darlingserver` (3 actions) | 8.7s | 1.9M | 1.4M | 0.40 GB |
| `//src/duct:system_duct_static` (+ `//darwin:sdk_env`, 4,178 map entries) | 82.5s | 47.7M | 69.5M | 18.2 GB |

25x the values and 50x the calls for one step up in size, and `//darwin:sdk_env` dominates
both. The port has 206 in-scope link edges and thousands of actions, so interpreting the
Starlark IN NIX does not extrapolate: it is not the memory ceiling any more (the split
fixed that), it is the cost per target and a steady supply of fresh walls in the
interpreter. Three were fixed today alone -- a `for` statement and a comprehension each
recursed once per iteration (`max-call-depth`, not slowness), and `foldl'` alone does not
help until each step also forces the accumulated list and env, or the same overflow
reappears one step later inside `dict.items()`.

**So the decision changes: use ONE opt-in import-from-derivation, the way overby's
`nix/lib/cargo` does it.** That library is strictly IFD-free by default with a single
documented exception -- a pure derivation extracts the metadata and Nix reads it -- which
is exactly the shape this needs:

1. a pure derivation runs REAL buck2 over the hermetic source (`nix/lib/darling-src.nix`
   already assembles all 147 pins, which also settles the gitignored-pins wall the pure
   path hit) and dumps the ACTION GRAPH as JSON;
2. Nix reads that one file (the IFD) and lowers each action to its own derivation, exactly
   as today -- overby's `build/lower.nix` already consumes a graph attrset, so the half
   that carries the value is kept;
3. the pure-Nix Starlark interpreter leaves the evaluation path. It stays useful as a
   checked, IFD-free mode for small targets, and the walls found through it were real
   interpreter bugs worth fixing upstream regardless.

Where the argv comes from, settled by probing all three (`buck/bxl/probe.bxl` records it):

- `buck2 aquery --output-all-attributes --json` renders `cmd` as a Rust debug string
  (`"[ar, rcsD, <path>]"`), lossy for any argument holding a comma or a space -- and this
  port passes plenty (`-Wl,-alias_list,<file>`, quoted defines). Unusable as-is.
- **BXL is no better in this buck2.** An `ActionQueryNode` exposes only
  `["action", "analysis", "attrs", "rule_type"]`; `attrs` carries the same debug-string
  `cmd`, and `.action` is an opaque handle whose `dir()` is empty. So a BXL dumper would
  have to re-derive the commands, which means duplicating every rule's `cmd_args`.
- **`buck2 log what-ran --format json` gives the real thing**: per action, the identity
  (target + category + identifier) and a reproducer holding `command` as a LIST and the
  full `env`. Faithful, and no rule changes.

The catch AS IT STOOD THEN, since the aquery entry below removes it: what-ran reports what EXECUTED, so a graph dumped this
way costs a full build inside the derivation, and the per-action derivations then redo that
work once each. Two shapes follow from it:

1. **Graph then lower** (the cargo analogue). One derivation builds and dumps what-ran; Nix
   reads it and gives every action its own derivation. Pays a double build whenever the
   graph changes, and buys per-action caching and sharing through a binary cache -- which is
   the reason for the Nix endpoint in the first place.
2. **One derivation, no IFD at all.** It runs buck2 over the hermetic pinned source and
   installs the outputs. A fraction of the work, and the usual shape for a build system
   inside Nix, but the graph is opaque to Nix: no per-action caching, and a one-line change
   rebuilds everything.

Either way `buck2 log what-ran` is the interface, and the hand-written prelude-free rules
and the daemon path do not change: the same BUCK files stay the single definition, and
`scripts/buck-test.sh` stays the gate.

**Shape 1 is what got built, and it works end to end.** `nix build .#darling-buck2-lowered`
produces `liblibsimple_darlingserver.a` **byte-identical** to the one the buck2 daemon
builds, through: a pure derivation that runs buck2 (`nix/lib/darlingBuck2Graph.nix`), one
`builtins.fromJSON` of its `graph.json`, and one derivation per action
(`nix/lib/darlingBuck2Lower.nix`). No Starlark is interpreted in Nix.

Three buck2 interfaces are needed, and `scripts/buck2-graph-dump.py` is the one place that
joins them, because no single one answers everything:

- `log what-ran --format json` gives the faithful argv and env, but only for actions that
  RAN a command -- it is silent about the ones buck2 performs in-process, and the port's
  header staging is exactly those (`symlinked_dir`).
- `audit output <path>` says which action produced a buck-out path. That is what separates
  an action's own OUTPUTS from what it consumes, which no argv makes explicit: a target's
  compile and its archive both name the object file, and only one writes it.
- `aquery` carries every action's kind AND both naming schemes, so it is what joins
  what-ran's `T (category identifier)` to audit's `(target: T, id: N)`.

In-process artifacts are copied out DEREFERENCED, because a staged include root is a farm
of relative symlinks into the project and those mean nothing once the tree is a store path.

Two things buck2 needs before it will start inside a build sandbox, both surprises:
it builds an HTTP client while starting its daemon and dies without a CA bundle even though
nothing is fetched, and it insists on watchman unless the config says
`file_watcher = notify`.

### 2026-07-30 (evening) -- the endpoint on a target that needs the pins

`nix build .#darling-buck2-migcom` builds **migcom**, the MIG compiler every codegen edge in
the port runs: 12 compiles plus bison plus flex plus the link, each its own Nix derivation,
from one graph dump. It runs (`migcom -h` prints migcom's own error), and it needs the pins,
which is what makes it the real test.

Three things that took finding:

- **A target's outputs come from the build report**, not from what-ran or aquery: those talk
  about actions, and an action's outputs carry no note of which target asked for them.
  `--build-report=<path>` gives `results.<label>.outputs.DEFAULT`, so the lowerer can offer
  `byTarget.<label>` with the artifact under its own name.
- **Any buck-src target needs ALL the pins.** Loading that package coerces the SDK maps,
  3,591 source paths across 70 pins, so there is no partial materialization: the graph
  derivation takes `allPins = true` and reads the list from `nix/submodules.json` (a source
  file, so no second import-from-derivation). Copying them costs ~80s with `--reflink=auto`.
- **The per-pin split changed how the pins have to be copied.** `buck-src/<pin>/BUCK` is
  committed now, so the destination directory already exists and `cp -a src dest` nests the
  whole tree one level down as `buck-src/<pin>/<pin>`. It copies CONTENTS instead.

The action derivations stage the project as SYMLINKS rather than copying it: an action only
reads project files, and copying the repo plus 4 GB of pins into each of hundreds of action
derivations would cost far more than the build it replaces. The pin symlinks deliberately
overwrite the ones pointing at the committed `buck-src/<pin>/BUCK`, because an action needs
sources, not BUCK files.

**The double-build cost, measured on migcom**: the graph derivation takes ~50s (pin
materialization plus buck2's own build of the target) and lowering the same graph takes ~35s,
so the endpoint costs roughly 1.7x a plain buck2 build the first time and nothing after, as
long as the graph does not change. libsimple's archive comes out byte-identical to the
daemon's; migcom's binary does not, and that is the link embedding different absolute paths,
not a difference in what was compiled.

Neither the hand-written prelude-free rules nor the daemon path changes: the same BUCK
files stay the single definition, and `scripts/buck-test.sh` stays the gate.

### 2026-07-30 (night) -- the endpoint lowers per TARGET, and what is left

Decided after asking what the lowering actually buys: **one derivation per TARGET, not per
action.** Per-action is the finer cache and it is what got built first, but the port has on
the order of 15,000 actions, and Nix pays an instantiation, a sandbox and a store round trip
for each -- too much at that count, and the per-derivation overhead is exactly the sort of
cost this course change existed to escape. Targets are a couple of hundred, which Nix is
comfortable with, and a target is the unit a person reasons about.

The granularity that costs is cheap here for a second reason: **most of these targets are
pinned upstream trees nobody edits**, so their derivations stay cached indefinitely and the
coarser rebuild only ever hits the handful of first-party targets under active work.

An honest note on what the endpoint is FOR, because it decides everything above. Running
buck2 in a single derivation would be far less machinery, and for an unchanged tree it caches
just as well. The per-target split earns its keep only on CHANGE: a contributor who edits one
target pulls every other target from the binary cache instead of rebuilding the world. That
is also why the graph has to become reusable across edits -- see below -- or the endpoint
pays for a full buck2 build on every source change and the split buys nothing.

Remaining work, in the order it should be done:

1. ~~**Prove the target-level path**~~ DONE. All three probes build per target: libsimple's
   archive, migcom (which runs), and libsystem_blocks.dylib -- a real Mach-O with the
   install_name /usr/lib/system/libsystem_blocks.dylib and the Block runtime's symbols.
   Three bugs stood in the way, all one shape: buck2 assumes a mutable buck-out, and Nix
   hands back read-only store outputs. `compgen` is a bash builtin that runCommand's shell
   does not have; `cp --no-preserve=mode` stripped migcom's executable bit, which surfaced
   two layers away as a clang backend crash on a broken pipe; and a store copy reproduces
   read-only DIRECTORIES, so the second dependency staged could not write into parents the
   first had created -- directories are made writable after each copy now, not at the end.
2. **Key the graph on the build DEFINITION, not on file contents.** An action's argv depends
   on file names and flags, never on what is inside a file. Half done:

   * The graph is now MACHINE-INDEPENDENT, which is the prerequisite. Measured rather than
     assumed: across 1,669 actions exactly three store paths appear -- clang (1,606
     references), the wrapper's resource root (1,606) and Darling's ld64 (12) -- so the dump
     replaces each with a named placeholder and the consumer fills it from its own inputs.
     Zero store paths survive, and the dumper reports any that would, since a silent one is
     a machine dependency nobody notices until the cache misses.
   * What remains is to stop the graph derivation depending on source CONTENTS. The clean
     form, and the one that matches this port's conventions, is to COMMIT graph.json the way
     sdk_headers.bzl, extra-deps.json and the export lists are committed, and regenerate it
     with a script when the build definition changes. That removes the IFD entirely, and
     editing code becomes a cache hit rather than a full buck2 build. It is also exactly
     what nix/lib/cargo does: a committed snapshot by default, IFD as the opt-in exception.
3. ~~**Filter `darling-src`'s baseSrc**~~ DONE, and the claim it rests on was too broad:
   `nix/`, `docs/` and the buck2 trees were already excluded, so editing the Nix never
   re-assembled anything. Editing the port's own definitions did, though -- so `buck/`,
   `scripts/`, `plan/`, `tests/` and the buck2 configs are excluded too, none of which the
   cmake build reads. The graph derivation's own source is filtered the same way, so
   editing the plan or the Nix that CONSUMES the graph no longer invalidates the graph and
   costs a full buck2 build to rediscover commands that did not change.
4. ~~**Scale to the whole graph**~~ DONE for the suite's target set, which is the one already
   known to build and spans host tier, guest tier, MIG and the firstpass/final pair.
   `nix build .#darling-buck2-all` asks for 29 targets and gets 29 named artifacts, lowered
   from **259 target derivations over 2,066 actions** -- the ratio that makes per-target the
   right unit, since 2,066 derivations would not have been comfortable. libsystem_kernel and
   libsystem_blocks come out as Mach-O dylibs with their install_names, dserverdbg as a host
   ELF executable.

   The measurements that bound the design: graph.json is 33.9 MB and the staged artifacts
   196 MB for those 29 targets (26.4 MB and 147 MB for a single dylib). Widening to all 206
   in-scope link edges is a matter of the target list, but expect the graph output to grow
   in proportion -- it is firmly a derivation output, never a committed file.
5. ~~**Gate it**~~ DONE: `checks.buck2-endpoint` builds libsimple through the whole pipeline
   -- buck2 in a pure derivation, the graph dump, the placeholder round trip, one derivation
   per target -- and asserts the archive really carries libsimple's symbols. Deliberately the
   pin-free end: a guest target would drag in the 4 GB pin materialization and stop being a
   gate anyone runs.
6. **How it sits next to the existing paths.** DECIDED, and the comparison is not flattering
   in one respect worth stating plainly.

   `nix/lib/darlingNinja.nix` (nix-ninja) solves the SAME problem from the cmake side: one
   Nix derivation per ninja EDGE, cached independently, shareable through Cachix. It is
   finer-grained than this endpoint and it has a structural advantage that cannot be
   matched here: **ninja publishes its graph as a FILE**. `build.ninja` exists after a cheap
   cmake configure, without compiling anything, so nix-ninja pays no double build and a code
   edit does not invalidate the graph. buck2 has no such artifact -- aquery and BXL render
   commands as a lossy debug string, and `log what-ran` only reports what executed -- so
   this endpoint has to run a build to learn the commands. That is the whole reason it costs
   a double build and cannot be incremental locally.

   That is one axis, and taken alone it flatters nix-ninja. On the axis that decides whether
   a fine-grained cache is SOUND, it goes the other way, and this repo documents it in its
   own words. A ninja edge carries a command, not a complete dependency statement: header
   dependencies are discovered from depfiles AFTER compiling, and every target compiles
   against one global include set, so nothing stops an edge reading a header nobody declared
   it needs. `nix/lib/darlingNinja.nix` pays for that twice over -- it re-provides every
   configure buildInput in EVERY edge's sandbox because the graph does not say which edges
   need them, and it patches compile definitions into the duct-tape because "nix-ninja's
   merged tree does not always deliver those kernel mach headers to a mig user-stub's
   per-edge compile", which produced a link failure rather than a cache miss.

   buck2 declares and ENFORCES inputs. A rule's sources, its deps and its staged include
   roots are explicit -- 573 to 638 staged roots in these graphs, first-class artifacts
   rather than a shared -I set -- so a target derivation here receives exactly what the
   target is allowed to read, and nothing had to be over-provided or patched to make the
   endpoint work. That is also what made the per-pin split meaningful: the boundaries are
   real, and buck2 rejects a package that reaches across one.

   So the trade is graph availability against soundness. Ninja hands over its graph for
   free but understates dependencies, which a cache can only compensate for by hashing too
   much (killing reuse) or too little (wrong hits). Buck2 makes the graph expensive to
   extract but states dependencies completely, which is what a cache actually needs. For
   publishing, where a wrong hit is worse than a slow build, that argues for this endpoint
   despite the double build -- and the choice still follows the build definition: nix-ninja
   while cmake is the authority, this endpoint for the buck2 tree.

   `darling-base` is orthogonal and stays: it is a COMPONENT-scope cache (toolchain, SDK
   staging, core libSystem as one derivation) for the cmake build, not a per-unit one.

   What this endpoint is FOR, stated once: reproducible, cacheable, shareable builds of the
   buck2 tree -- CI and publishing, where a contributor pulls every target they did not
   touch from a binary cache. The inner loop stays on the buck2 daemon, which is what
   `scripts/buck-test.sh` gates.

Two pieces of port-side debt stay on the list, independent of the endpoint: the generator is
not a fixpoint of the committed tree (216 of 367 blocks regenerate differently, some of them
not compiling), and 44 blocks still glob a sibling pin instead of depending on a root in it.


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

### libsystem_kernel DONE, and THE FINAL PASS WORKS

`libsystem_kernel_firstpass.dylib` links: 1343 exported symbols including
`_mach_msg`, `_mach_task_self_`, `___syscall`, `_mmap`, `_kevent`. It is built from
three cmake object libraries (libsyscall's 562 sources in 5 flag groups,
libsyscall_dynamic, and the 293-source `emulation` layer); the reference's fourth,
`libsyscall_64`, is not a separate target here because its sources are ALL
mig-generated `-x86_64-User.c` files that libsyscall already compiles through
`gen_srcs`.

**`//buck-src:system_blocks_final` is the first FINAL-pass link**, and it is what
phase 2 was for. libsystem_blocks linked against its four siblings' FIRSTPASS
dylibs (kernel, malloc, pthread, c), exactly as `add_circular` does. What proves
the mechanism is not that it links, but what it recorded:

- `LC_ID_DYLIB` = `/usr/lib/system/libsystem_blocks.dylib`
- four `LC_LOAD_DYLIB` entries naming the siblings' **install_names**, not the
  firstpass paths it actually linked against
- **zero undefined symbols**

So the plan's "highest risk" item is now demonstrated on real libSystem members,
not just a fixture.

**The kernel's own FINAL pass links too** (`//buck-src:system_kernel_final`,
`libsystem_kernel.dylib`, 919 KB, 1357 exports): it records libsystem_c,
libcompiler_rt and libdyld by install_name, and its remaining undefined symbols are
two-level imports from those siblings. Getting there needed two things the
firstpass pass had been hiding, both of which only a final link can reveal:

1. The ~30 `_dserver_rpc_*` symbols come from the GENERATED `rpc.c`, which the
   generator had dropped as "a generated source". Adding it was not enough: the
   reference force-includes `dserver-rpc-defs.h` into that ONE file, without which
   it hits its own `#error Missing definitions`. So it needs its own flag group
   (`emulation_rpc_obj`) rather than joining an existing one.
2. libsystem_kernel links libsimple's DARWIN archive, which has to be on the link
   line.

`libkqueue` now compiles as well (the symlink-dereference and glob fixes were what
it needed), so **libsystem_c is complete at all 44 object libraries** (1369
exports). Four more members are ported as firstpass dylibs: libsystem_platform,
libcompiler_rt, libsystem_dyld, and libsystem_m's objects (its dylib link is still
open).

Getting libsyscall + emulation compiling turned up four more findings:

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
- **ALL 562 sources now compile.** Closing the last 14 turned up the sharpest
  gotcha of the port so far: **buck2 does not `glob()` through a symlinked
  DIRECTORY.** It treats it as one opaque entry, so a header root pointing at one
  stages EMPTY -- while explicit sources through the same symlink still resolve,
  which is exactly what made it confusing (the `.c` files in that directory
  compiled fine; only the headers went missing). The materialized pins contain
  3861 symlinks, and
  `xnu/darling/src/libsystem_kernel/libsyscall -> xnu/libsyscall` is one of them.
  The generator now dereferences a root to its real directory. That fixed 12 of
  the 14; the last 2 just needed the CoreFoundation framework declared.
- Also fixed while here: `glob(["dir/**/*.h"])` does NOT match `dir/x.h` in buck2 --
  it requires at least one intermediate directory. Every generated root was
  therefore missing the headers sitting directly in it, so roots now glob both
  patterns.
- **Flag strings are SHELL-quoted.** ninja hands its command to `/bin/sh`, so
  cmake's escapes are load-bearing: `-DEMULATED_OSPRODUCTVERSION=\"14.4.1\"` and
  `-DEMULATED_VERSION="\"Darwin Kernel Version 23.4.0\""` are each ONE argument
  whose value CONTAINS double quotes (they expand to C string literals). A naive
  splitter drops the quotes (so the macro is no longer a string) or splits the
  second on its spaces. The generator now splits with shell rules and re-escapes
  for Starlark.
- **A root in another package cannot be globbed from here.** `emulation` wants
  `src/libsimple/include`, which the `buck-src` package cannot reach; such roots are
  now mapped to the target that already declares them
  (`//src/libsimple:libsimple_headers`) instead of emitting a glob that silently
  stages nothing.
- Darling's emulation layer **`#include`s `.c` files** by path
  (`<darling/emulation/.../setattrlist_generic.c>`), so the SDK map now carries `.c`
  as well as headers, and the root staging that tree globs sources too.
- `configure_file` (a new rule) generates `darling-config.h` the way cmake does:
  `${VAR}` / `@VAR@` substitution plus `#cmakedefine`. GIT_BRANCH and
  GIT_COMMIT_HASH are deliberately left empty rather than shelled out to git --
  baking VCS state into a header would invalidate every object that includes it on
  every commit.

**The pthread "text reloc" was my own bug, and it was hiding a worse one.**
`libsystem_pthread`'s dylib failed with `illegal text reloc in
'_pthread_key_delete' to '__pthread_list_lock'`. The symbol is defined by the
target's own `pthread.c` -- but per-source flag grouping had split the cmake object
library into SEVEN buck targets, and the dylib named only the first. So the object
defining the symbol was never linked in.

The failure mode worth remembering: naming one group **still links**. `libsystem_c`
was fine only because its object list was expanded deliberately;
`libsystem_malloc`'s dylib had been linking all along while silently missing a
group's symbols (99 exports after the fix). A dylib that links is not evidence that
its objects are all there, so the generator now expands each cmake object library
into all of its flag-group targets, and the suite asserts symbols from more than one
group (`_pthread_create` and `__pthread_list_lock` come from different groups).



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

## Phase 0 -- Buck2 stands up, builds one real library, directly (no Nix)

Goal: prove the toolchain end-to-end on one leaf, fast, outside Nix.

1. **Get buck2 + a prelude.** Use `buck2` from nixpkgs (`pkgs.buck2`) via a
   devshell so it is on `PATH` -- no need to vendor a binary. Add a minimal
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

## Phase 1 -- Spike the hard machinery (feasibility before scale)

Each is a focused, throwaway-ok spike proving Buck2 can express the pattern.
Do them in this order (increasing risk):

1. **MIG codegen.** A `genrule` (or custom rule) running `build-mig` over a
   `.defs` to emit `*_user.c`/`*_server.c`/headers; wire the outputs as `srcs` +
   `exported_headers` of the consuming library. Verify a duct-tape-style consumer
   compiles against the generated `mach/notify.h` (note: keep the hand-written
   source `notify.h` and the mig user header at DISTINCT header roots -- Buck2's
   per-target header maps make this natural, unlike nix-ninja's merged `$out`).
2. **Reexport / install_name.** Prove `-reexport_library`, `-install_name`,
   `-umbrella` flow through `cxx_library` linker_flags (or a thin linker
   wrapper). Small: one lib reexporting one other.
3. **Firstpass two-pass link (HIGHEST RISK).** The libSystem umbrella cycle:
   express `X_firstpass.dylib` stubs (link with stubbed/`-undefined
   dynamic_lookup` symbols), the umbrella `libSystem.B.dylib` reexporting all
   firstpass libs, and final `X.dylib` linking the umbrella. This is a real DAG
   once firstpass != final are distinct targets, so Buck2 should handle it -- but
   it is the thing most likely to need a custom rule. Spike with libSystem +
   2-3 sub-libs (libc, libnotify) before trusting the pattern.
4. **Cross-arch + SDK.** Confirm the toolchain select builds `x86_64` (and later
   `arm64`) with the right sysroot and codesign/lipo steps if needed.

Deliverable: a documented Buck2 idiom for each of MIG, reexport, firstpass, and
cross-arch. If firstpass cannot be expressed cleanly, that is the signal to keep
libSystem on nix-ninja and start Buck2 above it.

## Phase 2 -- Gradual project porting, iterating with Buck2 directly

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
   action + dependents. This is the payoff -- validate it feels fast on the
   first-party subtree before widening.

Deliverable: the actively-developed subtree (first-party + libSystem) builds and
rebuilds fast under a direct `buck2` daemon; the boundary to the cached dense
build is a set of `prebuilt_cxx_library` targets.

## Phase 3 -- Integrate with Nix

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


### 2026-07-30 (night) -- the double build is GONE: the graph comes from analysis

The graph derivation no longer compiles anything to learn what the commands are. Verified on
the exact graph the whole-port build consumed: **2,066 command actions recorded, zero
compiles inside the derivation**, no missing artifacts, and all 29 targets build from it.

This started as "how big a task is it to patch buck2 to emit structured commands". The patch
is one line: `aquery_attributes` already resolves the real argv into a `Vec<String>` with
paths mapped, then destroys it with `format!("[{}]", join(", "))`. Shipping it is the
expensive half, because nixpkgs ships buck2 as a prebuilt binary on purpose -- "the upstream
codebase extensively uses unstable rustc nightly features, and as a result can't be built
upstream in any sane manner" -- so a patch means owning a from-source buck2 on a pinned
nightly forever, for one line.

So the cheaper question got asked first: is that join lossy IN PRACTICE here? No, and it is
measured rather than assumed. Reversing it reproduces what-ran's argv **exactly for 2,066 of
2,066 actions**, and **no argument anywhere contains the separator** -- the flags that carry
commas (-Wl,-alias_list,<file>) never carry comma-space. `buck2-graph-dump.py
--check-against-what-ran` re-runs that comparison and fails the dump if it ever stops
holding, so it stays a checked assumption rather than a hopeful one.

The dump is analysis-first now:

- `aquery --output-all-attributes` gives every action's command line without executing it.
- `targets --show-full-output` names each target's output, where the build report needed
  exactly the build being avoided.
- The artifacts buck2 makes IN-PROCESS are materialized by PROVIDER, through
  `buck/bxl/materialize.bxl`. Building their targets was the first attempt and it has a
  structural hole: **`buck2 build <target>` produces a target's DEFAULT output and nothing
  else.** darling-config.h is action id 2 of //src/include:darling_config, reachable through
  no subtarget and not on the default output's path, so it was absent when a consumer came
  to include it, and three targets failed a long way from the cause. Asking by provider
  works because the port's rules are its own: CcLibInfo carries the include dirs. That
  ensures 14,593 artifacts on the whole-port graph, against the 638 the target-building
  version reached, and still compiles nothing.
- Nothing is lost by dropping what-ran's env: the only keys buck2 set were TMPDIR and
  BUCK_SCRATCH_PATH, which each target derivation makes in its own sandbox anyway.

Two diagnostic lessons, both of which cost time here. A Nix log that ends without an error
means the builder was KILLED, not that the build was fine -- an 8 GB cap over hundreds of
parallel clang processes does that, and the cap that protects EVALUATION is the wrong cap
for a build. And the `MISSING artifact` line the dumper prints is what finally located the
darling-config.h hole, which argues for putting the diagnostic in before it is needed.

This also revises the nix-ninja comparison above. The double build was the main cost this
endpoint carried against it, and it is gone; ninja still publishes its graph for free, but
buck2 can now be asked for one at analysis time too, and buck2's graph remains the sounder
of the two because its inputs are declared and enforced rather than discovered from depfiles.

Upstream is still worth a report -- aquery's `cmd` is lossy by construction and its
inputs/outputs come back empty (facebook/buck2 issue 475, closed without a documented
resolution), where Bazel emits argv, inputs and outputs structurally. This port no longer
waits on it.


### 2026-07-30 (night) -- content addressing, as an OPT-IN

`darlingBuck2Lower.nix` takes `contentAddressed ? false`, the same shape nix/lib/cargo uses
for its one IFD exception: off by default, available to anyone whose Nix and cache support
it. Verified working -- with it on, Nix reports "resolved derivation" and the target builds
normally.

What it buys: early cutoff BETWEEN targets. A header edit that leaves a target's output
bit-identical stops propagating to that target's dependents rather than relinking the world.
That holds regardless of how the graph is consumed.

What it does not buy on its own: a cheap source edit. That needs the GRAPH derivation to be
content-addressed as well, which is the CA-plus-IFD pairing of NixOS/nix issue 5805 --
closed, but still tracked under the ca-derivations stabilisation milestone, which stood at
65% (56 closed, 29 open) in March 2026, with only FIXED content addressing stable and the
floating kind still experimental. Keeping the two separate lets the safe half be taken alone.

Why it is off by default, and why the endpoint should not depend on it:

- it needs `experimental-features = ca-derivations` on every machine that builds OR
  substitutes, and dynamic-derivations additionally requires ca-derivations, so the newer
  feature rests on the less-finished one;
- the binary cache is the crux. This endpoint exists so other people do not rebuild what
  they did not touch; a cache that cannot serve CA outputs removes the entire payoff, and
  that is the one thing to verify before relying on it;
- the benefit vanishes silently if outputs are not bit-reproducible, with no error to say so.

The route to a cheap source edit that needs NO experimental feature is still the better
default: record staged artifacts as symlink MAPS rather than dereferenced copies (they are
pure symlink farms -- 3,591 links and zero real files in the SDK root), after which nothing
in the dump reads a source byte, and the graph derivation can run on a names-only skeleton.
Content addressing then becomes an optimisation rather than the mechanism.


## The coverage metric had a blind spot: 208/248, not 206/206

Every progress report in this file, and several commit messages, quoted coverage against a
denominator the script computed for itself, by guessing each link edge's kind from its output
NAME: `.dylib` or a `-dylib_install_name` flag meant a dylib, `.a` an archive, and a basename
with no dot an executable. Guessing failed twice, in the same direction both times.

  * A loadable MODULE matches none of those. zsh's are `-shared` with no install name, and
    their basename contains a dot, so the executable test rejected them too. 70 edges, 35
    distinct modules, counted in NO category -- removed from the denominator as well as the
    numerator.
  * Recognising an executable additionally required LINK_FLAGS to be non-empty. cmake passes
    none when it links an ordinary HOST tool, so `src/hosttools/darling-coredump` and its
    neighbours vanished the same way.

Both are the same failure: an edge nothing recognises is an edge nobody counts, and the
output said 100% precisely because it was blind. The fix is to stop guessing. cmake already
states what each edge IS, in the ninja rule name, so classification now reads that:

    C_SHARED_LIBRARY_LINKER / CXX_...   -> dylib, or module when the output ends in .so
    C_EXECUTABLE_LINKER     / CXX_...   -> executable
    C_STATIC_LIBRARY_LINKER / ASM_...   -> archive
    phony                               -> not a link at all

That last line matters as much as the others. 105 edges with object inputs are cmake OBJECT
libraries, whose `.o` files are aggregated behind a phony and never linked; the LINK_FLAGS
test had been excluding them by accident, and dropping the test without reading the rule
briefly inflated the executable count from 51 to 166. Anything the rule table does not
recognise is now printed as UNCLASSIFIED rather than skipped.

True coverage:

    dylibs      119 / 119   (1 out of scope)
    exes         53 /  58   (3 out of scope)
    archives     36 /  36   (1 out of scope)
    modules       0 /  35
    total       208 / 248   (83%)

The 40 that are missing are 35 zsh modules and 5 host tools (bsdln, elfdep, getuuid, wrapgen,
darling-coredump). None is needed to build or run the system component: the host tools appear
in the reference only under cmake's own bookkeeping edges (edit_cache, rebuild_cache, install,
and `all` phonies), and darling-coredump is installed but never invoked by the build. The
three cctools binaries are newly marked out of scope because the port consumes ld64 from Nix
rather than building it -- which was always true and never shown.

The build work claimed is real, and two more targets turned out to be ported than the metric
knew (migcom and rtsig, which it looked for as `darwin_binary` while they are `cc_binary`).
What was wrong is the completeness claim on top of it. The gap does not block the bash
milestone, but it is the honest picture of where the port stands.

## The install rules: what a prefix is, generated from the manifests

Task #2 of the bash milestone. Darling's build product is not the 208 link outputs, it is a
PREFIX: a directory laid out so that dyld, launchd and bash can find each other. build.ninja
says nothing about it, because `install` is one opaque edge that shells out to
`cmake -P cmake_install.cmake`. The authoritative statement is the per-directory
cmake_install.cmake files cmake writes at configure time, and nix/lib/darling-graph.nix ships
all 145 of them, so scripts/gen-install-from-manifests.py can generate the layout from the
reference the same way every other block in this port is generated.

236 install entries for the system component. What they turn into:

    142  built artifacts   -> prefix_tree `entries`, resolved through the port's registries
     28  source files      -> prefix_tree `files`, as cross-package LABELS
      1  symlink           -> prefix_tree `symlinks` (bin/sh -> bin/bash)
      9  directories       -> a prefix_dir target in the owning pin, merged in as `trees`
      1  out of scope      -> libstdc++, which is not ported and which nothing links
     37  UNMAPPED          -> 35 zsh modules, the certs bundle, darling-coredump

Four things the manifests do not say, each of which had to be recovered from somewhere else:

  * WHAT A SYMLINK POINTS AT. cmake/InstallSymlink.cmake creates the link in the build
    directory and then install()s it as an ordinary FILE, so the manifest names bin/sh and is
    silent about its target. darling-graph.nix now records every build-tree link in
    install-symlinks.tsv, which is the only place the answer exists.
  * WHICH TARGET BUILDS A LIPO'D BINARY. CoreFoundation is installed under that name, but the
    linker's output is CoreFoundation_x86_64 and a cmake POST_BUILD lipo renames it. With one
    architecture that lipo is a rename, so the port installs the thin file under the name the
    destination gives it.
  * THAT A FILE IS GENERATED, NOT BUILT. icudt66l.dat is `xz -d` of a committed .dat.xz,
    a CUSTOM_COMMAND rather than a link edge, so no registry knows it. Ported as a new
    stdout_gen rule, which is the missing shape next to host_gen (output as the last
    argument) and script_gen (outputs as argv).
  * WHERE A SOURCE FILE MAY BE NAMED FROM. buck/prefix owns none of these files, and a source
    attribute has to name a file of the package that DECLARES it, so all 28 travel as labels
    backed by export_file: through scripts/buck-exports.py for a split pin, through
    export-hints.json for a pin still inside the buck-src mega-package (libkqueue, vim), and
    through a generated block for the few outside the pins entirely (launchd's man pages,
    shellspawn's plist, etc/resolv.conf, which needed a package of its own).

The one design decision worth recording: a prefix_dir hands the prefix_tree its FILES, not
its directory. cmake's install(DIRECTORY) merges -- zsh installs the contents of
gen/install-this/ straight into libexec/darling, which already holds bin/ and usr/ -- and
symlinked_dir rejects overlapping destinations, correctly, since a symlink at libexec/darling
would shadow everything under it. Expanding each tree into its files and merging path by path
keeps the whole prefix a single in-process symlink farm, with a hard failure if two entries
ever claim the same destination.

What is still missing from a faithful prefix, none of it needed for bash: the 35 zsh modules
(task #7), the openssl certificates bundle (a build-generated directory, so it needs its own
target), and darling-coredump (task #8).
