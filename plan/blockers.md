# Blockers

Threads that are stuck pending a human decision, an upstream change, a
licensing question, or >1 day on a single signature. Pick up the next ranked
item and record the blocker here with reproduction steps. (Protocol: PLAN.md §10.)

## Open

- **Rootless runs one command per fresh container (no re-join).** A running
  container's init (darlingserver) lives in the user namespace the *first*
  `darling shell` created. A subsequent `darling shell` creates its own
  (sibling) user namespace and then tries `joinNamespace(pidInit, mnt)` =
  `open(/proc/<pidInit>/ns/mnt)`, which fails **EPERM** (no privilege over a
  sibling userns). So each invocation must start a *fresh* container (kill the
  stale darlingserver first). Fine for one-shot runs
  (`scripts/run-darwin-under-darling.sh`, M0), but it breaks the guest-Nix
  installer, which issues many sequential `darling shell` calls expecting a
  persistent container (Phase 0.5 full / Phase C). Fixes to evaluate: (a) run
  the whole install inside one `darling shell` session; (b) teach the launcher
  to *enter* an existing container's userns+mnt+pid via the persistent
  darlingserver instead of creating a new userns when a container is already
  running. Prefer (a) first (simpler, no launcher change).

- **First-boot shellspawn race + un-cleanable rootless prefixes.** A fresh
  prefix's first `darling shell` sometimes returns before `shellspawn.sock`
  appears (`Error connecting to shellspawn … No such file`). The launcher waits
  only `15 * 1s` for the socket (`src/startup/darling.c`), which a slow rootless
  first boot (chown-heavy setup) can exceed, so callers must retry. Separately,
  files the container creates in the prefix are owned by mapped container uids
  the host user cannot `rm` (EPERM), so a stale prefix cannot be cleaned from
  the host and reusing one can wedge later boots. Consequences: the one-shot
  runner/compile scripts (`run-darwin-under-darling.sh`, `cc-under-darling.sh`)
  are timing-sensitive. Fixes to evaluate: widen the shellspawn wait window
  (and/or poll faster); a `darling` subcommand that tears down + removes a
  prefix from inside the container (as container root). The underlying
  compile/run results are solid; only the harness around them is flaky.

- **Rootless prefix path must be short (Unix-socket `sun_path` limit).** The
  shellspawn/darlingserver socket lives at `<prefix>/var/run/…sock`; if the
  prefix path is long the socket path overflows `sockaddr_un.sun_path` (~108
  chars) and boot fails with "darlingserver socket path is too long" (the
  launcher's own 255-char `DPREFIX` check is looser and misses this). Keep
  prefixes short, e.g. the default `~/.darling`. Minor: tighten the launcher's
  check to the socket-path budget, or shorten the socket path. Not a rootless
  issue (affects the setuid path equally).

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
  writes uid_map/gid_map itself after denying setgroups, which works. A *fresh*
  prefix also creates and boots rootlessly (validated: `SINGLEID_BOOT_OK` +
  `sw_vers` 14.4.1 on a new short-path prefix). Its `Cannot chown …` messages
  (~4.5k) are for overlayfs lowerdir base files owned by host root (uid 0), which
  is unmapped in the namespace and cannot be chown'd; they are non-fatal (boot
  completes) and identical under a single-id or a subordinate-range map, so no
  range map is needed (a `newuidmap`/`newgidmap` range version was tried and
  reverted: darlingserver chowns to uid 0, which the single-id map already
  covers, and the residual host-0 files no range can touch).

- **Fork submodule URLs unhosted / xnu gitlink orphaned** → `scripts/init-submodules.sh`
  fetches from upstream darlinghq and overrides the xnu gitlink to the reachable
  base; Campaign-1 fixes carried as `patches/xnu/*`.
- **nixpkgs 26.05 pkg-config `Requires.private` gaps** (libsystemd, expat, xau,
  xdmcp) → added the providers to `nix/package.nix` buildInputs.
- **False 18-symbol libSystem gap** → `tbd-diff.py` now reads the exports trie
  (Darling re-exports str/mem funcs; `nm` missed them). Real gap ~0.
