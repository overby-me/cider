# PLAN: Making Darling Fully Capable of Running Nix

> **Goal**: Enable Darling (macOS compatibility layer for Linux) to run the Nix
> package manager reliably, so that Linux machines can build, test, and
> cross-compile `x86_64-darwin` Nix derivations — analogous to how Wine enables
> building and testing Windows binaries on Linux.

## Plan Documents

| Document | Description |
|---|---|
| [Background & Current State](./00-background.md) | Motivation, what works today, what doesn't |
| [Known Blockers](./01-blockers.md) | Detailed analysis of each blocking issue with fix strategies |
| [Phase 0 — Nix Packaging + DevShell](./02-phase0-packaging.md) | `flake.nix`, devShell, `.envrc`, NixOS module |
| [Phase 1 — Core Syscall Fixes](./03-phase1-syscalls.md) | `setattrlist`, `renameatx_np`, `utimensat`, etc. |
| [Phase 2 — Sandbox Stub](./04-phase2-sandbox.md) | `sandbox-exec` passthrough, sandbox API stubs |
| [Phase 3 — Nix Installation](./05-phase3-nix-install.md) | Automated installer, verification, wrappers |
| [Phase 4 — Derivation Building](./06-phase4-building.md) | Trivial derivations → stdenv → binary substitution |
| [Phase 5 — Nix Daemon](./07-phase5-daemon.md) | Multi-user mode, Directory Services stubs, launchd |
| [Phase 6 — CI & Testing](./08-phase6-ci.md) | NixOS VM tests, regression suite, GitHub Actions |
| [Phase 7 — Remote Builder](./09-phase7-remote-builder.md) | Darling as a `nix.buildMachines` target |
| [Phase 8 — Stretch Goals](./10-phase8-stretch.md) | `aarch64-darwin`, GUI testing, Hydra builder |
| [Architecture](./11-architecture.md) | System diagram, key technical decisions |
| [Syscall Triage](./syscall-triage.md) | Tracking table for unimplemented/buggy syscalls |

## Priority & Effort Estimates

| Phase | Priority | Effort | Depends On |
|-------|----------|--------|------------|
| Phase 0 — Nix packaging + devShell | P0 | S (1–2 weeks) | — |
| Phase 1 — Syscall fixes | P0 | L (4–8 weeks) | Phase 0 |
| Phase 2 — Sandbox stub | P0 | S (1 week) | — |
| Phase 3 — Nix installation | P0 | M (2–3 weeks) | Phases 1, 2 |
| Phase 4 — Derivation building | P1 | L (4–8 weeks) | Phase 3 |
| Phase 5 — Nix daemon | P2 | M (2–4 weeks) | Phase 4 |
| Phase 6 — CI/testing | P1 | M (2–3 weeks) | Phase 3 |
| Phase 7 — Remote builder | P2 | L (4–8 weeks) | Phases 4, 5 |
| Phase 8 — Stretch goals | P3 | XL (months) | Phase 7 |

**Estimated time to MVP** (Phases 0–3): ~8–14 weeks of focused effort.

**Estimated time to usable Darwin builder** (through Phase 7): ~6–12 months.

## How to Contribute

1. **Pick a task** from any phase document (earlier phases first).
2. **Check upstream** [Darling issues](https://github.com/darlinghq/darling/issues) for existing work.
3. **Write a minimal reproducer** — a small C program or shell command that demonstrates the bug inside `darling shell`.
4. **Fix it** in the appropriate subsystem (`darlingserver` for syscalls, `src/external/libc` for wrappers, `src/sandbox` for sandbox, etc.).
5. **Add a test** to the regression suite (see [Phase 6](./08-phase6-ci.md) and `tests/`).
6. **Submit a PR** to this repo, and consider upstreaming to `darlinghq/darling`.

### Key Scripts & Tools

| File | Description |
|---|---|
| `scripts/run-tests.sh` | Unified test runner — compiles and runs all regression tests inside Darling (6 suites) |
| `scripts/install-nix-in-darling.sh` | Automated Nix installer for Darling prefixes |
| `scripts/verify-nix.sh` | Standalone health-check for a Nix installation inside Darling |
| `scripts/build-trivial.sh` | Progressive derivation build tests (5 levels) for Phase 4 |
| `scripts/darling-nix` | Host-side wrapper to run Nix commands inside Darling |
| `scripts/triage-syscalls.sh` | Automated syscall triage — discovers unimplemented syscalls during Nix ops |
| `src/dirserv/dseditgroup` | Directory Services stub — group create/edit/delete/checkmember/read (Phase 5.1) |
| `src/dirserv/sysadminctl` | Directory Services stub — addUser/deleteUser with UID/GID/home/shell (Phase 5.1) |
| `src/dirserv/dscl` | Directory Services stub — read/list/create/delete/append/search (Phase 5.1) |
| `tests/darling-smoke.nix` | NixOS VM smoke test — Darling boot, stubs, filesystem, no network (Phase 6.6) |
| `tests/nix-in-darling.nix` | NixOS VM integration test — full Nix install + eval + build (Phase 6.1) |
| `tests/dirserv/test_dirserv.sh` | Shell-level tests for Directory Services stubs (60+ tests) |
| `tests/sandbox/test_sandbox_api.c` | C-level regression tests for sandbox API stubs |
| `tests/sandbox/test_sandbox_exec.sh` | Shell-level tests for the `sandbox-exec` stub binary |
| `tests/syscall/test_renameatx_np.c` | renameatx_np regression tests (plain rename, SWAP, EXCL, invalid flags) |
| `tests/syscall/test_setattrlist_flags.c` | setattrlist/getattrlist ATTR_CMN_FLAGS tests |
| `tests/syscall/test_utimensat.c` | utimensat/setattrlistat timestamp handling tests |

## References

- [Darling Project](https://www.darlinghq.org/) — upstream macOS compatibility layer
- [Darling GitHub](https://github.com/darlinghq/darling) — upstream source
- [nixie-dev/darling-nix](https://github.com/nixie-dev/darling-nix) — Nix overlay for Darling
- [Nix All The Way Down](https://ersei.net/en/blog/nix-all-the-way-down) — blog post documenting Nix-in-Darling attempt
- [Nix Darwin sandbox source](https://github.com/NixOS/nix/blob/master/src/libstore/platform/darwin.cc) — Nix's `sandbox-exec` invocation
- [Apple `setattrlist` docs](https://developer.apple.com/documentation/kernel/1387673-setattrlist)
- [Apple `renameatx_np` docs](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/renameatx_np.2.html)
- [Darling Docs — Build Instructions](https://docs.darlinghq.org/build-instructions.html)