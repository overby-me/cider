/* Macro-only xnu-sys operations, exported as REAL SYMBOLS for the Rust port (#71).
 *
 * FIRST-PARTY, despite sitting in the vendored xnu-sys tree. It lives here because it has to
 * compile with xnu-sys's exact defines, warning flags and eleven include roots, which is
 * precisely what the generated dt_objects target already provides; reproducing that set in
 * linux/server just to hold one file would be a second copy of the thing most likely to drift.
 * scripts/gen-xnu-sys-buck.py adds it to dt_objects by name (RUST_SHIM_SOURCES).
 *
 * WHY THIS EXISTS. bindgen binds no macros at all, so every macro a glue file calls is a hard
 * blocker for porting that file: it needs either a reimplementation in Rust or a C shim that
 * turns it into a linkable symbol. Most of the macros met so far were cheap to rewrite in Rust
 * (the TAILQ helpers, the xnu_sys_stub family). `kalloc` is not, and it is worth spelling out
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

#include <ciderd/xnu-sys/rs_shims.h>

#include <kern/kalloc.h>

#include <ciderd/xnu-sys/task.h>

#include <kern/thread.h>
#include <kern/waitq.h>

#include <ipc/ipc_mqueue.h>
#include <ipc/ipc_object.h>
#include <ipc/ipc_port.h>
#include <mach/port.h>
#include <ciderd/xnu-sys/log.h>
#include <ciderd/xnu-sys/hooks.internal.h>
#include <stdarg.h>
#include <ciderd/xnu-sys/memory.h>

/* kalloc, as a symbol. Returns NULL on failure, exactly as the macro does. */
void* xnu_sys_rs_kalloc(size_t size) {
	return kalloc(size);
};

/* kfree, as a symbol. XNU's kfree takes the SIZE as well as the pointer, because its zone
 * allocator has no per-allocation header to read it back from; passing the wrong size is a
 * silent heap error rather than a crash, so the Rust side must keep the size it allocated. */
void xnu_sys_rs_kfree(void* address, size_t size) {
	kfree(address, size);
};

/* simple_lock_init, as a symbol. xnu-sys passes a tag of 0 at every call site, so the tag is
 * fixed here rather than crossing the FFI as an argument nobody varies. */
void xnu_sys_rs_simple_lock_init(simple_lock_data_t* lock) {
	simple_lock_init(lock, 0);
};

/* MACH_PORT_MAKE, as a symbol. The macro has two definitions selected by NO_PORT_GEN, so the
 * shim keeps whichever this build actually compiles rather than picking one in Rust. */
uint32_t xnu_sys_rs_mach_port_make(uint32_t index, uint32_t gen) {
	return MACH_PORT_MAKE(index, gen);
};

/* io_release, as a symbol. It is static inline in ipc_object.h, so there is nothing to link
 * against without this. */
void xnu_sys_rs_io_release(struct ipc_object* object) {
	io_release((ipc_object_t)object);
};

/* ip_object_to_port, as a symbol: a __container_of, so the offset comes from the compiler. */
struct ipc_port* xnu_sys_rs_ip_object_to_port(struct ipc_object* object) {
	return ip_object_to_port((ipc_object_t)object);
};

/* task->xnu_task.itk_space, as a symbol. struct task stays opaque in the bindings because
 * reopening it costs about 94 KB of generated Rust, and this is the only field of it that any
 * ported glue file needs. */
void* xnu_sys_rs_task_ipc_space(struct xnu_sys_task* task) {
	return task->xnu_task.itk_space;
};

/* The three fields locks.c needs through opaque types. See the header for why these are shims
 * rather than a reopening. */
int* xnu_sys_rs_thread_rwlock_count(struct thread* thread) {
	return &thread->rwlock_count;
};

uint32_t xnu_sys_rs_thread_sched_flags(struct thread* thread) {
	return thread->sched_flags;
};

void* xnu_sys_rs_waitq_interlock(struct waitq* wq) {
	return &wq->xnu_sys_waitq_interlock;
};

/* current_task(), as a symbol. The macro forwards to current_task_fast(), which is inline. */
struct task* xnu_sys_rs_current_task(void) {
	return current_task();
};

