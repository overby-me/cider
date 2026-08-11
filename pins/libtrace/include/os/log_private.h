#ifndef _LIBTRACE_OS_LOG_PRIVATE_H_
#define _LIBTRACE_OS_LOG_PRIVATE_H_

#include <os/log.h>
#include <stdarg.h>
#include <time.h>
#include <sys/queue.h>

__BEGIN_DECLS

OS_EXPORT OS_NOTHROW OS_NOT_TAIL_CALLED OS_NONNULL5
void os_log_with_args(os_log_t oslog, os_log_type_t type, const char *format, va_list args, void *ret_addr);

OS_ENUM(oslog_stream_link_type, uint8_t,
	oslog_stream_link_type_log      = 0x0,
	oslog_stream_link_type_metadata = 0x1,
);

typedef struct os_log_pack_s os_log_pack_s;
typedef struct os_log_pack_s* os_log_pack_t;
struct os_log_pack_s {
	uint64_t olp_continuous_time;
	struct timespec olp_wall_time;
	const void* olp_mh;
	const void* olp_pc;
	const char* olp_format;
	uint8_t olp_data[];
};

// from https://github.com/apple/swift/blob/master/stdlib/public/Darwin/os/os.m
OS_EXPORT
size_t _os_log_pack_size(size_t os_log_format_buffer_size);

OS_EXPORT
uint8_t* _os_log_pack_fill(os_log_pack_t pack, size_t size, int saved_errno, const void* dso, const char* format);

OS_EXPORT
void os_log_pack_send(os_log_pack_t pack, os_log_t log, os_log_type_t type);

// needed for libc
// not entirely sure how these should be defined
#define os_log_pack_size(fmt, ...) _os_log_pack_size(sizeof(fmt))
// this one is definitely wrong (it's missing the va_args)
#define os_log_pack_fill(pack, size, errno, fmt, ...) _os_log_pack_fill(pack, size, errno, NULL, fmt)

OS_EXPORT
int os_log_shim_enabled(void* return_address);

__END_DECLS

#endif // _LIBTRACE_OS_LOG_PRIVATE_H_
