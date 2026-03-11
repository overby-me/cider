# Syscall Triage

Tracking document for unimplemented or buggy macOS syscalls encountered while
running Nix inside Darling. This table is populated by running Nix operations
with syscall tracing enabled and collecting "Unimplemented syscall" messages.

See: [Phase 1, Task 1.7](./03-phase1-syscalls.md#17--triage-unimplemented-syscalls)

---

## How to Collect Data

```bash
# Method 1: Watch for "Unimplemented syscall" messages during a Nix operation
darling shell /nix/store/.../bin/nix --version 2>&1 | grep -i "unimplemented"

# Method 2: Use DARLING_XTRACE for detailed Darwin-side tracing
DARLING_XTRACE=1 darling shell /nix/store/.../bin/nix-env --version 2>&1 | head -500

# Method 3: Trace darlingserver from the Linux host
strace -f -p $(pidof darlingserver) -e trace=all 2>&1 | grep -i "ENOSYS\|unimpl"

# Method 4: Run the full Nix install + build sequence and capture all output
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
| 488 | `renameatx_np` | `mv` (coreutils) | `nix-build` (file moves) | **Crash** — `mv` aborts | Must fix | 🔧 Planned ([1.3](./03-phase1-syscalls.md#13--implement-renameatx_np-syscall-488)) | Map to Linux `renameat2` |
| 462 | `clonefile` | Nix store optimiser | Store copy-on-write | Slow fallback | Should stub | 🔧 Planned ([1.5](./03-phase1-syscalls.md#15--implement-or-stub-clonefile--fclonefileat-syscall-462)) | Return `ENOTSUP`; Nix handles gracefully |
| 463 | `fclonefileat` | Nix store optimiser | Store copy-on-write | Slow fallback | Should stub | 🔧 Planned ([1.5](./03-phase1-syscalls.md#15--implement-or-stub-clonefile--fclonefileat-syscall-462)) | Same as `clonefile` |
| 220 | `getattrlist` | Various (stat-like) | File metadata reads | **Crash** or wrong results | Must fix | 🔧 Planned ([1.1](./03-phase1-syscalls.md#11--implement-setattrlist--fsetattrlist--getattrlist)) | Minimum: `ATTR_CMN_FLAGS` |
| 221 | `setattrlist` | `lchflags` / `chflags` | `nix-env` profile install | **Blocker** — EINVAL | Must fix | 🔧 Planned ([1.1](./03-phase1-syscalls.md#11--implement-setattrlist--fsetattrlist--getattrlist)) | Core blocker B1 |
| — | `fsetattrlist` | `lchflags` variant | `nix-env` profile install | **Blocker** | Must fix | 🔧 Planned ([1.1](./03-phase1-syscalls.md#11--implement-setattrlist--fsetattrlist--getattrlist)) | Same root cause as B1 |
| 547 | `setattrlistat` | `touch` / timestamps | Build scripts | **Crash** — segfault | Must fix | 🔧 Planned ([1.4](./03-phase1-syscalls.md#14--audit-and-fix-utimensat--futimens)) | May share root cause with B1 |
| — | `getentropy` | Crypto / hashing | Nix eval, signing | Potential crash | Should verify | 📋 Planned ([1.6](./03-phase1-syscalls.md#16--implement-getentropy--ccrandomgeneratebytes)) | May already work |
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
| | | | | |
<!-- Add rows as triage sessions are performed -->

---

*[← Phase 1 — Syscall Fixes](./03-phase1-syscalls.md) | [Phase 2 — Sandbox →](./04-phase2-sandbox.md)*