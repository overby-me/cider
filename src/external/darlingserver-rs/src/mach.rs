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
    // Generated dtape trap wrappers (they call the XNU _kernelrpc_*_trap on the current
    // task's ipc space). `name`/`name_out` are GUEST addresses; the trap copies results
    // out to them via copyout -> the task_write_memory hook.
    fn dtape_mach_port_allocate(target: u32, right: i32, name_out: u64) -> i32;
    fn dtape_mach_port_deallocate(target: u32, name: u32) -> i32;
    fn dtape_mach_port_type(target: u32, name: u32, ptype_out: u64) -> i32;
    fn dtape_mach_port_mod_refs(target: u32, name: u32, right: i32, delta: i32) -> i32;
}

/// Mach port right kinds (MACH_PORT_RIGHT_*).
pub const MACH_PORT_RIGHT_RECEIVE: i32 = 1;
pub const MACH_PORT_RIGHT_DEAD_NAME: i32 = 4;
/// Port type bit for a receive right: MACH_PORT_TYPE(MACH_PORT_RIGHT_RECEIVE) = 1 << 17.
pub const MACH_PORT_TYPE_RECEIVE: u32 = 0x0002_0000;
/// kern_return_t values.
pub const KERN_SUCCESS: i32 = 0;
pub const KERN_INVALID_NAME: i32 = 15;

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

/// Allocate a port right (`right`: RECEIVE=1, PORT_SET=3, DEAD_NAME=4) in the task
/// named by `target` in the current ipc space. The allocated name is copied OUT to the
/// guest address `name_out` (via the write_memory hook). Returns a kern_return_t.
pub unsafe fn port_allocate(target: u32, right: i32, name_out: u64) -> i32 {
    dtape_mach_port_allocate(target, right, name_out)
}

/// Release a user reference for the send/send-once/dead-name right `name` in the task
/// named by `target`. Returns a kern_return_t.
pub unsafe fn port_deallocate(target: u32, name: u32) -> i32 {
    dtape_mach_port_deallocate(target, name)
}

/// Query the type bits of the port name `name` in `target`'s ipc space; the
/// MACH_PORT_TYPE_* mask is copied OUT to the guest address `ptype_out` (write_memory
/// hook). Returns a kern_return_t (KERN_INVALID_NAME if the name does not exist).
pub unsafe fn port_type(target: u32, name: u32, ptype_out: u64) -> i32 {
    dtape_mach_port_type(target, name, ptype_out)
}

/// Change the user-reference count of the `right` on `name` by `delta` in `target`'s
/// ipc space (delta -1 on a receive right destroys it). Returns a kern_return_t.
pub unsafe fn port_mod_refs(target: u32, name: u32, right: i32, delta: i32) -> i32 {
    dtape_mach_port_mod_refs(target, name, right, delta)
}
