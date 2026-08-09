/* bindgen entry point for darlingserver.
 *
 * TWO SURFACES, one generated file, because rust_library takes a single out_dir.
 *
 * (1) THE HOOKS CONTRACT. The 36-field callback vtable the daemon implements, plus its
 * types. hooks.h is a self-contained SOURCE header -- it pulls only xnu-sys/types.h
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
#include <darlingserver/xnu-sys/hooks.h>

/* (2) internal structs + the XNU entry points the ported glue calls.
 *
 * task.h is listed even though semaphore.h already names dtape_task_t, because it only
 * FORWARD-DECLARES it: without this line dtape_task binds as an opaque [u8; 0] and the
 * xnu_task offset -- the one thing this half exists to provide -- is not there at all.
 */
#include <darlingserver/xnu-sys/semaphore.h>
#include <darlingserver/xnu-sys/task.h>
/* condvar.c walks back from a queue link to the containing dtape_thread, so the port needs
 * the offsets of mutex_link and of the embedded XNU thread. */
#include <darlingserver/xnu-sys/thread.h>
#include <darlingserver/xnu-sys/condvar.h>
#include <mach/task.h>
#include <mach/semaphore.h>
/* what timer.c itself includes: the timer queue it owns, and the XNU entry points it calls */
#include <kern/timer_call.h>
#include <kern/timer_queue.h>
#include <mach/mach_time.h>
/* traps.c: the Mach trap entry points and their argument structs. */
#include <mach/mach_traps.h>
/* psynch.c: the pthread kext callback table and the BSD sleep path. */
#include <darlingserver/xnu-sys/psynch.h>
#include <kern/sched_prim.h>
#include <kern/clock.h>
#include <sys/proc.h>
#include <sys/pthread_shims.h>
#include <kern/thread_call.h>
/* The pthread kext entry points psynch.c forwards to, declared here rather than by including
 * the kext's own kern_internal.h. That header cannot be used: something earlier in this wrapper
 * already claims its guard, _SYS_PTHREAD_INTERNAL_H_, so its body is skipped and the
 * declarations never arrive, and undefining the guard to force it through makes it drag in
 * sys/stat.h and net/if.h, which do not parse in this configuration (unknown type nlink_t,
 * incomplete struct if_data).
 *
 * These are copied from the extern block at the top of xnu-sys/src/psynch.c, which re-declares
 * them for the same reason. When psynch.c becomes Rust the block has to live somewhere, and
 * here bindgen types it rather than the port transcribing nine signatures by hand. */
extern int _psynch_cvbroad(proc_t p, user_addr_t cv, uint64_t cvlsgen, uint64_t cvudgen, uint32_t flags, user_addr_t mutex, uint64_t mugen, uint64_t tid, uint32_t* retval);
extern int _psynch_cvclrprepost(proc_t p, user_addr_t cv, uint32_t cvgen, uint32_t cvugen, uint32_t cvsgen, uint32_t prepocnt, uint32_t preposeq, uint32_t flags, int* retval);
extern int _psynch_cvsignal(proc_t p, user_addr_t cv, uint64_t cvlsgen, uint32_t cvugen, int threadport, user_addr_t mutex, uint64_t mugen, uint64_t tid, uint32_t flags, uint32_t* retval);
extern int _psynch_cvwait(proc_t p, user_addr_t cv, uint64_t cvlsgen, uint32_t cvugen, user_addr_t mutex, uint64_t mugen, uint32_t flags, int64_t sec, uint32_t nsec, uint32_t* retval);
extern int _psynch_mutexdrop(proc_t p, user_addr_t mutex, uint32_t mgen, uint32_t ugen, uint64_t tid, uint32_t flags, uint32_t* retval);
extern int _psynch_mutexwait(proc_t p, user_addr_t mutex, uint32_t mgen, uint32_t ugen, uint64_t tid, uint32_t flags, uint32_t* retval);
extern int _psynch_rw_rdlock(proc_t p, user_addr_t rwlock, uint32_t lgenval, uint32_t ugenval, uint32_t rw_wc, int flags, uint32_t* retval);
extern int _psynch_rw_unlock(proc_t p, user_addr_t rwlock, uint32_t lgenval, uint32_t ugenval, uint32_t rw_wc, int flags, uint32_t* retval);
extern int _psynch_rw_wrlock(proc_t p, user_addr_t rwlock, uint32_t lgenval, uint32_t ugenval, uint32_t rw_wc, int flags, uint32_t* retval);
/* thread.c calls bsd_exception, which no reachable header declares. Same situation as the
 * psynch entry points above, and the same answer: declare it here so bindgen types it. */
