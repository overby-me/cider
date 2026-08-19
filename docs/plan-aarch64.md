# aarch64 port plan

Cider today is x86_64 only: the guest is `x86_64-apple-darwin20`, the host tier assumes an
x86_64 Linux, and `flake.nix:26` says `systems = [ "x86_64-linux" ]`. This plan ports both
tiers to aarch64, where the guest becomes `arm64-apple-darwin20` (macOS 11 is the first arm64
macOS, so the darwin20 floor carries over unchanged) and the host is aarch64-linux.

## What "done" means

Two existing checks, run on an aarch64 host, in this order:

1. **`scripts/checks/buck-bash-check.nu` passes.** The buck2-built prefix boots, and the bash
   the port built runs and reports a Darwin build. This is the same milestone the buck2 port
   aimed at, now on arm64.
2. **`scripts/checks/buck-nix-bash-check.nu` passes.** Guest Nix, inside the container, builds
   GNU bash from source and runs the result. On arm64 the guest nix is the aarch64-darwin nix
   from the host store, not the x86_64-darwin one. This is the goal: bash builds under cider
   nix.

Neither check changes its verdict logic; the port's job is to make the same claims true on a
second architecture.

## The machine this is being built on (measured 2026-08-19)

- aarch64, 12 CPUs, 15 GB RAM, kernel 7.1.7, NixOS.
- Page size 4096 (`getconf PAGESIZE`), not 16K. macOS on arm64 uses 16K pages; see D5.
- No compiler outside `nix develop`. github.com is reachable.
- This host CANNOT run the x86_64 runtime checks. Keeping x86_64 green here means eval and
  target-determination stay identical, verified by buck2 cquery/audit, not by booting.

## Reference material: darling PR 1753

