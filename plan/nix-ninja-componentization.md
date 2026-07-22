# Full per-edge Darling build via nix-ninja (componentization / off-submodules)

Goal (task #39): make the **whole** Darling graph build per-edge via nix-ninja —
every compile a content-addressed nix derivation, so the ~40-min monolith becomes
seconds-incremental and fully cacheable, and the build is expressed entirely in
nix (the real path off git submodules). nix-ninja already builds the launcher and
the `libsystem_kernel` closure per-edge; the blocker to the rest was the mig scan.

## The blocker, diagnosed (was mislabelled "monorepo scan-toolchain")

Building `darlingserver-ninja` per-edge failed at the mig edges, e.g.:

```
mig: fatal: ".../osfmk/mach/memory_object.defs", line 205:
  fopen(.../osfmk/mach/memory_object.h): Permission denied
```

Root cause (concrete, not a toolchain gap):
- `cmake/mig.cmake` declares mig's `.h` as a **build-dir** output
  (`-header ${CMAKE_CURRENT_BINARY_DIR}/X.h`), separate from the source `.defs`.
- The XNU duct-tape source **also has a checked-in `X.h`** next to the `.defs`
  (a generated header that got committed).
- nix-ninja **merges the source tree and the configured build dir into one `$out`
  working tree**, so `<src>/…/mach/X.h` and `<build>/…/mach/X.h` map to the *same*
  `$out/…/mach/X.h`. The source copy is staged first as a **read-only symlink into
  the nix store** (`cp -rs`); mig then `fopen`s that path for write, follows the
  symlink into the store, and gets EACCES. In the real build source/build dirs are
  separate, so there is no collision.

## The fix (in the vendored lowering)

`nix/lib/nix-ninja/build/lower.nix`, `mkOutDirs` runs before each edge's command
and did `realize_writable "$(dirname output)"` — making the output *directory*
real but leaving the output *file* as a staged source symlink. Fix: also drop a
symlink sitting at a declared output path, so the command writes a fresh real file:

```nix
if [ -L <output> ]; then rm -f <output>; fi
```

This is general (any edge whose generated output shares a merged-$out path with a
checked-in source file), not mig-specific.

## Vendoring nix-ninja (also the off-submodules move)

The lowering lived in the `overby` flake input (read-only), so it couldn't be
fixed from here. Vendored `overby/nix/lib/ninja` → `nix/lib/nix-ninja/` (tracked
files) and pointed `nix/lib/darlingNinja.nix` at it. This lets the fix live here
and cuts the external dependency. (Stage 2, later: vendor `overby/rust/ninja` too
and drop the `overby` flake input entirely for a self-contained build.)

## Status / next

- [x] Diagnose the mig `.h` collision precisely.
- [x] Vendor the nix-ninja lib; apply the output-symlink fix.
- [x] **mig fix validated**: with it, the per-edge build goes from failing
      instantly to ~10 min deep, **past ALL mig edges** (0 Permission-denied). This
      was THE documented blocker for the whole componentization path.
- [ ] `darlingserver-ninja` green — blocked on the next issue (below), which is a
      deep XNU-header grind, not a drive-by.

### More per-edge fixes (each unblocks whole classes of edges)

2. **duct-tape mig user-stub `mach_msg` (RESOLVED).** A mig-generated `X_user.c`
   calls `mach_msg`, which XNU's `message.h` guards behind `#ifndef KERNEL` while
   the duct-tape defines `KERNEL`. The monolith tolerates the resulting implicit
   declaration; the per-edge builds bypass the cc-wrapper and don't inherit the
   monolith's `NIX_CFLAGS_COMPILE`, so they hit `-Werror=implicit-function-
   declaration`. Fix: bake `-Wno-error=implicit-function-declaration` into the
   nix-ninja configure's `CMAKE_C/CXX_FLAGS` (darlingNinja.nix). This cleared
   **all** compile edges (0 implicit errors) — the whole duct-tape compiles.

3. **archive/link toolchain (in progress).** The `.a`/link edges bake the darling
   stdenv cc-wrapper's absolute `ar`/`ranlib`/`ld` (a gcc-wrapper whose `ar`
   symlinks into binutils-wrapper); nix-ninja strips the baked path's context, so
   the wrapper + its bintools closure aren't mounted → `ar: No such file`. Fix:
   add `di.stdenv.cc` + `.bintools` to the edge toolchain. Rebuilding to confirm.

- [ ] Confirm `darlingserver-ninja` green per-edge (archive fix building).
- [ ] Scale to a full-darling-ninja target (`packages.darling-ninja`), kept OUT of
      `nix flake check` (thousands of derivations).
- [ ] Stage 2: vendor rust-ninja, drop the `overby` input (finish self-containing).

Landed durably: the mig-collision fix + nix-ninja vendoring. In flight: the
compile-tolerance + archive-toolchain fixes that take darlingserver green per-edge.
