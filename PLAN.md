# cider-nix

> **Cider Isn't Darwin Emulation, Really.**

cider-nix is a Nix-packaged fork of [Darling](https://github.com/darlinghq/darling)
(a userspace macOS/Darwin compatibility layer for Linux, "Wine for macOS"). Its host and
guest runtime have been rewritten in Rust.

**End goal:** build `aarch64-darwin` nixpkgs derivations on non-Apple ARM Linux, using
Darling as the Darwin layer, verified bit-for-bit against cache.nixos.org.

**Current campaign:** make `x86_64-darwin` builds work end-to-end against **nixpkgs 26.05**
(the last release supporting x86_64-darwin: a frozen target and a permanent cache oracle).
x86_64 is the native-speed test rig; most work (libSystem surface, harness, oracle, daemon)
is architecture-independent and transfers to ARM.

Tag work: **[ARCH-FREE]** (transfers as-is), **[ARCH-PARAM]** (transfers if parameterized
now), **[X86-ONLY]** (throwaway, minimize investment).

> This file carries what is currently TRUE. `plan/buck2-port.md` carries what does not
> belong here: why the port exists and what done means, the constraints learned from the
> nix-ninja grind, the phase plan and the non-goals. Neither keeps a status log -- the
> history is the commit that made each change.

---


## Buck2 port: how to work in it

The per-task narrative of how the port got here is in `docs/plan-history.md`, moved out
verbatim on 2026-08-11. What follows is only what changes what you do next.

**CLIMB THE LADDER FROM THE BOTTOM. Never start at the endpoint.**

1. `scripts/buck-lowering-stage-check.nu` — reads the generated staging script rather than
   building anything. Seconds warm, about six minutes cold after a `buck2 killall`. It is the
   only thing that can catch a staging fault at all: a build cannot, because the fault is in
   the script that lays out the tree the build then reads.
2. `nix build .#cider-buck2-one` — one real target end to end, about 18 s warm.
3. `nix build .#cider-buck2-prefix-min` — the gate, roughly an hour. Launch it only from a
   CLEAN working copy: jj auto-snapshots, so uncommitted edits are what Nix builds.

Three hours went once on chasing a shell-script fault at rung 3. Rung 1 names that class in
minutes, and did exactly that for #87 stage 2.

**RUN THE NIX-FREE SET FIRST. Nine checks, 27 seconds together, and several have each saved
an hour.** `buck-escape-roots-check.py`, `buck-pin-patches-check.py`, `buck-pin-rev-check.py`,
`buck-env-names-check.py`, `buck-first-party-paths-check.py`, `buck-labels-check.py`,
`buck-pin-paths-check.py`, `buck-host-includes.py`, `buck-coverage.py`.

**COUNT `^building`, NEVER the "these N derivations will be built" list.** The list overstates
the real work by nearly five times: gate12 listed 4,336 derivations and 895 builders actually
ran, because CA early cutoff removes the rest DURING the build. Judge by builders that ran.

**A BUCK EDIT IS NOT A FULL REBUILD ANY MORE** (#54, #79). The old advice to batch BUCK edits
is stale; the cascade was cut from 1,558 builders to 44.

**A RUNG 3 BUILD CAN WEDGE, SO WATCH IT:** `scripts/buck-stall-watch.py <log>`.

### cmake is gone (#82), and five generators are FROZEN

buck2 is the only build. The reference `result-graph-ref/build.ninja` can never be regenerated,
so the generators that read it are provenance, not tools. **A rename cannot reach a frozen
artifact, so every READER of one must accept BOTH names.** That has now bitten three times:
`SRC_STORE_RE` in `gen-buck-from-ninja.py`, `PROJECT_MARKER` in `buck-host-includes.py` (which
made 98.7 percent of its population noise and kept it red for days), and `SRC_STORE_RE` again
in `gen-mig-from-ninja.py` (all 124 mig edges). When a check is permanently red and someone
offers to freeze its threshold, suspect the POPULATION first.

`result-graph-stock` beside it is ALREADY collected, so this is not hypothetical: a check whose
input can vanish must fail rather than pass when it does.

### The rename rule (#84, #78)

**Upstream keeps the old name in its paths, patch headers, repo and org; only FIRST-PARTY names
change.** `__DARLING__` is upstream, 772 times across 188 pin files, and keeps its name.
`buck-upstream-names-check.py` holds the upstream names as DATA and must never be swept.

### Moving a path root needs THREE audits, each blind to the next (#87 stage 2)

1. **File content.** A sweep sees it. Be LABEL-FIRST: `buck-src/` alone mentions the old root
   1,854 times and only 172 are ours, the rest being `# cmake target:` frozen pragmas and the
   provenance source lists under them. Rewriting those breaks nothing at build time and
   silently stops coverage finding its reference paths.
2. **Symlink TARGETS.** No sweep can see these: a target is not file content. 4,031 of them
   named the old root while all eight static checks passed. Safe to suffix-rewrite only if the
   link climbs to the repo ROOT before descending, which must be checked before writing.
3. **Paths assembled from parts, or sliced by index.** Only reading the code finds these.
   `buck-src-normalise.py` built its key as `os.path.join("src", "external", rel)`, so the root
   never appeared as a literal; two array indices and one dead tuple entry hid the same way.

**And a destination rule is DIRECTLY UNDER THE PIN ROOT, never a depth number.** Five sites
encoded it as `== 3`; the worst was a literal `../../` back link, which is silent when wrong.

## Buck2 port: where it stands

Every in-scope link edge of the reference graph is ported and builds: **1451 of 1451**,
`buck2 build //...` green over all ~12k targets, `buck-test.nu` **160 passed, 1 failed**, and
every runtime check at 0 or a documented 3. Measured 2026-08-11 on a completed run, not
remembered and not deduced: the host-header fix took it from 159 to 160, and the arithmetic
prediction was confirmed by running the suite rather than by assuming.

It reads 161 rather than 159 because two checks that existed were never invoked by anything,
`buck-labels-check.py` and `buck-pin-paths-check.py`, and are now wired in. The nine nix-free
checks together take 27 seconds, so running them before a long build costs nothing.

The denominator is 1451, not the 1452 this line used to claim: #71 ported duct-tape to Rust,
so `libdarlingserver_duct_tape.a` stopped being a link edge. The floor had been left at 1452,
above the achievable maximum, so that check could not pass at all until b82c9e32.

One suite failure remains, and it is not a build gap. Install **UNMAPPED 5**: four pre-existing
gaps plus the shellspawn plist, which the Cider rename renamed on disk while the frozen
reference still names the old one; deliberately not mapped away, since that would hide a real
divergence.

The host-header failure is **FIXED** (ec35926e), and it was never 1,275 defects nor a threshold
worth freezing. `PROJECT_MARKER` in `buck-host-includes.py` had been renamed to
`cider-cmake-src`, but the reference `build.ninja` is a frozen cmake-era artifact that says
`darling-cmake-src` 455,547 times and the cider name zero times. The marker matched nothing, so
the project's own `-I` flags all counted as host includes: 98.7 percent of the population was
noise. Reading both names gives 26 targets, 24 include dirs, 21 ported, and all 21 already
declaring `host_headers`, so it is honestly green. Verified it can still fail by removing the
dep from one entry, which reported exactly that entry. It also used to return 0 when the
reference was missing, so a store GC would have turned the repair into a permanent blind pass;
it returns 2 now. That is not hypothetical, `result-graph-stock` beside it is already collected.

`result-graph-ref` points at the **all** graph and buck-test's thresholds are
all-component numbers. `scripts/buck-runtime-check.nu` runs the eleven runtime checks in
one command.

### What 100 percent does NOT mean

- **32-bit is not built and will not be.** `libsyscall_32` and the 74 i386 mig edges. A
  deliberate scope reduction: the long-term target here is aarch64.
- **cctools ld/ar/ranlib come from Nix** rather than being built.
- **The link-edge metric counts link edges.** Generated files are measured separately by
  `scripts/buck-codegen-coverage.py`: 227 outputs are unconsumed and all are mig side
  outputs the reference does not read either.
- **Build parity is not runtime parity.** buck-test is almost entirely static. What runs is
  the ten runtime checks plus `scripts/buck-loadall-check.nu`, which dlopens the prefix:
  292 of 336 installed dylibs and framework binaries load in the guest, and the 44 that do
  not are the Swift LFS pointers (#39), which are not libraries. Past dlopen is unmeasured.

### Deliberate divergences from the reference

Three, each stated in the code beside the reasoning rather than done quietly:

- **The real framework wins a destination collision.** The reference installs the nine
  dev-STUB frameworks to the same paths as the real ones, so whichever entry is read last
  wins; the port keeps the implementation and REPORTS every collision.
- **`_sqlite3.so`** is installed alongside the reference's `_sqlite.so`, whose init symbol
  is `init_sqlite3`, so `import sqlite3` works. Nothing the reference ships is removed.
- **perl 5.18 Storable** is compiled with `-DVERSION=2.41` to match its own `.pm`, over
  the reference's `2.4`.

### Traps that have each cost at least one increment

**A name does not identify an artifact.** This was wrong in three separate places and cost
the most of anything here. The coverage metric keyed edges by artifact basename; the
install resolver did too; and `binary_index()` did as well. Between them they hid 16
unported targets, shipped perl 5.28 binaries into the 5.18 tree, put AppKit's X11 binary in
CoreGraphics' backend slot, and shipped an EMPTY AppKit over the real one. Everything
resolves by reference PATH now, via the `buck-registry: <path> = <target>` pragma the
generated blocks already carried.

**A path in a build file lives in one of FOUR spaces and they look identical.** (1)
repo-relative and CURRENT: an include dir, a `root =`, a src. Must move. (2) pin-relative,
`openssl/src/tools/c_hash`. Must not. (3) FROZEN REFERENCE: a `buck-registry:` KEY, a
`# cmake target: X ->` line. Must not. (4) cmake BINARY-DIR, everything under `# TODO these
include dirs are GENERATED (codegen output):`. Must not. The existence test separates 1 from 2
and is self-validating (rewrite only when `src/<rest>` is gone and exactly one of
`darwin/<rest>`/`linux/<rest>` exists), but it CANNOT see 4, because cmake mirrors the source
layout into its binary dir: `src/CoreAudio/CoreAudio` is generated while
`darwin/CoreAudio/CoreAudio` is real, so both exist. Key class 4 on the comment block, not the
path. For classes 3 and 4 the generator is the arbiter: run `gen-buck-from-ninja.py <target>`
and read what it emits rather than reasoning about it.

**Two ways a glob silently stages NOTHING**: crossing a package boundary, and traversing a
symlinked directory. A CYCLIC symlink instead wedges the materializer with the daemon at 0%
CPU and nothing written. `find <tree> -type l` before debugging buck2.

**A generator fix only reaches the blocks you REGENERATE.** The cyclic-symlink fix was
applied and the hang came straight back from two other blocks that glob the same tree.
`grep -rn '"<tree>/\*\*/\*"' --include=BUCK .` lists them.

**`--dylibs` writes the LINK block; plain `--write` writes the OBJECTS block.** cflags and
gen_srcs live in the latter. Regenerating only the first looks like the change did not take.

**A mig_gen exports only what `compile_srcs` names**, and the `[xtrace]` subtarget only what
`xtrace_srcs` names. A `gen://` entry is necessary and not sufficient: the target builds,
the archive is produced, and the object is simply not in it. Check with
`llvm-ar t <archive> | grep -i <subsystem>`.

**The runtime checks cannot be chained naively.** Each kills stale processes under its own
root at START and not at exit, so three back to back leave three daemons alive and the
earlier ones fail spuriously. `buck-runtime-check.nu` kills between. `pgrep -x`, never `-f`:
an `-f` pattern matches the command line of the shell running it.

**Host ELF libraries must be on `LD_LIBRARY_PATH` for the LOADER**, not just for wrapgen.
Without it, loading AppKit kills the process before `main` with no output at all.

**An exclusion list is load-bearing, and a rename can empty it.** The lowering stages `pins/`
as a REAL directory so the pins can be planted in it, so the loop that
symlinks every other top-level entry into the store must skip `src`. That exclusion was
rewritten to a Nix BINDING name, which matches no directory, and all 1798 lowered targets then
failed with "Permission denied" 90 minutes into a build.
`scripts/buck-lowering-stage-check.nu` reads the generated staging script in seconds instead.

### The meta-lesson: re-test a recorded diagnosis before acting on it

Recorded diagnoses in this file keep turning out to be untested guesses, and most point away
from a fix that takes under an hour: DBusKit's "no framework root", getuuid's "missing
header", the JSC hang, "counting by path is not a one-line fix", libstdc++'s "incompatible
headers", the AppKit backend, CoreGraphics' "can never find its backend", the claim that
JavaScriptCore never worked upstream, eight krb5 symlinks called dangling that were absolute
GUEST paths, 22 libraries called display-dependent that only wanted `LD_LIBRARY_PATH`, and
`oracle.nu` called untestable when every branch of it is reachable behind a stub `nix`.
Several were written by the same agent that later disproved them. The count is deliberately
not kept: it only ever goes up, and a stale number is the same bug this section is about.

The pattern is identical every time: a real observation, an untested explanation attached to
it, and the explanation recorded as though it were the observation.

Corollaries that have each been paid for separately:

- **When a metric looks wrong, fix the measurement before reporting the number.** The
  codegen metric read 100%, then 0.02%, then 90% before it read correctly; all three wrong
  answers looked like answers.
- **When a probe fails, get the actual error.** `afinfo` swallows its OSStatus and prints
  "AudioFileOpen failed"; the status is -4, unimpErr, which is a different conversation.
- **Do not revert a correct fix to make a check green.** The AppKit probe passing on a
  wrong file hid an empty AppKit for hours.
- **Evidence that looks conclusive often is not.** libpthread bzeros `main_stack` on BOTH
  its success and failure paths, so a blanked value proves only that the function ran.

### Where the narratives went

Each fix above had a long writeup here. They are all in the commit that made the change,
which is where they belong: `jj log` or `git log` the file you are looking at. This section
keeps what is still true and useful, not the story of arriving at it.

---

## Status (2026-07)

Done:
- **Rust rewrite complete and default.** Host daemon (`linux/server`, crate `cider`, bin
  `ciderd`), launcher (`linux/launcher`, bin `cider`), guest loader
  (`darwin/loader`, bin `mldr`). The C++ daemon and C launcher/loader are deleted.
- **Boots to Darwin; M1 achieved.** Guest nix 2.34.8 builds and runs `hello` (and `pv`)
  from source under rootless Darling, launchd-free. `nix eval builtins.currentSystem` →
  `"x86_64-darwin"`.
- **Off git submodules.** Nix (`nix/submodules.json`, 147 pins + `nix/lib/cider-src.nix`)
  is the sole source path; `.gitmodules` + gitlinks deleted, no `?submodules=1`.
- **Full `.#default` builds green and boots.**
- **Identity:** macOS **14.4.1** / Darwin **23.4.0** / build **23E224**
  (`patches/xnu/0005` + `SystemVersion.plist`); clang auto-targets
  `x86_64-apple-darwin23.4.0`. `CMAKE_OSX_DEPLOYMENT_TARGET` stays 11.0 by choice.

Phases A (identity), B (symbol gap), C (bootstrap tools execute + build hello / M1) are done.
The open frontier is D (oracle), E (package ladder), F (ARM prep), plus the Rust/build/perf
tracks below.

---

## Architecture

- **Top-level layout (#87, both stages):** three top-level trees and no more. `darwin/` is
  guest side, `linux/` is host side, `pins/` is the 148 vendored upstreams. **`src/` no
  longer exists.** First-party code is classified by BUCK RULE KIND, not by name:
  `darwin_dylib` and `darwin_binary` are guest, `cc_binary` and `rust_binary` are host.
  `stageProject` now excludes `pins` rather than `src`, so pins are still planted into a real
  directory rather than a store symlink; deleting that exclusion instead of renaming it
  reproduces a failure that once cost a whole endpoint build.
  **The destination rule is DIRECTLY UNDER THE PIN ROOT, never a depth number.** Five sites
  encoded it as `== 3` and all five derive it from one `pinRoot` now, including the back link
  in `materializePins`, which was a literal `../../` and is silent when wrong: it dangles the
  SDK farm and surfaces an hour later as a missing header. `buck-pin-rev-check.py` asserts no
  two pins share a materialization directory, which is the collision the rule exists to stop.
  **A root move needs three audits, each blind to the next:** file content, which a sweep
  sees; symlink TARGETS, which no sweep can see and which numbered 4,031 here; and paths
  assembled from parts or sliced by index, which only reading the code finds.
- **Call chain (the debugging map):** Darwin binary → Darwin libc → `libsystem_kernel`
  BSD-trap stub → daemon translates to Linux → kernel. Syscalls are implemented only to the
  depth Nix needs, not for general macOS compat.
- **launcher** (`linux/launcher`, libc-only, builds offline): rootless userns re-exec,
  prefix bootstrap, spawns the daemon as container init, shellspawn client, teardown. Owns
  NO mounts/vchroot (the daemon does).
- **daemon** (`linux/server`): single-threaded epoll loop + a **stackful microthread
  scheduler** (`sched.rs`) — not async, because xnu-sys suspends microthreads
  synchronously from inside C stacks; single-worker is correct (xnu-sys locks are
  cooperative). RPC codec (`rpc_wire.rs`) is generated from the calls list, 162/162
  byte-identical to C. Wire = SOCK_DGRAM + SO_PASSCRED (sender pid via SCM_CREDENTIALS, used
  for `process_vm_readv` because the guest is in its own PID namespace).
- **xnu-sys** (`pins/ciderd/xnu-sys/`, still C): kernel-emulation glue
  that compiles the vendored XNU (osfmk/bsd). Linked into the daemon crate by
  `linux/server/build.rs`: bindgen generates the 36-field `xnu_sys_hooks_t` from source
  headers; static libs (`libciderd_xnu_sys.a`, `liblibsimple_ciderd.a`)
  come via the `XNU_SYS_LIB` env var. The Rust/C seam is the frozen `xnu_sys_*` API +
  `xnu_sys_hooks` vtable — Rust above, C+XNU below.
- **mldr loader** (`darwin/loader`, libc + goblin): guest Mach-O loader — segment mmap/slide,
  commpage, the elfcalls vtable (ELF↔Mach-O), start stack, daemon checkin, jump to dyld.
- **Container model:** an overlayfs prefix (`~/.cider`, macOS FS hierarchy) entered
  **rootless** via unprivileged user namespaces (needs
  `kernel.unprivileged_userns_clone=1`, kernel ≥5.11). **One command per fresh container** —
  a sibling userns cannot join a running container's mount ns.
- **Shared store:** guest `/nix/store` is the host store via a `/nix →
  /Volumes/SystemRoot/nix` symlink (the host root is mounted at `/Volumes/SystemRoot`);
  `/nix/var` stays Darling-local to avoid db/schema conflicts.
- **apple-sdk `.tbd` stubs:** binaries link against stub symbols, resolved at runtime from
  Darling's reimplemented libraries — so derivation hashes never depend on Darling.
- **sandbox-exec** is a parse-and-ignore stub (the Linux container already isolates).
- **Nix packaging:** `nix/lib/cider-src.nix` assembles the tree from the 147 pins +
  `patches/<name>/`; `nix/package.nix` builds the Darwin userland and installs the Rust
  crates; `nix/{launcher,server,xnu-sys,loader,cctools-port}.nix`.

---

## Invariants (never violate)

1. **Official nixpkgs 26.05 only.** A patched input makes hashes incomparable and the oracle
   worthless. Record nixpkgs-side needs as a blocker entry (see Blockers), don't fork inputs.
2. **No Apple-proprietary bits** in outputs or the repo. Reimplement from Apple open source
   (APSL) or clean-room from public docs; note provenance in commits. SDK stubs flow through
   Nix's own `apple-sdk` fetch, never vendored.
3. **Green never regresses.** Every fix lands with a regression test; `scripts/run-tests.nu`
   + flake checks pass before every commit; the compatibility matrix is append-only.
4. **Arch discipline.** Code touching registers, syscall numbers, thread state, signal
   frames, TLS, page size, or Mach-O CPU types goes behind the arch boundary. aarch64 is the
   customer; x86_64 is the test rig.

---

## Open work


CONSOLIDATED 2026-08-10. Eight subsections describing FINISHED work were removed, 660
lines: the endpoint going green, the minimal prefix, iteration cost (#56 #58), the #12 VM
hang, Rust and tooling, multi-user launchd (#47), and a section telling the reader to make
nix-ninja the primary incremental build, which #82 deleted outright. Every task number they
referenced is completed. Git history holds them.

What follows is only what is still OPEN.

### #66 - get the lowering out of the evaluator

A general buck2-graph to dynamic-derivation bridge, worth having for OTHER projects.
GENERALITY IS THE REQUIREMENT; cider is the first consumer, not the target. Nothing in the
reusable half may mention pins, the SDK farm, cider staging or this repo's layout.
Full detail, measurements and traps: docs/plan-history.md, "#66 in detail".

- **A, the bridge, DONE and GENERAL.** `nix/lib/dyn-actions.nix` plus nine fixtures beside it.
  `scripts/buck-dyndrv-check.nu` asserts **ten** properties and PASSES. Three are properties of
  Nix; the rest are of the bridge, and several were false when first checked (the DAG edge, the
  whole of `specDir` mode, specDir-plus-a-DAG). None had a fixture, so none could have been
  noticed. `extraEnv` is asked **per action**, which is the case a consumer actually has; and
  specDir mode now accepts a spec dir the bridge did NOT write, holding only name, builder and
  args, with the fixup supplying the system, version, outputs and the output PLACEHOLDER, since
  none of those is something a generator can know.
- **B, the adapter, and A and B are CONNECTED.** `scripts/buck_lowering.py` renders the WHOLE
  builder script and `buck-graph-to-specs.py` writes it, along with `needs.json` and a `dyn/`
  directory of bridge-shaped specs, inside the graph derivation.
  **`.#cider-buck2-dyn-gen` builds a real cider cone from those specs with nothing serialised
  in the evaluator, and `diff -r` against the lowered derivation is clean.** A second cone,
  `-trees`, covers the staged-tree numbering; `-scale` instantiates all **1,474** producers in
  ~13 s, against the lowering's own 10.6 s.
- **THE LOWERING NO LONGER ASSEMBLES A SCRIPT.** It reads the template and supplies five
  consumer values. All 1,474 labels unchanged, endpoint drvPath identical, rung 2 zero
  builders. Verified byte for byte by `scripts/buck-script-check.nu`, which reads the
  generator's own `full.json` out of the store rather than re-rendering, and by
  `scripts/buck-needs-check.nu`, which reads `passthru.definitionNeeds` rather than `deps` so
  it cannot compare the python against itself.
- **THREE FAILURES WORTH THE SPACE, all one shape: a green result over a broken build.** A run
  that passed with `find`/`sed` missing (nativeBuildInputs is only what the lowering ADDS to
  stdenv); the deep cone failing on `llvm-ar`, because **an emitted action runs no setup hooks**
  and `makeBinPath` follows neither hooks nor propagation; and the specDir check reporting OK
  while its diff never ran, because both modes produced a **byte-identical check derivation**.
  Look for the artifact, never the exit code.
- **THE INVARIANCE CHECK IS A TOOL,** `scripts/buck-lowering-invariance-check.nu`. It
  fingerprints every label's `builderScript` and `stageScript` against a saved baseline, which
  is the check a green ladder cannot replace: rung 2 builds ONE target, so a change that moves
  every *other* derivation is invisible to it.
- **STILL OPEN.** Building 1,474 emitted groups, and whether the prefix comes out identical
  that way, is unmeasured and is an hour-class build. Whether the bridge REPLACES the lowering
  or stays a second route is not answered by anything measured yet.
### D — Correctness oracle (the keystone remaining) [ARCH-FREE]
"It built" → "it built **correctly**." The project's core value proposition.
- **D.1** `scripts/oracle.nu <attr>` = `nix build --rebuild` vs cache.nixos.org, JSON
  (match / mismatch / build-failure / known-nondeterministic).
- **D.2** oracle column in `tests/nix/compatibility-matrix.sh`; a justified
  non-determinism allowlist.
- **D.3** on mismatch: diffoscope + classify (codegen vs metadata vs fs-ordering vs
  miscompile). **A codegen-class divergence is stop-the-line** — the shim is lying to the
  compiler (math, memory layout, or a syscall result) and everything above is suspect.

### M1 tail (Phase C.3–C.4b) [ARCH-FREE]
- Drive the official `pkgs.hello` **derivation** through guest nix (not hand-run
  configure/make). `scripts/build-pkg-bypass.nu <attr>` generalizes to any nixpkgs
  x86_64-darwin attr. Widen to no-substitute deps.
- **C.4b** gdb-on-timeout stall capture (timeout + on-timeout stack of the guest process +
  daemon), filed to the Stall notes below. (The old `config.status` here-doc pipe hang was
  the checkout lifetime-pipe fd leak → pipe-page starvation, now FIXED; reverify if it
  recurs.)

### E — Climb the package ladder [ARCH-FREE]
- **E.1** dependency-weighted 26.05 x86_64-darwin target list (CLI-only; GUI *runtime* out
  of scope — building GUI apps against link-time framework stubs is fine).
- **E.2** grind loop per package: build → triage (syscall / symbol / stall / semantic
  divergence) → fix with a regression test → oracle → append to matrix.
- **E.3** milestone packages: `python3` (pip-stall class), `git`, `cmake`, `openssl`, a
  large C++ package (`llvm`); stretch: `swiftc` (stresses libdispatch/CF).
- **Exit (campaign):** the full Tier-1..3 matrix green with oracle, on a frozen 26.05 pin,
  in CI, reproducibly from a clean prefix.

### F — ARM readiness (prep only, do not start the port) [ARCH-PARAM]
- **F.1** salvage-assess the three `feature/arm-support*` branches → `PLAN.md`.
- **F.2** arch-boundary audit (syscall numbers, ucontext layouts, asm, page size). Audit
  host-page-size vs Darwin `vm_page_size`: arm64 userland assumes **16K pages** — plan to
  report 16K from libSystem regardless of host, and prefer `CONFIG_ARM64_16K_PAGES` guests.
- **F.3** parameterize harness / VM tests / matrix / oracle / symbol tooling by arch.
  aarch64-darwin outputs carry ad-hoc code signatures (nixpkgs signs via sigtool) — the
  oracle must handle signature bytes correctly, not diff them naively.
- **F.4** document the QEMU aarch64 dev recipe (share `/nix/store` via virtiofs; never run
  ciderd under qemu-user — signal/TLS fidelity).

### CI + remote builder (built in Campaign 1, unvalidated — needs rework)
Machinery exists but was **never validated end-to-end on a live prefix** and predates the
Rust rewrite / launchd-bypass / 26.05 pin / submodule removal:
- CI: `.tangled/workflows/ci.yml` (tangled.org), `tests/*.nix`,
  `tests/nix/compatibility-matrix.sh`, dirserv-stubs check.
- Remote builder: `nix/ciderBuilderModule.nix` (`services.cider-builder`, sshd in prefix,
  `nix.buildMachines`), `scripts/cider-build-hook`, VM tests. Design (host
  `nix.buildMachines` → sshd in Darling → guest nix-daemon, shared store avoids SSH copy) is
  the north star but unexercised — and conflicts with one-command-per-container.

### Performance (measure during E; acceptable-if-slow for CI)
Baseline: spawn ~11–12× native (~28 ms/proc), compute ~7.6×. Spawn tax: ~22 ms (78%) = the
daemon fork/exec/RPC path. Landed and done: P0 ucred cache, P1 sigmask-free context switch,
P2 epoll re-arm memoize.
- **P0.7 spawn-path round-trips** — batch the fork/exec/registration RPCs. THE biggest
  wall-clock lever (~22 ms/spawn). High risk (IPC core).
- **P3 mach_msg same-task fast path** — handle same-task/local-port sends+recvs in-process.
  High risk. **P4** userspace signal deferral (drop the per-RPC sigmask pair). **P5** psynch
  uncontended CAS fast path. **P6** inline small OOL payloads into the datagram. **P8**
  scheduler futex contention (lock-free hot path) — deepest, do last.
- P0.5 dyld shared cache: DOWNGRADED to low (saves ~1.8 ms/spawn only).
- **Meta-blocker:** P3–P8 are core-cutting and not isolate-testable → gated on a reliable
  non-flaky spawn/IPC stress harness + fast daemon iteration (nix-ninja). Build that first.
- Already optimal (don't touch): BSD syscall dispatch (table-driven to Linux),
  `__ulock_wait/wake`→`futex(2)`, `vchroot_expand` path translation, cached
  `mach_task_self`/`mach_host_self`, getpwuid via glibc NSS.

### Watch-items (reopen on demand)

**Content addressing is research-grade, and the invalidation design rests on it.** Early
cutoff (#50, #56) is real and verified here twice. The two caveats that bite on this
machine: **CA + IFD is a known incompatibility (#5805)**, the placeholder-context problem
the three `unsafeDiscardStringContext` calls in the lowering work around, and CA is reported
to "still crash on trivial cases as recently as Nix 2.34.x", which is the version here
(2.34.7). Also: IFD cannot be parallelized, so the two IFDs (graph, then source closure) are
**strictly serial** because the closure needs `graph.json`.
- **Symbol:** 6 lazy-bound FSEvents stubs (`_FSEventStream*`, CoreServices) only if a real
  binary calls them. Re-run `symbol-demand.nu` as the package set widens (larger C++/Swift
  broadens the surface). Supply = `nm --defined-only` ∪ full export-trie (both, or you
  undercount re-exports).
- **Syscall:** dup2-to-guarded-fd → return EBADF, don't abort; may recur in
  `fcntl(F_DUPFD)`/`dup`. Network.framework `nw_*` = 39 loud NULL stubs (real impl out of
  scope; nix never uses S3 for local builds).
- **`-111`/ECONNREFUSED:** doesn't fire on `net.unix.max_dgram_qlen=16384` hosts; the two
  guest busy-spin band-aids (sigexc.c, mach_traps.c) are vestigial there but needed on
  qlen=512. Proper host-independent fix (open): the daemon drains the socket to EAGAIN
  (recvmmsg loop) into an internal queue so it never backs up.
- **SIGFPE exec-fidelity flake (#44):** intermittent signal-8 in guest build/test binaries —
  retryable (nix build ×4), not a real error nor a Rust regression.

### Upstream adoption
Fork point `f39a29489` (2026-03); upstream idle on core as of 2026-07-19. Adopt only when a
concrete failure justifies it:
- Newer-toolchain build fixes (we build under clang 21): cider
  `e3fe4288 3f277ba5 9f485c91 ddd118d9 fc5c0666`, xnu `644decacee`. Cherry-pick onto our
  patched xnu; **don't bump the gitlink** (ours diverges).
- libkqueue `b0795a2e` (EVFILT_TIMER type-punning) if a kqueue-timer stall appears.
- Upstream ciderd C++ tracking is obsolete (we're full-Rust). Fixing the launchd-boot
  hang would be an upstream-caliber rootless contribution.

---

## Operational notes / gotchas

- **The dev shell built the GUEST with the WRAPPED clang, and the endpoint never did.**
  One root cause, measured 2026-08-10, behind a clean `scripts/buck-test.nu` reporting
  `built, 432 of 659 reported an output` with 227 FAIL lines while the Nix endpoint was
  green. Not a code regression. `ciderBuck2Graph.nix` pins `darwin_cc` to
  `clang-unwrapped` and unsets `NIX_CFLAGS*`/`NIX_LDFLAGS*`; `scripts/buck-setup.nu` wrote
  neither, so `darwin_cc` fell back to the bare name `clang` from `buck/toolchains/BUCK`,
  which in the dev shell is the WRAPPED one. That breaks a guest build two ways:
  1. `add-hardening.sh` appends `-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2` AFTER the argv, so
     the port's `-D_FORTIFY_SOURCE=0` loses (`clang -dM -E` prints `_FORTIFY_SOURCE 2`).
     libc's `secure/_stdio.h` turns `snprintf` into a macro over
     `__builtin___snprintf_chk`, which rewrites libc's own DEFINITION of `snprintf`, so
     `//buck-src/libc:libc-stdio_obj` does not parse and everything downstream of libc
     produces no output.
  2. `bin/clang` re-sources the binutils `add-flags.sh` whenever
     `NIX_BINTOOLS_WRAPPER_FLAGS_SET_x86_64_unknown_linux_gnu` is unset, true here and
     false in a derivation, so every link gets `-Wl,-dynamic-linker=<glibc ld.so>` and ld64
     dies with `ld: unknown option`.
  FIX: `buck-setup.nu` now emits `darwin_cc`/`darwin_cxx` from `$NIX_CC/nix-support/orig-cc`.
  `cc`/`cxx` stay WRAPPED on purpose, because host ELF tools do need the nixpkgs dynamic
  linker and the unwrapped clang cannot even find `stdio.h`. Verified end to end:
  `ruby_zlib_dylib`, head of the 180-target ruby family, went from exit 3 to BUILD
  SUCCEEDED (4,704 commands) emitting a real `MH_MAGIC_64 BUNDLE DYLDLINK`.
  TWO DEAD ENDS worth not repeating: setting the bintools sentinel by hand aborts the
  wrapper with `NIX_LDFLAGS_BEFORE_...: unbound variable`, and `hardeningDisable = ["all"]`
  in the dev shell fixes the fortify half only (it is still correct for HOST builds, and
  matches the two lowering derivations, so it stays).
  WHY IT HID: buck2 actions inherit the DAEMON's environment, and a long-lived daemon kept
  serving from the environment it started in. `buck2 killall` is what exposed it. A green
  endpoint is not evidence about the dev shell.
  WHERE IT ENDED, measured 2026-08-10 on a suite run that COMPLETED: **ok=150, FAIL=4**,
  from ok=137 FAIL=311. All 307 cleared FAILs were in the dylib and executable sections;
  `built, 564 of 564 reported an output` against a 432 of 659 baseline, the denominator
  falling because the mirror fix removed 95 duplicate targets. The 4 that remain are
  BYTE IDENTICAL to the pre-existing ones and untouched by any of this: coverage 1448 of
  1452, install UNMAPPED 4, and the two host-header checks (1275 targets).
  `//buck/prefix:cider_prefix` builds end to end at 39,172 entries and 309 dylibs.
  WHAT IT COST, AND HOW THAT WAS PAID: it broke `hdiutil`, which compiled before. The cause
  was NOT the missing wrapper: `host_include_dirs` had a HOST LIBC on it. The straggler
  harvest takes every `-isystem` dir out of the dev shell's `NIX_CFLAGS_COMPILE`, and that
  list contains `glibc-iconv`, whose `iconv.h` opens with `#include <features.h>`. Those dirs
  go out as plain `-I`, so they are searched BEFORE the guest SDK, which has three `iconv.h`
  of its own. Letting the host one win defines `__GLIBC__` for a Darwin compile, libc++ takes
  its glibc branch in `__locale`, and the compile dies on `undeclared identifier '_ISspace'`.
  FIXED by filtering host libc out of the harvest, matching the PACKAGE NAME and not a
  substring: `libcap` contains the letters libc and is a library the port needs.
  Verified: `//buck-src:hdiutil` builds, 3,727 commands, `MH_MAGIC_64 EXECUTE`.
  A DEAD END, do not retry: handing glibc to `host_headers` as `-idirafter` looks like the
  symmetric fix (it is what the wrapper did) and is WRONG. It resolves `features.h` and then
  fails the same `_ISspace` way, because the problem was never the missing dir.
- **`.buckconfig.local` says GENERATED but was partly HAND MAINTAINED, and regenerating it
  silently dropped what only a human had put there.** 2026-08-10: a regenerate lost a whole
  `[buck2]` section (watchman then refused to start at nice 12, and every buck2 command died)
  and FOUR include dirs (`expat`, `systemd-minimal-libs`, `linux-headers`, `libxdmcp`), which
  took `//darwin/frameworks:fseventsd_obj` out with
  `linux/fanotify.h: 'linux/types.h' file not found`. None of them came from the script.
  Fixed at the source rather than by hand: the `[buck2]` section is emitted, and the four
  packages are declared in `nix/devShell.nix` so the `-isystem` harvest finds them.
  THE HABIT THAT WOULD HAVE CAUGHT IT: after regenerating a generated file, DIFF IT AGAINST
  THE PREVIOUS ONE. The script also printed `WARNING: pkg-config knows nothing about: xdmcp`
  and it went unread because only `ERROR` was grepped for.
- **`scripts/buck-test.nu` OOMs in the prefix section.** 2026-08-10, `nu` killed at 17.3 GB
  anon-rss on a 30 GB box entering `== the prefix ==`, so the suite never reports final
  totals. MECHANISM NOT ESTABLISHED. The obvious suspect is `out_of`, which does
  `buck2 build ... | complete` and buffers the whole build's output in memory. Every
  measurement so far is against it: that target through `nu ... | complete` peaked at
  **0.04 GB** of nushell RSS, and a full suite run that COMPLETED peaked at 0.04 GB too
  (ok=150 FAIL=4). But do NOT read that as refuted, which is how this was first written and
  it was too strong. NEITHER measurement reproduced the condition that OOMed: both ran with
  the prefix ALREADY BUILT, whereas the kill happened when the suite drove a COLD FULL
  prefix build itself. The one correlation on record is exactly that. Settling it needs a
  deliberate cold rebuild under the sampler, which costs a full rebuild, so it is a
  cost decision rather than an open question of what to do next.
- **Run recipe** (from a built `$out = nix build .#default`):
  `DSERVER_LIBEXEC_PATH=$out/libexec/cider
  DSERVER_MLDR_PATH=$out/libexec/cider/usr/libexec/cider/mldr CIDER_NO_LAUNCHD=1
  DPREFIX=<fresh dir> $out/bin/cider shell sh -c 'uname -sm'` → `Darwin x86_64`.
- **Phantom-path trap:** after any commit that touches a Rust crate, `.#default`'s hash
  changes and `nix eval .outPath` returns a NEW, UNBUILT path. Booting against it fails
  SILENTLY (daemon binary absent → launcher spins in its container-acquisition loop,
  wchan=hrtimer_nanosleep, empty log, `pgrep ciderd` finds nothing). Always
  `nix build .#default` first (or assert `test -x $out/bin/ciderd`). The same drift
  happens dirty→committed (a dirty-tree build and its commit hash differ).
- **mldr debug is gated** behind `MLDR_DEBUG=1` (default off). Do NOT grep for `[mldr]` to
  confirm a boot with the gate off — grep guest stdout (`Darwin`/`uname` output). The ungated
  ~15-line-per-process flood interleaving with stdout under `2>&1` was the false
  "concurrent-output flake"; measure output completeness with stdout/stderr SEPARATED.
- **mldr elfcall movaps constraint:** the guest calls elfcalls on an 8-byte-misaligned
  stack, so elfcall-reachable loader code must be movaps-free — no `mem::zeroed`/`Default` of
  a >8-byte struct on the stack (emits an aligned SSE store that #GPs); use `MaybeUninit` +
  scalar fills.
- **xnu-sys two-phase init:** `xnu_sys_init` then `xnu_sys_init_in_thread` on a kernel
  microthread (psynch etc.); no hook in the 36-field vtable may ever be NULL (NULL → indirect
  call to 0x0).
- **RPC socket fork-safety:** sockets live at high fds + FD_CLOEXEC (so a forked subshell's
  low-fd dup2/close can't clobber them); the child does a socket-refresh.
- **One command per fresh container** (kill the stale daemon first). Keep the prefix path
  short — the daemon/shellspawn AF_UNIX socket lives under `<prefix>/var/run/` and overflows
  `sockaddr_un.sun_path` (~108 chars) on long paths; use `~/.cider`. Export
  `TMPDIR=$HOME/tmp` (the default Darwin temp dir EACCESes). Two-boot warm flow; harness
  output must be file-based, never piped through a reader (a leaked container holds the pipe
  write-end open and blocks EOF).
- **`__private_extern__` is not a linker bug (#57):** modern clang emits it as an *undefined*
  symbol; link the consumer against real ncurses/libtinfo, don't touch ld64. `-fcommon`
  doesn't fix it.
- **xnu pin gotcha:** the super-repo gitlink was a Campaign-1 rev never published upstream;
  cider-src fetches the pinned rev from `submodules.json` + applies `patches/xnu/*`.
  Cherry-pick upstream fixes onto our patched xnu; don't bump the pin blindly.
- **nix-ninja / mig gotchas:** merged `$out` conflates a checked-in `osfmk/**/X.h` with the
  same-named mig-generated header (10 collisions; `notify.h` is
  `_MIG_KERNEL_SPECIFIC_CODE_`-sensitive — force it to 1 via a xnu-sys patch); mig edges
  need `-DKERNEL_USER -DMACH_KERNEL -DKERNEL`; `lower.nix` must `rm -f` a staged read-only
  source symlink at a declared output path (else mig `fopen`→EACCES). Full-graph nix-ninja is
  ~26k derivations — keep it OUT of `nix flake check`.

---

## The goal: full parity with upstream Darling

Everything upstream Darling supports, this project supports. Same libraries, same
frameworks, same features. What changes is only HOW it is built: buck2 instead of cmake,
Rust instead of the C daemon/launcher/loader, Nix instead of a system install. The port is
not a subset and is not finished when something merely boots.

Darling's own COMPONENTS hierarchy is the measure, because it is upstream's own
decomposition. It came from cider_parse_components.cmake, which #82 removed along with the
rest of cmake, so the hierarchy now survives only in git history and in the reference
build.ninja under result-graph-ref:

    core -> system -> cli
    stock = cli + python + ruby + perl + dev_gui_common + dev_gui_frameworks_common
                  + dev_gui_stubs_common + gui_frameworks + gui_stubs
    all   = stock + jsc + webkit + cli_extra + cli_dev_gui_stubs

Where the port stands: `result-graph-ref` is the **cli** graph, and against it the port
covers 759 of 871 link edges (87%) with 6 unmapped install entries. So "87%" means 87% of
`cli`, not of Darling. `cli` is the current front; `stock` (which is what an ordinary
Darling install is) adds the GUI framework and stub trees plus the three scripting
languages; `all` adds WebKit and JavaScriptCore on top.

Order of attack, each stage gated on the one before:

1. **cli to 100%** -- close the last install entries and link edges, keep every check green.
2. **stock**. The flake already builds a `stock` graph (`packages.cider-graph`), so
   coverage can be measured against it the day cli is done. Expect the GUI frameworks to be
   the bulk of the work and dev-stubs to be cheap.
3. **all** -- jsc and webkit last; they are the largest single consumers and depend on
   everything before them.

Two things to hold onto while working the near term. Coverage numbers are always relative
to the graph in `result-graph-ref`, so state which component a percentage refers to.
And the reference build is a wasting asset: gen-mig-from-ninja.py, gen-buck-from-ninja.py
and gen-install-from-manifests.py all read it, and it disappears when cmake does, so every
generator needs to be re-runnable before that happens.

### Near-term queue (stage 1, cli)

Re-derive before trusting: `scripts/buck-coverage.py --missing` and
`scripts/gen-install-from-manifests.py`.

1. **The `all` component.** Sized and started; see "Stage 3" above. Three targets left
   and each has a known cause: JavaScriptCore (HANGS buck2 with the daemon at 0% CPU,
   reproducible across a daemon restart -- the real blocker), MachExceptions_xtrace_mig
   (does not link) and the 9 dev-stub frameworks the coverage metric hides behind their
   basename collision with the real frameworks.

   Start with the GUI framework dylibs: they are 362 of the 497 missing edges, and
   everything else in stock sits downstream of them. The 16 linux/native ELF wrappers are
   already done, see below; the rest are Darling's own framework implementations under
   darwin/frameworks (101) and darwin/private-frameworks (45), plus 314 in pins which is
   mostly python, ruby, perl and their extension modules.

   Stage 2 is effectively complete: 1354 of 1359 stock link edges. The five that remain
   (DBusKit, iokitd, bsdln, getuuid, elfdep) have their blocks removed and their causes
   written up above. The next item is THE STOCK SWITCH itself, which unlike everything
   else in stage 2 does change buck/prefix/BUCK, so it needs the runtime checks and the
   guest-nix milestone run rather than skipped.

   Beware NAME COLLISIONS when driving the generator by cmake target name across the wider
   graph. `X11` is both the linux/native wrap_elf stub and CoreGraphics' X11 backend in
   darwin/frameworks, and `gen-buck-from-ninja.py --dylibs X11` silently picks the latter.
   cli was small enough that names were unique; stock is not.

2. **The 9 genuinely unported in-scope cli edges**: bsdln, elfdep, getuuid (host tools),
   csparser.bundle, lzfse, ping, vifs, libbind9_isccc.a, libopendirectory_internal.a. None
   is installed by the cli component, which is why UNMAPPED is 0 without them.

2. **launchservicesd** (darwin/frameworks/CoreServices/src/LaunchServices/launchservicesd;
   launchservicesd.m and LSBundle.m; links Foundation CoreServices FMDB sqlite3 z).
3. **hdiutil** (buck-src/darling-dmg; wants fuse, a HOST library, so check how the reference
   supplies it before assuming this is portable).
4. **Make the generators re-runnable** before the reference graph goes away.
   gen-mig-from-ninja.py is the worst case: buck-split-pins.py has since rewritten its
   committed blocks' `defs` to labels and changed `out_base`, so regenerating would clobber
   them and the last fix had to be spliced in by hand.
5. The other four host tools (bsdln, elfdep, getuuid, wrapgen). Not install entries and not
   used by the port, so low priority.
6. Task #11 per-action source filtering; #10/#12 NixOS VM; #63 exec-cross-arch; #57 linker;
   #26/#39 nix-ninja.

---

## Harness traps (read before writing a check or blaming the port)

Every one of these presented as "the port is broken" when it was the harness. The rule that
falls out: when a script and an identical hand-run disagree, the SCRIPT is the suspect. That
has been true six times running, each time a check freshly written.

- **`llvm-nm`, never bare `nm`, for Mach-O.** Inside `nix develop` the bare name is the
  clang wrapper's binutils nm, which answers "file format not recognized" and, with stderr
  discarded, yields an empty symbol list indistinguishable from a library missing
  everything.
- **Capture, then match, in buck-test.nu.** Under the bash suite `cmd | grep -q` reported
  FAILURE on a MATCH (grep exits early, the writer takes SIGPIPE, pipefail propagates it);
  under nushell a non-zero external in a pipeline throws instead. Either way: collect the
  output once with `complete`, then test it.
- **What invalidates the Nix endpoint** (measured from two graph derivations, not
  assumed): the graph takes the staged project as one store path, and that path holds
  the BUILD tree only -- `buck/ src/ darwin/ linux/ tests/ etc/ misc/ patches/
  templates/ tools/ buck-src/ buck-rust/` plus the root dotfiles. (`cmake/` was in this
  list until #82 removed cmake; it no longer exists.) `scripts/`, `nix/`,
  `docs/`, `plan/`, `PLAN.md` and `flake.nix` are NOT in it, with three exceptions that
  are their own inputs: `scripts/buck2-graph-dump.py`, `scripts/buck-src-normalise.py`,
  and `nix/lib/ciderBuck2{Graph,Lower}.nix`, which ARE the derivations.
  `scripts/buck-endpoint-stale.nu` answers this in a second, and it now takes the rule from
  the two filters rather than from a listing of the result: both drop `tests/**/*.nix`, so
  editing the VM test is NEUTRAL (measured: the prefix derivation did not move, and
  `nix build .#cider-buck2` afterwards consumed the very store path the earlier build had
  produced), while `tests/buck2/**` holds real targets and is not.
- **Evaluating the endpoint: 155s to 58s, measured with the eval profiler.**
  `nix eval --raw .#cider-buck2-prefix.drvPath --eval-profiler flamegraph
  --eval-profile-file <f>` works in nix 2.34 and puts 57 percent of the self time in
  ciderBuck2Lower.nix. Three output-preserving fixes: the staged-tree script escaped the
  same destination TWICE per link (155 to 68), argv escaping now runs once per DISTINCT
  argument since 97.5 percent of 208,515 entries repeat (68 to 60), and staged link targets
  the same way at 45 percent repeats (60 to 58). Each one is safe because the prefix
  derivation does not move; that identity is the check.
  What is left: about 40 percent is still the staged-tree script, which emits two escaped
  shell lines per link. Removing that means emitting a table plus a loop, or having the
  dumper emit it, either of which CHANGES an input or the output and so costs a full
  endpoint rebuild to verify. `lib.unique` is 3 percent and order-sensitive here, so it
  stays.
- **58 seconds is not a regression from the 9 seconds of commit 45098ec. The graph grew.**
  That measurement was 1,115 staged trees; graph.json is now 1.62 GB holding 5,282 trees
  with 3,581,461 links, 27,591 actions and 3,225 targets. Per staged tree the evaluation
  costs 10.7k function calls and 3.9 MB today against 17k and 5.6 MB then, so the work per
  unit of graph went DOWN; the absolute number went up because the port did. Getting under
  10 seconds again at this scale is a structural change, not another micro-fix.
  Section sizes come out of graph.json in under a second, without parsing 1.62 GB, because
  the dump writes it with `indent=2` and `sort_keys=True`: `grep -bn '^  "[a-zA-Z]*":'`
  gives every top-level key with its byte and line offset, and the counts are then line
  arithmetic (`^    "` is an entry, `^      "` is a link).
- **THE NIX ENDPOINT BUILDS A WORKING DARLING, END TO END, FOR THE FIRST TIME.** 8,472
  derivations, zero builder failures. The prefix is 622 MB and 34,126 files with
  `bin/cider`, `bin/ciderd` and `bin/cider-coredump`, and
  `scripts/buck-bash-check.nu --prefix result/cider_prefix__prefix` PASSES: the container
  boots and prints `BUCK2_BASH_OK 3.2.57(1)-release x86_64-apple-darwin19`, which is the
  Darwin bash and not the host's 5.x. Wall time: 29m41s for the graph, then about four
  hours for the lowering, most of it two avoidable problems (#48, #52).
  THREE OPERATIONAL TRAPS, each of which cost a run:
  1. `nix-daemon` forks a worker per CONNECTION that grows 8-9 MB per derivation BUILT
     (11.1 GB at 1,171, 15.3 GB at 1,873, swap to 9.1 GB), which extrapolates past this
     machine's 30 GB and is why the endpoint had never finished. It is all returned on
     disconnect, so CYCLE THE CONNECTION: `timeout 900 nix build ...` in a retry loop, since
     nix resumes from the store. Capping `--max-jobs` does not help, the growth is per
     derivation processed.
  2. BUT A CYCLING WINDOW MUST EXCEED THE LONGEST SINGLE DERIVATION or it livelocks. The 15
     minute window killed `JavaScriptCore_obj` (54 minutes on its own) and restarted it from
     zero, twice, before this was spotted. Drop the timeout for the last few derivations.
  3. The harness KILLS BACKGROUND JOBS THAT GO SILENT. Two runs died that way, one piped
     through `tail` (which buffers to exit, leaving a ZERO BYTE log and nothing to diagnose)
     and one compiling JSC quietly. Run with `-L` AND a heartbeat, and never through `tail`.
- **THE ROOT INVALIDATION CAUSE IS THE GRAPH DERIVATION ITSELF (#56), and #50, #53, #54 and
  #55 are all downstream of it.** `ciderBuck2Graph.nix` takes the project as ONE
  `builtins.path` that excludes only plan, docs, nix, scripts and a few dotfiles, so
  `darwin/`, `pins/`, `linux/` and `buck-src/` are all in it. Edit one C file and the graph
  rebuilds (30-47 min of buck2 analysis), its drv moves, and every lowered derivation moves
  with it, because each binds to the graph's DERIVATION rather than to its output. No amount
  of per-target or per-group granularity can matter beneath that. The comment on that filter
  already said so: keying the graph on the build DEFINITION rather than on file contents is
  the next step. The fix is to split ANALYSIS (BUCK, .bzl, configs, plus a NAME manifest of
  the sources) from MATERIALISATION (real sources, producing staged/ and treelinks/).
  WHAT THIS COSTS IN HINDSIGHT: four mechanisms were built and flagged off before anyone
  measured a one-file-edit rebuild. Measure that FIRST next time; it is the only number the
  work is for.
- **DONE (#53): a buck-src PIN can be lowered as ONE derivation, and the merge is
  byte-identical.** The dump decides WHICH pins, because contracting a DAG can create
  cycles and this graph has them: 43 of 157 pins form one strongly connected component over
  the system cone (Libinfo, cctools, corefoundation), mutually dependent at target level
  though the target graph is acyclic; `coarse_pin_map` runs Tarjan and offers only the 114
  that are clean, covering 1,310 of 3,225 targets. `groupOfLabel` is then a lookup.
  Verified on a real merged pin rather than a full rebuild: `pin-JavaScriptCore` merges five
  targets and its 1,091 files contain all 1,082 of `JavaScriptCore_obj` with ZERO checksum
  differences, the extra nine being exactly the other four targets' objects. 23 minutes.
  STILL OFF BY DEFAULT. Flipping `coarsePins` is a separate decision and wants the full
  coarse prefix built and diffed first; the expected win is ~1,196 fewer derivations and 31
  percent fewer staging passes, NOT less compile work.
- **#44: the narrowing gap was 25 quoted includes, and depfiles were not needed to close it.**
  HISTORICAL as of 2026-08-09: `narrowSources` is deleted, so this gap no longer gates
  anything. The comment it argued with said only depfiles could answer this case, and that
  narrowing waited on a 90 minute build. Both were wrong; it measured on the host in ten
  seconds, which is the transferable part.
  I FIRST REPORTED FIVE, and that was too narrow: I scanned only includes spelled `../`
  and missed the subdirectory form, which is the same problem (`libcxxabi` reaching for
  `include/atomic_support.h` and `demangle/ItaniumDemangle.h`, `fseventsd.m` for
  `linux/fanotify.h`). The closure in the dump always covered both; only the count was
  wrong. `scripts/buck-include-closure-check.py` now measures it properly and is verified
  both ways: 25 against a pre-closure graph, 0 after.
  The narrowing that matters: of 64,903 C-family files, 734 have a quoted `../` include and
  93 are uncovered, but 40 name a file that does not exist (guarded out) and 48 of the
  remaining 53 are vim GUI files this port never compiles (`gui_x11.c`, `gui_motif.c`,
  `gui_gtk.c` have ZERO compile actions, against 1 for `YarrPattern.cpp`). Never judge a
  gap by its raw count; judge it by what is actually compiled.
  #49 is answered too, and the answer is DO NOTHING:
  dropping `indent=2` saves ~0.4s of parse and destroys the `grep -bn` section-offset trick
  used repeatedly to measure this graph, and interning `target-sources.json` only matters
  once narrowing is on, so it belongs with #44.
- **`nix-diff <old.drv> <new.drv>` answers "why did this rebuild", and it is already
  installed.** It walks the derivation tree and names the first real difference, which for a
  content-addressed dependency is the thing that is otherwise hard to see: a consumer binds
  to the producing DERIVATION, not to its output path, so it prints
  `The input derivation named cider-buck2-graph.drv differs` and then `Sources: - old
  buck2-graph-dump.py + new`. That is the whole #55 cascade in one command. It beats
  decoding the `text` env var out of a `.drv` by hand, which is how this was first found.
  Pair the SAME artifact across the two revisions, not two different variants: comparing the
  default prefix against the coarse one just reports pin merging and tells you nothing.
- **VERIFY ON ONE DERIVATION, NOT ON A FULL PREFIX REBUILD.** #50 was proven on
  `.#cider-buck2-lowered` in minutes and #52 on a single target in 10 minutes, both by
  diffing a sorted file list plus per-file sha256 against a known-good output. Queueing #53
  behind a 3 hour rebuild of all ~8,400 derivations tested nothing that
  `nix build /nix/store/<hash>.drv^out` would not have caught, and blocked every other
  increment while it ran. Reach for a whole-endpoint build only to produce the deliverable,
  or when the change really does touch every derivation, and say which it is.
  Two related traps: a CONTENT ADDRESSED drv holds a deferred placeholder, so grepping a
  `.drv` for a store path finds nothing and the derivation has to come from the closure;
  and for the same reason the check is whether nix RERUNS THE BUILDER, not whether a
  drvPath moved.
- **#55 DONE. #54 IS NOT, AND EVERY SHORTCUT TO IT IS NOW CLOSED BY MEASUREMENT.** The goal is
  reachable: with `sourceGroups` on, editing `ACAccount.m` and rebuilding
  `libsimple_ciderd` ran **0 builders**, against 323 with neither flag. What fails is
  every available way of getting there.
  **Splitting the source into per-subtree stores cannot work for this tree.** A group is staged
  as one symlink to its own store path, and **2,306 of the 2,970 symlinks under `darwin`, `src`
  and `linux` are relative and cross a group boundary** (15 groups; `darwin/Developer/Platforms`
  2,189, `frameworks/SystemConfiguration` 52, `darwin/opendirectory_internal/include` 24). The
  endpoint failed 1,194 targets on `CoreServices/MacTypes.h`, which is itself a link to
  `../../../../basic-headers/MacTypes.h`. Two fixes were tried and both fail:
  1. A LINK FARM CANNOT REPAIR A RELATIVE ESCAPE. The kernel resolves `..` against the REAL
     parent once it crosses the farm symlink, so
     `readlink -f <farm>/src/external/IOKitUser/darling/submodules/xnu` gives `/nix/store/xnu`
     while `<farm>/src/external/xnu` exists and is never consulted.
  2. REWRITING ESCAPES TO ABSOLUTE PATHS RELOCATES THE PROBLEM, since the destination store has
     escapes of its own: for the pins it took 143 dangling links to **413**. The SDK
     `usr/include` extracted alone is **1,987 dangling of 1,987 symlinks**, against 0 of 2,928
     inside the assembled tree. It is nothing but relative links into the rest of the project.
  **Neither flag cut it either.** `sourceGroups` has the right granularity and the wrong
  mechanism; `narrowSources`, deleted since, was the reverse, because `projectSrc` was ONE
  union shared by every target (probed: the compile RAN). And their combination was closed at
  evaluation time: one
  `builtins.path` union costs **~4 seconds**, so 3,225 of them is **3.6 hours of eval**.
  **What is left untried** is the same idea at BUILD time: one CONTENT-ADDRESSED SUBSET
  DERIVATION PER TARGET, cut from the shared `projectSrc` and reproducing the project layout.
  One root so the web resolves, one shared input so the daemon does not blow up (147 distinct
  paths per staging script is what took it to 4.9 GB and stalled it), and an output addressed
  by the subset so an unchanged target collapses to the same path.
  `scripts/buck-escape-check.py` is what measures all of this: `groups`, `pins --root
  <assembled>`, `resolve <dir>`, and it refuses to pass when it walked no symlinks.
  **THE LAYOUT THAT SUBSET DERIVATION HAS TO REPRODUCE IS NOW KNOWN, and it is cheaper than a
  copy: REAL DIRECTORIES PLUS ONE SYMLINK PER FILE.** What broke the link farm was that a GROUP
  was staged as one symlink to a DIRECTORY, so `..` left the tree. Per FILE it does not: the
  containing directory is real and inside our own tree. Tested with clang on a scratch tree,
  both cases that matter and a negative control that really fails:
  `#include "../d.h"` through a per-file link **exit 0**; a staged source that is ITSELF a
  relative symlink **exit 0**; the same include with the destination NOT staged **exit 1**.
  The rule that makes it hold is the one the closure already applies: when a staged path is a
  symlink, stage its DESTINATION too.
  **AND IT HOLDS AGAINST REAL READ-ONLY STORE PATHS**, which the scratch test did not cover:
  the two groups realised with `builtins.path` (mode 444, `dr-xr-xr-x`), staged by the exact
  shell `stageGroupsFor` now emits. 0 staging errors, `MacTypes.h` resolves, 147 symlinks and
  28 real directories, and the store source is unmodified afterwards. The only 2 dangling links
  point at `src/external/...`, which this partial stage deliberately did not plant, because
  pins arrive from the `wantedPins` section rather than from a group.
  **AND THE SDK INVERTS THE WHOLE IDEA FOR A COMPILING TARGET, measured.** Every darwin compile
  needs `darwin/Developer/Platforms`, and that tree is a HUB: 2,633 symlinks reaching TWELVE
  roots (1,898 `src/external`, 444 `darwin/Developer`, 118 `darwin/frameworks`, 57
  `darwin/private-frameworks`, 34 `build/src`, 23 `darwin/basic-headers`, then `darwin/launchd`,
  `darwin/libm`, `darwin/sandbox`, `darwin/CoreAudio`, `darwin/libacm`,
  `darwin/libDiagnosticMessagesClient`). Counted as GROUPS:

  | | |
  |---|---|
  | distinct groups referenced by all 2,339 targets combined | **90** |
  | groups the SDK alone links into | **255** |
  | median groups per target | 24 |

  **CORRECTION, and the conclusion I first drew from those numbers was WRONG.** A compile does
  not read the SDK at its project path at all. Every one of the 58 include roots of
  `SecItemShimOSX_obj` is a `buck-out` STAGED FARM, the SDK among them as
  `.../__sdk_repo_include__/...`, and the lowering stages farms by their own mechanism. So the
  255 counts links INSIDE a tree that is reached through a farm, and staging the SDK as groups,
  or as one pre-assembled artifact, addresses neither. I built that artifact, it was correct
  (it carried the destinations and its internal links resolved), and the target failed exactly
  as before. Removed.

  **THE REAL RULE IS ONE LINE: A STAGED FARM'S LINK DESTINATIONS MUST BE STAGED, TRANSITIVELY.**
  The closure records hop one (the farm's link target). It misses the hops after it, and this
  tree is full of them: `usr/include/os/log_private.h` is a link to
  `src/external/libtrace/...`, and `usr/include/IOKit` is a link to
  `../../System/Library/Frameworks/IOKit.framework/Headers` which does not resolve in the repo
  at all. Every remaining grouped-staging failure has been an instance of this, so the fix is
  the transitive closure and not another destination.

  **THE CLOSURE'S ONE SILENT FAILURE MODE IS MEASURABLY ABSENT HERE (#69).** The per-target file
  list is inferred, and the way that could be wrong WITHOUT a build error is an `#include`
  the regex cannot resolve, i.e. one assembled from a macro. Counted:

  | | files | non-literal `#include` |
  |---|---|---|
  | first-party (`darwin`, `src`, `linux`) | 26,884 | **0** |
  | pins (`buck-src`) | 81,835 | 424 (0.52%) |

  The pin ones cannot bite, because pins are staged WHOLESALE: `pinsTree` carries each pin in
  full, so a macro include inside one always resolves. The inferred list only gates FIRST-PARTY
  groups, and there the count is zero. The regex also over-approximates by ignoring `#if`, which
  is the safe direction. So #69 is about genericity and deleting a pass, NOT about correctness
  risk, and the "silent wrong output" framing was wrong.

  **#54 IS DONE. THE GROUPED ENDPOINT IS BYTE IDENTICAL AND THE CASCADE IS CUT.**

  | | |
  |---|---|
  | `.#cider-buck2-prefix-min-grouped` | 1,617 builders, 0 root failures, 70 min |
  | content hash | `sha256-hkJQ0xJVx6tDzrBt2bsISkYDCvJtNXsQ08NTwxk9ADQ=`, the recorded one |
  | probe: unrelated `.m` edit, `SecItemShimOSX_obj` | **2 builders**, target NOT rebuilt, output path IDENTICAL |

  The probe target is the one that reads through a nested submodule and exposed the per-pin
  store regression, so it is a check that can fail. The two builders that do run are
  `cider-buck2-skeleton` and `cider-buck2-sources`, the graph-side content passes.
  What made it work, after `sourceGroups` had the right granularity and the wrong mechanism for
  months: MIRRORING instead of directory links (groups AND pins), and `pinsTree`, one CA tree of
  all 147 pins whose escape destinations come from their own store paths rather than from the
  project.
  Root failures on the way down, each from a real run: **90** (coarse pins had no group entry)
  to **9** (non-pin `src/external`) to **1** (a `script_gen` needs those too, not just compiles)
  to **0**.

  **AND POINTING pinPath AT THE PER-PIN STORES BROKE THE DEFAULT ENDPOINT. Reverted (#74).**
  Seven pins carry nested submodules, and the per-pin store does not have their content, so the
  pin's own link `darling/include/IOKit/IOReturn.h ->
  ../../../darling/submodules/xnu/iokit/IOKit/IOReturn.h` dangles INSIDE the store.
  `stageProject` uses `pinPath` too, so this was not confined to grouped staging:
  `SecItemShimOSX_obj` failed on `prefix-min`, an endpoint that had built green with a matching
  prefix hash. The revert rebuilt **0 builders**, i.e. it resolved to the cached pre-regression
  output.
  Not pinStore's fault, and not the fetch's either: `src/external/IOKitUser/darling/submodules/
  xnu` IS ITSELF A SYMLINK, to `../../../xnu/`, which resolves to a SIBLING PIN. The "1 entry"
  was that link. In the assembled tree it resolves (23 entries); planted as
  `ln -s <pinStore> src/external/IOKitUser` the kernel takes `../../../xnu` against the STORE,
  so it dangles. THE SAME MECHANISM as the group-directory link that failed 1,194 targets on
  `MacTypes.h`. `scripts/buck-escape-check.py` documents this exact case, naming this exact
  file, and I walked into it anyway.
  **So the fix is the session's own result applied to pins: ONE CA `pinsTree` holding all 147
  pins MIRRORED (real directories, one link per file) at their `pins/<name>` paths.**
  Self contained, so a sibling escape resolves inside it; input is the frozen pins, so it moves
  only on a pin bump, which is the cascade cut per-pin `pinPath` was reaching for.
  `scripts/buck-pin-store-check.nu` passes throughout, because it compares by NAR HASH and a NAR
  hash records a symlink TARGET as a STRING. `buck-escape-check.py` documents that exact trap,
  for this exact class of bug, and the pin check still uses the method it warns against.

  **THE PIN PATH WAS THE LAST SHARED INPUT, not the groups.** `pinPath` was
  `"${ciderSrc}/${p}"` and `ciderSrc` is the whole project, so every staging script that
  named a pin moved on any edit. Taking pins from `ciderSrc.pinPaths` instead, which the
  GRAPH has done since the per-pin split, is what finally cut it: on one target, an unrelated
  `.m` edit went from 6 builders to **2**, neither of them the target, and the target's output
  is the SAME store path either side of the edit.
- **#54 MEASURED, and per-target granularity is worth a lot: the median edit would rebuild 5
  targets instead of 2,339.** From `target-sources.json`: 2,339 targets, 74,621 distinct files,
  6,419,328 (target, file) pairs. Blast radius of editing ONE file, if each target depended
  only on what it reads:

  | percentile | targets invalidated |
  |---|---|
  | p25 | 2 |
  | **p50** | **5** |
  | p75 | 27 |
  | p90 | 78 |
  | p99 | 1,265 |
  | max | 1,267 |

  22 percent of files are read by exactly ONE target, 58 percent by ten or fewer, 94 percent by
  a hundred or fewer, and **no file is read by more than 1,267 targets**, so even the worst case
  is half the project rather than all of it. Today every edit rebuilds all 2,339.
  The cost side, same source: the median target reads 4,048 files (p90 5,640, max 13,726), so
  2,339 subsets is about 9.5 million entries. That rules out COPYING (tens of GB) and points at
  symlink farms, which work here for the reason group staging did not: every directory is real
  and only the leaves are links, so a relative link inside the subset resolves against the
  subset instead of escaping into another store path. Rough cost is derivation overhead, about
  2,339 builds, not the link creation.
- **#64: ld64 is content addressed, and narrowing its source is NOT possible as scoped.** The
  rebuild no longer propagates (its outputs from a clean tree and from an edited one are bit
  identical), but it still costs 26 to 28 minutes on any first-party edit. The plan was to drop
  `darwin/frameworks` and `darwin/private-frameworks` on the premise that the linker compiles
  nothing in them. **That premise is false**, and two fast experiments show it:
  deleting the trees fails at cmake GENERATE, not on dangling SDK symlinks but on
  `add_dependencies(QuartzCore CoreVideo)` in `src/external/cocotron` reaching a target defined
  under `darwin/frameworks`; and blanking only the implementation files gets past configure and
  then fails at LINK, because CFNetwork needs `_SCNetworkReachabilitySetCallback` and friends
  that `darwin/frameworks/SystemConfiguration` defines.
  One measurement explains both: **this ld64 derivation compiles across 369 distinct
  directories**. It is most of Darling, not a cctools build, which is also why it takes half an
  hour. Reducing it means changing WHAT it depends on in cmake, not which files reach the
  derivation, and that work should start from the ninja graph (26,351 edges) rather than from
  guesses about directories. Both experiments are reverted.
- **#70 CORRECTS THE ABOVE: it was never a property of ld64, it was two wrong target names.**
  Taking #64's own advice and starting from the ninja graph, the transitive closure over
  inputs, implicit inputs and order-only inputs says:

  | target set | edges | compiles | dirs |
  |---|---|---|---|
  | `x86_64-apple-darwin20-ld` alone | 42 | **40** | 7 |
  | ld64 + everything `cctools-port/misc` offers | 82 | **62** | 9 |
  | bare `install_name_tool` | 3,510 | 3,113 | 197 |
  | bare `nmedit` | 3,510 | 3,113 | 197 |
  | **the four names `buildFlags` passed** | 3,515 | **3,114** | **197** |

  `cctools-port/cctools/misc` defines NO `install_name_tool` and NO `nmedit`, only `lipo`, so
  ninja resolved those bare names to the GUEST tools under `darwin/xcselect`. That is where libc
  (635 compiles), icu (446), xnu (415), compiler-rt (139), corefoundation (127) and Libinfo
  (106) came from, and it is the 369 directories.
  **AND THE RESULT WAS DISCARDED**, which is what made the fix safe rather than a trade-off:
  `installPhase` looked for them under `cctools-port/cctools/misc`, where those targets never
  wrote, so its `find` failed and the `note: not built` branch fired. Checked three ways that
  nothing consumed them: the lowering never names them, no action's argv invokes them, and the
  only actions mentioning them BUILD them (precisely the `darwin/xcselect` shims ninja resolved to).
  VERIFIED: dropping the two names reproduces
  `sha256-tHH+BndVNL2V8g9iM7++iD/aGY3Pz5AirmcwEqJSblc=` exactly and collapses onto an EXISTING
  store path, so no consumer moves. The oracle was confirmed live first: three separate ld64
  outputs in the store all carry that hash.
  **THE WALL-CLOCK SAVING IS NOT THE 50x THE COMPILE COUNTS SUGGEST.** It ran in 1,290s (21.5
  min) against a recorded 26 to 28, but it shared the machine with a 1,049-derivation endpoint
  build throughout, and the recorded baseline was taken under unknown load. The compile cut
  (3,114 to 62) is certain; the time saving is not cleanly attributed, because the whole-project
  cmake CONFIGURE that both pay is now the dominant term. A fair number needs an idle re-measure.
- **DONE (#68): one command, one evaluation, and a counter that self-tests.**
  `.#cider-buck2-one` is the endpoint's OWN derivation for `libsimple_ciderd`,
  reached through `cider-buck2-prefix-min` rather than lowered again, so it is the same drv
  the endpoint builds (both evaluate to `jahgjqzjq…`). `scripts/buck-quick-check.nu` builds it
  and counts builders that RAN, with a probe mode that edits, rebuilds, counts and reverts by
  stripping its own marker, so an interrupted run leaves something the next one can clean up.
  IT PROVES ITS COUNTER FIRST, by building a derivation carrying a fresh nonce that must
  report exactly 1; otherwise `ran=0` could mean the log format changed rather than nothing
  rebuilt. Verified both ways: a fresh build reads 1, a rerun reads 0.
  **The 12s evaluation is paid once per change to the FLAKE SOURCE TREE, not per build**:
  rerun unchanged 0.3s, rerun after editing `nix/` 12.3s with ran=0, first build 12.7s. So it
  bites only when iterating on the lowering itself, which is much less of the loop than the
  14.5s one-target figure suggested. #66 IS NOT AN EVAL SAVING HERE, measured rather than
  assumed: forcing 1,474 producer drvPaths against forcing the same 1,474 lowered outPaths
  runs 10.45 / 10.84 / 12.56 against 11.16 / 10.55 / 11.07 interleaved, which is a wash.
  builtins.outputOf needs the producer outPath, so binding through it instantiates one
  derivation per action exactly as the lowering does. What DID come out of the evaluator is
  the script: the lowering reads full.json and needs.json now and computes neither, 12.0 to
  10.6s, and that keeps whichever route wins. The earlier 0.6s figure was for moving the
  action scripts alone, which was a smaller and different change. That probe also
  confirms for the first time what the source filters promise: a `nix/` edit rebuilds nothing.
- **#69 MEASURED: the declaration gap is a PER-TARGET question, and it is 675 files.**
  `scripts/buck-declaration-gap.py` splits each target's source set into what buck2 SAYS (argv
  tokens, staged-tree link targets) and what the closure pass COMPENSATES for (include roots
  taken wholesale, quoted includes), and verifies that partition against
  `buck2-graph-sources.py` on all 2,339 targets. On the current graph, union 74,620 files:
  wholesale include roots are **2 directories, 25 files, 2 targets**; quoted includes are
  **675 files over 693 edges, reached by 1,266 targets**.
  THIS DOES NOT CONTRADICT the 5-then-0 of `buck-include-closure-check.py`, which asks whether
  the UNION misses a file entirely and only for `../` escapes. A header can be declared for
  one target through its staged tree and be quoted-only for another. Both stand.
  WHY THE PORT WORKS ANYWAY: `cc_objects` declares only `srcs`. `finger_obj` lists five `.c`
  files and no headers, while `lprint.c` includes `finger.h` from its own directory. Compiles
  run IN THE PROJECT TREE against project-relative paths, so that resolves only because every
  target is staged with the whole project. The missing declarations and the #54 cascade are
  one fact seen from two sides.
  THE MECHANICAL ROUTE beats hand-written globs: the reference `build.ninja` carries depfiles
  on **26,198 of 40,014 edges**, so one cmake build with its `.d` files kept states every
  header each object really read, angle-bracket includes included.
  `scripts/gen-buck-from-ninja.py` already generates these targets from that same ninja.
- **#65: the recorded ld64 blocker is WRONG, established by reading and costing no build.**
  `linux/buildtools/BUCK` says the compile dies in cctools' own `mach/machine.h` on
  `<mach/machine/vm_types.h>` and asks for `cctools/include/foreign` on the include path. Four
  facts say otherwise. `mach-o/loader.h` guards ALL its mach includes behind `#ifdef __APPLE__`
  and typedefs `cpu_type_t`, `cpu_subtype_t` and `vm_prot_t` itself in the `#else`, so a host
  compile never reaches `machine.h`, which is why the reference needs nothing, and its real
  `getuuid.c.o` command carries only `darwin/include`, `linux/buildtools/include` and
  `cctools/include`. `cctools/include/mach/machine.h` has NO `#include` lines, so it cannot be
  the file failing, while `foreign/mach/machine.h` includes `<mach/machine/vm_types.h>` at line
  64. `cc_header_root` stages by a plain prefix strip and `cctools_port_include` sets no
  `include_subdirs`, so `foreign/` cannot collide into the root. And `include/mach/` has no
  `vm_prot.h`, so a compile with `__APPLE__` defined would die on that first.
  **THEN MEASURED, and the compile the comment says fails SUCCEEDS.** Run clang directly, no
  buck2 and no Nix, against the same include root the BUCK targets already name:
  `clang -DDARLING -Ibuck-src/cctools-port/cctools/include -c linux/buildtools/getuuid.c` exits
  0, and so does `elfdep.c`. Verified it can fail: drop that one `-I` and it dies on
  `mach-o/loader.h` not found. `-H` says the headers opened are cctools' own `mach-o/loader.h`
  and `fat.h` and that **`mach/machine.h` is never opened at all**, and the host clang defines
  no `__APPLE__`, which is the guard doing its job. So no include path change is needed and
  `foreign` must NOT be added.
  The one remaining doubt was buck2's own staging, since globs do not traverse a symlinked
  directory (the recorded DBusKit trap) and `foreign/` contains one. **Bounded, and it does not
  matter here**: the whole root holds 331 real headers and exactly TWO symlinked directories,
  `foreign/arm` and `foreign/mach/arm`, both pointing at `i386`, together reaching 31 ARM
  headers that x86_64 never needs and that `foreign/` keeps off the include path anyway. The
  two headers these tools do need are real files. So nothing about staging blocks the host
  tools; running buck2 only confirms it.
  The stale comment stays put on purpose: it is a BUCK file, so correcting it alone costs ld64
  plus the graph. Fold it into the next batch.
- **DONE (#50): the graph derivation has two outputs and is content addressed, so a
  dump-format change no longer rebuilds the port.** `graph.json` and `target-sources.json`
  are read only by the EVALUATOR and stay in `out`; `staged/` and `treelinks/` are read only
  by the lowered BUILDERS and move to `data`. Recorded paths are relative, so the split is a
  move. Verified BOTH ways on `.#cider-buck2-lowered`: adding a key to graph.json rebuilt
  only the graph and left the target at the same output with no builder run, while writing
  one file into `treelinks/` moved the data path and did rebuild it; removing the probe
  returned to the identical baseline output.
  THE CHECK IS "DOES IT REBUILD", NOT "DID THE drvPath MOVE". A consumer of a content
  addressed output holds a DEFERRED reference carrying the producing drv, so its drvPath
  always moves and the old plan would have read a false negative. Nix resolves it after the
  dependency builds and reuses the output when the resolution is identical.
- **DONE (#52): a target's independent actions run concurrently. JavaScriptCore 54m to
  10m36s at only `--cores 8`, and the objects are IDENTICAL.** 1,082 files each way, zero
  difference in the file list and zero across all 1,082 sha256 sums, and the 10m36s even
  includes rebuilding the dependency chain that the serial baseline did not pay. The test
  needs no ordering pass: actions are in buck2 topological order, so an action reading none
  of its siblings' outputs cannot depend on anything already launched, which is one set
  membership. `_reap` checks every background job EXPLICITLY, because `set -e` does not
  catch a background failure and an unnoticed one is a target quietly missing an object.
  Bounded by `NIX_BUILD_CORES`, so pair `--cores` with `--max-jobs`: 6 jobs each allowed 22
  cores is 132 compiles. Evaluation is unaffected, 21.4s and 1.76 GB.
  VERIFIED AT FULL BLAST RADIUS, because it changed every builder: a complete rebuild of all
  3,199 target derivations (the 5,282 farms were untouched and reused) ran 4 cycles in
  1h48m with zero failures, and the resulting prefix is BYTE-IDENTICAL to the serial one --
  39,173 entries, no tree difference, no difference across all 34,126 checksums -- and still
  passes `buck-bash-check.nu`. What limits a rebuild is not compile parallelism but
  per-derivation STAGING, paid once per target derivation: concurrency oscillates 0 to 18
  with repeated stretches at zero. That is the argument for #53.
- **DONE (#51, #47): the endpoint evaluation is 22.4s and 2.49 GB, from 58.8s and 9.0 GB.**
  Allocation went 20.6 GB to 5.95 GB, calls 56.5M to 38.5M, and graph.json 1.62 GB to
  481 MB. Two changes, both moving work out of the evaluator: the dump writes the UNION of
  project sources instead of a per-target map that repeated it 85 times (the per-target
  breakdown now lives in target-sources.json, which only narrowing reads), and staged farm
  links travel as `treelinks/*.tsv` plus `*.dirs` tables that a fixed-size read loop
  consumes, so nothing in Nix is proportional to the 3,581,461 links. Together with the
  three escaping fixes earlier the same evaluation has gone 161s to 22.4s. The prefix
  derivation MOVED, by design, so the guard did not apply: verified instead by building
  `.#cider-buck2-lowered` and a real codegen target (dserver_rpc) out of the new graph,
  and by reading an emitted staging script. The diagnosis that led there is kept below.
- **How it was found, since the method transfers and the conclusions above do not.** The
  evaluation split into a PARSE (11.0s, 3.73 GB, `fromJSON` alone) and the LOWERING on top
  (48s, 5.3 GB), so both halves had to be attacked separately. The parse was large because
  the graph repeated itself 85 times, and the instructive part was WHICH branch caused it:
  the `-I` walk fires only 46 times over 3 directories, because 96.4 percent of the
  1,251,596 include roots already point into buck-out. The port therefore HAS the precision
  buck2 normally gives, a declared header farm per target, and the 85x was the dump
  FLATTENING those farms per consumer, recomputable from data already in the same file.
  Depfiles would have been a ninja-shaped answer to a buck2 question. Three source-tree
  include roots remain as rule bugs worth fixing on their own: `darwin/xtrace/include`
  (44 uses), `darwin/launchd/src`, `buck-src/security/OSX/libsecurityd/mig`.
- **IFD is not the problem. The 1.62 GB payload is. Do not bet on an experimental feature
  before fixing the representation.** recursive-nix works here, verified end to end: an
  inner derivation built from inside a build, INNER_OK read back out of the store. The
  gotcha, which cost one failed run, is that the socket is exposed as
  `NIX_REMOTE=unix:///build/.nix-socket` and NOT the daemon path, so exporting
  `NIX_REMOTE=daemon` fails with "cannot connect to socket at
  /nix/var/nix/daemon-socket/socket". Keep that as a FALLBACK. It and dynamic-derivations
  are CppNix-specific and long-experimental, and snix takes IFD as a supported feature
  rather than a wart. After #51 the graph is tens of MB rather than 1.62 GB, an IFD that
  size costs a fraction of a second, and the architecture that exists today becomes
  affordable without any experimental feature. Do #51 and #47, RE-MEASURE, and only then
  decide whether granularity still needs a lever.
- **The OOM was NOT eval, and this bullet used to say it was.** The evaluator holding a
  9.0 GB heap resident for the whole IFD build was a contributor and is now 1.76 GB. The
  cause is `nix-daemon`, which forks a worker per CONNECTION that grows 8-9 MB per
  derivation BUILT: 11.1 GB at 1,171 and 15.3 GB at 1,873, extrapolating past 30 GB for
  8,472. It is all returned on disconnect, so CYCLE THE CONNECTION rather than capping
  memory, and `--max-jobs` does not help because the growth is per derivation PROCESSED.
  Full detail with the endpoint milestone above.
- **nushell traps** (task #40, one increment each): a `(...)` inside `$"..."` is a
  subexpression, so a literal `(Phase 4.1)` calls a command named `Phase` and fails at
  RUNTIME, not at parse time; an `else if` must sit on the closing brace line or it parses
  as a call to `else`; raw strings are `r#'...'#`, never `r#"..."#`; `get` with a computed
  index takes `-o`, not a trailing `?`; `input` reads the terminal, not stdin; a def cannot
  mutate its caller's variables and its `$env` writes do not propagate out.
  **`default` substitutes for NULL, not for an empty string.** A flag declared
  `--scratch: string = ""` is the empty string when omitted, so `$scratch | default <x>`
  keeps the empty string. That made a scratch root empty, and a cleanup loop that killed
  processes whose exe lives under it matched EVERYTHING and killed an unrelated build.
  The older checks take such an argument as an optional POSITIONAL, which really is null.
- **file(1) strings**: `Mach-O 64-bit x86_64 dynamically linked shared library` and
  `Mach-O 64-bit x86_64 executable`. x86_64 comes BEFORE "dynamically". Copy an existing
  case rather than writing it from memory.
- **A whole-tree glob over a vendored pin dies on one dangling symlink**, failing the whole
  package with an error naming a subtree unrelated to what you built. Check with
  `find buck-src/<pin> -xtype l`; fix in `GLOB_EXCLUDE` in gen-buck-from-ninja.py.
- **MIG runs the C preprocessor over the .defs**, so its -D flags decide which routines
  EXIST. A mysteriously absent symbol from a MIG-generated library is a mig_flags question
  first.
- **Confirm a port with a direct `buck2 build <label>`**, never with buck-port.py's verdict.
  It also says "failed (no recognisable error)" when the cause is a package-level file
  error.
- **buck2 runs**: `nix develop --command nu -c 'source scripts/buck-env.nu; buck2 ...'`,
  nu rather than bash now that the file is nushell.
  Sourcing buck-env.nu alone is not enough: the direnv cache goes stale (rustc and bindgen
  went missing that way), and buck2's daemon inherits the client PATH at daemon START, so
  `buck2 killall` after fixing PATH.
- **Never pre-create DPREFIX.** cider treats an existing prefix as already set up, and
  launchd then boots into an unpopulated filesystem and stalls deterministically.
- **`pkill -f <pattern>` matches the command you are about to run** (exit 144). For
  containers use one ERE pattern: `pkill -9 -x 'mldr|cider|ciderd|shellspawn'`.
- **A `jj git push` "Could not read from remote repository" is the remote**, not you
  (`ssh -o BatchMode=yes git@tangled.org` shows an IPv6 connect timeout). Retry.
- **Rebuild costs**: touching buck/generated/sdk_headers.bzl or the ksmig mig_flags rebuilds
  essentially everything, roughly 14,000 actions, about 20 minutes.
- **Known flakes**, re-run before believing a failure: buck-bash-check.nu fails roughly 1 in
  5 with a core dump (shared SIGFPE); buck-smoke-check.sh failed once at 11/31 then passed
  3/3.
- **All three runtime checks failing together is usually the MACHINE, not the tree**, and it
  has had three separate causes so far, so work through them in order before believing a
  regression. (1) Leftover containers, especially after a guest-nix milestone, which leaves
  its own prefix and daemon behind: `pkill -9 -x 'mldr|cider|ciderd|shellspawn'`.
  (2) A wrong ARTIFACT at a right path, which looks identical from outside: read the
  `buck/prefix/BUCK` diff, which is how a dylib landing at usr/bin/login was found. (3) Load.
  Running the checks immediately after a large rebuild fails them; the same scripts pass on
  an idle machine minutes later. Boot the container by hand as the tiebreaker -- it takes
  seconds and tells you at once whether the tree or the harness is at fault:
  `DPREFIX=<fresh> DSERVER_LIBEXEC_PATH=$rt/libexec/cider
  DSERVER_MLDR_PATH=$rt/libexec/cider/usr/libexec/cider/mldr CIDER_NO_LAUNCHD=1
  $rt/bin/cider shell /bin/bash -c 'echo HELLO'`.
- **Measure before attributing slowness**, and revert a fix whose premise turns out wrong.
  gen-install-from-manifests.py's eight minutes were a per-entry repo walk, not the
  backtracking regex I first blamed.

Guest-nix milestone against a buck2 prefix: materialize it to an `rt` dir, then
`DSERVER_LIBEXEC_PATH=$rt/libexec/cider
DSERVER_MLDR_PATH=$rt/libexec/cider/usr/libexec/cider/mldr bash
scripts/build-hello-bypass.nu --mono $rt --prefix /tmp/cider-hello-m1-buck2`. Expect
`build_rc=0` and "Hello, world!".

---

## Working agreements

- **Verification is execution in a clean prefix**, not inspection. A task is done when its
  test runs green from a fresh prefix, not when the code looks right.
- **Small commits**, phase-tagged (`feat(phaseB.3): ...`), tests included, this doc updated
  in the same commit.
- **When blocked** (a nixpkgs-side change seems required, a licensing question, a
  divergence-class stop-the-line, or >1 day stuck on one signature): add a dated entry under
  Blockers with reproduction steps and stop that thread; take the next ranked item.
- **Insurance:** mirror the bootstrap-tools closure + key reference narinfo/nars to our own
  Cachix early (the oracle depends on cache retention past 26.05 EOL, end of 2026).

## Risk register

| Risk | Class | Mitigation |
|---|---|---|
| Silent output divergence (shim lies subtly) | correctness | Phase D oracle + stop-the-line |
| Stalls in event-loop-heavy builds (kqueue/poll) | fidelity | C.4b watchdog + stall triage |
| macOS-14 symbol surface larger than expected | scope | demand-driven ordering; stubs last |
| Mach IPC perf through userspace daemon | perf | measure during E; acceptable for CI |
| Cache retention past 26.05 EOL | infra | mirror reference closures to own Cachix |
| x86-only effort waste | strategy | ARCH tags; Phase F keeps the boundary honest |

---

## Blockers

Active blockers get a dated entry here (repro steps + what's stuck); resolved ones fold into
Gotchas or Open work. The known standing limitations are already tracked above — the launchd
portset deadlock (#47, bypassed by `CIDER_NO_LAUNCHD=1`), the SIGFPE exec-fidelity flake
(#44, retryable), and the nix-ninja full-graph `migHeaderIncsFor` blocker. Nothing else is
currently un-tracked.


The task #80 grouped-build eval-speed analysis moved to `docs/plan-history.md`.
