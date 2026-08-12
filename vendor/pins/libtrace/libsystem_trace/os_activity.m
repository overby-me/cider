#include <os/activity_private.h>
#include <os/object_private.h>
#include <limits.h>

struct os_activity_s;
struct os_activity_extra_vtable_s {};

// just a stub
struct os_activity_vtable_s {
	_OS_OBJECT_CLASS_HEADER();
	struct os_activity_extra_vtable_s _os_obj_vtable;
};

extern const struct os_activity_vtable_s OS_OBJECT_CLASS_SYMBOL(os_activity) __asm__(OS_OBJC_CLASS_RAW_SYMBOL_NAME(OS_OBJECT_CLASS(os_activity)));

#define OS_ACTIVITY_CLASS (&OS_OBJECT_CLASS_SYMBOL(os_activity))

struct os_activity_s {
	_OS_OBJECT_HEADER(
		const struct os_activity_vtable_s* os_obj_isa,
		os_obj_ref_cnt,
		os_obj_xref_cnt
	);
};

const struct os_activity_s _os_activity_current = {
	.os_obj_isa = &OS_OBJECT_CLASS_SYMBOL(os_activity),
	.os_obj_ref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
	.os_obj_xref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
};

const struct os_activity_s _os_activity_none = {
	.os_obj_isa = &OS_OBJECT_CLASS_SYMBOL(os_activity),
	.os_obj_ref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
	.os_obj_xref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
};

OS_OBJECT_NONLAZY_CLASS
@implementation OS_OBJECT_CLASS(os_activity)
OS_OBJECT_NONLAZY_CLASS_LOAD

@end

os_activity_t _os_activity_create(void* dso, const char* description, os_activity_t activity, os_activity_flag_t flags) {
	return (os_activity_t)_os_object_alloc_realized(OS_ACTIVITY_CLASS, sizeof(struct os_activity_s));
};

void _os_activity_initiate(void *dso, const char *description, os_activity_flag_t flags, os_block_t activity_block OS_NOESCAPE) {
	// TODO: make this actually work like Apple's _os_activity_initiate
	// this is pretty much just a stub for now that allows the block to execute
	activity_block();
};