[darlinghq/darling#1753](https://github.com/darlinghq/darling/pull/1753) is a working ARM64
port of upstream Darling: bash, sh, perl, python and PAC-signed arm64e Apple binaries run.
It is unmerged and its author's word plus reviewer comments say it will be mined, not merged.
That is exactly how this plan consumes it: as the answer sheet for the arch-specific deltas,
re-derived into this tree's shape (monorepo, buck2, Rust ciderd/mldr).

What it provides, mapped to where the same work lands here:

| PR 1753 area | What it does | Where it lands in cider |
|---|---|---|
| main repo `src/libm/Source/ARM` (72 files) | arm64 libm: clang builtins for single-instruction ops, openlibm/msun for transcendentals | `src/darwin/libm/Source/ARM`, new BUCK sources |
| main repo SDK `usr/include/{arm,arm64,mach/arm,...}` | arm header layout matching Apple's SDK | `src/darwin/Developer/.../MacOSX.sdk/usr/include` |
| main repo `src/startup/mldr` (commpage, low-VA mapping, thread bootstrap) | arm64 commpage at 0xFFFFFC000, VA policy under FAST_DATA_MASK, thread entry ABI | `src/darwin/loader` (Rust mldr) |
| submodule `xnu` @ 12132d9 | BSD syscall ABI, guest syscall entry asm (`bsd_syscall.S` and friends) for arm64 | `vendor/patches/xnu/` |
| submodule `dyld` @ cce174b | low-VA dylib loading, arm64e PAC signing | `vendor/patches/dyld/` |
| submodule `libpthread` @ 70590d8, `libplatform` @ 60b178e, `libc` @ 55f6eb2, `libunwind` @ d940cbb, `objc4` @ a196f59, `libsystem` @ 3668d45, `libmalloc` @ 4f2a808, `libxpc` @ 082de08, `cctools-port` @ 428474b, `darlingserver` @ 0217769, and 19 more | per-component arm64 sources, asm, and flag gates | `vendor/patches/<pin>/` or in-tree, per component |

The full submodule sha table is in the PR diff (fetched once, kept in the scratchpad; re-fetch
with `curl -L https://github.com/darlinghq/darling/pull/1753.diff`). Per-component diffs are
produced by fetching the PR sha and diffing against cider's pinned rev
(`nix/submodules.json`); GitHub serves fork-network commits from the parent repo URL.

What it does NOT provide: cmake plumbing (we have buck2), darlingserver C changes apply only
as a design reference (ciderd is a Rust rewrite), and its mldr is C while ours is Rust.

## Where architecture actually lives in this tree (measured)

The retarget surface is smaller than it looks. `x86_64-apple-darwin20` appears 37 times in
`vendor/src/BUCK` and about 15 times elsewhere (`buck/toolchains/BUCK`,
`buck/rules/{codegen,darwin}.bzl`, `nix/lib/ciderBuck2Graph.nix`, 3 scripts). Everything else
is per-component:

**Guest assembly, the complete .s/.S inventory across committed BUCK files:**

- `xnu` (darling emulation layer): `bsd_syscall.S`, `mach_syscall.S`, `machdep_syscall.S`,
  `linux-syscall.S`, `sig_restorer.S`, `xtrace-hooks.S`. Darling-authored, arm64 versions
  exist in the PR's xnu sha. This is the guest -> Linux syscall path, the single most
  load-bearing piece.
- `libplatform`: `setjmp/x86_64/{setjmp,_setjmp,_sigtramp}.S`, `atomics/x86_64/{OSAtomic,pfz}.S`,
  `cachecontrol/x86_64/cache.S`, `ucontext/x86_64/*.S`. Apple ships arm64 siblings in the
  same tree.
- `csu`: `start.S`, `dyld_glue.S`, `start_glue.S`. arm64 variants upstream.
- `dyld`: `dyldStartup.S`, `dyld_stub_binder.S`, `stub_binding_helper.S`,
  `threadLocalHelpers.S`. arm64 variants upstream plus PR fixes.
- `libunwind`: `UnwindRegistersSave/Restore.S` (already multi-arch source, just needs the
  arm64 defines to be visible).
- `libc`: `x86_64/gen/mcount.S` plus whatever the arm64 source lists pull in.
- `objc4`: blocktramps (arm64 file already exists upstream). Not needed for bash, needed
  later for CF/Foundation.
- `compiler-rt`, `corefoundation`, `bzip2`: flagged by the same scan, examine when reached.

**Host-side Rust with x86_64 baked in:**

- `src/darwin/loader` (mldr): `threads.rs:187-203` (thread-start register ABI, inline asm),
  `jump.rs` (stack switch), `commpage.rs` (cpuid, x86 commpage base 0x7fffffe00000, x86 cap
  bits), `main.rs`/`stack.rs` (check when reached).
- `src/linux/server` (ciderd): `xnu/thread.rs` (1786 lines, thread state get/set is
  x86-shaped), `xnu/host.rs` + `xnu/processor.rs` (CPU_TYPE/CPU_SUBTYPE reporting),
  `rpc_wire.rs` header says "x86_64 layout" (verify: likely arch-independent in practice),
  `bin/ciderd.rs:192` (siginfo layout comment). `xnu/task.rs` is already
  `cfg!(target_arch)`-aware, and the wire enum has `dserver_rpc_architecture_arm64`, so the
  skeleton expects a second arch.
- `vendor/pins/ciderd/xnu-sys` (host C glue): sigcontext/mcontext conversion and whatever
  else `rg -l 'x86_64|REG_' vendor/pins/ciderd` turns up once materialized.

**libm:** in-tree Apple Libm with `Source/Intel` (66 x86_64 files) and `Source/PowerPC`. No
arm64 source exists from Apple; the PR's `Source/ARM` is the fill.

**Toolchain and packaging:**

- `flake.nix:26` `systems = [ "x86_64-linux" ]`.
- `buck/toolchains/BUCK`: `_DARWIN_FLAGS` carries `-target x86_64-apple-darwin20 -arch x86_64`,
  `ld_target = root//vendor/src:x86_64-apple-darwin20-ld`.
- `nix/darwinRust.nix`: pins rustc for one host (`x86_64-unknown-linux-gnu` tarball) and one
  guest std (`x86_64-apple-darwin`). aarch64 needs the `aarch64-unknown-linux-gnu` rustc and
  the `aarch64-apple-darwin` std, both official downloads.
- ld64 is built by the graph itself from the cctools pins (task #65); it must build as an
  aarch64-linux host tool and emit arm64. The PR bumps cctools-port for exactly this.
- SDK: `usr/include` needs the arm/arm64 header dirs the PR adds (about 40 files/symlinks).

**Scripts and checks:** 19 files under `scripts/` mention x86_64. Most are informational; the
ones on the critical path are `buck-setup.nu` (writes `.buckconfig.local`),
`build-pkg-bypass.nu` (fetches x86_64-darwin nix), and the coverage/report tools.

## Decisions

- **D1, target.** Guest triple `arm64-apple-darwin20`, `-arch arm64`,
  `-mmacosx-version-min=11.0`. Same clang, same `-O2` reasoning as x86_64
  (`buck/toolchains/BUCK`).
- **D2, arch selection.** One root config key, `[cider] guest_arch`, read where the triple is
  needed. `scripts/buck-setup.nu` writes it into `.buckconfig.local` from `uname -m`
  (aarch64 -> arm64, x86_64 -> x86_64), overridable by hand. The committed default in
  `buck/toolchains/BUCK` stays `x86_64` so an existing x86_64 checkout is bit-identical
  until its owner reruns setup. Generated BUCK files stay generated: arch-conditional source
  lists go through a small helper (`buck/rules`) keyed off the same config, not through
  hand-edits scattered across 2 MB of generated text.
- **D3, x86_64 stays alive at eval level.** Every change is guarded so
  `guest_arch = x86_64` produces the same graph as today. Verified per milestone with
  `buck2 audit` / target hashing, since this host cannot boot the x86_64 runtime. Runtime
  verification on x86_64 waits for an x86_64 machine; that is accepted and recorded.
- **D4, TSD/TLS on arm64.** Apple userspace reads TSD via TPIDRRO_EL0; Linux does not let
  EL0 set it and the register does not trap, so there is no emulation fallback.
  **RESOLVED 2026-08-19, no kernel mechanism needed.** Probed on this kernel (7.1.7):
  TPIDRRO_EL0 reads as 0 from EL0 on every thread, no fault, and prctl.h (headers 6.18.7)
  offers nothing to set it. The reference PR does not use the register at all: its
  `libsyscall/os/tsd.h` routes `_os_tsd_get_base()` through `sys_thread_get_tsd_base()`, a
  tid-keyed open-addressed hash table in the emulation layer (tls.c, TPIDR_EL0 value as the
  thread identity, single-entry cache in front), because dyld links the static emulation
  layer before TLV support exists. PTR_MUNGE becomes an XOR with a zero token in asm. TSD
  writes go through `sys_thread_set_tsd_base()` exactly as x86_64's arch_prctl(SET_GS) path
  does, so mldr's callback contract is unchanged. Stock-binary exposure (D4c) shrinks to
  binaries that INLINE the TPIDRRO read; nix's closure calls through our libSystem, and the
  PR ran stock PAC-signed Apple arm64e binaries with this scheme.
- **D5, page size.** Host pages are 4K here, macOS arm64 uses 16K. Our own guest tier is
  compiled from source, so milestone 1 runs with 4K throughout (commpage user page shift 12,
  PAGE_SIZE from headers left dynamic where Apple's arm64 headers allow it). Stock
  aarch64-darwin binaries assume vm_page_size at runtime but 16K compile-time constants
  exist in the wild; treat any milestone 2 fault at a 16K boundary as this risk
  materializing, and only then consider reporting 16K in the commpage (legal on a 4K host:
  every 16K-aligned mapping is 4K-aligned).
- **D6, libm.** Import the PR's `Source/ARM` wholesale into `src/darwin/libm/Source/ARM`
  (same layering: clang builtins for the single-instruction ops, msun for the rest), with an
  arch-conditional source list. Provenance noted in the directory, license is GPL3-compatible
  (darling code, openlibm-derived parts MIT).
- **D7, commpage.** arm64 commpage at `_COMM_PAGE64_BASE_ADDRESS = 0x0000000FFFFFC000`, the
  PR's field layout including the timebase fields, CPU caps from `getauxval(AT_HWCAP*)`
  mapped to Apple's kHasNeon-family bits. Keep the never-zero CPU count rule from
  `commpage.rs` (the SIGFPE story).
- **D8, upstream deltas as patches, not pin bumps.** The PR's submodule shas are not on
  darlinghq master and bumping pins to fork-network commits makes provenance a moving
  target. `vendor/patches/<pin>/` + `nix/submodules.json` hashes already exist as the
  mechanism (`nix/lib/cider-src.nix`, `buck-pin-patches-check.nu`). Derive each component's
  patch as `git diff <cider pin rev> <PR sha> -- <paths we build>`, trimmed to what our
  targets compile. In-tree components (libm, SDK, loader, server) are edited directly.
- **D9, order of attack is the bash link line, nothing wider.** bash links libSystem and
  nothing else (buck-bash-check's own comment). So milestone 1 needs exactly: csu, dyld,
  libsystem umbrella + firstpass, libsyscall/emulation (xnu), libplatform, libpthread, libc,
  libm, libmalloc, libdispatch(+libclosure), libcompiler_rt, libunwind + the small members
  already in the umbrella, bash itself, mldr, ciderd, launcher. Frameworks, objc4, CF, the
  GUI tier: explicitly out of scope until after milestone 2.

## Milestones and tasks

Task numbers are local to this plan (A-prefix) to stay clear of the global task sequence.

### M0: the host works at all (aarch64-linux is a buildable platform)

- **A1** `flake.nix` systems gains `aarch64-linux`; `nix develop` produces the toolchain
  shell on this machine. Done means: `clang --version`, `buck2 --version`, `nu --version`
  inside the shell.
- **A2** `scripts/buck-setup.nu` runs green: pins materialize, `.buckconfig.local` written.
  Done means: `buck2 build //src/linux/server:ciderd` (host Rust, no guest code) succeeds.
- **A3** Kernel probes, results recorded in this file: TPIDRRO_EL0 behavior (D4), plus
  anything else D4/D5 need. Done means: the D4 ladder has a measured branch taken.
- **A4** Host tier builds: every `//src/linux/...` target that is not guest-flavored, plus
  the host ld64 (`//vendor/src:...-ld` as an aarch64-linux ELF that can emit arm64; needs
  the PR's cctools-port fixes as patches if the pinned rev cannot). Done means: ld64 links a
  hello-world arm64 Mach-O object into an executable (file(1) says arm64, doesn't need to run).

### M1: the guest toolchain exists (arm64 Mach-O comes out)

- **A5** `[cider] guest_arch` plumbing: toolchains, `darwin.bzl`, `codegen.bzl`, the 37
  triple sites in `vendor/src/BUCK` (via helper, see D2), `buck-setup.nu`. Done means:
  `guest_arch=x86_64` graph is unchanged (target-hash diff empty), `guest_arch=arm64`
  compiles a trivial C file to an arm64 Mach-O object through `darwin_cc`.
- **A6** SDK arm headers: the PR's `usr/include/{arm,arm64,mach/arm,mach/arm64,...}` set,
  plus `basic-headers` arm additions. Done means: `#include <mach/mach.h>` and
  `#include <architecture/byte_order.h>` compile under `-target arm64-apple-darwin20`.
- **A7** Guest Rust: `nix/darwinRust.nix` keyed by host arch, `aarch64-apple-darwin` std.
  Done means: the staticlib probe from #102 reproduces for arm64.

### M2: the bash tier compiles (the D9 list, component by component)

Each component: arch-conditional source list + patches, done means its `_dylib`/archive
target builds for arm64. Suggested order (dependency-ish, syscall layer first since
everything tests against it):

- **A8** xnu: libsyscall + the darling emulation layer, including the six .S files. The
  largest patch, taken from the PR's xnu sha.
- **A9** csu, compiler-rt builtins, libunwind.
- **A10** libplatform (setjmp, atomics, cachecontrol, ucontext, string).
- **A11** libpthread (+ the D4 TSD decision applied).
- **A12** libc, Libinfo, libmalloc, libclosure, libdispatch, the remaining small umbrella
  members (libnotify, copyfile, removefile, libresolv, ...).
- **A13** libm ARM import (D6).
- **A14** dyld (PR patches: low-VA policy, arm64 program start).
- **A15** libsystem umbrella + firstpass two-pass link produce `libSystem.B.dylib` for arm64.
- **A16** bash. Done means: `file` on the output says Mach-O arm64 executable, and
  `//buck/prefix:cider_prefix` assembles end to end with guest_arch=arm64.

### M3: it boots (buck-bash-check passes on this machine)

- **A17** mldr (Rust loader): arm64 thread-start ABI in `threads.rs`, `jump.rs` stack
  switch, D7 commpage, `main.rs`/`stack.rs`/`elfcalls.rs` sweep, VA policy from the PR
  (mappings under 2^47 hold on arm64 Linux only if asked; the PR's slot-retry logic).
- **A18** ciderd: ARM_THREAD_STATE64 in `xnu/thread.rs` (get/set/exception paths),
  CPU_TYPE_ARM64 in host/processor reporting, siginfo/sigcontext handling on aarch64,
  `xnu-sys` host glue patches.
- **A19** The boot grind: `cider shell /bin/bash -c 'echo ...'` until
  `scripts/checks/buck-bash-check.nu` says PASS. Expect the classic parade (TSD, sigexc,
  commpage fields, dyld rebase) and log each fix in docs/changelog.md as usual.

### M4: the goal (buck-nix-bash-check passes)

- **A20** aarch64-darwin nix in the host store (`build-pkg-bypass.nu` grows the arch switch),
  the writable-/nix overlay path re-checked on this host.
- **A21** Whatever the toolchain-under-emulation shakes out (this is where stock binaries
  meet D4(c) and D5). Done means: `scripts/checks/buck-nix-bash-check.nu` prints
  `PASS: guest nix built and ran bash inside the buck2-built Darling` on this machine.

### M5: aftercare (not gating the goal)

- **A22** The Nix endpoint (`cider-buck2-prefix` and friends) evaluates and builds on
  aarch64-linux; NixOS module works on this host; README status table gains the arch column;
  x86_64 eval-parity check wired into `buck-test.nu` or a sibling.

## Bring-up log (what M0 measured, 2026-08-19)

- `nix develop` on aarch64-linux needed only the systems list and six `platforms` stamps;
  the whole toolchain came from cache.nixos.org.
- The dispatch-header disease has one shape and three homes: xnu (69 headers, patch 0019),
  the duct-tape xnu (135 headers, xnu-sys-xnu patch 0003), cctools-port foreign/ (26
  headers, patch 0002). All of them test `__arm64__`, which only Apple-target compilers
  define; a host aarch64 clang says `__aarch64__`. Guest compiles define both, so the
  patches are invisible on x86_64 and on the guest side.
- The duct-tape kernel configures for arm64 with darling PR 1753's darlingserver set,
  verbatim: `__arm64__ APPLE_ARM64_ARCH_FAMILY VMAPPLE ARM64_BOARD_CONFIG_VMAPPLE
  __ARM_VMSA__=8 __ARM64_PMAP_SUBPAGE_L1__` (buck/generated/xnu_sys_flags.bzl, host-arch
  keyed), plus its duct-tape header shims (xnu-sys-xnu patch 0004, include names rebased to
  ciderd/xnu-sys) and its rtclock_arm64.c (CNTVCT instead of TSC).
- Built green on this machine: `//vendor/pins/ciderd/xnu-sys:ciderd_xnu_sys` (the whole
  duct-tape kernel as an aarch64 ELF archive), `//vendor/src:migcom`, and
  `//vendor/src:x86_64-apple-darwin20-ld` (ld64 as an aarch64-linux host binary; arm64
  output not yet exercised, that is A5's smoke test).
- `//src/linux/server:ciderd` still does not build: wrapper.h exports the x86
  MachineStateCount table as enum constants and xnu/thread.rs is x86-shaped. That is the
  A18 state port, pulled forward to the front of the queue since M0 cannot finish without
  a compiling daemon. The reference is darlingserver 0217769's duct-tape/src/thread.c
  (+150 lines) and misc.c (+81), against ciderd's Rust twins.

## M2 progress (the guest bash tier, in flight)

Order the build surfaces the gaps, component by component. Landed so far:

- **Guest toolchain smoke test (A5 done):** `darwin_cc` with `guest_arch=arm64` emits a real
  arm64 Mach-O object (verified with `file` + `llvm-objdump --macho`).
- **bash (A16, partial):** conftypes.h gains an arm64 HOSTTYPE case (patch), since cider does
  not set CONF_HOSTTYPE and the source has no arm64 branch.
- **libm headers (A13, partial):** the in-tree dispatch headers `include/{fenv,math}.h` accept
  arm64 and `sdk_src_libm_headers` stages the arm targets. The **implementation** is not done:
  the libm target still compiles `Source/Intel/*.c` (SSE, `xmm_misc.c` fails on arm64). A13's
  real body is importing darling PR 1753's `Source/ARM` (72 files) and making the libm source
  list arch-conditional. **This is the current M2 blocker.**
- **libmalloc (A12 done):** the nanozone address-field widths guard now accepts arm64 (same
  widths as x86_64, per the PR); patch.

**Update, second M2 pass — landed:**

- **libm ARM Source (A13 done):** the ~100-file `Source/ARM` list imported and the libm BUCK
  made arch-conditional; all libm object targets and the static archive build for arm64.
- **libplatform machine layer (A10 done):** the pin's arm64 asm (5 files) selected per arch.
- **dyld (A14, partial):** the C++ objects build; a patch skips the FairPlay `mremap_encrypted`
  block under Darling (it only compiled on the arm arches). The .S startup and PAC pieces are
  still ahead.
- **The x86-flag filter (A4):** one filter in `compile_objects` drops `-msse*`/`-Dmovsxw` for
  an arm64 guest, clearing the ~30 generated sites (libunwind, xnu×23, libm, ...) at once.
- **libc noinode64 (A12, partial):** the eight 32-bit-inode compat object groups compile
  nothing on arm64 (arm64 has no such ABI; the define is a hard `#error` there).
- **objc4 arm mach headers (A12, partial):** `mach/arm/{thread_status,thread_state,_structs}.h`
  repointed from cctools to xnu to match the i386 mapping, so `arm_thread_state64_get_pc`
  resolves.

**Discovery:** bash links `//vendor/src:system_final` (the libSystem umbrella), and the check
builds `//buck/prefix:cider_prefix`, so M2/M3 pull the **whole guest tier** including objc4,
not just the minimal bash link the plan's D9 assumed. objc4 is therefore on the critical path.

**Update, third M2 pass — landed:**

- **objc4 isa (A12 done):** a DARLING/macOS arm64 branch in isa.h (x86_64 layout, 44-bit
  shiftcls) matches cider's arm64 MACH_VM_MAX_ADDRESS; patch.
- **libc arch asm + legacy groups (A12 done):** libc-x86_64 builds empty.c on arm64 (no arm
  mcount), and the eleven `*_legacy`/`*_pre1050` symbol-version groups compile nothing there
  (the $UNIX2003/$1050 variants are i386-only; they duplicated `_daemon`/etc at link).
- **The x86-flag filter (A4 done):** clears the ~30 `-msse` sites at once.
- **libm/libc dylib links:** libm firstpass links once `fma_freeBSD.c` is dropped (fma comes
  from arm64_builtins.c); libc firstpass links once the legacy groups are empty.
- **Guest syscall asm (A8, patch 0020):** the six darling-authored trampolines
  (bsd/mach/machdep syscall, linux-syscall thunk, sig_restorer, xtrace-hooks) gain arm64
  blocks.
- **Guest emulation conversions (A8/D4, patch 0021):** the arch-guarded half of the PR's
  emulation delta — the tid-keyed TSD table (tls.c, the D4 mechanism), sigexc.c, the arm64
  Linux stat layout, sigaction, the base.h fast-syscall gate, the open.h flag values. Every
  hunk `__aarch64__`-guarded; x86 byte-identical. The PR's new-syscall/behavioral changes are
  excluded (they alter the frozen x86 build and add un-globbed files).

**Update, fourth M2 pass — the xnu guest kernel builds and links (A8 done):**

- **open → openat (patch 0022):** arm64 dropped the `open` syscall, so `execve.c`,
  `vchroot_userspace.c`, `file_handle.c`, `dserver-rpc-defs.c` call `openat(AT_FDCWD, …)`.
- **sysctl_machdep (patch 0023):** the x86 cpuid asm is wrapped in `#else`; arm64 gets stub
  cpu tables.
- **bsdthread_register (patch 0024):** the pthread/workqueue thread-start trampolines gain
  their arm64 arms (args in x0-x5, a `br` to the entry), hand-merged against cider's
  workqueue patch 0010.
- **The asm label collision (patch 0020 fix):** `.std_ret`/`.no_sys` were `.`-prefixed, which
  is not a Mach-O local-label convention, so they went global and collided between
  bsd_syscall.S and mach_syscall.S; renamed to `Lstd_ret`/`Lno_sys`.
- **select-pre1050 (BUCK):** the pre-10.5 select/pselect variant emits a plain
  `_select`/`_pselect` on arm64 (no `$UNIX2003` versioning) that duplicated the modern
  wrapper; `libsyscall_obj5` is empty on arm64.

`//vendor/src/xnu:system_kernel_final` — the guest libsystem_kernel dylib — now links for
arm64. That is the largest single component of the port.

**Update, fifth M2 pass — bash links as an arm64 Mach-O (A11, A15, A16 essentially done):**

- **libpthread (A11):** `_getsectiondata` (from the arm64-only JIT-write-protect path) resolved
  by adding libmacho as an arm64-only sibling of the pthread final link.
- **libxpc type aliases (A15):** `_CREATE_ALIAS`'s `.equiv` form does not emit the alias on
  arm64 Mach-O, so every `_xpc_type_*` was undefined; the PR's `.set` form fixes it (patch,
  libxpc 0003).
- **libkern arm OSByteOrder (A15):** the arm header gated the plain `OSReadSwapInt*` names
  behind `_POSIX_C_SOURCE`, but the `OSSwap*` macros call the plain names; the PR drops the
  underscore variants and keeps the plain ones (patch, xnu 0025).
- **`//vendor/src:bash` BUILD SUCCEEDED.** `file` reports *Mach-O 64-bit arm64 executable,
  NOUNDEFS|DYLDLINK|TWOLEVEL|PIE* — fully linked, no undefined symbols. The libSystem umbrella
  and every dependency it pulls now build and link for arm64.

**Current blocker (M3 prefix assembly, and it is build-infra not arch):** `buck2 build
//buck/prefix:cider_prefix` fails at `vendor/src/security/darling/include/Security/CSCommon.h`
— an "invalid symlink … path contains platform-specific path separator", a `.`-component
symlink (`../.././../OSX/…`) that buck2 rejects and `cider-src-normalise` is meant to repoint.
This is orthogonal to the arch port (it would bite an x86 direct-buck2 prefix build the same
way); the fix is in the src-normalise path, not in any arm64 code. Once the prefix assembles,
`scripts/checks/buck-bash-check.nu` can boot it (M3), followed by the guest-nix goal (M4).

## Risks, ranked

1. **TPIDRRO_EL0 for stock binaries (D4c).** No kernel mechanism and an inlined read in the
   nix closure would force ugly choices (binary patching, a kernel module, or building the
   closure from source with our headers). Probed early (A3) precisely because it is the one
   item that could reshape M4.
2. **ld64 as an aarch64-linux host binary.** cctools-port on non-x86 Linux hosts is less
   traveled; the PR bump helps but this is the first tool the whole guest tier stands on.
   Probed in A4, before any mass porting.
3. **Page size (D5).** Contained for M3, real for M4. The mitigation (report 16K on a 4K
   host) is legal but changes commpage and vm_page_size reporting; do not pay it before a
   fault demands it.
4. **rpc_wire.rs "x86_64 layout".** If the RPC wire format actually bakes in x86_64 struct
   layout anywhere, ciderd and every guest stub disagree on arm64. Audit is part of A18,
   early enough to re-generate if true.
5. **Drift between the PR's submodule revs and cider's pins.** Patches may not apply clean;
   each component budget includes re-deriving the diff against our rev rather than forcing
   theirs in.

## Standing rules for this port

- Follow the buck2-first loop: iterate with `buck2 build` on single targets, run the checks,
  touch nix only at milestone edges (README: "Nix is the packaging, not the build").
- Every landed increment keeps `guest_arch=x86_64` eval-identical (D3) and gets a
  docs/changelog.md entry when it taught something.
- Commit with jj as work lands; never leave finished work uncommitted.
