# Vendored libtrace

This directory is **vendored source**, not a git submodule. It was previously the
submodule `src/external/libtrace`; it is now checked in directly so its sources
can be edited in-tree without the patch-file indirection.

- Upstream: https://github.com/ciderhq/cider-libtrace.git
- Base commit: `8cf07f02b15f7dca6436882a03678fff0392eaf6`

## Local changes on top of the base commit

- `include/os/log.h`, `libsystem_trace/os_log.c` — add `os_log` error/debug
  implementations needed by the 26.05 libSystem symbol surface (Phase B). Was
  `patches/libtrace/*.patch`.

## Re-syncing with upstream

Diff this tree against upstream `8cf07f02` (or a newer rev) to carry these changes
forward; there is no submodule gitlink to bump anymore.
