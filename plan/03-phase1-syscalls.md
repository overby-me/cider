# Phase 1 — Core Syscall & API Fixes

**Priority**: P0 · **Effort**: L (4–8 weeks) · **Depends on**: Phase 0

These are the minimum changes needed for Nix binaries to not crash on startup
and for basic Nix operations (eval, install, build) to function inside Darling.

All syscall work happens in the `darlingserver` submodule
(`src/external/darlingserver/`) and/or the libc wrappers in
`src/external/libc/`. Some fixes may also touch the XNU syscall shim layer in
`src/external/xnu/darling/src/libsystem_kernel/`.

---

## Tasks

### 1.1 — Implement `setattrlist` / `fsetattrlist` / `getattrlist`

**Resolves**: [Blocker B1](./01-blockers.md#b1-lchflags--setattrlist-failure),
partially [B4](./01-blockers.md#b4-touch--utimensat-crash)

**What to do**:

Add the `setattrlist(2)` and `fsetattrlist(2)` BSD syscalls to darlingserver's
syscall handler. These are the underlying calls that `lchflags`, `chflags`,
`utimes`, and other file-metadata functions use on macOS.

**Minimum viable implementation**:

| Attribute Group | Attribute | Action |
|---|---|---|
| `ATTR_CMN_FLAGS` | `UF_IMMUTABLE` | Map to `FS_IMMUTABLE_FL` via `ioctl(FS_IOC_SETFLAGS)`, or silently succeed when clearing (value = 0) |
| `ATTR_CMN_FLAGS` | All other flags | Return 0 (success), ignore silently |
| `ATTR_CMN_MODTIME` | modification time | Translate to `utimensat` on the Linux side |
| `ATTR_CMN_ACCTIME` | access time | Translate to `utimensat` on the Linux side |
| `ATTR_CMN_CRTIME` | creation time | Silently ignore (ext4/btrfs don't expose birth time for writing) |
| Everything else | — | Return `ENOTSUP` or 0 depending on whether ignoring is safe |

Also implement `getattrlist(2)` at minimum for `ATTR_CMN_FLAGS` so that
programs that read-then-modify flags don't crash.

**Files to modify**:

- `src/external/darlingserver/` — syscall dispatch table, new handler
- `src/external/xnu/darling/src/libsystem_kernel/` — ensure the Mach trap /
  BSD syscall number is wired through
- `src/external/libc/` — verify the userspace `setattrlist()` wrapper calls the
  correct syscall number

**Testing**: Write a small C program that calls `lchflags(path, 0)` and
`setattrlist()` with `ATTR_CMN_FLAGS`. Run inside `darling shell`. Must return 0.

---

### 1.2 — Fix `lchflags` Return Value

**Resolves**: [Blocker B1](./01-blockers.md#b1-lchflags--setattrlist-failure)

**What to do**:

Once `setattrlist` is implemented (1.1), verify that `lchflags(path, 0)` returns
0 (success). On macOS, `lchflags` is implemented as:

```c
int lchflags(const char *path, int flags) {
    struct attrlist attrlist;
    memset(&attrlist, 0, sizeof(attrlist));
    attrlist.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrlist.commonattr = ATTR_CMN_FLAGS;
    return setattrlist(path, &attrlist, &flags, sizeof(flags),
                       FSOPT_NOFOLLOW);
}
```

Trace through `src/external/libc/` to confirm this is what Darling's libc does,
and that the `FSOPT_NOFOLLOW` option is respected (i.e., the Linux side uses
`fstatat` / `utimensat` with `AT_SYMLINK_NOFOLLOW` rather than following
symlinks).

**Testing**: Same test program as 1.1. Additionally, copy the exact Nix
`nix-env` invocation from the blog post and verify it completes without the
"clearing flags" error.

---

### 1.3 — Implement `renameatx_np` (Syscall 488)

**Resolves**: [Blocker B3](./01-blockers.md#b3-unimplemented-syscall-488-renameatx_np)

**What to do**:

Add syscall 488 (`renameatx_np`) to darlingserver's BSD syscall table. Translate
directly to Linux's `renameat2(2)`.

**Signature**:

```c
int renameatx_np(int fromfd, const char *from, int tofd, const char *to,
                 unsigned int flags);
```

**Flag translation**:

| macOS Flag | macOS Value | Linux Equivalent | Linux Value |
|---|---|---|---|
| `RENAME_SWAP` | `0x00000002` | `RENAME_EXCHANGE` | `(1 << 1)` |
| `RENAME_EXCL` | `0x00000004` | `RENAME_NOREPLACE` | `(1 << 0)` |
| (none / 0) | `0x00000000` | (none — use plain `renameat`) | `0` |

**Edge cases**:

- If both `RENAME_SWAP` and `RENAME_EXCL` are set, return `EINVAL` (same as
  macOS behavior).
- If the underlying Linux filesystem doesn't support `renameat2` flags (e.g.,
  NFS), return `ENOTSUP`.

**Files to modify**:

- `src/external/darlingserver/` — add syscall 488 to the dispatch table
- `src/external/xnu/darling/src/libsystem_kernel/` — wire the BSD syscall number

**Testing**: Write a C program that:
1. Creates two files.
2. Calls `renameatx_np` with `RENAME_SWAP` to atomically swap them.
3. Calls `renameatx_np` with `RENAME_EXCL` to rename with exclusive semantics.
4. Verifies contents are correct after each operation.

Also verify that Nix's `mv` (from coreutils) no longer crashes.

---

### 1.4 — Audit and Fix `utimensat` / `futimens`

**Resolves**: [Blocker B4](./01-blockers.md#b4-touch--utimensat-crash)

**What to do**:

The Nix-provided `touch` (from coreutils, built for Darwin) segfaults. Debug
this to determine the exact failing call. Likely candidates:

1. `utimensat` with `UTIME_NOW` or `UTIME_OMIT` sentinel values not being
   translated correctly.
2. `setattrlistat` (a variant of `setattrlist` with `at`-style directory fd) not
   being implemented. If `touch` uses this path, it will crash since
   `setattrlist` is missing (see 1.1).
3. A NULL-pointer dereference in the syscall translation layer when handling
   edge cases.

**Debug approach**:

```bash
# On the Linux host, trace darlingserver's syscalls:
strace -f -p $(pidof darlingserver) -e trace=utimensat,openat,fstatat 2>&1 | head -100

# Inside darling shell, with xtrace:
DARLING_XTRACE=1 /nix/store/.../bin/touch /tmp/testfile
```

**Fix**: Ensure the `utimensat` handler in darlingserver:

- Accepts `UTIME_NOW` (`((1 << 30) - 1)` on macOS, same on Linux) and passes
  it through.
- Accepts `UTIME_OMIT` (`((1 << 30) - 2)` on macOS, same on Linux) and passes
  it through.
- Handles `AT_FDCWD` correctly as the directory file descriptor.
- Does not dereference NULL `timespec` pointers (which means "set to current
  time" on both platforms).

**Testing**: `touch /tmp/testfile` inside darling shell with Nix's coreutils
must not segfault. Also test `touch -t 202301011200 /tmp/testfile` (explicit
timestamp).

---

### 1.5 — Implement or Stub `clonefile` / `fclonefileat` (Syscall 462)

**Resolves**: Potential build failures when Nix optimises store copies.

**What to do**:

Nix uses `clonefile` on APFS for copy-on-write file duplication (much faster
than `cp`). On Linux, the equivalents are `ioctl(FICLONE)` (for btrfs/XFS) or
`copy_file_range`.

**Implementation options** (in order of preference):

1. **Translate to `ioctl(FICLONE)`** if the underlying Linux filesystem supports
   it (btrfs, XFS). This preserves the CoW semantics.
2. **Translate to `copy_file_range`** as a fallback — not CoW but still
   efficient (kernel-side copy, no userspace buffering).
3. **Return `ENOTSUP`** — Nix will fall back to regular `read`/`write` copy.
   This is the simplest option and is perfectly functional, just slower.

For MVP, option 3 is fine. Nix handles `ENOTSUP` gracefully.

**Testing**: Call `clonefile("/tmp/src", "/tmp/dst", 0)` inside darling shell.
Verify it either succeeds or returns `ENOTSUP` (not a crash / unimplemented
syscall error).

---

### 1.6 — Implement `getentropy` / `CCRandomGenerateBytes`

**Resolves**: Potential crashes in crypto / hashing code used by Nix and its
dependencies.

**What to do**:

`getentropy(buf, len)` is a simple call to fill a buffer with random bytes. Map
it to Linux's `getrandom(buf, len, 0)`. This may already be implemented in
Darling — verify first.

`CCRandomGenerateBytes` is part of CommonCrypto and calls `getentropy` under the
hood. If `getentropy` works, this should work too.

**Verify**:

```c
#include <sys/random.h>
int main(void) {
    char buf[32];
    return getentropy(buf, sizeof(buf));
}
```

Compile with Apple's clang inside darling shell, run, and check return value.

---

### 1.7 — Triage Unimplemented Syscalls

**Resolves**: Reduces "Unimplemented syscall (N)" crashes across the board.

**What to do**:

1. Run a Nix install + trivial build inside darling shell with syscall tracing
   enabled.
2. Collect all "Unimplemented syscall" messages.
3. Map each syscall number to its name (using XNU headers / the macOS syscall
   table).
4. Categorize:
   - **Must fix**: Causes Nix to crash or fail.
   - **Should stub**: Called but return value isn't critical (e.g., `kdebug`
     tracing calls). Return 0 or `ENOTSUP`.
   - **Can ignore**: Informational, doesn't affect execution.
5. File an issue or task for each "must fix" syscall.

**Output**: A table in this repo (e.g., `plan/syscall-triage.md`) tracking:

| Syscall # | Name | Caller | Impact | Status |
|---|---|---|---|---|
| 488 | `renameatx_np` | `mv` (coreutils) | Crash | Fixed (1.3) |
| 462 | `clonefile` | Nix store | Slow fallback | Stubbed (1.5) |
| ... | ... | ... | ... | ... |

---

### 1.8 — Update Emulated macOS Version

**Resolves**: [Blocker B6](./01-blockers.md#b6-macos-version-mismatch)

**What to do**:

Ensure Darling's runtime environment matches or exceeds the macOS version that
Nix's pre-built Darwin binaries target (currently 11.0 / Big Sur for most
Nixpkgs packages).

**Check current state**:

```bash
darling shell sw_vers
# Expected: ProductVersion: 10.15.x (Catalina)
# Desired:  ProductVersion: 11.0 or higher
```

**Steps**:

1. Update `SystemVersion.plist` in the Darling prefix (likely in
   `src/external/files/` or generated during prefix initialization).
2. Verify `CMakeLists.txt` already sets `CMAKE_OSX_DEPLOYMENT_TARGET 11.0`
   (it does — confirmed in our code analysis).
3. Audit `__MAC_OS_X_VERSION_MIN_REQUIRED` / `@available` guards in Darling's:
   - `src/external/libc/`
   - `src/external/corefoundation/`
   - `src/external/foundation/`
   - `src/external/libdispatch/`
4. Ensure no code paths are gated behind version checks that would disable
   functionality Nix needs (e.g., newer filesystem calls, newer POSIX APIs).
5. Test that Nix's pre-built `x86_64-darwin` binaries (from `cache.nixos.org`)
   launch without version-related `dyld` errors.

**Risks**: Bumping the version may expose new codepaths that call unimplemented
APIs. This is acceptable — better to surface those issues now than to paper
over them with an old version number.

---

## Recommended Implementation Order

```
1.3 (renameatx_np)     — quick win, unblocks mv
    ↓
1.1 (setattrlist)      — biggest impact, unblocks lchflags + possibly touch
    ↓
1.2 (lchflags verify)  — verification step after 1.1
    ↓
1.4 (utimensat)        — may be resolved by 1.1, debug to confirm
    ↓
1.5 (clonefile stub)   — quick, just return ENOTSUP
    ↓
1.6 (getentropy)       — verify first, may already work
    ↓
1.7 (triage)           — discovery task, informs remaining work
    ↓
1.8 (version bump)     — do last, may surface new issues
```

---

## Verification Checklist

After completing Phase 1, the following should all work inside `darling shell`:

- [ ] `lchflags /tmp/testfile 0` returns success (exit code 0)
- [ ] `mv /tmp/a /tmp/b` works with Nix's coreutils `mv` (no "Unimplemented syscall")
- [ ] `touch /tmp/testfile` works with Nix's coreutils `touch` (no segfault)
- [ ] A pre-built Nix binary from `cache.nixos.org` launches without dyld errors
- [ ] `sw_vers` reports macOS 11.0 or higher
- [ ] No "Unimplemented syscall" messages for syscalls in the critical path

---

*[← Phase 0 — Packaging](./02-phase0-packaging.md) | [Phase 2 — Sandbox →](./04-phase2-sandbox.md)*