# Architecture & Key Technical Decisions

This document describes the high-level system architecture and records the
rationale behind major technical decisions. It serves as a reference for
contributors who need to understand *why* things are designed the way they are,
not just *what* to build.

---

## System Architecture

### Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Linux Host (NixOS)                            │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  Host Nix Daemon                                              │  │
│  │  ┌──────────────────────────────────────────────────────────┐  │  │
│  │  │  nix.buildMachines = [{                                  │  │  │
│  │  │    hostName = "127.0.0.1"; port = 2222;                  │  │  │
│  │  │    systems = ["x86_64-darwin"];                           │  │  │
│  │  │  }]                                                      │  │  │
│  │  └────────────────────┬─────────────────────────────────────┘  │  │
│  └───────────────────────┼────────────────────────────────────────┘  │
│                          │ SSH / darling-exec                        │
│  ┌───────────────────────▼────────────────────────────────────────┐  │
│  │  Darling Container (overlayfs prefix at ~/.darling)            │  │
│  │                                                                │  │
│  │  ┌──────────────────────────────────────────────────────────┐  │  │
│  │  │  darlingserver                                           │  │  │
│  │  │  • Translates Darwin/XNU syscalls → Linux syscalls       │  │  │
│  │  │  • Manages Mach-O loading via mldr + dyld                │  │  │
│  │  │  • Provides namespace isolation (mount, PID, user)       │  │  │
│  │  └──────────────────────────────────────────────────────────┘  │  │
│  │                                                                │  │
│  │  ┌─────────────────┐  ┌──────────────────────────────────┐    │  │
│  │  │  Darwin Userland │  │  Nix (Darwin build)              │    │  │
│  │  │  • dyld          │  │  • nix / nix-daemon              │    │  │
│  │  │  • libSystem     │  │  • nix-build / nix-store         │    │  │
│  │  │  • libc          │  │  • sandbox-exec stub             │    │  │
│  │  │  • CoreFoundation│  │  • curl, bash, coreutils         │    │  │
│  │  │  • libdispatch   │  │  • clang, ld64 (from stdenv)     │    │  │
│  │  │  • Obj-C runtime │  │  • Darwin stdenv build machinery │    │  │
│  │  └─────────────────┘  └──────────────────────────────────┘    │  │
│  │                                                                │  │
│  │  /nix/store ──symlink──▶ /Volumes/SystemRoot/nix/store        │  │
│  │  /dev, /proc ──mount──▶ host kernel interfaces                │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  /nix/store  (shared filesystem — single source of truth)            │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Role | Location |
|---|---|---|
| **darlingserver** | Userspace syscall translator. Intercepts Mach/BSD traps from Darwin binaries and translates them to Linux equivalents. Manages the container namespace. | `src/external/darlingserver/` (submodule) |
| **mldr** | Mach-O loader. Loads Darwin Mach-O executables on Linux, sets up the process image, and hands off to `dyld`. | `src/libelfloader/` |
| **dyld** | Apple's dynamic linker. Resolves `@rpath`, `@loader_path`, loads `.dylib` dependencies. Runs inside the translated environment. | `src/external/dyld/` |
| **libSystem / libc** | Darwin's standard C library. Provides POSIX wrappers (`lchflags`, `setattrlist`, `posix_spawn`, etc.) that ultimately invoke darlingserver-translated syscalls. | `src/external/libc/`, `src/external/libsystem/` |
| **sandbox-exec stub** | Passthrough shim replacing Apple's `sandbox-exec`. Ignores sandbox profiles and directly `exec`s the builder command. | `src/sandbox-exec/` (to be created, Phase 2) |
| **Nix (Darwin)** | The Nix package manager compiled for `x86_64-darwin`, fetched from the official binary cache. Runs inside Darling as a Darwin process. | `/nix/store/...-nix-*/` inside the prefix |
| **Host Nix Daemon** | The Linux-native Nix daemon that orchestrates builds. Offloads `x86_64-darwin` builds to the Darling instance via SSH or a custom build hook. | Standard NixOS `nix-daemon.service` |
| **Darling prefix** | An overlayfs-backed directory (`~/.darling`) that provides a macOS-like filesystem hierarchy. System files are read-only from the Darling installation; user/build files are writable in the upper layer. | `~/.darling/` (runtime) |

