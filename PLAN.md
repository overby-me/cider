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
| Phase 1 — Syscalls | ✅ Core done, triage ongoing | [Triage table](./plan/syscall-triage.md) |
| Phase 2 — Sandbox | ✅ Done | `src/sandbox/sandbox.c` (fixed), `src/sandbox-exec/` (new), `tests/sandbox/` (new) |
| Phase 3 — Nix Install | 🚧 In progress | `scripts/install-nix-in-darling.sh`, `scripts/darling-nix`, `scripts/verify-nix.sh` |
| Phase 4 — Building | 🚧 Tooling ready | `scripts/build-trivial.sh` (new) |
| Phase 5 — Daemon | 🚧 Stubs done | `src/dirserv/` (new), `tests/dirserv/` (new) |
| Phase 6 — CI | 🚧 In progress | `.github/workflows/nix.yml`, `tests/darling-smoke.nix`, `tests/nix-in-darling.nix` (new) |
| Phase 7 — Remote Builder | 📋 Planned | — |
| Phase 8 — Stretch | 📋 Planned | — |

### Recently Completed

- **Phase 5.1 — Directory Services stubs**: Created `src/dirserv/` with three
  shell-script stubs (`dseditgroup`, `sysadminctl`, `dscl`) that translate
  macOS Directory Services commands to direct `/etc/passwd` and `/etc/group`
  file operations within the Darling prefix. These are required by the Nix
  multi-user installer to create the `nixbld` group and `_nixbldN` build users.
  - `dseditgroup`: create/delete/edit groups, add/remove members, checkmember,
    read group info. Idempotent operations, input validation.
  - `sysadminctl`: addUser/deleteUser with UID, GID, home, shell, fullName.
    Handles `-password`, `-adminUser`, `-roleAccount` flags (ignored). Idempotent.
  - `dscl`: read/list/create/delete/append/search on `/Users` and `/Groups`
    paths. Supports `.` and `/Local/Default` datasources. Full key coverage
    for Nix installer needs (UniqueID, PrimaryGroupID, NFSHomeDirectory,
    UserShell, RealName, GroupMembership, etc.).
  - Wired into CMake build via `src/dirserv/CMakeLists.txt`; installs to
    `libexec/darling/usr/sbin/`.
  - Comprehensive test suite: `tests/dirserv/test_dirserv.sh` with 60+ tests
    covering all three tools individually and a full Nix installer simulation
    (create group → create 5 build users → add to group → verify → idempotent
    re-run → cleanup).
- **Phase 6.1 — NixOS VM test**: Created `tests/nix-in-darling.nix` — full
  end-to-end NixOS VM integration test that boots Darling, verifies the shell,
  sandbox-exec, Directory Services stubs, installs Nix, tests core commands
  (version, eval, store verify), confirms `builtins.currentSystem ==
  x86_64-darwin`, and builds trivial derivations.
- **Phase 6.6 — Darling smoke test**: Created `tests/darling-smoke.nix` —
  lightweight NixOS VM test (no network required) that verifies Darling boots,
  shell works, macOS identity is correct, filesystem operations work,
  sandbox-exec/diskutil/Directory Services stubs are functional, and no
  unimplemented syscall warnings appear during basic operations.
- **Phase 6.2 — Wired tests into `flake.nix`**: Added `checks` output with
  three entries: `darling-build` (package builds), `darling-smoke` (VM smoke
  test), `nix-in-darling` (full integration test), and `dirserv-stubs` (pure
  shell unit test for Directory Services stubs, runnable without Darling).
- **Test runner updated**: Added `dirserv` suite to `scripts/run-tests.sh`
  (now 6 suites total).
- **Test runner**: Created `scripts/run-tests.sh` — unified test runner that
  copies all regression test sources into a Darling prefix, compiles C suites
  with the macOS toolchain, executes them (and shell-based suites), and
  produces a colour-coded per-suite summary. Supports `--suite` filtering,
  `--verbose`, and `--keep` for post-mortem debugging.
