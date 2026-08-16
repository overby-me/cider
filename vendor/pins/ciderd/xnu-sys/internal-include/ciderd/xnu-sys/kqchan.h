#ifndef _CIDERD_XNU_SYS_KQCHAN_H_
#define _CIDERD_XNU_SYS_KQCHAN_H_

#include <stdint.h>

#include <os/refcnt.h>
#include <sys/event.h>
#include <sys/eventvar.h>
#include <kern/waitq.h>

#include <ciderd/xnu-sys.h>

typedef struct xnu_sys_task xnu_sys_task_t;
typedef struct xnu_sys_kqchan_mach_port xnu_sys_kqchan_mach_port_t;

struct xnu_sys_kqchan_mach_port {
	os_refcnt_t refcount;
	xnu_sys_task_t* task;
	struct knote knote;
	xnu_sys_kqchan_mach_port_notification_callback_f callback;
	void* context;
	thread_t waiter_thread;
	struct waitq* waitq;
	xnu_sys_semaphore_t* waiter_death_semaphore;
	xnu_sys_semaphore_t* waiter_read_semaphore;
};

#endif // _CIDERD_XNU_SYS_KQCHAN_H_
