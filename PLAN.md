# PLAN.md — Campaign 2: x86_64-darwin builds on nixpkgs 26.05, structured for the aarch64 port

> **Audience:** an autonomous agent (Claude) working in this repository (`darling-nix`,
> a fork of darlinghq/darling with Nix support layered on top).
> **Read this whole file before touching anything.** Then read `plan/README.md` and skim
> the `plan/` documents from Campaign 1 — the phase machinery, scripts, and conventions
> from that campaign are reused here, not reinvented.

---

## 1. Mission

**End goal (not this campaign):** build `aarch64-darwin` nixpkgs derivations on
non-Apple ARM Linux hardware, using Darling as the Darwin compatibility layer.

**This campaign:** make `x86_64-darwin` builds actually work end-to-end against
**nixpkgs 26.05**, because:

1. Iteration is native-speed on our x86_64 dev machines (no QEMU tax).
2. nixpkgs 26.05 is the **final** release supporting x86_64-darwin. It is a *frozen
   target*: the package set, bootstrap tools, and Hydra-built cache paths will never
   move again. cache.nixos.org historically retains old store paths, so it remains a
   permanent correctness oracle.
3. Most of the remaining work (libSystem symbol surface for macOS 14, the build/verify
   harness, the cache-diff oracle, daemon plumbing) is **architecture-independent** and
   transfers wholesale to aarch64.

Every task below is tagged **[ARCH-FREE]** (transfers to aarch64 as-is),
**[ARCH-PARAM]** (transfers if parameterized now), or **[X86-ONLY]** (throwaway —
minimize investment).

---

## 2. Ground truth (verified July 2026 — re-verify anything load-bearing)

### 2.1 nixpkgs / platform facts

- Nixpkgs **26.05 "Yarara"** (released 2026-05-30) is the **last release supporting
  x86_64-darwin**. Binaries are built until 26.05 EOL at end of 2026. 26.11 drops the
  platform entirely, including building from source.
- Since nixpkgs 25.11, the minimum supported macOS is **Sonoma 14.0** (Darwin kernel
  **23.x**). Default SDK was 14.4 as of 25.11. `cc-wrapper` enforces availability
  annotations / deployment targets.
  **Do not hardcode these — verify against the actual pin** (see Phase A task 1).
- The modern SDK pattern: a unified `apple-sdk` package provides `$SDKROOT` with
  `.tbd` text-stub libraries (`usr/lib/libSystem.tbd` re-exporting the
  `libsystem_*` constellation). Binaries link against stubs; symbols resolve at
  runtime from the host — i.e. **from Darling's reimplemented libraries**. This is
  why derivation hashes don't depend on Darling at all.

### 2.2 Repository state (end of Campaign 1)

Already built and working to some degree — reuse, don't rebuild:

- **Syscall fixes:** `renameatx_np`→`renameat2`, `setattrlist`/`getattrlist`
  ATTR_CMN_FLAGS handling (the lchflags blocker), `clonefile`→`ENOTSUP` fallback,
  `utimensat` fixes + regression tests (`tests/syscall/`).
- **Sandbox:** `sandbox-exec` parse-and-ignore stub (`src/sandbox-exec/`),
  sandbox API stubs fixed to report success.
- **Directory Services stubs:** `dscl`, `dseditgroup`, `sysadminctl`
  (`src/dirserv/`, 78-test suite).
- **Nix install automation:** `scripts/install-nix-in-darling.sh`,
  `scripts/darling-nix` wrapper, `scripts/verify-nix.sh` health check.
- **Build testing:** `scripts/build-trivial.sh` (5 progressive levels),
  `tests/nix/compatibility-matrix.sh` (4-tier matrix, JSON reporting).
- **Triage automation:** `scripts/triage-syscalls.sh` — runs Nix ops inside Darling,
  captures unimplemented-syscall messages, emits a Markdown report. This is the core
  grind loop; extend it, keep it working.