- **Nix verification**: Created `scripts/verify-nix.sh` — standalone
  health-check for a Nix installation inside Darling. Checks infrastructure
  (prefix, binaries), core commands (`nix --version`, `nix-env`, `nix-store`),
  evaluator (`nix eval`, `builtins.currentSystem == x86_64-darwin`), store
  integrity (SQLite PRAGMA, path count), syscall health (no "Unimplemented
  syscall" or STUB warnings), optional network tests (`--online`), and
  environment (macOS version, nix.conf settings). Supports `--json` for CI.
- **Build test tooling**: Created `scripts/build-trivial.sh` — progressive
  derivation build script for Phase 4.1. Five levels: (1) echo to `$out`,
  (2) multi-line builder with mkdir/chmod/loops, (3) input transformation
  via `builtins.toFile`, (4) derivation dependency chain, (5) binary
  substitution from `cache.nixos.org`. Each level prints targeted debugging
  hints on failure.
- **Phase 1.8**: Verified emulated macOS version — `SystemVersion.plist`
  already reports 11.7.4 (Big Sur), `CMakeLists.txt` sets
  `CMAKE_OSX_DEPLOYMENT_TARGET 11.0`. No changes needed — task complete.
- **Bug fix**: Fixed `getattrlist` attribute buffer ordering — common
  attributes are now written in Apple-defined bit-position order
  (OBJTAG 0x10 → FNDRINFO 0x4000 → FLAGS 0x40000) instead of the
  previous incorrect order (FNDRINFO → FLAGS → OBJTAG). This prevents
  corrupted reads when callers request multiple common attributes.
- **Task 1.7**: Created `scripts/triage-syscalls.sh` — automated syscall
  discovery script that runs Nix operations inside Darling, captures
  "Unimplemented syscall" messages, categorizes them, and produces a
  Markdown report suitable for pasting into `plan/syscall-triage.md`.
- **Task 1.4**: Created `tests/syscall/test_utimensat.c` — comprehensive
  regression tests for utimensat/setattrlistat timestamp handling (16 tests
  covering MODTIME, ACCTIME, CRTIME, CHGTIME, combined attrs, FSOPT_NOFOLLOW
  on symlinks, utimes/lutimes libc functions, NULL pointers, kitchen-sink
  multi-attribute scenarios).
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
│   ├── build-trivial.sh                # NEW — Progressive derivation build tests (Phase 4)
│   ├── darling-nix                     # Host-side Nix command wrapper (Phase 3)
│   ├── install-nix-in-darling.sh       # Automated Nix installer (Phase 3)
│   ├── run-tests.sh                    # NEW — Unified regression test runner (6 suites)
│   ├── triage-syscalls.sh              # Automated syscall triage (Phase 1)
│   └── verify-nix.sh                   # NEW — Standalone Nix health-check (Phase 3)
├── src/
│   ├── dirserv/                        # NEW — Directory Services stubs (Phase 5)
│   │   ├── CMakeLists.txt
│   │   ├── dscl                        # dscl stub (read/list/create/delete/append/search)
│   │   ├── dseditgroup                 # dseditgroup stub (create/edit/delete/checkmember/read)
│   │   └── sysadminctl                 # sysadminctl stub (addUser/deleteUser)
│   ├── sandbox/sandbox.c               # Fixed sandbox API stubs (Phase 2)
│   ├── sandbox-exec/                   # NEW — sandbox-exec stub (Phase 2)
│   │   ├── CMakeLists.txt
│   │   └── sandbox-exec.c
│   └── diskutil/diskutil               # Extended with info/list verbs (Phase 3)
├── tests/
│   ├── darling-smoke.nix               # NEW — NixOS VM smoke test (Phase 6.6)
│   ├── nix-in-darling.nix              # NEW — NixOS VM integration test (Phase 6.1)
│   ├── dirserv/                        # NEW — Directory Services regression tests
│   │   └── test_dirserv.sh             # 60+ tests for dseditgroup/sysadminctl/dscl
│   ├── sandbox/                        # NEW — sandbox regression tests
│   │   ├── test_sandbox_api.c          # C-level sandbox API tests
│   │   └── test_sandbox_exec.sh        # Shell-level sandbox-exec tests
│   └── syscall/                        # NEW — syscall regression tests
│       ├── test_renameatx_np.c         # renameatx_np tests (Phase 1)
│       ├── test_setattrlist_flags.c    # setattrlist ATTR_CMN_FLAGS tests (Phase 1)
│       └── test_utimensat.c            # utimensat/timestamp tests (Phase 1)
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
    └── syscall-triage.md               # Syscall tracking table
```

## What's Next

The **critical path to MVP** (Nix running inside Darling) is:

1. **Build & test**: All core Phase 1 syscall work is complete. Build
   Darling with these changes and run the full regression test suite:

   ```bash
   # One command runs everything:
   ./scripts/run-tests.sh

   # Or target individual suites:
   ./scripts/run-tests.sh --suite renameatx_np --verbose
   ./scripts/run-tests.sh --suite sandbox_exec --keep
   ```

   Suites exercised:
   - `renameatx_np` — renameatx_np syscall 488 (5 tests)
   - `setattrlist_flags` — setattrlist/getattrlist ATTR_CMN_FLAGS (10 tests)
   - `utimensat` — utimensat/setattrlistat timestamps (16 tests)
   - `sandbox_api` — sandbox C API stubs
   - `sandbox_exec` — sandbox-exec integration (20 tests)
   - `dirserv` — Directory Services stubs (60+ tests)

2. **Phase 1.7 — Live triage**: Run `scripts/triage-syscalls.sh` inside a
   Darling prefix with Nix installed to discover any remaining unimplemented
   syscalls that weren't caught during code audit. This will populate the
   triage table with real-world findings.

   ```bash
   ./scripts/triage-syscalls.sh --output plan/syscall-triage-live.md
   ```

3. **Phase 3 — Nix installation**: With all known syscall blockers resolved
   (`lchflags`, `mv`/renameatx_np, `touch`/utimensat, `clonefile` stub,
   `getattrlist` buffer ordering fix), install Nix and verify:

   ```bash
   # Install Nix inside a Darling prefix
   ./scripts/install-nix-in-darling.sh

   # Verify the installation is healthy
   ./scripts/verify-nix.sh
   ./scripts/verify-nix.sh --online  # also test network/cache access

   # Quick ad-hoc commands via the wrapper
   ./scripts/darling-nix nix --version
   ./scripts/darling-nix nix eval --expr 'builtins.currentSystem'
   ```

4. **Phase 4 — Derivation building**: Once Nix installs successfully,
   exercise the full build pipeline with progressively harder derivations:

   ```bash
   # Run all five levels (stops early if a foundational level fails)
   ./scripts/build-trivial.sh

   # Target a specific level with debug output
   ./scripts/build-trivial.sh --level 1 --debug

   # Keep built derivations for inspection
   ./scripts/build-trivial.sh --keep --verbose
   ```

   Levels:
   1. Echo to `$out` — minimal: sandbox-exec → bash → file creation
   2. Multi-line builder — mkdir, chmod, loops, multiple output files
   3. Input transformation — `builtins.toFile`, sort, wc
   4. Derivation dependency — one derivation consumes another's output
   5. Binary substitution — fetch pre-built `hello` from cache.nixos.org

### Completed Task Summary

| Task | Status | Description |
|------|--------|-------------|
| 1.1 | ✅ | `setattrlist`/`fsetattrlist`/`getattrlist` — ATTR_CMN_FLAGS, CRTIME, CHGTIME |
| 1.2 | ✅ | `lchflags` return value — verified via 1.1 |
| 1.3 | ✅ | `renameatx_np` (syscall 488) — maps to Linux `renameat2` |
| 1.4 | ✅ | `utimensat` audit — setattrlistat handler fixed; test written |
| 1.5 | ✅ | `clonefile`/`fclonefileat` — ENOSYS→ENOTSUP stub |
| 1.6 | ✅ | `getentropy` — already works (maps to `getrandom`) |
| 1.7 | 🚧 | Triage — automation script created, needs live run |
| 1.8 | ✅ | macOS version — already 11.7.4 (Big Sur), no changes needed |
| 2.1 | ✅ | `sandbox-exec` stub |
| 2.2 | ✅ | `sandbox_init` API stubs fixed |
| 3.1 | ✅ | `install-nix-in-darling.sh` installer script |
| 3.3 | ✅ | `verify-nix.sh` standalone verification |
| 3.4 | ✅ | `darling-nix` host-side wrapper |
| 3.5 | ✅ | Channel/registry setup (integrated into installer step 6) |
| 4.1 | ✅ | `build-trivial.sh` progressive build tests (tooling ready) |
| 5.1 | ✅ | Directory Services stubs (`dseditgroup`, `sysadminctl`, `dscl`) |
| 6.1 | ✅ | NixOS VM test (`tests/nix-in-darling.nix`) |
| 6.2 | ✅ | Wired tests into `flake.nix` (checks output) |
| 6.3 | ✅ | `.github/workflows/nix.yml` CI workflow |
| 6.6 | ✅ | Darling smoke test (`tests/darling-smoke.nix`) |
| — | ✅ | `run-tests.sh` unified test runner (6 suites) |
| — | ✅ | `getattrlist` attribute buffer ordering bug fixed |
| — | ✅ | `diskutil info`/`list` stubs |
| — | ✅ | `dirserv-stubs` pure shell check (runnable without Darling) |

### Script & Test Quick Reference

| Script / Test | Purpose | When to Use |
|---------------|---------|-------------|
| `scripts/run-tests.sh` | Compile & run all regression tests inside Darling | After building Darling with changes |
| `scripts/triage-syscalls.sh` | Discover unimplemented syscalls during Nix operations | After installing Nix inside Darling |
| `scripts/install-nix-in-darling.sh` | Install Nix package manager inside a Darling prefix | One-time setup |
| `scripts/verify-nix.sh` | Health-check a Nix installation inside Darling | After install, or to diagnose regressions |
| `scripts/darling-nix` | Run Nix commands inside Darling from the host | Day-to-day Nix usage |
| `scripts/build-trivial.sh` | Test derivation building with 5 progressive levels | After Nix is installed and verified |
| `nix build .#checks.x86_64-linux.dirserv-stubs` | Run Directory Services stub tests (no Darling needed) | After editing `src/dirserv/` |
| `nix build .#checks.x86_64-linux.darling-smoke -L` | NixOS VM smoke test (no network) | After building Darling |
| `nix build .#checks.x86_64-linux.nix-in-darling -L` | Full Nix-in-Darling integration test | End-to-end validation |

See [plan/README.md](./plan/README.md) for the full priority table and effort
estimates.