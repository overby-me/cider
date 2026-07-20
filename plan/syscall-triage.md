# Syscall Triage

Tracking document for unimplemented or buggy macOS syscalls encountered while
running Nix inside Darling. This table is populated by running Nix operations
with syscall tracing enabled and collecting "Unimplemented syscall" messages.

See: [Phase 1, Task 1.7](./03-phase1-syscalls.md#17--triage-unimplemented-syscalls)

---

## How to Collect Data

```bash
# Method 1 (recommended): Use the automated triage script
./scripts/triage-syscalls.sh                          # basic run
./scripts/triage-syscalls.sh --xtrace                 # with DARLING_XTRACE
./scripts/triage-syscalls.sh --xtrace --output report.md  # save report

# Method 2: Watch for "Unimplemented syscall" messages during a Nix operation
darling shell /nix/store/.../bin/nix --version 2>&1 | grep -i "unimplemented"

# Method 3: Use DARLING_XTRACE for detailed Darwin-side tracing
DARLING_XTRACE=1 darling shell /nix/store/.../bin/nix-env --version 2>&1 | head -500

# Method 4: Trace darlingserver from the Linux host
strace -f -p $(pidof darlingserver) -e trace=all 2>&1 | grep -i "ENOSYS\|unimpl"

# Method 5: Run the full Nix install + build sequence and capture all output
./scripts/install-nix-in-darling.sh 2>&1 | tee nix-install-trace.log
grep -i "unimplemented\|STUB\|not.implemented\|ENOSYS" nix-install-trace.log
```

## Syscall Number Reference

macOS (XNU) BSD syscall numbers can be found in:
- `src/external/xnu/bsd/kern/syscalls.master` (this repo, if submodule is checked out)
- [Apple's open-source XNU syscall table](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master)

---

## Triage Table

| Syscall # | Name | Caller | Operation | Impact | Category | Status | Notes |
|-----------|------|--------|-----------|--------|----------|--------|-------|
| 488 | `renameatx_np` | `mv` (coreutils) | `nix-build` (file moves) | **Crash** — `mv` aborts | Must fix | ✅ Fixed ([1.3](./03-phase1-syscalls.md#13--implement-renameatx_np-syscall-488)) | Maps to Linux `renameat2`; RENAME_SWAP→RENAME_EXCHANGE, RENAME_EXCL→RENAME_NOREPLACE |
| 462 | `clonefile` | Nix store optimiser | Store copy-on-write | Slow fallback | Should stub | ⏭️ Stubbed ([1.5](./03-phase1-syscalls.md#15--implement-or-stub-clonefile--fclonefileat-syscall-462)) | Changed from ENOSYS→ENOTSUP; Nix falls back to read/write copy |
| 517 | `fclonefileat` | Nix store optimiser | Store copy-on-write | Slow fallback | Should stub | ⏭️ Stubbed ([1.5](./03-phase1-syscalls.md#15--implement-or-stub-clonefile--fclonefileat-syscall-462)) | Same as `clonefile` — ENOSYS→ENOTSUP |
| 220 | `getattrlist` | Various (stat-like) | File metadata reads | **Crash** or wrong results | Must fix | ✅ Fixed ([1.1](./03-phase1-syscalls.md#11--implement-setattrlist--fsetattrlist--getattrlist)) | Added ATTR_CMN_FLAGS support; returns flags=0. Fixed attribute buffer ordering (OBJTAG→FNDRINFO→FLAGS by bit position). |
| 221 | `setattrlist` | `lchflags` / `chflags` | `nix-env` profile install | **Blocker** — EINVAL | Must fix | ✅ Fixed ([1.1](./03-phase1-syscalls.md#11--implement-setattrlist--fsetattrlist--getattrlist)) | Added ATTR_CMN_FLAGS + CRTIME + CHGTIME to COMMON_SUPPORTED |
| — | `fsetattrlist` | `lchflags` variant | `nix-env` profile install | **Blocker** | Must fix | ✅ Fixed ([1.1](./03-phase1-syscalls.md#11--implement-setattrlist--fsetattrlist--getattrlist)) | Same generic handler as setattrlist |
| 547 | `setattrlistat` | `touch` / timestamps | Build scripts | **Crash** — segfault | Must fix | ✅ Fixed ([1.4](./03-phase1-syscalls.md#14--audit-and-fix-utimensat--futimens)) | Uses same generic handler — now supports ATTR_CMN_FLAGS |
| 500 | `getentropy` | Crypto / hashing | Nix eval, signing | OK | Already works | ✅ Verified ([1.6](./03-phase1-syscalls.md#16--implement-getentropy--ccrandomgeneratebytes)) | Maps to Linux getrandom(2) — already implemented |
| — | `getattrlist` (buffer order) | Callers requesting multiple attrs | `stat`-like metadata reads | **Wrong results** — misaligned buffer | Must fix | ✅ Fixed | `getattrlist_generic.c` attribute buffer now follows Apple-defined order: OBJTAG (bit 4) → FNDRINFO (bit 14) → FLAGS (bit 18) → dir attrs → file attrs |
| | | | | | | | |
<!-- Add new entries above this line as they are discovered -->

---

## Category Definitions

| Category | Description | Action Required |
|----------|-------------|-----------------|
| **Must fix** | Causes Nix to crash, abort, or produce incorrect results | Implement the syscall or a correct translation to Linux |
| **Should stub** | Called but return value isn't critical for correctness | Return `0`, `ENOTSUP`, or a sensible default |
| **Can ignore** | Informational / tracing call; does not affect execution | Suppress the warning message; no code change needed |

## Impact Levels

| Impact | Description |
|--------|-------------|
| **Crash** | Process aborts with signal (SIGILL, SIGSEGV, SIGABRT) or "Unimplemented syscall" |
| **Blocker** | Operation returns an error that Nix treats as fatal |
| **Wrong results** | Syscall returns unexpected data leading to subtle bugs |
| **Slow fallback** | Nix handles the error gracefully but uses a slower code path |
| **Cosmetic** | Warning message printed but no functional impact |

## Status Key

| Status | Meaning |
|--------|---------|
| 🔧 Planned | Fix designed, not yet implemented |
| 🚧 In progress | Implementation underway |
| ✅ Fixed | Implemented and verified |
| ⏭️ Stubbed | Returns a harmless value; full implementation deferred |
| ❌ Won't fix | Not needed for Nix; documented and closed |
| 📋 Needs triage | Discovered but not yet categorised |

---

## Discovery Log

Record each triage session here so we know what's been tested.

| Date | Tester | Nix Version | Operation Tested | New Syscalls Found |
|------|--------|-------------|------------------|--------------------|
| 2025-07 | — | — | Code audit | renameatx_np (488), clonefile (462/517), setattrlist (221), getattrlist (220), getentropy (500) |
| 2025-07 | — | — | Code audit (getattrlist buffer order) | None new — fixed attribute buffer ordering bug in `getattrlist_generic.c` (OBJTAG was written after FNDRINFO/FLAGS instead of before) |
| 2025-07 | — | — | Triage automation | Created `scripts/triage-syscalls.sh` and `tests/syscall/test_utimensat.c` for automated discovery |
| 2026-07 | — | bootstrap clang | GNU hello `./configure` under Darling | `dup2` to a guarded high fd aborted (see below); fixed in `patches/xnu/0006` |
<!-- Add rows as triage sessions are performed -->

---

## Campaign 2 live findings (running real builds under Darling)

Found by running GNU hello's `./configure` under rootless Darling. The toolchain
itself works: the bootstrap clang compiles + links + runs under Darling (see
plan/26.05-facts.md); configure passed ~198 checks before this one.

1. **`dup2` to a guarded high fd aborts the process.** configure's "whether
   dup2 works" test does `dup2(1, RLIMIT_NOFILE)` (here fd **524287**),
   expecting `EBADF`. Darling parks internal (darlingserver RPC) descriptors at
   high fd numbers, so that target collides with a guarded fd and `sys_dup2`
   (`.../bsd/impl/unistd/dup2.c`) called `__simple_abort()` (`Abort trap: 6`),
   killing configure. macOS returns `EBADF` for an out-of-range target, so
   `patches/xnu/0006` returns `EBADF` instead of aborting: the dup2 fails, the
   guarded fd is preserved, the process survives. (`close.c` already declines
   to abort on the same guard.)

   Method: a probe compiled with `scripts/cc-under-darling.sh` walked the gnulib
   dup2 operations, `fflush`ing each to stdout; the last line before the abort
   (`dup2(1, 524287)`) localized it, then `dup2.c` confirmed the guard/abort.

   This class (Darling internal fds colliding with programs that probe
   `RLIMIT_NOFILE`-relative fds) may recur in `fcntl(F_DUPFD)` / `dup`; apply the
   same EBADF-not-abort treatment if a later test trips it.

---

*[← Phase 1 — Syscall Fixes](./03-phase1-syscalls.md) | [Phase 2 — Sandbox →](./04-phase2-sandbox.md)*
