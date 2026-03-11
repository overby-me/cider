# Background & Motivation

## Why This Matters

The Nix ecosystem currently has no way to build or test `x86_64-darwin`
derivations without access to real Apple hardware (or a macOS VM that requires
macOS licensing). This is a serious limitation for:

- **Open-source CI**: Projects that need to verify their Darwin builds cannot do
  so on commodity Linux infrastructure.
- **Cross-compilation verification**: Even when cross-compiling *to* Darwin, the
  resulting binaries cannot be smoke-tested without macOS.
- **Nixpkgs maintenance**: Darwin breakage often goes unnoticed until a macOS
  user reports it.

[Darling](https://www.darlinghq.org/) is an open-source Darwin/macOS
translation layer for Linux — conceptually the same as Wine, but for macOS
instead of Windows. If Darling can run the Nix package manager and reliably
execute Nix-built Darwin binaries, we unlock the ability to build and test
`x86_64-darwin` packages on Linux.

## Prior Art

The [nixie-dev/darling-nix](https://github.com/nixie-dev/darling-nix) project
has already demonstrated that Darling can be packaged with Nix and integrated
with NixOS module tests. Their overlay builds Darling from source with
`clangStdenv` and provides a `darling` package plus an SDK output with `ld64`
and `ar`/`ranlib` from cctools-port.

A [blog post by ersei](https://ersei.net/en/blog/nix-all-the-way-down)
documented an end-to-end attempt at installing Nix inside Darling, identifying
concrete blockers along the way. Key findings from that effort:

- The Nix installer fails because `xmllint`, `diskutil info`, and `dseditgroup`
  are missing or unimplemented in Darling.
- The installer forces multi-user mode on Darwin; single-user mode requires
  manual patching.
- `lchflags` fails with `EINVAL` during `nix-env` profile installation because
  `setattrlist` is not implemented.
- Even after binary-patching `libnixstore.dylib` to skip the `lchflags` error
  check, `sandbox-exec` is missing so builds fail.
- Setting `_NIX_TEST_NO_SANDBOX=1` gets past that, but then `mv` crashes on
  unimplemented syscall 488 (`renameatx_np`) and `touch` segfaults.
- Various other programs (e.g. `fish`) crash with `Illegal instruction` due to
  incomplete syscall coverage.
- After extensive workarounds (replacing broken coreutils in the store, removing
  docs from home-manager, etc.), Nix + home-manager + neovim were eventually
  made to work, but the result was fragile and required many manual
  interventions.

This plan synthesizes those findings with our own code analysis of the Darling
source tree into an actionable roadmap.

---

## Current State of Affairs

### What Works

- Darling boots a macOS-like container with `darling shell`.
- Basic command-line utilities (`echo`, `ls`, `cp`, etc.) function.
- The Darling prefix (`~/.darling`) provides an overlayfs-backed macOS-like
  filesystem hierarchy.
- DMG/XIP images can be mounted and Xcode command-line tools can be installed.
- Simple C programs can be compiled and executed using Apple's toolchain.
- Darling can be built with Nix via the `nixie-dev/darling-nix` overlay and
  ships as part of upstream nixpkgs.
- The `darlingserver` provides userspace syscall translation (no kernel module
  required on modern builds).

### What Does Not Work (for Nix)

| Issue | Root Cause | Severity |
|---|---|---|
| `lchflags()` returns `EINVAL` | `setattrlist()` not implemented | **Blocker** |
| `/usr/bin/sandbox-exec` missing | Sandbox framework is stubbed | **Blocker** |
| `mv` crashes (`Unimplemented syscall 488`) | `renameatx_np` / `renameat2` not implemented | **Blocker** |
| `touch` segfaults | Likely missing `utimensat` or file-flag syscall | **Blocker** |
| Nix installer forces multi-user on Darwin | Installer script checks `uname` | High |
| `diskutil info` not implemented | `diskutil` is a shell script supporting only `eject` | Medium |
| `xmllint` missing | Not shipped in Darling | Medium |
| `dseditgroup` / Directory Services missing | User/group management unimplemented | Medium |
| `posix_spawn` + `POSIX_SPAWN_SETEXEC` → `ENOEXEC` | Incomplete `posix_spawn` attribute support | High |
| dyld cache load errors | Shared cache not generated for prefix | Medium |
| Sporadic segfaults in various programs | Incomplete syscall/ABI coverage | High |
| Darling reports macOS 10.15 (Catalina) | Newer Nix binaries target ≥ 11.0 | Medium |

### Relevant Source Locations in This Repo

| Area | Path | Notes |
|---|---|---|
| Sandbox stubs | `src/sandbox/sandbox.c` | All functions return "Not implemented" or 0 |
| Sandbox library | `src/libsandbox/` | `libsandbox.1.dylib` — thin shim |
| Syscall translation | `src/external/darlingserver/` | Submodule (empty until checked out) |
| libc wrappers | `src/external/libc/` | Darwin libc with BSD syscall wrappers |
| launchd | `src/launchd/` | Process management, uses `posix_spawn` |
| diskutil | `src/diskutil/diskutil` | Shell script, only supports `eject` verb |
| duct tape shims | `src/duct/src/` | Minimal stubs for `acl`, `dns_sd`, etc. |
| Build system | `CMakeLists.txt` | Top-level; deployment target is 11.0 |
| CI (current) | `.github/workflows/actions.yaml` | Debian-only, no Nix |

---

*Next: [Known Blockers →](./01-blockers.md)*