//! Task-level duct-tape operations: thin wrappers over the dtape_task_* functions that
//! take an explicit `dtape_task_t*` (unlike the mach traps, which act on the current
//! task). A handler gets the task pointer from `sched::current_task()` -- the task its
//! microthread is bound to -- and passes it here. Mirrors the `process->_dtapeTask`
//! calls in call.cpp. See plan/rust-rewrite-eval.md (bucket A).

use crate::bindings::dtape_task_t;

extern "C" {
    // Record the guest's dyld all-image-info (address + length) on the task, so later
    // introspection (e.g. a debugger, or task_info(TASK_DYLD_INFO)) can find the guest's
    // loaded-image list. duct-tape/src/task.c:198.
    fn dtape_task_set_dyld_info(task: *mut dtape_task_t, address: u64, length: u64);
}

/// Store the guest's dyld all-image-info location (`address`, `length`) on `task`.
pub unsafe fn set_dyld_info(task: *mut dtape_task_t, address: u64, length: u64) {
    dtape_task_set_dyld_info(task, address, length);
}
