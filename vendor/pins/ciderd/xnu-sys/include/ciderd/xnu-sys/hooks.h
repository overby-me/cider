#ifndef _CIDERD_XNU_SYS_HOOKS_H_
#define _CIDERD_XNU_SYS_HOOKS_H_

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include <libsimple/lock.h>
#include <ciderd/xnu-sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef xnu_sys_task_t* (*xnu_sys_hook_current_task_f)(void);
typedef xnu_sys_thread_t* (*xnu_sys_hook_current_thread_f)(void);

/**
 * Arms a timer that should invoke xnu_sys_timer_fired when it expires.
 * The deadline is given as an absolute timepoint with respect to the system's monotonic clock.
 *
 * When called with 0 or UINT64_MAX, the timer should instead be disarmed.
 *
 * Normally, the deadline will only be updated if the given deadline is less than
 * the current deadline (with an exception for 0/UINT64_MAX). If @p override is `true`,
 * this will forcibly update the timer deadline, even if it is later than the current deadline.
 */
typedef void (*xnu_sys_hook_timer_arm_f)(uint64_t absolute_ns, bool override);

typedef void (*xnu_sys_hook_log_f)(xnu_sys_log_level_t level, const char* message);
typedef void (*xnu_sys_hook_get_load_info_f)(xnu_sys_load_info_t* load_info);

typedef void (*xnu_sys_hook_thread_suspend_f)(void* thread_context, xnu_sys_thread_continuation_callback_f continuation_callback, void* continuation_contex, libsimple_lock_t* unlock_me);
typedef void (*xnu_sys_hook_thread_resume_f)(void* thread_context);
typedef void (*xnu_sys_hook_thread_terminate_f)(void* thread_context);
typedef xnu_sys_thread_t* (*xnu_sys_hook_thread_create_kernel_f)(void);
typedef void (*xnu_sys_hook_thread_setup_f)(void* thread_context, xnu_sys_thread_continuation_callback_f continuation_callback, void* continuation_context);
typedef void (*xnu_sys_hook_thread_set_pending_signal_f)(void* thread_context, int pending_signal);
typedef void (*xnu_sys_hook_thread_set_pending_call_override_f)(void* thread_context, bool pending_call_override);
typedef xnu_sys_thread_t* (*xnu_sys_hook_thread_lookup_f)(int id, bool id_is_nsid, bool retain);
typedef xnu_sys_thread_t* (*xnu_sys_hook_thread_lookup_eternal_f)(xnu_sys_eternal_id_t eid, bool retain);
typedef xnu_sys_thread_state_t (*xnu_sys_hook_thread_get_state_f)(void* thread_context);
typedef int (*xnu_sys_hook_thread_send_signal_f)(void* thread_context, int signal);
typedef void (*xnu_sys_hook_thread_context_dispose_f)(void* thread_context);
typedef xnu_sys_eternal_id_t (*xnu_sys_hook_thread_eternal_id_f)(void* thread_context);

typedef void (*xnu_sys_hook_current_thread_interrupt_disable_f)(void);
typedef void (*xnu_sys_hook_current_thread_interrupt_enable_f)(void);
typedef void (*xnu_sys_hook_current_thread_syscall_return_f)(int return_code);
typedef void (*xnu_sys_hook_current_thread_set_bsd_retval_f)(uint32_t retval);

typedef bool (*xnu_sys_hook_task_read_memory_f)(void* task_context, uintptr_t remote_address, void* local_buffer, size_t length);
typedef bool (*xnu_sys_hook_task_write_memory_f)(void* task_context, uintptr_t remote_address, const void* local_buffer, size_t length);
typedef xnu_sys_task_t* (*xnu_sys_hook_task_lookup_f)(int id, bool id_is_nsid, bool retain);
typedef xnu_sys_task_t* (*xnu_sys_hook_task_lookup_eternal_f)(xnu_sys_eternal_id_t eid, bool retain);
typedef void (*xnu_sys_hook_task_get_memory_info_f)(void* task_context, xnu_sys_memory_info_t* memory_info);
typedef bool (*xnu_sys_hook_task_get_memory_region_info_f)(void* task_context, uintptr_t address, xnu_sys_memory_region_info_t* memory_region_info);
typedef uintptr_t (*xnu_sys_hook_task_allocate_pages_f)(void* task_context, size_t page_count, int protection, uintptr_t address_hint, xnu_sys_memory_flags_t flags);
typedef int (*xnu_sys_hook_task_free_pages_f)(void* task_context, uintptr_t address, size_t page_count);
typedef uintptr_t (*xnu_sys_hook_task_map_file_f)(void* task_context, int fd, size_t page_count, int protection, uintptr_t address_hint, size_t page_offset, xnu_sys_memory_flags_t flags);
typedef uintptr_t (*xnu_sys_hook_task_get_next_region_f)(void* task_context, uintptr_t address);
typedef bool (*xnu_sys_hook_task_change_protection_f)(void* task_context, uintptr_t address, size_t page_count, int protection);
typedef bool (*xnu_sys_hook_task_sync_memory_f)(void* task_context, uintptr_t address, size_t size, int sync_flags);
typedef void (*xnu_sys_hook_task_context_dispose_f)(void* task_context);
typedef xnu_sys_eternal_id_t (*xnu_sys_hook_task_eternal_id_f)(void* thread_context);

