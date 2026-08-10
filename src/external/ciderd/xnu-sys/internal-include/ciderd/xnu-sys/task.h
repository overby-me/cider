#ifndef _DARLINGSERVER_XNU_SYS_TASK_H_
#define _DARLINGSERVER_XNU_SYS_TASK_H_

#include <kern/task.h>

#include <ciderd/rpc.h>
#include <ciderd/xnu-sys/condvar.h>
#include <ciderd/xnu-sys/types.h>

typedef struct xnu_sys_task xnu_sys_task_t;

struct proc_ident {
	xnu_sys_eternal_id_t eid;
};

struct xnu_sys_task {
	void* context;
	uint32_t saved_pid;
	dserver_rpc_architecture_t architecture;
	bool has_sigexc;
	void* p_pthhash;
	uint64_t dyld_info_addr;
	uint64_t dyld_info_length;
	xnu_sys_mutex_t dyld_info_lock;
	xnu_sys_condvar_t dyld_info_condvar;
	struct proc_ident p_ident;
	struct task xnu_task;
};

__attribute__((always_inline))
static xnu_sys_task_t* xnu_sys_task_for_xnu_task(task_t xnu_task) {
	if (!xnu_task) {
		return NULL;
	}
	return (xnu_sys_task_t*)((char*)xnu_task - offsetof(xnu_sys_task_t, xnu_task));
};

void xnu_sys_task_init(void);

#endif // _DARLINGSERVER_XNU_SYS_TASK_H_
