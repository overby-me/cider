# darling-nix

darling-nix is a Nix-packaged fork of [Darling](https://github.com/darlinghq/darling)
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


## Buck2 port: where it stands

Every in-scope link edge of the reference graph is ported and builds: **1452 of 1452**,
install **UNMAPPED 0**, `buck2 build //...` green over all ~12k targets, `buck-test.nu`
**151 of 151**, and every runtime check at 0 or a documented 3.

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

**An exclusion list is load-bearing, and a rename can empty it.** The lowering stages `src/`
and `src/external/` as REAL directories so the pins can be planted in them, so the loop that
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
- **Rust rewrite complete and default.** Host daemon (`linux/server`, crate `darling`, bin
  `darlingserverd`), launcher (`linux/launcher`, bin `darling`), guest loader
  (`darwin/loader`, bin `mldr`). The C++ daemon and C launcher/loader are deleted.
- **Boots to Darwin; M1 achieved.** Guest nix 2.34.8 builds and runs `hello` (and `pv`)
  from source under rootless Darling, launchd-free. `nix eval builtins.currentSystem` →
  `"x86_64-darwin"`.
- **Off git submodules.** Nix (`nix/submodules.json`, 147 pins + `nix/lib/darling-src.nix`)
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

- **Call chain (the debugging map):** Darwin binary → Darwin libc → `libsystem_kernel`
  BSD-trap stub → daemon translates to Linux → kernel. Syscalls are implemented only to the
  depth Nix needs, not for general macOS compat.
- **launcher** (`linux/launcher`, libc-only, builds offline): rootless userns re-exec,
  prefix bootstrap, spawns the daemon as container init, shellspawn client, teardown. Owns
  NO mounts/vchroot (the daemon does).
- **daemon** (`linux/server`): single-threaded epoll loop + a **stackful microthread
  scheduler** (`sched.rs`) — not async, because duct-tape suspends microthreads
  synchronously from inside C stacks; single-worker is correct (duct-tape locks are
  cooperative). RPC codec (`rpc_wire.rs`) is generated from the calls list, 162/162
  byte-identical to C. Wire = SOCK_DGRAM + SO_PASSCRED (sender pid via SCM_CREDENTIALS, used
  for `process_vm_readv` because the guest is in its own PID namespace).
- **duct-tape** (`src/external/darlingserver/duct-tape/`, still C): kernel-emulation glue
  that compiles the vendored XNU (osfmk/bsd). Linked into the daemon crate by
  `linux/server/build.rs`: bindgen generates the 36-field `dtape_hooks_t` from source
  headers; static libs (`libdarlingserver_duct_tape.a`, `liblibsimple_darlingserver.a`)
  come via the `DUCT_TAPE_LIB` env var. The Rust/C seam is the frozen `dtape_*` API +
  `dtape_hooks` vtable — Rust above, C+XNU below.
- **mldr loader** (`darwin/loader`, libc + goblin): guest Mach-O loader — segment mmap/slide,
  commpage, the elfcalls vtable (ELF↔Mach-O), start stack, daemon checkin, jump to dyld.
- **Container model:** an overlayfs prefix (`~/.darling`, macOS FS hierarchy) entered
  **rootless** via unprivileged user namespaces (needs
  `kernel.unprivileged_userns_clone=1`, kernel ≥5.11). **One command per fresh container** —
  a sibling userns cannot join a running container's mount ns.
- **Shared store:** guest `/nix/store` is the host store via a `/nix →
  /Volumes/SystemRoot/nix` symlink (the host root is mounted at `/Volumes/SystemRoot`);
  `/nix/var` stays Darling-local to avoid db/schema conflicts.
- **apple-sdk `.tbd` stubs:** binaries link against stub symbols, resolved at runtime from
  Darling's reimplemented libraries — so derivation hashes never depend on Darling.
- **sandbox-exec** is a parse-and-ignore stub (the Linux container already isolates).
- **Nix packaging:** `nix/lib/darling-src.nix` assembles the tree from the 147 pins +
  `patches/<name>/`; `nix/package.nix` builds the Darwin userland and installs the Rust
  crates; `nix/{launcher,server,duct-tape,loader,cctools-port}.nix`.

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

### D — Correctness oracle (the keystone remaining) [ARCH-FREE]
"It built" → "it built **correctly**." The project's core value proposition.
- **D.1** `scripts/oracle.nu <attr>` = `nix build --rebuild` vs cache.nixos.org, JSON
  (match / mismatch / build-failure / known-nondeterministic).
- **D.2** oracle column in `tests/nix/compatibility-matrix.sh`; a justified
  non-determinism allowlist.
- **D.3** on mismatch: diffoscope + classify (codegen vs metadata vs fs-ordering vs
  miscompile). **A codegen-class divergence is stop-the-line** — the shim is lying to the
  compiler (math, memory layout, or a syscall result) and everything above is suspect.

### The Nix endpoint builds the prefix, green

`nix build .#darling-buck2-prefix` finished with **NIX EXIT 0**: 3216 derivations, **0
errors**, ending on the prefix derivation. The result holds **34,720** files and links,
and all six spot checks pass (`bin/bash`, `bin/sh`, `usr/lib/dyld`,
`usr/lib/libSystem.B.dylib`, `usr/lib/system/libsystem_kernel.dylib`, the ICU data).
Read the `NIX EXIT` line and the `-o` link, never the wrapper status.

**The Nix prefix ships REAL Swift libraries.** `buck-dylib-shape.nu` over it reports 227
installed `.dylib` files, **227 Mach-O, 0 git LFS pointers**, and the 44 under
`usr/lib/swift` are genuine (libswiftCore 6.7 MB, libswiftFoundation 3.2 MB), because the
nix pins fetch LFS content. The HOST tree still installs the 131-byte pointers, which is
what the check's exception covers, so the two prefixes differ in exactly that set. This is
reported, not acted on: #39 stays as the user left it.

### The endpoint builds green on the rebuilt graph (2026-08-05)

`nix build .#darling-buck2-prefix` finished **exit 0** in **2 h 6 min**: 3,442 builders,
**0 errors**, on the graph rebuilt after the BXL and `InProcInfo` changes. The prefix is
**identical to the known-good reference** -- 39,173 entries each, zero differences in either
direction under `LC_ALL=C` -- and `buck-bash-check.nu --prefix` reports
**BUCK2_BASH_OK 3.2.57(1)-release x86_64-apple-darwin19, PASS**.

**Operational trap found on the way**: a build that stops advancing with flat CPU may be a
**zombie-reap hang in nix-daemon**, not contention. Builders finish, become `state=Z`, and the
worker never reaps them; it recurred with a single builder in flight, so it is not a
concurrency race. Memory (18 GB free), the daemon cgroup task limit (23 of 1,048,576) and
build-log flooding were all excluded. **Restarting `nix-daemon` cleared it**, and the resumed
build went straight through. Completed derivations survive in the store, so a restart costs
only the in-flight ones.

### A minimal prefix, sized for the goal rather than for parity (2026-08-05)

The goal is a prefix that boots, runs bash and can run nix. The endpoint was building the
full parity prefix for that, and most of it is dead weight: `darwin/frameworks` is 8,142
actions, private-frameworks 2,250, the scripting languages 1,197 -- 42% of 27,591.

`nix build .#darling-buck2-prefix-min` builds a prefix with those dropped, generated (not
hand-edited) by `scripts/gen-prefix-min.py` from the generated full prefix, and it
**PASSES `buck-bash-check.nu`: BUCK2_BASH_OK 3.2.57(1)-release**.

| | full | minimal |
|---|---|---|
| graph actions | 27,591 | **17,510** (-36.5%) |
| targets | 3,225 | 2,339 |
| staged trees | 5,282 | 4,175 |
| prefix entries | 39,174 | **9,980** (-75%) |
| prefix size | 622 MB | **270 MB** |

The build is bounded by the survivors closure, not by the entry list: dropping 44% of install
entries removed 36.5% of actions, because buck2 still builds what the remaining targets
depend on. **zsh was NOT excluded** (the exclusion list omits `//buck-src/zsh` although the
prose claimed it), so more is still available.

This also shrinks #54 and #55 without solving either: fewer targets means fewer stage-trees
to rebuild when the graph moves.

### Iteration cost: what the graph derivation really needs (#56, #58)

Editing one `.c` reruns the graph derivation, **30 to 90 minutes**, before any compile can
start. Content addressing keeps that from cascading into the lowered derivations, so it is a
fixed tax per edit.

**A skeleton does not fix it, and the reason is worth keeping.** buck2 analysis genuinely
cannot read a source file, and that was verified both ways: buck2 loads a skeleton with the
same **12,283** targets and all **3,225** action-owning labels, and emptying `buck-src/BUCK`
removes exactly its **1,227**. But this derivation also **materialises** the in-process
artifacts, and a farm of *generated* headers is produced by running a generator, which is a
host tool it builds from first-party C (`src/startup:rtsig`, `src/libelfloader:wrapgen`). An
emptied `rtsig.c` compiles, links, runs, and writes an **empty header** — quietly wrong
rather than failing. Reverted.

**Splitting analysis from materialisation is not the fix either**: measured on the failed
run, analysis is ~65 min and materialisation ~19 min, so a second derivation would redo
analysis in its own sandbox and pay the 65 again.

**Kept from the attempt, and verified**: `buck/bxl/materialize.bxl` no longer ensures every
node's default output, which was making the derivation compile objects and link binaries it
has no use for. The graph built that way is **the same graph** — `buck-graph-equiv.py`
reports every dimension identical, including staged artifact contents and all 5,282
reconstructed farms. Wall time **27 min** against 30-47 before; the 12.5 min figure seen
mid-way was a build that was silently missing 30 artifacts, not a real result.

Getting there cost two silent-failure bugs, both now closed. Artifacts made in-process were
reachable *only* as a side effect of building the target, so removing the default-output
ensure dropped 30 of them while the build **exited 0**. Rules now declare them
(`InProcInfo`, 98,455 → 98,484 ensured) and a missing one is **fatal** in the dump.

The real fix, if resumed, is the **codegen input closure** — computable from an existing
graph — so exactly the files this derivation compiles keep their contents. It must be
derived, never guessed by extension, because guessing fails silently.

`treelinks` also shrank **455.5 MB to 124.3 MB**: a link target is derivable from its name
(the name is the target tail in every case, and the `../` depth minus the name depth is
constant per table), so tables store names only. 5,240 of 5,266 qualify; 26 keep two columns.

The per-target source **groups** (#54) stopped being expensive: the cost was never the
groups but the 588 MB per-target map parsed to choose them, now precomputed to **2.06 MB**.
Measured after: **32.6 s cpu / 1.78 GB** against the 75.6 s / 3.40 GB that got it parked, so
it costs ~10 s over the default path and normal heap. Default eval itself is unchanged at
**22.6 s** despite the closure becoming a second IFD.

And it delivers, measured statically off the derivations rather than by a 90-minute build.
Across 85 framework groups, editing one framework rebuilds a **median of 1 target** and at
worst 1,702, against **all 3,215** for any edit whatsoever on the default path. The two worst,
LocalAuthentication and CryptoTokenKit at 1,702 each, are a granularity artifact and not a
dependency bug: the generated `sdk_darwin_frameworks_headers` target owns **five** SDK headers
split across those two framework directories, and since a group is three path segments it
drags both whole frameworks into the SDK header root every Darwin compile depends on. Making
those five travel as individual files, the way the 69 ungrouped ones already do, would cut the
worst case.

### #12 the VM hang: MEASURED, and it is not a hang in Darling

Four arms in one VM, same command, same prefix shape, one variable each:

| arm | stdin | result |
|-----|-------|--------|
| foreground | inherited from the driver | **124, no output, empty file** |
| foreground | `< /dev/null` | rc 0, `ARM_B_OK` |
| foreground | `setsid` + `< /dev/null` | rc 0, `ARM_C_OK` |
| backgrounded | POSIX gives it `/dev/null` | rc 0, `ARM_D_OK` |

So the variable is **stdin**, not the process group (setsid changed nothing) and not the
stdout target (a file, an anonymous pipe and a named FIFO all worked when backgrounded).
The guest command always ran: `BUCK2_BASH_OK`, `PIPED_OK` and `FIFO_OK` each appeared,
in under 75s, in a fresh prefix.

**Then reproduced on the host in seconds, and the root cause is a stack smash in the
guest kernel** (#46, fixed by `patches/xnu/0009-sockaddr-fixup-respect-caller-buffer.patch`).
The first reading, that the launcher waits for stdin EOF, was wrong: a FIFO held open by a
writer that never writes returns rc 0. The trigger is stdin being a **socket**, and what
it breaks is this:

`sockaddr_fixup_from_linux` converts a Linux sockaddr into a BSD one IN THE CALLER'S
BUFFER, and was told how many bytes the kernel wrote but never how large that buffer is.
On the PF_LOCAL branch it wrote a full `sizeof(sun_path)` plus a terminator, 106 bytes.
bash calls `getpeername(fd, &sa, &l)` from `isnetconn` with a **16 byte** `struct sockaddr`
for every shell whose stdin is a socket, so bash died in `__stack_chk_fail`, silently,
with SIGABRT.

The chain that found it, each step seconds on the host: socket fails, /dev/null and FIFO
do not; bash aborts and sh does not, and they are the same binary; `--norc` avoids it;
`strace -k` gives `isnetconn -> __stack_chk_fail -> abort -> kill(0, SIGABRT)`; and the
predicted discriminator held, AF_UNIX aborts where AF_INET does not, which is the
PF_LOCAL branch exactly. In the VM it surfaces as 124 rather than 1 because the driver
also waits for stdout to be closed and throws the output away.

**Confirmed end to end** against a prefix built with the patch: the same socketpair repro
that aborted now returns rc 0 and `BUCK2_BASH_OK 3.2.57(1)-release x86_64-apple-darwin19`.
The `< /dev/null` in the VM test stays: it is correct hygiene for a detaching command, and
the test runs against the Nix-built package, which needs an endpoint rebuild to carry the
patch.

Narrowed twice more: the daemon logs of a failing and a working run are identical through
`execve expand /bin/bash`, so bash execs fine; and with the same socket stdin
`darling shell /bin/echo X` returns 127 **with a message from the outer bash**, so bash
also runs and writes. Only the NESTED `bash -c` aborts, which puts the fault in passing
the socket fd to a SECOND guest process. Tracked as #46.

This retires the fd-2 lead for good: the fd-2-on-the-log line belongs to the persistent
shellspawn init, by design, and the surviving init in a failed run holds no pipe of the
caller's at all.

- **Test side:** every darling invocation in a VM test needs `< /dev/null`.
- **Darling side (open):** the launcher should not block forever on a stdin that never
  EOFs after the guest command has exited.

With stdin closed **the whole check passes at HEAD**: `nix build
.#checks.x86_64-linux.darling-buck2-smoke` exits 0, all three subtests green, against a
darling-buck2 built through the Nix endpoint rather than one already in the store. The
container boots in under half a second and the guest bash reports 3.2.57 and darwin.
That is #10. What still fails is the exit-code subtest, and it is
the only one that sets neither DPREFIX nor DARLING_NO_LAUNCHD. Arms with an explicit
prefix and no-launchd: `exit 0` gives rc 0, `echo` gives its output, and the DEFAULT
prefix behaves the same, so neither the prefix nor exit codes are the problem — it is the
launchd boot path. A guest `exit 7` returning nothing is not evidence of anything: the
driver documents that commands run under `set -euo pipefail`, so a non-zero exit aborts
the shell before the probe can report.

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
  darlingserver under qemu-user — signal/TLS fidelity).

### Rust + tooling
- **#63 exec across architectures** [narrow] — daemon cross-arch exec; the guest 32-bit
  loader (`mldr32`, cmake `BUILD_TARGET_32BIT`) is port-or-drop-undecided. Fat/universal
  Mach-O selection already done.
- **#72 duct-tape → self-contained `-sys` crate** — decouple XNU from the cmake tree (today
  linked via `DUCT_TAPE_LIB` at the cmake build's `.a`; bindgen runs on in-tree headers).
  Aspirational, not started.
- **#73 port build-time codegen to Rust** — `generate-rpc-wrappers.py` (already extended to
  emit the Rust codec, but still Python) and `tools/generate-xcode-stubs.py`.
- **#69 mig (Mach Interface Generator)** — still the C `bootstrap_cmds` fork (Apple-tracking,
  no nixpkgs substitute). A Rust rewrite is unstarted; only its nix-ninja edge handling is
  patched (see Build system).
