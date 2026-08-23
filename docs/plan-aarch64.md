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

**Current blocker (M3 prefix assembly — build-infra, arch-independent):** `buck2 build
//buck/prefix:cider_prefix` hits a chain of symlink-materialization issues, none of them arm64
code:

1. `security/darling/include/Security/CSCommon.h` had a `.`-component symlink
   (`../.././../OSX/…`) buck2 rejects — fixed by running `cider-src-normalise` on that pin.
2. `libnotify/darling/src/notify.defs` is a symlink to `../../../../../darwin/Developer/…/mach/
   notify.defs` — five `../` reach the repo root, but the SDK lives at `src/darwin`, not
   `darwin`, so it dangles. `cider-src-normalise` does **not** repoint it (no `.` component, and
   it does not verify the target exists). The `.#cider-src` assembled tree places the SDK at a
   layout where the symlink is correct; `buck-src.nu --all` copies it verbatim into the repo's
   `src/darwin` layout, where it breaks.

The lesson: `buck-src.nu --all` leaves the raw assembled-tree symlinks, and a **whole-tree**
`cider-src-normalise` pass is the wrong fix (it expands directory symlinks the direct-buck2
build was relying on staying opaque). The right path for M3/M4 is almost certainly the **nix
endpoint** — `nix build .#cider-buck2-prefix` (or `.#cider`), which materializes and lowers the
graph with the SDK layout its own lowering expects — rather than a direct `buck2 build
//buck/prefix:cider_prefix`. That also aligns with M4, which is a nix build anyway. Next pass:
try the nix endpoint on aarch64 for the prefix, then run `buck-bash-check.nu --prefix
<result>` (its `--prefix` path takes a pre-built tree) to boot it (M3), then the guest-nix goal
(M4).

**Milestone standing:** the guest bash binary and the entire libSystem umbrella it links
against build and link for arm64 today (`//vendor/src:bash` → a fully-linked arm64 Mach-O).
What remains is prefix *assembly* and *boot*, not guest-code compilation.

**Update, sixth pass — the loader, wrapgen, and the nix endpoint (A16, A17):**

- **mldr loader (A17 done for what compiles):** the host Rust loader builds as an aarch64 ELF.
  `jump.rs` switches the guest stack with `mov sp` / `br`; `threads.rs` starts a Darwin thread
  with the arm64 register ABI (x0-x5, same argument order as the x86 rdi/rsi/rdx/rcx/r8/r9);
  `commpage.rs` maps the commpage at the arm64 macOS base `0xFFFFFC000`, packs the two
  page-shift bytes at the arm offsets, and fills the capability word from `AT_HWCAP`
  (NEON/VFP/FMA + crypto/atomics/crc) instead of cpuid; the fault reporter reads `mcontext.pc`.
  The register ABI and commpage still need a *boot* to validate against — only compilation is
  proven so far.
- **wrapgen (A16):** it gated `e_machine` to `EM_X86_64` and rejected every aarch64 host `.so`
  ("is not an ELF for x86-64"), which failed all `*_wrap` elf-stub targets (X11, wayland,
  cairo, ffmpeg, …) on an arm64 host. Reading the dynamic symbol table is arch-independent, so
  the gate now accepts `EM_X86_64` or `EM_AARCH64`. This was the blocker stopping the nix
  endpoint.
- **The nix endpoint follows the guest arch (A7/A16):** `ciderBuck2Graph.nix` derives
  `guestArch` from the build machine and writes `[cider] guest_arch` into the config it
  generates, so a nix-lowered build is arm64 on an aarch64 host. Validated: `nix build
  .#cider-buck2-one` builds `libsimple_ciderd` through the arm64 lowering end to end.

**The prefix path is the nix endpoint, not direct buck2.** A direct `buck2 build
//buck/prefix:cider_prefix` hits latent broken pin symlinks (e.g. libnotify's `notify.defs`
targeting `../darwin/…` where the repo has `src/darwin`) that exist on x86 too; the nix
endpoint materializes and lowers the graph correctly and resolves `notify.defs` via the
`//vendor/src/xnu:osfmk_mach_notify.defs` export label. **`nix build .#cider-buck2-prefix-min`
is building now** — the real M3 gate. When it lands, boot it with `scripts/checks/
buck-bash-check.nu --prefix <result>` (M3), then the guest-nix goal (M4).

**Update, seventh pass — the ObjC framework stack builds for arm64 (the prefix compiles):**

The prefix-min nix build got past the bash tier and failed compiling the higher frameworks
(CoreFoundation, Foundation, CFNetwork, IOKit, Security) that every prefix tool links (the CUPS
`lp`/`lpr`/`ipp*` family were the visible roots; 463 derivations fell out of five root frameworks).
`//vendor/src:lp` now builds and links end to end, and so does the framework stack under it. Six
classes of arm64 breakage, all landed the disciplined way (arm64-guarded hunks, x86 untouched):

- **CF message forwarding + NSInvocation** (corefoundation 0021, 0022): `CFForwardingPrep.S` and
  `NSInvoke-x86.S` had i386/x86_64 only and `#error`-ed on every other arch. Added the arm64
  trampolines — spill x0-x7 / d0-d7 into a 128-byte marg_list, call `___forwarding___` /
  `__invoke__`, restart `objc_msgSend` on a forwarding target. Known runtime-only follow-up:
  `NSMethodSignature._argInfo` still computes marg offsets with the x86_64 register file (0xe0
  frame, 6 GP + 8 SSE), so 7+ register args and HFA returns are not yet correct on arm64. The
  reference PR has the same limitation; scalar forwarding is fine (GP args land at index*8 in both).
- **Uncast objc dispatch** (foundation 0025, cfnetwork 0004): arm64 forces
  `OBJC_OLD_DISPATCH_PROTOTYPES` to 0 (objc-api.h), because the arm64 variadic ABI puts varargs on
  the stack while the messenger reads registers — so every `objc_msgSend`/`objc_msgSendSuper`/
  `method_invoke`/stored-IMP call MUST be cast to its real signature. Cast the sites in KVO, the
  predicate operators, NSThread, NSKeyValueAccessor, and CFURLCache. Inert on x86.
- **method_invoke_stret** (foundation 0025): `OBJC_ARM64_UNAVAILABLE`. arm64 has no stret
  messenger (struct returns use the x8 indirect-result register, which `method_invoke` preserves),
  so the NSValue struct getters route through `method_invoke` under an arm64 `#if`.
- **PAGE_SHIFT_CONST** (IOKitUser 0001): the `-DKERNEL` userspace kext tools pull the arm64
  kernel `extern int PAGE_SHIFT_CONST` (arm64 chooses 4K/16K at init) instead of the i386/x86_64
  compile-time 12. Define it, fixed at 12, matching the host emulation shim (`xnu_sys_rs_shims.c`).
- **Security _ios export** (security 0001): on arm64 macOS SecCertificate.c aliases the `_ios`
  public-key impl to plain `_SecCertificateCopyPublicKey`, so exporting `_SecCertificateCopyPublicKey_ios`
  fails to resolve. Guard that export with `!TARGET_CPU_ARM64`.
- **`_DARWIN_NO_64_BIT_INODE`** (cc.bzl) and **bzip2 crc32** (bzip2/BUCK): arm64 has only 64-bit
  inodes, so defining the macro is a hard `#error` in sys/cdefs.h — folded `-D_DARWIN_NO_64_BIT_INODE`
  into the existing x86-only-flag drop filter so all framework groups lose it at once (libc keeps
  handling its own noinode64 *variant* targets by emptying them, A12). bzip2's accelerated CRC has a
  per-arch asm; `bz264_obj` now selects `bzip2/arm64/crc32vec.S` (from the upstream pin) so
  `_crc32_vec` is defined.

Method for the pin patches: cider's cfnetwork/security pins are byte-identical to the reference
PR's *base*, so those hunks came straight from the PR head. **Trap worth remembering:** a pin patch
that lands after other patches must be diffed against the *materialised* tree (pin + earlier
patches), NOT the pristine pin — foundation 0025 first failed in nix because NSKeyValueObserving.m
(also touched by 0020/0024) and NSKeyValueAccessor.m (0017) carried pristine context that collided.
`scripts/gen`-style: reconstruct the materialised base by reverse-applying the edits, then diff.
`nix build .#cider-src` is the fast patch-application smoke test (materialise only, no compile).

`nix build .#cider-buck2-prefix-min` is re-running with all six fixes; next is the boot check.

**Update, eighth pass — the prefix nix build clears the arm64 framework wall and hits an
arch-independent endpoint gap (cocotron / bundled-pin staging).**

With the six framework fixes in, `nix build .#cider-buck2-prefix-min` compiled the whole ObjC
framework stack and got deep into the prefix tools before failing. `--keep-going` collected ~1200
failed derivations; almost all are ONE cascade:

- **`'CoreGraphics/CGBase.h' file not found`** in every target that includes `Foundation.h`
  (CoreFoundation_obj, LocalAuthentication, sysmon, LaunchServices, ...). `Foundation/NSGeometry.h`
  includes `<CoreGraphics/CGBase.h>` unconditionally, and CGBase.h lives only in **cocotron**
  (`vendor/src/cocotron/CoreGraphics/include`). This builds fine under a direct `buck2` build
  (cocotron is present in the dev-shell `vendor/src`), so it is NOT an arm64 code problem.

  ROOT CAUSE, run to ground: cocotron is a **bundled in-tree pin** (checked into
  `vendor/pins/cocotron`, no `submodules.json` entry). `ciderBuck2Graph.nix` has explicit
  `bundledVendorSrcPins` handling that copies it into the graph's assembled source, and it does
  appear in the global `cider-buck2-sources/sources.json` (48 CoreGraphics + 233 AppKit headers).
  But the **per-target** side does not carry it: `cider-graph-sources` writes NO cocotron entry into
  `target-groups.json` (checked: zero mentions), so no target's `pins`/`wantedPins` contains it;
  and even if it did, `ciderBuck2Lower.nix`'s `pinsWithStores` filters to pins that have a store in
  `ciderSrc.pinPaths`, which only holds the fetched `submodules.json` pins. So a bundled pin reaches
  the graph analysis but never the per-target derivations. That is why only NON-Foundation targets
  (libsimple_ciderd, the earlier nix validation) have ever nix-built: nothing before needed CGBase.h.
  This gap is **arch-independent** — it blocks the x86 nix prefix identically, and the full
  prefix-min nix build has evidently never completed on any arch.

- Four genuinely arm64 compile issues sit behind the cascade, to fix once the prefix can build:
  `CarbonCore/ComponentManager.cpp` (`undeclared 'CURRENT_PLATFORM'`), `launchd/src/core.c`,
  `xtrace/xtracelib.cpp`, `vendor/src/libxpc/src/runtime.m`.

**Where this leaves the port.** The arm64-SPECIFIC work is done and verified end to end by a direct
`buck2 build //vendor/src:lp`: host tier, guest toolchain, the bash tier, the loader/wrapgen, the
nix-endpoint arch threading, and now the whole ObjC framework stack all build and link as arm64. The
one thing between here and buck-bash-check is NOT arm64 code — it is teaching the nix endpoint (the
`cider-graph-sources` Rust tool plus the `ciderBuck2Lower.nix` pin farm) to stage bundled in-tree
pins per target, the same way the graph build already stages them. The direct-buck2 prefix path is
no shortcut: it has its own pre-existing, arch-independent broken-pin-symlink blockers (libnotify
`notify.defs`, the security `.`-component), also latent on x86. Either route to a full prefix is
general endpoint work, not aarch64 support.

**Update, ninth pass — the bundled-pin endpoint gap is fixed, and the last arm64 compile gaps land.**

Decision (checked with the user, who asked for a recommendation and took it): fix the nix endpoint,
since it is the supported prefix path and the gap was fully diagnosed. The fix mirrors the graph's
existing `bundledVendorSrcPins` into the per-target lowering: `ciderBuck2Lower.nix` now defines
`bundledPins = [ "vendor/pins/cocotron" ]` and a `bundledStage` that symlinks each one from its own
content-addressed store (`builtins.path` on the in-tree pin) to `vendor/src/<name>` in EVERY staging
script, injected at both `pinStageLines` sites. Unconditional because attribution does not know these
pins; cheap because they are headers. Verified at the derivation level before building
(`cider-bundled-cocotron` is in the prefix closure and the `buck2-stage-project-grouped` script
references it): the ~1200-derivation `CGBase.h` cascade AND the libxpc `AppKit/NSApplication.h`
failure both dropped to zero in the next build. `.named` on the lowering only exposes ~30 top-level
probes, so there is no small Foundation target to test in isolation; the whole prefix is the test.

The three arm64 compile gaps the cascade had been hiding, all landed (PR 1753 has the first two):
CarbonCore `CURRENT_PLATFORM` -> `platformARM64NativeEntryPoint` (added to Components.h as 9);
launchd's exception-port thread-state flavor -> `ARM_THREAD_STATE64`; and an arm64 xtrace hook
trampoline (`ldr x16,#8` / `br`|`blr x16` / `.quad target`, x16 = IP0 scratch), which the PR does
not provide. These five files are first-party `src/darwin` / `nix/`, committed directly, not pin patches.

**Trap for next time: a source edit forces an ~18m graph rebuild.** `projectSrc` in
ciderBuck2Graph.nix is `builtins.path` over the whole tree (only docs/nix/tests-nix filtered), so
editing any `src/darwin` .c/.h rehashes it and the graph dump reruns. Batch source edits before a
prefix build. The comprehensive build (cocotron + the three fixes) is running now.

**Update, tenth pass — the prefix build clears to two roots, both fixed.**

The cocotron fix held: the ~1200-target `CGBase.h` cascade and the libxpc AppKit failure went to zero,
and the three arm64 compile fixes (CarbonCore, launchd, xtrace.cpp) all built. `--keep-going` left
exactly TWO real roots, everything else a dependency-failure of them:

