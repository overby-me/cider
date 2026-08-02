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

Removed. It was 1245 lines of dated entries, every one of which is the commit that
made the change: `jj log` or `git log`. What is still TRUE rather than historical
lives in the root PLAN.md, which carries the current numbers, the deliberate
divergences from the reference, and the traps that have each cost an increment.

This file keeps what PLAN.md does not: why the port exists and what done means, the
constraints learned from the nix-ninja grind, the phase plan, the non-goals, and the
writeups of the evaluation profiling and the VM harness.

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

## Booting it: what four runtime failures said about the port

Task #4 of the bash milestone is a check that boots the container and runs bash
(scripts/buck-bash-check.sh). It found four defects that nothing static had caught, which is
the argument for having it: every one of them passed analysis, linked cleanly, and produced
an artifact that looked right.

**1. The prefix had no empty directories.** The daemon died with "container: cannot mount
procfs". libexec/darling/proc comes from `install(DIRECTORY DESTINATION ...)` with no source
-- 17 of those, written into the manifest as `TYPE DIRECTORY FILES ""` -- and the generator
skipped every entry with an empty file list. Same failure mode as the coverage metric: a
parser that ignores what it does not recognise reports success.

**2. The prefix had none of the 74 symlinks the reference installs.** etc -> private/etc,
var -> private/var, private/etc/mtab -> /proc/self/mounts,
Volumes/DarlingEmulatedDrive -> /. These come from install(CODE) blocks running
`cmake -E create_symlink`, which the file(INSTALL ...) parser cannot see at all.

Both meant prefix_tree could no longer be a symlinked_dir, which maps destinations to
artifacts and expresses neither an empty directory nor a link to a path outside the tree. It
now builds from a MANIFEST -- dir, file and link entries -- and still links rather than
copies, so it costs the same.

**3. A prefix is not a tree that can be copied naively.** With
Volumes/DarlingEmulatedDrive -> /, `cp -aL` walks the whole machine; it had copied 82 GB
before being stopped. The two kinds of link have to be told apart, and the value alone does
not say which is which: an installed artifact points at an absolute host path, and so does
/proc/self/mounts. So the tree now carries its own manifest at .prefix-manifest.tsv, outside
what the container mounts, and scripts/buck-prefix-materialize.py follows only the links the
manifest does not declare.

**4. libc++abi was linked into libc++ as a plain dependency instead of a REEXPORT.** dyld
aborted with "initializer in image (libc++.1.dylib) that does not link with libSystem.dylib"
-- a misleading message: the real condition is that an initializer ran before libSystem's.
The reference passes `-Wl,-reexport_library,<path>`; the generator's reexport detector only
matched the other spelling, `-Wl,-reexport_library -Wl,<path>`, so the flag was silently
dropped and libc++abi was demoted to an ordinary sibling. cmake emits both forms, and every
Nix-built Darling in the store shows libc++abi as a reexport, which is what made the
difference visible.

The pattern in three of the four: a parser matched one spelling of something the reference
writes two ways, and said nothing about the rest.

### Where it stands, and what the abort turned out to be

With all four fixed, the prefix builds (5,536 files, 72 layout links, 567 directories), the
container comes up, the daemon serves its socket, the guest reaches darling_sigexc_self(),
and dyld loads 39 images. It then aborts running libc++'s initializer.

That abort is very likely NOT the port's. The evidence:

  * the buck2-built libc++.1.dylib and the CURRENT source's Nix-built one are structurally
    the same -- both carry an initializer section, both reexport libc++abi;
  * the tree that works (an older ~/darling-rt) has a libc++.1.dylib with NO initializers at
    all: there it is a stub that reexports libc++.2.dylib, a shape the current source no
    longer builds;
  * libobjc reaches libc++, and libdispatch, libsystem_trace and libxpc all pull in libobjc,
    identically in both trees -- so libc++ sits inside libSystem's own closure and its
    initializer necessarily runs before libSystem's, which is exactly what dyld refuses.

