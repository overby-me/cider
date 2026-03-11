# Phase 4 — Derivation Building

**Priority**: P1 · **Effort**: L (4–8 weeks) · **Depends on**: Phase 3 (Nix installation)

This is the acid test: can Nix actually *build* derivations inside Darling? Phase
3 got Nix installed and evaluating; this phase gets it building real software.

We progress from trivial derivations through to full stdenv builds and binary
substitution from the official cache.

---

## Context

A Nix derivation build on Darwin involves:

1. Nix creates a temporary build directory (`/tmp/nix-build-<name>.drv-N/`).
2. Nix generates a sandbox profile (`.sb` file) in that directory.
3. Nix calls `posix_spawn` to execute `/usr/bin/sandbox-exec -f <profile> <builder>`.
4. The builder (usually `/bin/bash`) runs inside the sandbox with a clean
   environment (`$PATH`, `$HOME`, `$TMPDIR` all controlled by Nix).
5. The builder script sources `$stdenv/setup` and runs the build phases
   (unpack, configure, build, install, fixup, etc.).
6. Build output is written to `$out` (a path in `/nix/store`).
7. Nix registers the output in the store database and makes it read-only.

Each step exercises different parts of the Darling compatibility layer. This
phase works through them incrementally.

---

## Tasks

### 4.1 — Build a Trivial Derivation

The simplest possible derivation — no dependencies, no stdenv, just `/bin/bash`
writing a file:

```nix
derivation {
  name = "hello-darling";
  builder = "/bin/bash";
  args = [ "-c" "echo 'Hello from Darling!' > $out" ];
  system = "x86_64-darwin";
}
```

**Build command**:

```bash
darling-nix nix-build --expr 'derivation { name = "hello-darling"; builder = "/bin/bash"; args = [ "-c" "echo hello > $out" ]; system = "x86_64-darwin"; }'
```

**What this exercises**:

- `posix_spawn` → `sandbox-exec` stub → `/bin/bash` (Phase 2 must be working)
- File creation in `/nix/store`
- `$out` environment variable propagation
- Basic file I/O (`echo`, redirect)
- Store path registration (SQLite write)
- Setting store path read-only (`chmod`, possibly `lchflags`)

**Expected failure modes**:

| Failure | Likely Cause | Fix |
|---|---|---|
| "Bad file descriptor" / ENOEXEC | `sandbox-exec` stub not installed or not executable | Phase 2 — verify installation |
| "clearing flags of path" | `lchflags` still failing | Phase 1.1 / 1.2 |
| Sandbox profile write fails | `/tmp` not writable or path issue | Check prefix `/private/tmp` setup |
| Builder hangs | `posix_spawn` with `POSIX_SPAWN_SETEXEC` broken | Phase 1 — B5 |
| "build failure may have been caused by lack of free disk space" | Generic Nix error wrapping the real issue | Check build log in `/nix/var/log/nix/` |

**Debugging**:

```bash
# Verbose build with debug output
darling-nix nix-build --expr '...' -vvvv --debug 2>&1 | tee build.log

# Check if the builder can be invoked manually
darling shell /usr/bin/sandbox-exec -f /dev/null -D _GLOBAL_TMP_DIR=/tmp /bin/bash -c 'echo ok'

# Manually run the derivation's builder to isolate the failure
darling shell nix-shell --pure --run 'echo $out' /nix/store/...-hello-darling.drv
```

---

### 4.2 — Get `bash` Executing Reliably in Build Sandboxes

Even after 4.1 works, there may be subtle issues with bash inside Nix's build
environment. The build environment is intentionally spartan:

- `$HOME=/homeless-shelter` (doesn't exist)
- `$PATH=/path-not-set` (intentionally broken)
- `$TMPDIR=/tmp/nix-build-<name>.drv-N/`
- `$NIX_STORE=/nix/store`

**Requirements for bash to function**:

- `/dev/null` must exist and be readable/writable
- `/dev/urandom` must exist (some builds need random data)
- `/dev/zero` must exist
- `$TMPDIR` must be writable
- `posix_spawn` with `POSIX_SPAWN_SETEXEC` must work (acts like `exec`)
- Signal handling must work (Nix sends `SIGTERM` to cancel builds)
- `pipe2` / `dup2` must work (for shell redirections)
- `fcntl` with `F_GETFD` / `F_SETFD` must work (for `O_CLOEXEC`)

**Verification**:

```bash
# Inside darling shell, simulate a Nix build environment:
env -i HOME=/homeless-shelter PATH=/path-not-set \
    TMPDIR=/tmp/test-build NIX_STORE=/nix/store \
    /bin/bash -c 'echo "PATH=$PATH"; echo "HOME=$HOME"; echo ok > /tmp/test-build/out'
```

**Check device nodes**:

```bash
darling shell ls -la /dev/null /dev/urandom /dev/zero
# These should exist. If not, they need to be created during prefix init
# or symlinked from /Volumes/SystemRoot/dev/
```

---

### 4.3 — Build with Nix's `bash` (from the Binary Cache)

The trivial derivation in 4.1 uses Darling's built-in `/bin/bash`. Real
derivations use Nix's own bash from the store (e.g.,
`/nix/store/...-bash-5.2-p26/bin/bash`). This is a pre-built `x86_64-darwin`
Mach-O binary fetched from `cache.nixos.org`.

