# Vendored darlingserver

This directory is **vendored source**, not a git submodule. It was previously the
submodule `src/external/darlingserver`; it is now checked in directly so its
sources can be edited in-tree without the patch-file indirection.

- Upstream: https://github.com/darlinghq/darlingserver.git
- Base commit: `89751e64bc6c2082f7725061824ee0e33395b0de`

## Local changes on top of the base commit

- `src/darlingserver.cpp` — optional writable-native-`/nix` overlay for guest Nix
  (opt-in via a `.enable-writable-nix` marker in the prefix). Was
  `patches/darlingserver/0001-optional-writable-nix-overlay.patch`.
- `src/message.cpp` — cache the daemon's own `ucred` (pid/uid/gid) instead of
  calling getpid/getuid/getgid per message; see `plan/perf-overhead.md`. Was
  `patches/darlingserver/0002-cache-darlingserver-own-credentials.patch`.

## Re-syncing with upstream

Diff this tree against upstream `89751e64` (or a newer rev) to carry these
changes forward; there is no submodule gitlink to bump anymore.