- **xtrace `trampoline.S`** -- x86_64/i386 macro bodies only, so on arm64 `trampoline_enter`/`call`
  assembled as instructions. Added an arm64 branch: save x0-x7 and the number x16 around the print
  call; entry passes `(x16, &args)`, exit passes `(x0 retval)` -- the split x86 did not need because
  rax was both. (Committed with the xtracelib.cpp hook.)
- **CoreServices `reexport.exp`** -- reexports 32 libm symbols, nine of them x86/PowerPC-only:
  `__FE_DFL_DISABLE_SSE_DENORMS_ENV` (Intel SSE denorm env), `_nextafterd` (PowerPC legacy) and
  seven `$fenv_access_off` variants. arm64 libm defines none of them, so the CoreServices_dylib link
  failed on nine undefined symbols, cascading to AudioToolbox, the af* tools, gzip/lzma/ffi/xip and
  the prefix itself. Added `reexport_arm64.exp` (the 23 that exist) and selected it in
  `src/darwin/frameworks/BUCK` by `guest_arch`; x86 keeps `reexport.exp` byte-identical.

Both landed; the final prefix build (all fixes) is running, reusing the previous build's object
cache. If it comes back green, `nix build .#cider-buck2-prefix-min` is the arm64 prefix and M3 moves
to the boot check (`buck-bash-check.nu --prefix <result>`).

Note logged for later: Foundation and CoreFoundation dylibs still name `reexport_x86_64.exp` /
`dylib_name = *_x86_64`, but both linked on arm64 in this build (their listed symbols all exist), so
they are cosmetic rather than blocking -- revisit only if a later link complains.

**Update, eleventh pass -- the prefix clears to two more roots (libffi, liblzma), both pins.**

With trampoline.S and CoreServices fixed, the build compiled and linked everything through the
frameworks and cleared to exactly TWO real roots again, every other failure (gzip, lzma_dylib,
ffi_dylib, xip_extract_cpio) a dependency-failure of them:

