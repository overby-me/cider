/* Declarations for the macro-only xnu-sys operations exported by src/xnu_sys_rs_shims.c (#71).
 *
 * A HEADER rather than two extern declarations on the Rust side, so that bindgen generates the
 * signatures like everything else. The whole discipline of this port is that nothing crossing
 * the FFI is transcribed by hand; a shim I wrote myself is no exception, because the day one of
 * these grows an argument the generated side follows and a hand-written one does not.
 */

#ifndef _CIDERD_XNU_SYS_RS_SHIMS_H_
#define _CIDERD_XNU_SYS_RS_SHIMS_H_

#include <stddef.h>
#include <stdint.h>

#include <kern/simple_lock.h>

void* xnu_sys_rs_kalloc(size_t size);
void xnu_sys_rs_kfree(void* address, size_t size);

/* simple_lock_init is a macro too (it forwards to usimple_lock_init), and xnu-sys calls it
 * with a tag of 0 everywhere, so the shim fixes the tag rather than exposing it. */
void xnu_sys_rs_simple_lock_init(simple_lock_data_t* lock);

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
struct xnu_sys_task;
void* xnu_sys_rs_task_ipc_space(struct xnu_sys_task* task);

/* locks.c reaches three fields through types the bindings keep opaque. Reopening struct thread
 * and struct waitq to get them was measured at +68 KB and +17 structs; these are three lines.
 * rwlock_count comes back as a POINTER because the C increments and decrements it in place. */
struct thread;
struct waitq;

/* psynch.c. current_task() forwards to current_task_fast(), which is not a symbol either, and
 * kheap_alloc is the same statement-expression shape as kalloc. Every psynch call site passes
 * KHEAP_DEFAULT, so the heap is fixed here rather than crossing as an argument nobody varies. */
struct task;

struct task* xnu_sys_rs_current_task(void);

/* kqchan.c. task_reference is a macro, os_ref_init and os_ref_release are inline, and
 * IPC_MQUEUE_RECEIVE is an event address rather than a small integer, so it comes back as a
 * value rather than through the enum. */
struct os_refcnt;

void xnu_sys_rs_task_reference(struct task* task);
void xnu_sys_rs_os_ref_init(struct os_refcnt* rc);
unsigned int xnu_sys_rs_os_ref_release(struct os_refcnt* rc);
unsigned long long xnu_sys_rs_ipc_mqueue_receive_event(void);

/* imq_is_set is a macro over waitqs_is_set, which is itself inline. */
struct ipc_mqueue;
int xnu_sys_rs_imq_is_set(struct ipc_mqueue* mq);
void* xnu_sys_rs_kheap_alloc(size_t size, int flags);
/* kheap_free is a statement expression that also NULLs the caller variable through a
 * __typeof__ cast, so it is a macro twice over. The Rust caller drops its own copy. */
void xnu_sys_rs_kheap_free(void* elem, size_t size);

void xnu_sys_rs_os_ref_retain(struct os_refcnt* rc);
void xnu_sys_rs_os_ref_release_live(struct os_refcnt* rc);

/* memory.c: the shared-entry red-black tree, which RB_PROTOTYPE_SC makes entirely
 * file-local. Five operations, which is all memory.c ever used; there is no lookup by key. */
struct xnu_sys_map_shared_entry;
struct xnu_sys_map_shared_entry_head;
void xnu_sys_rs_shared_entries_init(struct xnu_sys_map_shared_entry_head* head);
void xnu_sys_rs_shared_entries_insert(struct xnu_sys_map_shared_entry_head* head, struct xnu_sys_map_shared_entry* entry);
void xnu_sys_rs_shared_entries_remove(struct xnu_sys_map_shared_entry_head* head, struct xnu_sys_map_shared_entry* entry);
struct xnu_sys_map_shared_entry* xnu_sys_rs_shared_entries_first(struct xnu_sys_map_shared_entry_head* head);
struct xnu_sys_map_shared_entry* xnu_sys_rs_shared_entries_next(struct xnu_sys_map_shared_entry* entry);

/* thread.c: the four thread lock macros, each a simple_lock over a struct thread field. */
void xnu_sys_rs_thread_lock(struct thread* thread);
void xnu_sys_rs_thread_unlock(struct thread* thread);
void xnu_sys_rs_thread_lock_init(struct thread* thread);
void xnu_sys_rs_wake_lock_init(struct thread* thread);

/* thread.c: thread_reference and task_reference_internal are macros over os_ref. */
void xnu_sys_rs_thread_reference(struct thread* thread);
void xnu_sys_rs_task_reference_internal(struct task* task);

/* task.c: is_release is a macro over the ipc_space refcount. */
struct ipc_space;
void xnu_sys_rs_is_release(struct ipc_space* space);

/* task.c: task_set_64Bit_addr and _data are macros over t_flags. */
void xnu_sys_rs_task_set_64bit_addr(struct task* task);
void xnu_sys_rs_task_set_64bit_data(struct task* task);

/* misc.c: waitq_held reads four structs down through the opaque struct waitq. */
unsigned int xnu_sys_rs_waitq_held(struct waitq* wq);

/* psynch.c reaches thread->map, another field through the opaque struct thread. */
void* xnu_sys_rs_thread_map(struct thread* thread);

int* xnu_sys_rs_thread_rwlock_count(struct thread* thread);
uint32_t xnu_sys_rs_thread_sched_flags(struct thread* thread);
void* xnu_sys_rs_waitq_interlock(struct waitq* wq);

uint32_t xnu_sys_rs_mach_port_make(uint32_t index, uint32_t gen);
void xnu_sys_rs_io_release(struct ipc_object* object);
struct ipc_port* xnu_sys_rs_ip_object_to_port(struct ipc_object* object);

#endif
