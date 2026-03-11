# Known Blockers

Detailed analysis of each issue that prevents Nix from running inside Darling,
with fix strategies and pointers into the codebase.

---

## B1: `lchflags` / `setattrlist` Failure

**Symptom**: Running `nix-env` to install a package fails with:
```
error: clearing flags of path '/nix/store/…-user-environment/bin': Invalid argument
```

**What happens**: Nix's store optimisation code (in `libnixstore`) calls
`lchflags(path, 0)` to clear `UF_IMMUTABLE` before garbage collection. The
relevant Nix source:

```c
#if __APPLE__
    if (lchflags(path.c_str(), 0)) {
        if (errno != ENOTSUP)
            throw SysError("clearing flags of path '%1%'", path);
    }
#endif
```

On macOS, `lchflags()` is emulated via `setattrlist(2)`. Darling does not
implement `setattrlist`, so the underlying syscall fails with `EINVAL`.

**Location in Darling**:
- Syscall translation: `src/external/darlingserver/` (submodule)
- libc wrapper: `src/external/libc/`

**Fix strategy**:
1. Implement `setattrlist` / `fsetattrlist` in darlingserver's BSD syscall
   handler. At minimum, handle `ATTR_CMN_FLAGS` (clearing `UF_IMMUTABLE`).
2. Return success (0) for attribute sets that have no Linux equivalent but are
   benign to ignore (e.g., Finder info, extended security).
3. Ensure `lchflags(path, 0)` returns 0 rather than `EINVAL`.
4. Long-term: implement a proper `UF_IMMUTABLE` ↔ `FS_IMMUTABLE_FL` mapping
   via `ioctl(FS_IOC_SETFLAGS)`.

**Workaround (from blog post)**: Binary-patch `libnixstore.dylib` — replace the
`je` (jump-if-equal) after the `lchflags` call with `jmp` (unconditional jump)
to skip the error path. This is fragile and version-specific.

**Effort**: Medium — needs darlingserver changes + libc verification.

---

## B2: Missing `sandbox-exec`

**Symptom**: `nix-build` of any derivation fails with:
```
error: executing '/bin/bash': Bad file descriptor
```

**What happens**: Nix on Darwin wraps every builder invocation with:
```
/usr/bin/sandbox-exec -f <profile> -D _GLOBAL_TMP_DIR=... <builder>
```

The binary `/usr/bin/sandbox-exec` does not exist in the Darling prefix.
`posix_spawn` is called with `sandbox-exec` as the executable, which returns
`ENOEXEC`. Nix reports this misleadingly as "Bad file descriptor".

The sandbox API in `src/sandbox/sandbox.c` is entirely stubbed:
```c
int sandbox_init(const char *profile, uint64_t flags, char **errorbuf)
{
    *errorbuf = strdup("Not implemented");
    return 0;
}
```

**Fix strategy** (two options, not mutually exclusive):

- **Option A — Stub `sandbox-exec` (MVP)**: Ship a `/usr/bin/sandbox-exec`
  shell script or small C program that:
  - Parses `-f <profile>` and `-D <key>=<value>` arguments (discards them).
  - `exec`s the remaining arguments as the builder command.
  - Darling already provides Linux-level isolation via namespaces and the
    darlingserver container, so skipping the macOS sandbox is safe.

- **Option B — Translate to Linux sandboxing (stretch)**: Parse Apple's Sandbox
  Profile Language (Scheme-based `.sb` files) and map rules to Linux
  equivalents (Landlock, seccomp-bpf, namespaces). Large effort, not needed
  for MVP.

**Workaround (from blog post)**: Set `_NIX_TEST_NO_SANDBOX=1` — this is an
internal Nix environment variable that bypasses sandbox-exec. Works but is not
meant for production use.

**Effort**: Small for Option A (a few hours), Large for Option B (weeks).

---

## B3: Unimplemented Syscall 488 (`renameatx_np`)

**Symptom**: `mv` from Nix's coreutils crashes:
```
Unimplemented syscall (488)
```
This breaks derivation builds that need to move files (very common).

**What happens**: macOS syscall 488 is `renameatx_np`, which extends `rename`
with atomic swap and exclusive-create semantics. Modern Darwin coreutils
(fetched from the Nix binary cache) use this syscall. Darling's syscall table
does not have an entry for it.

**Fix strategy**: Implement `renameatx_np` by translating to Linux's
`renameat2(2)`. The flag mapping:

| macOS Flag | Value | Linux Equivalent |
|---|---|---|
| `RENAME_SWAP` | `0x00000002` | `RENAME_EXCHANGE` |
| `RENAME_EXCL` | `0x00000004` | `RENAME_NOREPLACE` |

When no flags are set, fall through to plain `renameat`.

