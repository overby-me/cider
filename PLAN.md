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
an hour.** `buck-escape-roots-check.nu`, `buck-pin-patches-check.nu`, `buck-pin-rev-check.nu`,
`buck-env-names-check.nu`, `buck-first-party-paths-check.nu`, `buck-labels-check.nu`,
`buck-pin-paths-check.nu`, `buck-host-includes.nu`, `buck-coverage.nu`.

**COUNT `^building`, NEVER the "these N derivations will be built" list.** The list overstates
the real work by nearly five times: gate12 listed 4,336 derivations and 895 builders actually
ran, because CA early cutoff removes the rest DURING the build. Judge by builders that ran.

**A BUCK EDIT IS NOT A FULL REBUILD ANY MORE** (#54, #79). The old advice to batch BUCK edits
is stale; the cascade was cut from 1,558 builders to 44.

**A RUNG 3 BUILD CAN WEDGE, SO WATCH IT:** `scripts/buck-stall-watch.nu <log>`.

### cmake is gone (#82), and five generators are FROZEN

buck2 is the only build. The reference `result-graph-ref/build.ninja` can never be regenerated,
so the generators that read it are provenance, not tools. **A rename cannot reach a frozen
artifact, so every READER of one must accept BOTH names.** That has now bitten three times:
`SRC_STORE_RE` in `gen-buck-from-ninja.py`, `PROJECT_MARKERS` in `buck-host-includes.nu` (which
made 98.7 percent of its population noise and kept it red for days), and `SRC_STORE_RE` again
in `gen-mig-from-ninja.py` (all 124 mig edges). When a check is permanently red and someone
offers to freeze its threshold, suspect the POPULATION first.

`result-graph-stock` beside it is ALREADY collected, so this is not hypothetical: a check whose
input can vanish must fail rather than pass when it does.

### The rename rule (#84, #78)

**Upstream keeps the old name in its paths, patch headers, repo and org; only FIRST-PARTY names
change.** `__DARLING__` is upstream, 772 times across 188 pin files, and keeps its name.
`buck-upstream-names-check` holds the upstream names as DATA and must never be swept.

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
`buck-labels-check.nu` and `buck-pin-paths-check.nu`, and are now wired in. The nine nix-free
checks together take 27 seconds, so running them before a long build costs nothing.

The denominator is 1451, not the 1452 this line used to claim: #71 ported duct-tape to Rust,
so `libdarlingserver_duct_tape.a` stopped being a link edge. The floor had been left at 1452,
above the achievable maximum, so that check could not pass at all until b82c9e32.

One suite failure remains, and it is not a build gap. Install **UNMAPPED 5**: four pre-existing
gaps plus the shellspawn plist, which the Cider rename renamed on disk while the frozen
reference still names the old one; deliberately not mapped away, since that would hide a real
divergence.

The host-header failure is **FIXED** (ec35926e), and it was never 1,275 defects nor a threshold
worth freezing. `PROJECT_MARKERS` in `buck-host-includes.nu` had been renamed to
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

**Two guest checks stand outside that command, because each needs an artifact the suite cannot
make on its own.** `scripts/buck-darwin-rust-run.nu` runs a Mach-O Rust binary in the guest
(#96 route A), and `scripts/buck-rpath-check.nu` proves dyld still expands `@rpath` there. Both
take a prebuilt prefix artifact with `--art`; the rpath one also takes the two probes, whose
four-line sources and exact rustc commands are recorded in its header. It runs THREE times and
the last two are the point: move the dylib off the rpath and the run must fail NAMING
`@rpath/libciderrpath.dylib`, then set `DYLD_LIBRARY_PATH` and the same layout must pass again,
which is what separates an rpath-expansion failure from an unloadable dylib.

### What 100 percent does NOT mean

- **32-bit is not built and will not be.** `libsyscall_32` and the 74 i386 mig edges. A
  deliberate scope reduction: the long-term target here is aarch64.
- **cctools ld/ar/ranlib come from Nix** rather than being built.
- **The link-edge metric counts link edges.** Generated files are measured separately by
  `scripts/buck-codegen-coverage.nu`: 227 outputs are unconsumed and all are mig side
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
  SDK farm and surfaces an hour later as a missing header. `buck-pin-rev-check.nu` asserts no
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

### #95 - migcom stamped the build time into every stub, so 110 groups never cached (DONE)

migcom wrote the wall clock into every generated stub, so two builds of the same inputs at
different times produced different bytes, and under content addressing that defeated early
cutoff for everything downstream of a mig group. Found by #66's full-graph comparison: 1,364 of
1,474 groups identical, 110 differing, all 110 mig.

Fixed by `patches/bootstrap_cmds/0001-migcom-honour-source-date-epoch.patch`. A freshly built
mig group now reads `stub generated Tue Jan  1 00:00:00 1980`. Guarded by
`scripts/buck-mig-epoch-check.nu`, which builds ONE mig group instead of the whole graph and is
in `buck-test.nu`.

Full detail, including the copy I got wrong first: docs/plan-history.md, "#95 in detail".

### #96 - a first-party source edit and the group cascade (ANSWERED 2026-08-12: THERE IS NO CASCADE)

**THE PREMISE IN THE OLD TITLE WAS FALSE.** It read "a first-party source edit still
invalidates every group that stages the project". Measured on the endpoint, it invalidates
**zero** groups.

**THE MEASUREMENT.** `scripts/buck-quick-check.nu --attr .#cider-buck2-prefix-min --probe
darwin/frameworks/AVFoundation/constants.m`, which builds the endpoint, appends a nonce comment
to one first-party source, rebuilds, counts builders that RAN, and reverts:

    counter self test           ran=1, so the counter can report non-zero
    baseline                    ran=1 in 937.5 s   (the endpoint was warm)
    after editing one .m        ran=2 in 1276.6 s
                                cider-buck2-skeleton
                                cider-buck2-sources
    of the 1,474 groups         ZERO
    ld64                        did not rebuild
    graph                       did not rebuild

**THE POSITIVE CONTROL IS THE POINT, because a zero needs one.** `cider-buck2-sources`
rebuilding proves the edit REACHED `projectSrc`. Without that, ran=2 would be indistinguishable
from a probe that measured nothing, and the file was checked against the source filter
beforehand for the same reason: `nix/lib/cider-src.nix` excludes only top-level names plus every
file called `BUCK`, and `darwin/` is kept.

**WHAT THE TWO REMAINING BUILDERS ARE.** Not a cascade: `projectSrc` is an input to the graph
derivation, so when a source changes it must be re-derived. Two derivations and a re-resolution
is the floor, not a defect.

**WHAT THIS SUPERSEDES.** The figure on record was "323 compiles and still climbing" from a
probe predating #54, #74, #79 and #95. It is 2. And the entry's own stated cause was the wrong
code path: it blamed `stageProject` embedding the whole `projectSrc`, which is the
`sourceGroups` = OFF path, while every endpoint sets it ON and goes through `stageTextFor` plus
`pinStageLines`, whose pins resolve through `pinsTree` from frozen per-pin stores. #54 narrowed
the groups, #74 gave the pins a self-contained mirrored tree, #79 gave the escape destinations
their own store paths. Those three closed this between them; nothing here needed implementing.

**TWO STALE CLAIMS THIS KILLED, both now corrected in place.** `nix/lib/cider-src.nix` justified
excluding BUCK files by "ld64 is built from this tree (nix/cctools-port.nix) ... 26,351 compile
steps", and `buck-quick-check.nu` predicted "6 builders, 17.5 minutes" with ld64 rebuilding. That
file no longer exists and #65 made ld64 the buck2-built linker. The BUCK exclusion RULE still
stands, on the smaller measured reason above.

**NOTHING TO DO.** Do not implement the fix this entry used to propose. Re-run the probe if the
staging or source-filter code changes; that is what it is for.
### #66 - get the lowering out of the evaluator (DONE 2026-08-11)

BOTH HALVES DONE. A general buck2-graph to dynamic-derivation bridge, worth having for OTHER
projects; cider is the first CONSUMER, not the target.

**THE RESULT.** The whole 1,474-group graph builds through the emitted route and reproduces the
lowered route exactly. Final run: 4,516 builders, zero nix-level errors, all 1,474 producers and
all 1,474 emitted actions, and the per-group comparison reads

    OK the whole graph emitted, all 1474 group(s) match the lowered route

**WHY THAT ZERO IS EVIDENCE.** The same check on the same graph reported `identical 1364, differ
110` one run earlier and named every differing group. So it had just demonstrated it can report
a non-zero, and 110 to 0 is the #95 migcom fix landing. A zero from a check nobody has seen fail
would have been worth nothing.

**KEEP BOTH ROUTES**, for an empirical reason rather than an aesthetic one: the DIFFERENTIAL
between them found four real defects, two of which neither route could expose alone. A second
implementation that agrees is a test; deleting it converts a working check into an unverified
assumption.

- **A, the bridge.** `nix/lib/dyn-actions.nix`, fourteen properties over eleven fixtures via
  `scripts/buck-dyndrv-check.nu`. `scripts/buck-bridge-generality-check.nu` ENFORCES that the
  reusable half references nothing outside itself, which is the requirement rather than a
  nicety. Usage, constraints and the limits a real consumer found: `docs/dyn-actions-bridge.md`.
- **B, the adapter.** `cider-graph-specs` renders the builder script and
  `cider-graph-specs` writes it plus `needs.json` and a `dyn/` spec dir inside the graph
  derivation. The lowering no longer assembles a script; it reads the template.
- **STILL OPEN, and it is the user's call.** Making the adapter standalone means emitting the
  toolchain list, the staging script and the staged tree scripts. Measured sizes: 1 toolchain
  set shared by all 1,474, 94 distinct staging scripts, 3,013 staged tree scripts. Nothing
  measured says what that would cost or save.

Full detail, every measurement and the corrected claims: docs/plan-history.md, "#66 in detail"
and the 2026-08-12 heading.

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
and cider-install-from-manifests all read it, and it disappears when cmake does, so every
generator needs to be re-runnable before that happens.

### Stage 1 and stage 2 queue: FINISHED, moved to docs/plan-history.md

634 lines lived here, 45 percent of this file, and every numbered item in them is a
completed task: the stock switch and GUI frameworks, the nine unported cli edges, the host
tools, the NixOS VM, the daemon growth traps, the relative escape findings and a getuuid
analysis. The section opened by calling itself stale. Coverage is 1451 of 1451 and stage 2
is complete, so none of it is a live instruction.

Moved, not deleted: docs/plan-history.md, under the 2026-08-12 heading. Go there for the
measurements, which are real and were expensive to take.

THE OPEN TASKS ARE #97, #98, #99, #76 AND #92. #96 is DONE (both routes). Nothing else in this
file is a queue.

### #97 to #99: porting buck2 into the overby.me monorepo, which takes no Python

**#99 IS DONE as of 2026-08-12.** All 2,244 lines of build-path Python are Rust: the graph dump,
the spec lowering, the source closure, the skeletoniser, the buck-src normaliser and the
dynamic-derivation spec fixup. Each flip was verified by rebuilding the content addressed
artifact it feeds and comparing STORE PATHS, which for a CA output is a byte comparison: the
graph, the specs, the sources and the skeleton all came out identical. Nothing on the build path
is interpreted now except the buck2 rules' own python, which is upstream's.

**See `docs/monorepo-port.md`**, which carries the measurements. The headline from #97: the eight
`gen-*.py` scripts are 5,338 lines, and the premise that the whole class is dead-end reference
reading is WRONG FOR HALF OF IT. Four are live generators over live inputs, and the biggest file
is not a tool at all but a LIBRARY that four live checks import, of which they use 7 percent
(8 functions, 182 lines of 2,508). Archive 2,743 lines, port 2,595.

The measurement trap worth keeping: grepping for a generator's name finds 2,899 hits for
`gen-buck-from-ninja.py`, and nearly all are `# GENERATED by scripts/X` headers in the files it
WROTE. A provenance header is not a call site, and counting it as one makes every generator look
live.

### Darwin Rust: route A builds and RUNS, and dies in dyld lazy binding (harness task #96)

**BUILD: DONE.** `scripts/buck-darwin-rust-build.nu` turns a Rust source into a Mach-O x86_64
executable on Linux using our own ld64. Four things make it work and each was a dead end alone:
the OFFICIAL rustc rather than the nixpkgs one (both are 1.95.0 at commit 59807616e, but nixpkgs
appends `(built from a source tarball)` and rustc crate-metadata checking is a STRING COMPARE, so
E0514); nixpkgs pkgsCross refuses on CCTOOLS not rustc, and #65 gives us our own; `-syslibroot` is
mandatory because libSystem re-exports `/usr/lib/system/*.dylib` by ABSOLUTE path; and
`-C linker-flavor=ld`.

**IT ALSO RUNS, which was the real question.** The container boots, and the daemon log shows
shellspawn, bash, cp, path_helper, then `execve /bin/cider-rust-probe ret 0`. Rust code executes:
the core stack has three frames in the binary itself at 0x100048000, 0x1000015d8, 0x100001738.

**THEN IT FAULTS, AND THE LOCATION IS EXACT.** SIGSEGV five lines after execve. Located by the
[[mldr-rs-breaks-guest-nix]] core method rather than by guessing:

    fault RIP                0x700e11b6e1e1
    core mapping             0x700e11af2000-0x700e11b79000  /usr/lib/system/libdyld.dylib
    offset                   0x7C1E1  =  dyld_stub_binder + 0xF1
    caller                   0x7C289, same function

So this is **dyld LAZY SYMBOL BINDING**: the binary calls an imported function for the first
time, goes through the lazy stub, and the binder segfaults. Reproducible: three boots, three
ASLR slides, the fault address ends in `1E1` every time.

**TWO HYPOTHESES ALREADY KILLED, do not re-chase them.** It is NOT thread-local storage: the
binary carries HAS_TLV_DESCRIPTORS and libdyld does export `__tlv_bootstrap`, which made TLV the
obvious suspect, and the core says the fault is in the stub binder instead. It is NOT a fixup
format mismatch: the probe and cider's own WORKING `/bin/bash` have the same load commands,
`LC_DYLD_INFO_ONLY` plus `LC_MAIN`, neither uses chained fixups.

**ROOT CAUSE FOUND: A PROT_NONE GUARD PAGE SITS INSIDE THE GUEST STACK.** The faulting code is
not symbol resolution at all, it is the XSAVE buffer setup that runs first: dyld reads
`_bufferSize32` (0xA88 = 2696, sane, and it matches `rax` in the core), subtracts it from `rsp`,
and zeroes upward. From the core's PT_LOAD headers, raw:

    0x7FFFFFDE3000-0x7FFFFFDF0000  RW
    0x7FFFFFDF0000-0x7FFFFFDF1000  flags EMPTY, no R no W no X
    0x7FFFFFDF1000-0x7FFFFFE00000  RW

`rsp` was 0x7FFFFFDF0700, so only **0x700 = 1792 bytes** lie below it before that guard page,
while dyld needs 2696. The loop starts at 0x7FFFFFDEFC40, which IS mapped RW, and walks UPWARD
into the guard. Checking only the first address is what made this look like a mapped-page fault.
mldr's own log agrees: it reports `stack sp=0x7fffffdf0110`, inside that page range.

**FOUR HYPOTHESES DIED HERE, do not re-chase any of them:** thread-local storage (the binary does
carry HAS_TLV_DESCRIPTORS and libdyld does export `__tlv_bootstrap`); a fixup-format mismatch (the
probe and cider's WORKING `/bin/bash` both carry `LC_DYLD_INFO_ONLY` + `LC_MAIN`, neither uses
chained fixups); a garbage buffer size; and an unmapped destination.

**TWO CORE-READING TRAPS WORTH KEEPING.** `info proc mappings` on a core lists only FILE-BACKED
mappings, so an anonymous stack absent from it proves NOTHING; use the PT_LOAD program headers.
And `readelf -l` splits each program header over TWO lines, so a naive regex reports zero PT_LOAD
for a core that has 186.

**FIXED, AND ROUTE A IS COMPLETE.** `darwin/loader/src/stack.rs` allocated the guest start stack
as `min(16 pages, RLIMIT_STACK)`, inherited from upstream `mldr.c:828-839`. 16 pages is 64 KB;
macOS gives the main thread 8 MB. Rust std had consumed 63,744 of 65,536 bytes before dyld's
first lazy bind, so the 2,696-byte XSAVE buffer ran off the bottom. Now 8 MB, still floored by
RLIMIT_STACK. Verified by rebuilding mldr and re-running the same probe against the same prefix:
SIGSEGV became

    CIDER_RUST_OK macos

exit 0, `std::env::consts::OS` reporting macos. bash survived the same stack only because its
startup high-water mark is lower.

### Route B: the official Darwin rustc under cider (DONE, it compiles Rust in the guest)

The rustc component is fetched and installed into the guest at `/opt/rustc` (442 MB). Running it
fails in two stages, in this order:

**1. `@rpath` is not resolved by cider's dyld.** `dyld: Library not loaded:
@rpath/librustc_driver-...dylib`, although the dylib IS at `/opt/rustc/lib` and the binary's
`LC_RPATH` is `@loader_path/../lib`, which should resolve from `/opt/rustc/bin`. Setting
`DYLD_LIBRARY_PATH=/opt/rustc/lib` makes it load, which isolates the gap to **`@rpath` /
`@loader_path` handling**. That is a real, self-contained cider defect and the first route B
finding.

**2. Foundation.framework is absent from prefix-min.** Of rustc's five non-libSystem deps,
`libobjc`, `libc++`, `libz` and `libiconv` are all present and only Foundation is missing.

**So route B needed the FULL prefix**, `//buck/prefix:cider_prefix`. Built: 23,409 commands, 0
failures, and Foundation.framework is in the artifact. With that prefix and the `@rpath` bypass:

    rustc 1.95.0 (59807616e 2026-04-14)

**3. THEN A REAL COMPILE KILLED THE DAEMON, AND IT WAS OUR BUG.** `rustc -O hello.rs` (HashMap,
an iterator sum, `println!`) got `semaphore_timedwait failed (internally): -111` in the guest and
`ciderd: FATAL host signal 11, fault addr 0x818` on the host. Diagnosed from the daemon crash
backtrace plus the core, not from the symptom:

    task_findtid+0xd6           <- SIGSEGV, mov 0x818(%rax) with rax = 0
    _psynch_mutexwait+0x351
    Handler::psynch_mutexwait
    rpc_wire::dispatch / process_one_call / run_dowork_loop / body_trampoline

The offsets are unsymbolised in the log (release build, no DWARF); `nm -S --numeric-sort` plus a
nearest-symbol-below lookup recovers every frame, and `objdump` at the exact offset names the
faulting instruction instead of leaving a choice of three dereferences.

**ROOT CAUSE: our `queue_enter_threads` stored the address of the link FIELD where XNU's
`queue_enter` stores the ELEMENT pointer.** `linux/server/src/xnu/thread.rs`. XNU element queues
put the `thread_t` itself in `head->next` and in each `task_threads.next`, because `queue_iterate`
casts the stored `queue_entry_t` straight to `thread_t`. Our two helpers agreed with each OTHER,
so the list looked consistent and nothing in Rust ever noticed; the C reader did not agree, read
`thread_id` at `(thread + 0x6b8) + 0x818`, and walked a next link taken from the middle of the
record. Same file also lacked `queue_enter`/`queue_remove`'s head cases and the link clearing.

Proven from the core rather than argued: under the field reading every link resolves to a real
thread of the crashing task with sane tids (7, 13, 11) and `->task` equal to the task being
walked; under the element reading every one of them is zero or garbage. That is the whole
diagnosis in one measurement.

**Why nothing caught it before.** `task_findtid` is reachable only from the contended branch of
`_psynch_mutexwait`, where a guest hands the kernel an owner tid hint that disagrees with what
the kernel knows. Guest bash never does that. rustc does it seconds into a real compile.

**VERIFIED, on the artifact.** After the fix the same command runs rustc to completion and only
fails in the LINKER, which is a prefix content gap and not a daemon defect: rustc calls `cc`, and
`/Library/Developer/DarlingCLT/usr/bin/clang` does not exist (the Command Line Tools package is
not installed). `--emit=obj` therefore closes it end to end:

    RUSTC_EXIT=0
    hello.o: Mach-O 64-bit x86_64 object, flags:<|SUBSECTIONS_VIA_SYMBOLS>

9,376 bytes, carrying `__ZN3std2rt10lang_start...` and the `CIDER_RUSTC_GUEST_OK map=` marker
string. A Darwin rustc running under cider compiled Rust to Darwin object code.

### @rpath was never resolved, because mldr handed dyld the HOST path (FIXED)

`dyld: Library not loaded: @rpath/librustc_driver-...dylib`, with the dylib sitting at
`/opt/rustc/lib` and the binary's `LC_RPATH` reading `@loader_path/../lib`. Nine hypotheses had
already been killed on this. The tenth was right and cost one grep.

**MECHANISM.** mldr passes `executable_path=` in `apple[]`, and passed `guest_path`, which is the
path mldr READ THE FILE FROM, i.e. a host path. dyld keeps that as `sExecPath`, returns it from
`getPath()`, and then RESOLVES it: `ImageLoaderMachO::getRPaths` calls `realpath(this->getPath())`
before expanding `@loader_path`, and dyld2's `@executable_path` branch calls `realpath(sExecPath)`.
Those run in the GUEST namespace, where `/tmp/.../prefix/opt/rustc/bin/rustc` does not exist, so
realpath returns NULL, `getRPaths` pushes nothing, and every LC_RPATH is dropped IN SILENCE.

**Why it looked mysterious for so long.** `DYLD_PRINT_RPATHS` prints nothing, because its only log
site is inside the substitution loop, which does not run when the rpath list is empty. The absence
of output reads as "rpaths were not consulted" when it actually means "there were none".

**PROVEN BEFORE IT WAS FIXED.** A symlink making that host path resolvable inside the guest, and
nothing else, turned the failure into `RPATH successful expansion of @rpath/librustc_driver-... to:
/opt/rustc/bin/../lib/...` and `rustc 1.95.0`. So the trigger is precisely whether realpath can
resolve that one string. Two earlier suspects died on the way: `allowAtPaths` (dyld's AMFI stub
returns `0x3F` and `ALLOW_AT_PATH` is bit 0, so at-paths ARE allowed, and bit 1 being set is also
why `DYLD_LIBRARY_PATH` worked), and env vars not reaching dyld (`DYLD_PRINT_LIBRARIES` prints).

**FIX in `darwin/loader/src/main.rs`**: the root prefix derivation moved out of the dylinker
branch, where it already existed for locating dyld, and `executable_path=` is now the host path
with that root stripped. Deliberately conservative: it rewrites only when the host path really is
under the root and the remainder is still absolute, so the first process (whose root is libexec,
not the vchroot) cannot have a working path turned into a broken one.

**VERIFIED with the workaround symlink DELETED**: `@rpath` resolves, `rustc --version` runs, and
`rustc -O --emit=obj` produces the same 9.2K Mach-O object, all with no `DYLD_LIBRARY_PATH`.
Guest bash still runs (`Darwin`, and a separate `/bin/echo` exec).

**Absolute-path loads were never affected**, which is why bash and every earlier guest worked and
this stayed invisible until a binary that uses `@rpath` ran.

**WHAT IS STILL OPEN.** No Darwin-native linker in the prefix, so linking an executable inside the
guest needs a Mach-O `ld64` there (route A links on the host instead). rustc reaches for `cc` and
`/Library/Developer/DarlingCLT/usr/bin/clang` does not exist.

### #76 - the Darling-origin host tools in Rust (DONE except two that are toolchain-blocked)

Written 2026-08-12 because the task was open in the harness with NO PLAN entry, so the next
increment would have rediscovered all of the below. Read off the tree, not from memory.

**TWO OF THEM ARE ALREADY PORTED, and well.** `linux/buildtools/BUCK` gives the CANONICAL names
`getuuid` and `elfdep` to `rust_binary` targets over `getuuid.rs` and `elfdep.rs`; the C survives
as `getuuid_c` and `elfdep_c` deliberately, because `scripts/buck-hosttools-parity.nu` diffs the
two on the same inputs and that comparison is only re-runnable while both exist. Provenance was
checked: both are Darling-origin and GPL (getuuid.c Copyright 2018 Lubos Dolezel, elfdep.c
2018-2020), so the headers stay and a Cider line sits beside them.

Parity is BYTE parity, stdout as hex and stderr verbatim, which is not pedantry: writing the
ports from a reading of the C produced a defect that survived review and died there, because
`std::io::Error` renders ENOENT as "No such file or directory (os error 2)" while C `strerror`
prints only "No such file or directory". Eyes would have passed it.

**NOTHING IN THE BUCK2 BUILD CONSUMES EITHER TOOL.** The one consumer, `cmake/dsym.cmake`,
belonged to the reference CMake build this port replaced. So the `_c` targets cost one compile
each and nothing else, and they can be dropped whenever the comparison stops being worth
re-running.

**AND UNTIL 2026-08-12 NOTHING INVOKED THE PARITY CHECK EITHER**, which is the same gap #85 found
in the lowering stage check: a check nobody runs is a file, not a check. `scripts/buck-test.nu`
now builds the six binaries in one buck2 call and runs it in the wrapgen section, so a divergence
fails the suite instead of waiting for someone to remember the script exists.

**WHAT IS ACTUALLY LEFT, and it is smaller than the task title suggests:**

    bsdln       NOT GONE, and NOT ours to rewrite. This entry said "GONE, zero files match
                anywhere in the tree" and that was false: linux/bsdln/{BUCK,ln.c} is right
                there, //linux/bsdln:bsdln builds, and linux/bsdln/BUCK already records the
                decision. ln.c is Copyright 1987, 1993, 1994 The Regents of the University of
                California, so it is FreeBSD ln with a small local delta, not Darling-origin
                code. The intended treatment is DE-VENDORING (pin the upstream source, compile
                it with -include bsd/string.h), not a Rust rewrite that would throw away the
                upstream history.
                HOW THE FALSE CLAIM SURVIVED, because the shape recurs: the search matched
                FILE NAMES only. Nothing is called bsdln.c; the directory is called bsdln. Same
                family as the buck-src lesson, where a search was structurally unable to see
                what it was asked about, so it returned a confident zero.
    wrapgen     DONE 2026-08-12. linux/libelfloader/wrapgen/wrapgen.rs is the build tool now
                and the C++ is kept beside it as wrapgen_c. Provenance was the last blocker and
                it is resolved; the record of how is below because the method is reusable.
                THE PROBLEM WAS that all four files carry no copyright, no licence and no
                Darling marker, and local history cannot settle it either: jj file annotate
                attributes every line to the #87 stage 1a move and the log for the path holds
                that one commit, so the pre-move history was squashed.
                RESOLVED BY BLOB IDENTITY AGAINST UPSTREAM, which is exact rather than a
                judgement. Darling has these at src/libelfloader/wrapgen/, and a git blob
                hash is sha1 over "blob <len>\\0" plus content, so it can be computed locally
                and compared with what the GitHub API reports:

                  print_wrapped_elf.cpp     3829 B  IDENTICAL  c12c01045ee7
                  produce_stubs_example.h    156 B  IDENTICAL  b59774dba4f5
                  wrapgen.cpp               7830 B  IDENTICAL  7079e613ecf6
                  stubgen32.cpp             8646 B  differs by exactly our own rename

                THE ONE DELTA IS FULLY ACCOUNTED FOR. stubgen32.cpp is 10 bytes shorter than
                upstream because #84 renamed 5 occurrences of _darling_elfcalls to
                _cider_elfcalls, and 5 sites times 2 characters is exactly 10. Reversing that
                substitution reproduces upstream blob d1acd8c0d1aa EXACTLY, so nothing else
                differs. That is a proof rather than an inspection.
                SO: Darling-origin, unmodified apart from our rename, and the missing header
                is UPSTREAM's absence which we inherit rather than something the move lost.

                **BUT IT IS NOT THE SAME FOOTING AS getuuid AND elfdep, AND THAT IS THE POINT
                WORTH CARRYING.** Those two are consumed by NOTHING in the buck2 build, which
                is exactly why porting them was cheap and why a byte-parity harness over a
                handful of inputs was sufficient proof. wrapgen is LOAD-BEARING:

                  linux/libelfloader/BUCK:15     the target //linux/libelfloader:wrapgen
                  buck/rules/codegen.bzl:558     the elf_wrapper rule RUNS it at build time
                  darwin/CoreAudio/BUCK:38       consumer
                  linux/native/BUCK:74           consumer
                  buck-src/BUCK:49080            consumer, the generated one

                It writes the Mach-O stub that lets a Darwin program call into a HOST ELF
                library, and codegen.bzl:563 records that it dlopen()s the real .so AT BUILD
                TIME. So the port had to reproduce its GENERATED OUTPUT exactly, across every
                library any consumer feeds it, not merely behave the same on a few probes.

                SO THE GATE WAS THE WHOLE CORPUS: all 22 libraries the three consumers name,
                16 from linux/native, 5 from darwin/CoreAudio and fuse from buck-src, compared
                in the .c, the vars .h, stdout, stderr and exit code. Byte identical in every
                one, from 3,615 bytes of C for swresample to 538,088 for GL, with 8 of the 22
                exercising the vars-header path. Five error paths too (no arguments, an
                unloadable library, a non-ELF, a 32-bit ELF, an executable with no DT_SONAME),
                plus a control that must fail and does.

                ONE BUG THE GATE CAUGHT THAT READING WOULD NOT HAVE: DT_SONAME is an index INTO
                the string table, and the C++ still passes it through vaddr_to_offset before
                adding it to a pointer that already includes the string table offset. The first
                version read at the wrong offset and every soname came out as rubbish.

                THE ONE DELIBERATE DIFFERENCE, as in getuuid and elfdep: the C++ mmaps and casts
                structures straight out of the mapping, so a lying offset reads past the end.
                The Rust reads the file and parses at CHECKED offsets.
    xcrun       darwin/clt/xcrun.c, darwin/xcselect/xcrun.c, darwin/xcselect/xcrun-shim.c
    PlistBuddy  darwin/PlistBuddy/PlistBuddy.c

**xcrun AND PlistBuddy ARE BLOCKED, and the reason is narrower than this entry first said.**
Both live under `darwin/`, so they are Mach-O GUEST binaries. Two separate gaps, measured
2026-08-12:

    buck/rules/rust.bzl        zero occurrences of --target, so the rule cannot ask for a
                               non-host target even if one worked
    rust-std for darwin        ABSENT. This is the real blocker.

**THE CORRECTION IS WORTH THE SPACE, because the first version of this entry said "a Darwin Rust
toolchain does not exist here" and that is false.** `rustc --print target-list` lists
`x86_64-apple-darwin`, `aarch64-apple-darwin` and three more, so the COMPILER supports the
target. What is missing is the standard library built FOR it:

    rustc --target x86_64-apple-darwin hello.rs
      error[E0463]: can't find crate for `std`
    rustc --target x86_64-apple-darwin --emit=obj  (with #![no_std])
      error[E0463]: can't find crate for `core`

and `rustc --print target-libdir --target x86_64-apple-darwin` names a directory that does not
exist. `core` being absent too means even a freestanding object cannot be produced.

So this is UNCONFIGURED, not impossible, and the distinction changes what the work is: supply
`core` and `std` for the target, then teach `rust.bzl` to pass `--target`. Note the project
already owns two of the awkward prerequisites, a Mach-O linker (ld64, buck2-built since #65) and
the Darwin SDK. Nobody has costed the rest. Do not start either tool expecting to finish it, but
do not repeat the claim that the toolchain cannot exist.

So the honest shape of #76 is: THREE DONE with a byte-parity harness the suite now runs, one that
was never in scope (bsdln is upstream BSD and wants de-vendoring instead), and two blocked on a
missing toolchain. Nothing is left that is merely waiting to be picked up.

**THE METHOD IS REUSABLE, and it is cheaper than reading history.** When provenance is in doubt
for a file that carries no header, do not argue from style or from a squashed log. Compute the
git blob hash locally, `sha1("blob " + len + "\0" + bytes)`, and compare it with what the GitHub
contents API reports for the upstream path. Identical means unmodified, full stop. When it
differs, reverse the known local transformation and hash again: if that reproduces the upstream
blob, the delta is fully explained and nothing is hiding in it.

### #92 - read the graph through buck2 structured data, not its rendered output

Written 2026-08-12 for the same reason as #76: the task was open with no entry describing it.

**THE DEFECT CLASS, and it is not hypothetical.** `buck2 aquery` renders an action command by
joining the argv with `", "`, and `cider-graph-dump` splits it back apart. That is
sound only while no argument contains the separator, which is an ASSUMPTION, and it has been
wrong: perl's `versions.h` passed the C initializer `"5.18", "5.28",` as ONE argument, it came
back as TWO, and the lowering died on a ValueError out of the configure script. The host, which
never round-trips through the rendering, built it correctly the whole time. That asymmetry is
the signature of this bug class: only the Nix route can see it.

**IT IS ALREADY GUARDED, so this is a robustness task and not an outage.** Two halves:

    buck-argv-roundtrip-check.nu            compares unjoin() against `buck2 log what-ran`,
                                            which carries the real argv as a LIST. It imports
                                            unjoin from the dumper rather than reimplementing
                                            it, so it tests the real code path.
    buck-argv-roundtrip-check.nu --static   no build: every BUCK string literal that becomes an
                                            argv element must not contain the separator. This
                                            is the half buck-test.nu runs.

Measured when that went in: exactly ONE literal in the tree contains `", "`, perl's VERSIONS,
and `configure_file` now passes its values through a file, so it is safe by construction.

**TWO TRAPS RECORDED IN THAT CHECK, worth reading before touching this.** It runs buck2 under
its OWN isolation dir, because `what-ran` lists only actions that actually EXECUTED; against the
warm daemon everything is cached, nothing runs, and the check reports zero comparable actions
while looking like it passed. And the dumper's own `--check-against-what-ran` covers only about
4 percent of the graph inside the Nix graph derivation, the actions owning artifacts buck2 makes
in-process, which is why it could not have caught the one bug it exists for.

**SO WHAT #92 BUYS** is deleting the assumption rather than testing it: take the argv as
structured data and the round trip disappears, along with both checks. Nothing measured says
what it costs. Do not start it while a cheaper task is open.
