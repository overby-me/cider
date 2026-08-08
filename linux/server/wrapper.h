/* bindgen entry point for darlingserver.
 *
 * TWO SURFACES, one generated file, because rust_library takes a single out_dir.
 *
 * (1) THE HOOKS CONTRACT. The 36-field callback vtable the daemon implements, plus its
 * types. hooks.h is a self-contained SOURCE header -- it pulls only duct-tape/types.h
 * (stdint/stdbool) and libsimple/lock.h -- so this half needs no build, just two source
 * include dirs.
 *
 * (2) THE INTERNAL STRUCTS THE PORTED GLUE NEEDS (#71). duct-tape glue files are moving to
 * Rust one at a time, and they manipulate duct-tape's own structs: semaphore.c walks
 * owning_task->xnu_task, so Rust needs the offset of xnu_task inside struct dtape_task,
 * which embeds the whole XNU struct task. Generating that is the entire point -- an offset
 * transcribed by hand is an offset that drifts silently the next time the struct gains a
 * field.
 *
 * This half is NOT self-contained, and that is why it was left out until now. It reaches
 * internal-include, the XNU header roots, and two GENERATED trees: darlingserver/rpc.h
 * (the RPC wrapper generator, via duct-tape.h's DSERVER_DTAPE_DECLS) and the MIG output for
 * mach/task.h, where semaphore_create and semaphore_destroy are actually declared -- XNU's
 * kern/sync_sema.h declares only semaphore_destroy_all. linux/server/BUCK wires all of them
 * as include_dirs; build.rs mirrors it for the cargo path.
 *
 * The XNU giants (task, thread, ipc_*, vm_*, lck_*, ...) are marked opaque, so only their
 * SIZE crosses. Measured: that keeps the added surface to 21 items and about 3 KB, and the
 * pre-existing 62 items come out byte for byte identical apart from dtape_semaphore itself,
 * which is the point -- it was an empty placeholder before and is now the real struct.
 */
#include <darlingserver/duct-tape/hooks.h>

/* (2) internal structs + the XNU entry points the ported glue calls.
 *
 * task.h is listed even though semaphore.h already names dtape_task_t, because it only
 * FORWARD-DECLARES it: without this line dtape_task binds as an opaque [u8; 0] and the
 * xnu_task offset -- the one thing this half exists to provide -- is not there at all.
 */
#include <darlingserver/duct-tape/semaphore.h>
#include <darlingserver/duct-tape/task.h>
/* condvar.c walks back from a queue link to the containing dtape_thread, so the port needs
 * the offsets of mutex_link and of the embedded XNU thread. */
#include <darlingserver/duct-tape/thread.h>
#include <darlingserver/duct-tape/condvar.h>
#include <mach/task.h>
#include <mach/semaphore.h>
/* what timer.c itself includes: the timer queue it owns, and the XNU entry points it calls */
#include <kern/timer_call.h>
#include <kern/timer_queue.h>
#include <mach/mach_time.h>
#include <i386/rtclock_protos.h>
/* host.c fills three info structs by FIELD, so those three have to be real rather than opaque:
 * host_basic_info, host_priority_info and host_preferred_user_arch. The vm_statistics pair
 * stays opaque deliberately -- host_statistics and vm_stats only ever memset them to zero and
 * never name a field, so all the port needs from them is their SIZE, which an opaque binding
 * still carries. kern/sched.h is here for the priority constants the HOST_PRIORITY_INFO case
 * copies out of XNU. */
#include <kern/host.h>
#include <mach/host_info.h>
#include <mach/vm_statistics.h>
#include <kern/sched.h>
/* processor.c: the processor and pset structs it defines and fills. */
#include <kern/processor.h>
#include <kern/machine.h>
/* kqchan.c: the kqueue channel, its knote and the mqueue peeks it does. */
#include <darlingserver/duct-tape/kqchan.h>
#include <sys/event.h>
#include <ipc/ipc_mqueue.h>
#include <os/refcnt.h>
#include <kern/simple_lock.h>
/* init.c: the zones it creates, the locks it initialises, and the host it reaches into. */
#include <ipc/ipc_importance.h>
#include <ipc/ipc_init.h>
#include <ipc/ipc_pset.h>
#include <ipc/ipc_space.h>
#include <kern/ipc_host.h>
#include <kern/sync_sema.h>
#include <kern/zalloc.h>
/* the macro-only operations exported as symbols for the port */
#include <darlingserver/duct-tape/rs_shims.h>

