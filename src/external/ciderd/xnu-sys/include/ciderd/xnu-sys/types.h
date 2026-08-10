#ifndef _DARLINGSERVER_XNU_SYS_TYPES_H_
#define _DARLINGSERVER_XNU_SYS_TYPES_H_

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct xnu_sys_thread xnu_sys_thread_t;
typedef struct xnu_sys_task xnu_sys_task_t;
typedef struct xnu_sys_kqchan_mach_port xnu_sys_kqchan_mach_port_t;
typedef struct xnu_sys_semaphore xnu_sys_semaphore_t;
typedef uint64_t xnu_sys_eternal_id_t;

typedef enum xnu_sys_log_level {
	xnu_sys_log_level_debug,
	xnu_sys_log_level_info,
	xnu_sys_log_level_warning,
	xnu_sys_log_level_error,
} xnu_sys_log_level_t;

typedef enum xnu_sys_semaphore_wait_result {
	xnu_sys_semaphore_wait_result_error = -1,
	xnu_sys_semaphore_wait_result_ok = 0,
	xnu_sys_semaphore_wait_result_interrupted = 1,
} xnu_sys_semaphore_wait_result_t;

typedef void (*xnu_sys_thread_continuation_callback_f)(void* context);

typedef struct xnu_sys_memory_info {
	uint64_t virtual_size;
	uint64_t resident_size;
	uint64_t page_size;
	uint64_t region_count;
} xnu_sys_memory_info_t;

typedef enum xnu_sys_memory_protection {
	xnu_sys_memory_protection_none = 0,
	xnu_sys_memory_protection_read = 1 << 0,
	xnu_sys_memory_protection_write = 1 << 1,
	xnu_sys_memory_protection_execute = 1 << 2,
} __attribute__((flag_enum)) xnu_sys_memory_protection_t;

typedef struct xnu_sys_memory_region_info {
	uintptr_t start_address;
	uint64_t page_count;
	uint64_t map_offset;
	xnu_sys_memory_protection_t protection;
	bool shared;
} xnu_sys_memory_region_info_t;

typedef enum xnu_sys_memory_flags {
	xnu_sys_memory_flag_none = 0,
	xnu_sys_memory_flag_fixed = 1ULL << 0,
	xnu_sys_memory_flag_overwrite = 1ULL << 1,
} xnu_sys_memory_flags_t;

#if DSERVER_EXTENDED_DEBUG
	typedef uintptr_t xnu_sys_port_id_t;
	typedef uintptr_t xnu_sys_port_set_id_t;
#endif

typedef enum xnu_sys_thread_state {
	xnu_sys_thread_state_dead,
	xnu_sys_thread_state_running,
	xnu_sys_thread_state_stopped,
	xnu_sys_thread_state_interruptible,
	xnu_sys_thread_state_uninterruptible,
} xnu_sys_thread_state_t;

typedef struct xnu_sys_load_info {
	uint64_t task_count;
	uint64_t thread_count;
} xnu_sys_load_info_t;

typedef struct xnu_sys_debug_port {
	uint32_t name;
	uint32_t rights;
	uint64_t refs;
	uint64_t messages;
} xnu_sys_debug_port_t;

typedef bool (*xnu_sys_debug_task_list_ports_iterator_f)(void* context, const xnu_sys_debug_port_t* port);
typedef bool (*xnu_sys_debug_portset_list_members_iterator_f)(void* context, const xnu_sys_debug_port_t* port);

typedef struct xnu_sys_debug_message {
	uint32_t sender;
	uint64_t size;
} xnu_sys_debug_message_t;

typedef bool (*xnu_sys_debug_port_list_messages_iterator_f)(void* context, const xnu_sys_debug_message_t* message);

#ifdef __cplusplus
};
#endif

#endif // _DARLINGSERVER_XNU_SYS_TYPES_H_
