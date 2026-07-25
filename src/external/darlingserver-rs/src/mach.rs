//! Mach special-port traps: the simplest Mach operations the daemon serves
//! (task_self_trap / host_self_trap / thread_self_trap / mach_reply_port). Thin
//! wrappers over the duct-tape's dtape_*_trap functions, which act on the CURRENT
//! task/thread (per the running microthread) -- so a handler calling them must run on
//! a microthread bound to the guest's task via the registry. These are the first real
//! Mach calls on the way to mach_msg (they take no message, so they need no copyin/
//! copyout and never block). Mirrors call.cpp's TaskSelfTrap/... handlers. See
//! plan/rust-rewrite-eval.md (bucket A, mach IPC core).

extern "C" {
    fn dtape_task_self_trap() -> u32;
    fn dtape_host_self_trap() -> u32;
    fn dtape_thread_self_trap() -> u32;
    fn dtape_mach_reply_port() -> u32;
}

/// Port name of the current task's self-port.
pub unsafe fn task_self_trap() -> u32 {
    dtape_task_self_trap()
}

/// Port name of the host self-port.
pub unsafe fn host_self_trap() -> u32 {
    dtape_host_self_trap()
}

/// Port name of the current thread's self-port.
pub unsafe fn thread_self_trap() -> u32 {
    dtape_thread_self_trap()
}

/// Allocate a fresh reply port in the current task's IPC space; returns its name.
pub unsafe fn mach_reply_port() -> u32 {
    dtape_mach_reply_port()
}