### Data Flow: Building a Darwin Derivation

```
1. User:           nix build .#myPkg --system x86_64-darwin
                         │
2. Host Nix Daemon:      Identifies x86_64-darwin → selects Darling builder
                         │
3. SSH transport:        Connects to sshd inside Darling (port 2222)
                         │
4. Darling nix-daemon:   Receives build request
                         │
5. Nix build setup:      Creates /tmp/nix-build-myPkg.drv-0/
                         Writes .sandbox.sb profile
                         │
6. sandbox-exec stub:    Ignores profile, exec's /bin/bash
                         │
7. bash builder:         Sources $stdenv/setup
                         Runs unpack → configure → build → install → fixup
                         │
8. Syscall translation:  Every Darwin syscall (open, stat, mmap, posix_spawn,
                         lchflags, renameatx_np, ...) goes through darlingserver
                         and becomes the Linux equivalent
                         │
9. Build output:         Written to /nix/store/...-myPkg
                         │
10. Store registration:  nix-daemon registers the path in SQLite
                         │
11. Shared store:        Output is immediately visible to the host
                         (shared /nix/store via bind mount / symlink)
                         │
12. Host Nix Daemon:     Marks the build as complete, returns result to user
```

---

## Key Technical Decisions

### Decision 1: Syscall Implementation Depth

**Decision**: Implement syscalls to the minimum depth required for Nix, not for
general macOS compatibility.

