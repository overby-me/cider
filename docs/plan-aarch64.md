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