- **Remote builder:** `nix/darlingBuilderModule.nix` (`services.darling-builder`,
  sshd in prefix, `nix.buildMachines`), `scripts/darling-build-hook` (no-SSH offload),
  NixOS VM tests (`tests/darling-builder.nix`, `tests/nix-in-darling.nix`,
  `tests/darling-smoke.nix`), tangled.org CI (`.tangled/workflows/ci.yml`).
- **Known problem branches:** `fixPythonPipStalling` (runtime stall class — likely
  kqueue/select/poll fidelity), three `feature/arm-support*` attempts (salvage
  assessment is Phase F).

**Campaign 2 addendum (verified 2026-07-19):** Campaign 1 machinery was never
validated end-to-end on a live prefix. The fork's submodules are fetched from
upstream darlinghq via `scripts/init-submodules.sh` (relative URLs are unhosted),
and the Campaign-1 xnu changes are carried as `patches/xnu/*.patch` on top of the
upstream base rev. See `plan/26.05-facts.md` for verified pin facts.

### 2.3 Identity masquerade: **fixed in A.2**

Campaign 1 pinned `SystemVersion.plist` to **11.7.4** (Big Sur) with
`CMAKE_OSX_DEPLOYMENT_TARGET=11.0`. nixpkgs ≥25.11 refuses / misbehaves below
macOS 14.0, and official 26.05 binaries **strongly link the macOS 14.0 libSystem
symbol surface**. A.2 retargeted the identity to macOS **14.4.1** (Darwin
**23.4.0** / build **23E224**); validated under a rebuilt prefix (`sw_vers`,
`uname -r`, and the `kern.os*` sysctls all report it). The deployment target
stays at 11.0 by choice (identity is independent of it; see plan/26.05-facts.md).
Phase B closes any remaining symbol-surface gap.

---

## 3. Invariants — never violate these

1. **Official expressions only.** Build with unmodified nixpkgs 26.05 and its official
   `apple-sdk` derivations. Derivation identity lives in the Nix expressions; our job
   is to make the *outputs* correct, not to fork the inputs. A patched nixpkgs means
   incomparable hashes and a worthless oracle. If a nixpkgs-side change seems
   unavoidable, stop and record it in `plan/blockers.md` instead.
2. **Never copy Apple-proprietary bits into build outputs or the repo.** SDK stubs and
   headers flow through Nix's own fetch of `apple-sdk` (the user accepts that posture);
   we never vendor them. Implementations we write come from Apple's open-source
   releases (APSL: Libc, libsystem_kernel surface, libdispatch, libpthread, libmalloc,
   libplatform, objc4, libc++, CF, dyld) or clean-room work from public documentation.
   Do not consult leaked/proprietary sources. Note provenance in commit messages when
   porting from Apple open source.
3. **The ratchet: green never regresses.** Every fix lands with a regression test.
   `scripts/run-tests.sh` and the flake checks must pass before every commit.
   The compatibility matrix is append-only progress: a package that built keeps
   building.
4. **Arch discipline.** New code that touches registers, syscall numbers, thread
   state, signal frames, TLS, page size, or Mach-O CPU types goes behind the existing
   arch abstraction (or a new `arch/` boundary you create). aarch64 is the customer;
   x86_64 is the test rig.
5. **Follow house style.** Conventional commits with phase tags
   (`feat(phaseB.3): ...`), update this file's checkboxes and the relevant `plan/`
   doc in the same commit, keep `plan/syscall-triage.md` current.

---

## 4. Phase A — Retarget identity to nixpkgs 26.05 / macOS 14 **[ARCH-FREE]**

Goal: Darling credibly claims to be a macOS-14-class system to Nix and to nixpkgs
builds.

- [x] **A.1 Pin and interrogate nixpkgs.** Add a flake input pinned to the
      `nixpkgs-26.05-darwin` branch (fall back to `nixos-26.05` if needed). Record in
      `plan/26.05-facts.md`: `nix eval` results for
      `pkgs.stdenv.hostPlatform.darwinMinVersion`, `darwinSdkVersion`, the default
      `apple-sdk` version, and the exact bootstrap-tools derivation + hash used by
      `pkgs/stdenv/darwin` for `x86_64-darwin`. All later phases cite this file, not
      memory.
