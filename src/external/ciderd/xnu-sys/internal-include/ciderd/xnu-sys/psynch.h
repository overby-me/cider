#ifndef _DARLINGSERVER_XNU_SYS_PSYNCH_H_
#define _DARLINGSERVER_XNU_SYS_PSYNCH_H_

#include <ciderd/xnu-sys/task.h>
#include <ciderd/xnu-sys/thread.h>

void dtape_psynch_init(void);
void dtape_psynch_task_init(dtape_task_t* task);
void dtape_psynch_task_destroy(dtape_task_t* task);
void dtape_psynch_thread_init(dtape_thread_t* thread);
void dtape_psynch_thread_destroy(dtape_thread_t* thread);

#endif // _DARLINGSERVER_XNU_SYS_PSYNCH_H_
