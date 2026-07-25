//! The daemon's reusable RPC handler: the real handler bodies, run on a microthread
//! bound to the calling guest's task (so `sched::current_task()` and the `mach::*`
//! traps act on that guest). Starts with the special-port Mach traps; this is where the
//! remaining ~70 calls get implemented as the daemon grows. See plan/rust-rewrite-eval.md.

use crate::mach;
use crate::rpc_wire::{
    self, CallCheckin, CallCheckout, CallMachMsgOverwrite, CallMachPortAllocate,
    CallMachPortDeallocate, CallMachPortModRefs, CallMachPortType, ReplyHostSelfTrap,
    ReplyMachReplyPort, ReplyTaskSelfTrap, ReplyThreadSelfTrap,
};
use std::os::fd::RawFd;

/// The daemon's RPC handler. Stateless for now (the per-guest state lives in the task
/// the handler's microthread is bound to).
pub struct Handler;

impl rpc_wire::RpcHandler for Handler {
    /// A guest thread checks in when it connects. Registration is implicit here (the
    /// task is ensured when the first call routes to it), so checkin just acknowledges;
    /// fork/exec-replacement notification (notifyCheckin) is a later refinement.
    fn checkin(&mut self, _call: &CallCheckin, _fds: &[RawFd]) -> Result<(), i32> {
        Ok(())
    }
    /// A guest thread checks out on exit/exec. Acknowledged; the death/exec lifecycle
    /// (reaping, exec listener) is a later refinement.
    fn checkout(&mut self, _call: &CallCheckout, _fds: &[RawFd]) -> Result<(), i32> {
        Ok(())
    }

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

    /// mach_msg: copy the message IN from the caller's `msg` buffer, route it, and (on
    /// receive) copy it OUT to the caller's `rcv_msg` buffer -- both in the caller's own
    /// address space via the memory hooks. The reply carries only the mach_msg_return_t.
    fn mach_msg_overwrite(&mut self, call: &CallMachMsgOverwrite, _fds: &[RawFd]) -> Result<(), i32> {
        match unsafe {
            mach::msg_overwrite(
                call.msg,
                call.option,
                call.send_size,
                call.rcv_size,
                call.rcv_name,
                call.timeout,
                call.priority,
                call.rcv_msg,
            )
        } {
            0 => Ok(()),
            code => Err(code),
        }
    }

    fn mach_port_deallocate(&mut self, call: &CallMachPortDeallocate, _fds: &[RawFd]) -> Result<(), i32> {
        match unsafe { mach::port_deallocate(call.target, call.name) } {
            mach::KERN_SUCCESS => Ok(()),
            code => Err(code),
        }
    }

    fn mach_port_mod_refs(&mut self, call: &CallMachPortModRefs, _fds: &[RawFd]) -> Result<(), i32> {
        match unsafe { mach::port_mod_refs(call.target, call.name, call.right, call.delta) } {
            mach::KERN_SUCCESS => Ok(()),
            code => Err(code),
        }
    }

    fn mach_port_type(&mut self, call: &CallMachPortType, _fds: &[RawFd]) -> Result<(), i32> {
        match unsafe { mach::port_type(call.target, call.name, call.ptype) } {
            mach::KERN_SUCCESS => Ok(()),
            code => Err(code),
        }
    }
}