- [x] **A.2 Bump the masquerade.** `SystemVersion.plist` → 14.4.1 / 23E224;
      `patches/xnu/0005` sets the `EMULATED_*` defines (kern.osrelease 23.4.0,
      kern.osproductversion 14.4.1, kern.osversion 23E224, banner
      "Darwin Kernel Version 23.4.0") that the guest-side `sysctl_kern.c` handlers
      serve; uname follows osrelease. `CMAKE_OSX_DEPLOYMENT_TARGET` kept at 11.0
      (identity-independent; raising it risks Big-Sur-era sources; see plan/26.05-facts.md).
      Validated: rebuilt Darling reports 14.4.1 / Darwin 23.4.0 / 23E224 across
      sw_vers, uname -r, and the kern.os* sysctls.
- [x] **A.3 Regression-test the identity.** `tests/identity/test_sw_vers.sh`
      passes 3/3 under the rebuilt prefix (macOS 14.4.1 / 23E224).
      `tests/identity/test_identity.c` asserts the same uname/kern.os* triple; its
      raw values are confirmed green, the compiled in-prefix run lands in Phase C
      once guest `clang` is available. Guest `builtins.currentSystem` check folds
      into Phase 0.5 / verify-nix.

**Exit criteria:** `verify-nix.sh` green against the 26.05 pin; no version-floor
refusals anywhere in `nix`'s own operation.

---

## 5. Phase B — Close the libSystem symbol gap to the 14.0 surface **[ARCH-FREE]**

Goal: official 26.05 binaries load under Darling without missing-symbol failures.
This is the highest-value arch-independent work in the whole project.

Strategy: **demand-driven first, exhaustive second.** Implement what real binaries
actually import before grinding the full theoretical surface.

- [x] **B.1 Build the demand list.** `scripts/symbol-demand.sh` — extracts
      system-library imports from Mach-O bind tables (llvm-objdump/otool),
      excluding intra-closure `@rpath` deps, ranked by referencing-binary count.
      Against the 26.05 bootstrap-tools closure: 728 system symbols.
- [x] **B.2 Build the supply list.** `scripts/tbd-diff.py` — parses the 14.4 SDK
      `libSystem.tbd` re-export closure (7988 symbols) and diffs vs Darling's built
      dylibs read from the **exports trie** (critical: Darling re-exports the plain
      str/mem functions; `nm` misses these). Result in `plan/symbol-gap.md`.
      **Finding: the libSystem surface for bootstrap-tools is already covered.**
      Real gap = 6 lazy-bound FSEvents functions in CoreServices; 0 libSystem, 0 CF,
      0 SC. Phase B is nearly a no-op for the `hello` milestone.
- [ ] **B.3 Grind the demand-side gap.** *Mostly moot for hello* (see B.2). Remaining:
      6 `FSEventStream*` stubs in CoreServices, added only if a real binary calls
      them (they are lazy-bound; a hello build should not). For future packages
      (Phase E) that reopen a real gap: (a) port from Apple open source; (b)
      clean-room; (c) loudly-logging stub last. Every addition gets a link-and-call
      test.
- [ ] **B.4 Wire symbol checking into CI.** A flake check that runs B.1's tool over a
      pinned reference closure and fails on *new* unresolved symbols (ratchet file of
      known-missing allowed, shrinking over time).

**Exit criteria:** every binary in the bootstrap-tools closure passes a dyld load
test (no missing strong symbols) under Darling. *Static analysis says this already
holds; confirm empirically in C.2.*

---

## 6. Phase C — The keystone: official bootstrap tools execute **[ARCH-FREE]**

This is the milestone that converts the project from "OS revival" to "treadmill."
Aim everything at it.

- [ ] **C.1 Substitute and stage.** Using the A.1 facts, `nix build` the exact
      bootstrap-tools derivation for x86_64-darwin from the 26.05 pin (it should
      substitute from cache.nixos.org — record the store path and narHash).
