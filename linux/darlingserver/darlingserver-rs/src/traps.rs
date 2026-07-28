//! XNU-trap duct-tape wrappers: the bulk of the Mach traps the guest issues, each a
//! thin `dtape_<name>(args) -> int` call whose return is the reply code. The generated
//! C++ does `Thread::syscallReturn(dtape_<name>(_body.<args>))`; here the handler calls
//! the same dtape function and returns Ok(()) on 0 / Err(code) otherwise. Pointer args
//! are GUEST addresses (the trap copies results out via the write_memory hook). The
//! traps act on the CURRENT task/thread (per the running microthread), so a handler
//! calling them must run on a microthread bound to the guest's task via the registry.
//! Mirrors generate-rpc-wrappers.py's DSERVER_DTAPE_DECLS. See plan/rust-rewrite-eval.md.

use crate::bindings::dtape_task_t;

extern "C" {
    // --- mach port ops (the rest, beyond allocate/deallocate/mod_refs/type in mach.rs) ---
    fn dtape_mach_port_move_member(target: u32, member: u32, after: u32) -> i32;
    fn dtape_mach_port_insert_right(target: u32, name: u32, poly: u32, poly_poly: i32) -> i32;
    fn dtape_mach_port_insert_member(target: u32, name: u32, pset: u32) -> i32;
    fn dtape_mach_port_extract_member(target: u32, name: u32, pset: u32) -> i32;
    fn dtape_mach_port_construct(target: u32, options: u64, context: u64, name: u64) -> i32;
    fn dtape_mach_port_destruct(target: u32, name: u32, srdelta: i32, guard: u64) -> i32;
    fn dtape_mach_port_guard(target: u32, name: u32, guard: u64, strict: bool) -> i32;
    fn dtape_mach_port_unguard(target: u32, name: u32, guard: u64) -> i32;
    fn dtape_mach_port_request_notification(target: u32, name: u32, msgid: i32, sync: u32, notify: u32, notify_poly: u32, previous: u64) -> i32;
    fn dtape_mach_port_get_attributes(target: u32, name: u32, flavor: i32, info: u64, count: u64) -> i32;

    // --- task <-> pid lookups (copy the result port/pid out via the pointer arg) ---
    fn dtape_task_for_pid(target_tport: u32, pid: i32, t: u64) -> i32;
    fn dtape_task_name_for_pid(target_tport: u32, pid: i32, t: u64) -> i32;
    fn dtape_pid_for_task(t: u32, pid: u64) -> i32;

    // --- Mach VM traps ---
    fn dtape_mach_vm_allocate(target: u32, addr: u64, size: u64, flags: i32) -> i32;
    fn dtape_mach_vm_deallocate(target: u32, address: u64, size: u64) -> i32;

    // --- Mach semaphore traps (the wait variants may block via thread_suspend) ---
    fn dtape_semaphore_signal(signal_name: u32) -> i32;
    fn dtape_semaphore_signal_all(signal_name: u32) -> i32;
    fn dtape_semaphore_wait(wait_name: u32) -> i32;
    fn dtape_semaphore_wait_signal(wait_name: u32, signal_name: u32) -> i32;
    fn dtape_semaphore_timedwait(wait_name: u32, sec: u32, nsec: u32) -> i32;
    fn dtape_semaphore_timedwait_signal(wait_name: u32, signal_name: u32, sec: u32, nsec: u32) -> i32;

    // --- mk_timer traps ---
    fn dtape_mk_timer_create() -> u32;
    fn dtape_mk_timer_destroy(name: u32) -> i32;
    fn dtape_mk_timer_arm(name: u32, expire_time: u64) -> i32;
    fn dtape_mk_timer_cancel(name: u32, result_time: u64) -> i32;

    // --- misc ---
    fn dtape_thread_get_special_reply_port() -> u32;
    // Swap the task's stored uid/gid, returning the previous pair via the out pointers.
    fn dtape_task_uidgid(task: *mut dtape_task_t, new_uid: i32, new_gid: i32, old_uid: *mut i32, old_gid: *mut i32);
}

// The XNU traps all return an int status (0 == success); the pointer args are guest
// addresses the trap copies results out to. Thin pass-throughs so the handler layer
// stays declarative.

