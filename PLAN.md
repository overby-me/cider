# PLAN: Making Darling Fully Capable of Running Nix

> **Goal**: Enable Darling (macOS compatibility layer for Linux) to run the Nix
> package manager reliably, so that Linux machines can build, test, and
> cross-compile `x86_64-darwin` Nix derivations — analogous to how Wine enables
> building and testing Windows binaries on Linux.

The full plan has been split into focused documents to keep context manageable.
See the **[plan/](./plan/)** directory for all details.

## Progress Summary

| Phase | Status | Key Files |
|-------|--------|-----------|
| Phase 0 — Packaging | ✅ Done | `flake.nix`, `nix/package.nix`, `nix/devShell.nix`, `nix/nixosModule.nix`, `.envrc` |
| Phase 1 — Syscalls | 🚧 In progress | [Triage table](./plan/syscall-triage.md) |
| Phase 2 — Sandbox | 🚧 In progress | `src/sandbox/sandbox.c` (fixed), `src/sandbox-exec/` (new), `tests/sandbox/` (new) |
| Phase 3 — Nix Install | 🚧 In progress | `scripts/install-nix-in-darling.sh` (new), `scripts/darling-nix` (new) |
| Phase 4 — Building | 📋 Planned | — |
| Phase 5 — Daemon | 📋 Planned | — |
| Phase 6 — CI | 🚧 In progress | `.github/workflows/nix.yml` (new) |
| Phase 7 — Remote Builder | 📋 Planned | — |
| Phase 8 — Stretch | 📋 Planned | — |

### Recently Completed

- **Phase 1.3**: Implemented `renameatx_np` (macOS syscall 488) — new file
  `src/external/xnu/.../impl/unistd/renameatx_np.c` translates to Linux
  `renameat2(2)` with flag mapping: `RENAME_SWAP` → `RENAME_EXCHANGE`,
  `RENAME_EXCL` → `RENAME_NOREPLACE`. Wired into syscall table at slot 488.
- **Phase 1.1**: Extended `setattrlist` / `fsetattrlist` / `setattrlistat` to
  support `ATTR_CMN_FLAGS` — the core blocker for `lchflags(path, 0)` which
  Nix calls during profile installation. Also added `ATTR_CMN_CRTIME` and
  `ATTR_CMN_CHGTIME` (silently ignored). Extended `getattrlist` /
  `fgetattrlist` / `getattrlistat` to return `flags = 0` when
  `ATTR_CMN_FLAGS` is requested, enabling read-modify-write flag cycles.
- **Phase 1.5**: Changed `clonefile` / `fclonefileat` stubs from `ENOSYS` to
  `ENOTSUP` so Nix gracefully falls back to regular read/write copy instead
  of treating it as a fatal unimplemented-syscall error.
- **Phase 1.6**: Verified `getentropy` (syscall 500) already works — maps to
  Linux `getrandom(2)`, no changes needed.
- **Testing**: Created `tests/syscall/test_renameatx_np.c` (renameatx_np
  regression tests: plain rename, RENAME_SWAP, RENAME_EXCL, invalid flags)
  and `tests/syscall/test_setattrlist_flags.c` (setattrlist/getattrlist
  ATTR_CMN_FLAGS tests: lchflags, chflags, symlinks, combined attrs,
  fsetattrlist, read-modify-write cycle).
- **Phase 2.2**: Fixed `sandbox_init`, `sandbox_init_with_parameters`,
  `sandbox_init_with_extensions`, and `sandbox_wakeup_daemon` — they now set
  `*errorbuf = NULL` on success instead of `strdup("Not implemented")`, and
  guard against NULL `errorbuf` pointers.
- **Phase 2.1**: Created `sandbox-exec` stub at `src/sandbox-exec/sandbox-exec.c`
  — a small C program that parses and ignores all sandbox flags (`-f`, `-p`,
  `-n`, `-D`) then `exec`s the remaining command. Wired into the CMake build
  via `src/sandbox-exec/CMakeLists.txt`; installs to
  `libexec/darling/usr/bin/sandbox-exec`.
- **Blocker mitigation**: Extended `src/diskutil/diskutil` with `info` and
  `list` verb stubs so the Nix installer's filesystem-type check succeeds.
- **Phase 3.1**: Created `scripts/install-nix-in-darling.sh` — automated
  installer that downloads, patches, and runs the Nix Darwin installer inside
  a Darling prefix in single-user mode.
- **Phase 3.4**: Created `scripts/darling-nix` — host-side wrapper for running
  Nix commands inside Darling without manual `darling shell bash -lc` boilerplate.
- **Phase 6.3**: Created `.github/workflows/nix.yml` — Nix CI workflow with
  flake check, package build, devShell evaluation, and smoke tests.
- **Phase 1.7**: Created `plan/syscall-triage.md` — tracking table for
  unimplemented syscalls with categories, impact levels, and discovery log.
- **Testing**: Created `tests/sandbox/test_sandbox_api.c` (C-level sandbox API
  tests) and `tests/sandbox/test_sandbox_exec.sh` (shell-level sandbox-exec
  integration tests).

## Quick Navigation