**Rationale**: Full macOS API coverage is a multi-year effort (and the upstream
Darling project's ongoing goal). We should be surgical about what we implement.
For example:

- `setattrlist` only needs to handle `ATTR_CMN_FLAGS` for clearing
  `UF_IMMUTABLE`. We don't need full Finder-info, resource-fork, or ACL
  support through this API.
- `clonefile` can return `ENOTSUP` — Nix gracefully falls back to regular copy.
- `sandbox_init` can return success with a NULL error buffer — Darling's
  namespace isolation is already sufficient.

**Trade-off**: Some non-Nix Darwin programs may still fail. That's acceptable —
this project's scope is Nix support, not universal macOS compatibility.

**How this affects contributors**: When implementing a syscall, always check
what the *caller* actually needs. Read the Nix source (or whatever Nix-ecosystem
program is calling it) and implement only what's required to make that caller
succeed. Document the scope of the implementation in code comments.

---

### Decision 2: Sandbox Strategy

**Decision**: Start with a `sandbox-exec` stub that passes through to `exec`.
Do NOT attempt to implement Apple's Sandbox Profile Language initially.

**Rationale**: Nix's sandbox on Darwin is defense-in-depth. The macOS sandbox
(`sandbox-exec` + `.sb` profiles) restricts file access, network access, and
process operations during builds. Inside Darling, we already have:

1. **Linux namespace isolation**: The Darling container uses mount namespaces
   (overlayfs), PID namespaces, and optionally network namespaces. This provides
   equivalent-or-stronger isolation to macOS's sandbox for build purposes.

2. **Nix's own isolation**: Nix controls `$PATH`, `$HOME`, `$TMPDIR`, and other
   environment variables. The build environment is intentionally spartan. The
   macOS sandbox adds a second layer, but its absence doesn't fundamentally
   compromise build isolation.

3. **No untrusted code**: In the Nix builder context, the code being executed
   comes from derivations the user has chosen to build. The sandbox prevents
   accidental side effects (e.g., a build script accidentally writing to `/usr`),
   not malicious code execution.

**When to revisit**: If Darling is ever used to run arbitrary untrusted macOS
software (not just Nix builds), proper sandbox support becomes important. See
[Phase 2, task 2.4](./04-phase2-sandbox.md#24--stretch-basic-sandbox-profile-language-parsing)
for the stretch-goal design.

---

### Decision 3: Single-User vs. Multi-User Nix

**Decision**: Target single-user mode first (Phase 3), add multi-user later
(Phase 5).

**Rationale**: Single-user mode has far fewer moving parts:

| Aspect | Single-User | Multi-User |
|---|---|---|
| Daemon required | No | Yes |
| Build users required | No | Yes (30+ users) |
| Directory Services required | No | Yes (`dseditgroup`, `sysadminctl`) |
| `launchd` integration | No | Yes |
| `setuid` / privilege separation | No | Yes |
| Concurrent builds | No | Yes |
| Suitable for development/testing | Yes | Yes |
| Suitable for production builders | Maybe | Yes |

Single-user mode is sufficient for the MVP (Phases 0–4). It lets us validate
that Nix works inside Darling without solving the much harder problems of user
management and privilege separation inside a namespace-based container.

---

### Decision 4: Shared vs. Separate Nix Store

**Decision**: Share the host's `/nix/store` with the Darling prefix via the
existing `/Volumes/SystemRoot` mount.

**Rationale**:

- **Avoids duplicating store contents.** A typical Nix closure for building
  Darwin packages is 500 MB–2 GB. Duplicating this inside the Darling prefix
  wastes disk and slows down builds (SSH copy overhead).

- **Host Nix daemon can manage garbage collection.** With a shared store, there's
  a single GC root set. Without sharing, the Darling-side store accumulates
  garbage that's invisible to the host's `nix-collect-garbage`.

- **Darwin build outputs are immediately available on the host.** No need to
  copy results back after a build completes — the output is already in the
  shared `/nix/store`.

**Implementation**:

```
# Inside the Darling prefix:
/nix → /Volumes/SystemRoot/nix    (symlink)
     → /nix/store                 (host's store, shared)
     → /nix/var                   (Darling-local state, NOT shared)
```

The store content (`/nix/store`) is shared, but the state
(`/nix/var/nix/db/db.sqlite`, `/nix/var/nix/daemon-socket/`, etc.) is
Darling-local. This prevents database conflicts between the host and Darling
Nix instances.

**Caveat**: Darling's overlayfs may interfere with writes to the shared store.
If so, use a direct bind mount (`mount --bind /nix/store ~/.darling/nix/store`)
during prefix initialization, bypassing the overlayfs upper layer for the store
directory. Test this during Phase 3.

**Fallback**: If shared store causes issues (permission mismatches, locking
conflicts, overlayfs quirks), fall back to a fully separate store inside the
Darling prefix. This is simpler but slower (requires SSH-based store path
transfer for the remote builder in Phase 7).

---

### Decision 5: macOS Version Target

**Decision**: Target macOS 11.0 (Big Sur) as the emulated version.

**Rationale**:

- Darling's `CMakeLists.txt` already sets `CMAKE_OSX_DEPLOYMENT_TARGET` to 11.0.
- Nixpkgs' Darwin stdenv targets macOS 11.0+ for `x86_64-darwin` builds.
- The official Nix binary cache (`cache.nixos.org`) serves binaries built with
  `-mmacosx-version-min=11.0` or higher.
- macOS 10.15 (Catalina, which Darling currently reports at runtime) is past
  end-of-life and increasingly unsupported by modern software.

**What this means**:

- `sw_vers` inside Darling should report `ProductVersion: 11.0`.
- `__MAC_OS_X_VERSION_MIN_REQUIRED` should be `110000` (Big Sur).
- Any `@available(macOS 11.0, *)` checks in Darling's libraries should evaluate
  to true.
- APIs introduced in Big Sur (e.g., `os_log` improvements, certain
  `posix_spawn` attributes) should be available or gracefully stubbed.

**Risk**: Bumping the version may expose new code paths in Darling's libraries
that call unimplemented APIs. This is acceptable — it surfaces real issues rather
than papering over them with an artificially old version number.

---

### Decision 6: CI Strategy

**Decision**: Use NixOS VM tests as the primary CI mechanism, with lighter-weight
build-only tests for fast feedback.

**Rationale**: Darling requires Linux namespace support (user namespaces,
overlayfs, mount namespaces) that isn't available inside a standard container or
Nix build sandbox. NixOS VM tests provide a full Linux kernel, which guarantees
the necessary capabilities.

**Trade-off**: VM tests are slow (5–30 minutes). We mitigate this with:

1. A fast "build smoke test" that just builds Darling (no VM, runs in Nix
   sandbox). Catches compilation regressions in ~10 minutes.
2. Binary caching (Cachix) so that the Darling build itself is rarely rebuilt
   from scratch in CI.
3. Parallelised test jobs — the build test and VM test run concurrently.
4. Path-based CI triggers — documentation-only changes skip the VM test.

See [Phase 6](./08-phase6-ci.md) for full CI design.

---

### Decision 7: SSH vs. Custom Build Hook for Remote Builds

**Decision**: Use SSH-based remote builds as the primary mechanism. A custom
build hook is a secondary optimisation.

**Rationale**:

| Aspect | SSH Remote Builder | Custom Build Hook |
|---|---|---|
| Protocol maturity | Battle-tested, standard Nix feature | Custom, must handle edge cases |
| Setup complexity | Moderate (sshd + keys) | Low (single script) |
| Store transfer | Built-in (SSH or shared mount) | Must be implemented |
| Build log streaming | Built-in | Must be implemented |
| Error handling | Built-in | Must be implemented |
| Nix version coupling | Low (protocol is stable) | High (hook interface can change) |

SSH remote builds are the standard way to offload Nix builds to another machine.
Even though Darling runs on the same host, treating it as a "remote" builder via
SSH reuses all of Nix's existing remote-build infrastructure — derivation
closure transfer, build log streaming, result retrieval, and error handling.

The custom build hook (calling `darling shell` directly) avoids SSH overhead and
is simpler to set up, but it requires reimplementing protocol details that SSH
remote builds handle automatically. It's better suited as an optimisation after
the SSH approach is proven.

See [Phase 7](./09-phase7-remote-builder.md) for both approaches.

---

## Subsystem Map

A quick reference for where to find things in the Darling source tree:

```
darling-nix/
├── plan/                          # This planning documentation
├── src/
│   ├── sandbox/                   # sandbox_init, sandbox_check, etc. (stubs)
│   │   └── sandbox.c             # ← Fix errorbuf handling (Phase 2.2)
│   ├── libsandbox/               # libsandbox.1.dylib shim
│   ├── diskutil/                  # diskutil shell script (eject only)
│   ├── duct/src/                  # Minimal shims (acl, dns_sd, os_log)
│   ├── launchd/                   # launchd + launchctl implementation
│   │   ├── src/core.c            # posix_spawn usage for job management
│   │   └── support/launchctl.c   # launchctl CLI, uses lchflags
│   ├── external/
│   │   ├── darlingserver/         # ← Main syscall translation (submodule)
│   │   ├── libc/                  # Darwin libc (lchflags, setattrlist wrappers)
│   │   ├── xnu/                   # XNU kernel headers + libsystem_kernel
│   │   │   └── darling/src/libsystem_kernel/  # BSD syscall stubs
│   │   ├── dyld/                  # Apple's dynamic linker
│   │   ├── libsystem/            # libSystem umbrella library
│   │   ├── corefoundation/       # CoreFoundation framework
│   │   ├── foundation/           # Foundation framework (NSFileManager, etc.)
│   │   ├── libdispatch/          # Grand Central Dispatch
│   │   ├── objc4/runtime/        # Objective-C runtime
│   │   ├── openssh/              # OpenSSH (sshd for remote builder)
│   │   ├── bash/                 # Darling's built-in bash
│   │   ├── cctools-port/         # ld64, ar, ranlib (Apple linker tools)
│   │   ├── swift/                # Swift runtime libraries
│   │   └── ...                   # ~100 more submodules
│   ├── native/                   # Linux-native wrappers (wraps ELF libs for Darwin use)
│   ├── frameworks/               # macOS frameworks (AppKit, CoreGraphics, etc.)
│   └── private-frameworks/       # Private frameworks (Bom, etc.)
├── CMakeLists.txt                # Top-level build configuration
├── .gitmodules                   # Submodule definitions (~100 entries)
├── .github/workflows/            # CI (currently Debian-only)
└── tools/                        # Build/install utilities
```

### Where Syscall Changes Go

```
User code (e.g. Nix) calls lchflags()
         │
         ▼
src/external/libc/        ← Darwin libc wrapper: translates to setattrlist()
         │
         ▼
src/external/xnu/darling/src/libsystem_kernel/   ← BSD syscall stub:
                                                    packages args into a trap
         │
         ▼
src/external/darlingserver/   ← Handles the trap on the Linux side:
                                translates setattrlist → ioctl/utimensat/etc.
         │
         ▼
Linux kernel                  ← Actual filesystem operation
```

Understanding this call chain is essential for debugging. If `lchflags` fails:

1. Is the libc wrapper calling the right syscall number? → Check `src/external/libc/`
2. Is the syscall number wired in the kernel trap table? → Check `src/external/xnu/.../libsystem_kernel/`
3. Is darlingserver handling it? → Check `src/external/darlingserver/`
4. Is the Linux translation correct? → `strace` on the darlingserver process

---

## Glossary

| Term | Meaning |
|---|---|
| **Darling prefix** (DPREFIX) | The overlayfs-backed directory (`~/.darling`) that provides the macOS filesystem hierarchy. Analogous to Wine's WINEPREFIX. |
| **darlingserver** | The userspace process that handles Darwin syscall translation. Replaces the earlier LKM (Linux Kernel Module) approach. |
| **mldr** | Mach-O loader — the ELF-side binary that loads a Mach-O executable and sets up the Darling execution environment. |
| **dyld** | Apple's dynamic linker. Handles `@rpath`, `@loader_path`, and `.dylib` loading within the Darwin process. |
| **Mach-O** | The executable format used by macOS (analogous to ELF on Linux). |
| **libSystem** | macOS's umbrella system library (analogous to `libc.so` on Linux but includes more). Contains libc, libm, libpthread, etc. |
| **stdenv** | Nix's standard build environment. The Darwin stdenv provides clang, ld64, Apple SDK headers, and shell scripts for the build phases. |
| **NAR** | Nix Archive — Nix's serialisation format for store paths. Used for binary substitution (downloading pre-built packages). |
| **Binary substitution** | Downloading pre-built packages from a binary cache instead of building from source. Critical for performance inside Darling. |
| **sandbox-exec** | macOS's command-line sandbox tool. Applies a Sandbox Profile (`.sb` file) before executing a command. Nix uses this for build isolation on Darwin. |
| **SBPL** | Sandbox Profile Language — the Scheme-based DSL used in `.sb` files to define sandbox rules. |
| **cctools** | Apple's binary tools suite (`ld64`, `ar`, `ranlib`, `otool`, `install_name_tool`). Darling uses the `cctools-port` fork that builds on Linux. |
| **overlayfs** | Linux filesystem that layers a writable upper directory over a read-only lower directory. Darling uses this for prefixes so the base system is shared and user changes are isolated. |

---

*[← Phase 8 — Stretch Goals](./10-phase8-stretch.md) | [Back to Plan Index](./README.md)*