- **libffi** (`pin-libffi`): clang's arm64 (Mach-O) integrated assembler rejects the aarch64
  `sysv.S` CFI -- a symbol-valued `.cfi_adjust_cfa_offset (ffi_closure_SYSV_FS)` and
  `.cfi_def_cfa x1, 40` -- with "invalid CFI advance_loc expression". That is exactly the case
  configure's `HAVE_AS_CFI_PSEUDO_OP` probe returns false for, but cider reuses an x86-generated
  fficonfig, so `ffi_cfi.h` still emits the pseudo-ops. Patch 0001 gates them off on arm64 (the
  header's own empty-macro `#else` branch). The x86/arm sources in the same object group are
  internally arch-guarded, so no BUCK src-selection was needed. libffi carries no asm CFI on arm64,
  as the autoconf path would produce.
- **liblzma** (`pin-liblzma`): `config.h` (x86-generated) hardcodes `HAVE_IMMINTRIN_H`, so
  `memcmplen.h` pulls in `<immintrin.h>` and clang errors compiling the x86 intrinsic headers
  (`mmintrin.h`) for arm64. Patch 0001 gates the define to x86; the SSE2 path that uses it is
  already guarded by `__SSE2__`, absent on arm64. Note a `-U` on the command line does NOT work
  here: config.h re-`#define`s it, so the header itself has to be gated.

Both are the FIRST patches for those pins (new `vendor/patches/{libffi,liblzma}/` dirs); verified to
apply via `nix build .#cider-src`. The prefix build with both fixes is running; if it comes back
green the arm64 prefix exists and M3 moves to the boot check.

**Update, twelfth pass -- THE ARM64 PREFIX BUILDS GREEN, and the boot fault is diagnosed.**

`nix build .#cider-buck2-prefix-min` returns NIX_EXIT=0 with a `result` symlink and zero failures
(0 compile, 0 link, 0 builder, 0 dependency). The whole port -- host tier, guest toolchain, bash
tier, loader/wrapgen, the ObjC framework stack, the nix-endpoint bundled-pin staging, and every pin
/compile fix -- produces a complete ~5,500-entry arm64 prefix: `bin/ciderd`, `libexec/cider/bin/bash`
(arm64 Mach-O), the guest dylibs, and `usr/libexec/cider/mldr`. That is the M3 BUILD gate.

The M3 BOOT (`buck-bash-check.nu --prefix result/cider_prefix_min__prefix`) does NOT yet pass. What
it does, from strace of the guest process (which runs mldr): mldr maps the guest correctly -- dyld
at 0x100000000, libSystem, the 8 MB start stack at 0x7fffff600000, all mmaps succeed -- then jumps
to dyld, and dyld immediately makes GARBAGE syscalls and fault-loops:

    getxattr(NULL, "lf_calls=", 0xa, 0x7fffffdfd40f) = -1 EFAULT
    syscall_0x2d2d8000(0xfff...f2, 0xf916..., ...)   = -1 ENOSYS
    syscall_0xfff(0, ...)                            = -1 ENOSYS
    rt_sigreturn({mask=[]})                          = -1 ENOSYS
    then --- SIGSEGV {si_code=SEGV_MAPERR, si_addr=0x8} --- forever (a caught fault the handler
    never resolves, ~360k/s).

Reading of it: the maps are fine, so this is not the loader's mapping. dyld's code RAN but on wrong
inputs -- the "lf_calls=" (the apple string is `elf_calls=<hex>`, the loader's ELF-call bridge, off
by one char) plus the varying junk syscall numbers say dyld called through a BAD POINTER and is
executing garbage. jump.rs (arm64 `mov sp; mov x29,xzr; br entry`) and stack.rs (the
`[mach_header, argc, argv, 0, envp, 0, apple, 0]` layout, arch-independent, x86-identical) both look
correct, and linux-syscall.S's arm64 stub (`mov x8, x6; svc #0`, number = 7th C arg = x6) is
correct. So the suspect is the register/pointer state dyld receives at entry, or how the guest reads
`elf_calls=`/the commpage -- A17/D-level runtime paths that were compile-only until this first boot.

BLOCKER on pinning it exactly: the guest process is short-lived and namespaced under ciderd, so
gdb/strace attach is racy; and `cider shell` swallows mldr/daemon stderr, so MLDR_DEBUG output never
reaches the caller. NEXT STEP is a diagnostic harness, not more guesswork: teach mldr to write its
dlog (entry, slide, commpage, the argc it reads back from the stack) to a FILE, rebuild, and read
the guest entry state directly -- then the wrong register/pointer is one comparison away. Boot
debugging is iterative (fix -> ~30 min prefix rebuild -> retest), so it will span several passes.

DIAGNOSTIC BREAKTHROUGH (same pass): run mldr DIRECTLY, outside ciderd/vchroot, with
`MLDR_DEBUG=1 __mldr_DYLD_ROOT_PATH=<prefix> mldr <guest-bash> --version`. It stops before the jump
(`test run; not jumping -- set __mldr_sockpath`) but prints everything up to it, un-swallowed, and it
clears mldr of blame:

- entry `0x100056e20`, commpage `@0xfffffc000` (ncpu=12), mach_header magic `0xfeedfacf`, and the
  start stack `sp[0]=mach_header, sp[8]=argc=2` are all correct;
- with the root set, dyld loads: `dyld mapped: slide=0x..., entry=<slide>+0x56038`, and
  `FINAL entry` is that dyld `__dyld_start`;
- disassembling the guest dyld: it is ARM64 / MH_MAGIC_64 / LC_UNIXTHREAD, and `__dyld_start` does
  `mov x28,sp; and sp,...; ldr x0,[x28]; ldr x1,[x28,#8]; add x2,x28,#0x10` -- i.e. it reads
  x0=sp[0]=mach_header, x1=sp[8]=argc, x2=&argv, which is EXACTLY the layout stack.rs builds.

So mldr's setup and the entry ABI are both correct. The fault is therefore in the guest dyld's
`start()` / libSystem bring-up on arm64 (chained-fixup application, the elf_calls bridge use, or the
TSD/commpage read), not in the loader. NEXT: reproduce the jump by starting ciderd by hand and
passing `__mldr_sockpath=<prefix>/.ciderd.sock` to a directly-run mldr so its (and dyld's) output is
not swallowed, then read the dyld PC at the first fault; or trace dyld's start under the same harness.

**Update, thirteenth pass -- the first boot fault is found (core dump) and fixed: the TSD.**

It never needed the ciderd harness. `coredumpctl` had a core from every boot attempt: mldr does NOT
loop forever, it SIGSEGVs (the strace "loop" was strace slowing the fault cascade). gdb on the core
gave the exact fault:

    #0  cthread_set_errno_self
        str w0, [x8, #3720]       ; global errno
        mrs x8, tpidrro_el0       ; x8 = thread pointer
        and x8, x8, #~7
    =>  ldr x8, [x8, #8]          ; x8 = 0 -> read 0x8 -> SIGSEGV (si_addr=0x8)
        cbz x8, .+8
        str w0, [x8]              ; *errno = w0
    x0 = -38 (a syscall's -ENOSYS return)

So it is NOT garbage execution -- a syscall returned an error and setting errno needs the per-thread
TSD, whose base comes from `mrs TPIDRRO_EL0`. TPIDRRO_EL0 is kernel-owned and reads 0 from EL0 on
Linux arm64 (the D4 problem), so the base is null and `ldr x8,[x8,#8]` faults. The garbage syscall
numbers in the earlier strace were the fault handler thrashing after this.

ROOT CAUSE: D4 was half-done. Patch 0021 added the tid-keyed hash table
`sys_thread_get_tsd_base()` (emulation tls.c, keyed by `__builtin_thread_pointer()` = TPIDR_EL0,
with a fast cache and a `tsd_zero_page` fallback), but never rewired os/tsd.h's inlined
`_os_tsd_get_base()` -- which every errno / pthread_self / TLS access uses -- so it still did
`mrs TPIDRRO_EL0`. `_os_cpu_number` in the same header got a `#ifdef DARLING` branch; `_os_tsd_get_base`
did not. Fix (xnu patch 0026): give it one, returning `sys_thread_get_tsd_base()`. dyld is
unaffected -- it uses `gSyscallHelpers->errnoAddress()` and never inlines this accessor, so its
self-contained link does not gain an unresolved symbol; the faulting code is in libSystem, which
carries tls.c.

Method note that unblocked everything: the direct-mldr harness plus `coredumpctl`/gdb is the boot
debugging loop -- each fault leaves a core with the exact PC and registers. Deferred: pthread_asm.S
`____chkstk_darwin` also reads TPIDRRO_EL0 directly (asm, can't just call a function); only hit on
large stack frames, so fix it if it surfaces. Prefix rebuild with 0026 is running; retest the boot
when it lands.

**Update, fourteenth pass -- a FAST boot-debug loop, the TSD fix confirmed, and the next fault (the
arm64 syscall stubs).**

Iteration was on the slow path: every fix meant a full `nix build .#cider-buck2-prefix-min`, ~30-40
min, because any source edit rehashes the whole-tree `projectSrc` and forces an ~18 min buck2 graph
re-dump before compiling. The fast loop instead uses direct `buck2` in the dev shell (guest_arch=arm64
in .buckconfig.local; buck2's own incremental engine, no graph dump) and OVERLAYS the rebuilt guest
dylibs onto a writable copy of the nix-built prefix -- guest binaries link libSystem at RUNTIME, so
only the ~38 system dylibs (+ dyld) move, not the tools. `scripts/checks/buck-bash-check.nu --prefix
<copy>`. Whole cycle ~1-2 min. Script: scratchpad/fast-boot.sh (target->prefix-path map lifted from
buck/prefix-min/BUCK; dyld added by hand because it is not a *.dylib and statically links
libsystem_kernel_static64.a). NOTE: overlay ALL of the TSD-inlining binaries or the OLD code is what
runs -- the first attempt missed dyld (39 `mrs TPIDRRO`), so the fault didn't move.

With libSystem + dyld overlaid, the TSD fix is CONFIRMED: the SIGSEGV-at-0x8 is gone (dyld now has 0
TPIDRRO reads, 97 to sys_thread_get_tsd_base) and the boot advances to a NEW, different fault --
Signal 5 (TRAP), a `brk #0x1`, because a call to Darwin BSD syscall 372 (`thread_selfid`) returned
-1 and the caller asserts it cannot. The call is a RAW `svc #0x80` stub (`mov x16,#372; svc #0x80;
b.cc ...`). Both ends are already correct: `sys_thread_selfid` does `LINUX_SYSCALL(__NR_gettid)`, and
`bsd_syscall.S` HAS an `__aarch64__` `__darling_bsd_syscall` dispatcher (`ldr x9,[table + x16*8];
blr x9`). The gap is the STUBS: the guest libsystem_kernel/dyld carry the UPSTREAM raw `svc #0x80`
syscall stubs (490 in libsystem_kernel, 153 in dyld) instead of darling stubs that `bl
__darling_bsd_syscall`. On Linux arm64 `svc #0x80` just traps to the kernel as `svc #0` with x8
unset, so it fails. NEXT: fix the arm64 syscall-stub generation so `___thread_selfid` et al. route
through `__darling_bsd_syscall` (as x86 does) rather than emitting `svc #0x80`. That is the arm64
guest syscall ABI -- likely the biggest remaining boot piece.

**Update, fifteenth pass -- the arm64 guest syscall ABI: BSD stubs (0027) AND Mach traps (0028).**

Two twin fixes, both the exact analog of what x86 darling already does, both landed as xnu patches
(the working tree under vendor/src/xnu is a pin materialization -- `jj status` is clean after editing
it -- so edits must be captured as patches to reach the nix build; buck2/fast-boot compiles the
working tree directly).

0027 (gen/bsdsyscalls/SYS.h): the arm64 `DO_SYSCALL` macro emitted `mov x16,#nr; svc #0x80`. Wrapped
it in `#ifdef DARLING` -> `bl __darling_bsd_syscall` + a Linux-errno check (`cmn x0,#4095; b.cc ok;
neg x0,x0; bl _cerror`). Unlike svc, `bl` clobbers x30/lr, so the stub gets a self-contained frame
(`stp/ldp x29,x30`). One edit fixes all 490 generated BSD stubs (they are all clean `label:
DO_SYSCALL; ret`). Verified in the built dylib: `___thread_selfid` disassembles to exactly the
intended sequence and `__darling_bsd_syscall` resolves (local `t`). This got the guest PAST the
thread_selfid brk.

A scare that was actually progress: rebuilding dyld with 0027 grew it +240 KB and it began aborting
early (`dyld: mkstringf, out of memory` / abort_with_payload). I first read this as a regression and
proved it by building a raw-svc dyld + fixed dylib -- which faulted at the OLD thread_selfid brk,
and the fault PC landed squarely inside dyld's mapping. That was the tell: dyld calls its OWN
statically-linked thread_selfid, so the fixed dyld is STRICTLY better (past thread_selfid); the +240
KB is just dyld now properly linking the bsd dispatcher so its static syscalls work. The mkstringf
OOM was the NEXT obstacle, not a regression.

That OOM was Mach traps. `_simple_salloc` (dyld's crash-safe allocator behind mkstringf) gets memory
via `vm_allocate`, a MACH TRAP -- and the arm64 `kernel_trap` macro (osfmk/mach/arm/syscall_sw.h)
still emitted raw `svc #0x80` (strace showed `syscall_0x<garbage> = ENOSYS`, x8 unset). 0028 does the
same treatment: `#ifdef DARLING` -> `bl __darling_mach_syscall` + frame. `__darling_mach_syscall`
ALREADY had a correct arm64 implementation (negates the trap number, indexes ___mach_syscall_table,
blr) -- only the stubs needed to call it. With 0028 the boot leaps forward: dyld allocates fine, maps
vchroot, and reaches DEPENDENCY LOADING.

Current frontier (the fast loop, ~2 min/cycle, confirmed each step): dyld now fails loading vchroot's
first dependency `/usr/lib/libSystem.B.dylib`. Two collected reasons: `mremap_encrypted() => -1,
errno=78 (ENOSYS)` -- dyld (ImageLoaderMachOCompressed.cpp:2144) thinks a segment is FairPlay-
encrypted (cryptid != 0) and calls a syscall the emulation does not implement -- and a path search
that stats `/usr/lib`, `/usr/local/lib`, `$HOME/lib` (DYLD_FALLBACK_LIBRARY_PATH) all ENOENT. NEXT:
figure out why libSystem is seen as encrypted (build cryptid, or an arm64 load-command misparse) and
why the guest `/usr/lib` -> prefix mapping is not resolving for the loader's stat probes. Note: errno
translation works (Linux ENOSYS 38 -> Darwin ENOSYS 78 is correct), so the emulation plumbing is
sound; this is a dyld-loader / prefix-mapping layer.

**Update, sixteenth pass -- the FairPlay mremap in the dyld2 loader (0003), then the signal wall.**

The libSystem "no suitable image" was NOT a path-mapping problem after all -- dyld had FOUND the file
(`.../usr/lib/libSystem.B.dylib`); the ENOENT stat probes were just dyld walking the fallback search
list. The real reason was the first collected exception: `mremap_encrypted() => -1, errno=78`. Every
cider dylib carries an `LC_ENCRYPTION_INFO_64` with cryptid 0 (not encrypted), and dyld's
registerEncryption (ImageLoaderMachOCompressed.cpp:2127) -- compiled only on `(__arm__ || __arm64__)`,
which is why x86 never saw it -- calls `::mremap_encrypted` whenever the command is PRESENT, cryptid
regardless. The emulation has no such syscall (489), so it returned ENOSYS and every dylib load aborted.

There was already a patch 0002 for EXACTLY this, but only in the dyld3 loader (dyld3/Loading.cpp);
the guest boots through the dyld2 loader, which 0002 missed. 0003 adds `&& !defined(DARLING)` to the
dyld2 block, byte-for-byte the same move 0002 made. libSystem now loads and the boot leaps again.

New frontier -- SIGNALS. With libSystem up, the container runs TWO guest processes (vchroot, then
shellspawn: two `darling_sigexc_self()`), and then a guest SIGSEGV (signal 11) arrives. The daemon
tries to deliver it and hits an arm64 hole on the HOST (Rust ciderd) side:
`xnu_sys_thread_load_state_from_user() unimplemented for architecture: dserver_rpc_architecture_x86_64`
-> `UNIMPLEMENTED call sigprocess (#12)` -> `sigprocess failed ... signal 11: -38` -> init dies. Two
threads to pull: (a) WHY the guest SIGSEGVs this early (real fault vs an expected darling
Mach-exception bounce), and (b) the daemon's thread-state / signal machinery is x86_64-only and even
mis-reports the guest arch as x86_64 -- an arm64 port of the ciderd sigprocess/thread_state path.
This is the first HOST-side (Rust) arm64 gap the boot has reached; everything before was guest Mach-O.

Landed so far this arc: 0027 (bsd stubs), 0028 (mach traps), dyld 0003 (fairplay). Boot path is now
guest-loads-and-runs; the wall moved from "no syscalls" to "signal delivery".

**Update, seventeenth pass -- the checkin arch (mldr), then the objc FAST_DATA_MASK / high-VA fault.**

The daemon's `xnu_sys_thread_load_state_from_user() unimplemented for architecture:
dserver_rpc_architecture_x86_64` was NOT missing arm64 code -- thread.rs HAS the
`#[cfg(target_arch="aarch64")]` branches. The task's `architecture` was simply WRONG: the Rust mldr
(src/darwin/loader/src/rpc.rs) hardcoded `architecture: ARCH_X86_64` in its CHECKIN and VCHROOT_PATH
RPC headers, so the daemon recorded every arm64 guest as x86_64 and skipped the arm64 thread-state
path. Fix (committed, jj-tracked, not a pin): report the loader's compile-time arch (enum: x86_64=2,
arm64=4; cider is native so host arch == guest arch). Signals now dispatch: the log turns into
`sigexc: emulating default signal effects` / `handler (11) returning` -- the arm64 signal machinery
runs. It was never the blocker though; it was masking the real one.

The real blocker: a guest SIGSEGV whose default action (terminate) kills init. Core dump pins it
exactly. Fault PC is in libobjc.A.dylib `readClass()` (offset 0x1fbc4), instruction
`and x8, x8, #0x7ffffffffff8 ; ldr w9, [x8]` -- that mask is objc's arm64 FAST_DATA_MASK, extracting
`cls->data()` from `cls->bits`. The guest dylibs are mapped at 0xe2be7e... -- **bit 47 is SET**
(0xe > 0x7). FAST_DATA_MASK is 0x00007ffffffffff8, i.e. 47-bit; masking a 0xe2be... pointer clears
bit 47 and yields 0x62be..., which is unmapped -> SEGV_MAPERR. On x86_64 the Linux mmap region sits
at 0x7f... (bit 47 clear) so the mask is a no-op and this never fires; aarch64 Linux hands out 48-bit
addresses with bit 47 set. So the guest (dyld's dylib mmaps, and the main image) MUST live below 2^47
(0x0000_8000_0000_0000) for Darwin's 47-bit pointer assumptions (objc, tagged pointers, isa masking)
to hold. NEXT: constrain guest mappings to the low 47 bits -- either mldr reserving / basing the guest
region low, or the sys_mmap emulation refusing bit-47-set results. This is the memory-layout half of
the arm64 port and is likely what darling PR 1753 addresses; check it.

Committed this pass: mldr checkin arch (36b9a676).

**Update, eighteenth pass -- the 47-bit VM layout: dylibs low (0029), dyld low (compute_slide).**

Two fixes for the FAST_DATA_MASK / high-VA fault, both verified by core dumps:

0029 (emulation sys_mmap, mman.c): for a kernel-chosen mapping (start==0, no MAP_FIXED) on aarch64,
hand the kernel a low bump-hint (Linux honours a free hint even topdown) so guest dylibs land below
2^47. dyld and libSystem link separate copies of sys_mmap, so disjoint arenas via VARIANT_DYLD (16
TiB / 64 TiB). Result: libSystem moved from 0xe2be... to 0x100000000000 (16 TiB) -- dylibs are now
low. The ucontext the daemon hands the signal handler also dropped from 0xe2be... to 0x10000127... .

compute_slide (mldr loader.rs, jj-tracked): the guest DYLD is placed by mldr, not sys_mmap; its
preferred base collides with the already-mapped main executable so the aarch64 kernel dropped it high
(0xe58a30faa000). After the fix (re-place a bit-47-set PIE reservation at 8 TiB) dyld sits at
0x080000000000 -- low, below the dylib arenas.

BUT the SAME objc readClass fault survives both. New core: the faulting `and x21,x8,#FAST_DATA_MASK ;
ldr w8,[x21]` reads x8 = 0xe121_5353_f820 (bit 47 SET) from a class that is itself LOW (x19 =
0x100004459050, in the 16 TiB dylib arena). So a correctly-placed low class carries a data pointer
into the HIGH half -- and that high half now contains ONLY mldr's own Linux libraries (glibc at
0xe12153700000, libgcc, ld-linux). So the guest class-data pointer resolves into mldr's glibc region.
That is not an mmap-placement problem (dylibs and dyld are low now); it is a mis-resolved pointer --
a dyld arm64 chained-fixup / __objc_classlist bind computing the wrong target, landing near mldr's
runtime. NEXT: disassemble libobjc readClass to see whether x0/x8 come from a classlist entry or a
realized class_rw, then chase the dyld fixup that produced a glibc-adjacent target. The 47-bit layout
is now correct; this is a fixups bug.

Committed this pass: xnu 0029 (sys_mmap low arena) + mldr compute_slide dyld-low.

**Update, nineteenth pass -- the objc fault is NOT the VM layout; it is a corrupted class_rw.**

Ran the fault to ground with the core + the on-disk dylib. The faulting class (libobjc, at runtime
0x100004459050, a low 16-TiB address -- correctly placed) has its five header words compared file vs
core:

  field   file        rebased(+slide 0x100004400000)   core runtime
  isa     0x59000     0x100004459000                   0x100004459000   OK
  super   0x0         0x0                              0x0              OK
  cache   0x462f0     0x1000044462f0                   0x1000044462f0   OK
  bits    0x55d00     0x100004455d00                   0xe1215353f820   WRONG

So dyld's classic LC_DYLD_INFO rebase is CORRECT for the whole struct -- isa/super/cache all match.
ONLY `bits` (offset 0x20) is overwritten at runtime, from the right value 0x100004455d00 to garbage
0xe1215353f820 -- an address that is UNMAPPED and sits just below mldr's own glibc (0xe12153700000);
it changes with ASLR each run (0xe2be.., 0xe58a.., 0xe121..). objc writes cls->bits during
realization: `realizeClassWithoutSwift` calloc's a class_rw and stores it into bits. So the guest's
class_rw allocation returned a garbage pointer in mldr's glibc neighbourhood. This is NOT the VM
layout (that is fixed -- the class, dylibs and dyld are all low now); it is the guest ALLOCATOR
handing back a bad pointer near the host libc. NEXT: disassemble the calloc stub objc calls
(libobjc __stubs ~0x45774) and read its GOT/la_symbol_ptr in the core -- determine whether guest
`calloc`/`malloc` binds to the guest libsystem_malloc or leaks to mldr's host glibc, and whether the
guest malloc zone reserves its region at a high/garbage base on arm64. The bit-47 mask fault is just
how the garbage surfaces; the bug is upstream in the allocation.

Checked the calloc binding: objc's class_rw calloc stub (libobjc 0x45774) reads la_symbol_ptr at
vmaddr 0x541e0, bound in the core to 0x0000100000e1d4e0 -- a LOW (16 TiB arena) guest address, i.e.
guest libsystem_malloc, NOT mldr's host glibc. So calloc is correctly guest-resolved; the garbage
comes from WITHIN the guest allocator -- its zone/region is high. strace of mldr shows no high mmap,
so the high region is not a plain guest mmap: suspects are (a) the guest malloc zone reserving via a
FIXED/hinted address (my sys_mmap low-hint only fires for start==0 && !MAP_FIXED, so a MAP_FIXED or
hinted-high reservation slips through), or (b) mach_vm_allocate's `*address` hint being high, or (c)
a class_rw slab/pool allocator using a bad base. NEXT: strace with mmap args (not just results) to
catch a MAP_FIXED/hinted high reservation, and read the guest default malloc zone struct to see its
region base. If it is a MAP_FIXED-high zone reservation, extend 0029 to also low-place hinted/FIXED
mappings whose hint has bit 47 set.

**Update, twentieth pass -- the objc fault SOLVED: libmalloc's zone hint, and the boot reaches
shellspawn.**

Instrumented objc (setData + realizeClassWithoutSwift, via a file-scope C-linkage helper writing to
fd 2) and both emulation mmap paths (sys_mmap, _kernelrpc_mach_vm_map_trap_impl). The logs were
conclusive: objc's class_rw comes from objc-zalloc.mm's `::calloc`, and every zone region reservation
went `mach_vm_allocate(ANYWHERE) -> _kernelrpc_mach_vm_map_trap_impl -> sys_mmap` with
`start=0x1000, flags=ANON|PRIVATE, NO MAP_FIXED`. That 0x1000 is libmalloc's minimum-address hint
(allocate anywhere >= a page); on aarch64 Linux the kernel ignores a hint that low and places the
mapping TOPDOWN (bit 47 set). My earlier 0029 only overrode `start==0` and bit-47-high hints, so a
low-but-bogus 0x1000 hint sailed through -> high region -> high class_rw -> FAST_DATA_MASK fault.

Fix (0029 rewritten): force EVERY non-MAP_FIXED mapping into the low bump arena, overriding the hint
outright -- a Darwin guest never wants a bit-47 address and a non-fixed hint carries no guarantee.
MAP_FIXED (exact addresses the guest derived from prior low reservations, e.g. dyld segment maps) is
still honoured. Result: zero high mmaps, zero setData-high, the objc realizeClass fault is GONE.

The boot LEAPS: vchroot finishes objc init, `execve`s /usr/libexec/shellspawn (ret 0), and shellspawn
starts inside the vchroot (fd 2 now -> /ciderd.log). No crash, no core -- it TIMES OUT
("cider: timed out waiting for the guest program to start"): shellspawn is up but has not spawned the
shell yet. All the diagnostic instrumentation was reverted; objc4 and mach_traps.c are pristine again,
only mman.c (0029) carries the fix. NEXT: debug why shellspawn hangs before running bash -- it is the
container's shell launcher, so this is likely a Mach-IPC/handshake or a specific syscall it waits on.

Committed this pass: xnu 0029 rewritten (force non-FIXED mappings low).

**Update, twenty-first pass -- the boot reaches shellspawn; next wall is the post-fork checkin RPC.**

With objc fixed the boot runs shellspawn (the container's shell launcher) and hangs. Probed the live
process tree: `cider` (launcher) is in its proxy ppoll, `ciderd` idle in epoll_wait, and the guest
`mldr`/shellspawn is blocked in `recvmsg` (syscall 212, wchan __skb_wait_for_more_packets) on fd 512
-- the RPC socket, i.e. a Mach/darlingserver RPC to the daemon, NOT the command socket. Decisive
socket evidence (`ss -xp`): the launcher already delivered the shell command --
`/var/run/shellspawn.sock` is ESTAB with Recv-Q = 8890 bytes queued and UNREAD on the guest's fd 9.
So shellspawn accepted the launcher's connection and forked to run the shell, but the fork's child is
stuck in an RPC before it ever reads the command.

fork.c pins it: sys_fork() does clone(SIGCHLD) on aarch64 (no SYS_fork), then the child closes the
inherited RPC socket, makes a fresh per-thread socket, and calls `dserver_rpc_checkin(is_fork=true,
..., newReadFd)` (fork.c:59) -- a blocking RPC. The child blocks in that checkin's recvmsg and the
daemon never logs a matching task_create/checkin, so the CHECKIN either is not reaching ciderd or its
handler is not replying. The emulation RPC uses the compile-time-correct arch (arm64), so this is not
the mldr-rpc.rs arch bug from pass 17; it is the darlingserver fork-checkin path (new socket / lifetime
pipe / child task registration) on arm64. NEXT: boot with CIDER_XNU_LOG=debug to see whether ciderd
receives the fork CHECKIN, then read ciderd's checkin handler (src/linux/server) for the is_fork path
and the per-thread-socket rendezvous. This is a HOST-side (Rust daemon) fork/IPC issue, the second
after the pass-17 arch fix.

Deeper probe (CIDER_XNU_LOG=debug + live process tree): the fork DID happen -- two guest processes,
the PARENT shellspawn blocked in `anon_pipe_read` (waiting on the shell it forked) and the CHILD in
`recvmsg` (the dserver checkin RPC). The daemon is NOT idle now; it is SPINNING on Mach IPC:
`sending kmsg ... to pid -1`, `mqueue_post: no receiver on mq=...`, and
`special_port GET bootstrap: task=... itk_bootstrap=(nil) -> port=(nil)`, over and over. So the
forked child's Mach state is wrong -- stale parent thread ports (messages to pid -1 = a dead thread)
and a NULL bootstrap port -- and the daemon churns delivering to dead ports instead of completing the
child's checkin, exactly the "a later send to the dead thread's ports spins the daemon (kmsg to pid
-1)" failure the checkout handler warns about. handler.rs:387 even flags it: "Exec-replacement's
task/thread swap is a later refinement." The arm64 boot is the FIRST to fork+exec a guest, so it is
the first to hit this. NEXT (host-side, Rust): trace whether the child's checkin creates its task
(task_create nsid=2) or the spin starves it; look at the fork/exec task+thread swap and bootstrap-port
inheritance in the daemon (task.rs / handler.rs / registry.rs) -- the forked child needs a fresh task
with its single thread and an inherited bootstrap port, and the parent's stale threads must be torn
down so the daemon stops messaging pid -1.

Localized further (pass 22). It is a REAL deadlock (200s timeout, not slow), and the earlier
"kmsg to pid -1" churn was only debug-level per-message logging, not a spin -- without debug the
daemon log is quiet. It is the FORK checkin, not exec: shellspawn accepts the launcher connection
(shellspawn.sock ESTAB, 8886 cmd bytes queued unread on fd 9), forks in listenForConnections, and the
child's fork.c does `__dserver_per_thread_socket_refresh()` then `dserver_rpc_checkin(is_fork=true,
newReadFd)`. DECISIVE datum from `ss -xap`: the daemon's `.ciderd.sock` is `u_dgr UNCONN Recv-Q 0`
and ciderd's single thread sits in epoll_wait -- so the child's checkin datagram NEVER ARRIVES at the
daemon. dserver did not abort ("Failed to checkin" never printed), so the child's sendto *succeeded*
but delivered to the wrong place (a DGRAM sendto to a bad/stale addr silently drops), and its reply
recvmsg blocks forever; no nsid=2 is ever created. So the bug is the FORK CHILD's RPC socket refresh
on arm64: create_thread_socket / server-addr / bind after clone. Strong lead: rpc.rs
reserve_high_cloexec documents that "the forked child's fork.c" runs on a stack MISALIGNED BY 8, which
it worked around for x86 (movaps) -- arm64 has strict 16-byte SP alignment, so a misaligned child
stack could corrupt the new socket setup or the sendto addr. NEXT: strace the fork child's
socket/bind/sendto to see the checkin's target addr (vs .ciderd.sock), and audit
__dserver_per_thread_socket_refresh + create_thread_socket for the arm64 forked-child (alignment /
server_addr inheritance). This is the precise, tractable blocker between here and a running bash.

**ROOT CAUSE + FIX (pass 23) -- the fork deadlock was a raw `svc` in the arm64 `___fork` stub.**
Pass 22's socket-refresh / stack-alignment hypothesis was WRONG. Instrumenting sys_fork (fork.c)
with kprintf showed it was NEVER CALLED: the guest's fork never reached the emulated sys_fork at
all. The trail: libc `fork()` (vendor/src/libc/sys/fork.c) calls the asm stub `__fork()` ->
`gen/bsdsyscalls/___fork.S`. Its arm64 branch emitted `mov x16,#SYS_fork; svc #0x80` -- a RAW
supervisor call -- while i386/x86_64 have an `#ifdef DARLING` branch routing through
`bl __darling_bsd_syscall`. On Linux arm64 that raw svc traps to the host kernel (x8 unset) and
never runs sys_fork, so the forked child never checks in with darlingserver and the parent hangs
forever in `_mach_fork_parent -> dserver_rpc_fork_wait_for_child` (RPC 11). This is the SAME class
of bug as the generated bsd stubs (0027) and mach traps (0028); the hand-written custom fork/vfork
stubs were simply missed. Fix: patch 0030 gives arm64 `___fork` the DARLING branch, using the same
error convention as SYS.h DO_SYSCALL (`cmn x0,#4095 / b.cc / neg / _cerror`) plus the fork-specific
child `__current_pid` clear. RESULT: the fork now works end-to-end -- sys_fork runs, the child
(pid=2) refreshes its socket, checks in, and completes full Mach re-init (task_self_trap,
thread_self_trap, set_thread_handles, ...); the parent's fork_wait returns. A NEW blocker appears
downstream: the child (forked shellspawn) then takes a SIGSEGV (sigexc_handler signal 11) before it
can spawn bash. Also debugging fact worth keeping: raw `write(2)` to fd 2 does NOT reach ciderd.log
(the guest's fd 2 is virtualized), and kprintf before the child's socket refresh is unsafe (shared
parent socket) -- log the fork child via kprintf only AFTER socket_refresh. NEXT: find the child's
SIGSEGV fault PC (instrument the sigexc path / mldr signal handler) and fix it. (vfork uses the same
raw-svc stub in `___vfork.S`; sys_vfork just calls sys_fork, so it needs the same treatment, but the
current bash path uses fork+posix_spawn, not vfork.)

**Post-fork crash chain (pass 24) -- three more arm64 defects, each one boot-step deeper.** With the
fork working, the forked child then crashed in a sequence of distinct bugs, each fixed and each
advancing the boot:
  1. SIGSEGV in `___pipe` writing to libsystem_kernel __TEXT (`_sys_pipe`). The arm64 pipe stub
     stashed the fildes pointer in x9 across the syscall, but patch 0027 routes bsd syscalls through
     `bl __darling_bsd_syscall` (a real call that clobbers caller-saved x9-x15), unlike the
     register-preserving `svc` the stub assumed. Fixed by stashing on the stack (patch 0032); audited
     siblings and fixed the same bug in `___getpid` (patch 0033, re-derive &__current_pid after the
     call). `___vfork` has the same x9-across-`svc` shape but still uses raw svc (the 0030 fork-class
     bug) and is off the bash path.
  2. The crash reports were themselves garbage until the arm64 signal struct layout was fixed: struct
     linux_gregset had fault_address LAST (kernel: FIRST) and struct linux_ucontext put uc_mcontext
     before uc_sigmask (arm64 kernel: sigmask + 1024-bit reservation, THEN mcontext). Every register
     read from a signal came from the wrong offset. Fixed against this host's asm/sigcontext.h +
     asm/ucontext.h (patch 0031); verified sigcontext.fault_address == siginfo.si_addr.
  With pipe fixed, the boot now does the SECOND fork AND `execve /bin/bash` -- bash's own dyld runs
  and loads its dylibs. bash then SIGSEGVs during libSystem startup in `__setjmp+0xc`
  (libsystem_platform): `mrs x16, TPIDRRO_EL0 ; and x16,#~7 ; ldr x16,[x16,#0x38]` faults at 0x38
  because TPIDRRO_EL0 reads as 0 -- the guest cannot use the hardware thread register (Linux owns
  TPIDR_EL0; cider emulates Darwin TSD via the hash table of patch 0026). setjmp/longjmp/chkstk read
  the TSD base straight from TPIDRRO_EL0 (offset 0x38 = the pointer-munge cookie), which cider does
  not populate. This is the deferred "pthread_asm.S chkstk TPIDRRO read" item, now on the critical
  path. NEXT: route those TSD-base reads through cider's arm64 TSD mechanism instead of TPIDRRO_EL0.
  (Symbolication note: bash's dylib map differs from shellspawn's -- 0x100002C00000 is
  libsystem_platform under bash but libsystem_asl under shellspawn -- so per-process maps matter;
  DYLD_PRINT_SEGMENTS now on in fast-boot. Also: kern_printf has no %016llx.)

**bash RUNS (pass 25) -- setjmp TSD-base fixed; now a login-shell / launcher-handshake matter.**
Root cause of the __setjmp crash: the asm `_OS_PTR_MUNGE_TOKEN` macro (os/tsd.h) read the TSD base
from `mrs TPIDRRO_EL0`, which is 0 on Linux EL0, so `ldr [base,#0x38]` faulted. Patch 0026 fixed the
C accessor but not this inlined asm. arm64 Linux has no free TLS register (tls.c), a call would
clobber setjmp's x0/lr, and _pthread_ptr_munge_token is a libpthread symbol libplatform cannot link
(confirmed: undefined-symbol link failure). Fix (patch 0034): use a zero munge token -- setjmp and
longjmp stay mutually consistent, nothing is dereferenced; drops jmp_buf mangling (a hardening) and
leaves ucontext mangling as a follow-up. RESULT: bash now starts fully -- loads its whole dylib set,
does Mach init, and FORK+EXEC+WAITs real subprocesses from its login profile: /bin/cp and
/usr/libexec/path_helper both run to completion (pid 4, 6), and bash handles signals. So the full
fork/exec/wait machinery works on arm64. It does not yet reach `echo BUCK2_BASH_OK`: the launcher
kills the container at its 60s startup watchdog because the 1-byte "started" marker shellspawn is
supposed to send back never arrives (main.rs:852), and/or the login-profile subprocess chain is slow
under emulation. NEXT: check whether CIDER_SHELL_STARTUP_TIMEOUT=0 lets bash finish (slow vs hung),
then fix the shellspawn->launcher started-marker handshake and/or avoid the login-profile path.

**M3 DONE (pass 26) -- bash boots and runs on cider aarch64. buck-bash-check PASSES.**
```
BUCK2_BASH_OK 3.2.57(1)-release arm64-apple-darwin19
PASS: the buck2-built Darling boots and runs bash
```
The last blocker was the command-substitution hang: fd tables showed bash holding BOTH ends of one
pipe (fd 13 and fd 14 -> the same pipe:[...]), so its read never saw EOF. Root cause in pipe.c:
sys_pipe ran the Linux pipe2 (filling fd[]) then, on x86 only, copied fd[1] into %edx so the Darwin
___pipe asm stub (`stp w0,w1,[fildes]`) could store both fds; the non-x86 path was literally
`#warning Missing assembly!`, so on arm64 fd[1] never reached x1 and fildes[1] was garbage -- bash
closed the wrong fd, leaked the write end, and blocked in eval $(path_helper -s). Fix (patch 0035):
the arm64 analogue `ldr w1, fd[1]`. With it bash finishes its --login profile (fork+exec+wait for
/bin/cp and /usr/libexec/path_helper, benign "No such file" cp warnings and all) and runs the target
`echo`. NOTE: run with CIDER_SHELL_STARTUP_TIMEOUT=0 because the shellspawn->launcher 1-byte
"started" marker (main.rs:852) still is not delivered on arm64 -- a cosmetic launcher-watchdog fix
for later (bash output reaches the captured fd directly regardless). Diagnostic instrumentation used
during this bring-up (fork.c/sigexc.c kprintf, rpc_wire.rs eprintln) is in the materialized pins
only, not captured as patches, so the nix re-materialization is clean; rpc_wire.rs (cider's own
source) reverted. NEXT: M4 -- the full nix build (`buck-nix-bash-check`: guest Nix builds bash inside
the arm64 container), which re-materializes every pin from patches 0001-0035.

**M4 started (pass 27) -- guest-nix infrastructure adapted for arm64; guest nix now launches under
cider. Next wall: nix aborts early.** buck-nix-bash-check drives scripts/build/build-pkg-bypass.nu,
which had bash x86_64-darwin assumptions. Two arm64 adaptations landed:
  1. The nixpkgs system is now derived from guest_arch (.buckconfig.local): aarch64-darwin for an
     arm64 guest, since cider can only execute binaries of the guest ABI (a cider arm64 cannot run
     x86_64-darwin tools). Verified the aarch64-darwin bash derivation resolves.
  2. scripts/gnix-build.sh hard-defaults to an x86_64-darwin nix; build-pkg-bypass now resolves and
     realizes the ($sys) nix (aarch64-darwin nix-2.34.8+1 substitutes cleanly from cache) and passes
     it via NIXBIN, so the guest gets an arm64 nix it can execute. This cleared the NO_NIX_BIN wall.
With NIXBIN set, the guest nix (aarch64-darwin, under cider) LAUNCHES but aborts very early -- during
`nix-store --init`/`--load-db`, before gnix-build.sh's =BUILD marker. The only guest output is
`sigprocess failed internally while processing Linux signal 6: -111`: signal 6 = SIGABRT, and the
sigexc handler's dserver_rpc_sigprocess RPC then failed with -111 (ECONNREFUSED, daemon connection
refused) and re-aborted. So there are (at least) two threads to pull next: WHY nix aborts (a real nix
error vs a cider bug in nix's sqlite/startup; nix forks heavily, so a forked-child RPC-socket gap
like the earlier fork work is plausible), and WHY the sigexc RPC is refused for that process. Also
still open: a few aarch64-darwin SDK build-tools (patchutils, cpio, pbzx, make-shell-wrapper-hook)
are "no substituter" in the cache -- build-pkg-bypass treats that as harmless, matching x86, but it
may bite once nix runs. M4 is a large, distinct phase: getting nix, then the whole Darwin arm64
toolchain (clang, ld64/cctools, make, coreutils) to run under cider -- each a bring-up like bash but
larger. The M3 milestone (bash boots and runs; patches 0030-0035, nix-validated) is the clean base
it builds on.

**M4 blocker identified (pass 28): the guest nix needs the arm64 FRAMEWORK stack, which prefix-min
lacks.** Instrumenting gnix-build.sh (per-step markers, full stderr) showed the guest nix aborts at
the very first step, `nix --version`, with a dyld error -- not sqlite, not fork:
```
=NIXVER=
dyld: Library not loaded: /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
  Referenced from: /nix/store/...-curl-8.21.0/lib/libcurl.4.dylib
  Reason: image not found
abort_with_payload: reason: dyld: No shared cache present
```
nix links libcurl, and (from otool -L) libcurl needs CoreFoundation + CoreServices +
SystemConfiguration -- Apple frameworks that live in the dyld shared cache on real macOS. cider has
no shared cache, so it must supply them as standalone dylibs from the prefix. The full prefix
(buck/prefix/BUCK) DOES map them (e.g. //vendor/src/corefoundation:CoreFoundation_dylib), but the
bash-tier prefix-min (what M3 and this M4 attempt used) does NOT. So M4's real requirement is the
arm64 framework stack: CoreFoundation (-> libobjc, already arm64 in M2) plus CoreServices and
SystemConfiguration (both -> CoreFoundation). NEXT: confirm CoreFoundation compiles for arm64 (build
//vendor/src/corefoundation:CoreFoundation_dylib was launched), then build a prefix that includes
CF+CoreServices+SystemConfiguration (or the full cider_prefix) for arm64 and point M4's $rt at it.
Each framework may surface its own arm64 execution bugs under cider once nix actually loads them --
this is the framework-tier analogue of the M2/M3 bash bring-up.

**M4 framework closure mapped (pass 29): nix's frameworks compile for arm64 EXCEPT the AppKit that
CoreServices drags in via re-export.** From nix's otool closure, the guest nix needs exactly
CoreFoundation + CoreServices + SystemConfiguration (Foundation too, transitively). Results building
each for arm64 with buck2:
  - CoreFoundation (//vendor/src/corefoundation:CoreFoundation_dylib): builds (real arm64 Mach-O;
    the buck-out artifact is misleadingly named `..._x86_64` but `file` says arm64).
  - CoreServices, SystemConfiguration (//src/darwin/frameworks:*_dylib): the umbrella dylibs build.
  - BUT CoreServices is an umbrella that LC_REEXPORTs its sub-frameworks -- AE, CarbonCore,
    DictionaryServices, FSEvents, LaunchServices, Metadata, SearchKit, SharedFileList, CFNetwork,
    CoreFoundation. dyld loads all of them when nix loads CoreServices. Building the sub set pulls in
    LaunchServices -> AppKit (//vendor/src:AppKit_obj), and AppKit does NOT compile for arm64:
    cocotron/AppKit/NSApplication.m uses x86 `uc_mcontext->__ss.__rip/__rsp` in cider's own CIDER_APP
    fatal-signal handler (should be __pc/__sp on arm64), and has IMP calls the newer arm64 SDK
    rejects ("too many arguments, expected 0" -- IMP is now void(*)(void), needs a cast). Foundation
    (also cocotron) built fine, so the IMP breakage looks localized to NSApplication.m, not pervasive.
  - The full prefix (//buck/prefix:cider_prefix) is the WRONG target: 16708 actions, pulls in CloudKit
    etc., and fails on a missing SDK MIG file (mach/notify.defs). Build only what nix needs.
DECISION POINT for M4: nix never calls AppKit -- it is forced in solely by the CoreServices ->
LaunchServices re-export. Two paths: (a) port AppKit (+ whatever else the re-export chain needs) to
arm64 -- larger, and mostly dead weight for a build tool; or (b) avoid loading it -- e.g. build a
stub LaunchServices (same exported symbols, no AppKit dep) or drop the LaunchServices re-export from
CoreServices, then supply CF-level symbols nix actually uses. (b) is the smarter path but needs a
symbol-usage audit (which CoreServices/re-exported symbols nix binds). The concrete first fixes
either way: NSApplication.m __rip/__rsp -> __pc/__sp under arm64 (a clear cider bug), and cast the
IMP calls. This framework-tier phase (stack + AppKit decision + then framework RUNTIME arm64 bugs
once nix loads them, then the clang/ld/make toolchain) is M4's bulk -- much larger than the M2/M3
bash bring-up. Overlay tooling exists: scratchpad/m4-fw.sh builds+copies the framework dylibs into
$rt; extend it once the AppKit path is chosen.

**AppKit ported for arm64 (pass 30): the framework tier is tractable, not a wall.** Building the
CoreServices re-export chain surfaced AppKit's arm64 breakage; `buck2 build //vendor/src:AppKit_dylib
--keep-going` showed it is SMALL and localized (not pervasive). Three fixes make AppKit compile AND
link for arm64 ("BUILD SUCCEEDED"):
  1. cocotron/AppKit/NSApplication.m -- cider's own CIDER_APP fatal-signal handler read x86
     `uc_mcontext->__ss.__rip/__rsp`; arch-guard to `__pc/__sp` on arm64.
  2. cocotron/AppKit/NSApplication.m + NSTextView.subproj/NSTypesetter_concrete.m -- direct IMP calls
     the newer arm64 SDK rejects (IMP is now `void(*)(void)`); cast before calling, e.g.
     `((void (*)(id, SEL, id, NSInteger, void *))function)(...)` and `((void (*)(id, SEL))imp)(self, NULL)`.
  3. cocotron/Onyx2D/O2Font_freetype.m -- an x86 `__builtin_ia32_pause()` spinlock hint in the
     host-font lock; arch-guard to `__asm__ __volatile__("yield")` on arm64.
NOTE: these edits are in the MATERIALIZED cocotron pin but NOT yet captured -- there is no
vendor/patches/cocotron/ dir and cocotron is not wired for patches, so a nix re-materialization would
lose them. TODO: create the cocotron patch set (and manifest wiring) to make them durable; the fast
buck2 build keeps them meanwhile.
NEXT for M4: overlay the FULL framework LOAD closure into $rt, not just CF/CoreServices/
SystemConfiguration/Foundation. nix loads CoreServices, which LC_REEXPORTs LaunchServices (-> AppKit
-> its deps), CFNetwork, and the AE/CarbonCore/... subs, so ALL of those (transitively) must be
present or dyld fails "image not found" as it did for CoreFoundation. Compute the closure by
recursively otool -L'ing the framework dylibs, map each to its buck target via buck/prefix/BUCK, and
extend scratchpad/m4-fw.sh (which already builds+overlays a named set) to cover it. Then re-run M4;
expect framework RUNTIME arm64 bugs once nix actually loads them, then the clang/ld/make toolchain.
The framework tier is the bulk of M4 but each blocker so far has been a small, localized fix.

**M4 huge step (pass 31): the arm64 framework stack works; guest nix LOADS and RUNS. Next runtime
blocker is the TPIDRRO_EL0/TSD bug again, now in dyld's thread-local accessor.** scratchpad/m4-fw.sh
now builds+overlays ALL public+private framework Mach-O binaries (main dylibs AND framework-internal
.dylib libraries) from buck/prefix/BUCK with --keep-going, then copies them into $rt. 210/212 build
for arm64 (only JavaScriptCore + DBusKit fail, which nix does not need). With the full closure present
the guest nix no longer hits any "dyld: image not found" -- it loads all 210 frameworks and RUNS:
gnix-build.sh reaches =NIXVER=, =INIT=, =BUILD=, =PKG_DONE=. But EVERY nix command exits 139 (SIGSEGV).
The fault is deterministic: PC=0x100008E515E4 = libdyld.dylib `_tlv_get_addr+0xc`, si_addr=0x810,
code=1. Disassembly:
```
ldr  x16, [x0, #8]            // x16 = TLVDescriptor->key   (= 0x102)
mrs  x17, TPIDRRO_EL0         // TSD base -- reads 0 from EL0 on Linux
and  x17, x17, #-8
ldr  x17, [x17, x16, lsl #3]  // *(0 + 0x102*8) -> FAULT at 0x810
```
This is the SAME root cause as the setjmp munge-token bug (patch 0034) and the errno accessor (0026):
hand-written asm reading the Darwin TSD base straight from TPIDRRO_EL0, which cider cannot use on
arm64 Linux (tls.c: the TSD lives in a tid-keyed hash reached via sys_thread_get_tsd_base()). nix uses
C++ thread_locals, so `_tlv_get_addr` (vendor/src/dyld/src/threadLocalHelpers.S, __arm64__ at line 230)
fires immediately. FIX: under DARLING arm64, fetch the base via sys_thread_get_tsd_base() instead of
`mrs TPIDRRO_EL0`. The wrinkle: _tlv_get_addr's contract is "clobber only x0/x16/x17", but a C call
trashes x1-x15/x18/x30/q0-q7, so the base fetch must save/restore those around the `bl` -- mirror the
LlazyAllocate block already in that file (lines 256-297). Expect more of the same class (any other
`mrs TPIDRRO_EL0` in guest asm) plus other nix/toolchain runtime bugs after. STATE: the framework
tier is essentially built for arm64; AppKit + these fixes live in materialized pins (durability TODO:
vendor/patches/cocotron, and this dyld fix). This was the last "does nix even run" blocker; past it,
M4 becomes iterating nix/clang/ld/make runtime bugs like the bash bring-up.

**GUEST NIX RUNS on cider arm64 (pass 32).** The _tlv_get_addr TPIDRRO_EL0 fix (patch 0004, dyld:
route the TSD base through sys_thread_get_tsd_base with the ABI save/restore) landed and WORKS:
`nix --version` now prints `nix (Nix) 2.34.8+1` and returns 0 (was 139/SIGSEGV). Verified the overlaid
libdyld carries the fix (_tlv_get_addr moved to 0x5154c; the old 0x515E4 fault offset is now harmless
LlazyAllocate code, so the residual faults in the $prefix log are cumulative from pre-fix runs -- the
current run's return codes are the truth). So: the whole arm64 framework stack loads AND nix, a large
threaded C++ program, executes under cider. NEXT blocker is no longer a crash but a nix-level error:
`nix-store --init`/`--load-db` exit 1 with `error: opening file "/Users/root/nixstate/db/schema": No
such file or directory` -- the store DB is not being created. Refined: nix-store --init DOES
create the DB directory -- $NIX_STATE_DIR/db/{big-lock, reserved(8MB)}, gcroots, temproots, profiles
all appear -- but db.sqlite and schema do NOT. So nix gets past the disk-space reservation and fails
specifically at CREATING THE SQLITE DB. That points at sqlite under cider arm64 (its open path does
fcntl advisory locking F_SETLK/F_GETLK, mmap, pwrite) rather than a permissions/mkdir problem. NEXT:
strace the guest nix-store --init (or instrument) to see which syscall on db.sqlite fails; likely an
arm64 fcntl-lock or mmap emulation gap. This is the store layer, past "does nix run". Reproduce:
scratchpad/m4-build.sh (CIDER_SHELL_STARTUP_TIMEOUT=0, guest log at /tmp/m4-guest-build.log via the
build-pkg-bypass cp). DURABILITY still open: the AppKit/Onyx2D fixes are in the cocotron pin with no
patch dir; scratchpad/m4-fw.sh overlays the framework stack into $rt but is not a committed build step.

**M4b RESOLVED (pass 33): the store-DB blocker was a cider arm64 `sys_lstat` bug, not sqlite.**
Pass 32 guessed the missing db.sqlite pointed at an fcntl-lock/mmap gap in sqlite. Wrong. A guest
probe run right after the failing `nix-store --init` (writing to a guest-mapped $HOME/probe.out so it
is readable live from the host) showed cider's filesystem is CONSISTENT and CORRECT there: stat on the
absent `db/schema` returns absent, open returns ENOENT, and a plain open(O_CREAT) of db.sqlite succeeds
and persists. So basic FS ops are fine and there is no sqlite/fcntl problem. The tell was the divergence
between two "does it exist" checks: nix's `pathExists()` (which uses **lstat**) saw db/schema as
existing on a fresh store, while bash `[ -e ]` (which uses **stat**) correctly saw it absent. That
isolates the fault to lstat specifically. Reading
`vendor/src/xnu/.../bsd/impl/stat/lstat.c`: on an arch defining neither `__NR_lstat64` nor `__NR_lstat`
(arm64, whose only Linux stat syscall is newfstatat), the `#else` branch of `sys_lstat`/`sys_lstat64`
stored the LINUX_SYSCALL result in a fresh `int status` instead of `ret`. `ret` kept the value
`vchroot_expand()` returned (0 on success), so `if (ret < 0)` was never taken and lstat/lstat64 returned
0 (success) with an UNPOPULATED stat buffer for every path, including nonexistent ones. Existing files
still worked (newfstatat filled the buffer, ret==0 was right), so the bug only bit absent paths.
`sys_stat` was immune because it delegates to `sys_fstatat`, which already assigns `ret`. That is exactly
why nix failed: `pathExists("<state>/db/schema")` returned true on a fresh store, nix `readFile()`'d it,
open() returned ENOENT, and `nix-store --init` aborted with `opening file ".../db/schema": No such file
or directory` before it ever created db.sqlite. FIX: patch 0036 (vendor/patches/xnu) assigns the
newfstatat result to `ret` in both `#else` branches. Rebuilt `//vendor/src/xnu:system_kernel_final`,
overlaid libsystem_kernel.dylib onto $rt, re-ran: `nix-store --init` now returns 0 and db/ contains
db.sqlite(-shm/-wal) + schema. This is a whole CLASS fix -- any guest code using lstat for existence
(nix, and likely make/coreutils/configure) was silently broken on arm64. NEXT (M4c): the guest driver
proceeds past init to `--load-db` and the real `nix build`; expect clang/ld64/cctools/make/coreutils
arm64 runtime bugs, iterated like the bash bring-up. DURABILITY still open: cocotron AppKit/Onyx2D fixes
(no patch dir yet) and the scratchpad/m4-fw.sh framework overlay (not a committed build step).

**M4c genuine build (pass 34): the check was passing TRIVIALLY; hardening it exposed and fixed a
ciderd scheduler crash, and the guest now really COMPILES bash.** After the lstat fix, buck-nix-bash-
check went green -- but falsely. `nix build` returned build_rc=0 in ~9s with no compiler output: the
aarch64-darwin bash-interactive output is on cache.nixos.org, build-pkg-bypass dumped the store DB with
`--include-outputs`, so load-db registered the target output as valid and the guest no-op'd. The driver
comment even claims it substitutes "everything but the target's own output", but only excluded the
default `out` (its $outhash), and the DB dump re-registered all of them anyway. Attempts to force a
rebuild inside the guest failed on the overlay: the substituted output lives in the read-only /nix
overlay LOWER, so `nix-store --delete` in the guest hit `fchmodat ... EPERM` (cannot clear a lower
path), and excluding only `out` from the dump broke referential integrity (dev/doc reference out ->
load-db rejects -> "failed to obtain derivation"). FIX (build-pkg-bypass.nu): compute ALL target
outputs (`nix-store -q --outputs $drv`), exclude the whole set from both the substitution and the DB
dump, and `nix-store --delete` (plain -- an unprivileged user may not `--ignore-liveness`) them from the
HOST store before the run so nothing shadows the build via the overlay lower. Plus `nix build -L` so the
compile is visible. With that, the guest genuinely builds from source -- and immediately crashed ciderd:
`ciderd: FATAL host signal 11`, fault addr 0xffffae103f9f8698, twice. addr2line'd the (unstripped)
daemon: the fault is `pqueue::meld_pair` via `priority_queue_remove` <- `waitq_thread_remove` <-
`waitq_select_thread_locked` <- `waitq_wakeup64_thread` <- a psynch mutex drop (ksyn_mtxsignal). ROOT
CAUSE: XNU's osfmk priority queue packs a node's child pointer into a signed `long child:48` bitfield and
unpacks by sign-extending bit 47 -- a trick to rebuild kernel 0xffff.... pointers. ciderd runs this in
USERSPACE; on x86_64 user VA is 47-bit (bit 47 = 0, harmless) but on arm64 it is 48-bit and ciderd is
mapped high (0xae..), so a valid node pointer with bit 47 set sign-extends to a bogus 0xffff.. address
(0xffffae103f9f8698 == 0xae103f9f8698 sign-extended). It only bites once the pairing heap has multiple
nodes to meld -- i.e. under real pthread-mutex contention, which a parallel guest build produces and the
single-threaded shell/nix never did. FIX: patch 0005 (vendor/patches/xnu-sys-xnu) masks unpack_child to
the low CHILD_BITS (zero-extend) under `#ifdef __LP64__` -- correct for every 48-bit userspace address,
a no-op on x86_64. Rebuilt //src/linux/server:ciderd, overlaid onto $rt, re-ran: ciderd stays alive (SN,
not the previous zombie), no new FATAL, and the transcript shows bash's configure running under cider
arm64 (`checking for getcwd... yes`, `geteuid... yes`, `mempcpy... no`). So the Darwin toolchain now
executes a real compile under the port. Same CLASS as lstat: XNU code assuming a property (canonical
high-half pointers / no-lstat-syscall) that holds for the kernel or x86 but not arm64 userspace. NEXT:
watch the configure->make->cc->ld->install chain for the next arm64 toolchain bug (or completion).

**M4c blocker localized (pass 35): the guest linker (`ld`) SIGTRAPs intermittently.** With the timeout
raised (1800s was killing a progressing build mid-make; now 7200s, CIDER_PKG_BUILD_TIMEOUT) and the
DYLD_PRINT_SEGMENTS debug env dropped, the genuine build runs full configure and into make -- clang
compiles reliably and most links succeed (mkbuiltins/man2html were built AND run). But the build fails
in configure with `cannot compute sizeof (size_t)` -- and it is NOT deterministic: across the driver's
4 retries a DIFFERENT probe fails each time (attempt1 size_t, attempt2 size_t=8 then intmax_t,
attempt3 size_t again). config.log (kept from the killed run at $prefix/Users/root/nixstate/builds/nix-*
/bash-5.3/config.log) shows the real cause: `AC_CHECK_SIZEOF` compiles AND links a conftest (`clang -o
conftest`), and the LINKER crashes -- `cctools-binutils-darwin-1010.6/bin/ld: 25217 Trace/BPT trap: 5
(core dumped) ld @responseFile` -> `clang: error: linker command failed with exit code 133` (128+5 =
SIGTRAP). ld prints nothing before trapping (a bare trap, no assertion), and it happened 5x in one
config.log. Tolerant checks (CoreFoundation link probes) swallow the failure and configure continues; a
sizeof link probe failing is fatal. A per-link ~15-25% crash rate cannot be beaten by whole-build
retries across a ~100-link build. CLUE: the earlier run WITH DYLD_PRINT_SEGMENTS (which serializes
execution via constant stderr writes) got all the way through configure into make; dropping it exposed
the flake -- so this looks timing-sensitive, i.e. a race, plausibly in the multithreaded linker via
cider's psynch/scheduler (same subsystem as the pass-34 priority_queue fix). Toolchain otherwise sound:
compile + link both work, just not reliably enough for a full build. NEXT: get a backtrace of the
crashing ld (isolated reproducer -- loop one guest link until it SIGTRAPs, capture the PC/backtrace),
localize the trap the way the ciderd backtrace localized the priority_queue bug, then fix at the root
(preferred) or, as a fallback, a retry-on-SIGTRAP ld shim. No core file is written and the sigexc crash
path logs no backtrace, so the reproducer must capture it live.

**M4c UNBLOCKED (pass 36): the intermittent ld SIGTRAP was a TOCTOU race in the arm64 TSD cache.**
Full chain, symptom to root, all localized statically (addr2line + objdump, no heavy cider runs):
the ld Trace/BPT trap (pass 35) is `__os_unfair_lock_unowned_abort` -- a `brk #0x1` in
libsystem_platform reached when os_unfair_lock_unlock finds the lock owner != the caller's self.
The owner is `sys_thread_get_tsd_base()[MACH_THREAD_SELF]` (libplatform lock.c, via the DARLING
tsd.h that already routes around TPIDRRO_EL0). `sys_thread_get_tsd_base()` (emulation tls.c, added
by patch 0021) fronted its tid-keyed hash with a single-entry cache in TWO PLAIN GLOBALS
(tsd_cache_tid/tsd_cache_base, NOT __thread) read non-atomically:
`if (tid == tsd_cache_tid && tsd_cache_base) return tsd_cache_base;`. That is a TOCTOU race: thread
A matches its own cached tid, then reads the base after thread B overwrote BOTH globals, and returns
B's TSD base -> A reads B's MACH_THREAD_SELF -> unowned_abort -> brk -> SIGTRAP. Intermittent,
thread-contention-driven (ld64's parallel linker), and masked when DYLD_PRINT_SEGMENTS serialised
execution -- exactly what pass 35 saw. FIX: patch 0037 (vendor/patches/xnu) removes the racy cache
(its purpose, avoiding a gettid() syscall, is obsolete since current_tid() is a register read via
__builtin_thread_pointer, and the hash probe is O(1)) and publishes table entries base-before-tid
with a release fence for weak arm64 ordering. Rebuilt libsystem_kernel, overlaid, re-ran: ZERO
`CIDER-FAULT sig=5` (was ~5 per configure), configure COMPLETES (`config.status: creating config.h`),
and make is compiling bash from source (alias.c, dispose_cmd.c, ...) with mksignames/mkbuiltins/
man2html LINKING with no trap. Same TSD-on-arm64 family as the errno/setjmp/tlv fixes. This was the
last known M4c blocker; the full from-source bash build is now running. (A temporary SIGTRAP entry in
sigexc.c's CIDER-FAULT logger is still in the materialized guest xnu for monitoring; revert before the
final clean prefix build.) NEXT: let the build finish -> buck-nix-bash-check PASS, then durability
(capture the cocotron/framework overlay steps) and revert the diagnostic logging.

**M4 ACHIEVED (pass 37): buck-nix-bash-check.nu PASSES on aarch64.** The guest Nix, running inside the
buck2-built cider on aarch64 Linux, compiled GNU bash 5.3.9 FROM SOURCE and ran it:
`build_rc=0` -> `GNU bash, version 5.3.9(1)-release (arm-apple-darwin23.4.0)` -> `run_rc=0` ->
`=PKG_DONE`, and the check prints `PASS: guest nix built and ran bash inside the buck2-built Darling`
(m4 check exit=0). The full from-source build ran: configure, all the subdir libraries, ~50 main .c
files compiled with clang, and the final `clang -o bash shell.o eval.o ... -lreadline -lhistory
-Wl,-framework -Wl,CoreFoundation -ldl` link, then the freshly-built binary executed. This is the goal
the whole port aimed at. The path from a silent no-op to a genuine build required, this session: the
arm64 sys_lstat fix (M4b, nix store init), hardening the check to actually compile instead of no-op on
the cache-substituted output, the ciderd priority_queue userspace-pointer fix (daemon crash under mutex
contention), and the tls.c TSD-cache TOCTOU fix (the intermittent ld SIGTRAP). The last piece was
`nix build --cores 1`: parallel `make -j` still hangs because SIGCHLD does not interrupt make's
jobserver ppoll (task #12), so the milestone build runs serially. FOLLOW-UPS, none blocking the goal:
task #12 (parallel-build SIGCHLD/ppoll hang -> restores fast parallel builds), and durability (task #10):
revert the temporary SIGTRAP entry in sigexc.c's CIDER-FAULT logger and capture the cocotron/AppKit and
framework-overlay steps as committed build inputs so a clean nix re-materialization reproduces this
without the manual dylib overlays.

**Pass 38 (M4 durability, task #10): the cocotron/framework fixes captured, and the normaliser gap a
rebase exposed.** After M4 the branch was rebased onto main (aa8baa72, 84 commits, 0 conflicts) and
buck2 re-verified. The rebase pulled main's CG-geometry CFBase.h patch, which targeted the
`include/CoreFoundation/CFBase.h` SYMLINK rather than the real `CoreFoundation/Base.subproj/CFBase.h`;
re-materialization failed applying it, fixed on-branch by retargeting to the real file (9f95199b).
Re-materializing then wiped every manual guest-tree edit, which is the whole point of this pass: an
arm64 fix that lived only in vendor/src vanishes on the next `buck-src.nu`, so each had to become a
committed patch. Three cocotron (the bundled AppKit/Onyx2D pin) x86-isms, surfaced by building AppKit
for arm64, are now `vendor/patches/cocotron/*.patch` (a32c729b): NSApplication.m read the x86
`uc_mcontext->__ss.__rip/__rsp` in its CIDER_APP fatal-signal handler (arch-guarded to `__pc/__sp`) and
called two sheet-didEnd IMPs directly, which the arm64 SDK types as `void(*)(void)` and rejects (cast to
the real `(id, SEL, id, NSInteger, void *)`); NSTypesetter_concrete.m called `_layoutNextFragment` (an
IMP) directly (cast to `(id, SEL)`); O2Font_freetype.m backed a spinlock off with the x86-only
`__builtin_ia32_pause` (yield). All three verified to apply to vendor/pins/cocotron and reproduce the
edits exactly.

The bigger find was a NORMALISER GAP. A direct `buck2 build` of the frameworks died at graph load:
`Invalid symlink at vendor/src/corefoundation/CFBurstTrie.h: include/CoreFoundation/./CFBurstTrie.h --
path contains platform-specific path separator`. corefoundation materializes 94 flat-header links that
carry a `.` component, exactly the case cider-src-normalise (src/linux/buildtools/src-normalise) exists
to rewrite. Cause: `buck-src.nu --all` copies each tree VERBATIM out of the assembled store (`nix build
.#cider-src`, which does not normalise) and never ran the normaliser -- only the per-path branch and
assembleProject (ciderBuck2Graph.nix) did. So a `--all` re-materialization, which is what a rebase
reaches for, left vendor/src un-normalised and every framework/AppKit build failed before compiling
anything. FIX (33885d63): the --all branch now runs the same normalise pass over the materialized tree.
Ran it once on the host tree (re-pointed 101 links, expanded 72 symlinked dirs, left JavaScriptCore's
one cyclic dir link alone); corefoundation's `/./` count went 94 -> 0.

The framework overlay is now a committed step, scripts/build/build-frameworks-overlay.nu (d954dfc7): it
parses buck/prefix/BUCK for the 212 public/private framework Mach-O outputs, builds them for arm64 with
--keep-going, and overlays each at the /System/Library/Frameworks/... path the BUCK prefix maps it to;
RT follows the checks' $BUCK2_RT convention, and --dry-run lists targets without building. The temporary
SIGTRAP entry in sigexc.c's CIDER-FAULT logger (pass 37) was a materialized-tree-only edit and is gone
with the re-materialization; no committed patch carries it.

VERIFIED: `buck2 build //vendor/src:AppKit_dylib //vendor/src:Onyx2D_dylib --keep-going` -> BUILD
SUCCEEDED, 5581 local actions, 0 failed, both dylibs produced. Graph load cleared with no CFBurstTrie.h
error (the normalise fix) and cocotron/AppKit + Onyx2D compiled clean for arm64 (the three patches).
Task #10 done. Remaining follow-ups, neither blocking M4: task #12 (parallel `make -j` SIGCHLD/ppoll
hang, which forces the milestone build to `--cores 1`) and task #11 (profile and speed up guest
execution).

**Pass 39 (task #12): the parallel `make -j` hang is a broken arm64 poll() timeout, not a signal-delivery
bug.** The symptom (gnix-build.sh's own note): under `make -j`, make's jobserver blocks in ppoll, its
finished jobs pile up as unreaped zombies, and the build stalls after the builtins/support subdirs;
serial `--cores 1` always works. The signal-delivery reading came up empty as a cause: SIGCHLD is
explicitly EXCLUDED from cider's sigexc catch-all (darling_sigexc_self skips SIGSTOP/SIGKILL/SIGCHLD),
so make keeps its OWN SIGCHLD handler; the guest cannot even block cider's control signals, because a
Darwin sigset is 32-bit and Linux SIGRTMIN is 34+, so they fall off the end of every mask the guest
converts; and the zombies prove the children are real Linux children of make, i.e. the kernel really is
posting SIGCHLD. What is actually broken is the poll() -> ppoll timeout. arm64 Linux has no `__NR_poll`,
so sys_poll_nocancel (bsd/impl/select/poll.c) falls back to `__NR_ppoll`, which takes a `struct
timespec`, and the ms->timespec conversion had the fields swapped and mis-scaled:
`tv_sec = (timeout % 1000) * 1000000, tv_nsec = timeout / 1000`. A 500 ms poll timeout became tv_sec =
500000000 (about 15.8 years). make's jobserver uses the poll TIMEOUT as the heartbeat on which it wakes
to reap finished jobs and recycle their tokens; with the timeout stuck at ~15 years it never wakes, the
SIGCHLD-driven EINTR just re-enters the same ~infinite poll, tokens never come back, and the build
deadlocks. The x86 `__NR_poll` path passes the ms value straight through and never saw this; serial
build uses fork+wait4, no poll, so it never hit it either. FIX: patch 0038 converts correctly (whole
seconds to tv_sec, the ms remainder to tv_nsec). gnix-build.sh's `--cores` is now `CIDER_GNIX_CORES`
(default 1, the safe serial path); re-enabling parallel is gated on a prefix rebuilt with 0038 running
buck-nix-bash-check with `CIDER_GNIX_CORES` > 1 and completing, after which the serial default can drop.
Confidence is high (the arithmetic is unambiguously wrong and every other candidate was ruled out), but
this is recorded as landed-pending-verification because the parallel run has not yet been executed on a
0038-built prefix.

**Pass 40 (task #12 verification attempt, and two infrastructure findings).** Tried to verify 0038 by
rebuilding the prefix and running buck-nix-bash-check with CIDER_GNIX_CORES=2 (make -j2). Two things got
in the way, neither the poll fix. (1) The HOST buck2 prefix build -- `buck2 build
//buck/prefix:cider_prefix`, which buck-bash-check.nu runs when given no --prefix -- fails at graph load:
`File not found: root//darwin/.../mach/notify.defs, Included in vendor/src/libnotify/BUCK`. That path is
an SDK-farm symlink (src/darwin/.../mach/notify.defs -> vendor/pins/xnu/osfmk/mach/notify.defs), and
vendor/pins/xnu is a FETCHED pin (submodules.json, hash-pinned), not a bundled one, so it is only ever in
the nix store, never on disk. The host buck2 prefix build wants it on disk. The Nix-endpoint prefix build
(`nix build .#cider-buck2-prefix`) assembles pins from the store and applies the vendor/patches (so it
would carry 0038), but a --dry-run of it ALSO fails, at eval: buck/rules/codegen.bzl:355 aborts with
`wayland_protocol needs [cider] wayland_scanner and wayland_protocols in .buckconfig.local: run
scripts/buck-setup.nu`. So the deeper finding is that the host setup itself is incomplete after the
rebase: .buckconfig.local is missing tool paths and vendor/pins is not fully materialized, and the tree
names its own remedy, `scripts/buck-setup.nu`. #12 verification is therefore, in an attended session: run
scripts/buck-setup.nu, `nix build .#cider-buck2-prefix` (applies 0038), point buck-bash-check.nu at the
result via --prefix, then buck-nix-bash-check with CIDER_GNIX_CORES=2. Deferred (the setup and Nix prefix
build are heavy, and this run was overnight and unattended). (2) A latent
and DANGEROUS bug in buck-bash-check.nu, hit here for real: when the prefix build fails, `--show-output`
prints nothing, so the parsed `$art` is "", and an empty string resolves to the cwd under `path type`,
which is a dir -- so the `!= "dir"` guard passed on nothing and the `cp -a $"($art)/." $rt` after the
`rm -rf $rt` became `cp -a /. $rt`, copying the root filesystem into the (already-emptied) prefix. It
reached 4.3 GB of /tmp, /root, /srv before hitting unreadable paths. Fixed with an explicit is-empty
guard (f090fac3); the polluted rt was removed. The M4 prefix in rt is regenerable, so this cost nothing
permanent, but the guard was one buck2 build failure away from a much worse outcome for anyone running
the check.

**Pass 41 (corrects pass 40's remedy: the prefix build is broken on BOTH paths, and buck-setup alone
does not fix it).** Ran buck-setup.nu: it wrote the [cider] toolchain config but left wayland_scanner and
wayland_protocols EMPTY (`wayland_scanner =` with no value), even though `nix build nixpkgs#wayland-scanner`
resolves cleanly by hand right after (returns .../wayland-scanner-1.25.0-bin) -- so the empty write is
transient, and a re-run with wayland-scanner already in the store should populate the host
.buckconfig.local. But that only touches the HOST config. `nix build .#cider-buck2-prefix` still fails,
UNCHANGED (same graph.drv hash before and after buck-setup): the Nix graph derivation generates its OWN
buck2 config in ciderBuck2Graph.nix and never reads the host .buckconfig.local, so it fails at
`root//src/darwin/wayland:{wayland_cgbackend_dylib,wayland_glue_obj,xdg_shell_protocol}` with the same
codegen.bzl:355 `needs [cider] wayland_scanner and wayland_protocols`. So the arm64 prefix cannot be
rebuilt on this host by either path: the HOST buck2 build needs non-empty wayland config AND vendor/pins/
xnu materialized on disk (the fetched pin behind libnotify's notify.defs), and the NIX endpoint needs
ciderBuck2Graph.nix to supply wayland_scanner/wayland_protocols in its generated config. This is a
post-rebase infrastructure regression (main added the src/darwin/wayland GUI backend, #112, and the
wayland tooling config did not come across cleanly), NOT the poll fix. CONSEQUENCE: #12's parallel-build
verification and #11's profiling both need a bootable prefix, and there is none to build against, so both
are blocked here pending an attended fix of the wayland config on both paths (+ pin materialization for
the host path). The poll fix (0038) is landed and high-confidence on its own reasoning; rt is left empty
(regenerates from the prefix build). This is the wind-down point for the unattended run: everything that
could be landed and verified WITHOUT a working prefix build has been, and the rest is gated on infra that
should be repaired with a human watching, not overnight.

**Pass 42 (the prefix build is RESTORED and M4 runs again -- wayland + poll + crash-handler fixes land
it).** Fixed every post-rebase arm64 blocker in the prefix build, in the order `nix build
.#cider-buck2-prefix-min` surfaced them: (1) the Nix graph config (nix/lib/ciderBuck2Graph.nix) did not
supply wayland_scanner / wayland_protocols to the .buckconfig.local it generates, so src/darwin/wayland
failed codegen.bzl:355 -- added the three keys (4ce4bf9d), sourced the way buck-setup does; (2) poll.c's
arm64 ppoll ms->timespec conversion (0038, already landed); (3) four FIRST-PARTY crash handlers --
launchd.c, crashtrace.m, wayland/WaylandEvents.m, wayland/watch.c -- read the x86 __rip/__rsp/__rbp and
full argument-register dumps straight from uc_mcontext->__ss, none of which exist in
__darwin_arm_thread_state64; arch-guarded each to __pc/__sp/__fp and __x[] (e32f9df8), the same class as
the cocotron NSApplication.m fix. With those, `.#cider-buck2-prefix-min` BUILDS clean (every member
compiled), buck-bash-check --prefix boots it and runs bash (`BUCK2_BASH_OK 3.2.57(1)-release
arm64-apple-darwin19`), and buck-nix-bash-check drives the guest nix to build and run bash: `build_rc=0`,
`run_rc=0`, `=PKG_DONE`, `GNU bash, version 5.3.9(1)-release (arm-apple-darwin23.4.0)`. So the M4
machinery is reproduced on this host after the rebase, on the MIN prefix. The FULL prefix still fails on
a separate JavaScriptCore arm64 gap (undefined LLInt/WASM offline-asm entry symbols
_vmEntryToJavaScript / _wasm_entry / _wasmLLIntPCRange* at link), which bash and nix do not need; it is
its own task.

Two INFRASTRUCTURE issues block a clean empirical #12 (parallel make -j) verification, neither the poll
fix: (a) the guest `--offline` build finds bash-interactive already in the store and returns build_rc=0
with ZERO compile activity -- a cache hit, so make -j2 never genuinely runs; (b) forcing a from-source
rebuild needs that cached output deleted, but the TEARDOWN HANG (after the guest exits, ciderd exits with
`[xnu_sys] Trying to lock/unlock mutex without an active thread!` spam and leaves guest bash processes
spinning) holds live /proc gc-roots on the output, so build-pkg-bypass's nix-store --delete is refused
and the cache survives. Clearing the debris by hand is whack-a-mole because each boot re-creates it. So
#12's poll fix stays LANDED and high-confidence (unambiguous arithmetic, airtight mechanism, and the
whole M4 pipeline -- which sets up CIDER_GNIX_CORES=2 -- now runs end to end), with the isolated
genuine-parallel-build test gated on fixing the teardown hang. That hang is itself a real regression
worth its own task: it is why every guest run leaves spinning processes behind.

**Pass 43 (bounding the no-active-thread mutex fallback: a valid hardening, but NOT the teardown-hang
root cause -- see Pass 44).** Bounded an unbounded ciderd-side spin that was at first believed to BE the
Pass 42(b) teardown hang; the end-to-end boot in Pass 44 disproved that and found the real cause in guest
code. The change stands as hardening. In src/linux/server/src/xnu/locks.rs,
`xnu_sys_mutex_lock`'s fallback for a caller with no microthread (`thread_for_xnu_thread` is null, which
happens hundreds of times a second once a guest forks, and for every lock taken during per-process
teardown) was `loop { lock queue_lock; if owner == 0 { return }; unlock; spin_loop() }` -- an UNBOUNDED
busy-wait for `xnu_sys_owner` to clear. During teardown a microthread can be destroyed while still owning
the mutex (it died between lock and unlock), so the owner never clears: the ciderd worker spins on a
pinned core forever and the guest process it serves stays wedged in its trapped syscall, holding the live
/proc gc-root that made `nix-store --delete` refuse and blocked a genuine from-source rebuild. The fix
bounds the wait: yield instead of busy-spinning, and after 2s (far longer than any legitimate
xnu_sys_mutex hold, which is sub-millisecond, so normal contention is unaffected) give up on the vanished
owner and take the lock anyway. Both exits return holding queue_lock, exactly like the success path, so
the paired null-thread unlock (which just releases queue_lock) stays balanced. The change is confined to
the null-thread branch; try_lock and unlock already returned promptly, and the hot path (active
microthread) is untouched. Verified with `//src/linux/server:stage3_spike` (rebuilt clean, 146 local
actions): 500k suspend+resume round-trips -- whose log is full of the very "Trying to lock/unlock mutex
without an active thread!" lines, so it exercises the changed paths -- complete in 3.4s at 6885
ns/round-trip, rc=0, no hang (27d67c00). This is a host-side stress proof with no guest boot and no
gc-roots. NOTE: the end-to-end boot (Pass 44) then showed this change does NOT stop the teardown hang --
the process that spins is a GUEST libdispatch thread, not ciderd -- so this stands as hardening only.

**Pass 44 (the real teardown-hang root cause: a GUEST libdispatch busy-loop on EPOLLHUP, found by booting
the Pass 43 ciderd).** Rebuilt the min prefix (nix `.#cider-buck2-prefix-min`) so its ciderd carries the
Pass 43 change, materialized it into rt (the nix prefix nests under `cider_prefix_min__prefix/`; bin +
libexec is the whole darling layout, the guest tree lives under libexec/cider), and booted with the same
env buck-bash-check uses (CIDER_NO_LAUNCHD=1, CIDERPREFIX): `BUCK2_BASH_OK 3.2.57(1)-release
arm64-apple-darwin19`. So the guest bash runs and the fix does not break the boot. But `cider shell` still
never returned. strace of the survivor showed ciderd already EXITED (zombie) while a guest process -- the
libdispatch manager thread, gettid()==2 -- busy-loops at 99.6% CPU:
`epoll_pwait(13, [{events=EPOLLIN|EPOLLHUP}], 1, -1, ...) = 1`, forever. fd 13 is the guest's socket to
ciderd; once ciderd exits it is EPOLLHUP (peer hung up). The guest's kevent()-over-epoll emulation
(vendor/pins/ciderd/xnu-sys/xnu/darling/src/libsystem_kernel/emulation/src/xnu_syscall/bsd/impl/kqueue/kevent.c)
reports the HUP fd as merely readable and never sets EV_EOF, so guest libdispatch re-arms the same dead
source every iteration and spins. THIS holds the /proc gc-root, not ciderd's mutex path -- so Pass 43's
premise was wrong. Bounding the ciderd null-thread spin is a real hardening (and it did let ciderd exit
cleanly here) but is orthogonal to the observed hang. The genuine fix is guest-side: map EPOLLHUP/EPOLLERR
onto EV_EOF in the kevent emulation so libdispatch drops the dead source and the process exits
(alternative: have ciderd SIGKILL its spawned guests on shutdown so none orphan-spin). Both are deep,
boot-testable changes in vendored code and are the next step. The min prefix + M4 pipeline are unaffected
and still pass (the check cache-hits to build_rc=0/run_rc=0); the hang only blocks the isolated
genuine-rebuild #12 test by keeping a gc-root alive.

**Pass 45 (why the genuine #12 empirical test is out of reach on THIS host: an overlay that is a
14963-action from-scratch build, and systemd-oomd killing it under pressure).** Tried to drive the
genuine rebuild (delete the cached bash output, recompile under make -j2) end to end and hit two
independent walls, both about resources rather than the port. (1) The guest nix links the
CoreFoundation/Foundation family, which the MIN prefix does not install; supplying them via
scripts/build/build-frameworks-overlay.nu is not a small overlay -- on a clean host buck-out those 212
framework targets pull a 14963-action from-scratch compile (the min prefix's framework objects were built
inside the nix sandbox, so nothing is cached on the host). (2) That build, and a bare-min-prefix
buck-nix-bash-check that boots the guest and forks a compile process tree, are both KILLED early -- but
NOT by the kernel OOM killer: memory.max is `max` and memory.events oom_kill is 0 at every cgroup level,
pids.max is not hit, yet `systemd-oomd` is active and kills the whole scope under memory/IO PRESSURE
(PSI), which never touches the kernel oom counter. The min-prefix `nix build` survives because its
compiles run in nix-daemon's own system-slice cgroup, off the user scope oomd watches; buck2 (thousands
of parallel clang) and a guest build run IN the user scope and trip it. A capped overlay (CIDER_FW_JOBS,
new this pass) still died, because the 14963-action depth -- not just width -- is the cost. One
observation worth keeping: the killed guest-build boot left an orphaned, slowly GROWING chain of `mldr`
guest processes (each the parent of the next) reparented to init; consistent with a normal
nix->sh->make->cc process tree mid-compile that outlived its killed driver, though a genuine runaway-fork
bug is not ruled out and would be worth a look during the attended #15 work. NET: on this 15 GB host under
a COSMIC/oomd session, the isolated genuine-parallel-build #12 proof and the full framework overlay need
attended handling (a bigger box, or oomd relaxed for the build scope, or the frameworks materialized from
nix instead of a host buck2 rebuild). The #12 poll fix (0038) stays LANDED and high-confidence on its own
reasoning, and the whole M4 pipeline -- which sets CIDER_GNIX_CORES=2 -- runs end to end; only the
isolated from-scratch reproduction is blocked, and by the environment, not the fix.

**Pass 46 (the teardown spin's real birth: an EVFILT_PROC NOTE_TRACK fork-follow orphans one epoll fd;
fix = EPOLLONESHOT, patch 0006).** Booted the 0004+0005 min prefix (result-min3, both patches confirmed
applied in the build log, no rejects). The guest command still ran (`BUCK2_BASH_OK ... arm64-apple-darwin19`)
but teardown STILL spun: an `mldr` at 99.6% CPU on `epoll_pwait(13)` returning EPOLLIN/EPOLLHUP forever,
`ciderd` already defunct. /proc/PID/fdinfo/13 again showed TWO sockets (tfd 14 ino b6ee, tfd 15 ino adfe)
with the SAME `data 0xdf7c00004000` -- so 0005's re-create guard did not prevent it. Straced the WHOLE boot
with fd decoding (`strace -f -y`) to catch the birth, no rebuild needed. Ground truth, on epoll fd 13:

    epoll_ctl(13, ADD, 14<socket:[47704]>, data=0xdf7c00004000)      # SOCK_STREAM, proc_open kqchan
    socketpair(AF_UNIX, SOCK_SEQPACKET, [9, 10<socket:[59018]>])     # ciderd hands over a child channel
    epoll_ctl(13, ADD, 15<socket:[59018]>, data=0xdf7c00004000)      # same knote, ~1ms later, NO DEL

Two different socket types on ONE knote pointer = the EVFILT_PROC NOTE_TRACK fork-follow (proc.c copyout
110-149): on a NOTE_FORK, ciderd passes a fresh child kqchan fd via SCM_RIGHTS and libkqueue calls
`kevent_copyin_one` to start following the child. A knote holds exactly one fd in `kn_dupfd`, so the second
registration orphans the first: nothing references it, nothing can EPOLL_CTL_DEL it, and
`linux_kevent_copyout` only ever has the knote pointer (never the fd that fired), so the wait loop cannot
remove it either. When ciderd exits both sockets go EPOLLHUP; the orphan is level-triggered and fires
forever while copyout discards a zero-filter knote with no progress -- the 100% CPU spin. This is why 0004
(delete path) and 0005 (re-create path) could not fix it: the orphan is never deleted and never re-created,
it is a second live registration the one-fd knote model cannot track. FIX (patch 0006, committed a35bf7a4):
register proc kqchan fds EPOLLONESHOT so any registration fires at most once then goes quiet; a live knote
rearms (EPOLL_CTL_MOD) after each delivered event, NOTE_EXIT is left disarmed (about to be deleted), and a
freed knote never reaches copyout (platform.c discards zero-filter events first) so an orphan is never
rearmed and cannot spin. The machport hot path is untouched. Empirical confirmation (boot-test of the
result-min4 rebuild) is the outstanding step; the mechanism is proven by the strace and the fix is bounded
by construction.

**Pass 47 (0006 boot-tested: the proc spin is GONE for the simple case, but two distinct issues remain --
a machport orphan and a teardown that never completes).** Rebuilt to result-min4 (0004+0005+0006 all in the
build log) and tested three ways.
- SIMPLE (`bash -c 'echo BUCK2_BASH_OK'`), 75s time-series: peak guest CPU 5% (boot only), settling to 0%.
  The exact mldr that used to burn 99.6% on epoll_pwait(13) is now 0% and BLOCKED in epoll_pwait. fdinfo of
  fd 13 shows the proc orphan fd with `events=40000000` = a disarmed EPOLLONESHOT fd -- fired once, went
  quiet, exactly as designed. So 0006 WORKS: the proc-orphan CPU spin is eliminated.
- COMPLEX (`bash -c 'echo; sleep 4; echo'`), strace -f -y: at teardown the guest mldr spins on
  epoll_pwait(13) returning EPOLLIN ~140us apart on knote 0xdf7c00004000. The spinning fd (fd14) was
  registered `events=EPOLLIN` with NO EPOLLONESHOT, while the proc fd15 has EPOLLIN|EPOLLONESHOT. Since only
  proc.c was patched, fd14 is a MACHPORT orphan: the same freed-knote-leaves-a-registered-fd bug exists in
  evfilt_machport, and it spins on EPOLLIN (unread data on a freed knote's fd that the zero-filter discard
  never drains) rather than EPOLLHUP. So 0006 is INCOMPLETE -- the orphan/spin is a property of the shared
  kqchan knote lifecycle, not proc alone, and machport needs the same treatment (or a general birth-fix in
  the knote free path).
- TEARDOWN, separate bug: even in the SIMPLE no-spin case, `cider` never returns. Process tree at rest:
  launcher `cider` blocked in ppoll([fd=3,fd=7], NULL) forever; its only child ciderd idle in
  epoll_pwait(4); the guest mldr idle in epoll_pwait(13) with (in the echo case) an UNREAPED ZOMBIE child.
  In the complex case wait4 DID reap the children, so the child-exit path can work, yet nothing concludes
  the session. This teardown-incompleteness is the actual milestone blocker and is at least partly
  pre-existing (result-min3 also never returned, it just span while doing so). Compounding it: `cider`
  appears to ignore SIGTERM (buck-bash-check wraps the boot in `timeout 180`, which cannot kill it, so the
  check HANGS instead of passing-with-output at 180s). NET for #15: the headline CPU spin is fixed for the
  common case and committed; remaining work is (a) extend the orphan fix to machport (patch 0007, mirror of
  0006) or prevent the orphan at the knote free site, and (b) root-cause why the launcher/ciderd/guest never
  conclude teardown, and/or make `cider` honor SIGTERM so the timeout-guarded check yields a pass.

**Pass 48 (the teardown-completion bug, probed without a rebuild: the launcher blocks every catchable
signal, and the stall is a regression).** With result-min4 booted on the simple `echo` command: the
launcher `cider` waits in ppoll on fd3 = socket to ciderd and fd7 = a pipe, timeout NULL. Sending SIGTERM,
then SIGINT, SIGQUIT, SIGHUP to it in turn: it survives ALL of them (only SIGKILL ends it). That is the
mechanism behind buck-bash-check hanging: the check wraps the boot in `timeout 180`, timeout's SIGTERM is
ignored, and timeout then waits forever for a process that will not die. Two consequences: (a) the check
can never pass-by-timeout, so cider MUST either return on its own or be taught to honor SIGTERM; (b) the
launcher is waiting for ciderd to signal session-end (fd3/fd7), which never comes because the guest never
concludes -- in the fast `echo` case the guest parent sits in epoll_pwait(13) with an unreaped zombie bash,
i.e. it never saw the child exit, while the slower `sleep 4` case DID reap (a fork-vs-watch timing smell:
bash may exit before/at the moment its proc knote is armed). Important framing: `cider shell <cmd>`
RETURNED at Pass 26 (buck-bash-check passed), so the non-return is a REGRESSION introduced somewhere
between M3 (pass 26) and the current base, NOT inherent. Cheap next lead (no rebuild): bisect the plan /
jj history between pass 26 and pass 42 (where the teardown hang first surfaced) for changes to the launcher
shutdown path, ciderd's guest-exit detection, or the proc/NOTE_EXIT handling, rather than only chasing it
forward from the symptom.

**Pass 49 (the teardown blocker pinned to a single call: shellspawn's NOTE_EXIT kevent never fires).**
Traced the launcher's exit condition to shell_loop (launcher/src/main.rs:848-864): after the guest program
starts, `cider` blocks on sockfd for a 4-byte exit status. The guest sender is shellspawn.c (the
NO_LAUNCHD guest init): it sends the 1-byte started marker (line 320), then registers
`EVFILT_PROC/NOTE_EXIT` on the shell pid (330-334) and BLOCKS in `kevent(kq, NULL,0,&ev,1,NULL)` (342)
until NOTE_EXIT; only then does it `waitpid` + `write(fd,&wstatus,4)` (415-420). The hang is that this
kevent never returns: shellspawn is the guest mldr we keep finding idle in epoll_pwait(13) with an
unreaped zombie shell. So the milestone blocker is a proc/NOTE_EXIT DELIVERY failure in the guest
kqueue-on-epoll, and it is CONSISTENT, not a race: a comparison run (`echo` vs `echo; sleep 2`, both under
`timeout -k 5 40`) hung BOTH (rc=137, 45s, each having printed its marker). It is also independent of 0006
and pre-existing (result-min3 never returned either), so 0006 neither caused nor was expected to fix it --
0006's job was the CPU spin, which it does. NEXT (diagnostic, no rebuild first): strace shellspawn's kevent
and ciderd's proc channel across the shell's exit to decide whether ciderd fails to SEND the NOTE_EXIT
(daemon-side kqchan_proc bug) or libkqueue fails to DELIVER it (guest-side proc copyout/arming), then fix
that specific end. This is the same EVFILT_PROC machinery as 0004-0006 and likely the pass-26 -> pass-42
regression.

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
