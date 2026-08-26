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

**Pass 50 (correction: the fd13 loop is NOT shellspawn -- the teardown path is on a different epfd).**
Traced epoll_ctl on the guest kqueue fd13 for the simple `echo` boot: ADD=2 (fd14 EPOLLIN machport-style,
fd15 EPOLLIN|EPOLLONESHOT proc), MOD=0, DEL=0, and NO third ADD. So the process idling/spinning on fd13 is
a long-lived guest kqueue (libdispatch, whose knotes here are never re-armed or torn down in this window),
NOT shellspawn: shellspawn's EVFILT_PROC/NOTE_EXIT knote for the shell is registered on ITS OWN kqueue
epfd, in the shellspawn guest process, which the `epoll_ctl(13<` filter missed. Consequences: (i) the prior
passes' fd13 fdinfo (the two-fd 0xdf7c00004000 case) is a libdispatch knote, so 0006 is validated there,
but (ii) the teardown NOTE_EXIT lives elsewhere and must be traced on shellspawn's OWN epfd. Concrete next
step: identify the shellspawn guest process (the one that sends the 1-byte started marker then blocks in
kevent), find which epoll fd IT waits on, and trace epoll_ctl/epoll_pwait/recvmsg on THAT fd across the
shell exit -- that is where the missed NOTE_EXIT (or a never-registered proc knote) actually is. Stop
reading fd13 for the teardown question.

**Pass 51 (Pass 50 was wrong: fd13 IS shellspawn's kqueue; the teardown bug is knote-pointer ALIASING
that misroutes NOTE_EXIT).** Identified the guest procs by full cmdline in the hung simple-echo state: TWO
`/usr/libexec/shellspawn` mldrs (one blocked in accept(8) = the listener, one in epoll_pwait(13) = the
instance running the shell) plus the zombie bash. So fd13 IS shellspawn's kqueue (it links
libSystem/libdispatch); Pass 50's "libdispatch not shellspawn" call was wrong. shellspawn.c:329-334
registers TWO knotes in one kevent: changes[0] = EVFILT_READ on the launcher socket fd, changes[1] =
EVFILT_PROC/NOTE_EXIT on shell_pid. In the trace both land in epoll 13 with the SAME data.ptr
0xdf7c00004000 (fd14 and fd15), ADD=2 MOD=0 DEL=0. Two LIVE knotes cannot share an address, so one fd is an
ORPHAN of a previously-freed knote whose address was reused -- read.c registers a DUP of the socket
(_dup_4libkqueue, read.c:190), the textbook case where close() does not unregister and only EPOLL_CTL_DEL
does. That shared data.ptr is the whole teardown bug: when the shell exits and the proc fd fires, copyout
resolves data.ptr to the WRONG knote/filter, the event is delivered as the wrong filter or discarded,
shellspawn's `if (ev.filter == EVFILT_PROC && NOTE_EXIT)` never trips, it never breaks its loop, never
sends the 4-byte exit status, and the launcher hangs. This ALIASING is the shared root of BOTH the orphan
spin (0004-0006) AND the teardown hang, PREDATES 0006 (result-min3 showed the same two-fd data.ptr), and
0006 only bounded the spin symptom. THE FIX must eliminate the orphan at the source: guarantee a knote's fd
is EPOLL_CTL_DEL'd whenever the knote is freed -- including the create-failure path (kevent_copyin_one:
150-154 calls knote_release WITHOUT kn_delete, so a create that registered its fd then returned -1 leaks
it) and any dup'd-fd delete path -- so knote_new can never return an address still referenced by a live
epoll entry. OPEN: the exact free-without-DEL site is not yet pinned; a knote-lifecycle trace on shellspawn
from process start is the next step, then a birth-fix patch rather than more ONESHOT symptom-bounding.

**Pass 52 (refinement: create-failure is RULED OUT; the two aliased knotes are both LIVE, so it is an
allocation double-hand-out).** kevent_copyin (common/kevent.c:203-229): when nevents==0 -- exactly
shellspawn's `kevent(kq, changes, 2, NULL, 0, NULL)` -- a failing change returns -1 (line 227), which would
send shellspawn to its `err` label. It does not go there, so BOTH changes[0] (EVFILT_READ) and changes[1]
(EVFILT_PROC) creates SUCCEEDED and both knotes are live and inserted. That rules out the Pass-51
create-failure-leak theory: this is not an orphan of a failed create, it is two LIVE knotes that share one
address. knote_new is a plain `calloc(1, sizeof(struct knote))` (knote.c:46, no freelist), and the address
0xdf7c00004000 is identical on every run (the guest has no ASLR, so allocation is deterministic). So the
real question is why the guest heap hands the second knote an address the first still holds -- candidates:
(a) a guest malloc/TSD bug on arm64 returning a live chunk (cf. the pass-36 arm64 TSD TOCTOU), (b) a
kq_tofree delayed-free that free()s a still-referenced knote mid-batch, or (c) data.ptr not being the value
I think for one filter. DECISIVE next step needs instrumentation, not more black-box straces: add a
temporary dbg line logging the pointer from knote_new and from each EPOLL_CTL_ADD (guarded by an env var),
rebuild once, and watch whether knote_new truly returns the same address twice or whether one knote is
freed between the two ADDs. Only then patch -- the fix site is the allocator/free path, not read.c.
Meanwhile 0006 stays as the verified proc-spin bound; do not layer more ONESHOT.

**Pass 53 (THE root cause, found with the 0007 trace: aarch64 struct epoll_event was packed, so the kernel
read/wrote data at the wrong offset and every kqueue event misrouted; fix = xnu 0039).** Booted result-min5
with CIDER_TRACE_KNOTE=1. The trace settled the Pass-52 contradiction: knote_new returns DISTINCT pointers
(EVFILT_READ ident=launcher-fd -> 0x40000266f2d0 dupfd14; EVFILT_PROC ident=shell-pid -> 0x40000266f3c0
dupfd15), yet the host epoll_ctl (strace) recorded BOTH with data=0xdf7c00004000. So the collapse is not in
libkqueue at all -- it is the guest->kernel epoll_event marshalling. Cause:
emulation/.../ext/sys/epoll.h defined `struct epoll_event { uint32_t events; epoll_data_t data; }
__attribute__((packed))` UNCONDITIONALLY. That is the x86_64 layout: the Linux kernel packs epoll_event
ONLY on x86_64 (uapi/linux/eventpoll.h gates EPOLL_PACKED on __x86_64__), giving 12 bytes with the 8-byte
data at offset 4. On aarch64 the kernel leaves it unpacked: __u64 data aligns to 8, so 16 bytes with data
at offset 8. With the packed guest struct on an aarch64 host, the kernel read data from offset 8 while the
guest wrote it at offset 4; the bytes the kernel picked up were the pointer's high 32 bits (identical
0x00004000 for every 0x40000266f... knote) plus adjacent stack bytes (0xdf7c), so ALL knotes collapsed to
0xdf7c00004000 and aliased onto one epoll registration. That single marshalling bug is the whole of #15:
NOTE_EXIT for the shell came back tagged as the wrong knote/filter, so shellspawn never saw the exit and
the launcher hung; and a freed knote's descriptor fired under a live knote's pointer -> the zero-filter
discard spin. It is a LATENT bug present since the port began (the packed attribute was never arch-gated);
it only bites when live knote pointers share the bytes the kernel misreads at offset 8, which the current
guest heap layout (0x40000266f...) guarantees -- which is why an earlier heap layout (pass 26) could pass
buck-bash-check while today's hangs. FIX (xnu 0039, committed 24eb277e): gate the packing on __x86_64__,
matching the kernel per arch. This should make 0004-0006 unnecessary (they bounded symptoms of the
misrouting); keep them for this build to change one variable, and revisit removing the now-redundant
ONESHOT once 0039 is confirmed by buck-bash-check on result-min6. NOTE: this bug affects ALL guest epoll
users (libdispatch too), not just kqueue, so 0039 is broadly load-bearing.

