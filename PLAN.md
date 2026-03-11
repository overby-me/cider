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
| Phase 1 — Syscalls | 📋 Planned | [Triage table](./plan/syscall-triage.md) |
| Phase 2 — Sandbox | 🚧 In progress | `src/sandbox/sandbox.c` (fixed), `src/sandbox-exec/` (new), `tests/sandbox/` (new) |
| Phase 3 — Nix Install | 🚧 In progress | `scripts/install-nix-in-darling.sh` (new), `scripts/darling-nix` (new) |
| Phase 4 — Building | 📋 Planned | — |
| Phase 5 — Daemon | 📋 Planned | — |
| Phase 6 — CI | 🚧 In progress | `.github/workflows/nix.yml` (new) |
| Phase 7 — Remote Builder | 📋 Planned | — |
| Phase 8 — Stretch | 📋 Planned | — |

### Recently Completed

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
│   └── sandbox/                        # NEW — sandbox regression tests
│       ├── test_sandbox_api.c          # C-level sandbox API tests
│       └── test_sandbox_exec.sh        # Shell-level sandbox-exec tests
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

1. **Phase 1 — Syscall fixes** (P0, not started): This is the biggest remaining
   blocker. The `setattrlist`/`renameatx_np`/`utimensat` implementations in
   darlingserver are required before Nix binaries can run without crashing.
   Start with task 1.3 (`renameatx_np` → `renameat2` mapping) as it's the
   quickest win, then 1.1 (`setattrlist`) for the biggest impact.

2. **Phase 2 — Verification**: The sandbox-exec stub and API fixes are
   implemented but need testing inside a real Darling build. Run the tests in
   `tests/sandbox/` to verify.

3. **Phase 3 — Nix installation**: Once Phase 1 syscalls are in place, run
   `scripts/install-nix-in-darling.sh` and iterate on any remaining issues.

See [plan/README.md](./plan/README.md) for the full priority table and effort
estimates.