/* Declarations for the macro-only duct-tape operations exported by src/dtape_rs_shims.c (#71).
 *
 * A HEADER rather than two extern declarations on the Rust side, so that bindgen generates the
 * signatures like everything else. The whole discipline of this port is that nothing crossing
 * the FFI is transcribed by hand; a shim I wrote myself is no exception, because the day one of
 * these grows an argument the generated side follows and a hand-written one does not.
 */

#ifndef _DARLINGSERVER_DUCT_TAPE_RS_SHIMS_H_
#define _DARLINGSERVER_DUCT_TAPE_RS_SHIMS_H_

#include <stddef.h>

#include <kern/simple_lock.h>

void* dtape_rs_kalloc(size_t size);
void dtape_rs_kfree(void* address, size_t size);

/* simple_lock_init is a macro too (it forwards to usimple_lock_init), and duct-tape calls it
 * with a tag of 0 everywhere, so the shim fixes the tag rather than exposing it. */
void dtape_rs_simple_lock_init(simple_lock_data_t* lock);

#endif
