//! `xnu-sys/src/task.c`, in Rust (#71, fourteenth file).
//!
//! NAMED `dtape_task` because `linux/server/src/task.rs` already exists and is the DAEMON side.
//! Third time that has come up, after kqchan and psynch.
//!
//! task.c was 1,766 lines, of which about 1,000 were verbatim XNU that the file itself marked
//! `<copied from="xnu://7195.141.2/osfmk/kern/task_policy.c">` and two more like it. Those moved
//! to `xnu-sys/src/task_xnu.c` in the commit before this one, unedited, because #71 is a port
//! of the GLUE with XNU staying C. What is left, and what is here, is the 763 lines of Darling
//! glue: task creation and teardown, `task_info`, the `task_for_pid` family, and the four
//! `proc_*` entry points `task_ident.c` needs.
//!
//! **`struct task` IS REOPENED FOR THIS FILE**, reversing a recorded decision. It was refused at
//! +21 structs and 91 KB when reopening would have saved one accessor shim; this file reaches
//! **12 distinct fields** through it, so the alternative was a dozen shims that would never
//! become Rust. What made it safe to reverse is [`crate::xnu::layout`], which asserts at build time
//! that bindgen lays the struct out exactly as C does. It also pays for itself twice over:
//! `task_lock`, `queue_init`, `MACH_PORT_VALID` and `task_has_64Bit_addr` are macros over fields
//! that are now reachable, so they are written here in Rust rather than shimmed.
//!
//! The two that could NOT be reached are `task_set_64Bit_addr` and `task_set_64Bit_data`, macros
//! over `t_flags` whose bit definitions are not otherwise needed, so they are the twentieth and
//! twenty-first shims.

use std::mem::offset_of;
use std::os::raw::{c_int, c_uint, c_void};
use std::ptr;

use crate::bindings::{
    self, audit_token_t, dserver_rpc_architecture_t, dtape_task, integer_t, ipc_port_t,
    mach_msg_header_t, mach_msg_type_number_t, mach_port_name_t, mach_vm_address_t,
    mach_vm_size_t, natural_t, proc_ident, task_flavor_t, task_info_t, task_t, thread_state_t,
    vm_address_t,
};
use crate::xnu::init::dtape_hooks;

/// `kernel_task`, assigned by the first `dtape_task_create` with no parent and nsid 0.
#[no_mangle]
pub static mut kernel_task: task_t = ptr::null_mut();

/// `dtape_task_for_xnu_task`: `always_inline` in C, so there is no symbol to call.
#[inline]
pub(crate) unsafe fn task_for_xnu_task(xnu_task: task_t) -> *mut dtape_task {
    if xnu_task.is_null() {
        return ptr::null_mut();
    }
    (xnu_task as *mut u8).sub(offset_of!(dtape_task, xnu_task)) as *mut dtape_task
}

/// `task_lock` / `task_unlock`, macros over the mutex that is now a reachable field.
#[inline]
pub(crate) unsafe fn task_lock(xtask: task_t) {
    bindings::lck_mtx_lock(&mut (*xtask).lock);
}

#[inline]
pub(crate) unsafe fn task_unlock(xtask: task_t) {
    bindings::lck_mtx_unlock(&mut (*xtask).lock);
}

/// `queue_init(q)`: a circular list head points at itself.
#[inline]
unsafe fn queue_init(q: *mut bindings::queue_head_t) {
    (*q).next = q as *mut _;
    (*q).prev = q as *mut _;
}