/* kheap_alloc, as a symbol, on the default heap. Same statement-expression shape as kalloc. */
void* xnu_sys_rs_kheap_alloc(size_t size, int flags) {
	return kheap_alloc(KHEAP_DEFAULT, size, flags);
};

/* kheap_free, as a symbol: it is a statement expression that NULLs the caller variable. */
void xnu_sys_rs_kheap_free(void* elem, size_t size) {
	kheap_free(KHEAP_DEFAULT, elem, size);
};

/* task_reference, as a symbol: it is a macro. */
void xnu_sys_rs_task_reference(struct task* task) {
	task_reference(task);
};

/* The os_refcnt pair, which are inline. */
void xnu_sys_rs_os_ref_init(struct os_refcnt* rc) {
	os_ref_init(rc, NULL);
};

unsigned int xnu_sys_rs_os_ref_release(struct os_refcnt* rc) {
	return os_ref_release(rc);
};

/* IPC_MQUEUE_RECEIVE is an event ADDRESS, so it cannot be an enumerator. */
unsigned long long xnu_sys_rs_ipc_mqueue_receive_event(void) {
	return (unsigned long long)IPC_MQUEUE_RECEIVE;
};

/* imq_is_set, as a symbol: a macro over an inline. */
int xnu_sys_rs_imq_is_set(struct ipc_mqueue* mq) {
	return imq_is_set(mq) ? 1 : 0;
};

/* thread->map, the one field psynch.c needs through the opaque struct thread. */
void* xnu_sys_rs_thread_map(struct thread* thread) {
	return thread->map;
};

/* waitq_held reaches four structs down through the opaque struct waitq. Returning the owner
 * rather than a pointer keeps the comparison, and the type of the thing compared, on this side. */
unsigned int xnu_sys_rs_waitq_held(struct waitq* wq) {
	return wq->xnu_sys_waitq_interlock.xnu_sys_interlock.xnu_sys_interlock.xnu_sys_mutex.xnu_sys_owner == (uintptr_t)current_thread();
};

/* memory.c: the remaining os_ref operations, inline like the two already here. */
void xnu_sys_rs_os_ref_retain(struct os_refcnt* rc) {
	os_ref_retain(rc);
};

void xnu_sys_rs_os_ref_release_live(struct os_refcnt* rc) {
	os_ref_release_live(rc);
};

/* memory.c: the shared-entry tree.
 *
 * RB_GENERATE expands to an entire red-black tree implementation, and RB_PROTOTYPE_SC makes
 * every one of its functions file-local, so there is no symbol for Rust to call. The tree is
 * also completely private to memory.c: no other translation unit, not even memory_xnu.c, so
 * much as names xnu_sys_map_shared_entry.
 *
 * So it stays in C. Hand-writing a red-black tree in Rust to replace it would be a few hundred
 * lines whose rebalancing has to be exactly right, to gain nothing observable. Rust drives it
 * through the five operations memory.c actually used, and it never looked anything up by key:
 * the only reads are an in-order walk and a drain.
 */
static int xnu_sys_map_shared_entry_compare(xnu_sys_map_shared_entry_t* first, xnu_sys_map_shared_entry_t* second) {
	if (first->address < second->address) {
		return -1;
	} else if (first->address > second->address) {
		return 1;
	} else {
		return 0;
	}
};

RB_PROTOTYPE_SC(static, xnu_sys_map_shared_entry_head, xnu_sys_map_shared_entry, link, xnu_sys_map_shared_entry_compare);
RB_GENERATE(xnu_sys_map_shared_entry_head, xnu_sys_map_shared_entry, link, xnu_sys_map_shared_entry_compare);

void xnu_sys_rs_shared_entries_init(xnu_sys_map_shared_entry_head_t* head) {
	RB_INIT(head);
};

void xnu_sys_rs_shared_entries_insert(xnu_sys_map_shared_entry_head_t* head, xnu_sys_map_shared_entry_t* entry) {
	RB_INSERT(xnu_sys_map_shared_entry_head, head, entry);
};

void xnu_sys_rs_shared_entries_remove(xnu_sys_map_shared_entry_head_t* head, xnu_sys_map_shared_entry_t* entry) {
	RB_REMOVE(xnu_sys_map_shared_entry_head, head, entry);
};