That reading was WRONG, and the control build disproved it. `nix build .#default` from the
same source produces a Darling that boots past dyld's initializers on this machine, with a
libc++ that is structurally identical to the port's -- same initializer section, same
reexport, same dependency set. So the abort is the port's, not the source's.

Two more differences fell out of comparing the two trees, and only one of them mattered:

  * the port emitted libc++'s dependencies in the order (libSystem, libc++abi) while the
    reference emits (libc++abi, libSystem), because ld64 records LC_LOAD_DYLIB in
    command-line order and cmake puts LINK_FLAGS, where -Wl,-reexport_library lives, ahead
    of LINK_LIBRARIES. Fixed by ordering reexports first; it did not change the abort, but
    it is what the reference does.
  * every one of the 39 images the guest loads is otherwise IDENTICAL between the two trees
    in initializer size and dependency set. So the defect was never in the metadata.

Swapping files between the two trees found it. With libSystem.B.dylib AND usr/lib/system
taken from the control build and everything else from buck2, **bash runs inside the
container**. Either alone still fails, and so does every individually loaded top-level dylib
(libc++, libc++abi, libobjc, libresolv) -- the umbrella and its sublibraries have to be
consistent with each other, which is what makes this a build-level difference rather than a
single bad artifact.

Everything else the port produces is therefore correct: the 5,536-file prefix, its layout,
the Rust daemon, launcher and loader, and the materialization.

### The cause: UPWARD dependencies, which the port had never expressed

dyld links an upward library but does NOT descend into it when running initializers. That is
the whole point of the flag, and it is what lets libSystem's own initializer run first: five
of its sublibraries depend on something that sits ABOVE libSystem, so a plain dependency
would make dyld initialize that thing before libSystem itself.

The reference passes `-Wl,-upward_library` for exactly those five edges:

    libsystem_trace.dylib   -> libobjc
    libdispatch.dylib       -> libobjc
    libxpc.dylib            -> libobjc
    libsystem_malloc.dylib  -> libsystem_c
    libdyld.dylib           -> libsystem_c and eight more

The port had never emitted an upward dependency anywhere. The rule supported them --
darwin_dylib has had an `upward` attribute all along -- but the generator listed
`-Wl,-upward_library` only in the set of flags it deliberately IGNORES, so every one of them
became an ordinary sibling. dyld then walked libSystem -> libsystem_trace -> libobjc ->
libc++, found libc++'s initializer first, and aborted the process before libSystem had ever
been initialized. The error it prints for that is "initializer in image (libc++.1.dylib)
that does not link with libSystem.dylib", which is why the first three days of this looked
like a problem with libc++.

With the five edges marked upward, the buck2-built Darling boots and runs bash:

    BUCK2_BASH_OK 3.2.57(1)-release x86_64-apple-darwin19

Three runs, three passes. That is bash 3.2.57 -- Darwin's bash, not the host's 5.3 -- with a
Darwin machine type, in a container whose every part came from buck2: the prefix, the
daemon, the launcher and the guest loader.

`uname` is not there, and that is correct: it belongs to the cli component, which this
milestone deliberately does not build. The Nix-built reference cannot run it here either.

scripts/buck-fix-link-model.py is what applies both corrections (order and upward) to
existing blocks, and it has a --check mode, because regenerating the blocks wholesale still
loses things the generator cannot reproduce.

## The Nix endpoint reaches the same milestone

`nix build .#darling-buck2-prefix` now produces a Darling that boots and runs bash, built
entirely through the endpoint: the graph dumped by real buck2 in a pure derivation, then one
derivation per buck2 target, ending in the prefix.

    BUCK2_BASH_OK 3.2.57(1)-release x86_64-apple-darwin19

The store output is the same shape as the daemon's: 5,537 files, 72 layout links, 108 MB.
scripts/buck-bash-check.sh takes --prefix now, so ONE check covers both endpoints -- with no
argument it builds through the buck2 daemon, with one it boots a tree Nix produced.