extern void bsd_exception(int exception, long long* codes, int code_count);

extern void psynch_zoneinit(void);
extern void _pth_proc_hashinit(proc_t p);
extern void _pth_proc_hashdelete(proc_t p);
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
#include <darlingserver/xnu-sys/kqchan.h>
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
/* misc.c: the machine-state count table, the kmsg trace and the log entry points. */
#include <mach/i386/thread_status.h>
#include <ipc/ipc_kmsg.h>
#include <darlingserver/xnu-sys/log.h>
/* task.c: the info flavors it fills and the IPC entry points it drives. */
#include <kern/ipc_tt.h>
#include <kern/restartable.h>
#include <mach/mach_port.h>
#include <ipc/ipc_hash.h>
#include <darlingserver/xnu-sys/memory.h>
/* memory.c: the region info structs it fills, the VM flag families and the zone info types. */
#include <mach/vm_region.h>
#include <mach/vm_prot.h>
#include <mach/memory_object_types.h>
#include <mach_debug/zone_info.h>
#include <mach_debug/vm_info.h>
#include <vm/vm_kern.h>
/* thread.c: the thread state flavors it loads and stores, and the exception path. */
#include <mach/thread_act.h>
#include <sys/ux_exception.h>
#include <mach/thread_info.h>
#include <rtsig.h>
#include <mach/i386/thread_status.h>
/* stubs.c: the globals XNU writes into and the parameter types of the stubs. */
#include <darlingserver/xnu-sys/stubs.h>
#include <kern/policy_internal.h>
#include <sys/file_internal.h>
#include <pthread/workqueue_internal.h>
#include <mach_debug/lockgroup_info.h>
#include <mach/kmod.h>
/* stubs.c takes DTAPE_FATAL_STUBS from the command line if it is set and 0 otherwise, and the
 * port has to make the same choice, so the same #ifndef decides it here. */
#ifndef DTAPE_FATAL_STUBS
	#define DTAPE_FATAL_STUBS 0
