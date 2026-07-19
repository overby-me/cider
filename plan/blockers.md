# Blockers

Threads that are stuck pending a human decision, an upstream change, a
licensing question, or >1 day on a single signature. Pick up the next ranked
item and record the blocker here with reproduction steps. (Protocol: PLAN.md §10.)

## Open

- **Host privilege for running Darling** (resolved: setuid wrapper). This build
  requires euid 0 (`src/startup/darling.c` fails on non-root; rootless userns is
  disabled). Rootless via `unshare --map-root-user` fails (single-uid mapping
  breaks the prefix chowns and mount-namespace setup). Decision: a setuid-root
  copy of `darling` via `scripts/darling-host.sh` + a one-time
  `sudo install -m4755` (re-run after each Darling rebuild). Not a blocker while
  the setup command is available; noted so a fresh environment knows why.

## Resolved

- **Fork submodule URLs unhosted / xnu gitlink orphaned** → `scripts/init-submodules.sh`
  fetches from upstream darlinghq and overrides the xnu gitlink to the reachable
  base; Campaign-1 fixes carried as `patches/xnu/*`.
- **nixpkgs 26.05 pkg-config `Requires.private` gaps** (libsystemd, expat, xau,
  xdmcp) → added the providers to `nix/package.nix` buildInputs.
- **False 18-symbol libSystem gap** → `tbd-diff.py` now reads the exports trie
  (Darling re-exports str/mem funcs; `nm` missed them). Real gap ~0.
