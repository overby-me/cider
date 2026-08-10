#ifndef _DARLINGSERVER_XNU_SYS_CONDVAR_H_
#define _DARLINGSERVER_XNU_SYS_CONDVAR_H_

#include "locks.h"

typedef struct xnu_sys_condvar {
	libsimple_lock_t queue_lock;
	xnu_sys_mutex_head_t queue_head;
} xnu_sys_condvar_t;

void xnu_sys_condvar_init(xnu_sys_condvar_t* condvar);
void xnu_sys_condvar_signal(xnu_sys_condvar_t* condvar, size_t count);
void xnu_sys_condvar_wait(xnu_sys_condvar_t* condvar, xnu_sys_mutex_t* mutex);

#endif // _DARLINGSERVER_XNU_SYS_CONDVAR_H_
