#ifndef _DARLINGSERVER_XNU_SYS_PSYNCH_H_
#define _DARLINGSERVER_XNU_SYS_PSYNCH_H_

#include <ciderd/xnu-sys/task.h>
#include <ciderd/xnu-sys/thread.h>

void xnu_sys_psynch_init(void);
void xnu_sys_psynch_task_init(xnu_sys_task_t* task);
void xnu_sys_psynch_task_destroy(xnu_sys_task_t* task);
void xnu_sys_psynch_thread_init(xnu_sys_thread_t* thread);
void xnu_sys_psynch_thread_destroy(xnu_sys_thread_t* thread);

#endif // _DARLINGSERVER_XNU_SYS_PSYNCH_H_