**Test**:

```nix
let
  bash = builtins.fetchurl {
    url = "https://cache.nixos.org/nar/...";  # or use a pinned store path
  };
in derivation {
  name = "test-nix-bash";
  builder = "${bash}/bin/bash";
  args = [ "-c" "echo 'Using Nix bash!' > $out" ];
  system = "x86_64-darwin";
}
```

Or more practically:

```bash
# Force-fetch bash from the binary cache
darling-nix nix-store -r /nix/store/...-bash-5.2-p26

# Then build a derivation that uses it
darling-nix nix-build --expr '
  let pkgs = import <nixpkgs> { system = "x86_64-darwin"; };
  in derivation {
    name = "test-nix-bash";
    builder = "${pkgs.bash}/bin/bash";
    args = [ "-c" "echo ok > \$out" ];
    system = "x86_64-darwin";
  }
'
```

**What this additionally exercises**:

- `dyld` loading the Nix-built bash and all its dependencies (`libSystem`,
  `libc++`, etc.) — these are Mach-O binaries that must be translated by Darling
- NAR unpacking (when fetching from the cache)
- Symlink handling in `/nix/store`
- `LC_RPATH` / `@rpath` resolution in Mach-O binaries

**Expected failure modes**:

| Failure | Likely Cause | Fix |
|---|---|---|
| `dyld: Symbol not found` | Nix bash built for macOS 11+ but Darling reports 10.15 | Phase 1.8 (version bump) |
| `dyld: Library not loaded` | Missing `libSystem` or `libc++` dylib in Darling prefix | Verify Darling's system libraries cover the needed symbols |
| `Illegal instruction: 4` | Binary uses CPU instruction Darling doesn't translate | Check if SSE/AVX instructions are involved; may need darlingserver fix |
| Segfault during load | `dyld` cache issue or broken mmap translation | See [Blocker B7](./01-blockers.md#b7-dyld-shared-cache) |

---

### 4.4 — Handle Binary Substitution from `cache.nixos.org`

Binary substitution (downloading pre-built packages instead of building them) is
critical for practical use — building everything from source inside Darling would
be extremely slow.

**What to test**:

```bash
# Fetch a simple package from the cache
darling-nix nix-store -r /nix/store/...-hello-2.12.1

# Or build with substitution:
darling-nix nix-build '<nixpkgs>' -A hello --system x86_64-darwin
```

**Substitution pipeline**:

```
nix-store --realise
  → curl HTTPS request to cache.nixos.org
    → download .narinfo (package metadata)
    → download .nar.xz (compressed archive)
  → xz decompress
  → NAR unpack to /nix/store/...
  → set permissions (chmod, chown)
  → register in SQLite database
  → clear flags (lchflags — Phase 1)
```

**Requirements**:

- **HTTPS/TLS**: `curl` must successfully connect to `cache.nixos.org`. Test:
  ```bash
  darling shell curl -sI https://cache.nixos.org/nix-cache-info
  ```

- **xz decompression**: The `xz` binary from the store must work. If it uses
  unimplemented syscalls, we need the host-side `xz` or a fallback.

- **NAR unpacking**: Nix's NAR format uses `mknod`, `symlink`, `chmod`,
  `chown`, `utimes`. All must work.

- **Large file support**: Some NARs are hundreds of MB. Ensure `mmap`, `ftruncate`,
  and large `read`/`write` calls work correctly.

- **Certificate verification**: Nix verifies the binary cache's signing key, not
  TLS certificates for trust. But `curl` still needs working TLS. Darling ships
  OpenSSL certificates via `src/external/openssl_certificates/` — verify they're
  up to date.

---

### 4.5 — Build a Simple C Program with Darwin stdenv

This is the first "real" build — compiling C code using Nixpkgs' Darwin stdenv,
which pulls in clang, ld64, Apple SDK headers, and the full build machinery.

```bash
darling-nix nix-build '<nixpkgs>' -A hello --system x86_64-darwin
```

**What the Darwin stdenv does**:

1. Sources `$stdenv/setup` (a large bash script).
2. Unpacks the source tarball.
3. Runs `./configure` (or cmake, meson, etc.).
4. Compiles with `clang` targeting `x86_64-apple-darwin`.
5. Links with `ld64` (Apple's linker, from cctools-port).
6. Runs fixup phase: `install_name_tool`, `codesign`, `strip`, etc.
7. Produces a Mach-O executable or library in `$out`.

**Key binaries that must work** (all from the Nix store, built for Darwin):

| Binary | Role | Concern |
|---|---|---|
| `bash` | Builder shell | Covered in 4.2/4.3 |
| `coreutils` (`mv`, `cp`, `touch`, `install`, `mkdir`) | Basic file operations | `mv` needs `renameatx_np` (Phase 1.3), `touch` needs `utimensat` (Phase 1.4) |
| `clang` | C/C++/ObjC compiler | May use `posix_spawn` internally; large binary with many dylib deps |
| `ld64` | Apple linker | Writes Mach-O output; may use `fcntl` advisory locks |
| `ar` / `ranlib` | Archive tools | From cctools, should be straightforward |
| `install_name_tool` | Fix dylib paths | Modifies Mach-O headers; needs working `mmap` + `ftruncate` |
| `codesign_allocate` | Code signature space | May fail (no codesign in Darling); needs graceful fallback |
| `strip` | Strip symbols | Modifies Mach-O binaries |
| `xattr` | Extended attributes | `xattr -cr` is run during fixup; needs `removexattr` / `listxattr` |
| `sed`, `grep`, `awk` | Text processing | Usually fine, but check for syscall issues |
| `tar`, `gzip`, `xz` | Archive handling | `tar` may use `fchflags`; `xz` may use newer syscalls |

**Coreutils crash workaround strategy**:

If specific coreutils binaries from the Nix store crash due to unimplemented
syscalls, there are two approaches:

1. **Preferred**: Fix the syscall in darlingserver (Phase 1).
2. **Temporary**: Create wrapper scripts in the prefix that intercept the
   crashing commands and redirect to Darling's built-in versions:
   ```bash
   # In the Darling prefix:
   mkdir -p /usr/local/nix-compat/bin
   cat > /usr/local/nix-compat/bin/mv << 'EOF'
   #!/bin/sh
   exec /bin/mv "$@"
   EOF
   chmod +x /usr/local/nix-compat/bin/mv
   # Add /usr/local/nix-compat/bin early in $PATH for builds
   ```
   This is a "Nix crime" if done inside the store, but putting it in `$PATH`
   via `nix.conf` or a build hook is acceptable as a temporary measure.

---

### 4.6 — Fix Remaining Coreutils / Build-Tool Crashes

Based on the blog post and analysis, the following specific binaries are known
to crash inside Darling when fetched from the Nix binary cache. Each needs
either a syscall fix or a workaround.

| Binary | Crash Symptom | Root Cause | Fix |
|---|---|---|---|
| `mv` | `Unimplemented syscall (488)` | `renameatx_np` missing | Phase 1.3 |
| `touch` | `Segmentation fault: 11` | `utimensat` / `setattrlist` | Phase 1.4 / 1.1 |
| `install` | `clearing flags` or crash | `fchflags` / `chflags` | Phase 1.1 |
| `cp` | Possible crash | `clonefile` / `fclonefileat` | Phase 1.5 |
| `tar` | `fchflags` warning or crash | `fchflags` on extracted files | Phase 1.1 |
| `xattr` | `removexattr` failure | xattr syscalls incomplete | New task — implement `removexattr`, `listxattr`, `getxattr` |
| `codesign_allocate` | Likely failure | Code signing not supported | Stub or skip in stdenv fixup phase |
| `fish` | `Illegal instruction: 4` | Uses newer CPU/syscall features | Lower priority — not in the critical build path |

**Approach**: Work through these in order of build-pipeline criticality. A build
can't succeed if `mv` crashes, so that's fixed first (Phase 1.3). The codesign
tools are less critical — if they fail, we can patch the stdenv fixup phase to
skip codesigning inside Darling.

**Extended attribute (xattr) handling**:

The Darwin stdenv fixup phase runs `xattr -cr $out` to clear quarantine
attributes. This requires:

- `listxattr` — list all xattrs on a file
- `removexattr` — remove a specific xattr
- `getxattr` / `setxattr` — read/write xattr values

On Linux, these have direct equivalents (`listxattr(2)`, `removexattr(2)`,
etc.). Darlingserver needs to translate the macOS xattr syscalls to the Linux
ones, mapping the `com.apple.*` namespace appropriately.

If full xattr support is too complex, a minimal approach:

- `listxattr` → return empty list (no xattrs)
- `removexattr` → return success (nothing to remove)
- `getxattr` → return `ENODATA` (no such xattr)

This is safe because Darling files won't have real Apple quarantine attributes.

---

### 4.7 — Verify Build Output Correctness

After a successful `nix-build`, verify the output is correct:

```bash
# Build hello
darling-nix nix-build '<nixpkgs>' -A hello --system x86_64-darwin

# Check the output exists and is a Mach-O binary
darling shell file /nix/store/...-hello-2.12.1/bin/hello

# Run it
darling shell /nix/store/...-hello-2.12.1/bin/hello
# Expected: "Hello, world!"

# Verify the store path is valid
darling-nix nix-store --verify-path /nix/store/...-hello-2.12.1

# Check closure (all dependencies resolved)
darling-nix nix-store -qR /nix/store/...-hello-2.12.1
```

**Important**: The output hash of a derivation built inside Darling will differ
from the same derivation built on real macOS if the build is not perfectly
reproducible (input-addressed derivations use the same hash regardless of
content, but if there are build failures or different outputs, something is
wrong).

---

### 4.8 — Handle `codesign` in the Fixup Phase

The Darwin stdenv's fixup phase attempts to ad-hoc codesign all Mach-O binaries.
This calls `codesign_allocate` and/or `codesign` (or `sigtool` in recent
Nixpkgs). Darling is unlikely to support code signing.

**Options**:

1. **Stub `codesign`**: Provide a `/usr/bin/codesign` that does nothing and
   returns 0. Mach-O binaries will work fine inside Darling without signatures.

2. **Patch stdenv**: Override the Darwin stdenv to skip the signing fixup phase
   when running inside Darling. Detect this via an environment variable
   (e.g., `NIX_DARLING=1`).

3. **Use `sigtool`**: Recent Nixpkgs uses a pure-Nix `sigtool` for ad-hoc
   signing that may actually work since it's just modifying Mach-O bytes.
   Test before assuming it fails.

**Recommendation**: Test option 3 first. If it fails, use option 1 (quickest).
Option 2 is cleanest but requires Nixpkgs patching.

---

## Verification Checklist

After completing Phase 4, ALL of the following must pass:

- [ ] Trivial derivation (4.1) builds and produces correct output
- [ ] Derivation using Nix's bash from the store (4.3) builds successfully
- [ ] `nix-store -r` fetches packages from `cache.nixos.org` without errors
- [ ] NAR unpacking works for at least 10 different packages
- [ ] `nix-build '<nixpkgs>' -A hello --system x86_64-darwin` succeeds
- [ ] The built `hello` binary runs and prints "Hello, world!"
- [ ] `nix-store --verify-path` confirms the output is valid
- [ ] No "Unimplemented syscall" messages during the build
- [ ] No segfaults during the build
- [ ] `nix-collect-garbage` runs without errors (exercises store deletion + `lchflags`)

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| clang crashes inside Darling | Medium | Critical — can't compile anything | Test clang standalone first; may need specific dyld/ABI fixes |
| ld64 produces bad Mach-O output | Low | Critical — binaries won't run | Compare output with real macOS build; use `otool -L` to verify |
| Stdenv setup script uses unsupported shell features | Low | High — all builds fail | Test bash compatibility thoroughly in 4.2 |
| Binary cache signatures fail verification | Low | High — no substitution | Check Nix's ed25519 verification code path; may need `libsodium` to work |
| Build takes hours due to Darling overhead | High | Medium — usable but slow | Focus on binary substitution; only build what can't be fetched |
| Race conditions from incomplete `fcntl` locking | Medium | Medium — intermittent failures | Test concurrent builds only in Phase 5; keep Phase 4 single-threaded |

---

## Performance Expectations

Darling adds overhead to every syscall (Darwin → Linux translation). Expect:

- **Evaluation**: ~2–5× slower than native Linux Nix evaluation. The Nix
  evaluator is CPU-bound, so the overhead is mostly from dyld and library
  translation, not syscall volume.

- **Binary substitution**: ~1.5–2× slower. Network I/O dominates; the overhead
  is in NAR unpacking (filesystem syscalls).

- **Compilation**: ~3–10× slower. Compilation is both CPU-intensive and makes
  many syscalls (file reads, process spawning). The `clang` → `ld64` pipeline
  inside Darling will be noticeably slower than on native macOS.

- **Disk usage**: Each Darling prefix uses overlayfs, so the base system files
  are shared. The Nix store will be the main disk consumer. Plan for ~10–20 GB
  for a basic set of packages.

These are rough estimates. Actual performance will depend heavily on the host
hardware and which syscalls are hot. Profiling after Phase 4 is complete will
identify optimisation opportunities.

---

*[← Phase 3 — Nix Installation](./05-phase3-nix-install.md) | [Phase 5 — Nix Daemon →](./07-phase5-daemon.md)*