- [ ] **C.2 Execute.** Inside the prefix, run the unpacked tools directly: `sh`,
      `coreutils`, `tar`, `sed`, `grep`, then `clang --version`, then compile and run
      a hello.c against the SDK stubs. Triage failures with
      `scripts/triage-syscalls.sh` + `DSERVER` logs; every fix follows the Phase B/1
      pattern (fix + regression test).
- [ ] **C.3 Trivial derivation with official stdenv path.** `nix build` a
      one-derivation package (e.g. `pkgs.hello` or smaller) with
      `--system x86_64-darwin` against the pin, substituting all dependencies,
      building only the target. Then widen: build with `--max-jobs` local only, no
      substitutes for the target's direct deps, forcing real stdenv usage.
- [ ] **C.4 Stall defense.** Wrap all matrix/build invocations in a watchdog
      (timeout + on-timeout stack capture of the guest process and darlingserver via
      gdb attach). Stalls are the signature failure mode of a subtly-wrong kernel
      shim (see `fixPythonPipStalling`); suspects are kqueue/kevent, poll/select
      edge semantics, and Mach IPC waits. File each stall signature in
      `plan/stall-triage.md`.

**Exit criteria:** `pkgs.hello` (26.05, x86_64-darwin) builds from source under
Darling with only official inputs.

---

## 7. Phase D — The oracle: bit-compare against cache.nixos.org **[ARCH-FREE]**

"It built" upgrades to "it built **correctly**."

- [ ] **D.1 One-liner oracle.** For any derivation whose output was substituted from
      the official cache, `nix build --rebuild <installable>` rebuilds locally and
      fails if the result differs. Wrap this as `scripts/oracle.sh <attr>` with JSON
      output (match / mismatch / build-failure / known-nondeterministic).
- [ ] **D.2 Matrix integration.** Extend `tests/nix/compatibility-matrix.sh`: each
      package row gains an oracle column. Maintain an allowlist of
      known-nondeterministic packages (timestamps, parallelism artifacts) with links
      to upstream evidence — an allowlist entry requires justification in the commit.
- [ ] **D.3 Divergence triage protocol.** On mismatch: `diffoscope` the two outputs,
      classify (codegen difference vs embedded metadata vs filesystem ordering vs
      genuine miscompile), and file in `plan/divergence-triage.md`. A codegen-class
      divergence is a **stop-the-line** event — it means the shim is lying to the
      compiler somewhere (math, memory layout, or a syscall result), and everything
      built on top is suspect.

**Exit criteria:** oracle wired into CI; `hello` and the stdenv closure's
reproducible members bit-match official cache paths.

---

## 8. Phase E — Climb the ladder **[ARCH-FREE]**

- [ ] **E.1 Target list.** Generate a dependency-weighted ranking of 26.05
      x86_64-darwin packages (most-depended-upon first). CLI-only; anything touching
      AppKit/WindowServer at *runtime* is out of scope (building GUI apps is fine —
      frameworks are link-time stubs).
- [ ] **E.2 Grind loop.** For each package: build → on failure triage (syscall gap /
      symbol gap / stall / semantic divergence) → fix with regression test → oracle →
      append to matrix. Keep per-package notes only for non-obvious fixes.
- [ ] **E.3 Milestone packages** (each proves a subsystem): `python3` (pip stall
      class), `git`, `cmake`, `openssl`, `ninja`-built things, one large C++ package
      (`llvm` eventually). Stretch, and only after everything above:
      hosting `swiftc` (stresses libdispatch/CF hard — this is the gateway to
      building modern GUI apps later, still link-time only).

**Exit criteria (campaign):** ≥ the full Tier-1..3 matrix green with oracle, on a
frozen 26.05 pin, in CI, reproducibly from a clean prefix.

---

## 9. Phase F — ARM readiness (do continuously, finish last) **[ARCH-PARAM]**