/* struct task_id_token is defined in XNU osfmk/kern/task_ident.c, NOT in a header, and init.c
 * redefines it locally purely to get its SIZE for zone_create. The port needs the same size, so
 * the definition lives here where the C compiler computes it rather than as a number written
 * into Rust. Same three fields, same order, as both XNU and init.c have them.
 */
struct dtape_rs_task_id_token {
	struct proc_ident ident;
	ipc_port_t        port;
	os_refcnt_t       tidt_refs;
};

/* THE COUNT AND CPU MACROS, RE-EXPRESSED AS ENUMERATORS.
 *
 * bindgen binds a plain integer #define and nothing else. It cannot const-evaluate either
 * shape host.c relies on:
 *
 *   #define HOST_BASIC_INFO_COUNT  ((mach_msg_type_number_t)(sizeof(host_basic_info_data_t) \
 *                                                            / sizeof(integer_t)))
 *   #define CPU_TYPE_X86           ((cpu_type_t) 7)
 *
 * so both come out missing rather than wrong, which is the good failure but still a failure.
 * An enumerator initialiser IS an integer constant expression, so the compiler evaluates these
 * from the REAL macros and bindgen emits the values. Nothing is transcribed, so nothing drifts:
 * if host_basic_info gains a field, the count follows on the next build.
 */
enum dtape_rs_host_consts {
	DTAPE_RS_HOST_BASIC_INFO_COUNT = HOST_BASIC_INFO_COUNT,
	DTAPE_RS_HOST_BASIC_INFO_OLD_COUNT = HOST_BASIC_INFO_OLD_COUNT,
	DTAPE_RS_HOST_PRIORITY_INFO_COUNT = HOST_PRIORITY_INFO_COUNT,
	DTAPE_RS_HOST_PREFERRED_USER_ARCH_COUNT = HOST_PREFERRED_USER_ARCH_COUNT,
	DTAPE_RS_HOST_VM_INFO_REV0_COUNT = HOST_VM_INFO_REV0_COUNT,
	DTAPE_RS_HOST_VM_INFO64_COUNT = HOST_VM_INFO64_COUNT,
	DTAPE_RS_CPU_TYPE_X86 = CPU_TYPE_X86,
	DTAPE_RS_CPU_SUBTYPE_X86_64_ALL = CPU_SUBTYPE_X86_64_ALL,
	DTAPE_RS_CPU_THREADTYPE_NONE = CPU_THREADTYPE_NONE,
	/* processor.c, same sizeof-expression shape as the host counts above. */
	DTAPE_RS_PROCESSOR_BASIC_INFO_COUNT = PROCESSOR_BASIC_INFO_COUNT,
	DTAPE_RS_PROCESSOR_CPU_LOAD_INFO_COUNT = PROCESSOR_CPU_LOAD_INFO_COUNT,
	DTAPE_RS_PROCESSOR_SET_LOAD_INFO_COUNT = PROCESSOR_SET_LOAD_INFO_COUNT,
	DTAPE_RS_MAX_SCHED_CPUS = MAX_SCHED_CPUS,
	DTAPE_RS_PROCESSOR_SET_BASIC_INFO_COUNT = PROCESSOR_SET_BASIC_INFO_COUNT,
	DTAPE_RS_POLICY_TIMESHARE_LIMIT_COUNT = POLICY_TIMESHARE_LIMIT_COUNT,
	DTAPE_RS_POLICY_FIFO_LIMIT_COUNT = POLICY_FIFO_LIMIT_COUNT,
	DTAPE_RS_POLICY_RR_LIMIT_COUNT = POLICY_RR_LIMIT_COUNT,
	DTAPE_RS_POLICY_TIMESHARE_BASE_COUNT = POLICY_TIMESHARE_BASE_COUNT,
	DTAPE_RS_POLICY_FIFO_BASE_COUNT = POLICY_FIFO_BASE_COUNT,
	DTAPE_RS_POLICY_RR_BASE_COUNT = POLICY_RR_BASE_COUNT,
	/* init.c: sizes for zone_create, and the one macro-valued size among them. */
	DTAPE_RS_SIZEOF_TASK_ID_TOKEN = sizeof(struct dtape_rs_task_id_token),
	DTAPE_RS_IKM_SAVED_KMSG_SIZE = IKM_SAVED_KMSG_SIZE,
	/* kqchan.c: anonymous-enum values and macros bindgen does not surface by name. */
	DTAPE_RS_KN_VANISHED = KN_VANISHED,
	DTAPE_RS_THREAD_INTERRUPTIBLE = THREAD_INTERRUPTIBLE,
	DTAPE_RS_THREAD_INTERRUPTED = THREAD_INTERRUPTED,
};
