//! `xnu-sys/src/memory.c`, in Rust (#71, fifteenth file).
//!
//! 1,170 lines of glue after the copied-XNU half moved to `xnu-sys/src/memory_xnu.c`: the
//! zone and kalloc allocators, the `copyin`/`copyout` family, the `vm_map_copy` path, the
//! region queries, and the shared remap that backs `mach_vm_remap` with a memfd.
//!
//! **The red-black tree stays in C.** `RB_GENERATE` expands to a whole tree implementation and
//! `RB_PROTOTYPE_SC` makes every function of it file-local, so there is nothing to call. It is
//! also entirely private to this file, and this file never looked anything up by key: the only
//! reads are an in-order walk and a drain. So it lives in `xnu_sys_rs_shims.c` and is driven here
//! through five operations. See that file for the reasoning.
//!
//! **`struct zone` is xnu-sys's own, not XNU's.** memory.c defines a two-field one at its top,
//! shadowing the XNU struct of the same name, so it is declared here the same way rather than
//! bound. That was worth checking: `--opaque-type=zone.*` in the flags made it look like XNU's.
//!
//! **The `vm_` family is no longer opaque**, measured at +3 structs and 1,780 bytes, so
//! `vm_map_copy` fields are written directly instead of through accessors.
//!
//! Two `goto out` cleanup chains, in `mach_vm_remap_external_shared` and `mach_vm_remap_external`,
//! are labeled blocks, so the single cleanup path at the bottom still runs exactly once however
//! the middle exits. That shape matters more here than anywhere else in the port: those two own
//! a memfd, an mmap and up to two shared entries at once.

use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::ptr;

use crate::bindings::{
    self, boolean_t, xnu_sys_map_shared_descriptor_t, xnu_sys_map_shared_entry_t, xnu_sys_memory_info_t,
    xnu_sys_memory_region_info_t, ipc_port_t, kern_return_t, mach_msg_type_number_t, mach_port_t,
    mach_vm_offset_t, mach_vm_size_t, natural_t, task_t, user_addr_t, vm_map_address_t,
    vm_map_copy_t, vm_map_offset_t, vm_map_size_t, vm_map_t, vm_offset_t, vm_prot_t, vm_size_t,
    vm_tag_t,
};
use crate::xnu::init::xnu_sys_hooks;

// The Linux constants memory.c spells out for itself rather than pulling in a libc header.
const MAP_ANONYMOUS: c_int = 0x20;
const MAP_SHARED: c_int = 0x01;
const MAP_PRIVATE: c_int = 0x02;
const PROT_READ: c_int = 0x1;
const PROT_WRITE: c_int = 0x2;
const PROT_EXEC: c_int = 0x4;
const MAP_FAILED: *mut c_void = usize::MAX as *mut c_void;
const _SC_PAGESIZE: c_int = 30;
const MFD_CLOEXEC: c_uint = 0x1;

extern "C" {
    fn mmap(addr: *mut c_void, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64)
        -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> c_int;
    fn malloc(size: usize) -> *mut c_void;
    fn calloc(n: usize, size: usize) -> *mut c_void;
    fn free(ptr: *mut c_void);
    fn aligned_alloc(align: usize, size: usize) -> *mut c_void;
    fn close(fd: c_int) -> c_int;
    fn ftruncate(fd: c_int, len: i64) -> c_int;
    fn memfd_create(name: *const c_char, flags: c_uint) -> c_int;
    fn sysconf(name: c_int) -> i64;
}

/// xnu-sys's own `struct zone`, two fields, defined at the top of memory.c and shadowing the
/// XNU struct of the same name. Nothing outside this file can see it.
#[repr(C)]
pub struct zone {
    name: *const c_char,
    size: vm_size_t,
}

/// `struct kalloc_heap KHEAP_DEFAULT[1]`, a stub in the C and a stub here: nothing reads it, it
/// only has to exist so the heap argument has an address.
#[no_mangle]
pub static mut KHEAP_DEFAULT: [bindings::kalloc_heap; 1] =
    [unsafe { std::mem::MaybeUninit::zeroed().assume_init() }];

/// The other heap the C declares the same way. ipc_kmsg and ipc_voucher reference it, so a
/// missing one is an undefined symbol at the DAEMON link and nowhere earlier.
#[no_mangle]
pub static mut KHEAP_DATA_BUFFERS: [bindings::kalloc_heap; 1] =
    [unsafe { std::mem::MaybeUninit::zeroed().assume_init() }];

/// `vm_size_t kalloc_max_prerounded = 0`, read by ipc_init.
#[no_mangle]
pub static mut kalloc_max_prerounded: vm_size_t = 0;

/// `kernel_map`, which is a MACRO here: `#define kernel_map (kernel_task->map)`. Reachable now
/// that struct task is not opaque.
#[inline]
unsafe fn kernel_map() -> vm_map_t {
    (*crate::xnu::task::kernel_task).map
}

/// `current_map()`, also a macro: `current_map_fast()` is `current_thread()->map`. struct thread
/// IS still opaque, so that field comes through the shim.
#[inline]
unsafe fn current_map() -> vm_map_t {
    bindings::xnu_sys_rs_thread_map(bindings::current_thread()) as vm_map_t
}

#[inline]
fn page_size() -> u64 {
    unsafe { sysconf(_SC_PAGESIZE) as u64 }
}

fn byte_count_to_page_count_round_up(byte_count: u64) -> u64 {
    (byte_count + (page_size() - 1)) / page_size()
}

fn byte_count_to_page_count_round_down(byte_count: u64) -> u64 {
    byte_count / page_size()
}

/// `VM_MAP_PAGE_SHIFT(map)`: the map's own shift, or the global one when there is no map.
#[inline]
unsafe fn vm_map_page_mask(map: vm_map_t) -> u64 {
    let shift = if map.is_null() {
        page_size().trailing_zeros()
    } else {
        (*map).xnu_sys_page_shift
    };
    (1u64 << shift) - 1
}

#[inline]
fn round_page_mask(addr: u64, mask: u64) -> u64 {
    (addr + mask) & !mask
}

#[inline]
fn trunc_page_mask(addr: u64, mask: u64) -> u64 {
    addr & !mask
}

#[inline]
fn mach_vm_round_page(addr: u64) -> u64 {
    round_page_mask(addr, page_size() - 1)
}

