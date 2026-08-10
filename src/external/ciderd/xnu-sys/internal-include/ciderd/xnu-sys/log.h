#ifndef _DARLINGSERVER_XNU_SYS_LOG_H_
#define _DARLINGSERVER_XNU_SYS_LOG_H_

#include <ciderd/xnu-sys/types.h>

__attribute__((format(printf, 2, 3)))
extern void xnu_sys_log(xnu_sys_log_level_t level, const char* format, ...);

#define xnu_sys_log_debug(format, ...) xnu_sys_log(xnu_sys_log_level_debug, format, ## __VA_ARGS__)
#define xnu_sys_log_info(format, ...) xnu_sys_log(xnu_sys_log_level_info, format, ## __VA_ARGS__)
#define xnu_sys_log_warning(format, ...) xnu_sys_log(xnu_sys_log_level_warning, format, ## __VA_ARGS__)
#define xnu_sys_log_error(format, ...) xnu_sys_log(xnu_sys_log_level_error, format, ## __VA_ARGS__)

#endif // _DARLINGSERVER_XNU_SYS_LOG_H_
