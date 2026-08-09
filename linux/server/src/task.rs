//! Task-level duct-tape operations: thin wrappers over the dtape_task_* functions that
//! take an explicit `dtape_task_t*` (unlike the mach traps, which act on the current
//! task). A handler gets the task pointer from `sched::current_task()` -- the task its
//! microthread is bound to -- and passes it here. Mirrors the `process->_dtapeTask`
//! calls in call.cpp. See PLAN.md (bucket A).

use crate::bindings::{dtape_semaphore_t, dtape_task_t};

// These were `extern "C"` declarations resolving back into this crate through the linker;
// imported directly since duct-tape became Rust (#71, #75).
//
//   dtape_task_set_dyld_info       records the guest dyld all-image-info (address and length)
//                                  on the task, so later introspection (a debugger, or
//                                  task_info(TASK_DYLD_INFO)) can find the loaded-image list.
//   dtape_task_set_sigexc_enabled  ptrace sigexc: a debugger uses PT_SIGEXC so signals arrive
//                                  as Mach exceptions it can intercept.
//   dtape_task_try_resume          resume the task if it was stopped waiting for the debugger.
use crate::xnu::task::{dtape_task_set_dyld_info, dtape_task_set_sigexc_enabled, dtape_task_try_resume};

/// Enable or disable sigexc (Mach-exception signal delivery) on `task` -- PT_SIGEXC.
pub unsafe fn set_sigexc_enabled(task: *mut dtape_task_t, enabled: bool) {
    dtape_task_set_sigexc_enabled(task, enabled);
}
/// Try to resume `task` if it was suspended awaiting a debugger. Returns whether it resumed.
pub unsafe fn try_resume(task: *mut dtape_task_t) -> bool {
    dtape_task_try_resume(task)
}

/// Store the guest's dyld all-image-info location (`address`, `length`) on `task`.
pub unsafe fn set_dyld_info(task: *mut dtape_task_t, address: u64, length: u64) {
    dtape_task_set_dyld_info(task, address, length);
}

// The object-level semaphores used to be four more extern declarations here, against
// duct-tape/src/semaphore.c. That file is Rust now (#71), so these forward into the crate
// rather than out through the FFI. The signatures are unchanged, and the symbols are still
// exported with the C ABI, because kqchan.c is still C and calls them.

/// Create a semaphore owned by `task` with `initial` value.
pub unsafe fn semaphore_create(task: *mut dtape_task_t, initial: i32) -> *mut dtape_semaphore_t {
    crate::xnu::semaphore::dtape_semaphore_create(task, initial)
}
/// Increment (signal) `sem`.
pub unsafe fn semaphore_up(sem: *mut dtape_semaphore_t) {
    crate::xnu::semaphore::dtape_semaphore_up(sem);
}
/// Decrement (wait on) `sem`, blocking the current microthread until it is signaled.
/// Returns false if interrupted.
pub unsafe fn semaphore_down_simple(sem: *mut dtape_semaphore_t) -> bool {
    crate::xnu::semaphore::dtape_semaphore_down_simple(sem)
}
/// Destroy `sem`.
pub unsafe fn semaphore_destroy(sem: *mut dtape_semaphore_t) {
    crate::xnu::semaphore::dtape_semaphore_destroy(sem);
}

/// The host-side parent pid (PPid) of `pid`, from /proc/<pid>/status. Used to link a
/// forked child to its parent (matching Process's constructor, which parses PPid).
pub fn read_ppid(pid: libc::pid_t) -> Option<libc::pid_t> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("PPid:") {
            return rest.trim().parse().ok();
        }
    }
    None
}