#[inline]
fn mach_vm_trunc_page(addr: u64) -> u64 {
    trunc_page_mask(addr, page_size() - 1)
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_memory_init() {}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_vm_map_create(task: *mut bindings::xnu_sys_task) -> vm_map_t {
    let map = malloc(std::mem::size_of::<bindings::_vm_map>()) as vm_map_t;
    if map.is_null() {
        return map;
    }

    bindings::xnu_sys_rs_os_ref_init(&mut (*map).map_refcnt as *mut _ as *mut _);

    (*map).max_offset = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_MACH_VM_MAX_ADDRESS as u64;
    (*map).xnu_sys_page_shift = page_size().trailing_zeros();

    (*map).xnu_sys_task = task;

    bindings::xnu_sys_rs_shared_entries_init(&mut (*map).shared_entries as *mut _ as *mut _);
    crate::xnu::locks::xnu_sys_mutex_init(&mut (*map).shared_entry_lock);

    map
}

unsafe fn shared_descriptor_create(memfd: c_int, size: u64) -> *mut xnu_sys_map_shared_descriptor_t {
    let desc = malloc(std::mem::size_of::<xnu_sys_map_shared_descriptor_t>())
        as *mut xnu_sys_map_shared_descriptor_t;
    if desc.is_null() {
        return desc;
    }

    bindings::xnu_sys_rs_os_ref_init(&mut (*desc).refcount as *mut _ as *mut _);

    (*desc).memfd = memfd;
    (*desc).size = size;

    desc
}

unsafe fn shared_descriptor_retain(desc: *mut xnu_sys_map_shared_descriptor_t) {
    bindings::xnu_sys_rs_os_ref_retain(&mut (*desc).refcount as *mut _ as *mut _);
}

unsafe fn shared_descriptor_release(desc: *mut xnu_sys_map_shared_descriptor_t) {
    if bindings::xnu_sys_rs_os_ref_release(&mut (*desc).refcount as *mut _ as *mut _) != 0 {
        return;
    }

    close((*desc).memfd);
    free(desc as *mut c_void);
}

unsafe fn shared_entry_create(
    address: u64,
    size: u64,
    page_offset: u64,
    descriptor: *mut xnu_sys_map_shared_descriptor_t,
) -> *mut xnu_sys_map_shared_entry_t {
    let shared_entry =
        malloc(std::mem::size_of::<xnu_sys_map_shared_entry_t>()) as *mut xnu_sys_map_shared_entry_t;
    if shared_entry.is_null() {
        return shared_entry;
    }

    (*shared_entry).address = address;
    (*shared_entry).size = size;
    (*shared_entry).page_offset = page_offset;
    (*shared_entry).descriptor = descriptor;

    shared_descriptor_retain(descriptor);

    shared_entry
}

unsafe fn shared_entry_destroy(shared_entry: *mut xnu_sys_map_shared_entry_t) {
    shared_descriptor_release((*shared_entry).descriptor);
    free(shared_entry as *mut c_void);
}

unsafe fn map_insert_shared_entry_locked(
    map: vm_map_t,
    shared_entry: *mut xnu_sys_map_shared_entry_t,
) {
    bindings::xnu_sys_rs_shared_entries_insert(
        &mut (*map).shared_entries as *mut _ as *mut _,
        shared_entry as *mut _,
    );
}

unsafe fn map_insert_shared_entry(map: vm_map_t, shared_entry: *mut xnu_sys_map_shared_entry_t) {
    crate::xnu::locks::xnu_sys_mutex_lock(&mut (*map).shared_entry_lock);
    map_insert_shared_entry_locked(map, shared_entry);
    crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*map).shared_entry_lock);
}

/// Returns entries in-order.
///
/// If the number of entries returned is equal to the space provided and the address of the last
/// entry returned still falls within the target region, there may be additional entries
/// intersecting the region. You can call this function again with the address just after the
/// last entry to continue searching.
unsafe fn map_find_shared_entries_locked(
    map: vm_map_t,
    address: u64,
    size: u64,
    out_entries: &mut [*mut xnu_sys_map_shared_entry_t],
) -> usize {
    let mut count = 0usize;

    if out_entries.is_empty() {
        return count;
    }

    // RB_FOREACH, as the first/next pair it is underneath.
    let mut entry =
        bindings::xnu_sys_rs_shared_entries_first(&mut (*map).shared_entries as *mut _ as *mut _)
            as *mut xnu_sys_map_shared_entry_t;
    while !entry.is_null() {
        if !((*entry).address + (*entry).size < address || (*entry).address > address + size) {
            out_entries[count] = entry;
            count += 1;

            if count == out_entries.len() {
                break;
            }
        }
        entry = bindings::xnu_sys_rs_shared_entries_next(entry as *mut _)
            as *mut xnu_sys_map_shared_entry_t;
    }

    count
}

