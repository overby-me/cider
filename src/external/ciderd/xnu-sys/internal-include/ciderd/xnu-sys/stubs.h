#ifndef _CIDERD_XNU_SYS_STUBS_H_
#define _CIDERD_XNU_SYS_STUBS_H_

#include <stdbool.h>

void xnu_sys_stub_log(const char* function_name, int safety, const char* subsection);

// for general functions where it's unknown whether they can be safely stubbed or not
#define xnu_sys_stub(...) (xnu_sys_stub_log(__FUNCTION__, 0, "" __VA_ARGS__))

// for functions that have been confirmed to be okay being stubbed
#define xnu_sys_stub_safe(...) (xnu_sys_stub_log(__FUNCTION__, 1, "" __VA_ARGS__))

// for functions that have been confirmed to require an actual implementation (rather than a simple stub)
#define xnu_sys_stub_unsafe(...) ({ \
		xnu_sys_stub_log(__FUNCTION__, -1, "" __VA_ARGS__); \
		__builtin_unreachable(); \
	}) \

#endif // _CIDERD_XNU_SYS_STUBS_H_
