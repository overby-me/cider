#ifndef _CIDERD_XNU_SYS_THREAD_H_
#define _CIDERD_XNU_SYS_THREAD_H_

#include <kern/thread.h>
#include <ciderd/xnu-sys/locks.h>
#include <ciderd/xnu-sys/task.h>
#include <ciderd/xnu-sys/condvar.h>

#include <sys/event.h>

typedef struct xnu_sys_thread xnu_sys_thread_t;

struct xnu_sys_opaque_ksyn_waitq_element {
	// more than enough for the actual structure (should be a max of 56 bytes)
	char opaque[64];
};

typedef struct xnu_sys_thread_user_state {
	LIST_ENTRY(xnu_sys_thread_user_state) link;

#if __x86_64__
	x86_thread_state_t thread_state;
	x86_float_state_t float_state;
#endif
} xnu_sys_thread_user_state_t;

typedef LIST_HEAD(xnu_sys_thread_user_state_head, xnu_sys_thread_user_state) xnu_sys_thread_user_state_head_t;

struct xnu_sys_thread {
	void* context;
	xnu_sys_mutex_link_t mutex_link;
	const char* name;
	uintptr_t pthread_handle;
	uintptr_t dispatch_qaddr;
	struct kevent_ctx_s kevent_ctx;
	xnu_sys_thread_user_state_head_t user_states;
	xnu_sys_thread_user_state_t default_state;
	bool processing_signal;

	bool waiting_suspended;
	xnu_sys_mutex_t suspension_mutex;
	xnu_sys_condvar_t suspension_condvar;

	//
	// uthread stuff for psynch
	//
	struct xnu_sys_opaque_ksyn_waitq_element kwe;
	lck_mtx_t  *uu_mtx;
	uint16_t uu_pri;
	caddr_t uu_wchan;
	int (*uu_continuation)(int);
	const char* uu_wmesg;

	struct thread xnu_thread;
};

__attribute__((always_inline))
static xnu_sys_thread_t* xnu_sys_thread_for_xnu_thread(thread_t xnu_thread) {
	if (!xnu_thread) {
		return NULL;
	}
	return (xnu_sys_thread_t*)((char*)xnu_thread - offsetof(xnu_sys_thread_t, xnu_thread));
};

__attribute__((always_inline))
static xnu_sys_task_t* xnu_sys_task_for_thread(xnu_sys_thread_t* thread) {
	if (!thread) {
		return NULL;
	}
	return xnu_sys_task_for_xnu_task(thread->xnu_thread.task);
};

#endif // _CIDERD_XNU_SYS_THREAD_H_