Do **not** start the aarch64 port in this campaign — *prepare* it.

- [ ] **F.1 Salvage assessment.** Diff the three `feature/arm-support*` branches
      against current master; write `plan/arm-salvage.md`: what's reusable (syscall
      entry, thread state, signal frames, TLS), what's rotten, what was never
      finished. No code moves yet.
- [ ] **F.2 Arch-boundary audit.** Inventory every place Campaign-1/2 code assumes
      x86_64 (syscall numbers, `ucontext` layouts, asm, `PAGE_SIZE` conflation).
      Introduce/enforce the arch abstraction now, while refactors are cheap.
      Specifically: audit for host-page-size vs Darwin `vm_page_size` conflation —
      Darwin/arm64 userland assumes **16K pages**; the plan there is to report 16K
      from libSystem regardless of host kernel page size (and to prefer
      `CONFIG_ARM64_16K_PAGES` guest kernels when we get to QEMU).
- [ ] **F.3 Parameterize the harness.** Flake systems, VM tests, matrix, oracle, and
      symbol tooling all take an arch parameter (`x86_64-darwin` today,
      `aarch64-darwin` next). The oracle matters *more* on ARM — that's where
      cache.nixos.org coverage is best and nixpkgs support continues past 2026. Note:
      aarch64-darwin outputs carry ad-hoc code signatures (nixpkgs signs via
      sigtool); the oracle must treat signature bytes correctly, not diff them
      naively.
- [ ] **F.4 ARM dev environment recipe.** Document (don't yet automate) the path:
      `qemu-system-aarch64` with MTCG (`-smp`, `-cpu max`), snapshot after
      boot+install, share `/nix/store` via virtiofs, build aarch64-linux artifacts on
      the x86 host via `boot.binfmt.emulatedSystems` — but never run darlingserver
      itself under qemu-user (signals/TLS fidelity). Real-hardware step-up:
      GitHub arm64 runners / Hetzner CAX / Oracle Ampere / Asahi.

---

## 10. Working agreements

- **Session start:** read this file, `plan/26.05-facts.md`, and the triage docs;
  run `scripts/run-tests.sh` and the smoke check to confirm the baseline is green
  before changing anything.
- **Verification is execution, not inspection.** A task is done when its test runs
  green in a clean prefix (`--keep` only for debugging), not when the code looks
  right.
- **Small commits, phase-tagged, tests included, plan updated.** Same style as
  Campaign 1's history.
- **When blocked** (nixpkgs-side change seems required, licensing question, a
  divergence-class stop-the-line event, or >1 day stuck on one signature): write it
  up in `plan/blockers.md` with reproduction steps and stop that thread; pick up the
  next ranked item. The human reviews blockers.
- **Time-sensitivity note:** 26.05 is supported until end of 2026 and the cache
  should persist beyond that, but mirror the bootstrap-tools closure and key
  reference narinfo/nars into our own Cachix early (cheap insurance for the oracle).

## 11. Risk register (carry-forward from design discussions)

| Risk | Class | Mitigation |
|---|---|---|
| Silent output divergence (shim lies subtly) | correctness | Phase D oracle + stop-the-line protocol |
| Stalls in event-loop-heavy builds (kqueue/poll) | fidelity | C.4 watchdog + stall triage doc |
| macOS-14 symbol surface larger than expected | scope | B.1 demand-driven ordering; stubs only as last resort |
| Mach IPC perf through userspace darlingserver | perf | measure during E; acceptable for CI even if slow |
| Cache retention past 26.05 EOL | infra | mirror reference closures to own Cachix (§10) |
| Apple open-source drops lag/stop | existential | affects future surfaces, not the frozen 26.05 target |
| x86-only effort waste | strategy | ARCH tags; Phase F audit keeps the boundary honest |

---

*Campaign 1 history and background: see `plan/00-background.md` through
`plan/11-architecture.md` and the git log. This document supersedes the old PLAN.md
task list; the Campaign 1 plan is archived at `plan/PLAN-campaign1.md`.*