/// `MACH_PORT_VALID(name)`: neither the null name nor the dead name.
#[inline]
fn mach_port_valid(name: mach_port_name_t) -> bool {
    const MACH_PORT_NULL: mach_port_name_t = 0;
    const MACH_PORT_DEAD: mach_port_name_t = !0;
    name != MACH_PORT_NULL && name != MACH_PORT_DEAD
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_init() {
    // this will assign to kernel_task
    let arch = if cfg!(target_arch = "x86_64") {
        bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_x86_64
    } else if cfg!(target_arch = "x86") {
        bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_i386
    } else if cfg!(target_arch = "aarch64") {
        bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_arm64
    } else if cfg!(target_arch = "arm") {
        bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_arm32
    } else {
        // The C is a #error, which has no runtime equivalent; a build for an architecture the
        // RPC protocol does not name would be wrong from the first message either way.
        panic!("Unknown architecture")
    };

    if dtape_task_create(ptr::null_mut(), 0, ptr::null_mut(), arch).is_null() {
        panic!("Failed to create kernel task");
    }
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_create(
    parent_task: *mut dtape_task,
    nsid: u32,
    context: *mut c_void,
    architecture: dserver_rpc_architecture_t,
) -> *mut dtape_task {
    if parent_task.is_null() && nsid == 0 && !kernel_task.is_null() {
        let task = task_for_xnu_task(kernel_task);

        // don't acquire an additional reference;
        // the managing Task instance acquires ownership of the kernel task
        //task_reference(kernel_task);

        if !(*task).context.is_null() {
            panic!("The kernel task already has a context");
        } else {
            (*task).context = context;
        }
        return task;
    }

    let task = libc_malloc(std::mem::size_of::<dtape_task>()) as *mut dtape_task;
    if task.is_null() {
        return ptr::null_mut();
    }

    (*task).context = context;
    (*task).saved_pid = nsid;
    (*task).architecture = architecture;
    (*task).has_sigexc = false;
    (*task).dyld_info_addr = 0;
    (*task).dyld_info_length = 0;
    (*task).p_ident.eid = (*dtape_hooks).task_eternal_id.expect("task_eternal_id hook")(context);
    crate::xnu::locks::dtape_mutex_init(&mut (*task).dyld_info_lock);
    crate::xnu::condvar::dtape_condvar_init(&mut (*task).dyld_info_condvar);
    ptr::write_bytes(&mut (*task).xnu_task as *mut _ as *mut u8, 0, std::mem::size_of::<bindings::task>());

    // this next section uses code adapted from XNU's task_create_internal() in osfmk/kern/task.c

    bindings::dtape_rs_os_ref_init(&mut (*task).xnu_task.ref_count as *mut _ as *mut _);

    bindings::lck_mtx_init(&mut (*task).xnu_task.lock, ptr::null_mut(), ptr::null_mut());
    queue_init(&mut (*task).xnu_task.threads);

    (*task).xnu_task.active = true;

    (*task).xnu_task.map = bindings::dtape_vm_map_create(task);

    queue_init(&mut (*task).xnu_task.semaphore_list);

    // Task #47: a task created with NO parent takes ipc_task_init's parent==TASK_NULL branch,
    // which sets itk_bootstrap = IP_NULL. It can then never inherit launchd's bootstrap port,
    // and its first service lookup goes to MACH_PORT_NULL.
    crate::xnu::misc::log(
        bindings::dtape_log_level_t::dtape_log_level_debug,
        &format!(
            "dtape_task_create: nsid={} parent={:p} parent_bootstrap={:p}",
            nsid,
            parent_task,
            if parent_task.is_null() {
                ptr::null_mut()
            } else {
                (*parent_task).xnu_task.itk_bootstrap
            }
        ),
    );
    bindings::ipc_task_init(
        &mut (*task).xnu_task,
        if parent_task.is_null() {
            ptr::null_mut()
        } else {
            &mut (*parent_task).xnu_task
        },
    );

    if !parent_task.is_null() {
        bindings::task_importance_init_from_parent(
            &mut (*task).xnu_task,
            &mut (*parent_task).xnu_task,
        );
    }

    // this is a hack to force all tasks to have an IPC importance structure associated with them
    // since i'm not sure where it's normally acquired in XNU.
    // (this is necessary ipc_importance_send() needs the task to have a valid `task_imp_base`)
    if (*task).xnu_task.task_imp_base.is_null() {
        let imp = bindings::ipc_importance_for_task(&mut (*task).xnu_task, 0);
        // the new IPC importance structure has 2 references:
        //   * one that the task gets,
        //   * and another one that we (the caller) get
        // we don't actually want a reference; we only want the task to have one.
        bindings::ipc_importance_task_release(imp);
    }

    if !parent_task.is_null() {
        (*task).xnu_task.sec_token = (*parent_task).xnu_task.sec_token;
        (*task).xnu_task.audit_token = (*parent_task).xnu_task.audit_token;
    } else {
        (*task).xnu_task.sec_token = bindings::KERNEL_SECURITY_TOKEN;
        (*task).xnu_task.audit_token = bindings::KERNEL_AUDIT_TOKEN;
    }

    (*task).xnu_task.audit_token.val[5] = (*task).saved_pid;

    if architecture == bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_x86_64
        || architecture == bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_arm64
    {
        bindings::dtape_rs_task_set_64bit_addr(&mut (*task).xnu_task);
        bindings::dtape_rs_task_set_64bit_data(&mut (*task).xnu_task);
    }

    bindings::ipc_task_enable(&mut (*task).xnu_task);

    crate::xnu::psynch::dtape_psynch_task_init(task);

    if parent_task.is_null() && nsid == 0 {
        if !kernel_task.is_null() {
            panic!("Another kernel task has been created");
        }

        kernel_task = &mut (*task).xnu_task;
    }

    task
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_destroy(task: *mut dtape_task) {
    crate::xnu::misc::log(
        bindings::dtape_log_level_t::dtape_log_level_debug,
        &format!("{}: task being destroyed", (*task).saved_pid),
    );

    crate::xnu::psynch::dtape_psynch_task_destroy(task);

    // this next section uses code adapted from XNU's task_deallocate() in osfmk/kern/task.c

    task_lock(&mut (*task).xnu_task);
    (*task).xnu_task.active = false;
    bindings::ipc_task_disable(&mut (*task).xnu_task);
    task_unlock(&mut (*task).xnu_task);

    bindings::semaphore_destroy_all(&mut (*task).xnu_task);

    bindings::ipc_space_terminate((*task).xnu_task.itk_space);

    bindings::ipc_task_terminate(&mut (*task).xnu_task);

    bindings::dtape_vm_map_destroy((*task).xnu_task.map);

    bindings::dtape_rs_is_release((*task).xnu_task.itk_space);

    bindings::lck_mtx_destroy(&mut (*task).xnu_task.lock, ptr::null_mut());

    (*dtape_hooks).task_context_dispose.expect("task_context_dispose hook")((*task).context);

    libc_free(task as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_uidgid(
    task: *mut dtape_task,
    new_uid: c_int,
    new_gid: c_int,
    old_uid: *mut c_int,
    old_gid: *mut c_int,
) {
    task_lock(&mut (*task).xnu_task);
    if !old_uid.is_null() {
        *old_uid = (*task).xnu_task.audit_token.val[1] as c_int;
    }
    if !old_gid.is_null() {
        *old_gid = (*task).xnu_task.audit_token.val[2] as c_int;
    }
    if new_uid >= 0 {
        (*task).xnu_task.audit_token.val[1] = new_uid as u32;
    }
    if new_gid >= 0 {
        (*task).xnu_task.audit_token.val[2] = new_gid as u32;
    }
    task_unlock(&mut (*task).xnu_task);
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_retain(task: *mut dtape_task) {
    bindings::dtape_rs_task_reference(&mut (*task).xnu_task);
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_release(task: *mut dtape_task) {
    task_deallocate(&mut (*task).xnu_task);
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_dying(_task: *mut dtape_task) {
    // nothing for now
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_set_dyld_info(
    task: *mut dtape_task,
    address: u64,
    length: u64,
) {
    crate::xnu::locks::dtape_mutex_lock(&mut (*task).dyld_info_lock);
    crate::xnu::misc::log(
        bindings::dtape_log_level_t::dtape_log_level_debug,
        &format!("setting dyld info to {length} bytes at {address:x}"),
    );
    (*task).dyld_info_addr = address;
    (*task).dyld_info_length = length;
    crate::xnu::locks::dtape_mutex_unlock(&mut (*task).dyld_info_lock);
    crate::xnu::condvar::dtape_condvar_signal(&mut (*task).dyld_info_condvar, usize::MAX);
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_set_sigexc_enabled(task: *mut dtape_task, enabled: bool) {
    // FIXME: we should probably have a lock for this
    (*task).has_sigexc = enabled;
}

#[no_mangle]
pub unsafe extern "C" fn dtape_task_try_resume(task: *mut dtape_task) -> bool {
    if (*task).xnu_task.user_stop_count != 0 {
        crate::xnu::misc::log(
            bindings::dtape_log_level_t::dtape_log_level_debug,
            &format!(
                "sigexc target task is stopped ({}), resuming",
                (*task).xnu_task.user_stop_count
            ),
        );
        return bindings::task_resume(&mut (*task).xnu_task)
            == bindings::KERN_SUCCESS as bindings::kern_return_t;
    }
    false
}

#[no_mangle]
pub unsafe extern "C" fn task_deallocate(xtask: task_t) {
    let task = task_for_xnu_task(xtask);
    let count = bindings::dtape_rs_os_ref_release(&mut (*xtask).ref_count as *mut _ as *mut _);
    if count > 0 {
        // IPC importance info might be holding the last reference on the task
        if count == 1 && !(*task).xnu_task.task_imp_base.is_null() {
            bindings::ipc_importance_disconnect_task(&mut (*task).xnu_task);
        }
        return;
    }
    dtape_task_destroy(task);
}

#[no_mangle]
pub unsafe extern "C" fn pid_from_task(xtask: task_t) -> c_int {
    let task = task_for_xnu_task(xtask);
    (*task).saved_pid as c_int
}

#[no_mangle]
pub unsafe extern "C" fn proc_get_effective_task_policy(_task: task_t, flavor: c_int) -> c_int {
    crate::dtape_stub!();
    if flavor == bindings::TASK_POLICY_ROLE as c_int {
        bindings::dtape_rs_host_consts_DTAPE_RS_TASK_UNSPECIFIED as c_int
    } else {
        panic!("Unimplemented proc_get_effective_task_policy flavor: {flavor}")
    }
}

#[no_mangle]
pub unsafe extern "C" fn task_pid(task: task_t) -> c_int {
    pid_from_task(task)
}

#[no_mangle]
pub unsafe extern "C" fn task_policy_update_complete_unlocked(
    _task: task_t,
    _pend_token: bindings::task_pend_token_t,
) {
    crate::dtape_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn task_port_notify(_msg: *mut mach_msg_header_t) {
    crate::dtape_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn task_port_with_flavor_notify(_msg: *mut mach_msg_header_t) {
    crate::dtape_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn task_suspension_notify(
    _request_header: *mut mach_msg_header_t,
) -> bindings::boolean_t {
    crate::dtape_stub!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn task_update_boost_locked(
    _task: task_t,
    _boost_active: bindings::boolean_t,
    _pend_token: bindings::task_pend_token_t,
) {
    crate::dtape_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn task_watchport_elem_deallocate(
    _watchport_elem: *mut bindings::task_watchport_elem,
) {
    crate::dtape_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn task_create_suid_cred(
    _task: task_t,
    _path: bindings::suid_cred_path_t,
    _uid: bindings::suid_cred_uid_t,
    _sc_p: *mut bindings::suid_cred_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_dyld_process_info_notify_deregister(
    _task: task_t,
    _rcv_name: mach_port_name_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_dyld_process_info_notify_register(
    _task: task_t,
    _sright: ipc_port_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_generate_corpse(
    _task: task_t,
    _corpse_task_port: *mut ipc_port_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_get_assignment(
    _task: task_t,
    _pset: *mut bindings::processor_set_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_get_state(
    _task: task_t,
    _flavor: c_int,
    _state: thread_state_t,
    _state_count: *mut mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

/// `TASK_LEGACY_DYLD_INFO_COUNT`, defined inside `task_info` in the C: the count that stops
/// short of `all_image_info_format`, for callers built before that field existed.
const TASK_LEGACY_DYLD_INFO_COUNT: mach_msg_type_number_t =
    (offset_of!(bindings::task_dyld_info, all_image_info_format) / std::mem::size_of::<natural_t>())
        as mach_msg_type_number_t;

#[no_mangle]
pub unsafe extern "C" fn task_info(
    xtask: task_t,
    flavor: task_flavor_t,
    task_info_out: task_info_t,
    task_info_count: *mut mach_msg_type_number_t,
) -> bindings::kern_return_t {
    use bindings::{
        dtape_rs_host_consts_DTAPE_RS_MACH_TASK_BASIC_INFO_COUNT as MACH_TASK_BASIC_INFO_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_AUDIT_TOKEN_COUNT as TASK_AUDIT_TOKEN_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_BASIC_INFO_32_COUNT as TASK_BASIC_INFO_32_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_BASIC_INFO_64_COUNT as TASK_BASIC_INFO_64_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_DYLD_INFO_COUNT as TASK_DYLD_INFO_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_FLAGS_INFO_COUNT as TASK_FLAGS_INFO_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_THREAD_TIMES_INFO_COUNT as TASK_THREAD_TIMES_INFO_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_VM_INFO_REV0_COUNT as TASK_VM_INFO_REV0_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_VM_INFO_REV1_COUNT as TASK_VM_INFO_REV1_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_VM_INFO_REV2_COUNT as TASK_VM_INFO_REV2_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_VM_INFO_REV3_COUNT as TASK_VM_INFO_REV3_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_VM_INFO_REV4_COUNT as TASK_VM_INFO_REV4_COUNT,
        dtape_rs_host_consts_DTAPE_RS_TASK_VM_INFO_REV5_COUNT as TASK_VM_INFO_REV5_COUNT,
    };

    let task = task_for_xnu_task(xtask);
    let flavor = flavor as u32;
    let invalid = bindings::KERN_INVALID_ARGUMENT as bindings::kern_return_t;
    let success = bindings::KERN_SUCCESS as bindings::kern_return_t;

    if flavor == bindings::TASK_BASIC_INFO_32
        || flavor == bindings::TASK_BASIC_INFO_64
        || flavor == bindings::MACH_TASK_BASIC_INFO
    {
        let mut mem_info: bindings::dtape_memory_info_t = std::mem::zeroed();
        (*dtape_hooks).task_get_memory_info.expect("task_get_memory_info hook")(
            (*task).context,
            &mut mem_info,
        );

        crate::xnu::misc::log(
            bindings::dtape_log_level_t::dtape_log_level_debug,
            "task_info: TODO: fetch utimeus and stimeus somehow",
        );
        let utimeus: u64 = 0;
        let stimeus: u64 = 0;
        let usec = bindings::USEC_PER_SEC as u64;

        if flavor == bindings::TASK_BASIC_INFO_32 {
            let info = task_info_out as *mut bindings::task_basic_info_32;
            if *task_info_count < TASK_BASIC_INFO_32_COUNT as mach_msg_type_number_t {
                return invalid;
            }
            *task_info_count = TASK_BASIC_INFO_32_COUNT as mach_msg_type_number_t;
            (*info).suspend_count = (*task).xnu_task.user_stop_count as integer_t;
            (*info).virtual_size = mem_info.virtual_size as _;
            (*info).resident_size = mem_info.resident_size as _;
            (*info).user_time.seconds = (utimeus / usec) as _;
            (*info).user_time.microseconds = (utimeus % usec) as _;
            (*info).system_time.seconds = (stimeus / usec) as _;
            (*info).system_time.microseconds = (stimeus % usec) as _;
            (*info).policy = 0;
        } else if flavor == bindings::TASK_BASIC_INFO_64 {
            let info = task_info_out as *mut bindings::task_basic_info_64;
            if *task_info_count < TASK_BASIC_INFO_64_COUNT as mach_msg_type_number_t {
                return invalid;
            }
            *task_info_count = TASK_BASIC_INFO_64_COUNT as mach_msg_type_number_t;
            (*info).suspend_count = (*task).xnu_task.user_stop_count as integer_t;
            (*info).virtual_size = mem_info.virtual_size as _;
            (*info).resident_size = mem_info.resident_size as _;
            (*info).user_time.seconds = (utimeus / usec) as _;
            (*info).user_time.microseconds = (utimeus % usec) as _;
            (*info).system_time.seconds = (stimeus / usec) as _;
            (*info).system_time.microseconds = (stimeus % usec) as _;
            (*info).policy = 0;
        } else {
            let info = task_info_out as *mut bindings::mach_task_basic_info;
            if *task_info_count < MACH_TASK_BASIC_INFO_COUNT as mach_msg_type_number_t {
                return invalid;
            }
            *task_info_count = MACH_TASK_BASIC_INFO_COUNT as mach_msg_type_number_t;
            (*info).suspend_count = (*task).xnu_task.user_stop_count as integer_t;
            (*info).virtual_size = mem_info.virtual_size as _;
            (*info).resident_size = mem_info.resident_size as _;
            (*info).user_time.seconds = (utimeus / usec) as _;
            (*info).user_time.microseconds = (utimeus % usec) as _;
            (*info).system_time.seconds = (stimeus / usec) as _;
            (*info).system_time.microseconds = (stimeus % usec) as _;
            (*info).policy = 0;
        }

        return success;
    }

    if flavor == bindings::TASK_THREAD_TIMES_INFO {
        let info = task_info_out as *mut bindings::task_thread_times_info;
        if *task_info_count < TASK_THREAD_TIMES_INFO_COUNT as mach_msg_type_number_t {
            return invalid;
        }
        *task_info_count = TASK_THREAD_TIMES_INFO_COUNT as mach_msg_type_number_t;

        crate::xnu::misc::log(
            bindings::dtape_log_level_t::dtape_log_level_debug,
            "task_info: TODO: fetch utimeus and stimeus somehow",
        );
        let utimeus: u64 = 0;
        let stimeus: u64 = 0;
        let usec = bindings::USEC_PER_SEC as u64;

        (*info).user_time.seconds = (utimeus / usec) as _;
        (*info).user_time.microseconds = (utimeus % usec) as _;
        (*info).system_time.seconds = (stimeus / usec) as _;
        (*info).system_time.microseconds = (stimeus % usec) as _;

        return success;
    }

    if flavor == bindings::TASK_DYLD_INFO {
        let info = task_info_out as *mut bindings::task_dyld_info;

        // We added the format field to TASK_DYLD_INFO output.  For
        // temporary backward compatibility, accept the fact that
        // clients may ask for the old version - distinquished by the
        // size of the expected result structure.
        if *task_info_count < TASK_LEGACY_DYLD_INFO_COUNT {
            return invalid;
        }

        // DARLING:
        // This call may block, waiting for Darling to provide this information
        // shortly after startup.
        crate::xnu::misc::log(
            bindings::dtape_log_level_t::dtape_log_level_debug,
            &format!("going to read dyld info for task {:p} ({})", task, (*task).saved_pid),
        );

        crate::xnu::locks::dtape_mutex_lock(&mut (*task).dyld_info_lock);

        while (*task).dyld_info_addr == 0 && (*task).dyld_info_length == 0 {
            crate::xnu::misc::log(
                bindings::dtape_log_level_t::dtape_log_level_debug,
                &format!("going to wait for dyld info for task {:p} ({})", task, (*task).saved_pid),
            );
            crate::xnu::condvar::dtape_condvar_wait(
                &mut (*task).dyld_info_condvar,
                &mut (*task).dyld_info_lock,
            );
            crate::xnu::misc::log(
                bindings::dtape_log_level_t::dtape_log_level_debug,
                &format!("awoken from dyld info wait for task {:p} ({})", task, (*task).saved_pid),
            );
        }

        (*info).all_image_info_addr = (*task).dyld_info_addr as mach_vm_address_t;
        (*info).all_image_info_size = (*task).dyld_info_length as mach_vm_size_t;

        crate::xnu::locks::dtape_mutex_unlock(&mut (*task).dyld_info_lock);

        // struct task_dyld_info is PACKED, so a reference to a field of it is unaligned and
        // Rust refuses to form one. Reading the two values into locals is what the C log does
        // anyway, and it is the read that matters, not the reference.
        let logged_addr = ptr::addr_of!((*info).all_image_info_addr).read_unaligned();
        let logged_size = ptr::addr_of!((*info).all_image_info_size).read_unaligned();
        crate::xnu::misc::log(
            bindings::dtape_log_level_t::dtape_log_level_debug,
            &format!(
                "got dyld info for task {:p} ({}): {} bytes at {:x}",
                task,
                (*task).saved_pid,
                logged_addr,
                logged_size
            ),
        );

        // only set format on output for those expecting it
        if *task_info_count >= TASK_DYLD_INFO_COUNT as mach_msg_type_number_t {
            (*info).all_image_info_format = if task_has_64bit_addr(xtask) {
                bindings::TASK_DYLD_ALL_IMAGE_INFO_64 as integer_t
            } else {
                bindings::TASK_DYLD_ALL_IMAGE_INFO_32 as integer_t
            };
            *task_info_count = TASK_DYLD_INFO_COUNT as mach_msg_type_number_t;
        } else {
            *task_info_count = TASK_LEGACY_DYLD_INFO_COUNT;
        }

        return success;
    }

    if flavor == bindings::TASK_AUDIT_TOKEN {
        if *task_info_count < TASK_AUDIT_TOKEN_COUNT as mach_msg_type_number_t {
            return invalid;
        }

        let audit_token_p = task_info_out as *mut audit_token_t;
        *audit_token_p = (*task).xnu_task.audit_token;
        *task_info_count = TASK_AUDIT_TOKEN_COUNT as mach_msg_type_number_t;

        return success;
    }

    if flavor == bindings::TASK_VM_INFO {
        let info = task_info_out as *mut bindings::task_vm_info;
        let orig_info_count = *task_info_count;

        if orig_info_count < TASK_VM_INFO_REV0_COUNT as mach_msg_type_number_t {
            return invalid;
        }

        ptr::write_bytes(
            info as *mut u8,
            0,
            orig_info_count as usize * std::mem::size_of::<natural_t>(),
        );

        let mut meminfo: bindings::dtape_memory_info_t = std::mem::zeroed();
        (*dtape_hooks).task_get_memory_info.expect("task_get_memory_info hook")(
            (*task).context,
            &mut meminfo,
        );

        (*info).page_size = meminfo.page_size as _;
        (*info).resident_size = meminfo.resident_size as _;
        (*info).resident_size_peak = meminfo.resident_size as _;
        (*info).virtual_size = meminfo.virtual_size as _;

        // TODO: fill in other stuff

        // The C nests these; a descending scan is the same decision and does not indent five
        // deep. Highest revision the caller can hold, wins.
        *task_info_count = TASK_VM_INFO_REV0_COUNT as mach_msg_type_number_t;
        for count in [
            TASK_VM_INFO_REV5_COUNT,
            TASK_VM_INFO_REV4_COUNT,
            TASK_VM_INFO_REV3_COUNT,
            TASK_VM_INFO_REV2_COUNT,
            TASK_VM_INFO_REV1_COUNT,
        ] {
            if orig_info_count >= count as mach_msg_type_number_t {
                *task_info_count = count as mach_msg_type_number_t;
                break;
            }
        }

        return success;
    }

    if flavor == bindings::TASK_FLAGS_INFO {
        let info = task_info_out as *mut bindings::task_flags_info;
        let orig_info_count = *task_info_count;

        if orig_info_count < TASK_FLAGS_INFO_COUNT as mach_msg_type_number_t {
            return invalid;
        }

        (*info).flags = 0;

        if (*task).architecture
            == bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_x86_64
            || (*task).architecture
                == bindings::dserver_rpc_architecture_t::dserver_rpc_architecture_arm64
        {
            (*info).flags = bindings::TF_LP64 | bindings::TF_64B_DATA;
        }

        return success;
    }

    crate::dtape_stub_unsafe!("unimplemented flavor")
}

/// `task_has_64Bit_addr(task)`, a macro over `t_flags` that is reachable now that the struct is
/// not opaque.
#[inline]
unsafe fn task_has_64bit_addr(xtask: task_t) -> bool {
    (*xtask).t_flags & bindings::TF_64B_ADDR != 0
}

#[no_mangle]
pub unsafe extern "C" fn task_inspect(
    _task_insp: bindings::task_inspect_t,
    _flavor: bindings::task_inspect_flavor_t,
    _info_out: bindings::task_inspect_info_t,
    _size_in_out: *mut mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_safe!();
    bindings::KERN_FAILURE as bindings::kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn task_is_driver(_task: task_t) -> bool {
    crate::dtape_stub_safe!();
    false
}

#[no_mangle]
pub unsafe extern "C" fn task_map_corpse_info(
    _task: task_t,
    _corpse_task: task_t,
    _kcd_addr_begin: *mut vm_address_t,
    _kcd_size: *mut u32,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_map_corpse_info_64(
    _task: task_t,
    _corpse_task: task_t,
    _kcd_addr_begin: *mut mach_vm_address_t,
    _kcd_size: *mut mach_vm_size_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_name_deallocate(_task_name: bindings::task_name_t) {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_policy_get(
    _task: task_t,
    _flavor: bindings::task_policy_flavor_t,
    _policy_info: bindings::task_policy_t,
    _count: *mut mach_msg_type_number_t,
    _get_default: *mut bindings::boolean_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_policy_get_deallocate(_t: bindings::task_policy_get_t) {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_policy_set(
    _task: task_t,
    _flavor: bindings::task_policy_flavor_t,
    _policy_info: bindings::task_policy_t,
    _count: mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_safe!();
    bindings::KERN_SUCCESS as bindings::kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn task_policy_set_deallocate(task_policy_set: bindings::task_policy_set_t) {
    task_deallocate(task_policy_set as task_t)
}

#[no_mangle]
pub unsafe extern "C" fn task_purgable_info(
    _task: task_t,
    _stats: *mut bindings::task_purgable_info_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_register_dyld_image_infos(
    _task: task_t,
    _infos_copy: bindings::dyld_kernel_image_info_array_t,
    _infos_len: mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_register_dyld_shared_cache_image_info(
    _task: task_t,
    _cache_img: bindings::dyld_kernel_image_info_t,
    _no_cache: bindings::boolean_t,
    _private_cache: bindings::boolean_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_restartable_ranges_register(
    _task: task_t,
    _ranges: *mut bindings::task_restartable_range_t,
    _count: mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_restartable_ranges_synchronize(
    _task: task_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_set_exc_guard_behavior(
    _task: task_t,
    _behavior: bindings::task_exc_guard_behavior_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_set_info(
    _task: task_t,
    _flavor: task_flavor_t,
    _task_info_in: task_info_t,
    _task_info_count: mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_set_phys_footprint_limit(
    _task: task_t,
    _new_limit_mb: c_int,
    _old_limit_mb: *mut c_int,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_set_state(
    _task: task_t,
    _flavor: c_int,
    _state: thread_state_t,
    _state_count: mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_suspension_token_deallocate(
    _token: bindings::task_suspension_token_t,
) {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_terminate(_task: task_t) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn task_unregister_dyld_image_infos(
    _task: task_t,
    _infos_copy: bindings::dyld_kernel_image_info_array_t,
    _infos_len: mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::dtape_stub_unsafe!()
}

/// The shared body of `task_for_pid` and `task_name_for_pid`.
///
/// The C is a `goto out` cleanup chain; the same shape here is a labeled block, so the single
/// cleanup path at the bottom still runs exactly once however the middle exits.
unsafe fn task_for_pid_internal(
    target_tport: mach_port_name_t,
    pid: c_int,
    t: usize,
    task_name: bool,
) -> bindings::kern_return_t {
    let mut kr = bindings::KERN_FAILURE as bindings::kern_return_t;
    let mut receiving_task: task_t = ptr::null_mut();
    let mut looked_up_task: *mut dtape_task = ptr::null_mut();
    let mut right: ipc_port_t = ptr::null_mut();
    let mut out_name: mach_port_name_t = 0;

    'out: {
        receiving_task = bindings::port_name_to_task(target_tport);
        if receiving_task.is_null() {
            break 'out;
        }

        looked_up_task = (*dtape_hooks).task_lookup.expect("task_lookup hook")(pid, true, true);
        if looked_up_task.is_null() {
            break 'out;
        }

        right = if task_name {
            bindings::convert_task_name_to_port(&mut (*looked_up_task).xnu_task)
        } else if std::ptr::eq(
            &(*looked_up_task).xnu_task as *const _,
            bindings::dtape_rs_current_task() as *const _,
        ) {
            bindings::convert_task_to_port_pinned(&mut (*looked_up_task).xnu_task)
        } else {
            bindings::convert_task_to_port(&mut (*looked_up_task).xnu_task)
        };

        // consumed by convert_task{,_name}_to_port{,_pinned}
        looked_up_task = ptr::null_mut();

        if right.is_null() {
            break 'out;
        }

        out_name = bindings::ipc_port_copyout_send(right, (*receiving_task).itk_space);

        // consumed by ipc_port_copyout_send
        right = ptr::null_mut();

        if !mach_port_valid(out_name) {
            break 'out;
        }

        if bindings::copyout(
            &out_name as *const _ as *const c_void,
            t as bindings::user_addr_t,
            std::mem::size_of::<mach_port_name_t>(),
        ) != 0
        {
            break 'out;
        }

        // consumed by copyout
        out_name = 0;

        kr = bindings::KERN_SUCCESS as bindings::kern_return_t;
    }

    // out:
    if mach_port_valid(out_name) {
        bindings::mach_port_deallocate((*receiving_task).itk_space, out_name);
    }
    if !right.is_null() {
        bindings::ipc_port_release_send(right);
    }
    if !looked_up_task.is_null() {
        dtape_task_release(looked_up_task);
    }
    if !receiving_task.is_null() {
        task_deallocate(receiving_task);
    }
    kr
}

#[no_mangle]
pub unsafe extern "C" fn task_for_pid(
    args: *mut bindings::task_for_pid_args,
) -> bindings::kern_return_t {
    task_for_pid_internal((*args).target_tport, (*args).pid, (*args).t as usize, false)
}

#[no_mangle]
pub unsafe extern "C" fn task_name_for_pid(
    args: *mut bindings::task_name_for_pid_args,
) -> bindings::kern_return_t {
    task_for_pid_internal((*args).target_tport, (*args).pid, (*args).t as usize, true)
}

#[no_mangle]
pub unsafe extern "C" fn pid_for_task(
    args: *mut bindings::pid_for_task_args,
) -> bindings::kern_return_t {
    let mut kr = bindings::KERN_FAILURE as bindings::kern_return_t;
    let mut converted_task: task_t = ptr::null_mut();

    'out: {
        converted_task = bindings::port_name_to_task_name((*args).t);
        if converted_task.is_null() {
            break 'out;
        }

        let pid = task_pid(converted_task);

        if pid < 0 {
            break 'out;
        }

        if bindings::copyout(
            &pid as *const _ as *const c_void,
            (*args).pid as bindings::user_addr_t,
            std::mem::size_of::<c_int>(),
        ) != 0
        {
            break 'out;
        }

        kr = bindings::KERN_SUCCESS as bindings::kern_return_t;
    }

    // out:
    if !converted_task.is_null() {
        task_deallocate(converted_task);
    }
    kr
}

#[no_mangle]
pub unsafe extern "C" fn task_is_exec_copy(_task: task_t) -> bindings::boolean_t {
    crate::dtape_stub_safe!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn task_wait_locked(_task: task_t, _until_not_runnable: bindings::boolean_t) {
    // this was stubbed in the LKM, so it should be safe to stub here
    crate::dtape_stub_safe!();
}

//
// for task_ident.c
//

#[no_mangle]
pub unsafe extern "C" fn proc_find_ident(i: *const proc_ident) -> *mut c_void {
    (*dtape_hooks).task_lookup_eternal.expect("task_lookup_eternal hook")((*i).eid, true)
        as *mut c_void
}

#[no_mangle]
pub unsafe extern "C" fn proc_rele(p: *mut c_void) -> c_int {
    dtape_task_release(p as *mut dtape_task);
    0
}

#[no_mangle]
pub unsafe extern "C" fn proc_task(p: *mut c_void) -> task_t {
    &mut (*(p as *mut dtape_task)).xnu_task
}

#[no_mangle]
pub unsafe extern "C" fn proc_ident(p: *mut c_void) -> proc_ident {
    (*(p as *mut dtape_task)).p_ident
}

//
// end for task_ident.c
//

extern "C" {
    #[link_name = "malloc"]
    fn libc_malloc(size: usize) -> *mut c_void;
    #[link_name = "free"]
    fn libc_free(ptr: *mut c_void);
}

/// Silences the unused-import lint for types that appear only in casts.
const _: Option<c_uint> = None;
