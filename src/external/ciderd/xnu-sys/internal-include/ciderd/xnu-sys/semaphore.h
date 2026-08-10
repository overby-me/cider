#ifndef _DARLINGSERVER_XNU_SYS_SEMAPHORE_H_
#define _DARLINGSERVER_XNU_SYS_SEMAPHORE_H_

#include <ciderd/xnu-sys.h>

#include <kern/sync_sema.h>

struct xnu_sys_semaphore {
	xnu_sys_task_t* owning_task;
	semaphore_t xnu_semaphore;
};

#endif // _DARLINGSERVER_XNU_SYS_SEMAPHORE_H_