#endif
/* the macro-only operations exported as symbols for the port */
#include <darlingserver/xnu-sys/rs_shims.h>

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
	/* psynch.c: more anonymous-enum wait results and the abortsafe level. */
	DTAPE_RS_THREAD_ABORTSAFE = THREAD_ABORTSAFE,
	DTAPE_RS_THREAD_AWAKENED = THREAD_AWAKENED,
	DTAPE_RS_THREAD_RESTART = THREAD_RESTART,
	DTAPE_RS_THREAD_TIMED_OUT = THREAD_TIMED_OUT,
	DTAPE_RS_THREAD_UNINT = THREAD_UNINT,
	/* CONFIG_THREAD_MAX comes from a -D on the command line rather than from a header, and
	 * bindgen only surfaces macros it can attribute to a file, so allowlisting it by name
	 * matches nothing. As an enumerator the compiler evaluates it like any other. */
	DTAPE_RS_CONFIG_THREAD_MAX = CONFIG_THREAD_MAX,
	/* hashinit allocates with Z_WAITOK | Z_ZERO. Enumerators of zalloc_flags_t, which the port
	 * does not otherwise need, so they come across as values rather than reopening the type. */
	DTAPE_RS_Z_WAITOK = Z_WAITOK,
	DTAPE_RS_Z_ZERO = Z_ZERO,
	/* thread.c: the leaf state counts, the wait result and the RT signal number. */
	DTAPE_RS_x86_THREAD_STATE32_COUNT = x86_THREAD_STATE32_COUNT,
	DTAPE_RS_x86_THREAD_STATE64_COUNT = x86_THREAD_STATE64_COUNT,
	DTAPE_RS_x86_FLOAT_STATE32_COUNT = x86_FLOAT_STATE32_COUNT,
	DTAPE_RS_x86_FLOAT_STATE64_COUNT = x86_FLOAT_STATE64_COUNT,
	DTAPE_RS_THREAD_WAITING = THREAD_WAITING,
	DTAPE_RS_LINUX_SIGRTMIN = LINUX_SIGRTMIN,
	/* thread.c: the composite state counts and the thread info counts, all sizeof
	 * expressions, plus the exception code array bound. */
	DTAPE_RS_x86_THREAD_STATE_COUNT = x86_THREAD_STATE_COUNT,
	DTAPE_RS_x86_FLOAT_STATE_COUNT = x86_FLOAT_STATE_COUNT,
	DTAPE_RS_x86_DEBUG_STATE_COUNT = x86_DEBUG_STATE_COUNT,
	DTAPE_RS_x86_DEBUG_STATE32_COUNT = x86_DEBUG_STATE32_COUNT,
	DTAPE_RS_x86_DEBUG_STATE64_COUNT = x86_DEBUG_STATE64_COUNT,
	DTAPE_RS_THREAD_IDENTIFIER_INFO_COUNT = THREAD_IDENTIFIER_INFO_COUNT,
	DTAPE_RS_THREAD_BASIC_INFO_COUNT = THREAD_BASIC_INFO_COUNT,
	DTAPE_RS_EXCEPTION_CODE_MAX = EXCEPTION_CODE_MAX,
	/* memory.c: the region info counts are sizeof expressions and the address ceiling is a
	 * cast macro, so none of them can come through the allowlist. */
	DTAPE_RS_MACH_VM_MAX_ADDRESS = MACH_VM_MAX_ADDRESS,
	DTAPE_RS_VM_REGION_BASIC_INFO_COUNT = VM_REGION_BASIC_INFO_COUNT,
	DTAPE_RS_VM_REGION_BASIC_INFO_COUNT_64 = VM_REGION_BASIC_INFO_COUNT_64,
	DTAPE_RS_VM_REGION_SUBMAP_SHORT_INFO_COUNT_64 = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64,
	/* memory.c: the protection, sync and behavior values are CAST macros, so bindgen
	 * cannot emit them and the allowlist matched nothing. Enumerators instead. */
	DTAPE_RS_VM_PROT_NONE = VM_PROT_NONE,
	DTAPE_RS_VM_PROT_READ = VM_PROT_READ,
	DTAPE_RS_VM_PROT_WRITE = VM_PROT_WRITE,
	DTAPE_RS_VM_PROT_EXECUTE = VM_PROT_EXECUTE,
	DTAPE_RS_VM_PROT_ALL = VM_PROT_ALL,
	DTAPE_RS_VM_SYNC_ASYNCHRONOUS = VM_SYNC_ASYNCHRONOUS,
	DTAPE_RS_VM_SYNC_SYNCHRONOUS = VM_SYNC_SYNCHRONOUS,
	DTAPE_RS_VM_SYNC_INVALIDATE = VM_SYNC_INVALIDATE,
	DTAPE_RS_VM_BEHAVIOR_DEFAULT = VM_BEHAVIOR_DEFAULT,
	/* task.c: the default role, an enum variant of a type nothing else needs. */
	DTAPE_RS_TASK_UNSPECIFIED = TASK_UNSPECIFIED,
	/* task.c: the info-flavor counts, every one a sizeof expression the C must evaluate. */
	DTAPE_RS_TASK_BASIC_INFO_32_COUNT = TASK_BASIC_INFO_32_COUNT,
	DTAPE_RS_TASK_BASIC_INFO_64_COUNT = TASK_BASIC_INFO_64_COUNT,
	DTAPE_RS_MACH_TASK_BASIC_INFO_COUNT = MACH_TASK_BASIC_INFO_COUNT,
	DTAPE_RS_TASK_THREAD_TIMES_INFO_COUNT = TASK_THREAD_TIMES_INFO_COUNT,
	DTAPE_RS_TASK_DYLD_INFO_COUNT = TASK_DYLD_INFO_COUNT,
	DTAPE_RS_TASK_AUDIT_TOKEN_COUNT = TASK_AUDIT_TOKEN_COUNT,
	DTAPE_RS_TASK_VM_INFO_REV0_COUNT = TASK_VM_INFO_REV0_COUNT,
	DTAPE_RS_TASK_VM_INFO_REV1_COUNT = TASK_VM_INFO_REV1_COUNT,
	DTAPE_RS_TASK_VM_INFO_REV2_COUNT = TASK_VM_INFO_REV2_COUNT,
	DTAPE_RS_TASK_VM_INFO_REV3_COUNT = TASK_VM_INFO_REV3_COUNT,
	DTAPE_RS_TASK_VM_INFO_REV4_COUNT = TASK_VM_INFO_REV4_COUNT,
	DTAPE_RS_TASK_VM_INFO_REV5_COUNT = TASK_VM_INFO_REV5_COUNT,
	DTAPE_RS_TASK_FLAGS_INFO_COUNT = TASK_FLAGS_INFO_COUNT,
	/* stubs.c: whether an unknown-safety stub aborts. A build-time choice, so it is the C that
	 * makes it rather than a constant written into Rust. */
	DTAPE_RS_DTAPE_FATAL_STUBS = DTAPE_FATAL_STUBS,
	/* THE LAYOUT INVARIANT THE WHOLE PORT RESTS ON.
	 *
	 * Five ported files walk back from an embedded XNU struct to the duct-tape one that
	 * contains it, using offset_of. That is only correct while Rust and C agree on the layout
	 * of both, and nothing checks it: bindgen runs with --no-layout-tests, and marking a type
	 * opaque or reopening it is exactly the kind of change that could move a field silently.
	 * These are the C compiler answers, asserted against Rust in linux/server/src/layout.rs. */
	DTAPE_RS_SIZEOF_XNU_TASK = sizeof(struct task),
	DTAPE_RS_SIZEOF_XNU_THREAD = sizeof(struct thread),
	DTAPE_RS_SIZEOF_DTAPE_TASK = sizeof(struct dtape_task),
	DTAPE_RS_SIZEOF_DTAPE_THREAD = sizeof(struct dtape_thread),
	DTAPE_RS_OFFSETOF_DTAPE_TASK_XNU_TASK = __builtin_offsetof(struct dtape_task, xnu_task),
	DTAPE_RS_OFFSETOF_DTAPE_THREAD_XNU_THREAD = __builtin_offsetof(struct dtape_thread, xnu_thread),
	/* misc.c: the _MachineStateCount table. Both halves are macros, the flavor an integer
	 * and the count a sizeof expression, so both are evaluated here rather than written
	 * into Rust. The table is indexed BY the flavor, so a wrong index would be silent. */
	DTAPE_RS_X86_THREAD_STATE32 = x86_THREAD_STATE32,
	DTAPE_RS_X86_THREAD_STATE32_COUNT = x86_THREAD_STATE32_COUNT,
	DTAPE_RS_X86_THREAD_STATE64 = x86_THREAD_STATE64,
	DTAPE_RS_X86_THREAD_STATE64_COUNT = x86_THREAD_STATE64_COUNT,
	DTAPE_RS_X86_THREAD_FULL_STATE64 = x86_THREAD_FULL_STATE64,
	DTAPE_RS_X86_THREAD_FULL_STATE64_COUNT = x86_THREAD_FULL_STATE64_COUNT,
	DTAPE_RS_X86_THREAD_STATE = x86_THREAD_STATE,
	DTAPE_RS_X86_THREAD_STATE_COUNT = x86_THREAD_STATE_COUNT,
	DTAPE_RS_X86_FLOAT_STATE32 = x86_FLOAT_STATE32,
	DTAPE_RS_X86_FLOAT_STATE32_COUNT = x86_FLOAT_STATE32_COUNT,
	DTAPE_RS_X86_FLOAT_STATE64 = x86_FLOAT_STATE64,
	DTAPE_RS_X86_FLOAT_STATE64_COUNT = x86_FLOAT_STATE64_COUNT,
	DTAPE_RS_X86_FLOAT_STATE = x86_FLOAT_STATE,
	DTAPE_RS_X86_FLOAT_STATE_COUNT = x86_FLOAT_STATE_COUNT,
	DTAPE_RS_X86_EXCEPTION_STATE32 = x86_EXCEPTION_STATE32,
	DTAPE_RS_X86_EXCEPTION_STATE32_COUNT = x86_EXCEPTION_STATE32_COUNT,
	DTAPE_RS_X86_EXCEPTION_STATE64 = x86_EXCEPTION_STATE64,
	DTAPE_RS_X86_EXCEPTION_STATE64_COUNT = x86_EXCEPTION_STATE64_COUNT,
	DTAPE_RS_X86_EXCEPTION_STATE = x86_EXCEPTION_STATE,
	DTAPE_RS_X86_EXCEPTION_STATE_COUNT = x86_EXCEPTION_STATE_COUNT,
	DTAPE_RS_X86_DEBUG_STATE32 = x86_DEBUG_STATE32,
	DTAPE_RS_X86_DEBUG_STATE32_COUNT = x86_DEBUG_STATE32_COUNT,
	DTAPE_RS_X86_DEBUG_STATE64 = x86_DEBUG_STATE64,
	DTAPE_RS_X86_DEBUG_STATE64_COUNT = x86_DEBUG_STATE64_COUNT,
	DTAPE_RS_X86_DEBUG_STATE = x86_DEBUG_STATE,
	DTAPE_RS_X86_DEBUG_STATE_COUNT = x86_DEBUG_STATE_COUNT,
	DTAPE_RS_X86_AVX_STATE32 = x86_AVX_STATE32,
	DTAPE_RS_X86_AVX_STATE32_COUNT = x86_AVX_STATE32_COUNT,
	DTAPE_RS_X86_AVX_STATE64 = x86_AVX_STATE64,
	DTAPE_RS_X86_AVX_STATE64_COUNT = x86_AVX_STATE64_COUNT,
	DTAPE_RS_X86_AVX_STATE = x86_AVX_STATE,
	DTAPE_RS_X86_AVX_STATE_COUNT = x86_AVX_STATE_COUNT,
	DTAPE_RS_X86_AVX512_STATE32 = x86_AVX512_STATE32,
	DTAPE_RS_X86_AVX512_STATE32_COUNT = x86_AVX512_STATE32_COUNT,
	DTAPE_RS_X86_AVX512_STATE64 = x86_AVX512_STATE64,
	DTAPE_RS_X86_AVX512_STATE64_COUNT = x86_AVX512_STATE64_COUNT,
	DTAPE_RS_X86_AVX512_STATE = x86_AVX512_STATE,
	DTAPE_RS_X86_AVX512_STATE_COUNT = x86_AVX512_STATE_COUNT,
	DTAPE_RS_X86_PAGEIN_STATE = x86_PAGEIN_STATE,
	DTAPE_RS_X86_PAGEIN_STATE_COUNT = x86_PAGEIN_STATE_COUNT,
};
