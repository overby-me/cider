#ifndef _DARLINGSERVER_XNU_SYS_LOCKS_H_
#define _DARLINGSERVER_XNU_SYS_LOCKS_H_

#include <stdint.h>
#include <sys/queue.h>

#include <libsimple/lock.h>

typedef struct xnu_sys_mutex_link {
	TAILQ_ENTRY(xnu_sys_mutex_link) link;
} xnu_sys_mutex_link_t;

typedef TAILQ_HEAD(xnu_sys_mutex_head, xnu_sys_mutex_link) xnu_sys_mutex_head_t;

typedef struct xnu_sys_mutex {
	volatile uintptr_t xnu_sys_owner;
	libsimple_lock_t xnu_sys_queue_lock;
	xnu_sys_mutex_head_t xnu_sys_queue_head;
} xnu_sys_mutex_t;

typedef struct lck_mtx {
	xnu_sys_mutex_t xnu_sys_mutex;
} lck_mtx_t;

typedef struct lck_spin {
	lck_mtx_t xnu_sys_interlock;
} lck_spin_t;

void xnu_sys_mutex_init(xnu_sys_mutex_t* mutex);
void xnu_sys_mutex_lock(xnu_sys_mutex_t* mutex);
void xnu_sys_mutex_unlock(xnu_sys_mutex_t* mutex);
bool xnu_sys_mutex_try_lock(xnu_sys_mutex_t* mutex);
void xnu_sys_mutex_assert(xnu_sys_mutex_t* mutex, bool should_be_owned);

#endif // _DARLINGSERVER_XNU_SYS_LOCKS_H_
