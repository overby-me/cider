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
- [ ] `darlingserver-ninja` builds green per-edge (validating now).
- [ ] Iterate remaining per-edge failures (expect a few more, as launcher/kernel
      each did).
- [ ] Scale to a full-darling-ninja target (`packages.darling-ninja`), kept OUT of
      `nix flake check` (thousands of derivations).
- [ ] Stage 2: vendor rust-ninja, drop the `overby` input.