/* The in-order walk, as a first/next pair, which is what RB_FOREACH is underneath. */
xnu_sys_map_shared_entry_t* xnu_sys_rs_shared_entries_first(xnu_sys_map_shared_entry_head_t* head) {
	return RB_MIN(xnu_sys_map_shared_entry_head, head);
};

xnu_sys_map_shared_entry_t* xnu_sys_rs_shared_entries_next(xnu_sys_map_shared_entry_t* entry) {
	return RB_NEXT(xnu_sys_map_shared_entry_head, NULL, entry);
};

/* thread.c: the four thread lock macros, each a simple_lock over a field of struct thread.
 * The lock group they name is file-static to XNU, so these cannot be written in Rust even
 * with the struct reopened. */
void xnu_sys_rs_thread_lock(struct thread* thread) {
	thread_lock(thread);
};

void xnu_sys_rs_thread_unlock(struct thread* thread) {
	thread_unlock(thread);
};

void xnu_sys_rs_thread_lock_init(struct thread* thread) {
	thread_lock_init(thread);
};

void xnu_sys_rs_wake_lock_init(struct thread* thread) {
	wake_lock_init(thread);
};

/* thread.c: thread_reference and task_reference_internal are macros over os_ref, the same
 * shape as the task_reference shim above. */
void xnu_sys_rs_thread_reference(struct thread* thread) {
	thread_reference(thread);
};

void xnu_sys_rs_task_reference_internal(struct task* task) {
	task_reference_internal(task);
};

/* task.c: is_release is a macro over the ipc_space refcount. */
void xnu_sys_rs_is_release(ipc_space_t space) {
	is_release(space);
};

/* task.c: the two 64-bit flag setters are macros over t_flags. */
void xnu_sys_rs_task_set_64bit_addr(struct task* task) {
	task_set_64Bit_addr(task);
};

void xnu_sys_rs_task_set_64bit_data(struct task* task) {
	task_set_64Bit_data(task);
};

/* THE VARIADIC FRONT ENDS, from misc.c (#71).
 *
 * Stable Rust can CALL a C variadic function but cannot DEFINE one, and xnu-sys exports four
 * variadic definitions. These three are misc.c's; the fourth, panic, stays in stubs.c until that
 * file is ported. Each does the one thing Rust cannot, which is start a va_list; everything
 * else about misc.c is Rust now. xnu_sys_logv is here for the same reason at one remove, since
 * its parameter IS a va_list.
 *
 * Rust does not need any of them to log: it formats with format! and calls xnu_sys_log with a
 * plain "%s", which is a variadic CALL and therefore fine.
 */
int vsnprintf(char* buffer, size_t buffer_size, const char* format, va_list args);

/* panic, the fourth variadic definition, from stubs.c. The #undef is load bearing and comes
 * straight from stubs.c: XNU makes panic a MACRO, so without this the definition below expands
 * into something else entirely. */
#undef panic

__attribute__((noreturn))
void abort(void);

typedef struct FILE FILE;
extern FILE* stdout;

int fflush(FILE* stream);
int printf(const char* format, ...);
int vprintf(const char* format, va_list args);

void panic(const char* message, ...) {
	va_list args;
	va_start(args, message);
	printf("ciderd xnu-sys panic: ");
	vprintf(message, args);
	va_end(args);
	printf("\n");
	fflush(stdout);
	abort();
};

void xnu_sys_logv(xnu_sys_log_level_t level, const char* format, va_list args) {
	char message[4096];
	vsnprintf(message, sizeof(message), format, args);
	xnu_sys_hooks->log(level, message);
};

void xnu_sys_log(xnu_sys_log_level_t level, const char* format, ...) {
	va_list args;
	va_start(args, format);
	xnu_sys_logv(level, format, args);
	va_end(args);
};

void kprintf(const char* fmt, ...) {
	va_list args;
	va_start(args, fmt);
	xnu_sys_logv(xnu_sys_log_level_info, fmt, args);
	va_end(args);
};

int scnprintf(char* buffer, size_t buffer_size, const char* format, ...) {
	va_list args;
	va_start(args, format);
	int code = vsnprintf(buffer, buffer_size, format, args);
	va_end(args);
	if (code < 0) {
		return code;
	} else {
		return strnlen(buffer, buffer_size);
	}
};
