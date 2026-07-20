# Blockers

Threads that are stuck pending a human decision, an upstream change, a
licensing question, or >1 day on a single signature. Pick up the next ranked
item and record the blocker here with reproduction steps. (Protocol: PLAN.md §10.)

## Open

- **Rootless fresh-prefix first-boot chowns fail (single-uid map).** Rootless
  works for an already-initialized prefix (see Resolved), but creating a *fresh*
  prefix rootlessly floods with `Cannot chown …` — Darling's first-boot setup
  chowns base-system files to several uids, and the single-id user-namespace map
  (`0 <ruid> 1`) can only own uid 0/self, so every other chown gets EPERM. The
  boot does not complete within the shellspawn window. Fix (planned): map a
  subordinate **range** via `newuidmap`/`newgidmap` + `/etc/subuid`+`/etc/subgid`
  (the launcher already notes this for `_nixbld`-style multi-user), or teach the
  setup to skip chowns it cannot satisfy under a single-id map. Until then,
  initialize the prefix once by another means (setuid trampoline, or a host with
  a subuid range) and then run rootless. Does not block the campaign (an
  initialized prefix is reusable), but wanted for a clean from-scratch rootless UX.

## Resolved

- **Host privilege for running Darling** → **rootless via unprivileged user
  namespaces**, no setuid, no sudo. `src/startup/darling.c` now enters a
  `CLONE_NEWUSER` namespace mapping the caller to root and re-execs into it
  (`enterUserNamespaceAndReexec`, guarded by `DARLING_USERNS_STAGE2`) when not
  already euid 0; the container's mount/PID unshares and overlayfs mount then
  run as namespaced root. Validated end-to-end on an initialized prefix: a
  mode-555 (non-setuid, root-owned) store `darling` run as uid 1000 boots and
  `darling shell echo ROOTLESS_OK` prints `ROOTLESS_OK` (rc 0); the rebuilt
  macOS-14 build likewise reports its identity via `sw_vers`/`sysctl` rootlessly.
  Requires `kernel.unprivileged_userns_clone=1` and kernel >= 5.11 for
  overlayfs-in-userns (host 7.1.2). `scripts/darling-trampoline.c` remains as a
  setuid fallback for hosts without unprivileged userns. The earlier
  `unshare --map-root-user` failure was the single-uid map; the in-launcher path
  writes uid_map/gid_map itself after denying setgroups, which works. Fresh-prefix
  creation is the one remaining gap (see Open).

- **Fork submodule URLs unhosted / xnu gitlink orphaned** → `scripts/init-submodules.sh`
  fetches from upstream darlinghq and overrides the xnu gitlink to the reachable
  base; Campaign-1 fixes carried as `patches/xnu/*`.
- **nixpkgs 26.05 pkg-config `Requires.private` gaps** (libsystemd, expat, xau,
  xdmcp) → added the providers to `nix/package.nix` buildInputs.
- **False 18-symbol libSystem gap** → `tbd-diff.py` now reads the exports trie
  (Darling re-exports str/mem funcs; `nm` missed them). Real gap ~0.
