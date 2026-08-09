//! Mach special-port traps: the simplest Mach operations the daemon serves
//! (task_self_trap / host_self_trap / thread_self_trap / mach_reply_port). Thin
//! wrappers over the duct-tape's dtape_*_trap functions, which act on the CURRENT
//! task/thread (per the running microthread) -- so a handler calling them must run on
//! a microthread bound to the guest's task via the registry. These are the first real
//! Mach calls on the way to mach_msg (they take no message, so they need no copyin/
//! copyout and never block). Mirrors call.cpp's TaskSelfTrap/... handlers. See
//! PLAN.md (bucket A, mach IPC core).

// Declared here in an `extern "C"` block until duct-tape became Rust (#71); imported directly
// now (#75), because the linker matched those by name and rustc never compared them against
// the definitions.
//
//   the four self traps         task, host, thread and reply port, each returning a guest name
//   the port traps              generated dtape wrappers that call the XNU _kernelrpc_*_trap on
//                               the current task ipc space. name and name_out are GUEST
//                               addresses; the trap copies results out through copyout, which
//                               is the task_write_memory hook.
//   dtape_mach_msg_overwrite    the mach_msg trap. msg and rcv_msg are GUEST addresses: the
//                               message is copied IN from msg (copyinmsg, read_memory) and on
//                               receive OUT to rcv_msg (copyoutmsg, write_memory). Blocks via
//                               thread_suspend when a receive has to wait.
use crate::xnu::traps::{
    dtape_host_self_trap, dtape_mach_reply_port, dtape_task_self_trap, dtape_thread_self_trap,
};
use crate::xnu::traps_generated::{
    dtape_mach_msg_overwrite, dtape_mach_port_allocate, dtape_mach_port_deallocate,
    dtape_mach_port_mod_refs, dtape_mach_port_type,
};

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

/// The mach_msg trap on the current task. `msg` points to the message to send (guest
/// address); on receive the dequeued message is copied to `rcv_msg`. Returns a
/// mach_msg_return_t (MACH_MSG_SUCCESS == 0).
#[allow(clippy::too_many_arguments)]
pub unsafe fn msg_overwrite(
    msg: u64,
    option: i32,
    send_size: u32,
    rcv_size: u32,
    rcv_name: u32,
    timeout: u32,
    priority: u32,
    rcv_msg: u64,
) -> i32 {
    dtape_mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, priority, rcv_msg)
}

/// mach_msg option bits.
pub const MACH_SEND_MSG: i32 = 0x0000_0001;
pub const MACH_RCV_MSG: i32 = 0x0000_0002;
/// Remote-port disposition: make a send right from a named receive right (lets a task
/// send to a port it holds the receive right for, no separate insert_right needed).
pub const MACH_MSG_TYPE_MAKE_SEND: u32 = 20;
/// MACH_MSGH_BITS(remote, local): assemble the header bits field.
pub const fn msgh_bits(remote: u32, local: u32) -> u32 {
    remote | (local << 8)
}