// TODO: we should have the process inform us when it unmaps a shared entry that we remapped;
//       right now, we only close the memfd when the process dies (so the memory is potentially
//       in-use needlessly).

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_vm_map_destroy(map: vm_map_t) {
    if bindings::xnu_sys_rs_os_ref_release(&mut (*map).map_refcnt as *mut _ as *mut _) != 0 {
        panic!("VM map still in-use at destruction");
    }

    crate::xnu::locks::xnu_sys_mutex_lock(&mut (*map).shared_entry_lock);
    // RB_FOREACH_SAFE plus RB_REMOVE: take the first repeatedly, which is the same drain.
    loop {
        let entry =
            bindings::xnu_sys_rs_shared_entries_first(&mut (*map).shared_entries as *mut _ as *mut _)
                as *mut xnu_sys_map_shared_entry_t;
        if entry.is_null() {
            break;
        }
        bindings::xnu_sys_rs_shared_entries_remove(
            &mut (*map).shared_entries as *mut _ as *mut _,
            entry as *mut _,
        );
        shared_entry_destroy(entry);
    }
    crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*map).shared_entry_lock);

    free(map as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_reference(map: vm_map_t) {
    bindings::xnu_sys_rs_os_ref_retain(&mut (*map).map_refcnt as *mut _ as *mut _);
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_deallocate(map: vm_map_t) {
    bindings::xnu_sys_rs_os_ref_release_live(&mut (*map).map_refcnt as *mut _ as *mut _);
}

// TODO: zone-based allocations could be optimized to not just use malloc

#[no_mangle]
pub unsafe extern "C" fn zone_create(
    name: *const c_char,
    size: vm_size_t,
    _flags: bindings::zone_create_flags_t,
) -> *mut zone {
    let z = malloc(std::mem::size_of::<zone>()) as *mut zone;
    if z.is_null() {
        return ptr::null_mut();
    }
    (*z).name = name;
    (*z).size = size;
    z
}

#[no_mangle]
pub unsafe extern "C" fn zdestroy(z: *mut zone) {
    free(z as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn zalloc(zone_or_view: bindings::zone_or_view_t) -> *mut c_void {
    malloc((*(zone_or_view as usize as *mut zone)).size as usize)
}

#[no_mangle]
pub unsafe extern "C" fn zalloc_flags(
    zone_or_view: bindings::zone_or_view_t,
    flags: bindings::zalloc_flags_t,
) -> *mut c_void {
    let p = zalloc(zone_or_view);
    if p.is_null() {
        return p;
    }

    if flags & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_Z_ZERO as bindings::zalloc_flags_t != 0 {
        ptr::write_bytes(
            p as *mut u8,
            0,
            (*(zone_or_view as usize as *mut zone)).size as usize,
        );
    }

    p
}

#[no_mangle]
pub unsafe extern "C" fn zfree(_zone_or_view: bindings::zone_or_view_t, elem: *mut c_void) {
    free(elem);
}

#[no_mangle]
pub unsafe extern "C" fn zone_id_require(
    _zone_id: bindings::zone_id_t,
    _elem_size: vm_size_t,
    _addr: *mut c_void,
) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn zone_require(_z: *mut zone, _addr: *mut c_void) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn zinit(
    size: vm_size_t,
    _max: vm_size_t,
    _alloc: vm_size_t,
    name: *const c_char,
) -> *mut zone {
    zone_create(name, size, 0)
}

#[no_mangle]
pub unsafe extern "C" fn kheap_free(
    _kheap: bindings::kalloc_heap_t,
    addr: *mut c_void,
    _size: vm_size_t,
) {
    free(addr);
}

#[no_mangle]
pub unsafe extern "C" fn kheap_free_addr(kheap: bindings::kalloc_heap_t, addr: *mut c_void) {
    kheap_free(kheap, addr, 0);
}

#[no_mangle]
pub unsafe extern "C" fn kfree(addr: *mut c_void, _size: vm_size_t) {
    free(addr);
}

#[no_mangle]
pub unsafe extern "C" fn kalloc_ext(
    _kheap: bindings::kalloc_heap_t,
    req_size: vm_size_t,
    flags: bindings::zalloc_flags_t,
    _site: *mut bindings::vm_allocation_site_t,
) -> bindings::kalloc_result {
    if flags & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_Z_ZERO as bindings::zalloc_flags_t != 0 {
        bindings::kalloc_result {
            addr: calloc(1, req_size as usize),
            size: req_size,
        }
    } else {
        bindings::kalloc_result {
            addr: malloc(req_size as usize),
            size: req_size,
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn zone_heap_name(_z: *mut zone) -> *const c_char {
    crate::xnu_sys_stub_safe!();
    b"\0".as_ptr() as *const c_char
}

#[no_mangle]
pub unsafe extern "C" fn zone_name(z: *mut zone) -> *const c_char {
    (*z).name
}

#[no_mangle]
pub unsafe extern "C" fn zalloc_permanent(size: vm_size_t, align_mask: vm_offset_t) -> *mut c_void {
    let power_of_2 = (std::mem::size_of::<u64>() * 8) as u32 - (align_mask as u64).leading_zeros();
    let memory = aligned_alloc(1usize << power_of_2, size as usize);
    if memory.is_null() {
        return memory;
    }

    // Carried over exactly: the C zeroes sizeof(size), which is 8 bytes, not `size` bytes.
    // Changing it would be a behaviour change, and this is a port.
    ptr::write_bytes(memory as *mut u8, 0, std::mem::size_of::<vm_size_t>());
    memory
}

#[no_mangle]
pub unsafe extern "C" fn vm_page_free_reserve(_pages: c_int) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn kernel_memory_allocate(
    _map: vm_map_t,
    addrp: *mut vm_offset_t,
    size: vm_size_t,
    _mask: vm_offset_t,
    _flags: bindings::kma_flags_t,
    _tag: vm_tag_t,
) -> kern_return_t {
    let p = mmap(
        ptr::null_mut(),
        size as usize,
        PROT_READ | PROT_WRITE,
        MAP_ANONYMOUS | MAP_PRIVATE,
        -1,
        0,
    );
    if p == MAP_FAILED {
        return bindings::KERN_FAILURE as kern_return_t;
    }

    *addrp = p as vm_offset_t;
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn vm_deallocate(
    _map: vm_map_t,
    start: vm_offset_t,
    size: vm_size_t,
) -> kern_return_t {
    // Carried over exactly, including the shape: the C returns the BOOLEAN munmap(...) == 0,
    // not a kern_return_t, so success is 1 and failure 0 here as it is there.
    (munmap(start as *mut c_void, size as usize) == 0) as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn vm_allocate_kernel(
    map: vm_map_t,
    addr: *mut vm_offset_t,
    size: vm_size_t,
    flags: c_int,
    tag: vm_tag_t,
) -> kern_return_t {
    let mut tmp: mach_vm_offset_t = 0;
    let status = mach_vm_allocate_kernel(map, &mut tmp, size as mach_vm_size_t, flags, tag);
    if status == bindings::KERN_SUCCESS as kern_return_t {
        *addr = tmp as vm_offset_t;
    }
    status
}

/// **Not `no_mangle`: this one has an ASM LABEL.** vm_kern.h declares it
/// `__XNU_INTERNAL(kmem_alloc)`, which expands to `__asm("_kmem_alloc$XNU_INTERNAL")`, so every
/// C caller emits a reference to that name and a plain `kmem_alloc` satisfies none of them. The
/// C got this for free by including the header; Rust has to say it.
#[export_name = "_kmem_alloc$XNU_INTERNAL"]
pub unsafe extern "C" fn kmem_alloc(
    map: vm_map_t,
    addrp: *mut vm_offset_t,
    size: vm_size_t,
    tag: vm_tag_t,
) -> kern_return_t {
    kernel_memory_allocate(map, addrp, size, 0, 0, tag)
}

#[no_mangle]
pub unsafe extern "C" fn kmem_free(map: vm_map_t, addr: vm_offset_t, size: vm_size_t) {
    vm_deallocate(map, addr, size);
}

#[no_mangle]
pub unsafe extern "C" fn copyoutmap(
    map: vm_map_t,
    fromdata: *mut c_void,
    toaddr: vm_map_address_t,
    length: vm_size_t,
) -> kern_return_t {
    if map == kernel_map() {
        ptr::copy(fromdata as *const u8, toaddr as *mut u8, length as usize);
        bindings::KERN_SUCCESS as kern_return_t
    } else {
        let ok = (*xnu_sys_hooks).task_write_memory.expect("task_write_memory hook")(
            (*(*map).xnu_sys_task).context,
            toaddr as usize,
            fromdata,
            length as usize,
        );
        if ok {
            bindings::KERN_SUCCESS as kern_return_t
        } else {
            /*
             * WHOSE MAP was written into. The write itself already reports the host pid and ESRCH;
             * what it cannot say is which GUEST process that map belongs to, and that is the whole
             * question -- a receive is supposed to copy out into the RECEIVER, so a dead pid here
             * means the map is not the one it should be.
             */
            eprintln!("CIDER_VMWRITE the map that failed belongs to guest nsid {}",
                      crate::sched::nsid_for_task((*map).xnu_sys_task));
            bindings::KERN_FAILURE as kern_return_t
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn copyinmap(
    map: vm_map_t,
    fromaddr: vm_map_offset_t,
    todata: *mut c_void,
    length: vm_size_t,
) -> kern_return_t {
    if map == kernel_map() {
        ptr::copy(fromaddr as *const u8, todata as *mut u8, length as usize);
        bindings::KERN_SUCCESS as kern_return_t
    } else {
        let ok = (*xnu_sys_hooks).task_read_memory.expect("task_read_memory hook")(
            (*(*map).xnu_sys_task).context,
            fromaddr as usize,
            todata,
            length as usize,
        );
        if ok {
            bindings::KERN_SUCCESS as kern_return_t
        } else {
            bindings::KERN_FAILURE as kern_return_t
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn copyin(
    user_addr: user_addr_t,
    kernel_addr: *mut c_void,
    nbytes: vm_size_t,
) -> c_int {
    if copyinmap(current_map(), user_addr, kernel_addr, nbytes)
        == bindings::KERN_SUCCESS as kern_return_t
    {
        0
    } else {
        1
    }
}

#[no_mangle]
pub unsafe extern "C" fn copyout(
    kernel_addr: *const c_void,
    user_addr: user_addr_t,
    nbytes: vm_size_t,
) -> c_int {
    // it doesn't actually modify kernel_addr
    if copyoutmap(
        current_map(),
        kernel_addr as *mut c_void,
        user_addr,
        nbytes,
    ) == bindings::KERN_SUCCESS as kern_return_t
    {
        0
    } else {
        1
    }
}

#[no_mangle]
pub unsafe extern "C" fn copyinmsg(
    user_addr: user_addr_t,
    kernel_addr: *mut c_char,
    nbytes: bindings::mach_msg_size_t,
) -> c_int {
    copyin(user_addr, kernel_addr as *mut c_void, nbytes as vm_size_t)
}

#[no_mangle]
pub unsafe extern "C" fn copyoutmsg(
    kernel_addr: *const c_char,
    user_addr: user_addr_t,
    nbytes: bindings::mach_msg_size_t,
) -> c_int {
    copyout(kernel_addr as *const c_void, user_addr, nbytes as vm_size_t)
}

#[no_mangle]
pub unsafe extern "C" fn kmem_suballoc(
    parent: vm_map_t,
    _addr: *mut vm_offset_t,
    _size: vm_size_t,
    _pageable: boolean_t,
    _flags: c_int,
    _vmk_flags: bindings::vm_map_kernel_flags_t,
    _tag: vm_tag_t,
    new_map: *mut vm_map_t,
) -> kern_return_t {
    // this is enough to satisfy ipc_init
    crate::xnu_sys_stub!();
    *new_map = parent;
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn vm_kernel_map_is_kernel(map: vm_map_t) -> boolean_t {
    (map == kernel_map() || map == bindings::ipc_kernel_map) as boolean_t
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_copy_discard(copy: vm_map_copy_t) {
    if copy.is_null() {
        return;
    }
    free(copy as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_copyin_common(
    src_map: vm_map_t,
    src_addr: vm_map_address_t,
    len: vm_map_size_t,
    src_destroy: boolean_t,
    _src_volatile: boolean_t,
    copy_result: *mut vm_map_copy_t,
    _use_maxprot: boolean_t,
) -> kern_return_t {
    // XNU only performs a kernel buffer copy when the data is sufficiently small;
    // however, we always perform a kernel buffer copy just to make it easier for ourselves

    // this code has been adapted from vm_map_copyin_kernel_buffer() in osfmk/vm/vm_map.c

    let copy = malloc(std::mem::size_of::<bindings::vm_map_copy>() + len as usize) as vm_map_copy_t;
    if copy.is_null() {
        return bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
    }

    (*copy).type_ = bindings::VM_MAP_COPY_KERNEL_BUFFER as c_int;
    (*copy).size = len;
    (*copy).offset = 0;
    (*copy).c_u.kdata = (*copy).xnu_sys_copy_data.as_mut_ptr() as *mut c_void;

    let kr = copyinmap(src_map, src_addr, (*copy).c_u.kdata, len as vm_size_t);
    if kr != bindings::KERN_SUCCESS as kern_return_t {
        free(copy as *mut c_void);
        return kr;
    }

    if src_destroy != 0 {
        let mask = vm_map_page_mask(src_map);
        vm_map_remove(
            src_map,
            trunc_page_mask(src_addr, mask),
            round_page_mask(src_addr + len, mask),
            0,
        );
    }

    *copy_result = copy;
    bindings::KERN_SUCCESS as kern_return_t
}

unsafe fn vm_map_copyout_kernel_buffer(
    map: vm_map_t,
    addr: *mut vm_map_address_t,
    copy: vm_map_copy_t,
    copy_size: vm_map_size_t,
    overwrite: boolean_t,
    consume_on_success: boolean_t,
) -> kern_return_t {
    let mut kr = bindings::KERN_SUCCESS as kern_return_t;

    if overwrite == 0 {
        // we need to allocate memory for this copy
        if map == kernel_map() {
            *addr = mmap(
                ptr::null_mut(),
                copy_size as usize,
                PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS,
                -1,
                0,
            ) as vm_map_address_t;
            if *addr == MAP_FAILED as vm_map_address_t {
                return bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
            }
        } else {
            *addr = (*xnu_sys_hooks).task_allocate_pages.expect("task_allocate_pages hook")(
                (*(*map).xnu_sys_task).context,
                byte_count_to_page_count_round_up(copy_size) as usize,
                PROT_READ | PROT_WRITE,
                0,
                0,
            ) as vm_map_address_t;
            if *addr == 0 {
                return bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
            }
        }
    }

    if copyoutmap(map, (*copy).c_u.kdata, *addr, copy_size as vm_size_t) != 0 {
        kr = bindings::KERN_INVALID_ADDRESS as kern_return_t;
    }

    if kr != bindings::KERN_SUCCESS as kern_return_t {
        if overwrite == 0 {
            // clean up the space we allocate earlier
            let mask = vm_map_page_mask(map);
            vm_map_remove(
                map,
                trunc_page_mask(*addr, mask),
                round_page_mask(*addr + round_page_mask(copy_size, mask), mask),
                0,
            );
            *addr = 0;
        }
    } else {
        // copy was successful
        if consume_on_success != 0 {
            free(copy as *mut c_void);
        }
    }

    kr
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_copy_overwrite(
    dst_map: vm_map_t,
    dst_addr: vm_map_offset_t,
    copy: vm_map_copy_t,
    _copy_size: vm_map_size_t,
    _interruptible: boolean_t,
) -> kern_return_t {
    if copy.is_null() {
        return bindings::KERN_SUCCESS as kern_return_t;
    }

    let mut dst_addr = dst_addr;
    vm_map_copyout_kernel_buffer(dst_map, &mut dst_addr, copy, (*copy).size, 1, 1)
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_copyout_size(
    dst_map: vm_map_t,
    dst_addr: *mut vm_map_address_t,
    copy: vm_map_copy_t,
    copy_size: vm_map_size_t,
) -> kern_return_t {
    if copy.is_null() {
        *dst_addr = 0;
        return bindings::KERN_SUCCESS as kern_return_t;
    }

    if (*copy).size != copy_size {
        *dst_addr = 0;
        return bindings::KERN_FAILURE as kern_return_t;
    }

    vm_map_copyout_kernel_buffer(dst_map, dst_addr, copy, copy_size, 0, 1)
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_copyout(
    dst_map: vm_map_t,
    dst_addr: *mut vm_map_address_t,
    copy: vm_map_copy_t,
) -> kern_return_t {
    let size = if copy.is_null() { 0 } else { (*copy).size };
    vm_map_copyout_size(dst_map, dst_addr, copy, size)
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_copy_validate_size(
    _dst_map: vm_map_t,
    copy: vm_map_copy_t,
    size: *mut vm_map_size_t,
) -> boolean_t {
    if copy.is_null() {
        return 0;
    }
    (*size == (*copy).size) as boolean_t
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_remove(
    map: vm_map_t,
    start: vm_map_offset_t,
    end: vm_map_offset_t,
    _flags: boolean_t,
) -> kern_return_t {
    if map == kernel_map() {
        if munmap(start as *mut c_void, (end - start) as usize) < 0 {
            return bindings::KERN_FAILURE as kern_return_t;
        }
        bindings::KERN_SUCCESS as kern_return_t
    } else {
        if (*xnu_sys_hooks).task_free_pages.expect("task_free_pages hook")(
            (*(*map).xnu_sys_task).context,
            start as usize,
            byte_count_to_page_count_round_down(end - start) as usize,
        ) < 0
        {
            return bindings::KERN_FAILURE as kern_return_t;
        }
        bindings::KERN_SUCCESS as kern_return_t
    }
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_allocate_kernel(
    map: vm_map_t,
    addr: *mut mach_vm_offset_t,
    size: mach_vm_size_t,
    flags: c_int,
    tag: vm_tag_t,
) -> kern_return_t {
    if map == kernel_map() {
        let mut tmp: vm_offset_t = 0;
        let kr = kernel_memory_allocate(
            map,
            &mut tmp,
            size as vm_size_t,
            vm_map_page_mask(map) as vm_offset_t,
            flags as bindings::kma_flags_t,
            tag,
        );
        if kr == bindings::KERN_SUCCESS as kern_return_t {
            *addr = tmp as mach_vm_offset_t;
        }
        kr
    } else {
        // mach_vm_allocate_kernel allocates with default protection
        let tmp = (*xnu_sys_hooks).task_allocate_pages.expect("task_allocate_pages hook")(
            (*(*map).xnu_sys_task).context,
            byte_count_to_page_count_round_up(size) as usize,
            PROT_READ | PROT_WRITE,
            0,
            0,
        ) as u64;
        if tmp == 0 {
            return bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
        }
        *addr = tmp as mach_vm_offset_t;
        bindings::KERN_SUCCESS as kern_return_t
    }
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_msync(
    map: vm_map_t,
    address: mach_vm_offset_t,
    size: mach_vm_size_t,
    sync_flags: bindings::vm_sync_t,
) -> kern_return_t {
    let mut linux_flags: c_int = 0;

    // TODO: give the Linux bits names/macros

    if sync_flags & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_SYNC_ASYNCHRONOUS as bindings::vm_sync_t != 0 {
        linux_flags |= 1 << 0;
    }

    if sync_flags & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_SYNC_SYNCHRONOUS as bindings::vm_sync_t != 0 {
        linux_flags |= 1 << 2;
    }

    if sync_flags & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_SYNC_INVALIDATE as bindings::vm_sync_t != 0 {
        linux_flags |= 1 << 1;
    }

    if !(*xnu_sys_hooks).task_sync_memory.expect("task_sync_memory hook")(
        (*(*map).xnu_sys_task).context,
        address as usize,
        size as usize,
        linux_flags,
    ) {
        return bindings::KERN_FAILURE as kern_return_t;
    }

    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_protect(
    map: vm_map_t,
    start: mach_vm_offset_t,
    size: mach_vm_size_t,
    _set_maximum: boolean_t,
    new_protection: vm_prot_t,
) -> kern_return_t {
    // we ignore `set_maximum`

    let mut prot: c_int = 0;

    let end_memaddr = mach_vm_round_page(start + size);
    let start_memaddr = mach_vm_trunc_page(start);
    let protect_size = end_memaddr - start_memaddr;

    if new_protection & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_READ as vm_prot_t != 0 {
        prot |= PROT_READ;
    }
    if new_protection & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_WRITE as vm_prot_t != 0 {
        prot |= PROT_WRITE;
    }
    if new_protection & bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_EXECUTE as vm_prot_t != 0 {
        prot |= PROT_EXEC;
    }

    if !(*xnu_sys_hooks).task_change_protection.expect("task_change_protection hook")(
        (*(*map).xnu_sys_task).context,
        start_memaddr as usize,
        byte_count_to_page_count_round_up(protect_size) as usize,
        prot,
    ) {
        return bindings::KERN_FAILURE as kern_return_t;
    }

    bindings::KERN_SUCCESS as kern_return_t
}

/// The protection bits the hook reports, translated to the Mach ones.
///
/// Carried over including the LLDB hack, comment and all: when a region is executable the C does
/// not OR the bit in, it ASSIGNS `VM_PROT_EXECUTE | VM_PROT_READ`, discarding write. Both region
/// calls do it and both are reproduced.
unsafe fn region_protection(region_info: &xnu_sys_memory_region_info_t) -> vm_prot_t {
    let mut protection: vm_prot_t = 0;

    if region_info.protection & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_read != 0 {
        protection |= bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_READ as vm_prot_t;
    }
    if region_info.protection & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_write != 0
    {
        protection |= bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_WRITE as vm_prot_t;
    }
    // This is a special hack for LLDB. For processes started as suspended, with two RX segments.
    // However, in order to avoid failures, they are actually mapped as RWX and are to be changed
    // to RX later by dyld.
    if region_info.protection & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_execute
        != 0
    {
        protection = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_EXECUTE as vm_prot_t
            | bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_READ as vm_prot_t;
    }

    protection
}

/// Look the region up, and if there is nothing at this address, step to the next one.
///
/// Shared by both region calls, which had this identically.
unsafe fn find_region(
    map: vm_map_t,
    address: u64,
    region_info: *mut xnu_sys_memory_region_info_t,
) -> Result<u64, kern_return_t> {
    let ctx = (*(*map).xnu_sys_task).context;
    let mut addr_to_check = address;

    if !(*xnu_sys_hooks).task_get_memory_region_info.expect("hook")(ctx, addr_to_check as usize, region_info) {
        addr_to_check = (*xnu_sys_hooks).task_get_next_region.expect("hook")(ctx, addr_to_check as usize) as u64;
        if addr_to_check == 0 {
            return Err(bindings::KERN_NO_SPACE as kern_return_t);
        }
        if !(*xnu_sys_hooks).task_get_memory_region_info.expect("hook")(ctx, addr_to_check as usize, region_info)
        {
            return Err(bindings::KERN_FAILURE as kern_return_t);
        }
    }

    Ok(addr_to_check)
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_region(
    map: vm_map_t,
    address: *mut mach_vm_offset_t,
    size: *mut mach_vm_size_t,
    flavor: bindings::vm_region_flavor_t,
    info: bindings::vm_region_info_t,
    count: *mut mach_msg_type_number_t,
    object_name: *mut mach_port_t,
) -> kern_return_t {
    let flavor = flavor as u32;
    if flavor != bindings::VM_REGION_BASIC_INFO && flavor != bindings::VM_REGION_BASIC_INFO_64 {
        crate::xnu_sys_stub_unsafe!("Unimplemented flavor")
    }

    let mut region_info: xnu_sys_memory_region_info_t = std::mem::zeroed();
    let mut kr;

    'region_info_out: {
        match find_region(map, *address, &mut region_info) {
            Err(e) => {
                kr = e;
                break 'region_info_out;
            }
            Ok(_) => {}
        }

        *address = region_info.start_address as u64;
        *size = region_info.page_count as u64 * page_size();

        if flavor == bindings::VM_REGION_BASIC_INFO_64 {
            let out = info as bindings::vm_region_basic_info_64_t;

            if *count < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_REGION_BASIC_INFO_COUNT_64 as mach_msg_type_number_t {
                kr = bindings::KERN_INVALID_ARGUMENT as kern_return_t;
                break 'region_info_out;
            }
            *count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_REGION_BASIC_INFO_COUNT_64 as mach_msg_type_number_t;

            (*out).protection = region_protection(&region_info);
            (*out).offset = region_info.map_offset;
            (*out).shared = region_info.shared as boolean_t;
            (*out).behavior = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_BEHAVIOR_DEFAULT as _;
            (*out).user_wired_count = 0;
            (*out).inheritance = 0;
            (*out).max_protection = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_ALL as vm_prot_t;
            (*out).reserved = 0;
        } else {
            let out = info as bindings::vm_region_basic_info_t;

            if *count < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_REGION_BASIC_INFO_COUNT as mach_msg_type_number_t {
                kr = bindings::KERN_INVALID_ARGUMENT as kern_return_t;
                break 'region_info_out;
            }
            *count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_REGION_BASIC_INFO_COUNT as mach_msg_type_number_t;

            (*out).protection = region_protection(&region_info);
            (*out).offset = region_info.map_offset as u32;
            (*out).shared = region_info.shared as boolean_t;
            (*out).behavior = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_BEHAVIOR_DEFAULT as _;
            (*out).user_wired_count = 0;
            (*out).inheritance = 0;
            (*out).max_protection = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_ALL as vm_prot_t;
            (*out).reserved = 0;
        }

        kr = bindings::KERN_SUCCESS as kern_return_t;
    }

    // region_info_out:
    if !object_name.is_null() {
        *object_name = ptr::null_mut();
    }

    kr
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_region_recurse(
    map: vm_map_t,
    address: *mut bindings::mach_vm_address_t,
    size: *mut mach_vm_size_t,
    depth: *mut u32,
    info: bindings::vm_region_recurse_info_t,
    info_cnt: *mut mach_msg_type_number_t,
) -> kern_return_t {
    let mut region_info: xnu_sys_memory_region_info_t = std::mem::zeroed();

    if !depth.is_null() {
        *depth = 0;
    }

    match find_region(map, *address, &mut region_info) {
        Err(e) => return e,
        Ok(_) => {}
    }

    *address = region_info.start_address as u64;
    *size = region_info.page_count as u64 * page_size();

    if *info_cnt == bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_REGION_SUBMAP_SHORT_INFO_COUNT_64 as mach_msg_type_number_t {
        let out = info as bindings::vm_region_submap_info_64_t;

        ptr::write_bytes(
            out as *mut u8,
            0,
            std::mem::size_of::<bindings::vm_region_submap_info_64>(),
        );

        if region_info.protection & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_read
            != 0
        {
            (*out).protection |= bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_READ as vm_prot_t;
        }
        if region_info.protection & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_write
            != 0
        {
            (*out).protection |= bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_WRITE as vm_prot_t;
        }
        if region_info.protection
            & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_execute
            != 0
        {
            (*out).protection |=
                bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_EXECUTE as vm_prot_t;
        }

        (*out).offset = region_info.map_offset;
        (*out).share_mode = if region_info.shared {
            bindings::SM_SHARED as u8
        } else {
            bindings::SM_PRIVATE as u8
        };
        (*out).max_protection = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_ALL as vm_prot_t;
    } else {
        // in the LKM, only VM_REGION_SUBMAP_SHORT_INFO_COUNT_64 was implemented and everything
        // was fine, so it's fine to return KERN_INVALID_ARGUMENT here; log a message just in
        // case, though.
        crate::xnu_sys_stub_safe!("unsupported structure size");
    }

    // Carried over exactly: the C assigns KERN_INVALID_ARGUMENT in the else branch and then
    // unconditionally overwrites it with KERN_SUCCESS on the next line, so the error never
    // reaches the caller. Reproduced rather than fixed, because this is a port.
    bindings::KERN_SUCCESS as kern_return_t
}

unsafe fn mach_vm_remap_external_shared(
    target_map: vm_map_t,
    address: *mut mach_vm_offset_t,
    size: mach_vm_size_t,
    _mask: mach_vm_offset_t,
    flags: c_int,
    src_map: vm_map_t,
    memory_address: mach_vm_offset_t,
    cur_protection: *mut vm_prot_t,
    max_protection: *mut vm_prot_t,
    _inheritance: bindings::vm_inherit_t,
) -> kern_return_t {
    let mut kr = bindings::KERN_SUCCESS as kern_return_t;
    let mut memfd: c_int = -1;
    let mut mapped_addr: *mut c_void = ptr::null_mut();
    let mut region_info: xnu_sys_memory_region_info_t = std::mem::zeroed();
    let mut prot: c_int = 0;
    let mut target_addr: vm_map_address_t = 0;
    let mut vm_prot: vm_prot_t = 0;
    let mut descriptor: *mut xnu_sys_map_shared_descriptor_t = ptr::null_mut();
    let mut src_shared_entry: *mut xnu_sys_map_shared_entry_t = ptr::null_mut();
    let mut target_shared_entry: *mut xnu_sys_map_shared_entry_t = ptr::null_mut();
    let mut src_existing_entries: [*mut xnu_sys_map_shared_entry_t; 8] = [ptr::null_mut(); 8];

    let end_memaddr = mach_vm_round_page(memory_address + size);
    let start_memaddr = mach_vm_trunc_page(memory_address);
    let map_size = end_memaddr - start_memaddr;

    'out: {
        if !(*xnu_sys_hooks).task_get_memory_region_info.expect("hook")(
            (*(*src_map).xnu_sys_task).context,
            memory_address as usize,
            &mut region_info,
        ) {
            kr = bindings::KERN_FAILURE as kern_return_t;
            break 'out;
        }

        if region_info.protection & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_read
            != 0
        {
            prot |= PROT_READ;
            vm_prot |= bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_READ as vm_prot_t;
        }
        if region_info.protection & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_write
            != 0
        {
            prot |= PROT_WRITE;
            vm_prot |= bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_WRITE as vm_prot_t;
        }
        if region_info.protection
            & bindings::xnu_sys_memory_protection_xnu_sys_memory_protection_execute
            != 0
        {
            prot |= PROT_EXEC;
            vm_prot |= bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_EXECUTE as vm_prot_t;
        }

        // `goto src_setup_done` skips the memfd creation when the source region is already
        // shared, so the body between here and there is its own labeled block.
        'src_setup_done: {
            crate::xnu::locks::xnu_sys_mutex_lock(&mut (*src_map).shared_entry_lock);

            let src_existing_entry_count = map_find_shared_entries_locked(
                src_map,
                start_memaddr,
                map_size,
                &mut src_existing_entries,
            );

            if src_existing_entry_count == 1
                && (*src_existing_entries[0]).address == start_memaddr
                && (*src_existing_entries[0]).size >= map_size
            {
                // special case for what LLDB does with dyld info
                shared_descriptor_retain((*src_existing_entries[0]).descriptor);
                descriptor = (*src_existing_entries[0]).descriptor;
                crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*src_map).shared_entry_lock);
                break 'src_setup_done;
            } else if src_existing_entry_count != 0 {
                // TODO: handle this case gracefully
                crate::xnu_sys_stub_unsafe!("Cannot complexly remap existing shared regions yet");
            }

            crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*src_map).shared_entry_lock);

            memfd = memfd_create(b"cider-remapped\0".as_ptr() as *const c_char, MFD_CLOEXEC);
            if memfd < 0 {
                kr = bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
                break 'out;
            }

            if ftruncate(memfd, map_size as i64) < 0 {
                kr = bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
                break 'out;
            }

            mapped_addr = mmap(
                ptr::null_mut(),
                map_size as usize,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                memfd,
                0,
            );
            if mapped_addr == MAP_FAILED {
                mapped_addr = ptr::null_mut();
                kr = bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
                break 'out;
            }

            descriptor = shared_descriptor_create(memfd, map_size);
            if descriptor.is_null() {
                kr = bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
                break 'out;
            }
            memfd = -1; // the descriptor now owns the memfd

            // FIXME: there's a race here between us reading the memory from the source process
            //        into the memfd and when we actually replace the mapping in the source
            //        process with our shared version. in that short window, other threads in the
            //        source process may be modifying the region and any changes they make during
            //        that time will be lost when we replace it with our shared version.
            //
            //        even if we refactor this code to perform the memfd creation and setup within
            //        the source process, there would still be a race since we can't actually
            //        prevent other threads from accessing that memory.

            kr = copyinmap(src_map, start_memaddr, mapped_addr, map_size as vm_size_t);
            if kr != bindings::KERN_SUCCESS as kern_return_t {
                break 'out;
            }

            if (*xnu_sys_hooks).task_map_file.expect("task_map_file hook")(
                (*(*src_map).xnu_sys_task).context,
                (*descriptor).memfd,
                byte_count_to_page_count_round_up(map_size) as usize,
                prot,
                start_memaddr as usize,
                0,
                bindings::xnu_sys_memory_flags_xnu_sys_memory_flag_fixed
                    | bindings::xnu_sys_memory_flags_xnu_sys_memory_flag_overwrite,
            ) as u64 != start_memaddr
            {
                kr = bindings::KERN_FAILURE as kern_return_t;
                break 'out;
            }

            src_shared_entry = shared_entry_create(start_memaddr, map_size, 0, descriptor);
            if src_shared_entry.is_null() {
                kr = bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
                break 'out;
            }

            map_insert_shared_entry(src_map, src_shared_entry);
            src_shared_entry = ptr::null_mut(); // the map now owns the shared entry
        }

        // src_setup_done:
        target_addr = (*xnu_sys_hooks).task_map_file.expect("task_map_file hook")(
            (*(*target_map).xnu_sys_task).context,
            (*descriptor).memfd,
            byte_count_to_page_count_round_up(map_size) as usize,
            prot,
            0,
            0,
            bindings::xnu_sys_memory_flags_xnu_sys_memory_flag_none,
        ) as u64;
        if target_addr == 0 {
            kr = bindings::KERN_FAILURE as kern_return_t;
            break 'out;
        }

        target_shared_entry = shared_entry_create(target_addr, map_size, 0, descriptor);
        if target_shared_entry.is_null() {
            kr = bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
            break 'out;
        }

        map_insert_shared_entry(target_map, target_shared_entry);
        target_shared_entry = ptr::null_mut(); // the map now owns the shared entry

        *max_protection = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_ALL as vm_prot_t;
        *cur_protection = vm_prot;
        *address = target_addr;

        if flags & bindings::VM_FLAGS_RETURN_DATA_ADDR as c_int != 0 {
            *address += memory_address - start_memaddr;
        }
    }

    // out:
    if !mapped_addr.is_null() && munmap(mapped_addr, map_size as usize) < 0 {
        crate::xnu::misc::log(
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_error,
            "failed to unmap memfd",
        );
    }

    if !descriptor.is_null() {
        shared_descriptor_release(descriptor);
    }

    if !src_shared_entry.is_null() {
        shared_entry_destroy(src_shared_entry);
    }

    if !target_shared_entry.is_null() {
        shared_entry_destroy(target_shared_entry);
    }

    if memfd >= 0 {
        close(memfd);
    }

    kr
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_remap_external(
    target_map: vm_map_t,
    address: *mut mach_vm_offset_t,
    size: mach_vm_size_t,
    mask: mach_vm_offset_t,
    flags: c_int,
    src_map: vm_map_t,
    memory_address: mach_vm_offset_t,
    copy: boolean_t,
    cur_protection: *mut vm_prot_t,
    max_protection: *mut vm_prot_t,
    inheritance: bindings::vm_inherit_t,
) -> kern_return_t {
    let mut kr = bindings::KERN_SUCCESS as kern_return_t;
    let mut mem_copy: vm_map_copy_t = ptr::null_mut();
    let mut addr: vm_map_address_t = 0;
    let mut dealloc = false;

    if copy == 0 {
        return mach_vm_remap_external_shared(
            target_map,
            address,
            size,
            mask,
            flags,
            src_map,
            memory_address,
            cur_protection,
            max_protection,
            inheritance,
        );
    }

    'out: {
        // vm_map_copyin is a macro over vm_map_copyin_common.
        kr = vm_map_copyin_common(src_map, memory_address, size, 0, 0, &mut mem_copy, 0);
        if kr != bindings::KERN_SUCCESS as kern_return_t {
            break 'out;
        }

        let mut memflags: bindings::xnu_sys_memory_flags_t = 0;
        if flags & bindings::VM_FLAGS_ANYWHERE as c_int == 0 {
            memflags |= bindings::xnu_sys_memory_flags_xnu_sys_memory_flag_fixed;
        }
        if flags & bindings::VM_FLAGS_OVERWRITE as c_int != 0 {
            memflags |= bindings::xnu_sys_memory_flags_xnu_sys_memory_flag_overwrite;
        }

        // TODO: properly determine when to make memory executable by looking at the protection
        //       of the source region; for now, we just always make it executable for
        //       compatibility with libobjc's trampolines
        let prot = PROT_READ | PROT_WRITE | PROT_EXEC;

        addr = (*xnu_sys_hooks).task_allocate_pages.expect("task_allocate_pages hook")(
            (*(*target_map).xnu_sys_task).context,
            byte_count_to_page_count_round_up(size) as usize,
            prot,
            if flags & bindings::VM_FLAGS_ANYWHERE as c_int != 0 {
                0
            } else {
                *address as usize
            },
            memflags,
        ) as u64;
        if addr == 0 {
            kr = bindings::KERN_RESOURCE_SHORTAGE as kern_return_t;
            break 'out;
        }

        dealloc = true;

        kr = vm_map_copy_overwrite(target_map, addr, mem_copy, (*mem_copy).size, 1);
        if kr != bindings::KERN_SUCCESS as kern_return_t {
            break 'out;
        }

        dealloc = false;

        // a successful copy-out consumes the copy
        mem_copy = ptr::null_mut();

        crate::xnu_sys_stub_safe!("Determine correct protections for copied memory");
        *max_protection = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_ALL as vm_prot_t;
        // LLDB doesn't like it when we tell it that memory is executable;
        // so don't tell it that it's executable, even if it is
        *cur_protection = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_READ as vm_prot_t
            | bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_WRITE as vm_prot_t;
        *address = addr;
    }

    // out:
    if !mem_copy.is_null() {
        vm_map_copy_discard(mem_copy);
    }
    if dealloc {
        (*xnu_sys_hooks).task_free_pages.expect("task_free_pages hook")(
            (*(*target_map).xnu_sys_task).context,
            addr as usize,
            byte_count_to_page_count_round_up(size) as usize,
        );
    }
    kr
}

// Code copied from xnu/osfmk/vm/vm_user.c
#[no_mangle]
pub unsafe extern "C" fn mach_vm_remap_new_external(
    target_map: vm_map_t,
    address: *mut mach_vm_offset_t,
    size: mach_vm_size_t,
    mask: mach_vm_offset_t,
    flags: c_int,
    src_tport: mach_port_t,
    memory_address: mach_vm_offset_t,
    copy: boolean_t,
    cur_protection: *mut vm_prot_t,
    max_protection: *mut vm_prot_t,
    inheritance: bindings::vm_inherit_t,
) -> kern_return_t {
    let prot_all = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_ALL as vm_prot_t;
    let prot_read = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_READ as vm_prot_t;
    let prot_none = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_NONE as vm_prot_t;
    let prot_write = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_WRITE as vm_prot_t;
    let prot_exec = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_VM_PROT_EXECUTE as vm_prot_t;

    let flags = flags | bindings::VM_FLAGS_RETURN_DATA_ADDR as c_int;
    // VM_GET_FLAGS_ALIAS extracts the tag from the flags, and the C never reads the tag
    // afterwards, so the extraction is dropped rather than reproduced as dead code.

    /* filter out any kernel-only flags */
    if flags & !(bindings::VM_FLAGS_USER_REMAP as c_int) != 0 {
        return bindings::KERN_INVALID_ARGUMENT as kern_return_t;
    }

    if target_map.is_null() {
        return bindings::KERN_INVALID_ARGUMENT as kern_return_t;
    }

    if (*cur_protection & !prot_all) != 0
        || (*max_protection & !prot_all) != 0
        || (*cur_protection & *max_protection) != *cur_protection
    {
        return bindings::KERN_INVALID_ARGUMENT as kern_return_t;
    }
    if (*max_protection & (prot_write | prot_exec)) == (prot_write | prot_exec) {
        /*
         * XXX FBDP TODO
         * enforce target's "wx" policies
         */
        return bindings::KERN_PROTECTION_FAILURE as kern_return_t;
    }

    let src_map = if copy != 0 || *max_protection == prot_read || *max_protection == prot_none {
        bindings::convert_port_to_map_read(src_tport)
    } else {
        bindings::convert_port_to_map(src_tport)
    };

    if src_map.is_null() {
        return bindings::KERN_INVALID_ARGUMENT as kern_return_t;
    }

    let mut map_addr: mach_vm_offset_t = *address;

    // I wasn't able to find an reimplementation of vm_map_remap in ciderd,
    // so we will use mach_vm_remap_external for the time being.
    let kr = mach_vm_remap_external(
        target_map,
        &mut map_addr,
        size,
        mask,
        flags,
        src_map,
        memory_address,
        copy,
        cur_protection, /* IN/OUT */
        max_protection, /* IN/OUT */
        inheritance,
    );

    *address = map_addr;
    vm_map_deallocate(src_map);

    if kr == bindings::KERN_SUCCESS as kern_return_t {
        bindings::ipc_port_release_send(src_tport as ipc_port_t); /* consume on success */
    }
    kr
}

//
// The stubs. Every one of these is a signature and a xnu_sys_stub call in the C too.
//

#[no_mangle]
pub unsafe extern "C" fn _mach_make_memory_entry(
    _target_map: vm_map_t,
    _size: *mut bindings::memory_object_size_t,
    _offset: bindings::memory_object_offset_t,
    _permission: vm_prot_t,
    _object_handle: *mut ipc_port_t,
    _parent_entry: ipc_port_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_memory_entry_access_tracking(
    _entry_port: ipc_port_t,
    _access_tracking: *mut c_int,
    _access_tracking_reads: *mut u32,
    _access_tracking_writes: *mut u32,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_memory_entry_ownership(
    _entry_port: ipc_port_t,
    _owner: task_t,
    _ledger_tag: c_int,
    _ledger_flags: c_int,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_memory_entry_purgable_control(
    _entry_port: ipc_port_t,
    _control: bindings::vm_purgable_t,
    _state: *mut c_int,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn pmap_require(_pmap: bindings::pmap_t) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_wire_external(
    _host_priv: bindings::host_priv_t,
    _map: vm_map_t,
    _start: mach_vm_offset_t,
    _size: mach_vm_size_t,
    _access: vm_prot_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_zone_force_gc(_host: bindings::host_t) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_page_query_internal(
    _target_map: vm_map_t,
    _offset: vm_map_offset_t,
    _disposition: *mut c_int,
    _ref_count: *mut c_int,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_purgable_control(
    _map: vm_map_t,
    _address: vm_map_offset_t,
    _control: bindings::vm_purgable_t,
    _state: *mut c_int,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_unwire(
    _map: vm_map_t,
    _start: vm_map_offset_t,
    _end: vm_map_offset_t,
    _user_wire: boolean_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_wire_kernel(
    _map: vm_map_t,
    _start: vm_map_offset_t,
    _end: vm_map_offset_t,
    _caller_prot: vm_prot_t,
    _tag: vm_tag_t,
    _user_wire: boolean_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn vm32__task_wire(_map: vm_map_t, _must_wire: boolean_t) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn vm32__map_exec_lockdown(_map: vm_map_t) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_map_external(
    _target_map: vm_map_t,
    _address: *mut mach_vm_offset_t,
    _initial_size: mach_vm_size_t,
    _mask: mach_vm_offset_t,
    _flags: c_int,
    _port: ipc_port_t,
    _offset: bindings::vm_object_offset_t,
    _copy: boolean_t,
    _cur_protection: vm_prot_t,
    _max_protection: vm_prot_t,
    _inheritance: bindings::vm_inherit_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_behavior_set(
    _map: vm_map_t,
    _start: mach_vm_offset_t,
    _size: mach_vm_size_t,
    _new_behavior: bindings::vm_behavior_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_inherit(
    _map: vm_map_t,
    _start: mach_vm_offset_t,
    _size: mach_vm_size_t,
    _new_inheritance: bindings::vm_inherit_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_page_info(
    _map: vm_map_t,
    _address: bindings::mach_vm_address_t,
    _flavor: bindings::vm_page_info_flavor_t,
    _info: bindings::vm_page_info_t,
    _count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_page_query(
    _map: vm_map_t,
    _offset: mach_vm_offset_t,
    _disposition: *mut c_int,
    _ref_count: *mut c_int,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_page_range_query(
    _map: vm_map_t,
    _address: bindings::mach_vm_address_t,
    _size: mach_vm_size_t,
    _dispositions_addr: bindings::mach_vm_address_t,
    _dispositions_count: *mut mach_vm_size_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_purgable_control(
    _map: vm_map_t,
    _address: mach_vm_offset_t,
    _control: bindings::vm_purgable_t,
    _state: *mut c_int,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_read_list(
    _map: vm_map_t,
    _data_list: bindings::mach_vm_read_entry_t,
    _count: natural_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_memory_info(
    _host: bindings::host_priv_t,
    _namesp: *mut bindings::mach_zone_name_array_t,
    _names_cntp: *mut mach_msg_type_number_t,
    _infop: *mut bindings::mach_zone_info_array_t,
    _info_cntp: *mut mach_msg_type_number_t,
    _memory_infop: *mut bindings::mach_memory_info_array_t,
    _memory_info_cntp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_memory_object_memory_entry(
    _host: bindings::host_t,
    _internal: boolean_t,
    _size: vm_size_t,
    _permission: vm_prot_t,
    _pager: bindings::memory_object_t,
    _entry_handle: *mut ipc_port_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_memory_object_memory_entry_64(
    _host: bindings::host_t,
    _internal: boolean_t,
    _size: bindings::vm_object_offset_t,
    _permission: vm_prot_t,
    _pager: bindings::memory_object_t,
    _entry_handle: *mut ipc_port_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm_allocate_cpm(
    _host_priv: bindings::host_priv_t,
    _map: vm_map_t,
    _addr: *mut bindings::vm_address_t,
    _size: vm_size_t,
    _flags: c_int,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm32_mapped_pages_info(
    _map: vm_map_t,
    _pages: *mut bindings::page_address_array_t,
    _pages_count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm32_region_info(
    _map: vm_map_t,
    _address: bindings::vm32_offset_t,
    _regionp: *mut bindings::vm_info_region_t,
    _objectsp: *mut bindings::vm_info_object_array_t,
    _objects_cntp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm32_region_info_64(
    _map: vm_map_t,
    _address: bindings::vm32_offset_t,
    _regionp: *mut bindings::vm_info_region_64_t,
    _objectsp: *mut bindings::vm_info_object_array_t,
    _objects_cntp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn convert_port_to_memory_object(
    _port: mach_port_t,
) -> bindings::memory_object_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_vm_machine_attribute(
    _map: vm_map_t,
    _addr: bindings::mach_vm_address_t,
    _size: mach_vm_size_t,
    _attribute: bindings::vm_machine_attribute_t,
    _value: *mut bindings::vm_machine_attribute_val_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_zone_get_btlog_records(
    _host: bindings::host_priv_t,
    _name: bindings::mach_zone_name_t,
    _recsp: *mut bindings::zone_btrecord_array_t,
    _recs_cntp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_FAILURE as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn mach_zone_get_zlog_zones(
    _host: bindings::host_priv_t,
    _namesp: *mut bindings::mach_zone_name_array_t,
    _names_cntp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_FAILURE as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn mach_zone_info(
    _host: bindings::host_priv_t,
    _namesp: *mut bindings::mach_zone_name_array_t,
    _names_cntp: *mut mach_msg_type_number_t,
    _infop: *mut bindings::mach_zone_info_array_t,
    _info_cntp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_zone_info_for_largest_zone(
    _host: bindings::host_priv_t,
    _namep: *mut bindings::mach_zone_name_t,
    _infop: *mut bindings::mach_zone_info_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn mach_zone_info_for_zone(
    _host: bindings::host_priv_t,
    _name: bindings::mach_zone_name_t,
    _infop: *mut bindings::mach_zone_info_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_region(
    _map: vm_map_t,
    _address: *mut vm_map_offset_t,
    _size: *mut vm_map_size_t,
    _flavor: bindings::vm_region_flavor_t,
    _info: bindings::vm_region_info_t,
    _count: *mut mach_msg_type_number_t,
    _object_name: *mut mach_port_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn vm_map_region_recurse_64(
    _map: vm_map_t,
    _address: *mut vm_map_offset_t,
    _size: *mut vm_map_size_t,
    _nesting_depth: *mut natural_t,
    _submap_info: bindings::vm_region_submap_info_64_t,
    _count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}
