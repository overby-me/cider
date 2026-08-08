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
#include <stdint.h>

#include <kern/simple_lock.h>

void* dtape_rs_kalloc(size_t size);
void dtape_rs_kfree(void* address, size_t size);

/* simple_lock_init is a macro too (it forwards to usimple_lock_init), and duct-tape calls it
 * with a tag of 0 everywhere, so the shim fixes the tag rather than exposing it. */
void dtape_rs_simple_lock_init(simple_lock_data_t* lock);

/* debug.c needs three more XNU accessors that Rust cannot reach:
 *
 *   MACH_PORT_MAKE   a macro, and worse, one whose definition depends on NO_PORT_GEN, so
 *                    reimplementing it in Rust would silently pick a branch.
 *   io_release       declared STATIC INLINE in ipc_object.h, so it is not a linkable symbol at
 *                    all: nm finds only local per-translation-unit copies.
 *   ip_object_to_port  a __container_of, which is an offset the compiler knows and a hand
 *                    written Rust version would have to rederive.
 */
struct ipc_port;
struct ipc_object;

/* The ONE field debug.c reaches through struct task, which is deliberately opaque in the
 * bindings. Reopening task to get it was measured at +94 KB and +22 structs, nearly doubling
 * the bindings that every compile of the crate pays for; this accessor is one line. */
struct dtape_task;
void* dtape_rs_task_ipc_space(struct dtape_task* task);

uint32_t dtape_rs_mach_port_make(uint32_t index, uint32_t gen);
void dtape_rs_io_release(struct ipc_object* object);
struct ipc_port* dtape_rs_ip_object_to_port(struct ipc_object* object);

#endif
