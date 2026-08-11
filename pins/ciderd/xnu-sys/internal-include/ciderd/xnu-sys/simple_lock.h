#ifndef _CIDERD_XNU_SYS_SIMPLE_LOCK_H_
#define _CIDERD_XNU_SYS_SIMPLE_LOCK_H_

#include <stdint.h>
#include "locks.h"

struct usimple_lock {
	lck_spin_t xnu_sys_interlock;
};

typedef struct usimple_lock usimple_lock_data_t;
typedef usimple_lock_data_t* usimple_lock_t;

#endif // _CIDERD_XNU_SYS_SIMPLE_LOCK_H_