| Document | Description |
|---|---|
| [plan/README.md](./plan/README.md) | **Start here** — index, priority table, effort estimates |
| [plan/00-background.md](./plan/00-background.md) | Motivation, what works today, what doesn't |
| [plan/01-blockers.md](./plan/01-blockers.md) | Detailed analysis of each blocking issue |
| [plan/02-phase0-packaging.md](./plan/02-phase0-packaging.md) | `flake.nix`, devShell, `.envrc`, NixOS module |
| [plan/03-phase1-syscalls.md](./plan/03-phase1-syscalls.md) | `setattrlist`, `renameatx_np`, `utimensat`, etc. |
| [plan/04-phase2-sandbox.md](./plan/04-phase2-sandbox.md) | `sandbox-exec` passthrough, sandbox API stubs |
| [plan/05-phase3-nix-install.md](./plan/05-phase3-nix-install.md) | Automated installer, verification, wrappers |
| [plan/06-phase4-building.md](./plan/06-phase4-building.md) | Trivial derivations → stdenv → binary substitution |
| [plan/07-phase5-daemon.md](./plan/07-phase5-daemon.md) | Multi-user mode, Directory Services stubs, launchd |
| [plan/08-phase6-ci.md](./plan/08-phase6-ci.md) | NixOS VM tests, regression suite, GitHub Actions |
| [plan/09-phase7-remote-builder.md](./plan/09-phase7-remote-builder.md) | Darling as a `nix.buildMachines` target |
| [plan/10-phase8-stretch.md](./plan/10-phase8-stretch.md) | `aarch64-darwin`, GUI testing, Hydra builder |
| [plan/11-architecture.md](./plan/11-architecture.md) | System diagram, key technical decisions, glossary |
| [plan/syscall-triage.md](./plan/syscall-triage.md) | Tracking table for unimplemented syscalls |

## New File Map

Files created or modified as part of this plan:

```text
darling-nix/
├── .github/workflows/nix.yml          # Nix CI workflow (Phase 6)
├── flake.nix                           # Flake with package, devShell, NixOS module (Phase 0)
├── nix/
│   ├── package.nix                     # Darling Nix derivation (Phase 0)
│   ├── devShell.nix                    # Developer shell (Phase 0)
│   └── nixosModule.nix                 # NixOS module (Phase 0)
├── scripts/
│   ├── install-nix-in-darling.sh       # Automated Nix installer (Phase 3)
│   └── darling-nix                     # Host-side Nix command wrapper (Phase 3)
├── src/
│   ├── sandbox/sandbox.c               # Fixed sandbox API stubs (Phase 2)
│   ├── sandbox-exec/                   # NEW — sandbox-exec stub (Phase 2)
│   │   ├── CMakeLists.txt
│   │   └── sandbox-exec.c
│   └── diskutil/diskutil               # Extended with info/list verbs (Phase 3)
├── tests/
│   ├── sandbox/                        # NEW — sandbox regression tests
│   │   ├── test_sandbox_api.c          # C-level sandbox API tests
│   │   └── test_sandbox_exec.sh        # Shell-level sandbox-exec tests
│   └── syscall/                        # NEW — syscall regression tests
│       ├── test_renameatx_np.c         # renameatx_np tests (Phase 1)
│       └── test_setattrlist_flags.c    # setattrlist ATTR_CMN_FLAGS tests (Phase 1)
└── plan/
    ├── README.md                       # Index + priority table
    ├── 00-background.md                # Motivation & current state
    ├── 01-blockers.md                  # Blocking issues analysis
    ├── 02-phase0-packaging.md          # Phase 0 details
    ├── 03-phase1-syscalls.md           # Phase 1 details
    ├── 04-phase2-sandbox.md            # Phase 2 details
    ├── 05-phase3-nix-install.md        # Phase 3 details
    ├── 06-phase4-building.md           # Phase 4 details
    ├── 07-phase5-daemon.md             # Phase 5 details
    ├── 08-phase6-ci.md                 # Phase 6 details
    ├── 09-phase7-remote-builder.md     # Phase 7 details
    ├── 10-phase8-stretch.md            # Phase 8 details
    ├── 11-architecture.md              # Architecture & decisions
    └── syscall-triage.md               # NEW — syscall tracking table
```

## What's Next

The **critical path to MVP** (Nix running inside Darling) is:

1. **Phase 1 — Remaining syscall work**: The core syscall blockers
   (`renameatx_np`, `setattrlist`/`getattrlist` with `ATTR_CMN_FLAGS`,
   `clonefile` stub) are now implemented. Remaining Phase 1 tasks:
   - **Task 1.4** (`utimensat` audit): Debug whether Nix's `touch` segfault
     is now resolved by the `setattrlist` fixes (it may have been calling
     `setattrlistat` under the hood). If not, trace the exact failing call.
   - **Task 1.7** (triage): Run Nix inside Darling with tracing enabled and
     collect any remaining "Unimplemented syscall" messages.
   - **Task 1.8** (version bump): Update emulated macOS version to 11.0+.

2. **Build & test**: Build Darling with the new syscall implementations and
   run the regression tests in `tests/syscall/` and `tests/sandbox/` inside
   `darling shell` to verify everything works end-to-end.

3. **Phase 3 — Nix installation**: With the syscall fixes in place, run
   `scripts/install-nix-in-darling.sh` and iterate on any remaining issues.
   This is now much closer to working since the `lchflags` and `mv` blockers
   are resolved.

See [plan/README.md](./plan/README.md) for the full priority table and effort
estimates.