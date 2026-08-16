#ifndef _CIDERD_XNU_SYS_H_
#define _CIDERD_XNU_SYS_H_

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#include <libsimple/lock.h>
#include <ciderd/rpc.internal.h>
#include <ciderd/rpc-supplement.h>
#include <ciderd/rpc.h>

#include <ciderd/xnu-sys/types.h>
#include <ciderd/xnu-sys/hooks.h>

#ifdef __cplusplus
extern "C" {
#endif

void xnu_sys_init(const xnu_sys_hooks_t* hooks);
void xnu_sys_init_in_thread(void);
void xnu_sys_deinit(void);

uint32_t xnu_sys_task_self_trap(void);
uint32_t xnu_sys_host_self_trap(void);
uint32_t xnu_sys_thread_self_trap(void);
uint32_t xnu_sys_mach_reply_port(void);
uint32_t xnu_sys_thread_get_special_reply_port(void);
uint32_t xnu_sys_mk_timer_create(void);

DSERVER_XNU_SYS_DECLS;

typedef void (*xnu_sys_kqchan_mach_port_notification_callback_f)(void* context);

/**
 * The threshold beyond which thread IDs are considered IDs for kernel threads.
 * Thread IDs lower than this value are reserved for userspace threads.
 * Thread IDs greater than or equal to this value are reserved for kernelspace threads.
 *
 * This should NOT be used to differentiate kernelspace threads from userspace ones.
 * This is simply used as a convenient cutoff beyond which we do not expect Linux to actually assign
 * thread IDs within our namespace. In practice, there should be no difference between the way userspace
 * and kernelspace threads are handled in the xnu-sys code.
 *
 * This is used as the starting offset for thread IDs for kernelspace threads (which do not have a "real" managed Darling thread backing them).
 */
#define XNU_SYS_KERNEL_THREAD_ID_THRESHOLD (1ULL << 22)

/**
 * Creates a new xnu-sys task. The caller receives a reference on the new task.
 *
 * An @p nsid value of `0` indicates the task being created is the kernel task.
 */
xnu_sys_task_t* xnu_sys_task_create(xnu_sys_task_t* parent_task, uint32_t nsid, void* context, dserver_rpc_architecture_t architecture);
xnu_sys_thread_t* xnu_sys_thread_create(xnu_sys_task_t* task, uint64_t nsid, void* context);
xnu_sys_kqchan_mach_port_t* xnu_sys_kqchan_mach_port_create(xnu_sys_task_t* owning_task, uint32_t port, uint64_t receive_buffer, uint64_t receive_buffer_size, uint64_t saved_filter_flags, xnu_sys_kqchan_mach_port_notification_callback_f notification_callback, void* context);
xnu_sys_semaphore_t* xnu_sys_semaphore_create(xnu_sys_task_t* owning_task, int initial_value);

void xnu_sys_kqchan_mach_port_destroy(xnu_sys_kqchan_mach_port_t* kqchan);
void xnu_sys_semaphore_destroy(xnu_sys_semaphore_t* semaphore);

void xnu_sys_thread_entering(xnu_sys_thread_t* thread);
void xnu_sys_thread_exiting(xnu_sys_thread_t* thread);
void xnu_sys_thread_set_handles(xnu_sys_thread_t* thread, uintptr_t pthread_handle, uintptr_t dispatch_qaddr);
/**
 * Returns the thread corresponding to the given thread port.
 *
 * @warning It is VERY important that the caller ensures the thread cannot die while we're looking it up.
 *          This can be accomplished, for example, by locking the global thread list before the call.
 */
xnu_sys_thread_t* xnu_sys_thread_for_port(uint32_t thread_port);
void* xnu_sys_thread_context(xnu_sys_thread_t* thread);
int xnu_sys_thread_load_state_from_user(xnu_sys_thread_t* thread, uintptr_t thread_state_address, uintptr_t float_state_address);
int xnu_sys_thread_save_state_to_user(xnu_sys_thread_t* thread, uintptr_t thread_state_address, uintptr_t float_state_address);
void xnu_sys_thread_process_signal(xnu_sys_thread_t* thread, int bsd_signal_number, int linux_signal_number, int code, uintptr_t signal_address);
void xnu_sys_thread_wait_while_user_suspended(xnu_sys_thread_t* thread);
void xnu_sys_thread_retain(xnu_sys_thread_t* thread);
void xnu_sys_thread_release(xnu_sys_thread_t* thread);
void xnu_sys_thread_sigexc_enter(xnu_sys_thread_t* thread);
void xnu_sys_thread_sigexc_exit(xnu_sys_thread_t* thread);
void xnu_sys_thread_sigexc_enter2(xnu_sys_thread_t* thread);
void xnu_sys_thread_dying(xnu_sys_thread_t* thread);

void xnu_sys_task_uidgid(xnu_sys_task_t* task, int new_uid, int new_gid, int* old_uid, int* old_gid);
void xnu_sys_task_retain(xnu_sys_task_t* task);
void xnu_sys_task_release(xnu_sys_task_t* task);
void xnu_sys_task_dying(xnu_sys_task_t* task);
void xnu_sys_task_set_dyld_info(xnu_sys_task_t* task, uint64_t address, uint64_t length);
void xnu_sys_task_set_sigexc_enabled(xnu_sys_task_t* task, bool enabled);
bool xnu_sys_task_try_resume(xnu_sys_task_t* task);

/**
 * Invoked when a timer armed by an earlier call to the timer_arm hook expires.
 *
 * It is allowed to be invoked spuriously.
 */
void xnu_sys_timer_fired(void);

void xnu_sys_kqchan_mach_port_modify(xnu_sys_kqchan_mach_port_t* kqchan, uint64_t receive_buffer, uint64_t receive_buffer_size, uint64_t saved_filter_flags);
void xnu_sys_kqchan_mach_port_disable_notifications(xnu_sys_kqchan_mach_port_t* kqchan);
bool xnu_sys_kqchan_mach_port_fill(xnu_sys_kqchan_mach_port_t* kqchan, dserver_kqchan_reply_mach_port_read_t* reply, uint64_t default_buffer, uint64_t default_buffer_size);
bool xnu_sys_kqchan_mach_port_has_events(xnu_sys_kqchan_mach_port_t* kqchan);

void xnu_sys_semaphore_up(xnu_sys_semaphore_t* semaphore);
xnu_sys_semaphore_wait_result_t xnu_sys_semaphore_down(xnu_sys_semaphore_t* semaphore);
bool xnu_sys_semaphore_down_simple(xnu_sys_semaphore_t* semaphore);

uint64_t xnu_sys_debug_task_port_count(xnu_sys_task_t* task);
uint64_t xnu_sys_debug_task_list_ports(xnu_sys_task_t* task, xnu_sys_debug_task_list_ports_iterator_f iterator, void* context);
uint64_t xnu_sys_debug_portset_list_members(xnu_sys_task_t* task, uint32_t portset, xnu_sys_debug_portset_list_members_iterator_f iterator, void* context);
uint64_t xnu_sys_debug_port_list_messages(xnu_sys_task_t* task, uint32_t port, xnu_sys_debug_port_list_messages_iterator_f iterator, void* context);

#ifdef __cplusplus
};
#endif

#endif // _CIDERD_XNU_SYS_H_
