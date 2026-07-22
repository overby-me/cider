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

2. **duct-tape mig user-stub `mach_msg` (DIAGNOSED — deeper than first thought).**
   The mig-generated `notify_user.c` link-fails with `undefined reference to
   mach_msg` (functions `mach_notify_dead_name`, `mach_notify_no_senders`, …).
   Investigation (all confirmed):
   - The **monolith** `result/bin/darlingserver` has `mach_notify_dead_name` (T,
     defined) and it calls **`mach_msg_send_from_kernel_proper`**, not `mach_msg`
     (verified by `objdump -d`). There is **no** `mach_msg` symbol in the monolith
     binary at all. So the correct kernel codegen calls the kernel send, and plain
     `mach_msg` never appears.
   - mig chooses between them by `IsKernelUser` (bootstrap_cmds `user.c:585` emits
     `mach_msg_send_from_kernel` when kernel-user, else `mach_msg` at `:591`).
     `IsKernelUser` is set by the `KernelUser` subsystem keyword, which `notify.defs`
     guards behind `#if KERNEL_USER` (`notify.defs:60`). `KERNEL_USER=1` is a
     duct-tape `add_compile_definitions` (CMakeLists `:118`), surfaced to mig by
     `cmake/mig.cmake`'s `get_directory_property(... COMPILE_DEFINITIONS)`.
   - **The nix-ninja mig command is correct**: graph-json inspection shows every
     `*_user.c` edge — including `notify_user.c` (from `notify.defs`) — carries
     `-DKERNEL_USER` (and `-DKERNEL …`), before the `.defs` arg, exactly as the
     monolith. mig preprocesses via `$C -E … "${cppflags[@]}"` (mig.sh:72) where
     cppflags includes `-DKERNEL_USER=1` and `$C` = `configured/cc`.
   - So the command is byte-identical to the monolith's, yet the per-edge object
     referenced plain `mach_msg`. Either the link error was **stale** (pre the
     mig-collision fix / pre-rebuild) or mig's cpp diverges in the **isolated edge
     sandbox** (e.g. `configured/cc` resolving differently, so `#if KERNEL_USER`
     evaluates false). Ground-truth build of just the `notify_user.c` edge was
     pending (blocked on a store auto-GC) — that file's `mach_msg` vs
     `mach_msg_send_from_kernel` form decides it.

   NOTE: the earlier `-Wno-error=implicit-function-declaration` in
   `CMAKE_C/CXX_FLAGS` only **masks** this (turns the implicit-decl into a silent
   undefined symbol at link). If the codegen is correct there is no implicit decl
   and the `-Wno` is unnecessary; it should be removed once the edge is confirmed.

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
