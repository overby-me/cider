#ifndef _LIBTRACE_OS_ACTIVITY_PRIVATE_H_
#define _LIBTRACE_OS_ACTIVITY_PRIVATE_H_

#include <os/object_private.h>
#include <os/activity.h>

OS_OBJECT_DECL_BASE(os_activity, OS_OBJECT_CLASS(object));
OS_OBJECT_CLASS_IMPLEMENTS_PROTOCOL(os_activity, os_activity);

#endif // _LIBTRACE_OS_ACTIVITY_PRIVATE_H_
