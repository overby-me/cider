# Upstream darling adoption notes (surveyed 2026-07-19)

Fork point: `f39a29489` ("Merge PR #1702 skanalysis-symbols", 2026-03-08).
Upstream `master` HEAD at survey: `e947f0d5` (2026-06-08). Upstream idle ~6 weeks.

## Verdict

Upstream has **not** advanced on anything core to this campaign since the fork:
no syscall, Mach IPC, dyld, libSystem, version-identity, or aarch64 work in
4 months (36 commits, all app-compat stubs/symbols or newer-toolchain build
fixes). Nobody upstream implemented renameatx_np / setattrlist / clonefile /
getattrlist — our `patches/xnu/*` remain the frontier, no conflict risk.

## Worth adopting (pull only if/when needed)

1. **Newer-toolchain ("Fedora 44") build fixes** — most relevant, because we
   build under nixpkgs 26.05's clang 21. If our build fails on
   `-Werror=incompatible-pointer-types`, gnu17 inline semantics, or similar,
   the fixes are upstream:
   - darling tree: `e3fe4288 3f277ba5 9f485c91 ddd118d9 fc5c0666`
     (src/libaks, DiskArbitration, ImageIO, SecurityFoundation, OpenDirectory).
   - xnu: `644decacee` — one line in `libsyscall/CMakeLists.txt`
     (`-Wno-error=incompatible-pointer-types`). Cherry-pick onto our patched
     xnu (do **not** bump the gitlink; ours diverges).
   - corecrypto: "Convert Inline Functions Into Normal Functions" (gnu17).
2. **libkqueue `b0795a2e`** — EVFILT_TIMER type-punning/behavior fix in
   `src/linux/timer.c` (programs the timerfd directly). Relevant to the
   **stall class** (libdispatch timers ride libkqueue under Darling). Adopt as
   a gitlink bump if we chase kqueue-timer stalls in Phase C.4.
3. Nice-to-have (via a full master merge): Foundation NSDistributedLock,
   CF symbols, SystemConfiguration-from-configd restructure.

## How to adopt

Cleanest is merging upstream `master` into our fork: the only gitlink both
sides changed is xnu (ours `42ced1fa`/patched-`5f26a4c2` vs theirs
`fa29287aa2`); resolve by keeping ours. Deferred until a concrete build/stall
failure justifies the merge noise — recorded here so it is one lookup away.