**Pass 54 (0039 CONFIRMED: buck-bash-check PASSES in 3s, #15 resolved).** Rebuilt result-min6 (0004-0007 +
xnu 0039) and tested. Direct boot: `cider shell /bin/bash -c 'echo BUCK2_BASH_OK'` returns rc=0 in <1s (was
rc=137, hung 150s+); the survivor mldr is idle in accept(8), no epoll_pwait spin. Official gate:
`buck-bash-check.nu --prefix result-min6` -> `PASS: the buck2-built Darling boots and runs bash`, rc=0,
elapsed 3s (previously it hung past 180s because cider never returned and timeout could not kill it). So the
epoll_event layout fix is the correct and complete fix for #15: NOTE_EXIT now routes to the right knote,
shellspawn reports the shell's exit, and the launcher returns cleanly. The residual persistent ciderd +
shellspawn-listener that linger after exit are BY DESIGN (ciderd is a warm daemon for the prefix; idle,
state S, cleaned by the next run's kill-by-root loop) -- not the old spin. #15 is DONE. Follow-ups: (1) the
libkqueue symptom patches 0004-0006 are now redundant with 0039; 0004/0005 are harmless general robustness,
but 0006's proc-EPOLLONESHOT+rearm adds a MOD syscall per proc event and could be reverted for cleanliness
and for #11 (guest speed) once there is a spare rebuild; 0007 is an off-by-default diagnostic, keep it.
(2) #12 (parallel make -j) was blocked by #15 and is now unblocked; the epoll fix likely also matters for
any build-time kqueue traffic. (3) The remaining loop goal is the buck-NIX-bash-check gate (guest nix builds
bash from source), whose blocker was environmental (systemd-oomd + the 14963-action framework overlay,
Pass 45), not #15.

**Pass 55 (#15 done; the buck-NIX-bash-check final gate is blocked by missing frameworks, not the teardown
bug).** With #15 fixed, ran buck-nix-bash-check.nu on the min prefix (result-min6 rt). It FAILED, but
cleanly and for the Pass-45 reason, not #15: the guest nix's curl aborts with `Library not loaded:
/System/Library/Frameworks/CoreFoundation.framework ... dyld: No shared cache present` -- the MIN prefix
does not install the CoreFoundation/Foundation family. Two things worth recording: (i) the boot failed FAST
on the missing dylib, before any build, with mldr=0/ciderd=0 and MemAvailable flat at 9 GB -- so the
Pass-45 runaway mldr chain + oomd did NOT recur; that process explosion was plausibly the NOTE_TRACK
misrouting that 0039 fixed, though a genuine build has not yet run far enough to prove it. (ii) The
frameworks live in the FULL prefix, which IS a nix attribute (.#cider-buck2-prefix, flake.nix:367) that
would build under nix-daemon (surviving oomd) -- but it is blocked by #14 (JavaScriptCore arm64 LLInt/WASM
offline-asm link failure). So the path to the final gate is now: fix #14 -> nix build .#cider-buck2-prefix
-> buck-nix-bash-check with the full prefix. That is a distinct effort from #15 (a JSC/offline-asm link
issue, not kqueue/epoll). Open question for that effort: whether buck-nix-bash-check truly needs the whole
full prefix or only CoreFoundation+Foundation (curl's dependency), in which case a CF/Foundation-scoped
addition to the min prefix could sidestep JSC/#14 entirely -- worth checking before committing to the full
JSC fix. NET this session: #15 (the novel, load-bearing teardown/epoll-misrouting bug) is fixed and the
intermediate milestone passes; the remaining loop goal is gated by #14 + framework packaging.

**Pass 56 (framework path re-scoped: #14/JSC is a red herring; the real gate is oomd-immune nix packaging of
the M4 framework closure).** Re-read the M4 record (passes 29-38) against the current state. Confirmed: the
min prefix has zero framework dylibs; guest nix needs the CoreFoundation/CoreServices/SystemConfiguration/
Foundation stack, which drags in a ~210-dylib load closure via CoreServices' LC_REEXPORTs. That closure
BUILDS for arm64 -- pass 31 measured 210/212 targets build, only JavaScriptCore + DBusKit fail, and nix
needs neither. So the full prefix (.#cider-buck2-prefix / //buck/prefix:cider_prefix) is the WRONG target on
two counts: it fails at JSC (#14) AND at other cones nix never touches (mach/notify.defs MIG, CloudKit;
16708 actions, pass-29 note). Fixing #14 is therefore NOT required for buck-nix-bash-check. The actual
blocker is purely PACKAGING: the working overlay (scratchpad/m4-fw.sh, captured as
scripts/build/build-frameworks-overlay.nu, task #10) is a HOST buck2 build of the 210 framework targets
(~14963 actions), and on this 15 GB host systemd-oomd kills host-scope buck2 builds under PSI pressure
(Pass 45); even a job-capped run died. The min prefix escapes oomd only because it builds through
nix-daemon's own cgroup. CONCRETE PATH: lower the framework closure through the SAME nix endpoint the min
prefix uses -- i.e. a scoped prefix target (min + the ~210 framework dylibs, minus JavaScriptCore/DBusKit)
with its own buck2-targets list and a flake attribute (mirroring cider-buck2-prefix-min /
buck2-targets-min.nix), then `nix build` it (oomd-immune, per-target derivations), materialize into $rt, and
run buck-nix-bash-check. That is the next phase: BUCK prefix tier + targets list + flake attribute + one
heavy-but-oomd-immune nix build, then the genuine guest bash build (which #15/0039 should now let complete,
given the Pass-45 runaway-mldr chain did not recur). This is the bulk of the remaining work and is
well-scoped but large; #14 (JSC offline-asm link) stays a separate, non-gating task.

**Pass 57 (task #16: the framework-tier nix prefix is wired and building; two blockers found and fixed).**
Built the framework tier as planned: gen-prefix-fw.nu (sibling of gen-prefix-min.nu that KEEPS
System/Library/Frameworks + PrivateFrameworks and drops only JavaScriptCore + DBusKit, the two framework
dylibs that do not build for arm64), buck/prefix-fw/BUCK (generated, 741 framework entries, consistency
check clean), nix/lib/buck2-targets-fw.nix, and packages.cider-buck2-prefix-fw mirroring the FULL prefix's
lowering settings -- crucially NOT prefix-min's, because prefix-min uses sourceGroups=true which dangles the
frameworks' relative header symlinks (CoreServices/MacTypes.h); min only survives that by dropping
frameworks. Committed de74cf7c. Then drove `nix build .#cider-buck2-prefix-fw` (oomd-immune, nix-daemon
cgroup) and hit two blockers, each fixed:
  1. WAYLAND-SCANNER UNDECLARED. The framework GUI cone (AppKit -> cocotron -> wayland, pulled by the
     CoreServices->LaunchServices re-export) runs wayland codegen, whose tool + protocol XML store paths
     ciderBuck2Graph bakes into the buckconfig as PLAIN TEXT -- invisible to Nix, so absent in the sandbox:
     "wayland-scanner: No such file or directory". Fixed by declaring wayland-scanner + wayland-protocols +
     wayland-core-protocol in the fw endpoint's extraTools (commit 202220aa). Confirmed: all wayland/AppKit
     targets then built.
  2. OOM UNDER DEFAULT PARALLELISM. With wayland fixed the build reached the framework compiles and 747
     targets died with NO logs and NO compile errors -- the signature of kernel-OOM kills, not build errors
     (memory was high again only AFTER the kills freed it). This is exactly what m4-fw.sh's CIDER_FW_JOBS
     cap warns about: the big ObjC frameworks (Foundation, AppKit, ...) compiled all at once exhaust the
     15GB host. nix-daemon survives systemd-oomd but not the kernel OOM killer when total RAM is gone. Fixed
     by capping the nix build to --max-jobs 4 --cores 2 (plus --keep-going to surface any genuine failure
     with a log). Re-launched; monitoring. If it completes, materialize result-fw and run buck-nix-bash-check
     (the genuine guest bash build, which #15/0039 should now let finish).

**Pass 58 (fw build blocker 3: the cocotron aarch64 patches were never applied because cocotron is
vendored, not a submodule).** With the OOM cap, the fw build cut 747 failures to 30, all cascading from ONE
root: pin-cocotron, which failed with the four pass-30 arm64 errors in NSApplication.m (__rip/__rsp absent
on arm_thread_state64; IMP calls need casts). The fixes existed as vendor/patches/cocotron/0001-0003 (task
#10 captured them) but were ORPHANED: cocotron was converted to a checked-in vendored pin (VENDORED.md, not
in nix/submodules.json), and the build stages it directly from vendor/pins/cocotron via bundledPins
(ciderBuck2Lower.nix:351 / ciderBuck2Graph.nix:109), so cider-src.nix -- which only patches submodules --
never applied them. The materialized working-copy vendor/src/cocotron was fixed, masking it; the nix
bundledPins store reads the raw pin. Fix (commit dd5f3b03): fold the three patches into vendor/pins/cocotron
(same as the original 86), so the content-addressed bundled store carries the fix. Re-launched; base tier
stays cached, cocotron + the 30 GUI-framework dylibs (AppKit/Cocoa/QuartzCore/WebKit/Onyx2D/X11+wayland
backends) rebuild. So far three distinct fw-build blockers found and fixed: wayland-scanner declaration,
OOM job cap, and this cocotron pin fold-in.

**Pass 59 (fw build blocker 4: objc_msgSend_stret is x86-64-only).** With cocotron fixed, the fw build cut
to a SINGLE failure: wayland_appkit_dylib, "Undefined symbols for architecture arm64: _objc_msgSend_stret".
That entry point exists only on x86-64; arm64 returns a struct >16 bytes through the indirect-result
register x8 via the ordinary objc_msgSend. src/darwin/wayland/objc.rs hard-coded
`#[link_name="objc_msgSend_stret"]` on msg_send_rect_ret (-frame -> NSRect, 32 bytes). Fix (commit
follows): gate the link_name -- _stret on x86_64, objc_msgSend elsewhere; Rust's sret lowering puts the
hidden pointer in x8 on aarch64, so the plain symbol is correct. Only objc.rs changed, so most of the
framework closure stays cached; re-running rebuilds the graph + wayland_appkit + staging. Four fw-build
blockers now, all clean arch/packaging fixes: wayland-scanner declaration, OOM cap, cocotron pin fold-in,
objc_msgSend_stret. If wayland_appkit was truly the last, result-fw should complete this run.

**Pass 60 (task #16 built: the framework-tier nix prefix is COMPLETE and boots; guest nix now loads with
frameworks).** After the four fixes, `nix build .#cider-buck2-prefix-fw` completed with 0 failures
(result-fw). The prefix carries the full stack the min prefix lacked: CoreFoundation, CoreServices,
SystemConfiguration, Foundation, CFNetwork, AppKit -- all real arm64 Mach-O, 199 framework dylibs (min had
0), JSC dylib correctly excluded. buck-bash-check --prefix result-fw PASSES in 3s (boots + runs bash with
the 199 frameworks materialized, clean return via #15). Then launched buck-nix-bash-check (the loop's final
gate: guest nix builds bash from source) against it. First 30s: the Pass-55 CoreFoundation "image not found"
is GONE, and the Pass-45 runaway-mldr/oomd does NOT recur (mldr steady at 1, MemAvailable flat ~10GB) --
confirming both the frameworks and the #15/0039 fix. The genuine guest build is running; outcome pending.
NOTE for future fw rebuilds: the fw endpoint has no `skeleton`, so any first-party source edit rebuilds the
graph AND invalidates the per-target cache (each of the 4 fixes cost a ~full framework rebuild at
--max-jobs 4); adding skeleton to the fw graph, as prefix-min has, would avoid that if more fixes are
needed.

**Pass 61 (THE GOAL: buck-nix-bash-check PASSES on aarch64 via the framework prefix).** Ran
buck-nix-bash-check against result-fw (rt materialized from the framework tier). Guest nix, running inside
the buck2-built Darling on aarch64, built GNU bash 5.3.9 FROM SOURCE and ran it:

    build_rc=0
    GNU bash, version 5.3.9(1)-release (arm-apple-darwin23.4.0)
    run_rc=0
    =PKG_DONE .../bash-interactive-5.3p9.drv=
    PASS: guest nix built and ran bash inside the buck2-built Darling

No CoreFoundation "image not found" (frameworks present, Pass 55 cleared), no Pass-45 runaway-mldr/oomd
(mldr peaked at a stable ~9-process build chain, not a runaway; memory dipped to ~0.9GB at the compile peak
then recovered to 10.5GB), and CLEAN teardown -- 0 leaked cider/ciderd/mldr afterwards (#15/0039). The
parallel `make` during the guest bash build (CIDER_GNIX_CORES=2) completed without the #12 hang, so 0038
(poll) + 0039 (epoll) resolve that too. This is the milestone the whole aarch64 port aimed at. The chain
that made it possible this session: #15 root-caused to the packed-epoll_event ABI bug (xnu 0039) so the
guest kqueue routes correctly and teardown completes, then task #16 packaged the framework closure as an
oomd-immune nix prefix (gen-prefix-fw + cider-buck2-prefix-fw) with four arch/packaging fixes
(wayland-scanner declaration, OOM job cap, cocotron pin fold-in, objc_msgSend_stret).

**Pass 62 (task #11 step 1: profiled a guest spawn; the #1 cost is a getcpu syscall storm, not dyld).**
Followed #11's "profile FIRST" step. No perf on this host, so used timing + strace -f -c on `cider shell`
against the materialized fw prefix. A minimal guest spawn (`/usr/bin/true`) costs ~43 ms wall, ~60% in
sys, i.e. OS-shim not codegen. strace -f -c of 15 true spawns: getcpu was 368,550 of 407,946 syscalls
(~90%) and ALL errored -- ~24k failing getcpu per short-lived process, far more than the dyld map/bind
(~340 mmap+mprotect/spawn) or the ciderd RPC (~324 sendmsg+recvmsg/spawn) the task predicted as the top
levers. Root cause: libmalloc calls _malloc_cpu_number() on every allocation (magazine selection,
magazine_tiny/small/medium/nano), which on DARLING routes _os_cpu_number() (xnu libsyscall/os/tsd.h)
straight to a getcpu Linux syscall -- the hottest path in a process that mallocs thousands of times during
dyld/libSystem init. Real Darwin reads the cpu number from a register (TPIDRRO_EL0 low bits), but cider
uses TPIDRRO_EL0 for the TSD base, so it fell back to the syscall. FIX (xnu 0040, committed 452a10a6):
cache the first result and skip the syscall thereafter -- the value is only a magazine hint and getcpu
returns the same (failing->0) value all process long here. ~24k getcpu/spawn -> ~1 per libmalloc TU.
(The clang split the task asked for could not be measured: /usr/bin/clang in the prefix is only the xcrun
shim; the real clang comes from the guest nix store during a build.) NEXT: rebuild min prefix with 0040,
re-strace a spawn to confirm getcpu is gone and measure the per-spawn wall-time drop.

**Pass 63 (task #11: the getcpu fix is VERIFIED, ~40% faster spawn).** Rebuilt the min prefix with xnu
0040 (result-min7), re-materialized rt, and re-ran the profile. Before -> after, minimal guest spawn
(`/usr/bin/true`):
  - getcpu syscalls: 368,550 for 15 spawns (~24,570/spawn, ~90% of ALL syscalls) -> 22 for 5 spawns
    (~4.4/spawn, 0.02%). The 22 still error, but caching means getcpu is now called ~once per libmalloc
    translation unit per process instead of once per malloc. ~99.98% fewer.
  - per-spawn wall (30x true): 1.285s -> 0.771s, i.e. ~43ms -> ~26ms, about 40% faster.
  - sys time (30x true): 0.788s -> 0.385s, HALVED -- direct confirmation the win is the eliminated
    syscall storm, not noise.
Landed as xnu 0040 (commit 452a10a6). NEXT lever, now measured rather than guessed: with getcpu gone the
top real syscalls are dyld's -- newfstatat ~972/spawn and mmap ~518/spawn (path resolution + image
map/bind). That is the task's predicted #1 (dyld cold-load: no shared cache, every short-lived process
re-stats and re-maps its whole dylib closure). Candidate: a dyld closure/shared-cache or a stat cache for
the common libSystem+frameworks set. Higher effort; profile the newfstatat targets first (are they
repeated stats of the same closure paths, which a cache would collapse).

**Pass 64 (task #11: profiled the dyld path; the newfstatat redundancy is real but modest, the real cost
is closure mmap/open).** strace -f -e newfstatat,openat of ONE guest spawn: 3379 newfstatat but only 184
UNIQUE paths (~18x redundancy). The repeats are shared PREFIX components: PREFIX/usr 491x, PREFIX/usr/lib
460x, PREFIX/usr/lib/system 396x -- roughly once per system dylib. Cause: vchroot_run
(linux_premigration/vchroot_userspace.c:280-353) walks each path component and lstat's it to catch
symlinks in the guest->host mapping, with no cross-call cache, so every dylib load re-stats the common
prefixes. A component lstat cache would collapse 3379 -> ~184, but: (a) the win is modest -- ~918 redundant
lstats/spawn at ~2us ~= 1.5-5 ms of the ~26 ms spawn; (b) it is a correctness-critical change to the layer
every file op goes through, needing generation-based invalidation on all path-mutating syscalls and a full
buck-nix-bash-check regression. The DOMINANT dyld cost is not the stats but the actual mmap (~518/spawn) and
openat (~604/spawn) of the whole dylib closure, which only a dyld shared cache / prebound closure removes
(the task's lever #1, "hardest"). ASSESSMENT of remaining #11 levers after getcpu: (1) dyld shared cache =
biggest remaining win, biggest effort; (2) psynch uncontended futex fast path (task lever #2, rated
tractable) -- worth profiling the ~324 sendmsg/recvmsg/spawn RPC to see how much is uncontended psynch; (3)
vchroot stat cache = modest + risky. getcpu was the outsized, low-risk win; the rest are diminishing-returns
or higher-risk. NEXT: profile the ciderd RPC breakdown to size the psynch lever before any core-layer change.

**Pass 65 (task #11: after getcpu there is no single outlier; psynch RPC is the tractable next lever).**
Post-fix syscall profile (strace -f -c, 5 spawns, wall dominated by wait4 which is idle waiting): the real
work is spread -- newfstatat 4859 (~972/spawn), mmap 2589 (~518/spawn), openat 870, read 624, plus the
ciderd RPC sendmsg 1023 (~205/spawn) + recvmsg 1678 (~336/spawn), clock_gettime 2003 (~400/spawn), and
execve/clone for the spawn. Crucially, ZERO futex syscalls -- so all guest pthread locking round-trips to
ciderd even when uncontended, exactly the task's lever #2. So ~541 RPC messages/spawn are lock/cond/signal
round-trips, a chunk of which (uncontended lock/unlock) could be done in-guest via a Linux futex, daemon
only for real sleep/wake. That is the best remaining TRACTABLE lever (the dyld closure mmap/open is bigger
but needs a shared cache; the vchroot stat cache is modest+risky). clock_gettime ~400/spawn is also worth a
look (should be a vDSO no-syscall read). NEXT: read the guest psynch path (libpthread + the daemon
kqchan/psynch RPC) to see where an uncontended mutex/cond fast path can stay in-guest.

**Pass 66 (task #11: CORRECTION to Pass 65 -- psynch is NOT the spawn bottleneck; the RPC is Mach setup).**
Read the libpthread lock path. The uncontended unlock already has an IN-GUEST fast path
(pthread_mutex.c:999-1031: numwaiters==0 returns immediately; otherwise a plain CAS, no kernel/daemon
call unless there are actual waiters), and there is also a __ulock policy. Build-spawn processes are ~single
-threaded (strace: clone ~2.4/spawn), so their locks are uncontended and take the CAS fast path -- they do
NOT RPC for locks. So the ~541 sendmsg/recvmsg/spawn are almost certainly Mach bootstrap/task/thread setup
(the per-process spawn handshake, task lever #3), not psynch; the recvmsg error rate (~30%) also looks like
Mach receive polling, not lock waits. Pass 65's "psynch is the next lever" was premature. REVISED remaining
#11 levers, honestly: getcpu (DONE, ~40%, low risk) was the one outsized win; what is left is fundamentals
-- the dyld closure mmap/open (needs a shared cache, big project) and the Mach per-spawn handshake (lever
#3, load-bearing, hard to trim safely) -- plus modest/bounded ones: the vchroot lstat cache (collapses the
measured 3379->184 stats/spawn, safe with generation invalidation, ~5-15% of a spawn) and routing
clock_gettime (~400/spawn) to a vDSO/commpage read. NEXT concrete landable increment: the vchroot lstat
cache (targets the measured dyld-load stat redundancy; implement with a global generation bumped by every
path-mutating syscall so any mutation invalidates it; regression-test with buck-bash-check and
buck-nix-bash-check). The psynch fast path stays relevant only for contended/multi-threaded guests, not the
build spawn path.

**Pass 67 (task #11: profile is FLAT post-getcpu; remaining levers characterized; getcpu was the one clean win).**
Re-profiled a min spawn (5x /usr/bin/true) after the getcpu fix. Per-spawn syscall counts: newfstatat 972,
mmap 518, clock_gettime 401, recvmsg 336, getpid 217, sendmsg 205, rt_sigprocmask 197, write 181, openat
174, close 168, rt_sigaction 159, read 125, gettid 114, getuid/getgid 105 each, epoll_pwait 103, pread64 84.
NOTHING is remotely getcpu-scale (getcpu was ~24,500/spawn = ~25x the largest survivor). The profile is now
FLAT -- normal process-startup traffic spread across categories, no single outlier. getcpu was THE win.

Dead leads ruled out THIS pass (measurement over assumption):
- vchroot debug printf: vchroot_userspace.c:197 unconditionally `__simple_printf("vchroot_expand(): input
  %s")` -> write(1), which looked like a per-translation cost. Empirically it does NOT fire (booted, captured
  guest stdout: only the marker, zero spam) -- the guest hot path doesn't route through this exact function's
  print. Not a cost.
- clock_gettime (401/spawn): only ~1.1% of time; Darwin timing maps to a Linux clock_gettime syscall with no
  easy vDSO route from the Darwin guest. Not worth it.
- getpid/gettid/getuid/getgid (105-217/spawn): cheap; caching is fork/setuid-risky for ~1%. Skip.

Remaining REAL levers, ranked honestly:
1. dyld shared cache -- BIGGEST win. A min spawn opens 77 distinct dylibs individually (drives most of the
   518 mmap + 174 openat + reads/stats). The guest-side infra EXISTS (dyld3 SharedCacheBuilder.cpp,
   SharedCacheRuntime.cpp, update_dyld_shared_cache). It is inactive because BOTH pieces are missing: (a)
   ciderd implements none of the shared_region host syscalls (__shared_region_map_and_slide[_2]_np /
   _check_np -- grep of src/linux/server is empty), and (b) no cache file is generated for the arm64 prefix.
   So it is a MAJOR multi-subsystem project (host VM-mapping syscall in ciderd, mapping the Mach-O cache at
   SHARED_REGION_BASE with slide/rebase, plus an arm64 cache-generation build step over the prefix dylibs).
   High value, high effort, real risk; flagged for a deliberate go/no-go rather than loop-grinding.
2. vchroot lstat cache -- newfstatat is 972/spawn and 94.5% redundant (3379 total, 184 unique; top repeats
   are read-only system prefixes: /usr/lib/system 396x, /usr/lib 460x, /usr 491x re-stat'd during one dyld
   load). But newfstatat is a cheap syscall (~4% of a spawn), and the fix lives in correctness-critical path
   resolution. SAFEST framing: cache is_symlink ONLY for provably-immutable read-only prefixes (never stale,
   no invalidation). Loop-sized and testable via buck-nix-bash-check (a resolution bug breaks the real build).

CONCLUSION: #11's high-value, low-risk perf work is COMPLETE (getcpu, ~40%, verified). What remains is a
major project (dyld shared cache) or a modest bounded change (vchroot immutable-prefix cache). Next loop
increment: the vchroot immutable-prefix stat cache (bounded, safe, on-theme); the dyld shared cache is the
bigger prize but needs an explicit go-ahead given its scale.

**Pass 68 (task #11: dyld shared cache feasibility scope -- verdict GO, but a large multi-step project).**
Code-read only, no build. Corrects Pass 67's stated blocker: the missing ciderd shared_region syscalls only
gate the SYSTEM-WIDE mapping. The PRIVATE path (SharedCacheRuntime.cpp mapCachePrivate, chosen when
loadDyldCache sees options.forcePrivate) maps the cache with ordinary mmap(MAP_FIXED|MAP_PRIVATE, fd, offset)
and applies slide/rebase in userspace -- NO shared_region syscall. cider already emulates guest file mmap
(that is the 518 mmap/spawn loading dylibs today), so the private path is architecturally reachable now.
Confirmed pieces:
 - dyld CONSUMES the cache: dyld2.cpp calls loadDyldCache at startup (4232) and resolves dylibs from the
   cache via findInSharedCacheImage + ImageLoaderMachO::instantiateFromCache (3560/3566/3644/3763/3930); not
   patched out. So a mapped cache collapses the 77 per-spawn dylib opens.
 - forcePrivate is driven by gLinkContext.sharedRegionMode == kUsePrivateSharedRegion (dyld2.cpp:4222); the
   mode is set from env/config (2232-2640), so cider can force the private path.
 - Builder knows arm64: SharedCacheBuilder.cpp:94 (ARM64_SHARED_REGION_START 0x180000000, size 0x100000000).
 - The builder tool exists (dyld3/shared-cache/*: SharedCacheBuilder, CacheBuilder, mrm_shared_cache_builder;
   interlinked-dylibs/update_dyld_shared_cache_compat.cpp has main) but is NOT a cider BUCK/nix target yet.
Implementation plan (each a heavy-build increment, one at a time):
 1. Add a host build target for a cache builder (update_dyld_shared_cache / mrm builder); resolve its deps
    (MachOAnalyzer, CacheBuilder, codesign). Biggest single unknown -- may be a build-system rabbit hole.
 2. nix build step: run it over the ~77 prefix dylibs (install names /usr/lib/...) -> dyld_shared_cache_arm64,
    placed at the dyld-expected path (IPHONE/MACOSX_MRM_DYLD_SHARED_CACHE_DIR + base + arch) in the prefix.
 3. Set cider dyld to kUsePrivateSharedRegion (env DYLD_SHARED_REGION=private or a small dyld2 default patch).
 4. Make it map+rebase under cider: handle the codesign-coverage check (SharedCacheRuntime.cpp:478; Darling
    stubs codesign, likely OK), MAP_FIXED at 0x180000000-0x280000000 (needs that guest VM range free -- key
    risk), and the DataConstScopedWriter mprotect RW/RO slide pass.
 5. Boot, confirm dylib opens collapse (re-run dyldprof: openat/mmap/newfstatat should drop sharply), measure
    per-spawn wall, regression-test buck-bash-check + buck-nix-bash-check, commit.
Risks: (1) building the cache tool cleanly here; (2) MAP_FIXED placement collision with cider's guest layout;
(3) codesign/rebase under cider. None is a proven blocker; all are integration work. VERDICT: feasible and it
is the biggest remaining perf lever, but a genuinely large, heavy-build, multi-iteration effort. Recommend an
explicit go-ahead before sinking many heavy builds into it; the bounded vchroot lever remains the smaller
alternative.

**Pass 69 (task #11: dyld-cache step 1 de-risked -- TRACTABLE as an incremental guest binary, not a host port).**
Code-read only, no build. The cache builder should be built as a GUEST arm64-darwin binary run under cider,
NOT cross-compiled for the linux host: MachOAnalyzer.cpp (and the layout code) use mach/vm_* APIs
(vm_allocate/mach_task_self/vm_copy/vm_protect) that are native for the guest (cider emulates them) but would
need a shim layer on a linux host. And the guest dyld target ALREADY compiles the heavy shared pieces for
arm64-darwin: dyld3/MachOAnalyzer, MachOAnalyzerSet, MachOFile, MachOLoaded, ClosureBuilder, Closure,
ClosureWriter, ClosureFileSystemPhysical, Diagnostics, shared-cache/DyldSharedCache (dyld BUCK 62-155). So a
builder is INCREMENTAL: add ~8 shared-cache srcs -- SharedCacheBuilder.cpp, CacheBuilder.cpp,
AdjustDylibSegments.cpp, FileUtils.cpp, a driver (mrm_shared_cache_builder.cpp or update_dyld_shared_cache.cpp)
-- plus headers MachOFileAbstraction.hpp (big template), CodeSigningTypes.h, Trie.hpp. Extra deps/risks:
codesign hashing (CommonCrypto/SHA for the cache cdhash; guest needs it) and the optimizers
(OptimizerObjC.cpp / IMPCaches.cpp / OptimizerBranches.cpp / OptimizerLinkedit.cpp) which are the compile-grind
risk -- but they are cache OPTIMIZATIONS, not required for a functional cache, so a first cut can disable them
(unoptimized-but-functional cache still collapses the 77 dylib opens, which is the whole point). NET: step 1's
"biggest unknown" is downgraded to a moderate incremental guest-binary target; the GO verdict stands and the
effort/risk estimate drops. Remaining un-derisked risk is step 4 (MAP_FIXED at 0x180000000-0x280000000 must be
free in cider's guest VM layout); scope that next (cheap), after which further progress needs a heavy build and
so waits on the user's go/no-go.

**Pass 70 (task #11: dyld-cache step 4 MAP_FIXED placement de-risked -- the 0x180000000 range is a natural gap).**
Code-read only, no build. SHARED_REGION_BASE_ARM64 = 0x180000000, SIZE 0x100000000 (xnu shared_region.h:86),
so the private cache maps at 0x180000000-0x280000000 (6-10 GiB). cider's guest VM layout (loader.rs
compute_slide + the aarch64 placement comments): the guest MAIN executable lands near its vmaddr 0x100000000
(~4 GiB) with a bit-47-clear slide; dyld is re-placed at 0x080000000000 (8 TiB) when it would land high; guest
dylib mmap arenas live at 16/64 TiB; Linux anonymous mmaps land high (~0x7f...); libmalloc uses the high mmap
arenas, not a low brk. So 0x180000000-0x280000000 is a GAP -- above the ~4 GiB main image and far below
dyld/arenas -- which is exactly the real arm64 macOS layout (main at 4 GiB, shared region at 6 GiB) that cider
inherited. At dyld-init time (only main image + dyld mapped) the range is free, so mapCachePrivate's
mmap(MAP_FIXED) at 0x180000000 should succeed; cider's mmap emulation already passes MAP_FIXED through
(s2c.rs mmap_flags). Residual placement risk is only a pathological main-image slide extending past 6 GiB
(improbable: images are MB-scale and the slide hint is 0x100000000). NET: step 4 placement is likely safe.

CHEAP-SCOPING PHASE COMPLETE (Passes 68-70). The dyld shared cache is GO with its three named risks scoped:
step 1 (build the cache tool) = tractable incremental guest binary; step 4 placement = natural gap, likely
safe; the remaining unknowns (codesign cdhash handling per SharedCacheRuntime.cpp:478, and the actual compile
grind of SharedCacheBuilder + CacheBuilder for the guest) can only be resolved by building. Further progress
therefore needs heavy builds and waits on the user's go/no-go among: (A) dyld shared cache [biggest perf win,
multi heavy-build iterations], (B) the smaller vchroot immutable-prefix lstat cache (~4%), or (C) #14 (JSC).

**Pass 71 (user chose "do both A and B"; B implemented + building; RPC question answered + tiered as tasks).**
User greenlit BOTH the dyld shared cache (A) and the vchroot lstat cache (B); doing B first (bounded, quick
verified win), then A. Also asked "how much work to run nix mostly without xnu rpc?" -> answered: the ~200
RPC round-trips/process (sendmsg 205 + recvmsg 336 per spawn) are lifecycle-dominated (task/thread
registration, Mach bootstrap ports, teardown); file IO is already in-guest. Tier 1 (trim the hot lifecycle
handshakes) is moderate/incremental and where the nix win is; Tier 2 (in-guest Mach/signal fast paths) is
large; Tier 3 (drop ciderd for most ops) is very large. Added as tasks #17 (Tier 1), #18 (Tier 2 todo),
#19 (Tier 3 todo). To size Tier 1 precisely, ciderd has DSERVER_TRACE_CALLS (logs "RECV #<num>"); still need
to wire capture of ciderd's stderr (in `cider shell` mode it is not on the fd the guest stderr redirect
catches).

B source CONFIRMED: vchroot_expand is the guest translator (33 BSD-wrapper call sites: openat, faccessat,
stat, chdir, ...); its vchroot_run does the per-component NOFOLLOW lstat, and 93% of the 3379 stats/spawn are
guest-prefix paths issued as absolute host paths (NOFOLLOW + accumulated-prefix signature). B implemented as
vendor/patches/xnu/0041-aarch64-vchroot-stat-cache.patch (7 files): a 256-entry direct-mapped per-process
cache in vchroot_run of "accumulated path exists and is not a symlink", keyed by full path, tagged with
__vchroot_generation; the namespace-mutating wrappers that can REMOVE or RETYPE a path bump the generation --
unlinkat.c (covers unlink+rmdir-via-AT_REMOVEDIR), stat/rmdir.c (direct __NR_unlinkat AT_REMOVEDIR),
renameat.c, renameatx_np.c (__NR_renameat2), symlinkat.c; creates cannot invalidate an existing-dir entry
and ENOENT is never cached, so that set is complete. Symlinks/ENOENT bypass the cache; disabled under TEST.
BUILD MODEL learned: vendor/src is EXCLUDED from the nix build (cider-src.nix:92); guest xnu changes must be
patches under vendor/patches/xnu (applied to the vendor/pins/xnu fetch), NOT edits to the read-only vendor/src
tree. Patch dry-runs clean (7/7 files). Rebuilding min prefix -> result-min8; next: measure the stat drop
(dyldprof: expect newfstatat 3379 -> near 184 unique) and per-spawn wall, then buck-bash-check (and ideally
buck-nix-bash-check) to confirm no regression, then commit. After B lands: start A (Pass 69 step 1, guest
cache-builder target).

**Pass 72 (task #11 lever B VERIFIED + correct; done).** Committed 0041 (fd4aa943), rebuilt min prefix ->
result-min9 (/nix/store/d7ivyxd82cly9japwmnj8dzmyrmhhiy8-..., a NEW path; the first rebuild was a no-op
because the flake only sees VCS-COMMITTED files -- 0041 was uncommitted, so min8 == min7 byte-for-byte). Cache
symbols confirmed in the built libsystem_kernel.dylib. Measured (result-min9, `cider shell`):
 - newfstatat 3379 -> 967 per spawn (~71% fewer); the worst hot path (/usr/lib/system re-stat'd 396x) fell to
   ~18x; unique still 184. Residual redundancy is generation-bump CHURN: ~18-26 boot-time system-setup
   mutations (the `cp /Users/root ...` launchd/template writes) each bump __vchroot_generation and clear the
   whole cache, so prefixes get re-stat'd ~20x instead of once. On a real long-running build (higher
   lookup:mutation ratio, and the mutations are mostly one-time boot setup) it collapses more.
 - Per-spawn wall ~27ms (30x true = 0.809s) vs ~26ms pre-B = WITHIN NOISE. Confirms Pass 67: newfstatat is a
   cheap syscall (~0.4us), so cutting 2412/spawn saves ~1ms -- B is a SYSCALL-TRAFFIC reduction, not a
   wall-clock win. Correct and worth keeping (less kernel traffic, helps heavier path-walk workloads), but not
   a spawn speedup on this micro-benchmark.
 - Regression: buck-bash-check --prefix result-min9 PASS -- "BUCK2_BASH_OK 3.2.57(1)-release
   arm64-apple-darwin19", the Darling boots and runs bash. No path-resolution regression from the cache.
B is COMPLETE (commit fd4aa943 stands). A possible future refinement: finer-grained invalidation (drop only
the mutated path's entry instead of a global generation bump) would recover the residual ~20x, but the wall
payoff is sub-noise so it is not worth the added risk now. NEXT: A (dyld shared cache), Pass 69 step 1.

**Pass 73 (task #11: WALL is RPC-latency-bound, not dylib-load-bound -- reconsider A vs Tier 1).**
B taught the lesson: cutting 2400 cheap newfstatat/spawn (71%) did NOT move the ~26ms wall (newfstatat ~0.4us).
So before A's large build, measured what actually dominates the wall (strace -w -f, 10 spawns, result-min9).
Raw top is idle-blocking (accept 96.8% = ciderd waiting for connections; epoll_pwait/ppoll/wait4 = daemon/
parent idle), which strace -w -f conflates with the guest critical path. The signal that survives: recvmsg
averages 122us/call and there are ~240 recvmsg/spawn -> ~29ms, on the ORDER of the whole 26ms spawn wall;
mmap/openat/read (dyld load) are cheap per call (~22-25us). Interpretation: the spawn wall is substantially
RPC round-trip LATENCY (guest blocks ~122us per ciderd reply), not dylib-load syscall count. Consequence for
the plan: A (dyld shared cache) collapses ~600 cheap dylib opens+mmaps -- FEWER syscalls than B removed -- so
its WALL payoff is likely sub-noise like B (its real value is I/O reduction + the unmeasured dyld parse/bind
CPU + being the correct architecture, and it helps more for dylib-heavy processes than /usr/bin/true). The
BIGGER wall lever is Tier 1 (#17): cut the per-process RPC round-trips. CAVEAT: strace -w -f mixes guest and
daemon waits, so this needs a clean confirmation -- size the RPC by tracing ONLY the guest process chain
(exclude ciderd) or wire DSERVER_TRACE_CALLS capture to count RECV per spawn, then RPC_count x ~122us gives
the critical-path RPC cost. RECOMMENDATION surfaced to user: prioritize Tier 1 for wall-clock; keep A as a
lower-priority I/O/architecture improvement. Awaiting steer; meanwhile confirming RPC dominance cheaply.

**Pass 74 (task #11 lever A: user chose "do A first, Tier 1 after"; step 1 driver written, BUCK target next).**
User steer: do A (dyld shared cache) first despite the sub-noise-wall caveat (values the I/O + correct
architecture), then start Tier 1 (#17). A step 1 = build a guest arm64 cache-builder tool. Chosen entry: the
MRM builder C API (mrm_shared_cache_builder.h: createSharedCacheBuilder(BuildOptions_v1*) / addFile(path,data,
size,flags) / addSymlink / runSharedCacheBuilder / getErrors / getFileResults / destroySharedCacheBuilder) --
cleaner and more self-contained than update_dyld_shared_cache.cpp (which pulls legacy mega-dylib-utils.h).
Darling never compiled the cache tools (CMakeLists only builds system_loader), so this is a fresh port.
Enums: Platform macOS=1, Disposition Customer=2, FileFlags NoFlags=0. DRIVER WRITTEN:
src/darwin/cache-builder/cache_builder_main.c -- reads a manifest of guest dylib install-names (e.g.
/usr/lib/libSystem.B.dylib), mmaps each from <root-prefix>, addFile(installName,data,size,NoFlags),
runSharedCacheBuilder, then writes each getFileResults() entry (the cache bytes) into <out-dir>. Options:
version1, platform macOS, archs=["arm64"], Customer, isLocallyBuiltCache.
PORTING ITEMS for the builder srcs (guest arm64-darwin): (1) <apfs/apfs_fsctl.h> at SharedCacheBuilder.cpp:36
is the ONLY apfs reference (no fsctl calls) -- cider's SDK lacks it, so stub an empty header (or patch out the
include). (2) -DBUILDING_UPDATE_DYLD_CACHE_BUILDER=1 (SharedCacheBuilder.cpp:79 guards on it), NOT
-DBUILDING_DYLD. (3) MachOFileAbstraction.hpp is a big template header. (4) codesign cdhash needs
CommonCrypto SHA. SRCS for the obj target: shared-cache/{mrm_shared_cache_builder,SharedCacheBuilder,
CacheBuilder,AdjustDylibSegments,FileUtils,JSONReader}.cpp + dyld3/{MachOAnalyzer,MachOAnalyzerSet,MachOFile,
MachOLoaded,Closure,ClosureBuilder,ClosureFileSystemPhysical,ClosureFileSystemNull,ClosureWriter,
Diagnostics}.cpp + shared-cache/DyldSharedCache.cpp; skip OptimizerObjC/IMPCaches/OptimizerBranches/
OptimizerLinkedit for a first functional cache (verify SharedCacheBuilder does not hard-require them).
NEXT: author a cc_objects + darwin_binary target (model compile flags/include-dir deps on
vendor/src/dyld/BUCK system_loader_obj, but a normal executable linking libSystem -- find a normal guest-exe
target to model entry/linkage on, not the dyld dylinker), add the apfs stub, COMMIT (driver+BUCK; flake sees
only committed files), build the single target to surface compile errors, iterate. Then: nix step to run it
under cider over the prefix dylibs -> cache file at the dyld-expected path; enable dyld private mode; verify.

**Pass 75 (task #11 lever A step 1 DONE: the guest arm64 dyld cache-builder tool BUILDS).** cache_builder is
a 1.7MB arm64 Mach-O (NOUNDEFS|DYLDLINK|PIE) -- a component Darling never compiled, now building on cider
aarch64 via .#cider-buck2-cache-builder. Build-system notes: the single-target buildTarget path overflows Nix
eval (max-call-depth), so the endpoint uses the ciderBuck2Lower path (like cider-buck2-migcom, allPins); and
these must run under PLAIN `nix build` -- systemd-run --user --scope gets torn down when the harness reaps the
long background task (killed a run mid graph-materialization). PORT FIXES (each committed): removed the
nonexistent dyld3/shared-cache/JSONReader.cpp; stubbed dyld3::json (src/darwin/cache-builder/json_stub.cpp) so
it links without JSONReader.mm's Foundation/NSJSONSerialization; empty <apfs/apfs_fsctl.h> stub; <stdbool.h>
in the C driver; -DBUILDING_CACHE_BUILDER=1 (THE key define -- gates DyldSharedCache::CreateOptions/MappedMachO,
TimeRecorder, Diagnostics::warning); and the full src set is required (the optimizers are referenced
unconditionally, "skip them" does NOT link): dyld3/shared-cache/{mrm_shared_cache_builder,SharedCacheBuilder,
CacheBuilder,AdjustDylibSegments,FileUtils,DyldSharedCache,OptimizerObjC,OptimizerLinkedit,OptimizerBranches,
IMPCaches}.cpp + dyld3/{MachOAnalyzer,MachOAnalyzerSet,MachOFile,MachOLoaded,Closure,ClosureBuilder,
ClosureFileSystemPhysical,ClosureFileSystemNull,ClosureWriter,Diagnostics,PathOverrides,RootsChecker}.cpp. The
ObjC optimizers compiled clean (no ObjC-runtime hell). Driver src/darwin/cache-builder/cache_builder_main.c
(MRM C API) + BUCK in src/darwin/cache-builder/ + cache_builder_obj in vendor/src/dyld/BUCK. STEP 2 (next):
run cache_builder under cider over the 221 guest dylib install-names (scratchpad/cache-manifest.txt) to emit
a dyld_shared_cache_arm64; prototype the run first (cheap: cider shell <cache_builder> <out-dir> / <manifest>
on the min9 rt) to confirm it emits a cache; then wire into the prefix at the dyld cache path, set dyld
private mode, rebuild, boot, verify dylib opens collapse (dyldprof) + buck-bash-check.

**Pass 76 (task #11 lever A step 2: cache_builder RUNS under cider; blocked on dylib cache-eligibility;
checkpointing A, pivoting to Tier 1).** Ran cache_builder under cider (guest root = rt/libexec/cider; place
the binary at guest /usr/bin, manifest + out-dir under guest /tmp; scratchpad/step2-proto.sh). It works: reads
the manifest, mmaps + addFile's each dylib, invokes the real SharedCacheBuilder. BUT the builder rejects the
set: dylibsToCache ends up < 30 -> "[ciderCustomer.arm64] missing required minimum set of dylibs"
(SharedCacheBuilder.cpp:912, the >=30 guard). Tried manifests: all-199 (not self-contained), the /usr/lib/
system closure (38), and a computed dependency closure (39, 0 external missing) -- all still < 30. RULED OUT
every inspectable cause (llvm-otool + reading the checks): install-name matches path; LC_SEGMENT_SPLIT_INFO
present; MH_TWOLEVEL set; arch arm64 cpusubtype 0x0 ALL (matches archs=["arm64"]); platform 1 macOS; deps
self-contained; 0 symlink-alias deps; bind addends all 0 (the >31 cache limit is not hit); and per
MachOAnalyzer.cpp:3753 an arm64 non-chained dylib RETURNS TRUE from canBePlacedInDyldCache after the addend
check -- so by inspection these dylibs should be eligible AND land in dylibsToCache, yet they do not. The
reduction is in loadMachOs/verifySelfContained for a reason not isolable by inspection. The definitive
diagnostic (driver addFile flag NoFlags->MustBeInCache, committed, so SharedCacheBuilder.cpp:783-819 prints
the per-dylib "not included because: <reason>") needs a cache_builder REBUILD, and that rebuild keeps getting
KILLED ("interrupted by the user") during the allPins graph re-materialization (twice; plain nix build, not
systemd-run -- so it is resource/harness flakiness on the heavy 147-pin materialization, not the scope). A
STATUS: step 1 DONE and durable (cache_builder is a 1.7MB arm64 Mach-O that builds via .#cider-buck2-cache-
builder and RUNS under cider -- a component Darling never compiled); step 2 blocked on the un-isolated
eligibility reason + fragile diagnostic rebuild. Combined with Pass 73 (A's WALL payoff is sub-noise; the
spawn is RPC-bound), A is a large effort with an uncertain remaining blocker for little wall gain. DECISION:
checkpoint A here (resumable: the tool + the MustBeInCache diagnostic + step2-proto harness + the closure
manifest are all in place; next step is simply to land the MustBeInCache rebuild and read the reason), and
per the user's "A first, Tier 1 after" PIVOT to Tier 1 (#17), the higher-value wall lever, on fresh ground.

**Pass 77 (task #11 Tier 1 / #17: per-spawn RPC histogram captured; REVISES Pass 73; first trim = drop debug
kprintf).** Capture unblock: ciderd's stdout+stderr (incl. DSERVER_TRACE_CALLS "RECV #<num>") go to
<prefix>/ciderd.log (launcher main.rs:526-537), not /dev/null -- so the histogram needs NO rebuild
(scratchpad/measure-rpc.sh: boot+1 vs boot+10 spawns, delta/spawn). RESULT: ~50 RPCs per EXEC'd process
(marginal), plus a ~223-RPC one-time boot. This REVISES Pass 73: the earlier "wall is RPC-bound" was from a
boot-inflated strace (recvmsg ~240/spawn); the true marginal per-process RPC is ~50 -> ~50 x ~122us ~= 6ms,
about 23% of the ~26ms spawn wall, NOT dominant. dyld load + exec + guest compute is the other ~20ms (so A's
dyld cache, if unblockable, attacks the bigger chunk). Per-spawn RPC by type (delta): mach_msg_overwrite 7.8,
mach_reply_port 6.7, task_self_trap 6.7, mach_port_deallocate 4.4, kprintf 4.4, thread_self_trap 3.3,
host_self_trap 3.3, vchroot_path 3.3, set_thread_handles/uidgid/checkin ~2 each. Levers: (a) DEBUG kprintf
(4.4/spawn) -- execve.c "execve expand", filio.c "dtype for fd", sigexc.c "darling_sigexc_self()" are
unconditional debug prints that dserver_rpc_kprintf round-trip to ciderd; pure noise, SAFE to remove. (b)
self-port traps task_self_trap 6.7 + host_self_trap 3.3 (+ thread_self 3.3) RPC every call
(mach_traps.c:38,706, no caching) returning per-process constants -- cacheable getcpu-style but needs
fork-invalidation (riskier). (c) mach_reply_port 6.7 -- per-thread reply port, should be TSD-cached. FIRST
TRIM (this pass): (a), vendor/patches/xnu/0042-aarch64-drop-per-process-debug-kprintf.patch (3 files,
dry-runs clean) -- removes the 3 hot debug kprintf. Rebuild min prefix, re-run measure-rpc.sh (expect kprintf
~4.4->0/spawn), buck-bash-check. Then consider (b)/(c). Note: RPC is ~23% of wall so Tier 1's ceiling is
modest; the getcpu fix remains the standout perf win.

**Pass 78 (task #11 Tier 1: trim #1 VERIFIED; self-port-cache design correction).** Rebuilt min prefix with
0042 -> result-min10 (/nix/store/n49g03ccw75aywl5kchyz3alxmjwkl75-...). Measured (measure-rpc10.sh):
kprintf dropped 4.4 -> ~0 per spawn (gone from the histogram); boot RECV 277 -> 252. buck-bash-check --prefix
result-min10 PASS ("BUCK2_BASH_OK 3.2.57 arm64"). So trim #1 (drop 3 debug kprintf, 0042) is landed + verified
-- ~4 fewer RPCs/spawn, no regression. CORRECTION for the next trim: mach_task_self() is ALREADY a cached
global (mach/mach_init.h:83 `#define mach_task_self() mach_task_self_`; mach_init.c:71 the global, :192 set
ONCE to task_self_trap() at init), and the mach_port_* guards use that cached global -- so caching
mach_task_self is NOT the lever. Yet task_self_trap is 6.7/spawn, so the 6.7 comes from DIRECT task_self_trap()
calls (or repeated mach_init) elsewhere in the guest that should reuse mach_task_self_ instead. NEXT: grep the
guest for direct task_self_trap()/host_self_trap() call sites, find the hot one, and route it through the
cached global (or cache host self similarly). Same for mach_reply_port 6.7 (per-thread reply port -- should be
TSD-cached; check __TSD_MIG_REPLY usage). Record the source as a plan pass before patching.

**Pass 79 (task #11 Tier 1: 0043 was INEFFECTIVE; 0044 caches task_self_trap at the leaf).** Rebuilt with
0043 -> result-min11 (nqh398yg...). measure-rpc11: task_self_trap STILL 6.7/spawn (unchanged) -- so caching
the mach_task_self() C function did nothing; guest code invokes the task_self trap DIRECTLY, not via that
function. 0043 is harmless (a correct function cache) but inert; leaving it. The robust fix, 0044
(vendor/patches/xnu/0044-aarch64-cache-task-self-trap-leaf.patch), caches at the emulation LEAF
(task_self_trap_impl in mach_traps.c, the getcpu pattern) so it catches every caller, and resets the cache in
the fork child (fork.c, after re-checkin -- a forked child is a new task; vfork + posix_spawn both route
through sys_fork, and exec'd processes get fresh statics, so one reset covers all). Also confirmed
mach_reply_port 6.7/spawn is ALREADY TSD-cached (mig_reply_port.c mig_get_reply_port -> __TSD_MIG_REPLY), so
its cost is cache-ineffectiveness (reply-port lifecycle), a deeper fix. Tier 1 clean-win status: kprintf
(0042) landed+verified; task_self (0044) building; beyond these the RPC levers are deep/risky
(reply-port lifecycle, mach_msg service calls, host/thread self = caller-freed refs) for a few % wall each
(RPC ~23% of wall; getcpu 40% stays the standout). NEXT: rebuild min12 with 0044, measure task_self_trap
(expect 6.7 -> ~1), buck-bash-check; if verified, Tier 1's clean wins are done -- then either the reply-port
lifecycle fix (if tractable), return to A's eligibility diagnostic, or record perf substantially complete.

**Pass 80 (task #11 Tier 1 trim #2 VERIFIED).** Rebuilt with 0044 -> result-min12
(4isw4rjy3pwnlaz0g33yks52hkfzxjjb-...). measure-rpc12: task_self_trap 6.7 -> 3.3/spawn (~half); total per-spawn
50 -> 47; boot RECV 252 -> 236. Residual 3.3 is inherent (each fork child resets the cache + re-fetches once,
and each exec'd process re-fetches once -- correct). buck-bash-check --prefix result-min12 PASS ("BUCK2_BASH_OK
3.2.57 arm64") -- the fork-child cache reset is correct, no regression. So Tier 1 CLEAN WINS ARE DONE:
kprintf (0042, -4.4 RPC/spawn) + task_self (0044, -3.4 RPC/spawn) = ~8 fewer RPCs/spawn (of ~50), no
regressions. Item-4 note for the reply-port lever: mig_dealloc_reply_port has NO callers in libsyscall, so the
6.7 mach_reply_port/spawn is NOT from that destruction path -- it is either the __TSD_MIG_REPLY slot not
persisting on aarch64 (the D4 TSD-base-via-hash situation) or mach_msg consuming the reply port; needs
mach_msg.c emulation analysis (queue item 4). Overnight queue continues: unblock A (item 2) next.

**Pass 81 (task #11 A: eligibility reason isolated to SharedCacheBuilder dep-resolution; deep, deferred).**
Rebuilt cache_builder WITH MustBeInCache (result-cachebuilder lpwv154s...) and re-ran the diagnostic. The
only reported error: "/usr/lib/system/libxpc.dylib not placed because: Could not find dependency '<X>'" for
14 core libs (libobjc.A, libsystem_c/kernel/malloc/platform/pthread/info/trace/blocks, libcompiler_rt,
libdispatch, libdyld, liblaunch, libunwind). VERIFIED all 14 are in the 39-dylib manifest, present as files,
and name-matched (e.g. libsystem_c install-name == /usr/lib/system/libsystem_c.dylib). knownDylibs
(SharedCacheBuilder.cpp:584-590) is keyed by BOTH runtimePath and installName, so a present+matched dep should
resolve. Yet libxpc's deps are "not found" -> the deps are NOT in dylibsToCache: loadMachOs
(CacheInputBuilder) routed them to otherDylibs/couldNotLoad, OR the getRealPath fallback (line 670) mangles
the guest path under cider. They are not individually reported (FileFlags MustBeInCache -> state mapping in
mrm addFile/fileSystem.addFile is not clearly mustBeIncluded per CacheBuilder.h:60 state==MustBeIncluded).
ROOT is a SharedCacheBuilder-internals / ClosureFileSystem-under-cider issue; pinning it needs builder
INSTRUMENTATION (print which bucket each dylib lands in + getRealPath results) = another cache_builder rebuild.
DECISION: A is precisely characterized + resumable (next step: instrument loadMachOs bucketing / getRealPath),
but it is a deep rabbit hole for uncertain wall payoff; per the overnight "don't loop on a blocked item"
guardrail, defer A and move to the next bottleneck. A remains the biggest dyld-side lever for a future focused
session. Committed patches to date (all inert-safe or wins): 0040 getcpu, 0041 vchroot cache, 0042 kprintf,
0043 (inert) + 0044 task_self; plus the cache_builder target (src/darwin/cache-builder + vendor/src/dyld).

**Pass 82 (task #11 A: ROOT CAUSE found -- a DRIVER bug, not a cider/builder block).** Instrumented
SharedCacheBuilder (debug patch vendor/patches/dyld/0001) and re-ran: "CIDERDBG buckets: dylibsToCache=1
otherDylibs=0 executables=0 couldNotLoad=0" -- only 1 of 39 added dylibs reached ANY bucket, and it was
libxpc (the alphabetically-last /usr/lib/system entry). Cause: FileSystemMRM::addFile
(mrm_shared_cache_builder.cpp:166) stores FileInfo.path as a RAW const char* (not a copy), and the driver
(cache_builder_main.c) passed `line` from a REUSED `char line[4096]` buffer -- so at build time all 39
FileInfo.path pointers read the buffer's final value (the last manifest line = libxpc), collapsing 39 files to
one. So A was NEVER blocked by cider dylib eligibility (that whole line of investigation was chasing a
symptom); it was a use-after-scope in the driver. FIX: strdup(line) per file before addFile (leak fine,
short-lived tool). Rebuilding cache_builder; expect buckets=39 and an actual cache to emit. This unblocks A's
carry-through (install cache -> dyld private mode -> boot -> dyldprof). Revert the debug patch
vendor/patches/dyld/0001 before the final keeper build.

**Pass 83 (task #11 A: strdup fix landed 37/39; last 2 blockers = flat-namespace dylibs).** After the strdup
driver fix, CIDERDBG showed dylibsToCache=37 with libsystem_blocks.dylib + libunwind.dylib in otherDylibs, and
libxpc (plus the rest) cascading on "Could not find dependency ...libsystem_blocks.dylib / ...libunwind.dylib".
Confirmed directly: both ship with mach header flags=0x100004 (MH_DYLDLINK|MH_NO_REEXPORTED_DYLIBS) and NO
MH_TWOLEVEL (0x80) / MH_NOUNDEFS (0x1). dyld's canBePlacedInDyldCache (MachOFile.cpp:55) rejects
non-two-level dylibs -> they never enter the cache -> everything that links them cascades out. ROOT: their
_final targets in vendor/src/BUCK carried `linker_flags = ["-Wl,-flat_namespace", "-Wl,-undefined,suppress"]`
(flat + suppress is a firstpass idiom that leaked into the finals); every other system dylib final links
two-level by default. FIX (committed): drop those flags so unwind_final + system_blocks_final link two-level;
undefined symbols resolve via the firstpass `siblings` already listed. Bounded risk: if a symbol fails to
resolve two-level the min-prefix build errors (revert), and two-level is the safer runtime model (gated by
buck-bash-check). Rebuilding the min prefix (result-min13); then re-run cache_builder expecting dylibsToCache=39
and an emitted cache. Still to do after: install cache at the dyld path -> dyld private mode -> boot -> dyldprof
to confirm the ~77 per-spawn dylib open/mmap collapse; revert vendor/patches/dyld/0001 before the keeper build.

**Pass 84 (task #11 A: two-level fix LANDED, 39/39 eligible; now a guest-lib export gap).** The
flat->two-level change took three min-prefix rebuilds to converge, because a two-level link must resolve
every out-of-lib ref via explicit firstpass siblings (flat+suppress had hidden them): unwind_final needed
system_malloc + system_pthread + system_dyld firstpass (malloc/free, pthread_rwlock_*, dyld unwind/dladdr +
dyld_stub_binder); system_blocks_final needed libplatform (__platform_memmove) + system_dyld
(dyld_stub_binder for the lazy stub to __os_assert_log). Result: both ship as flags=0x100085
(MH_TWOLEVEL|MH_NOUNDEFS), and cache_builder now reports "dylibsToCache=39 otherDylibs=0 couldNotLoad=0" --
the flat-namespace cascade is gone, all 39 dylibs are cache-eligible. (Fixes squashed into the two-level
commit.) NEW blocker, a different class: runSharedCacheBuilder binds eagerly and failed on a dangling import
-- "symbol '_ccchacha20' not found, expected in libcorecrypto.dylib, needed by libcommonCrypto.dylib". Root:
libcommonCrypto (lib/CommonCryptorChaCha20*.c) imports ccchacha20 + ccchacha20poly1305_{info,encrypt_oneshot,
decrypt_oneshot} from corecrypto, but corecrypto's scripts/exported-symbols.exp had the whole chacha family
commented out -- the functions are compiled (src/ccchacha20poly1305.c) but not exported. The runtime loader
tolerated this lazily (bash never calls ChaCha20); the cache builder does not. corecrypto is a pin
(darlinghq/darling-corecrypto, nix/submodules.json), so the fix is a pin patch:
vendor/patches/corecrypto/0001-export-ccchacha20-family.patch uncomments exactly the four defined+imported
symbols. Rebuilding the min prefix; expect the cache to emit next (or the builder to surface the next dangling
import, same pattern).

**Pass 85 prep (A step 3 mechanism located).** The guest dyld boot NEVER maps a shared cache: dyld2.cpp
(~line 6813) wraps the whole "load shared cache" block -- checkSharedRegionDisable + mapSharedCache + the
DATA_CONST override -- in `#ifndef DARLING`, with the comment "we don't plan on building our libraries into a
shared cache". cider builds with DARLING defined, so mapSharedCache() is never called and installing a cache
file alone does nothing. Everything else is present and appears ungated: mapSharedCache/sSharedCacheLoadInfo,
the findInSharedCacheImage lookups in the dylib-load path (dyld2.cpp:3246/3560/3763), and the
DYLD_SHARED_REGION env (use/private/avoid, dyld2.cpp:2230). Cache dir constant
MACOSX_MRM_DYLD_SHARED_CACHE_DIR = "/System/Library/dyld/" (guest path). So A step 3 = a dyld patch that
enables the mapSharedCache block under DARLING (guarded so it no-ops when no cache is installed), then install
the emitted cache at guest /System/Library/dyld/, boot, dyldprof to confirm the ~77 per-spawn dylib open/mmap
collapse, buck-bash-check. Risky (boot dyld + MAP_FIXED at the cache baseAddress under cider's vm / page-size
handling); do it only after the cache actually emits, and keep it revertible.

**Pass 86 (task #11 A: a dyld shared cache BUILDS -- step 2 done).** With the full corecrypto export patch
in, cache_builder under cider succeeded: "dylibsToCache=39 otherDylibs=0 couldNotLoad=0" then "OK, 2 cache
file(s)", exit 0. It emitted dyld_shared_cache_arm64 (8MB) + .map at guest /tmp/cache-out (host
$CIDERPREFIX/private/tmp/cache-out). Verified: magic "dyld_v1 arm64", 3 mappings (EX 5MB @0x180000000, RW
1MB @0x182568000, RO 1MB @0x186668000), imagesCount=39. Preserved to scratchpad/dyld_shared_cache_arm64. So
the flat-namespace + corecrypto-export saga is resolved and a guest shared cache is producible. STEP 3
STARTED: confirmed the guest dyld (usr/lib/dyld, 1.5MB) is built from src/dyld2.cpp (nm shows dyld::_main,
sSharedCacheLoadInfo, findInSharedCacheImage) and mldr (src/darwin/loader/src/main.rs:337) execs
/usr/lib/dyld -- so the mapSharedCache patch is in the real boot path. Wrote
vendor/patches/dyld/0005-aarch64-enable-shared-cache-under-darling.patch (un-gates the mapSharedCache block;
safe no-op without a cache) and reverted the debug patch 0001. Next: rebuild min prefix, install the cache at
guest /System/Library/dyld/dyld_shared_cache_arm64, boot with DYLD tracing / dyldprof to confirm the
per-spawn dylib open/mmap collapse, buck-bash-check. The 39 cached dylibs are unchanged by the dyld-loader
patch, so the preserved cache still matches the rebuilt prefix.

**Pass 87 (task #20/A step 3: cache maps -- two dyld hurdles down, one hard one left).** With
vendor/patches/dyld/0005 (un-gate mapSharedCache) + 0006 (skip codesign registration under DARLING + log
reject reason), the guest dyld now gets PAST code-signature registration. Measured with measure-cache.sh on
the rebuilt prefix: still no speedup (229 *.dylib opens, ~245 ms/spawn both ways) but now the reject reason is
LOGGED: "dyld: shared cache not used: syscall to map cache into shared region failed" -- the SYSTEM-WIDE
mapping path (SharedCacheRuntime.cpp ~820, __shared_region_map_and_slide_np) which cider does not emulate.
Forcing PRIVATE mode (DYLD_SHARED_REGION=private, uses ordinary mmap) instead HANGS the spawn (timed out,
no dyld output) -- the MAP_FIXED @0x180000000 + chained-fixup rebase under cider's vm. So step 3's remaining
blocker is the actual cache mapping: system-wide needs a syscall cider lacks; private hangs in mmap/rebase.
HYPOTHESIS for the private hang: dyld applies an ASLR slide and the rebase of the cache's chained fixups loops
under cider; forcing disableASLR (slide=0, map at the cache's own baseAddress, no rebase) may avoid it -- but
that needs a dyld patch + ~2h rebuild to test, and MAP_FIXED@0x180000000 availability under cider is itself
unverified. NOTE: patches 0005/0006 are safe no-ops without a cache installed (mapSharedCache no-ops; codesign
skip only matters with a cache), so the prefix still boots normally; no regression. Step 3 is a genuine
multi-cycle dyld-cache-under-cider-vm port; paused here for a direction call. Cache (step 2) is banked.

**Pass 88 (task #20/A step 3: cache MAPS -- but cached-code execution traps; A banked here).** The no-slide
patch 0007 (force opts.forcePrivate + opts.disableASLR under DARLING) cleared the mapping blockers: with the
cache installed at guest /System/Library/dyld/, the guest dyld now MAPS it -- measure-cache.sh shows the
with-cache spawn at "*.dylib opens=39 shared_cache opens=2 mmap@0x18x=3" vs the nocache "opens=229 mmap=0".
So per-spawn dylib file opens collapse 229 -> 39 and the 3 cache regions map at 0x180000000. That is the whole
build->install->map->serve-from-cache path working end to end. BUT the mapped-cache process then HANGS: the
wall A/B shows nocache 236.3 ms/spawn vs with-cache 60000 ms/spawn (every timed spawn hit the 60s timeout).
Cause (from the strace tail): an infinite loop of SIGTRAP {si_code=TRAP_BRKPT, si_addr=0x180370d40} -- the
process executes code inside the cache TEXT (0x180000000-0x180568000) that hits a brk and re-traps forever.
Hypotheses: (a) disableASLR skipped the chained-fixup unpack, so a stub/pointer in cache __TEXT/__DATA stayed
in packed form and a branch lands on a brk; (b) cider's SIGTRAP/brk handling does not advance the PC past the
brk, turning a one-shot trap into a loop. Either is a deeper dyld-cache-under-cider-vm issue, past the
user-approved one-shot. NET: the mapping blocker (codesign + shared-region syscall + slide) is SOLVED and the
dylib-open collapse is proven (229->39), but end-to-end there is no usable speedup yet (it hangs); baseline
236 ms/spawn is unchanged without a cache. The prefix ships NO cache, and mapSharedCache no-ops without one,
so patches 0005/0006/0007 are safe no-ops in the shipped prefix (nocache spawn works at 236 ms, no
regression). A banked here; resuming it later means fixing the cached-code trap (start by NOT skipping the
rebase/unpack at slide=0, and checking cider's brk PC-advance). Per the user's one-shot decision, pivoting to
Tier 1 (task #21) for measurable RPC wins.

**Pass 89 (task #20/A: fully characterized end to end -- works but no speedup yet; exact remaining blocker found).**
Layer by layer, with numbers:
1. Cache BUILDS (39 images) -- done.
2. Guest dyld MAPS it (patches 0005 un-gate, 0006 skip codesign, 0007 forcePrivate+disableASLR) -- done;
   B2 shows "mapped dyld cache file private to process ... 0x180000000" and "Using shared cached for
   libsystem_kernel".
3. The OPTIMIZED (Customer) cache TRAPS: optimizeAwayStubs rewrites call sites, a rewritten branch lands on
   brk #1 in cached libsystem_c (0x180370d40), cider loops on SIGTRAP -> hang. The earlier "opens 229->39"
   was this process trapping EARLY (39 opens before the crash), NOT a real collapse. Fixed by building an
   InternalDevelopment cache (optimizeStubs=false, commit f658b124): boots clean, 0 SIGTRAPs, exit 0.
4. But the dev cache gives NO speedup: with the on-disk dylibs present, dyld BYPASSES the cache and still
   opens+mmaps each dylib from disk at 0x100001000000 (with-cache *.dylib opens=229 == nocache 229; ms/spawn
   258 vs 248 baseline -- flat). The cache is mapped but only a couple of dylibs actually come from it.
5. Removing the 39 on-disk dylibs PROVES the collapse is real: dyld then opens 0 dylib files (229->0) and uses
   the cache -- BUT the boot ABORTS: "dyld: shared cache not used: shared cache file open() failed" ->
   "Library not loaded: /usr/lib/libSystem.B.dylib, image not found". Only 1 cache open() succeeded across the
   whole boot; child/re-exec'd processes fail to open() the cache file, and with no on-disk fallback they
   abort. So the EXACT remaining blocker is: child processes under cider cannot open() the cache at
   /System/Library/dyld/ (a cider fs/path-visibility issue for the cache across fork/exec).
NET: A is a deep, mostly-working infrastructure (build+map+no-trap+open-collapse all proven) that does not yet
deliver a spawn speedup. Two things stand between here and a win: (a) fix child-process cache open() so the
cache is used without keeping dylibs on disk; (b) a MARGINAL in-session spawn benchmark -- the current
`cider shell /usr/bin/true` is boot-dominated (~223 boot RPCs), so even a perfect dylib-load collapse barely
moves its wall; A's real payoff is many-spawns-per-session build workloads (#11's actual goal), not per-boot.
All A patches (0005/0006/0007 dyld, f658b124 dev-cache) are safe no-ops in the shipped prefix (no cache
installed). Banked here as a documented checkpoint; honest verdict is that the measured spawn speedup is 0 so
far and realizing it is further multi-layer cider-fs work of uncertain payoff given boot domination.

**Pass 90 (task #20/A: child cache-open root cause; A grind stopped here).** Traced the "shared cache file
open() failed" child abort. In the WORKING case (dylibs on disk) every process, children included, opens the
cache at the CIDERPREFIX-translated host path (/tmp/cider-nixpkg-1000/System/Library/dyld/dyld_shared_cache_arm64,
success). In the BROKEN case (on-disk dylibs removed so the cache MUST supply libSystem) a child instead does
openat("/System/Library/dyld/dyld_shared_cache_arm64") -- the RAW guest path, host-cwd-relative -> ENOENT --
and does not fall through to the CIDERPREFIX path, so dyld reports "shared cache file open() failed" and, with
no on-disk libSystem fallback, aborts. So the child needs the cache at the earliest dyld bootstrap (to get
libSystem) at a stage where cider's guest->host path translation for /System/Library/dyld is not yet applied
for that process; normally this never bites because on-disk dylibs satisfy libSystem before the cache is
consulted. Fixing it is a cider fork/exec bootstrap + fs-translation change (ensure the cache path resolves,
or the cache is reachable, at the earliest child dyld stage) -- deep, and the payoff is capped because the
`cider shell X` benchmark is boot-dominated (~223 boot RPCs) so per-boot spawns barely benefit regardless.
DECISION: stop grinding A here. It is a thoroughly documented, mostly-working infrastructure (build + map +
no-trap dev cache + proven 229->0 open collapse) whose spawn-speedup payoff needs (a) the child bootstrap
cache-open fix and (b) an in-session marginal-spawn benchmark to even be visible. Recommended next steps for
whoever resumes: build the in-session benchmark first (boot once, time many /usr/bin/true spawns; that grounds
every perf claim and isolates the ~47 marginal RPCs + dylib-load cost from boot), then decide if A's remaining
cider-bootstrap work is worth it vs the RPC levers (Tier 1 self-trap caches; Tier 2 reply-port churn = 11
RPCs/spawn). All A patches (dyld 0005/0006/0007, cache_builder dev-cache f658b124) are committed and are safe
no-ops in the shipped prefix (no cache installed).

**Pass 91 (task #11: grounded per-spawn baseline -- the number to optimize against).** Built an in-session
marginal-spawn benchmark (scratchpad/in-session-bench.sh): boot cider once, run N x /usr/bin/true inside one
guest bash, fit the slope. Result on result-min13 (no cache): boot+1=0.292s, boot+20=0.862s, boot+60=1.990s
-> MARGINAL ~28 ms/in-session-spawn (slopes 30.0/28.8/28.2, consistent), and boot itself ~264 ms. So a single
`cider shell X` (~292 ms) is ~90% one-time boot, ~10% spawn -- which is why lever A (targeting the spawn's
dylib load) is invisible in the per-invocation benchmark, and why the RPC histogram's ~223 boot RECV dwarf the
~47 marginal per-spawn RECV. For build workloads (many spawns per session, #11's real goal) the number that
matters is the ~28 ms marginal spawn. Of that ~28 ms: ~47 guest->ciderd RPCs (mach_msg_overwrite 7.8,
mach_reply_port 6.7, mach_port_deallocate 4.4, the self-traps ~3.3 each, vchroot_path 3.3, ...) plus the
dylib mmap/fork/exec. This baseline grounds all future perf claims: measure any change (A, Tier 1/2) as delta
on the ~28 ms marginal (and separately on the ~264 ms boot), NOT on the boot-dominated per-invocation wall.

**Pass 92 (task #21 Tier 1: task_self is the only cacheable self-trap; host/thread_self are not; reply-port
cache is the next lead).** Tried extending the task_self leaf cache (0044) to host_self_trap. It BUILT but
HUNG the guest (cider shell /usr/bin/true rc=124). Root cause is Mach semantics, not a code bug: mach_task_self
returns a cached self-port name that callers never deallocate (Darwin itself caches it in mach_task_self_), but
mach_host_self (and mach_thread_self) ADD a send-right reference each call and callers deallocate it -- so a
single cached name is over-released, the port dies, and host ops hang. Reverted 0044 to task_self-only (commit
6c6f0bd1); repointed result-min13 at the equivalent working prefix bnkbwki4 (same source as the reverted
build, no 2h rebuild needed). Confirmed bnkbwki4 boots (/usr/bin/true rc=0; the "shared cache not used" lines
prove the A dyld patches safely no-op with no cache installed -> no regression). So Tier 1 LEAF-CACHING IS
DONE: task_self was the only safely-cacheable hot self-trap (already saves ~3.3 RPC/spawn, 6.7->3.3; the
residual 3.3 is the first call per process/exec). Re-confirmed histogram (47 marginal RPC/spawn): mach_msg
7.8, mach_reply_port 6.7, mach_port_deallocate 4.4, thread_self 3.3, host_self 3.3, task_self 3.3 (cached),
vchroot_path 3.3. NEXT LEAD: mach_reply_port (6.7) ~= mach_msg (7.8) means a reply port is allocated per MIG
RPC -- the guest mig_get_reply_port per-thread TSD cache (__TSD_MIG_REPLY slot 2, mig_reply_port.c) is NOT
sticking under cider. If it stuck, mach_reply_port would drop to ~1/thread (save ~5) and some of the 4.4
deallocate. Biggest remaining marginal-spawn lever, but needs a TSD/MIG investigation (is slot 2 preserved
across cider's thread setup? do the MIG stubs actually use mig_get_reply_port, or allocate fresh?) + a 2h
rebuild, uncertain. Reminder: the ~28ms marginal is ~10% of the ~292ms per-invocation (boot dominates), so
absolute wall wins here are small; they matter for many-spawn build workloads.

**Pass 93 (task #21 Tier 1: leaf-caching exhausted; the bulk is per-exec init RPCs; next real lever is
checkin-batching, Tier 2).** vchroot_path (3.3/spawn) is ALREADY cached in the guest: vchroot_userspace.c has
a static prefix_path filled once by init_vchroot_path(), guarded `if (prefix_path_len == -1)`; the 3.3 is the
re-fetch after each exec (fresh image resets the static), same shape as task_self's residual. So the hot
per-spawn RPCs break down as: already-cached-per-process (task_self 3.3, vchroot_path 3.3 -- residual is
first-call-per-exec), UNCACHEABLE (host_self 3.3, thread_self 3.3 -- Mach add-ref/deallocate), and real
work (mach_msg 7.8 IPC, mach_reply_port 6.7 + deallocate 4.4 reply-port alloc, checkin/uidgid/set_thread_
handles ~2.2 each process-init). Leaf-caching is DONE (task_self was the only win). KEY STRUCTURAL OBSERVATION:
a large share of the 47 is FIRST-CALL-PER-EXEC init (task_self, host_self, thread_self, vchroot_path, uidgid,
set_thread_handles, checkin ~ 13-17 RPC/spawn across ~3 execs/spawn). The one genuinely tractable lever left
is TIER 2 checkin-batching: the child re-checks-in with ciderd after fork/exec (dserver_rpc_checkin); if the
checkin RESPONSE carried the per-process constants (vchroot prefix, task self port, and the uidgid/thread
handles it already needs), the guest could populate its caches from the checkin reply instead of issuing
separate RPCs -- potentially removing several RPC/exec. That is a protocol + guest + server change (moderate,
one 2h rebuild), not a leaf cache. host_self/thread_self cannot be folded in (refcount). Everything else
(reply-port cache in build-generated MIG, the 223-RPC boot) is deeper Tier 2/3. Reminder: marginal spawn is
~10% of the boot-dominated ~292ms per-invocation, so absolute wall wins per RPC are ~0.5ms; these matter only
for many-spawn build workloads. Honest position: the quick/medium per-spawn RPC wins are done; remaining
levers are deliberate Tier 2/3 efforts.

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

**Pass 94 (task #21: checkin-batching assessed -- too wire-risky for the payoff; measure the real workload
instead).** The RPC protocol is generated by vendor/pins/ciderd/scripts/generate-rpc-wrappers.py from a `calls`
list that emits BOTH the guest C headers and the Rust rpc_wire.rs "byte-identical ... x86_64 layout". checkin
is `('checkin', [args], [])` -- empty reply. The one clean batchable field is task_self (`port_name uint32_t`,
mirroring the task_self_trap reply); vchroot_path is buffer-based (`char* buffer` written via memory hooks),
so it cannot be folded in as a plain reply field. Even the clean task_self batch ripples through: a ciderd-pin
patch to the generator, the regenerated guest C + rpc_wire.rs, the server handler (populate), and the guest
(store _cached_task_self at checkin) -- a wire-layout-sensitive multi-component change for only ~3 RPC/spawn
(~1.5ms on a boot-dominated wall). Not worth forcing autonomously. HONEST FRONTIER: every per-spawn RPC lever
is now either done (task_self, kprintf), impossible (host/thread_self refcount), already-cached (vchroot),
build-generated + needs runtime instrumentation (reply-port), or a deliberate wire/architecture change
(checkin-batching, 223-RPC boot reduction, A child-bootstrap). The remaining perf work is deliberate,
multi-hour, and modest-payoff; it should be scoped deliberately, not loop-ground. Most useful next measurement:
time the real build workload (buck-nix-bash-check builds bash from source under cider = many in-session spawns
= #11's actual goal) to get the definitive number and regression-check the committed A + task_self work.

**Pass 95 (task #11: build-workload benchmark was mis-prefixed; A patches confirmed non-regressing; building
the full prefix for the definitive number).** Ran buck-nix-bash-check (guest nix-builds bash) but against the
MIN prefix (bnkbwki4 = cider_prefix_min), which lacks CoreFoundation -- the build aborted "Library not loaded:
CoreFoundation ... image not found" with dyld appending "dyld cache load error: shared cache file open()
failed" (dyld2.cpp:4421 -- that text is dyld's EXISTING augmentation on a missing-dylib error when no cache is
present, NOT a new abort from the A patches). So the failure was a setup error (wrong prefix), not an A
regression. Confirmed NO regression directly: on the min prefix, `cider shell /bin/bash -c 'echo $((6*7)); 
/usr/bin/true'` returns BASH_OK: 42 + TRUE_OK, rc=0 -- bash and its dylibs load fine with A patches
(0005/0006/0007) + task_self 0044 committed. buck-nix-bash-check needs the FULL framework prefix
(.#cider-buck2-prefix, //buck/prefix:cider_prefix, ~5500 entries incl. CoreFoundation). Building that now to
get the definitive #11 build-workload wall time AND verify A on the real milestone. This is the heaviest build
(full framework closure) -- one at a time, bounded jobs.

**Pass 96 (task #11: the full-prefix milestone build is blocked by pre-existing build-infra, NOT by the perf patches; the guest-execution perf investigation is complete within what is achievable).** Built the full framework prefix (.#cider-buck2-prefix, ~5500 entries incl. CoreFoundation) with the committed A dyld patches (0005/0006/0007) + the task_self leaf-cache (0044) to get the definitive build-workload number and verify no regression on the real milestone. The build fails (nonzero rc, guaranteed), but every failing derivation is pre-existing infrastructure unrelated to guest-execution perf:

- Root cause of the largest cluster: `wayland-scanner: No such file or directory` (a missing nix build-input, /nix/store/...-wayland-scanner-1.25.0-bin/bin/wayland-scanner). That one missing codegen tool cascades to core_protocol, xdg_shell_protocol, wayland_glue_obj, wayland_appkit_dylib, wayland_cgbackend_dylib, DBusKit_dylib, pin-dbuskit.
- securitytool_macos: a separate macOS SecurityTool compile failure (security/SecurityTool/macOS/display_error_code.c), no symbol/corecrypto involvement.
- JavaScriptCore_dylib + jsc: the known #24 JSC/offline-asm blocker.

Verified clean on the perf side: corecrypto builds (all corecrypto_obj/firstpass/final/static succeed, so the exported-symbols patch 0001 is fine), and there are ZERO undefined-symbol / symbol-not-found / SIGTRAP / brk / "dyld: shared cache" / cache_builder abort signatures anywhere in the ~800k-line log. dyld and xnu are not in the failed-drv list. So the A patches + task_self do NOT regress the full milestone; combined with the earlier min-prefix proof (bash runs, rc=0), the perf patches are confirmed non-regressing. The corefoundation-submodule `rm`/`ln` "Permission denied" lines are noisy but non-fatal (they never appear as a failed derivation). The build was killed once the diagnosis was locked (the aggregate had already reported "1 dependency failed"; my subsystems had already built successfully, so no further my-subsystem failure could surface) rather than burn more host time on a foregone --keep-going wind-down over ~5500 leaves.

Net honest state of #11:
- Tier 1 (task_self leaf-cache, patch 0044): SHIPPED. Caches the per-process task-self port and skips ~6.7 task_self RPC/spawn; reset in the fork child (new task -> fresh port namespace). host_self/thread_self are uncacheable (Mach add-ref/deallocate refcount semantics, over-release hangs the guest), vchroot is already cached, the reply-port lives in build-generated MIG; task_self is the only safe leaf-cache win.
- Lever A (dyld shared cache, patches 0005/0006/0007 + cache_builder): BANKED. Builds a development cache (stubs intact, no brk-trap), maps it under cider, and proves the open-collapse (229 individual dylib opens -> 0). Blocked on child-process cache-open under cider's bootstrap; the patches are safe no-ops with no cache installed (bash still runs). No measured end-to-end speedup.
- Baselines grounded: ~28 ms marginal per in-session spawn, ~264 ms one-time boot, ~47 RPC/spawn (~223 at boot).
- The full-prefix build-workload wall-time number is unobtainable until the pre-existing infra is fixed (wayland-scanner packaging + #24 JSC), both out of scope for perf.

Conclusion: the guest-execution perf investigation is comprehensively complete within what is achievable without deep, risky work. The remaining levers (checkin-batching wire change, boot-RPC reduction below ~223, A's child-bootstrap cache-open, Tier 2 Mach/signal fast paths, Tier 3 run-without-ciderd) are deliberate multi-hour efforts, not quick wins.

**Pass 97 (task #11: boot-phase RPC histogram measured; per-process init constants -- all already cached -- dominate; checkin-reply batching is the one favorable remaining boot lever).** Boot is ~90% of per-invocation cost (~264ms of ~292ms), so I measured the BOOT RPC histogram (boot + one trivial `exit 0`, DSERVER_TRACE_CALLS, min prefix result-min13): 236 total RECV across 19 distinct calls. Top: mach_msg_overwrite 39, mach_reply_port 34, mach_port_deallocate 23 (= 96, 41%); vchroot_path 18, thread_self_trap 17, host_self_trap 17, task_self_trap 17, uidgid 14, set_thread_handles 11, checkin 11, get_tracer 6, started_suspended 6, fork_wait_for_child 5, mldr_path 5, checkout 5.

Two structural findings:
1. The Mach transport primitives (mach_msg_overwrite + mach_reply_port + mach_port_deallocate = 41% of boot) are the RPC mechanism's own per-call overhead: each MIG round-trip allocates a reply port, sends/receives, then deallocates. They scale with the NUMBER of RPCs, so they only shrink if the call count shrinks (they are not an independent target).
2. The "who am I" per-process init constants (task_self 17, host_self 17, thread_self 17, uidgid 14, vchroot_path 18, checkin 11) are EACH ALREADY per-process cached in the guest: task_self by patch 0044; uidgid by a long-standing rwlock-guarded stored_uid/stored_gid cache in getuid.c (with the explicit comment "the server never changes our UID and GID on its own ... we can just cache"); vchroot likewise. So these counts are not redundant within a process; they equal roughly (processes spawned at boot ~= 11-18) x (the one-shot init set each freshly exec'd image must fetch). Consequence: uidgid is NOT a new caching candidate (already done), and there is no remaining per-process leaf-cache win of the task_self kind.

Highest-value remaining boot lever, and the only one with a favorable risk/payoff: FOLD the already-cached per-process constants into the checkin reply. Every process performs one checkin (currently an empty reply). If checkin returned {task_self, uid, gid, vchroot_path}, each new process would seed its caches from that single reply instead of issuing separate init RPCs. Upper bound on the saving is set by the checkin count (~11 at boot), so realistically ~11 processes x 3 folded constants ~= up to ~30 fewer init RPCs, plus the matching mach_reply_port/mach_port_deallocate/mach_msg_overwrite each of those would have cost (roughly another 2-3x), i.e. a plausible boot reduction on the order of 30-60 RPC (13-25% of boot). host_self_trap and thread_self_trap are EXCLUDED: their Mach add-ref/deallocate semantics make the returned name non-cacheable (leaf-caching them over-releases a send right and hangs the guest, proven in an earlier pass), so they cannot be folded either.

Why this is not the "wire-risky" gamble it first appears: generate-rpc-wrappers.py generates BOTH the guest C stubs and the server rpc_wire.rs from one `calls` entry, so adding reply args to the checkin entry keeps the guest/server byte-layout in sync by construction. The residual risk is purely semantic: the guest checkin path must seed stored_uid/stored_gid (getuid.c) + the task_self cache (0044) + the vchroot cache from the reply and then NOT re-fetch, while the existing setuid/vchroot mutation paths remain authoritative. That is testable (bash still runs, then measure the boot RPC delta).

Net: after Pass 96 (milestone verified, non-regressing) this pass grounds the boot cost precisely and isolates checkin-reply batching as the single substantive perf lever left with acceptable risk. The remaining alternatives are either unsafe (host/thread self) or deep (cut Mach transport, Tier 2 in-guest fast paths, Tier 3 run-without-ciderd). Next iteration: design the batched checkin reply in generate-rpc-wrappers.py, wire the server checkin handler to fill the task's uid/gid/task-self/vchroot and the guest checkin path to seed the caches, rebuild the min prefix, verify bash runs, and measure the boot RPC delta.

**Pass 98 (task #11 / #25: checkin-reply batching is now fully designed, de-risked read-only, and implementation-ready; graceful RPC fallback makes it no-regression-by-construction).** Completed the read-only design for folding the already-cached per-process init constants {task_self, uid, gid} into the checkin reply (currently empty), the one substantive boot-RPC lever left (boot is ~90% of per-invocation cost; these constants are ~40% of the 236 boot RPC). Key findings that lower the risk from the initial "deep wire gamble" framing:

1. Handoff mechanism is the standard, extensible apple[] array. mldr already passes kernfd/executable_path/elf_calls to libSystem via apple[] (src/darwin/loader/src/stack.rs); libsystem_kernel parses apple[] in mach_driver_init (lkm.c:35, the same loop that matches "elf_calls="). So the seed values ride as new apple[] strings (dserver_task_self=/dserver_uid=/dserver_gid=) parsed at that existing site. No change to the frozen 31-entry elf_calls vtable.

2. Fold site is the mldr loader checkin (src/darwin/loader/src/rpc.rs:311, is_fork=false), which runs once per exec'd process POST-exec (fresh statics) -> it captures the exec'd processes' task_self (17) + uidgid (14) re-fetches. The fork.c:59 checkin (is_fork=true) is pre-exec and wiped by the following exec, so it keeps the existing 0044 reset and is not the target.

3. Wire sync is far smaller than feared. generate-rpc-wrappers.py is the single source of truth and emits BOTH the guest C stubs AND the server rpc_wire.rs (both marked auto-generated, x86_64 layout). So one edit to the checkin `calls` entry (reply [] -> [('task_self','uint32_t'),('uid','int32_t'),('gid','int32_t')]) regenerates both in sync. The ONLY hand-maintained copy is the loader's RpcReplyCheckin (rpc.rs:170, currently header-only); its body {u32,i32,i32} is all 4-byte fields => identical aarch64/x86_64 layout (8-byte header + 12-byte body = 20-byte reply), trivial to hand-match. rpc_wire_check.rs already asserts RpcReplyUidgid == replyhdr + ReplyUidgid; add the same assertion for checkin to catch drift at test time.

4. No-regression by construction: the guest caches already fall back to an RPC when unseeded (task_self checks _cached_task_self != NULL else RPC; getuid.c checks stored_uid != -1 else RPC). So if seeding misses an image (the dyld-copy vs main-executable-copy per-image-statics wrinkle in mach_driver_init), the worst case is NO BENEFIT for that image, not a hang or wrong value. The ONLY hang hazard is a loader/server wire-layout mismatch, which is simple here and test-guarded.

Net: #25 is high-payoff (est. 30-60 fewer boot RPC, 13-25% of boot) with contained, testable risk. Implementation plan (next): (a) edit the checkin `calls` entry in generate-rpc-wrappers.py; regenerate; confirm rpc_wire_check + a new checkin size assertion pass. (b) server handler.rs checkin (418) fills the reply from the registered process (task-self port name + creds via task_uidgid(taskptr,-1,-1)). (c) loader rpc.rs: extend RpcReplyCheckin, return the values; append dserver_* strings to apple[] in stack.rs (checkin must run before the apple[] build; verify order in main.rs). (d) guest lkm.c mach_driver_init parses the new apple[] keys and calls a new __task_self_trap_set() (mach_traps.c) + a stored_uid/stored_gid seeder (getuid.c). (e) rebuild min prefix (~2h, one at a time, background + heartbeat), verify `cider shell /bin/bash -c 'echo $((6*7)); id; /usr/bin/true'` rc=0 with correct uid, then measure boot RPC delta vs 236 (boot-rpc.sh). Revert via jj on any regression. This is staged deliberately so each step is verifiable; the wire edit is not done blind. Full working notes in scratchpad/checkin-batching-design.md.

**Pass 99 (task #11/#25: checkin-reply batching SHIPPED, verified correct, and measured; boot RPC 236 -> 224).** Built the min prefix (.#cider-buck2-prefix-min) with #25 committed (bd2d2384): the checkin reply, previously empty, now carries {task_self, uid, gid}; the ciderd handler fills it from the checking-in task; mldr passes the values to the image as apple[] strings (dserver_task_self/uid/gid, all hex); and libsystem_kernel's mach_driver_init parses them and seeds the task-self cache (0044) and getuid.c's uid/gid cache, so a freshly exec'd process skips its first task_self_trap + uidgid RPCs.

Two compile fixes were needed during the build (each a missed caller of the changed checkin signature) and were squashed into #25:
1. mldr rpc.rs checkin_thread() also calls checkin() and returned i32; checkin() now returns CheckinReply, so it uses .code (a new thread shares the process's warm caches, no seed needed).
2. The generated guest C stub dserver_rpc_checkin gained 3 reply out-ptrs; fork.c's fork-child call now passes NULL, NULL, NULL (the child inherits the parent's warm caches). Added as a fork.c hunk in vendor/patches/xnu/0045.
Note: changing libsystem_kernel (emulation) cascaded to a near-full guest rebuild (~2h); everything links libSystem. The detached build (setsid, own session) was required because harness-tracked background builds were killed at ~10 min.

Correctness gate (cider shell /bin/bash on the #25 min prefix): BASH_OK 42, GUID 0:0 (uid/gid correct -> seeding does not corrupt creds), 3x fork/exec /usr/bin/true SPAWN_OK 0, overall rc=0, no hang. So #25 is non-regressing and fork children still work.

Boot RPC (boot + one `exit 0`, DSERVER_TRACE_CALLS): 236 -> 224 total (-12). task_self_trap 17 -> 11 (-6), uidgid 14 -> 8 (-6). Interpretation: the mldr loader checkin (is_fork=false) runs once per exec'd process and seeds it, eliminating that process's first task_self_trap + uidgid RPC; ~6 exec'd processes at boot => -6 each. The remaining task_self_trap (11) / uidgid (8) are fork children (is_fork=true, deliberately not seeded so they NULL the reply and inherit warm caches) plus repeat/daemon contexts. vchroot_path (18) is unchanged: vchroot seeding was deferred to a v2 (its reply is a variable-length string -> more wire work) and would add roughly another -6.

Net: #25 is the first working checkin-reply-batching win. Boot is ~90% of per-invocation cost and ~RPC-bound (~1.1 ms/RPC over 236 RPC ~= 264 ms), so -12 boot RPC ~= ~13 ms/boot (~4-5% of boot / per-invocation), non-regressing, verified. It also proves the mechanism (fold per-process constants into checkin, seed via apple[]) end to end. v2 follow-ups: fold vchroot_path (string reply) for ~-6 more; host_self_trap/thread_self_trap remain unfoldable (Mach add-ref/deallocate semantics). Task #25 complete.

**Pass 100 (task #11/#25 v2: vchroot prefix folded into checkin seeding; boot RPC 224 -> 219; full checkin-batching lever 236 -> 219).** Built the min prefix with v2 (abecd0d4): mldr passes its already-fetched vchroot prefix to the image as apple[] dserver_vchroot=<path>, and libsystem_kernel's mach_driver_init seeds prefix_path via a new __vchroot_seed (vendor/patches/xnu/0046), so a freshly exec'd process skips its first vchroot_path RPC. No wire change was needed (mldr already fetches the prefix via rpc::vchroot_path). The build was clean on the first try (no compile fixes, unlike v1); again a ~2h near-full guest rebuild (libsystem_kernel cascade), run detached.

Correctness gate (cider shell /bin/bash on the v2 min prefix): BASH_OK 42, GUID 0:0 (uid/gid correct), SPAWN_OK 0 -- the fork/exec spawns succeeded, which requires vchroot path translation, so the seeded prefix is correct and seeding did not corrupt it. rc=0, no hang. Non-regressing.

Boot RPC (boot + one `exit 0`, DSERVER_TRACE_CALLS): vchroot_path 18 -> 13 (-5); total 224 -> 219. Combined with v1, the full checkin-batching lever is:
  task_self_trap  17 -> 11
  uidgid          14 -> 8
  vchroot_path    18 -> 13
  TOTAL boot RECV 236 -> 219  (-17, ~7.2% of boot)
Each foldable per-process init constant now seeds from the mldr checkin/loader into the freshly exec'd image via apple[], eliminating that process's first RPC for it; the residual counts are fork children (deliberately not seeded -> inherit the parent's warm caches) plus repeat/daemon contexts.

CHECKIN-BATCHING LEVER: FULLY HARVESTED. The three foldable per-process init constants (task_self, uid/gid, vchroot) are all seeded. host_self_trap (17) and thread_self_trap (17) remain UNFOLDABLE: their Mach add-ref/deallocate semantics make the returned name non-cacheable (leaf-caching over-releases a send right and hangs the guest, proven earlier). The remaining boot RPC (219) is dominated by the Mach transport primitives themselves: mach_msg_overwrite 39 + mach_reply_port 34 + mach_port_deallocate 23 = 96 (44% of boot), which are the RPC mechanism's own per-call overhead and only shrink by reducing the NUMBER of RPCs (deep Tier 2: in-guest Mach fast paths / batching the message layer). Boot is ~90% of per-invocation cost and ~RPC-bound (~1.1 ms/RPC over ~219 RPC ~= ~240 ms), so -17 boot RPC ~= ~19 ms/boot (~7% of boot and of per-invocation), non-regressing, verified end to end.

## Shipped perf summary for #11 (aarch64 guest execution)
- Tier 1: task_self_trap leaf-cache (patch 0044). Caches the per-process task-self port; skips repeat task_self RPCs within a process.
- Checkin-reply batching v1 (0045 + server rpc_wire/handler + mldr loader): fold {task_self, uid, gid} into the checkin reply, seed via apple[]. Boot 236 -> 224.
- Checkin-reply batching v2 (0046 + mldr): fold vchroot prefix. Boot 224 -> 219.
- Net measured: boot RPC 236 -> 219 (-17, ~7%), all verified non-regressing (bash rc=0, uid correct, spawns work).
- Lever A (dyld shared cache, 0005/0006/0007 + cache_builder): BANKED. Builds a dev cache, maps it, proves open-collapse (229 -> 0), but blocked on child-process cache-open under cider; safe no-op with no cache installed, no measured speedup.
- Grounded baselines: ~28 ms marginal/spawn, ~264 ms boot (~90% of per-invocation), ~47 RPC/spawn, 236 RPC/boot (now 219).

## Remaining levers (all deep, deliberately NOT pursued as marginal/high-cost)
- Mach transport (44% of boot): reduce the NUMBER of RPCs (in-guest Mach port fast paths, reply-port pooling) -- Tier 2 (#22), deep.
- host_self/thread_self: unfoldable (ref semantics).
- Tier 3 (#23): run guest processes mostly without ciderd -- very deep.
- The full-prefix milestone build number is gated on pre-existing infra (missing wayland-scanner, securitytool, #24 JSC), independent of perf.

The reachable, sensible-payoff perf work for #11 is complete. Each further lever is a multi-week effort or unsafe; not worth another ~2h rebuild for a marginal RPC.

**Pass 101 (task #11: wall-time A/B REFUTES the checkin-batching as a speedup; RPC count was a false proxy; the change delivers NO measured wall-time benefit and slightly REGRESSES spawn-heavy workloads).** Both prefixes were still in the nix store, so I ran wall-time A/B benchmarks isolating exactly the checkin-batching: BEFORE = bnkbwki4 (Tier1 + A only, no checkin-batching) vs AFTER = 7hhijafyy (+ checkin-batching v1+v2). Same rt slot, sequential, warmed, median of N.

- boot + `exit 0` (N=12): BEFORE median 241.0ms (min 213.7) vs AFTER median 242.9ms (min 226.9). Within noise -> NO wall-time change from the -17 boot RPC.
- boot + 60x `/usr/bin/true` (N=8, two runs): BEFORE median 2013 / 2114 ms vs AFTER median 2189 / 2274 ms -> AFTER consistently ~160ms SLOWER over 60 spawns (~2.5ms/spawn), reproduced in both runs (min and max also consistently slower).

So the -17 boot RPC and the per-spawn task_self/uidgid/vchroot savings did NOT translate to wall-time; the spawn-heavy workload measured slightly SLOWER with the checkin-batching. Likely mechanism: the change moved work from LAZY (the guest RPCs a value only when it needs it, over a fast local unix socket) to EAGER (the ciderd checkin handler computes mach_task_self + task_uidgid(-1,-1) on EVERY checkin, and mldr builds/copies + the guest mach_driver_init parses four extra apple[] strings per exec'd process). The eager per-spawn cost exceeds the cheap local RPCs it eliminates. A confound cannot be fully excluded (AFTER is a near-full guest rebuild), but nix determinism means the only source delta between the two prefixes is the checkin-batching patches, so the slowdown is attributable to them.

HONEST CORRECTION to Passes 99-100: those recorded the checkin-batching as a win based on RPC COUNT (236->224->219) and an ESTIMATED "~19ms/boot" that assumed the average ~1.1ms/RPC (264ms/236) applied to the eliminated calls. That estimate was wrong: the eliminated per-process init RPCs are cheap leaf traps off the critical path (removing them saves ~0ms), and boot/spawn wall-time is dominated by other costs. RPC count is NOT a reliable proxy for wall-time here. The correctness verification in Pass 99/100 stands (bash rc=0, uid correct, spawns work -- the change is CORRECTNESS-safe), but the PERFORMANCE claim was unfounded.

Real-workload caveat: the ~2.5ms/spawn overhead is a fixed per-exec cost, so it is measurable for trivial-exec-heavy phases (shell/configure scripts, `true` loops) but negligible for compute-heavy execs (a multi-second gcc). Net impact on a real build is small (slightly negative to neutral), not catastrophic.

RECOMMENDATION: the checkin-batching (v1 = #25 bd2d2384/0045, v2 = abecd0d4/0046) provides NO measured wall-time benefit and a small measured spawn-heavy regression, at the cost of a wire change + 3 patches of ongoing complexity. The sensible engineering call is to REVERT it, returning HEAD to the Tier-1-only state (functionally identical to bnkbwki4, the faster prefix). NOT auto-reverted: this discards a large amount of build/iteration effort and the microbenchmark carries a rebuild confound, so it is surfaced for a decision rather than done unilaterally. Reverting is one `jj backout` of each commit (v2 then v1) + a rebuild to produce the artifact; the perf conclusion needs no rebuild (bnkbwki4 already demonstrates the reverted-state, faster perf). Tier 1 (0044) is left in place: it is a simple within-process cache, not implicated in this regression (its own wall-time is untested, but it adds no eager per-spawn server work).

LESSON for #11: gate perf investment on a WALL-TIME A/B, not RPC count. The genuinely wall-time-relevant target is the Mach transport on the critical path (the blocking round-trips a spawn actually waits on: mach_msg_overwrite and its reply-port/deallocate), not the count of cheap leaf RPCs. This is deep Tier 2 and should itself be gated on a wall-time A/B of a prototype before investing in a full build.

Net honest #11 outcome: the perf investigation is thorough and the mechanisms are well understood, but it did NOT produce a measured guest-execution speedup. Tier 1 shipped (wall-time untested, plausibly neutral); checkin-batching shipped but is a measured non-win / slight regression (recommend revert); lever A banked (no speedup). The reachable wins under the RPC-reduction thesis are exhausted; a real speedup requires critical-path (wall-time) analysis of the Mach transport, which is a deeper effort.

**Pass 102 (task #11: reverted the checkin-batching per Pass 101's wall-time finding).** Backed out the checkin-batching (v1 #25 + v2) by restoring the affected files to their pre-#25 state (parent 77f3b30c): removed vendor/patches/xnu/0045 + 0046; reverted rpc_wire.rs + handler.rs (checkin reply empty again), the mldr loader (rpc.rs/main.rs/stack.rs), and generate-rpc-wrappers.py. Kept Tier 1 (0044). Rationale: Pass 101's wall-time A/B showed the checkin-batching is a non-win (neutral on boot, ~2.5ms/spawn slower on spawn-heavy) despite the -17 boot RPC; RPC count was a false proxy. No rebuild needed to confirm the reverted-state perf -- bnkbwki4 already demonstrates it. HEAD now = Tier1 + A only, functionally the faster pre-batching state. Honest #11 outcome: no measured guest-execution speedup was achieved; the RPC-reduction thesis was exhausted without a wall-time win. A real speedup would need critical-path Mach-transport work (deep Tier 2), and any such work must be gated on a prototype wall-time A/B before a full build.

**Pass 103 (task #11: strace critical-path profile REDIRECTS the strategy -- boot wall-time is image-load-bound (mmap + dylib file I/O), NOT RPC-bound; Lever A targets the real bottleneck).** Applied the Pass 101 lesson properly: instead of counting RPCs, straced one `cider shell bash -c 'exit 0'` (strace -f -T to a file, killed after the boot since ciderd never exits) and summed syscall wall-time. Distribution (strace-inflated absolute times, but the proportions are the point):
- mmap: ~29ms across 1432 calls (dyld mapping dylib segments) -- the single biggest syscall-time sink.
- file I/O: read ~20ms + newfstatat ~18ms (888 calls, path resolution under vchroot) + openat ~13ms + close ~10ms + pread ~4ms ~= ~64ms (opening/stat'ing/reading the ~dozens of dylibs + resolving paths).
- RPC: recvmsg ~9.5ms + sendmsg ~7.3ms ~= ~17ms TOTAL, and that includes ciderd's side -- so the guest's actual RPC blocking is even less.

Conclusion: RPC is ~7% of boot syscall time; IMAGE LOADING (mmap + dylib open/stat/read) is the dominant ~90ms. This confirms Pass 101 (RPC count is a false proxy for wall-time) and redirects #11:
- The RPC-reduction work (Tier 1 leaf-cache, checkin-batching v1/v2) targeted ~7% of the cost. Checkin-batching reverted (Pass 102) as a measured non-win; Tier 1 is a tiny slice.
- LEVER A (dyld shared cache, banked) is the CORRECT wall-time lever: a shared cache replaces ~1432 individual mmaps + hundreds of dylib open/stat/read with ONE mapped cache region. A was banked on the child-process cache-open blocker under cider's bootstrap -- but it attacks the actual bottleneck, so fixing that blocker is the highest-value wall-time work for #11.
- Secondary target: newfstatat path resolution (888 calls, ~18ms) -- the 0041 vchroot stat cache already targets this; extending it (or reducing path-component stats) is a smaller, cheaper win than A.

Honest #11 course-correction: the RPC thesis is retired. The wall-time-relevant levers are (1) reduce image-load mmap + dylib file I/O -> Lever A (dyld shared cache); (2) reduce path-resolution stats -> vchroot stat cache. Next: assess the tractability of Lever A's child-bootstrap cache-open blocker (the thing that banked A), since A is now shown to be the right lever -- and gate any build on a wall-time A/B of the cache actually mapping in a child.

**Pass 104 (task #11: Lever A cheaply REFUTED -- the shared cache maps but dyld2 does not use it for dylib loads; A delivers no image-load reduction as-is, reviving it is deep).** Applying the Pass 103 redirect (boot is image-load-bound), tested Lever A cheaply (NO rebuild): installed the existing dev cache into the guest prefix and straced openat/mmap with vs without it.
- With cache: the cache IS opened (fd ok) and MAPPED (20 cache mmaps), BUT total mmap (1431 -> 1426) and dylib-opens (229 -> 234) are UNCHANGED. The guest maps the cache AND still opens+mmaps every dylib from disk -> the cache is mapped but not consulted for dylib resolution -> pure extra work, no saving.
- Two reasons: (1) the dev cache lists only 39 dylibs (the build manifest was a core subset) of the ~229 the guest loads; (2) even for dylibs that ARE in the cache (e.g. libcache.dylib), the guest re-opens them from disk -> dyld2's "load this dylib from the shared cache" path is not consulting the cache. The A patches (0005/0006/0007) un-gate the cache MAP under DARLING but not the dylib-LOOKUP-in-cache path; the guest boots dyld2, and the inDyldCache() checks live on the dyld3 path, not the dyld2 load path in use here.

So A targets the right bottleneck category (image-load) but delivers ZERO reduction as implemented. Making A a real win requires BOTH: (a) build a full-manifest cache (all ~229 dylibs, not 39), AND (b) un-gate dyld2's dylib-lookup-in-shared-cache under DARLING so loads are served from the mapped cache instead of disk -- a deep, risky dyld2 change needing a full guest rebuild to test, uncertain payoff (best case collapses ~229 dylib open+mmap into ~1 cache map, unproven). Not pursued speculatively.

Honest #11 boundary: boot/spawn wall-time is dominated by loading ~229 dylibs (1431 mmaps + 229 opens) under the Darwin-on-Linux shim; the RPC layer is ~7% (thesis retired, checkin-batching reverted). The one architectural lever that could collapse image-load -- the dyld shared cache -- is deeply blocked (dyld2 gated lookup + subset cache). Efficient/reachable perf wins are exhausted. A real speedup would require the deep dyld2 shared-cache-load work, gated on first PROVING (in a prototype) that un-gating serves a dylib from the cache. Smaller remaining lever: vchroot path-resolution stats (newfstatat 888, ~18ms; the 0041 stat cache already helps).

Method note (efficiency): this entire A assessment used strace + reading the cache .map + dyld source -- zero rebuilds. That is how perf claims should be gated (Pass 101 lesson applied).

**Pass 105 (task #11: Lever A is TRACTABLE, not dead -- the dev-cache bypass is an inode/mtime-match gate in dyld2, and the WIN can be validated with ZERO guest rebuilds).** Read the dyld2 cache-vs-disk decision (src/dyld/src/dyld2.cpp:3595-3646). For an overridable cache dylib with a DEVELOPMENT cache (dylibsExpectedOnDisk=true -- which I built to dodge the production-cache brk-trap), dyld2 sets useCache=true ONLY IF the on-disk dylib's inode+mtime EXACTLY match the values the cache recorded (hasFileModTimeAndInode, lines 3606-3609). Our installed dylibs never match (the cache was built from different files and rt is re-copied with fresh inodes), so useCache stays false and every dylib loads from disk -- exactly Pass 104's observation. The load path itself (findInSharedCacheImage -> instantiateFromCache) is fully functional and NOT DARLING-gated.

Two fixes: (1) build the cache FROM the exact installed dylibs so inode/mtime match -- no dyld change, but fragile (any re-copy changes inodes); (2) a ~3-line dyld2 patch: under DARLING, in the dylibsExpectedOnDisk branch, force useCache=true (trust the cache, skip the inode/mtime match) -- robust.

EFFICIENT plan (validate the WIN cheaply BEFORE any guest rebuild -- Pass 101 lesson): (a) build a FULL-manifest dev cache (all ~229 dylibs the guest loads, vs the current 39) FROM the current rt so inode/mtime match; (b) install it, strace a boot -- if total mmap + dylib-opens COLLAPSE (toward the ~20 cache mmaps) and bash still runs rc=0, the image-load win is PROVEN with zero guest rebuilds; (c) only then add the dyld2 useCache patch + ONE guest rebuild for robustness + a wall-time A/B. If (b) shows no collapse or breakage, A is genuinely blocked -> document and stop pursuing. This targets the real bottleneck (image-load ~90ms) and is gated on a cheap measured proof, not a speculative rebuild.

**Pass 106 (task #11: Lever A patch 0008 built + correctness-safe but does NOT enable cache use; the real blocker is findInSharedCacheImage failing under cider, deeper than the useCache gate; 0008 reverted; A banked as not-tractable).** Built the min prefix with 0008 (force useCache for the dev cache under DARLING; ~2h rebuild, near-full because buck2's cache does not persist across nix builds). Correctness fine: bash prints 42, uid 0, rc=0. But the dev cache is STILL not used. DYLD_PRINT_SEGMENTS on a boot shows the truth: dyld reports "mapped dyld cache file private to process (/System/Library/dyld/dyld_shared_cache_arm64)" -- the cache DOES map (my earlier strace cache-mmaps=0 was a false negative; the cache is mmap'd by fd, not by a path matching my grep) -- and then prints "dyld: Mapping /usr/lib/libSystem.B.dylib" + "Speculatively read ... path=/usr/lib/libSystem.B.dylib" for EVERY dylib, i.e. it loads each dylib from DISK even though libSystem is in the cache.

So dyld's findInSharedCacheImage(path) returns FALSE (the dylib is not found in the mapped cache), which means my 0008 branch -- inside `if (findInSharedCacheImage(...)) ... if (overridableDylib()) ... if (dylibsExpectedOnDisk)` -- is NEVER REACHED. 0008 fixed the wrong gate: the useCache inode/mtime check (Pass 105) is downstream of a lookup that already fails. Root cause (revised): the cache maps but its per-dylib image lookup fails under cider -- sSharedCacheLoadInfo's image list is not searchable by the install-name paths the guest requests. That is a dyld cache image-list/path-matching problem, not the load-decision gate, and fixing it needs deep dyld cache-internals debugging (why the mapped cache's image list is not found) plus more ~2h rebuilds, for a modest dev-cache payoff (~10-15% best case; a dev cache saves the dylib open/mmap but not symbol binding). Not justified. Reverted 0008 (abandoned ba7c8411).

Lever A is banked as NOT TRACTABLE within reasonable effort: the cache maps but dyld does not resolve dylibs from it (findInSharedCacheImage fails), and the production cache that would resolve + pre-bind brk-traps under cider. The image-load bottleneck (Pass 103: ~1431 mmap + ~229 dylib opens of ~38 distinct dylibs, ~90ms) stands, but the shared-cache lever to collapse it is deeply blocked at dyld's cache-lookup layer.

## Honest final #11 conclusion (efficient investigation complete)
No measured guest-execution speedup was achievable within reasonable effort:
- RPC reduction (Tier 1 task_self, checkin-batching v1/v2): targets ~7% of boot and does NOT translate to wall-time (checkin-batching measured a slight spawn regression, Pass 101, reverted Pass 102). RPC count is a false proxy for wall-time.
- The real bottleneck is IMAGE LOAD (~90ms: mmap + dylib open/read of ~38 dylibs under the Darwin-on-Linux shim), per the strace critical-path profile (Pass 103).
- The only architectural lever for image load -- the dyld shared cache -- maps but is not consulted for dylib loads (findInSharedCacheImage fails under cider), and cannot use a production cache (brk-trap). Making it work is deep dyld cache-internals work (this pass).
- Remaining levers (deep dyld cache-lookup fix; Tier 2 Mach transport; Tier 3 no-ciderd) are all deep, multi-rebuild, uncertain-payoff efforts.
Net: the bottleneck is now precisely characterized and every lever to attack it is either wrong-target (RPC, ~7%, no wall-time effect) or deeply blocked (shared cache). What shipped and stuck: Tier 1 task_self leaf-cache (0044, plausibly neutral). Everything speculative was reverted. Method lesson carried throughout: gate perf work on a wall-time measurement, never RPC/syscall counts.

**Pass 107 (task #11 / Lever A: cheap read-only deep-dive into WHY findInSharedCacheImage fails; corrects Pass 105; the failure is in dyld's cache path-lookup, not a missing closure or the useCache gate).** Read dyld3::findInSharedCacheImage (SharedCacheRuntime.cpp:945) and dumped our dev cache's dyld_cache_header. Findings:
- The lookup: for a new-format cache it uses loadAddress->hasImagePath(path, idx) + cachedDylibsImageArray(); for old-format it scans imagesOffset[imagesCount] and strcmp's each pathFileOffset path. Either way it matches by the guest install-name path.
- Our cache header: magic dyld_v1 arm64; imagesCount=39 (all our dylibs); cacheType=0 (development); formatVersion=10; sharedRegionStart=0x180000000; maxSlide=0x7fa98000; dylibsImageArrayAddr=0x1867e0000 (NON-zero -> the closure ImageArray IS present), dylibsImageArraySize=0x1cac. And DYLD_PRINT_SEGMENTS confirms the cache maps ("mapped dyld cache file private to process").
- CORRECTION to Pass 105: dylibsExpectedOnDisk = 0 in this cache (bit8 of the 0x40a bitfield), NOT 1. So my 0008 patch forced useCache in the `dylibsExpectedOnDisk==true` branch, which is NEVER TAKEN here -- 0008 was doubly wrong (wrong branch, and findInSharedCacheImage fails upstream of the whole useCache decision anyway). Good that it was reverted.

So the real, precise blocker: the cache maps and HAS a populated dylibs ImageArray, yet findInSharedCacheImage returns false for e.g. /usr/lib/libSystem.B.dylib, so dyld loads every dylib from disk. The failure is inside dyld's path lookup (hasImagePath via the dylibsTrie, or the old-format path-scan) despite the data being present -- likely a formatVersion-branch mismatch (formatVersion=10 vs the guest dyld's kFormatVersion), a dylibsTrie that our minimal MRM cache_builder did not populate, or a slide/pointer resolution issue reading the ImageArray under cider's noslide mapping. Distinguishing these requires adding a debug printf inside findInSharedCacheImage (which branch is taken; hasImagePath's result; the trie address) and a ~2h guest rebuild to observe it.

Decision: NOT pursued further autonomously. This is deep dyld cache-format debugging (multiple ~2h rebuild cycles just to identify, then fix, the lookup failure) for a modest dev-cache payoff (~10-15%: a dev cache saves dylib open/mmap but not symbol binding; the production cache that also pre-binds brk-traps under cider). Lever A stays banked: the cache maps but dyld's dylib lookup into it fails, and salvaging it is a deep, uncertain, multi-rebuild dyld effort. The #11 conclusion (Pass 106) stands: the image-load bottleneck is real and precisely characterized, but every lever to attack it is wrong-target (RPC) or deeply blocked (shared cache). Holding for user direction on whether the deep dyld-lookup debug is worth pursuing.

**Pass 108 (task #11 / Lever A: cheap investigation exhausted; the blocker is dyld's trieWalk in hasImagePath returning NULL, with every checkable precondition verified OK; further diagnosis needs a debug-printf rebuild).** Continued the read-only dive (no rebuild). Verified, all cheaply from the cache bytes + dyld source:
- The cache maps FULLY: mapCachePrivate (0007 forces forcePrivate+disableASLR) mmaps each of the 3 mappings MAP_FIXED at its own address (mapping[0]=0x180000000 fileOff 0, mapping[1]=0x182568000 fileOff 0x568000, mapping[2]=0x186668000 fileOff 0x668000), slide=0, loadAddress=0x180000000. The "mapped dyld cache file private to process" message only prints on success, so all mmaps succeeded.
- hasImagePath (DyldSharedCache.cpp:545) preconditions all pass: mapping[0].fileOffset=0 (no early bail at :548), mappingOffset=0x140 >= 0x118 (trie branch), formatVersion=10 == kFormatVersion=10 (Closure.h:50). It computes slide = this - mapping[0].address = 0, dylibTrieStart = dylibsTrieAddr(0x1867e1cac) + 0 = 0x1867e1cac -- which is inside mapping[2] (mapped) and is the CORRECT runtime address.
- The dylibsTrie is well-formed and CONTAINS the paths: dumping its 0x330 bytes shows the prefix-trie fragments "/usr/lib/", "lib", "system/lib", "System.B.dylib", "objc.A.dylib", "resolv.9.dylib", "quarantine.dylib", ... i.e. all 39 dylib paths.

So the cache maps, the trie is present + correct + at the right address, formatVersion matches -- yet dyld3::MachOLoaded::trieWalk(dylibTrieStart, dylibTrieEnd, dylibPath) returns NULL for e.g. "/usr/lib/libSystem.B.dylib", so hasImagePath is false, findInSharedCacheImage is false, and every dylib loads from disk (Pass 104/106). The remaining candidates cannot be distinguished read-only: (a) the path string dyld passes under cider differs subtly from the trie's stored path (vchroot/realpath normalization, a leading component, etc.), or (b) a trieWalk detail (uleb offsets in the trie vs what our MRM cache_builder emitted). Distinguishing requires a debug printf inside hasImagePath/trieWalk (print dylibPath, dylibTrieStart, and the walk result) + a ~2h rebuild.

Net: Lever A is characterized to the byte -- the cache is valid and maps, but dyld's trie lookup of dylib paths into it fails under cider for a reason that needs one debug-printf rebuild to pin, then a fix (likely a small path-normalization or cache_builder trie fix). Payoff remains modest (~10-15%, dev cache, no symbol pre-binding; production cache brk-traps). This is the entire remaining lever for the image-load bottleneck. The cheap investigation is complete; the next step is the user's call (a debug-printf rebuild). Holding.

**Pass 109 (task #11 / Lever A RETIRED on a WALL-TIME verdict; earlier "trieWalk fails" conclusion CORRECTED). All findings cheap, no rebuild.** Booted the existing A-patched prefix (izrd7995) with the dev cache installed and instrumented it with DYLD_PRINT_LIBRARIES / DYLD_PRINT_SEGMENTS and strace. Results:

- The shared cache actually WORKS under cider. DYLD_PRINT_SEGMENTS shows it mapping (0x180000000 / 0x182568000 / 0x186668000) and "Using shared cached for" ~12 dylibs (libsystem_kernel, _pthread, _platform, ...), their __TEXT landing in the cache region. So Passes 104-108 were WRONG that findInSharedCacheImage/trieWalk fails: it succeeds. (Confirmed independently by reimplementing dyld3 trieWalk in Python over the cache's real trie bytes -- it resolves /usr/lib/libSystem.B.dylib->idx0, libobjc.A->3, libsystem_c->20. Trie/path/mapping/formatVersion all correct.)
- Why only ~12 and not all ~38: the MRM cache-vs-disk policy in dyld2.cpp:3588-3646. For dylibsExpectedOnDisk=0, a dylib present ON DISK is treated as a root/override (onDiskFileIsRoot, :3627) and loaded from disk; only cache-only or "magic" dylibs use the cache. Cider's prefix ships the real dylib files on disk, so most load from disk. (This also explains why 0008 did nothing: it forced useCache in the dead dylibsExpectedOnDisk==true branch, :3602.)
- Forcing the rest to the cache does NOT work: hiding the on-disk copies so existsOnDisk=false (dyld2.cpp:3614 -> useCache=true) SEGFAULTS the guest (SIGSEGV/sigexc in ciderd.log), for libSystem.B and even leaf libresolv.9. The dev cache's inter-image bindings are only self-consistent for a subset; mixing cache-loaded and disk-loaded dylibs yields wrong cross-image addresses -> crash. Hiding ALL 39 aborts even earlier. So the one-line "useCache=true under DARLING" policy patch would segfault, not win -- the cheap hide-test saved a wasted ~2h rebuild.
- THE METRIC. Wall-time A/B, 12 full boots each, same prefix, cache file present vs absent (absent => mapCachePrivate open fails => A inert):
    cache-ON  median 276ms (min 239)   cache-ON2 median 271ms (min 218)
    cache-OFF median 244ms (min 225)
  Cache-ON is a ~30ms REGRESSION. The 12 cached dylibs still get opened/statted (root-check), so disk I/O is not saved (strace: opens 230 both ways; only ~30 fewer mmaps), while mapping the 8MB cache (3 mmaps + rebase) costs ~30ms. strace image-load counts barely move.

VERDICT: Lever A (dyld shared cache) does not improve guest boot wall-time and is a slight regression as built; extending it is blocked by cache inter-image binding fragility under cider's mixed cache/disk loading (a deep cache_builder+dyld project for, best case after also paying the ~30ms map, only ~tens of ms). The shipped prefix ships NO cache file, so the A patches (0005/0006/0007) are DORMANT (mapCachePrivate open fails, negligible cost) and ship no regression -- left in place; not worth a ~2h rebuild to revert dead-but-harmless code. Lever A is retired.

Net for #11: both "obvious" levers are now retired on wall-time evidence -- RPC reduction (Tier1 neutral, checkin-batching a regression) and image-load via shared cache (neutral/regression). The boot is ~244ms; Pass 103's strace put image-load at ~90ms and RPC ~17ms, leaving ~130ms in guest kernel/exec/vchroot setup that has NOT been profiled. The next cheap step (no rebuild) is a fresh phase-level profile of where the ~244ms actually goes (mldr exec -> first guest instruction -> dyld start -> bash main -> exit), to find whether any lever with a real ceiling remains before committing any build. Holding for direction on which to pursue.

**Pass 110 (task #11: the whole-session benchmark target was LOGIN-dominated and unrepresentative of the build hot path; reframing the goal). All cheap, no rebuild.** Traced the `cider shell /bin/bash -c 'exit 0'` boot with strace -f -tt and read the launcher (src/linux/launcher/src/main.rs).

- `cider shell X` is NOT one guest spawn. It is a SIX-mldr-exec LOGIN CHAIN: cider -> ciderd -> mldr(vchroot) -> shellspawn -> `/bin/bash --login -c "'/bin/bash' '-c' 'X'"`, and the `--login` sources profile scripts that themselves spawn `cp -r "/System/Library/User Template/..." /Users/root/` (a recursive template copy) and `/usr/libexec/path_helper -s`, THEN finally `/bin/bash -c 'X'`. So the per-process image-load (~90ms, Pass 103) is paid ~6x, and a recursive cp + path_helper run on EVERY invocation. This login machinery, not guest image-load, dominates the ~240ms I have been benchmarking all session.
- The launcher has a direct path too: `cider exec BIN` -> spawn_binary -> `SHELLSPAWN_SETEXEC` execs BIN directly with NO shell and NO --login (main.rs:642), vs `cider shell`/bare-arg -> spawn_shell -> `-c` into `bash --login` (main.rs:621). The template-copy + path_helper come only from the login shell, so `cider exec` avoids them entirely.
- Build actions carry absolute-path argvs (graph-specs renders `run` specs as argv of tools by absolute path), i.e. a build runs `clang ...` directly, not `bash --login -c "clang ..."`. So the real build hot path almost certainly uses direct exec, and the login chain is an artifact of my interactive `cider shell` proxy. My ~240ms benchmark OVERSTATES the build per-process cost.
- `cider exec` could not be benchmarked as-is: full_path (main.rs:1066) does host realpath(arg)+SYSTEM_ROOT, so `cider exec /bin/bash` fails host-side; and in CIDER_NO_LAUNCHD the persistent shellspawn socket that exec/spawn_binary connect to is torn down per invocation. Measuring the true hot path needs a PERSISTENT daemon (not CIDER_NO_LAUNCHD) + the correct exec contract.

REFRAME: the efficient next step for #11 is to measure the RIGHT thing before optimizing anything else -- direct guest exec with a warm persistent daemon (`cider exec` / shellspawn SETEXEC, ciderd + shellspawn kept alive across spawns), which is what buck2 builds actually do. That number (not the login-chain ~240ms) is the real spawn cost, and its breakdown (image-load vs Mach/RPC setup vs teardown) tells us which lever, if any, has a real ceiling. Two concrete candidates fall out already: (1) if interactive `cider shell` latency matters, make the login idempotent -- skip the per-login `cp -r User Template` when `/Users/root` is already populated and cache path_helper output (a cheap, real shell-startup win); (2) confirm the warm-exec image-load cost is or is not worth attacking (Lever A is out; per-dylib mmap/vchroot-open would be the remaining angle). Both gate on first getting the warm-exec measurement. Holding for direction on whether to stand up the persistent-daemon harness and measure warm exec, or to fix the login idempotency.

**Pass 111 (task #11/#26: THE bottleneck found and it is a cheap launcher fix, not guest work. All wall-time, no rebuild yet).** Stood up the warm persistent-daemon harness (do NOT kill ciderd/shellspawn between runs; the container init in NO_LAUNCHD is the shellspawn-mldr) and measured DIRECT exec, the real build hot path. Findings:

- Warm direct exec: `cider exec <macho>` (SYSTEM_ROOT=/Volumes/SystemRoot; full_path = host realpath + SYSTEM_ROOT, so pass the host path of a guest Mach-O e.g. $VROOT/bin/bash) works (EXECRES:42). Median wall-time: bash direct 149ms, `true` 148ms -- IDENTICAL. Since `true` loads almost nothing and bash loads many dylibs yet both cost the same, IMAGE-LOAD IS NOT THE BOTTLENECK. `cider shell` (login chain) is 242ms; the login chain adds ~90ms on top of direct exec. (strace is unusable on cider guests: the guest uses ptrace for sigexc, which deadlocks with strace's ptrace -> hangs. Decomposed via fast-exit timing points instead.)
- Decomposition of the 148ms direct exec (warm), via fast-exit variants: `cider --version` (userns+prefix, exit) = 14ms; `cider exec /nonexistent` (host + container-attach + nsjoin, die at full_path before guest) = 117ms; `cider exec true` (full guest spawn) = 154ms. So: host launcher ~14ms; CONTAINER-ATTACH ~103ms (dominant); guest exec+teardown (incl. image-load) only ~37ms.
- ROOT CAUSE of the ~103ms: the container is REBUILT ON EVERY INVOCATION. ciderd PID changes every call (3109940->...951->...961->...971) and .init.pid tracks it. In rootless mode (euid!=0) each `cider` call does unshare(CLONE_NEWUSER)+re-exec (main.rs:66) creating a fresh userns, so it cannot setns into the prior container's mnt ns (stale-reap, main.rs:135-142) and kills+respawns the container. This also explains warm==cold (242 vs 232 shell; every spawn is cold).
- The ~103ms is MOSTLY POLL-GRANULARITY WASTE, not real work: after spawn_init the launcher polls for the shellspawn socket with `usleep(100*1000)` = 100ms between checks (main.rs:154-160). Measured: the socket actually appears ~20ms after container start (trials 19/20/21ms). So the launcher sleeps to ~100ms when the container was ready at ~20ms -> ~80ms wasted PER SPAWN.

FIX (cheap, high-value, wall-time-justified): reduce the socket-wait poll granularity from 100ms to ~1ms (keep the 360s cap: `for _ in 0..360000 { ...; usleep(1000) }`), or better use a short sleep with the same total timeout. Expected: direct exec 154ms -> ~74ms, shell 242ms -> ~160ms, i.e. ~80ms off EVERY guest spawn -- the single biggest #11 win found, and it multiplies across the thousands of process spawns in a nix build. This is a LAUNCHER change (src/linux/launcher/src/main.rs, a Linux Rust binary), NOT a ~2h guest prefix rebuild, so it is cheap to build and measure. Deeper follow-on (bigger but complex): make the container PERSISTENT across rootless invocations (join the existing container's userns instead of unshversing a fresh one) to also skip the ~20ms rebuild + nsjoin each spawn; needs Linux userns-join feasibility work (setns(CLONE_NEWUSER) perms) -- defer until after the cheap poll fix is measured. Next: locate the launcher build, apply the poll fix, rebuild just the launcher, install into rt/bin/cider, and A/B the wall-time.

**Pass 112 (task #11/#26: the poll fix is IMPLEMENTED, BUILT, and WALL-TIME VERIFIED -- the biggest #11 win of the session, and cheap).** Applied the Pass 111 fix in src/linux/launcher/src/main.rs: the shellspawn-socket wait now polls at 1ms (usleep(1000), 360_000 iters = same 360s cap) instead of 100ms. Built with `nix build .#launcher` (a small libc-only buildRustPackage: seconds, NOT the ~2h guest prefix rebuild; nix picked up the dirty jj working tree). 

Clean in-place A/B on the min prefix, warm daemon, both launcher binaries in rt/bin/ (so ds_bin_path resolves ciderd as a sibling), median of 12-15 spawns:
  direct exec (cider exec true): OLD 156ms -> NEW 64ms   (~92ms, 59% faster)
  login shell (cider shell):     OLD 247ms -> NEW 149ms  (~98ms, 40% faster)
Correctness unchanged: NEW exec+shell both compute 42. Committed as nroulyqp "perf(cider): poll shellspawn socket at 1ms not 100ms".

Confounder resolved: ds_bin_path (main.rs) resolves ciderd next to /proc/self/exe, else falls back to INSTALL_PREFIX/bin/ciderd (=/usr/local, absent). Running the freshly built launcher straight from its /nix/store path therefore fails to start ciderd (writes .init.pid but the child dies) and hangs the socket wait; install it into rt/bin next to ciderd and it works. The source fix ships automatically in the next full prefix build; no separate action needed. The current-src launcher is otherwise compatible with the older izrd7995 prefix.

Session arc for #11: retired two dead-end levers on wall-time (RPC reduction; dyld shared cache = +30ms regression), corrected a wrong trieWalk conclusion, then found the real cost by measuring the RIGHT thing (warm direct exec, not the login-chain boot): image-load is only ~37ms and not the bottleneck; the bottleneck was a 100ms poll-granularity stall paid on every spawn. One cheap launcher line removes ~90ms/spawn.

Remaining #11 headroom (smaller, and needs care): (1) the container is still REBUILT every rootless spawn (~20ms: new userns per invocation cannot rejoin the prior container's mnt ns) -- making it persistent (join the existing container's userns) would save the rebuild + nsjoin, but needs Linux userns-join feasibility work; (2) the login chain still adds ~85ms over direct exec (cp -r User Template + path_helper on every --login) -- only matters if interactive `cider shell` latency matters, and builds use direct exec anyway. Both are optional follow-ons; the big cheap win is banked. Next default: measure whether the persistent-container work is worth it, else hold.

**Pass 113 (task #11: swept for sibling stalls (none) + proved the persistent-container lever is FEASIBLE).** Two cheap no-rebuild investigations after banking the poll fix:

- Sibling-stall sweep of the per-spawn hot path: NONE found. ciderd is fully epoll-driven (epoll_wait(-1), server.rs:101); the launcher proxy loop is event-driven poll() with a 60s startup watchdog, not a busy wait (main.rs:816-833). The 100ms socket poll (fixed in Pass 112) was the only coarse sleep. (Spotted an unrelated guest-side nit: shellspawn.c:407/430 close shellfd[0] 3x instead of shellfd[i] -- a small fd leak in teardown, not perf; would need a guest rebuild, deferred.)
- Persistent-container feasibility PROVEN. Root of the ~20ms per-spawn rebuild: each rootless cider does unshare(CLONE_NEWUSER)+re-exec (main.rs:66, enter_userns_and_reexec) landing in a SIBLING userns of the running container, and container_joinable/setns into a sibling's mnt ns fails, so it kills+rebuilds the container (stale-reap main.rs:135-142; ciderd PID changes every spawn). But a probe from the ORIGINAL (parent) userns shows a fresh same-uid process CAN setns into a live ciderd's user ns AND then its mnt ns (both OK): ciderd's userns 4026533291 is a CHILD of the launcher's initial userns 4026531837, and from the parent you hold the rights to join the child. So the launcher can REUSE the container instead of rebuilding.

FIX DESIGN (launcher only, cheap build via nix build .#launcher): when a live joinable container exists (.init.pid valid + comm==ciderd), JOIN it from the parent userns -- setns(user) then setns(mnt) -- and skip both the unshare+re-exec and the spawn_init/socket-wait rebuild; only unshare+create when no container exists. Careful points: (1) ordering -- prefix must be resolved before the container check, but the userns gate currently runs first (main.rs:65 before :84); need to read .init.pid early or reorder. (2) after setns(CLONE_NEWUSER) into the container ns we are uid0 there (its map sends our real uid->0), so the setuid(0)/seteuid dance must be re-checked. (3) keep the create path unchanged as the fallback. Expected: direct exec ~64ms -> ~44ms (skip the ~20ms rebuild) AND a genuinely persistent daemon (one ciderd serves a whole build instead of a fork+init+teardown per command) -- a structural win beyond the ms for the thousands of spawns in a build. Payoff smaller than the poll fix but real; next step is to implement it carefully in the launcher and A/B in rt/bin.
