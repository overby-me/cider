/* Macro-only duct-tape operations, exported as REAL SYMBOLS for the Rust port (#71).
 *
 * FIRST-PARTY, despite sitting in the vendored duct-tape tree. It lives here because it has to
 * compile with duct-tape's exact defines, warning flags and eleven include roots, which is
 * precisely what the generated dt_objects target already provides; reproducing that set in
 * linux/server just to hold one file would be a second copy of the thing most likely to drift.
 * scripts/gen-duct-tape-buck.py adds it to dt_objects by name (RUST_SHIM_SOURCES).
 *
 * WHY THIS EXISTS. bindgen binds no macros at all, so every macro a glue file calls is a hard
 * blocker for porting that file: it needs either a reimplementation in Rust or a C shim that
 * turns it into a linkable symbol. Most of the macros met so far were cheap to rewrite in Rust
 * (the TAILQ helpers, the dtape_stub family). `kalloc` is not, and it is worth spelling out
 * why, because the reason is invisible in the source:
 *
 *   kalloc(size)
 *     -> ({ static vm_allocation_site_t site __attribute__((section("__DATA, __data")))
 *             = { .refcount = 2, .tag = 0, .flags = 0 };
 *           kalloc_ext(KHEAP_DEFAULT, size, Z_WAITOK, &site).addr; })
 *
 * A statement expression holding a function-static `vm_allocation_site_t`, XNU's per-call-site
 * allocation accounting. Writing that in Rust means INITIALISING a vm_allocation_site_t by
 * field, which means un-opaquing part of `vm_.*` -- the family deliberately kept opaque so that
 * struct task does not drag most of osfmk into bindings the whole daemon reads. The cost of
 * that relaxation is unmeasured, and it would be paid by every compile of the crate.
 *
 * A shim costs one object file and nothing else, and it keeps the accounting HONEST rather than
 * approximating it: the static site below is this file's own call site, exactly as it would be
 * for any C caller.
 *
 * THIS IS SHARED WORK, not scaffolding for one port. `kalloc` blocks at least processor.c and
 * debug.c, and `kfree` blocks debug.c, so the two functions here are the difference between
 * those files being portable and not.
 */

#include <kern/kalloc.h>

#include <stddef.h>

/* kalloc, as a symbol. Returns NULL on failure, exactly as the macro does. */
void* dtape_rs_kalloc(size_t size) {
	return kalloc(size);
};

/* kfree, as a symbol. XNU's kfree takes the SIZE as well as the pointer, because its zone
 * allocator has no per-allocation header to read it back from; passing the wrong size is a
 * silent heap error rather than a crash, so the Rust side must keep the size it allocated. */
void dtape_rs_kfree(void* address, size_t size) {
	kfree(address, size);
};