**Location**: darlingserver syscall table (`src/external/darlingserver/`).

**Workaround (from blog post)**: Replace the Nix store's `mv` binary with
Darling's built-in `/bin/mv` that uses older syscalls. This is a "Nix crime"
(modifying store paths) and breaks reproducibility.

**Effort**: Small — straightforward syscall mapping, well-defined semantics.

---

## B4: `touch` / `utimensat` Crash

**Symptom**: Running `touch` from Nix's coreutils causes:
```
Segmentation fault: 11 (core dumped)
```
This breaks derivation builds (e.g., neovim's build script calls `touch`).

**What happens**: The Nix-provided `touch` (compiled for newer macOS) likely
uses `setattrlistat` or a `utimensat`-related path that is missing or buggy in
Darling. It may also be related to the `setattrlist` gap from B1 — `touch -t`
on macOS can go through `setattrlist` to set modification times.

**Fix strategy**:
1. Audit the `utimensat` / `futimens` translation in darlingserver.
2. Ensure `UTIME_NOW` and `UTIME_OMIT` sentinel values are correctly handled.
3. If the crash is in `setattrlistat`, fixing B1 may resolve this too.
4. Test with Nix's specific coreutils version.

**Workaround (from blog post)**: Same as B3 — replace the store's `touch` with
Darling's built-in version.

**Effort**: Medium — needs debugging to pinpoint exact crash location.

---

## B5: `posix_spawn` with `POSIX_SPAWN_SETEXEC` Returns `ENOEXEC`

**Symptom**: Even when `sandbox-exec` or other executables exist, `posix_spawn`
with the `POSIX_SPAWN_SETEXEC` flag (which makes it behave like `exec`) can
return `ENOEXEC` for certain binaries.

**What happens**: The `POSIX_SPAWN_SETEXEC` flag is used by Nix's sandbox setup
and by launchd (`src/launchd/src/core.c:4553`). If darlingserver doesn't fully
support this flag in its `posix_spawn` implementation, the caller gets
`ENOEXEC` and reports confusing errors.

**Fix strategy**: Verify `POSIX_SPAWN_SETEXEC` handling in darlingserver's
`posix_spawn` implementation. Ensure it correctly replaces the current process
image (like `execve`) rather than spawning a child.

**Effort**: Medium — requires darlingserver debugging.

---

## B6: macOS Version Mismatch

**Symptom**: Various subtle failures due to Darling reporting macOS 10.15
(Catalina) while Nix's pre-built Darwin binaries increasingly target macOS 11.0+
(Big Sur).

**What happens**: The Nix binary cache serves binaries built with
`-mmacosx-version-min=11.0` or higher. These binaries may use APIs or syscalls
that were introduced in Big Sur and aren't present in Darling's Catalina-era
libraries.

**Note**: The `CMakeLists.txt` already sets `CMAKE_OSX_DEPLOYMENT_TARGET` to
`11.0`, but the runtime environment (`sw_vers`, `SystemVersion.plist`) may still
report 10.15.

**Fix strategy**:
1. Update `sw_vers` / `SystemVersion.plist` in the Darling prefix to report 11.0.
2. Audit `__MAC_OS_X_VERSION_MIN_REQUIRED` availability guards in Darling's
   libc, libSystem, and frameworks.
3. Ensure there are no code paths gated on version checks that disable
   functionality we need.

**Effort**: Medium — version bumps can have cascading effects.

---

## B7: dyld Shared Cache

**Symptom**: Some binaries print on startup:
```
dyld: dyld cache load error: shared cache file open() failed
```

**What happens**: macOS ships a pre-linked shared cache
(`/System/Library/dyld/dyld_shared_cache_x86_64`) that contains all system
libraries. Darling may not generate this cache, forcing `dyld` to fall back to
loading individual `.dylib` files. This usually works but can cause errors with
binaries that assume the cache exists.

**Fix strategy**:
1. Determine if Darling generates a shared cache during prefix initialization.
2. If not, add a cache generation step or ensure the fallback path works
   reliably.
3. This is lower priority — most Nix binaries link against Nix-provided
   libraries, not system ones.

**Effort**: Medium-to-Large depending on root cause.

---

## Blocker Dependency Graph

```
B1 (setattrlist) ──→ B4 (touch/utimensat) may share root cause
B2 (sandbox-exec) ──→ B5 (posix_spawn) related but independent
B3 (renameatx_np)    standalone
B6 (version)         affects everything subtly
B7 (dyld cache)      standalone, lower priority
```

**Recommended fix order**: B2 (quick win) → B3 (quick win) → B1 → B4 → B5 → B6 → B7

---

*[← Background](./00-background.md) | [Phase 0 — Packaging →](./02-phase0-packaging.md)*