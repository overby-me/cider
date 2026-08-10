#ifndef _DARLINGSERVER_XNU_SYS_MEMORY_H_
#define _DARLINGSERVER_XNU_SYS_MEMORY_H_

#include <stdint.h>
#include <mach/vm_types.h>
#include <os/refcnt.h>
#include <sys/tree.h>

#include <ciderd/xnu-sys/locks.h>

struct xnu_sys_task;

typedef struct xnu_sys_map_shared_descriptor {
	os_refcnt_t refcount;
	int memfd;
	uint64_t size;
} xnu_sys_map_shared_descriptor_t;

typedef struct xnu_sys_map_shared_entry {
	RB_ENTRY(xnu_sys_map_shared_entry) link;
	uint64_t address;
	uint64_t size;
	uint64_t page_offset;
	xnu_sys_map_shared_descriptor_t* descriptor;
} xnu_sys_map_shared_entry_t;

typedef RB_HEAD(xnu_sys_map_shared_entry_head, xnu_sys_map_shared_entry) xnu_sys_map_shared_entry_head_t;

struct _vm_map {
	uint32_t xnu_sys_page_shift;
	uint64_t max_offset;
	os_refcnt_t map_refcnt;
	struct xnu_sys_task* xnu_sys_task;
	xnu_sys_map_shared_entry_head_t shared_entries;
	xnu_sys_mutex_t shared_entry_lock;
};

typedef struct _vm_map xnu_sys_map_t;

#define VM_MAP_PAGE_SHIFT(map) ((map) ? (map)->xnu_sys_page_shift : PAGE_SHIFT)

struct vm_map_header {

};

struct vm_map_copy {
	int type;
	uint64_t offset;
	uint64_t size;
	union {
		struct vm_map_header hdr;
		vm_object_t object;
		void* kdata;
	} c_u;
	char xnu_sys_copy_data[];
};

#define cpy_hdr c_u.hdr

#define cpy_object c_u.object
#define cpy_kdata c_u.kdata

#define VM_MAP_COPY_ENTRY_LIST 1
#define VM_MAP_COPY_OBJECT 2
#define VM_MAP_COPY_KERNEL_BUFFER 3

void xnu_sys_memory_init(void);
vm_map_t xnu_sys_vm_map_create(struct xnu_sys_task* task);
void xnu_sys_vm_map_destroy(vm_map_t map);

#endif // _DARLINGSERVER_XNU_SYS_MEMORY_H_