Getting there found five gaps, and four of them are the same gap wearing different clothes:
the endpoint replays what buck2 RECORDS, so anything buck2 knows but does not record is
invisible to it.

  * AN ACTION'S INPUTS, when it reads them from a file. The prefix passes a manifest and
    nothing else, so argv-scraping saw one path where there are 5,537. aquery declares them
    (buck.all_ineligible_for_dedup_inputs), with the producing action for each, so the dump
    records input TARGETS and the lowering stages them. General, not prefix-specific.
  * AN ACTION'S ENVIRONMENT. The launcher bakes its install prefix and git branch and commit
    through env!(), supplied as the action's env dict -- and aquery reports a command, its
    inputs and its kind, but no environment. The Rust runner now takes --env KEY=VALUE ahead
    of the compiler, so the command line is self-describing. OUT_DIR goes the same way.
  * THE VENDORED CRATE SOURCES. buck-rust/ is gitignored, so it is in neither the project
    source the endpoint copies nor the graph derivation's tree. nix/lib/rust-vendor.nix is
    now shared by the dev shell, the graph and the lowering: a graph dumped against
    different crate sources than the build uses is a graph of a different build.
  * SYMLINK NORMALISATION. scripts/buck-src.sh runs buck-src-normalise.py on every pin and
    the derivation did not, so buck2 refused libnotify's notify.defs. It has to run AFTER
    every pin (it follows the SDK farm's links) and needs --repo, because from the store it
    cannot find the project by looking above itself.

The fifth was not about recording at all: 36 committed paths pointed into
/nix/store/HASH-darling-cmake-src, and worked only because that store path still existed
here. write_block now strips the prefix so no future block can carry one.

What it costs: the graph derivation is 3m13s (5,709 actions, 115 staged artifacts, 31,124
artifacts ensured). Adding the prefix widened the materialization step enough that it now
builds some object targets -- a libarchive compile is what surfaced it -- so the earlier
"zero compiles in the graph derivation" is no longer exactly true. Minutes, not the hours a
full build would be, but it is a real change and worth stating rather than leaving as a
stale claim.

## Profiling the evaluation: 152s of CPU down to 9s

Nix 2.34 has a sampling eval profiler (`--eval-profiler flamegraph`), and pointing it at
`nix eval .#darling-buck2-prefix.drvPath` answered in one run what had been guesswork.

Before: 2m08s wall, 152s CPU, 200M thunks, 376M function calls, 28.8 GB allocated -- to
compute ONE derivation path. After: 14s wall, 9.3s CPU, 19M function calls, 6.3 GB.

Three costs, in the order the profile ranked them:

**Path normalisation, ~25% directly plus most of the 21% the profiler charged to
`primop isString`.** `linkTargets` resolved every relative symlink value by hand: split on
"/", fold away each "..", join back. `lib.splitString` is `filter isString (builtins.split
...)`, which is where the isString time came from, and `lib.init` copies, so the fold was
quadratic in the path depth. It ran over every link in every staged tree -- the SDK farm
alone is 3,591 -- once per consuming target. It is now one `os.path.normpath` per link in
the dumper, recorded as `stagedTreeDeps`, and Nix just reads the list.

**A scan where an index belonged.** `declaredStaged` tested all ~1,230 staged paths against
the declared-inputs list for every target. `stagedByTarget` inverts it once.

**The same script text, rebuilt per consumer.** A staged farm is consumed by many targets,
and `stagedTreeScript` rebuilt its shell script -- two `escapeShellArg` calls per link,
across 1,115 trees -- every time. Memoised per tree.

### A wrong turn worth recording

Midway I concluded the memoisation had changed behaviour, because the derivation hash moved
between a memo-off and a memo-on evaluation. It had not. The lowering interpolates
`${src}/...`, so every lowered derivation depends on the whole project source, and I had
edited that very file between the two runs. Appending a bare comment to
darlingBuck2Lower.nix changes the hash too; two evaluations with no edit between them are
identical. The memo was reverted on that bad reading and then restored.

The misreading exposed something real, though, and it is not fixed: **editing any byte of
the project invalidates every lowered target derivation**, a comment included. For an
endpoint whose whole purpose is that other people do not rebuild what they did not touch,
that is a serious weakness -- the graph is already keyed on build DEFINITION rather than
file contents, but the lowering is not. Worth its own work.

## The VM harness: Darling does not run in a NixOS test VM at all

Task #10 was meant to be the easy one: run the bash milestone in the same harness
tests/darling-smoke.nix uses. tests/darling-buck2-smoke.nix boots the VM, finds the
launcher, and then `darling-buck2 shell /bin/bash -c ...` times out with no output, where
the identical command takes seconds on the host through both endpoints.

Diagnosed, not guessed. The test now dumps the daemon log, the process list and the
uid/userns state on failure, and the log says the container BOOTS: full dtape init,
`execve expand /usr/libexec/shellspawn`, `darling_sigexc_self()`. Then it hangs. The
difference from a working host run is one line:

    host (works):  [guest kprintf] dtype for fd 2 -> /Volumes/SystemRootpipe:[94095524]
    VM   (hangs):  [guest kprintf] dtype for fd 2 -> /darlingserver.log

The guest never resolves its stderr through the host-root mount and falls back to the
daemon's own log. Two cheaper explanations were tested and eliminated: running without a TTY
reproduces fine on the host, and giving the VM 4 cores and 4 GB instead of 2 and 2 changes
nothing.

**It is not the port.** The REFERENCE Nix-built Darling fails the same way in the same
harness: `nix build .#checks.x86_64-linux.darling-smoke` gets to `darling shell true` and
times out with exit code 124, at the same place. (That check also had to be repaired first
to run at all -- it fails its own linter on an f-string with no placeholders, which says it
has not been run in a while.)

So two things are now known that were not:

  * the buck2 port's Darling is fine -- it boots and runs bash on the host, from the daemon
    path and from the Nix endpoint, repeatedly;
  * `tests/darling-smoke.nix` does not pass on this machine with the reference build, so
    task #5 was never "port more components until it goes green". Whatever is wrong with
    Darling inside a NixOS test VM has to be fixed first, and it belongs to Darling's
    container plumbing rather than to this port.


## The actual goal: Nix running INSIDE Darling, building bash

Running bash was never the destination. The target is Nix running inside the buck2-built
Darling and building bash there, which is a different order of capability: it needs the
guest to be a usable macOS userland, not just a loader and a shell.

Sized, by counting link edges per component scope the same way coverage does:

    scope     dylibs  exes  archives  modules  total
    system       121    61        37       35    254   <- what the port covers today
    cli          249   460       128       43    880   (+626)
    stock        610   528       134       96   1368   (+488 over cli)

What the goal actually requires, measured rather than assumed:

**The userland.** Today's prefix is bash, sh, zsh, tcsh, csh, bzip2, launchctl, bsdtar,
cpio, xz, openssl, syslog, notifyutil, plconvert, the terminfo tools, and launchd. There are
NO coreutils -- no ls, cat, cp, mkdir, rm, env, sed, grep, install, mktemp. Of the 48
binaries a Nix installation exercises, cli provides 44; the remaining four (tar, readlink,
whoami, install) are BSD-style install symlinks rather than separate link edges, which the
install-manifest generator already handles.

**The libraries Nix links.** libcurl, libsqlite3 and libxml2 are absent from system and
present in cli. libz, libarchive, libc++, libSystem, libiconv and libssl are already here.

So cli is the prerequisite and stock is probably not needed for the goal itself.
tests/nix-in-darling.nix additionally calls /usr/sbin/dseditgroup to create the nixbld
group, which is stock -- but a single-user Nix install does not need it, and the goal is
the capability, not that particular test.

**The daemon side already works.** linux/server/src/container.rs carries the
.enable-writable-nix path, which overlays the host /nix/store into the container because
Nix refuses to build in a diverted store. That daemon is buck2-built and running.

So the path is: port cli (+626 edges), regenerate the install rules at that scope, install
Nix into the guest ON THE HOST -- the VM is blocked on the pre-existing hang -- and build
bash inside it.
