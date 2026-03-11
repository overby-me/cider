# PLAN: Making Darling Fully Capable of Running Nix

> **Goal**: Enable Darling (macOS compatibility layer for Linux) to run the Nix
> package manager reliably, so that Linux machines can build, test, and
> cross-compile `x86_64-darwin` Nix derivations — analogous to how Wine enables
> building and testing Windows binaries on Linux.

The full plan has been split into focused documents to keep context manageable.
See the **[plan/](./plan/)** directory for all details.

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