pub unsafe fn mach_port_move_member(target: u32, member: u32, after: u32) -> i32 { dtape_mach_port_move_member(target, member, after) }
pub unsafe fn mach_port_insert_right(target: u32, name: u32, poly: u32, poly_poly: i32) -> i32 { dtape_mach_port_insert_right(target, name, poly, poly_poly) }
pub unsafe fn mach_port_insert_member(target: u32, name: u32, pset: u32) -> i32 { dtape_mach_port_insert_member(target, name, pset) }
pub unsafe fn mach_port_extract_member(target: u32, name: u32, pset: u32) -> i32 { dtape_mach_port_extract_member(target, name, pset) }
pub unsafe fn mach_port_construct(target: u32, options: u64, context: u64, name: u64) -> i32 { dtape_mach_port_construct(target, options, context, name) }
pub unsafe fn mach_port_destruct(target: u32, name: u32, srdelta: i32, guard: u64) -> i32 { dtape_mach_port_destruct(target, name, srdelta, guard) }
pub unsafe fn mach_port_guard(target: u32, name: u32, guard: u64, strict: bool) -> i32 { dtape_mach_port_guard(target, name, guard, strict) }
pub unsafe fn mach_port_unguard(target: u32, name: u32, guard: u64) -> i32 { dtape_mach_port_unguard(target, name, guard) }
#[allow(clippy::too_many_arguments)]
pub unsafe fn mach_port_request_notification(target: u32, name: u32, msgid: i32, sync: u32, notify: u32, notify_poly: u32, previous: u64) -> i32 { dtape_mach_port_request_notification(target, name, msgid, sync, notify, notify_poly, previous) }
pub unsafe fn mach_port_get_attributes(target: u32, name: u32, flavor: i32, info: u64, count: u64) -> i32 { dtape_mach_port_get_attributes(target, name, flavor, info, count) }

pub unsafe fn task_for_pid(target_tport: u32, pid: i32, t: u64) -> i32 { dtape_task_for_pid(target_tport, pid, t) }
pub unsafe fn task_name_for_pid(target_tport: u32, pid: i32, t: u64) -> i32 { dtape_task_name_for_pid(target_tport, pid, t) }
pub unsafe fn pid_for_task(t: u32, pid: u64) -> i32 { dtape_pid_for_task(t, pid) }

pub unsafe fn mach_vm_allocate(target: u32, addr: u64, size: u64, flags: i32) -> i32 { dtape_mach_vm_allocate(target, addr, size, flags) }
pub unsafe fn mach_vm_deallocate(target: u32, address: u64, size: u64) -> i32 { dtape_mach_vm_deallocate(target, address, size) }

pub unsafe fn semaphore_signal(signal_name: u32) -> i32 { dtape_semaphore_signal(signal_name) }
pub unsafe fn semaphore_signal_all(signal_name: u32) -> i32 { dtape_semaphore_signal_all(signal_name) }
pub unsafe fn semaphore_wait(wait_name: u32) -> i32 { dtape_semaphore_wait(wait_name) }
pub unsafe fn semaphore_wait_signal(wait_name: u32, signal_name: u32) -> i32 { dtape_semaphore_wait_signal(wait_name, signal_name) }
pub unsafe fn semaphore_timedwait(wait_name: u32, sec: u32, nsec: u32) -> i32 { dtape_semaphore_timedwait(wait_name, sec, nsec) }
pub unsafe fn semaphore_timedwait_signal(wait_name: u32, signal_name: u32, sec: u32, nsec: u32) -> i32 { dtape_semaphore_timedwait_signal(wait_name, signal_name, sec, nsec) }

pub unsafe fn mk_timer_create() -> u32 { dtape_mk_timer_create() }
pub unsafe fn mk_timer_destroy(name: u32) -> i32 { dtape_mk_timer_destroy(name) }
pub unsafe fn mk_timer_arm(name: u32, expire_time: u64) -> i32 { dtape_mk_timer_arm(name, expire_time) }
pub unsafe fn mk_timer_cancel(name: u32, result_time: u64) -> i32 { dtape_mk_timer_cancel(name, result_time) }

pub unsafe fn thread_get_special_reply_port() -> u32 { dtape_thread_get_special_reply_port() }

/// Swap the task's uid/gid to (new_uid,new_gid); returns the PREVIOUS (uid,gid).
pub unsafe fn task_uidgid(task: *mut dtape_task_t, new_uid: i32, new_gid: i32) -> (i32, i32) {
    let mut old_uid: i32 = -1;
    let mut old_gid: i32 = -1;
    dtape_task_uidgid(task, new_uid, new_gid, &mut old_uid, &mut old_gid);
    (old_uid, old_gid)
}