#if DSERVER_EXTENDED_DEBUG
	typedef void (*xnu_sys_hook_task_register_name_f)(void* task_context, uint32_t name, uintptr_t pointer);
	typedef void (*xnu_sys_hook_task_unregister_name_f)(void* task_context, uint32_t name);
	typedef void (*xnu_sys_hook_task_add_port_set_member_f)(void* task_context, xnu_sys_port_set_id_t port_set, xnu_sys_port_id_t member);
	typedef void (*xnu_sys_hook_task_remove_port_set_member_f)(void* task_context, xnu_sys_port_set_id_t port_set, xnu_sys_port_id_t member);
	typedef void (*xnu_sys_hook_task_clear_port_set_f)(void* task_context, xnu_sys_port_set_id_t port_set);
#endif

typedef struct xnu_sys_hooks {
	xnu_sys_hook_current_task_f current_task;
	xnu_sys_hook_current_thread_f current_thread;

	xnu_sys_hook_timer_arm_f timer_arm;

	xnu_sys_hook_log_f log;
	xnu_sys_hook_get_load_info_f get_load_info;

	xnu_sys_hook_thread_suspend_f thread_suspend;
	xnu_sys_hook_thread_resume_f thread_resume;
	xnu_sys_hook_thread_terminate_f thread_terminate;
	xnu_sys_hook_thread_create_kernel_f thread_create_kernel;
	xnu_sys_hook_thread_setup_f thread_setup;
	xnu_sys_hook_thread_set_pending_signal_f thread_set_pending_signal;
	xnu_sys_hook_thread_set_pending_call_override_f thread_set_pending_call_override;
	xnu_sys_hook_thread_lookup_f thread_lookup;
	xnu_sys_hook_thread_lookup_eternal_f thread_lookup_eternal;
	xnu_sys_hook_thread_get_state_f thread_get_state;
	xnu_sys_hook_thread_send_signal_f thread_send_signal;
	xnu_sys_hook_thread_context_dispose_f thread_context_dispose;
	xnu_sys_hook_thread_eternal_id_f thread_eternal_id;

	xnu_sys_hook_current_thread_interrupt_disable_f current_thread_interrupt_disable;
	xnu_sys_hook_current_thread_interrupt_enable_f current_thread_interrupt_enable;
	xnu_sys_hook_current_thread_syscall_return_f current_thread_syscall_return;
	xnu_sys_hook_current_thread_set_bsd_retval_f current_thread_set_bsd_retval;

	xnu_sys_hook_task_read_memory_f task_read_memory;
	xnu_sys_hook_task_write_memory_f task_write_memory;
	xnu_sys_hook_task_lookup_f task_lookup;
	xnu_sys_hook_task_lookup_eternal_f task_lookup_eternal;
	xnu_sys_hook_task_get_memory_info_f task_get_memory_info;
	xnu_sys_hook_task_get_memory_region_info_f task_get_memory_region_info;
	xnu_sys_hook_task_allocate_pages_f task_allocate_pages;
	xnu_sys_hook_task_free_pages_f task_free_pages;
	xnu_sys_hook_task_map_file_f task_map_file;
	xnu_sys_hook_task_get_next_region_f task_get_next_region;
	xnu_sys_hook_task_change_protection_f task_change_protection;
	xnu_sys_hook_task_sync_memory_f task_sync_memory;
	xnu_sys_hook_task_context_dispose_f task_context_dispose;
	xnu_sys_hook_task_eternal_id_f task_eternal_id;

#if DSERVER_EXTENDED_DEBUG
	xnu_sys_hook_task_register_name_f task_register_name;
	xnu_sys_hook_task_unregister_name_f task_unregister_name;
	xnu_sys_hook_task_add_port_set_member_f task_add_port_set_member;
	xnu_sys_hook_task_remove_port_set_member_f task_remove_port_set_member;
	xnu_sys_hook_task_clear_port_set_f task_clear_port_set;
#endif
} xnu_sys_hooks_t;

#ifdef __cplusplus
};
#endif

#endif // _CIDERD_XNU_SYS_HOOKS_H_