- **#68 finish the repo reorg** — move the C++ darlingserver + duct-tape from `src/external`
  into `linux/darlingserver/`, completing the `darwin/` (guest) + `linux/` (host) seam.
- **Linker (#57 tail)** — `packages.darling-ld64` (`nix/cctools-port.nix`) done; fold in
  `install_name_tool`/`nmedit`, validate a real darwin dylib link with `-DDARLING_LD64_DIR`.

### Build system — make nix-ninja the primary incremental build (#26/#39)
Lower every edge of Darling's ~26k-edge ninja graph to its own content-addressed nix
derivation (the ~40-min monolith → seconds-incremental, fully cacheable, pure-nix). Infra:
`nix/lib/darlingNinja.nix` (`buildTarget`), vendored `nix/lib/nix-ninja/`.
- **State:** the libSystem umbrella builds per-edge (~5036 edges, valid Mach-O);
  darlingserver-ninja green per-edge; the graph-json IFD is feasible (~100s). Interim fast
  loops exist (`packages.darlingserver` coarse ~5-6 min vs 40; launcher fast-path).
- **Open blocker:** full-graph `buildTarget {}` (the `all` phony) stops at
  `migHeaderIncsFor` scope-sensitivity — `asl.c`'s `<asl_ipc.h>` `-I` resolves at subgraph
  scope but returns `[]` at full-graph scope.
- **To make primary:** (1) close the asl.c blocker → full-graph green; (2) build the
  install/fixup wrapper reproducing `package.nix`'s exact `libexec/darling` layout from
  per-edge outputs, diff'd identical; (3) wire `packages.darling-ninja`, kept OUT of
  `nix flake check` (thousands of derivations hang it); (4) vendor rust-ninja, drop the
  `overby` input.

### Multi-user / launchd / #47
- **#47 launchd: a guest RPC sendmsg gets ECONNREFUSED** [long-term] — narrowed 2026-08-01
  from "launchd deadlocks" to a 15-line syscall reproduction. The SPIN half is FIXED
  (patches/xnu/0008): a failed sigexc used to abort, and aborting needs the machinery that
  just failed, so it looped on ud2 -- 56,676,502 SIGILLs at one address, ~50% CPU,
  unkillable. It now exits with a diagnostic. launchd still does not work.

  The whole failure, from `strace -ff -e trace=socket,connect,bind,close,fcntl,sendmsg,sendto`:

        socket(AF_UNIX, SOCK_DGRAM, 0)  = 10
        bind(10, {AF_UNIX}, 2)          = 0        # autobind, NOT connected
        fcntl(10, F_DUPFD_CLOEXEC, 512) = 513      # RPC fd parked high
        close(10)
        sendto (513, #1  checkin)            = 40  # ok
        sendmsg(513, #35 thread_self_trap)         # ok
        sendmsg(513, #8  set_thread_handles)       # ok
        sendmsg(513, #31 pthread_canceled)         # ok
        sendmsg(513, #36 mach_reply_port)          # ok
        sendmsg(513, #38 mach_msg_overwrite)       # ok
        sendmsg(513, #31 pthread_canceled)         # ok
        sendmsg(513, #38 mach_msg_overwrite) = -1 ECONNREFUSED   <-- the bug
        --- SIGABRT {si_code=SI_USER, si_pid=1} ---             # __simple_abort
        sendmsg(513, #14 interrupt_enter)    = -1 ECONNREFUSED  # sigexc, same fault
        +++ exited with 1 +++                                    # 0008 working

  So: the SECOND mach_msg_overwrite on a socket whose previous seven sends all succeeded,
  same fd, same path, sender never connected. That is the entire open question.

  The FIRST failure in the system is not launchd's, though. A launchd JOB (guest pid 4)
  starts, closes the inherited RPC fds 512/513/514, opens its own, checks in, runs ~20 RPCs
  fine, and then its last mach_msg_overwrite comes back with reply status **0x10000003 =
  MACH_SEND_INVALID_DEST**, whereupon it exit_group(1). launchd sees that as
  `SIGCHLD {si_pid=4, si_status=1}`, keeps going for another dozen successful RPCs, and only
  THEN gets ECONNREFUSED. So MACH_SEND_INVALID_DEST is the earliest thing that goes wrong and
  is the better thread to pull; the ECONNREFUSED may well be downstream of whatever state
  that leaves behind.

  ELIMINATED by measurement, do not re-investigate:
    * The portset/kqueue linkage. One portset, not empty, and a message on a member port
      DOES wake the kqchan waiter.
    * "Stranded messages on ports with empty klists." Posted == consumed, 18 for 18.
    * The daemon restarting or its socket being replaced. `Listener::bind` unlinks and binds
      once; the socket inode is stable across a run and `lsof` shows it alive and
      `type=DGRAM (UNCONNECTED)` at failure time.
    * "Two daemons fighting over the path." The WORKING (DARLING_NO_LAUNCHD=1) run has
      three darlingserver processes and the failing one has two, so the count is not it.

    * The socket being replaced mid-run. Sampled at 100 Hz for 6s: the inode at
      <prefix>/.darlingserver.sock never changes.
    * The container's mount namespace resolving the path differently. The host, the daemon's
      /proc/PID/root and the guest's /proc/PID/root all stat the SAME inode.

  ANSWERED: the destination is **MACH_PORT_NULL**. Instrumenting all three INVALID_DEST
  exits of ipc_kmsg_copyin_header gives exactly one event per boot:

        copyin_header: INVALID_DEST (name not valid) dest=0x0 reply=0x403 dest_type=19

  dest=0x0 with a perfectly good reply port (0x403) and dest_type 19 (COPY_SEND). The job is
  not sending to a stale or dead port; it is sending to a port it never got. That makes this
  a BOOTSTRAP PORT problem, not an IPC one: a launchd job whose bootstrap_port is null fails
  its first service lookup and exits, which is the exit(1) launchd sees.

  ROOT CAUSE FOUND AND FIXED (the first cause, not the whole task). Every guest task was
  created with NO PARENT: Registry::ensure_task passed std::ptr::null_mut() to
  dtape_task_create, which its own comment admitted ("Parent is NULL for now"). ipc_task_init's
  parent==TASK_NULL branch sets itk_bootstrap = IP_NULL, so a launchd JOB could never inherit
  launchd's bootstrap port however correct everything else was. It asked, got nil, sent its
  first service lookup to MACH_PORT_NULL and exited.

  ensure_task now finds the parent through /proc/<host pid>/PPid and passes its task. The
  lookup has to happen there rather than in Handler::set_current, because the task is created
  before the first call is dispatched and set_current's parent link comes too late. With a
  parent, ipc_task_init also inherits the exception ports, the registered ports and the
  security/audit tokens, which is what XNU does.

  Measured, same boot, before and after:

        before   dtape_task_create: nsid=4 parent=(nil)      GET bootstrap -> (nil)   INVALID_DEST dest=0x0
        after    dtape_task_create: nsid=4 parent=0x..d8e10  GET bootstrap -> 0x..cbe50   INVALID_DEST count 0

  launchd STILL does not complete. It is NOT a deadlock: it is a 30-SECOND POLL LOOP.
  Timestamping the daemon's own strace and measuring the gaps gives 29.555s, 30.001s, 30.001s,
  each ending with a reply to call #62 semaphore_timedwait. launchd waits on a semaphore with
  a 30 second timeout, times out, does two or three RPCs, and waits again -- forever. An
  earlier revision of this entry called it a quiescent deadlock with ninety seconds of
  silence; that was an artifact of filtering the trace on one timestamp prefix and missing the
  intermediate cycles. Read gaps, do not eyeball a filtered tail.

  The ECONNREFUSED cascade is HALF a teardown artifact, and the other half is the real event.
  Sampling process counts every 2 seconds against the guest's own RPC log (with that log
  DELETED first -- see below) shows a sharp partial collapse mid-run:

        t=22s  daemons=2  mldr=4  rpclog=0
        t=24s  daemons=1  mldr=2  rpclog=3

  Two mldr processes and one darlingserver disappear together at ~23 seconds, and all three
  -111 lines (mach_reply_port, mach_msg_overwrite, interrupt_enter) appear in that same
  instant, with 66 seconds of timeout still to run. In the earlier timestamped run the
  refusal coincided with the harness's own SIGTERM, which is what led to calling the whole
  cascade an artifact; it is better stated as: something in the container dies at ~23s, and
  ONE process's -111 triple is its death rattle. Exactly 3 lines per run, then silence.

  TRAP, and it cost a wrong reading: /tmp/dserver-client-rpc.log is the HOST's file. The guest
  and the host resolve it to the SAME inode, and it is opened O_APPEND, so it accumulates
  across every run. Thirty-one lines of repeating -111 look like a live retry loop and are
  actually ten runs' worth of three. Delete it before every run. `strace -ff -tt` across every
  thread settles it by timestamp:

        11:59:32.5   all activity stops, about one second into the boot
        ...          NINETY SECONDS of complete silence, every process blocked in recvmsg
        12:01:11.6   the harness's own `timeout 100` fires and SIGTERMs the daemon
        12:01:11.648832  daemon killed
        12:01:11.648946  launchd's sendmsg -> ECONNREFUSED, 114 MICROSECONDS later

  So the ECONNREFUSED, the -111, the abort and the exit(1) are all artifacts of the TEARDOWN.
  They are what any process gets for talking to a daemon that has just been killed. Do not
  chase them again; use a timeout longer than the observed hang and look at the QUIET period.

  WHO IS WAITING, from the daemon's own RECV trace (DSERVER_TRACE_CALLS=1), last call parked
  per (nsid, tid):

        nsid=1 tid=1  #38 mach_msg_overwrite   launchd's dispatch thread, blocked on the PORTSET
        nsid=1 tid=3  #62 semaphore_timedwait  a launchd worker in a timed wait
        nsid=4 tid=4  #38 mach_msg_overwrite   the JOB, blocked in a mach_msg

  And guest pid 4 is `launchctl bootstrap -S System` (from its execve). So the ORIGINAL entry
  named the right victim after all, even though its portset explanation was wrong.

  THE IPC ITSELF WORKS. Measured in one round trip, lines 793-808 of the daemon log:
    * the job sends to launchd; the message lands on a port that IS in the portset and
      `wq_prepost_do_post_locked` preposts it to set 0x40001;
    * launchd's receive CONSUMES that prepost (`waitq_clear_prepost_locked: invalidate
      prepost 0x280000`);
    * launchd replies to pid 4 and the post finds a real receiver (`receiver=0x..247b60`).
  So bootstrap messaging is not broken. After that exchange everything simply goes idle.

  THIRD FIX LANDED: proc_get_effective_thread_policy's stub returned -1 for every flavor
  except LATENCY_QOS, and -1 is TRUTHY. Every XNU caller reads that result either as a
  boolean flag (DARWIN_BG, PASSIVE_IO) or as a small non-negative tier/QoS class (IO, QOS,
  THROUGH_QOS), so every thread read as "background" and every throttle tier came back
  nonsense. The real implementation exists in xnu/osfmk/kern/thread_policy.c but is NOT in
  the duct-tape build, so the stub wins. Returning 0 (not background, no throttling, QoS
  unspecified) is the neutral answer for all of them. Measured across three runs each:
  mldr processes surviving at t=32s went from 2 to 3, consistently. The stub line was the
  LAST line of every boot log, in five runs out of five.

  Run-to-run VARIANCE is real and has corrupted single-run readings before: the -111 count
  per run is 0 to 4, while the end state (process counts, daemon log length 445-467) is
  deterministic. Measure across at least three runs before believing a difference.

  ROOT CAUSE FOUND AND FIXED. An S2C call (the daemon asking a guest to do something, e.g.
  the mmap that copies out an OOL memory descriptor) was addressed using a single global
  "current guest", set by the serve loop from the call it was dispatching. That is only
  correct while that dispatch is on top. A microthread parked in a blocking mach_msg receive
  is resumed as a SIDE EFFECT of another thread's call -- the reply that wakes it arrives on
  the SENDER's dispatch -- so when it resumed and needed an S2C, it read the sender's identity
  and sent its mmap request to the wrong process. The reply was then filed under the wrong
  (pid,tid) key, so the waiting microthread was never rescheduled: a permanent hang, with the
  guest thread stuck in recvmsg and the daemon showing a RECV with no matching reply.

  The identity now lives on the Microthread (sched.rs s2c_peer), bound when a call is
  dispatched onto it, so a resumed microthread still targets its OWN guest. The global slot
  remains as a fallback for microthreads that never had one bound.

  How it was found, because the method is the transferable part:
    * /proc/PID/task/*/syscall on the guest processes. gdb is useless here (guest Mach-O has
      no host symbols, every frame is "?? ()"), but the raw syscall number + args showed all
      three threads blocked in recvmsg(512) -- waiting for the daemon, not deadlocked on
      each other.
    * A SEND-reply trace to pair with the existing RECV trace. Received-and-parked-forever
      and received-and-answered look identical without it. That gave the decisive count:
      every thread parked in exactly ONE unanswered call.
    * The Mach msgh_id, which is the MIG routine number. 420 in subsystem "job" (base 400,
      src/launchd/src/job.defs) is job_mig_kickstart, and its reply is 520. That named the
      operation instead of leaving it as "some message".
    * The descriptor type. Every complex message in the boot carried dtype=0 (a port
      descriptor, which copies out entirely inside the daemon) EXCEPT kickstart's request and
      reply, which carry dtype=1 (MACH_MSG_OOL_DESCRIPTOR). The first message needing OOL
      copyout to a BLOCKED guest thread was exactly the one that hung. That is what turned a
      structural coincidence into a mechanism.

  Result, measured over three runs: daemon log 445-467 lines -> 4181-4210; mldr processes at
  t=36s 3 -> 6/10/14 (launchd is spawning jobs now); launchctl RECV=71 SEND=71, balanced.
  The container still does not finish -- see the next entry for where it gets to now.

  #47 IS DONE. The container now boots through launchd -- launchd as guest pid 1, launchctl
  bootstrap -S System loading the system jobs, memberd and shellspawn running, 21 guest
  threads where there used to be 3 -- and runs a command to completion. Locked in by
  scripts/buck-launchd-check.nu, which is the no-launchd check's counterpart and exists
  because "bash runs" never implied "init works": the no-launchd path skips init entirely.

  TWO OPS TRAPS, both of which cost real time here and will cost it again:

    * `pkill -9 -x a b c` is a USAGE ERROR ("only one pattern can be provided") and kills
      NOTHING, silently, exiting 2. Every cleanup written that way is a no-op. 22 stale mldr
      processes from earlier runs had accumulated and were competing with live measurements.
      Use `pkill -9 -x 'mldr|darling|darlingserver|shellspawn'` -- one ERE pattern.
    * Do NOT pre-create DPREFIX. darling treats an existing prefix directory as one it has
      already set up, so `mkdir -p` before booting skips first-time setup and launchd boots
      into an unpopulated filesystem and stalls deterministically at ~509 lines of daemon
      log. This masqueraded as a port bug for a while: the check failed 3/3 while the same
      command by hand passed 8/8, and the only difference was the mkdir.

  A SEPARATE bug found along the way, not yet fixed: a guest fd that is a SOCKET gets the
  vchroot prefix pasted onto readlink's output, producing the path
  "/Volumes/SystemRootsocket:[100816751]". Visible as a [guest kprintf] "dtype for fd 2"
  line. It blinds launchctl's stderr, which is its own reason to care. Find out whether its
  RPC reply was actually SENT after the microthread was woken, or whether the wake and the
  reply have come apart. That is a narrow question about the daemon's parked-microthread
  resume path, and it is the last unexplained step.

  Not a lead: shellspawn is PRESENT in the prefix, at usr/libexec/shellspawn (NOT
  usr/libexec/darling/shellspawn, where I looked first and wrongly concluded it was missing),
  together with System/Library/LaunchDaemons/org.darlinghq.shellspawn.plist. `launchctl
  bootstrap -S System` is what should load that plist, which is why nothing runs the command:
  the launcher waits for a shellspawn that never starts because bootstrap never finishes.

  ELIMINATED for the ECONNREFUSED before it turned out to be a teardown artifact, kept because
  the same ideas will tempt the next reader: the daemon closing its socket (it binds fd 3 once
  and never closes it), the path resolving differently after vchroot (host and every guest
  /proc/PID/root stat the same inode), and an fd-parking race on 512/513/514 across launchd's
  shared thread fd table (with -tt, no other thread touches those fds anywhere near the send).

  Do NOT misread launchd's console banner: "launchd[1] has started up" followed by "Shutdown
  logging is enabled" is its STARTUP message, and the second line is about log configuration,
  not a shutdown. The guest also keeps its own RPC log at
  /tmp/dserver-client-rpc.log -- INSIDE the container's mount namespace, so it is not visible
  at that path on the host, which is why it reads as empty there.

  A note on tools: `ss -x` cannot see the daemon socket from the host, because unix sockets
  are netns-scoped and the daemon lives in the container's namespace. `lsof -U` can (it walks
  /proc/*/fd), and /proc/<daemon pid>/net/unix reads that namespace's table directly.

  Reproduce by dropping `DARLING_NO_LAUNCHD=1`. The daemon's own log is
  `<prefix>/darlingserver.log`, NOT the launcher's stderr. Still bypassed by
  `DARLING_NO_LAUNCHD=1`; not on the nix-builds critical path.
- Multi-user nix-daemon, `_nixbldN` setuid-in-userns, concurrent-build fcntl locking — open,
  production-hardening, not on the critical path (single-user M1 sidesteps it).

### CI + remote builder (built in Campaign 1, unvalidated — needs rework)
Machinery exists but was **never validated end-to-end on a live prefix** and predates the
Rust rewrite / launchd-bypass / 26.05 pin / submodule removal:
- CI: `.tangled/workflows/ci.yml` (tangled.org), `tests/*.nix`,
  `tests/nix/compatibility-matrix.sh`, dirserv-stubs check.
- Remote builder: `nix/darlingBuilderModule.nix` (`services.darling-builder`, sshd in prefix,
  `nix.buildMachines`), `scripts/darling-build-hook`, VM tests. Design (host
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
- Newer-toolchain build fixes (we build under clang 21): darling
  `e3fe4288 3f277ba5 9f485c91 ddd118d9 fc5c0666`, xnu `644decacee`. Cherry-pick onto our
  patched xnu; **don't bump the gitlink** (ours diverges).
- libkqueue `b0795a2e` (EVFILT_TIMER type-punning) if a kqueue-timer stall appears.
- Upstream darlingserver C++ tracking is obsolete (we're full-Rust). Fixing the launchd-boot
  hang would be an upstream-caliber rootless contribution.

---

## Operational notes / gotchas

- **Run recipe** (from a built `$out = nix build .#default`):
  `DSERVER_LIBEXEC_PATH=$out/libexec/darling
  DSERVER_MLDR_PATH=$out/libexec/darling/usr/libexec/darling/mldr DARLING_NO_LAUNCHD=1
  DPREFIX=<fresh dir> $out/bin/darling shell sh -c 'uname -sm'` → `Darwin x86_64`.
- **Phantom-path trap:** after any commit that touches a Rust crate, `.#default`'s hash
  changes and `nix eval .outPath` returns a NEW, UNBUILT path. Booting against it fails
  SILENTLY (daemon binary absent → launcher spins in its container-acquisition loop,
  wchan=hrtimer_nanosleep, empty log, `pgrep darlingserver` finds nothing). Always
  `nix build .#default` first (or assert `test -x $out/bin/darlingserver`). The same drift
  happens dirty→committed (a dirty-tree build and its commit hash differ).
- **mldr debug is gated** behind `MLDR_DEBUG=1` (default off). Do NOT grep for `[mldr]` to
  confirm a boot with the gate off — grep guest stdout (`Darwin`/`uname` output). The ungated
  ~15-line-per-process flood interleaving with stdout under `2>&1` was the false
  "concurrent-output flake"; measure output completeness with stdout/stderr SEPARATED.
- **mldr elfcall movaps constraint:** the guest calls elfcalls on an 8-byte-misaligned
  stack, so elfcall-reachable loader code must be movaps-free — no `mem::zeroed`/`Default` of
  a >8-byte struct on the stack (emits an aligned SSE store that #GPs); use `MaybeUninit` +
  scalar fills.
- **duct-tape two-phase init:** `dtape_init` then `dtape_init_in_thread` on a kernel
  microthread (psynch etc.); no hook in the 36-field vtable may ever be NULL (NULL → indirect
  call to 0x0).
- **RPC socket fork-safety:** sockets live at high fds + FD_CLOEXEC (so a forked subshell's
  low-fd dup2/close can't clobber them); the child does a socket-refresh.
- **One command per fresh container** (kill the stale daemon first). Keep the prefix path
  short — the daemon/shellspawn AF_UNIX socket lives under `<prefix>/var/run/` and overflows
  `sockaddr_un.sun_path` (~108 chars) on long paths; use `~/.darling`. Export
  `TMPDIR=$HOME/tmp` (the default Darwin temp dir EACCESes). Two-boot warm flow; harness
  output must be file-based, never piped through a reader (a leaked container holds the pipe
  write-end open and blocks EOF).
- **`__private_extern__` is not a linker bug (#57):** modern clang emits it as an *undefined*
  symbol; link the consumer against real ncurses/libtinfo, don't touch ld64. `-fcommon`
  doesn't fix it.
- **xnu pin gotcha:** the super-repo gitlink was a Campaign-1 rev never published upstream;
  darling-src fetches the pinned rev from `submodules.json` + applies `patches/xnu/*`.
  Cherry-pick upstream fixes onto our patched xnu; don't bump the pin blindly.
- **nix-ninja / mig gotchas:** merged `$out` conflates a checked-in `osfmk/**/X.h` with the
  same-named mig-generated header (10 collisions; `notify.h` is
  `_MIG_KERNEL_SPECIFIC_CODE_`-sensitive — force it to 1 via a duct-tape patch); mig edges
  need `-DKERNEL_USER -DMACH_KERNEL -DKERNEL`; `lower.nix` must `rm -f` a staged read-only
  source symlink at a declared output path (else mig `fopen`→EACCES). Full-graph nix-ninja is
  ~26k derivations — keep it OUT of `nix flake check`.

---

## The goal: full parity with upstream Darling

Everything upstream Darling supports, this project supports. Same libraries, same
frameworks, same features. What changes is only HOW it is built: buck2 instead of cmake,
Rust instead of the C daemon/launcher/loader, Nix instead of a system install. The port is
not a subset and is not finished when something merely boots.

Darling's own COMPONENTS hierarchy (cmake/darling_parse_components.cmake) is the measure,
because it is upstream's own decomposition:

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
2. **stock**. The flake already builds a `stock` graph (`packages.darling-graph`), so
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
   everything else in stock sits downstream of them. The 16 src/native ELF wrappers are
   already done, see below; the rest are Darling's own framework implementations under
   src/frameworks (101) and src/private-frameworks (45), plus 314 in src/external which is
   mostly python, ruby, perl and their extension modules.

   Stage 2 is effectively complete: 1354 of 1359 stock link edges. The five that remain
   (DBusKit, iokitd, bsdln, getuuid, elfdep) have their blocks removed and their causes
   written up above. The next item is THE STOCK SWITCH itself, which unlike everything
   else in stage 2 does change buck/prefix/BUCK, so it needs the runtime checks and the
   guest-nix milestone run rather than skipped.

   Beware NAME COLLISIONS when driving the generator by cmake target name across the wider
   graph. `X11` is both the src/native wrap_elf stub and CoreGraphics' X11 backend in
   src/frameworks, and `gen-buck-from-ninja.py --dylibs X11` silently picks the latter.
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
  the BUILD tree only -- `buck/ src/ darwin/ linux/ tests/ cmake/ etc/ misc/ patches/
  templates/ tools/ buck-src/ buck-rust/` plus the root dotfiles. `scripts/`, `nix/`,
  `docs/`, `plan/`, `PLAN.md` and `flake.nix` are NOT in it, with three exceptions that
  are their own inputs: `scripts/buck2-graph-dump.py`, `scripts/buck-src-normalise.py`,
  and `nix/lib/darlingBuck2{Graph,Lower}.nix`, which ARE the derivations.
  `scripts/buck-endpoint-stale.nu` answers this in a second, and it now takes the rule from
  the two filters rather than from a listing of the result: both drop `tests/**/*.nix`, so
  editing the VM test is NEUTRAL (measured: the prefix derivation did not move, and
  `nix build .#darling-buck2` afterwards consumed the very store path the earlier build had
  produced), while `tests/buck2/**` holds real targets and is not.
- **Evaluating the endpoint: 155s to 58s, measured with the eval profiler.**
  `nix eval --raw .#darling-buck2-prefix.drvPath --eval-profiler flamegraph
  --eval-profile-file <f>` works in nix 2.34 and puts 57 percent of the self time in
  darlingBuck2Lower.nix. Three output-preserving fixes: the staged-tree script escaped the
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
  `bin/darling`, `bin/darlingserver` and `bin/darling-coredump`, and
  `scripts/buck-bash-check.nu --prefix result/darling_prefix__prefix` PASSES: the container
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
  #55 are all downstream of it.** `darlingBuck2Graph.nix` takes the project as ONE
  `builtins.path` that excludes only plan, docs, nix, scripts and a few dotfiles, so
  `darwin/`, `src/`, `linux/` and `buck-src/` are all in it. Edit one C file and the graph
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
- **#44: the narrowing gap is 25 quoted includes, and depfiles are not needed to close it.**
  The comment at `projectSrc` says this case only depfiles can answer, and that narrowing
  waits on a 90 minute build. Both are wrong; it measures on the host in ten seconds.
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
  `The input derivation named darling-buck2-graph.drv differs` and then `Sources: - old
  buck2-graph-dump.py + new`. That is the whole #55 cascade in one command. It beats
  decoding the `text` env var out of a `.drv` by hand, which is how this was first found.
  Pair the SAME artifact across the two revisions, not two different variants: comparing the
  default prefix against the coarse one just reports pin merging and tells you nothing.
- **VERIFY ON ONE DERIVATION, NOT ON A FULL PREFIX REBUILD.** #50 was proven on
  `.#darling-buck2-lowered` in minutes and #52 on a single target in 10 minutes, both by
  diffing a sorted file list plus per-file sha256 against a known-good output. Queueing #53
  behind a 3 hour rebuild of all ~8,400 derivations tested nothing that
  `nix build /nix/store/<hash>.drv^out` would not have caught, and blocked every other
  increment while it ran. Reach for a whole-endpoint build only to produce the deliverable,
  or when the change really does touch every derivation, and say which it is.
  Two related traps: a CONTENT ADDRESSED drv holds a deferred placeholder, so grepping a
  `.drv` for a store path finds nothing and the derivation has to come from the closure;
  and for the same reason the check is whether nix RERUNS THE BUILDER, not whether a
  drvPath moved.
- **DONE (#50): the graph derivation has two outputs and is content addressed, so a
  dump-format change no longer rebuilds the port.** `graph.json` and `target-sources.json`
  are read only by the EVALUATOR and stay in `out`; `staged/` and `treelinks/` are read only
  by the lowered BUILDERS and move to `data`. Recorded paths are relative, so the split is a
  move. Verified BOTH ways on `.#darling-buck2-lowered`: adding a key to graph.json rebuilt
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
  `.#darling-buck2-lowered` and a real codegen target (dserver_rpc) out of the new graph,
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
  include roots remain as rule bugs worth fixing on their own: `src/xtrace/include`
  (44 uses), `src/launchd/src`, `buck-src/security/OSX/libsecurityd/mig`.
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
- **Never pre-create DPREFIX.** darling treats an existing prefix as already set up, and
  launchd then boots into an unpopulated filesystem and stalls deterministically.
- **`pkill -f <pattern>` matches the command you are about to run** (exit 144). For
  containers use one ERE pattern: `pkill -9 -x 'mldr|darling|darlingserver|shellspawn'`.
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
  its own prefix and daemon behind: `pkill -9 -x 'mldr|darling|darlingserver|shellspawn'`.
  (2) A wrong ARTIFACT at a right path, which looks identical from outside: read the
  `buck/prefix/BUCK` diff, which is how a dylib landing at usr/bin/login was found. (3) Load.
  Running the checks immediately after a large rebuild fails them; the same scripts pass on
  an idle machine minutes later. Boot the container by hand as the tiebreaker -- it takes
  seconds and tells you at once whether the tree or the harness is at fault:
  `DPREFIX=<fresh> DSERVER_LIBEXEC_PATH=$rt/libexec/darling
  DSERVER_MLDR_PATH=$rt/libexec/darling/usr/libexec/darling/mldr DARLING_NO_LAUNCHD=1
  $rt/bin/darling shell /bin/bash -c 'echo HELLO'`.
- **Measure before attributing slowness**, and revert a fix whose premise turns out wrong.
  gen-install-from-manifests.py's eight minutes were a per-entry repo walk, not the
  backtracking regex I first blamed.

Guest-nix milestone against a buck2 prefix: materialize it to an `rt` dir, then
`DSERVER_LIBEXEC_PATH=$rt/libexec/darling
DSERVER_MLDR_PATH=$rt/libexec/darling/usr/libexec/darling/mldr bash
scripts/build-hello-bypass.nu --mono $rt --prefix /tmp/darling-hello-m1-buck2`. Expect
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
portset deadlock (#47, bypassed by `DARLING_NO_LAUNCHD=1`), the SIGFPE exec-fidelity flake
(#44, retryable), and the nix-ninja full-graph `migHeaderIncsFor` blocker. Nothing else is
currently un-tracked.

## Grouped build: eval speed (done) vs incremental rebuild (open) — task #80

The grouped lowering (task #78) built every ninja edge's command + staging script as a Nix
string DURING EVAL, so whole-Darling eval was ~15-40 min, paid on every build (the graph-json
IFD busts Nix's eval cache). Fixed by **build-time lowering** (`nix/lib/nix-ninja/build/lower_group.py`,
flag `buildTimeLowering`): Nix eval now computes only each group's `{edge list, external-group
drvs}`; the tool reads the shared `graph.json` in the sandbox and does the rewrite/stage/run.
Measured: `darling-full-group-bt` eval **~58 s** (was ~35 min); migcom + libSystem green through
it. `darling-{group-test3,libsystem-group,full-group}-bt` exercise it; the legacy eval-time
`mkGroup` path is untouched behind the flag.

**Incremental rebuild is a separate, still-open problem, and it is NOT just source staging.**
A small source edit currently triggers a ~full recompile, because of a chain of store-path
couplings that all rehash on any source change:
- `cmakeSrcStore` (whole source tree) rehashes → CMake **re-configures** (~min) →
- `build.ninja` bakes absolute `cmake-src` / `cmake-ninja-configured` paths → the **graph-json
  (`graphDrv`) rehashes** (confirmed: `graphDrv` contains those store paths) →
- every bt group derivation reads `graphDrv` (and mounts the rewrite roots) → **all ~900 groups
  rebuild**.

So per-component source staging alone cannot deliver incrementality — `graphDrv` is the dominant
blocker. The full fix is three pieces, in order:
1. **Relativise the graph** so `graphDrv` is content-stable across source edits (strip the
   rewrite-root prefixes in the graph-json derivation; make it content-addressed so a re-config
   that yields byte-identical relative content keeps the same store path). This is the key
   enabler — without it (2)/(3) are moot.
2. **Per-component source subtrees** (`builtins.path` slice of `cmakeSrcStore/<component>`,
   content-addressed): a group depends only on its component's subtree, so editing one `.c`
   re-keys just that component. Keeps eval fast (no per-file `indivOf`/`readDir` in eval).
3. **Configure decoupling**: feed the configure derivation only CMake-relevant files so a
   `.c`-content edit does not re-run cmake at all.

Honest architectural note: this is exactly where the nix-ninja + IFD approach hits its
structural ceiling. Even done perfectly, it re-evaluates every build (~58 s) and its
incrementality is per-*derivation* (whole component recompiles), never per-*action* (one `.o` +
relink). **Buck2's persistent daemon avoids all of these store-path-rehash couplings by design**
(no configure/eval per build, per-action deps) — so the fast edit->rebuild inner loop is the
genuine case FOR a Buck2 port, distinct from the eval-speed problem (which was a fixable Nix
issue, now fixed). Recommendation: finish the full-green grind (#2) + implement (1)-(3) to get a
~1-3 min component-incremental loop with no port; treat Buck2 as the deliberate next step only if
that loop proves too slow for how Darling actually gets developed.

### Full-green grind (#2): where it stands (branch `wip-mega-group-unwind`)

The build-time path (`darling-full-group-bt`) grinds green through migcom -> libSystem -> duct-tape
-> libc -> and reaches the `security/*` / openssh tier. Mechanical gaps fixed along the way (all
committed): skip CMake housekeeping targets, shebang rewrites on staged sources AND generated script
outputs, rspfiles, ext-dir de-symlink before cp, command-referenced source staging, srcHeaders
non-header include-chain data (`.exp`/`.exp-in`/`.list`/`.ipp`), cctools ar+ranlib co-grouping by
OUTPUT tool dir.

Wall #2 from the earlier note (the `build-mig` dense-staging mega-SCC) is now UNWOUND, and the
duct-tape `notify.h` wall is FIXED. Committed on the branch (`639e374e`, `c723f265`):
- **notify.h source-restore** (`lower_group.py`): `mach/notify.h` exists as BOTH a hand-written
  source header (defines `MACH_NOTIFY_*` + the notify structs) and a mig re-emission (routine stubs
  only). The merged `$out` cannot hold both; mig's copy shadowed the source and broke every
  `<mach/notify.h>` kernel consumer. Fix: after a source-backed generated header is produced, restore
  the authoritative source copy over it (the mig `.c` consumers only need the structs, also in source).
- **mega-SCC unwind** (`lower.nix`): `rawHeaderProducerGroups` is now GROUP-LEVEL pure -- a mixed
  pure-gen + compile-dependent group no longer becomes a universal dep, so `build-mig` no longer
  absorbs duct-tape/bootstrap_cmds/... Mixed-group header producers retarget per-component via
  `migByCompDir` (which skips source-backed headers).
- **Tarjan SCC topo** (`lower_group.py`): the old Kahn fallback dumped a blocked SCC's edges in
  list order, mis-ordering acyclic producer->consumer pairs riding on the SCC (libc's dylib link ran
  before the `notify_firstpass` it links). Replaced with iterative Tarjan condensation (producers
  first; only genuine cycles emit as a block). Fixed libc.

Remaining `darling-full-group-bt` failures (18, taxonomised), in priority order:

1. **Source header shadows a SYSTEM header for a C compile (WALL #1, ~14 failures, dominant).**
   Confirmed via the compiler's `In file included from` chain (NOT a plain libcxx-on-`-I` issue):
   a C compile in `security/*` (e.g. `Security_x86_64_only_stuff`, `SecLogging.c`; `-std=gnu99`, no
   `-isysroot`) includes the SDK's `corecrypto/ccdigest.h` -> `cc.h` -> `cc_config.h:429`, which does
   `#include <endian.h>`. That resolves to `src/external/security/OSX/libsecurity_utilities/lib/
   endian.h` -- a SOURCE header shadowing the system `<endian.h>` because security's lib dir is on the
   compile's `-I` list -- and it drags in the security_utilities C++ chain (`utilities.h` -> `errors.h`
   -> `<exception>` -> libcxx `<cstddef>`), which is C++-only and explodes in C mode (`unknown type
   name 'using'`). So the trigger is `-I` precedence over SYSTEM headers, not libcxx per se. The
   reference build avoids it (some mix of `-isysroot`, `-iquote` vs `-I`, or not having that lib dir on
   the C compile's search path); our flat merged-`$out` + broad `-I` list does not. Fix needs deliberate
   header-search scoping so source-tree dirs do NOT shadow toolchain/SDK system headers for a compile
   that only asked for `<endian.h>` -- e.g. move project header dirs to `-iquote`/`-idirafter`, or add
   `-isysroot <SDK>` AND ensure system-name includes prefer the sysroot. This is the genuinely DEEP
   design wall (same class the eval-time `mkGroup` path would hit); needs a header-search decision, not
   a one-line strip. UNVERIFIED fix.
2. **libbsm cross-group `libSystem.B.dylib` staging (1 failure, foundational).** `libbsm` links the
   final umbrella `libSystem.B.dylib`; at BUILD time it is missing from libbsm's group sandbox. Ground
   truth (instrumented): libbsm's group ran but did NOT contain the libSystem.B producer edge, and the
   umbrella dylib was not ext-dir-staged in -- yet an eval probe reported the two edges in the SAME
   group with the producer in `extGids`. That **eval-vs-build grouping inconsistency** is the bug to
   chase next (idsInGroup vs the `--edges` actually passed, or a realProducers path-form mismatch).
3. **Generated data files not staged (2 failures).** openssh `ge25519_base.data`, libsecurity_cssm
   `derived_src/funcnames.gen` -- generated non-header data a compile reads, not reaching the sandbox.

Status: the eval floor is fixed+committed; the notify.h wall + mega-SCC are fixed+committed; libc
green. `main` stays green on the default (eval-time) path and `darling-{group-test3,libsystem-group}
-bt`; `libSystem-group-bt` is green on the build-time path too (re-verified). `full-group-bt` green
through libc; the dominant remaining blocker is WALL #1 (root-separation). The generic `nix-ninja`
lib is upstreamable to overby.me (sibling to its buck2/cargo libs; rust-ninja extractor already
lives there) -- root-separation is the main pre-upstream item.
