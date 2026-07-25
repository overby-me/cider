//! The daemon's reusable RPC handler: the real handler bodies, run on a microthread
//! bound to the calling guest's task (so `sched::current_task()` and the `mach::*`
//! traps act on that guest). Starts with the special-port Mach traps; this is where the
//! remaining ~70 calls get implemented as the daemon grows. See plan/rust-rewrite-eval.md.

use crate::mach;
use crate::rpc_wire::{
    self, CallMachPortAllocate, ReplyHostSelfTrap, ReplyMachReplyPort, ReplyTaskSelfTrap,
    ReplyThreadSelfTrap,
};
use std::os::fd::RawFd;

/// The daemon's RPC handler. Stateless for now (the per-guest state lives in the task
/// the handler's microthread is bound to).
pub struct Handler;

impl rpc_wire::RpcHandler for Handler {
    fn task_self_trap(&mut self, _fds: &[RawFd]) -> Result<ReplyTaskSelfTrap, i32> {
        Ok(ReplyTaskSelfTrap { port_name: unsafe { mach::task_self_trap() } })
    }
    fn host_self_trap(&mut self, _fds: &[RawFd]) -> Result<ReplyHostSelfTrap, i32> {
        Ok(ReplyHostSelfTrap { port_name: unsafe { mach::host_self_trap() } })
    }
    fn thread_self_trap(&mut self, _fds: &[RawFd]) -> Result<ReplyThreadSelfTrap, i32> {
        Ok(ReplyThreadSelfTrap { port_name: unsafe { mach::thread_self_trap() } })
    }
    fn mach_reply_port(&mut self, _fds: &[RawFd]) -> Result<ReplyMachReplyPort, i32> {
        Ok(ReplyMachReplyPort { port_name: unsafe { mach::mach_reply_port() } })
    }

    /// Allocate a port right; the allocated NAME is copied out to the caller's `name`
    /// address in ITS OWN address space (write_memory hook -> process_vm_writev to the
    /// client's pid). The reply carries only the kern_return_t.
    fn mach_port_allocate(&mut self, call: &CallMachPortAllocate, _fds: &[RawFd]) -> Result<(), i32> {
        match unsafe { mach::port_allocate(call.target, call.right, call.name) } {
            mach::KERN_SUCCESS => Ok(()),
            code => Err(code),
        }
    }
}
