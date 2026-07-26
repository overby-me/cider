//! The daemon's reusable RPC handler: the real handler bodies, run on a microthread
//! bound to the calling guest's task (so `sched::current_task()` and the `mach::*`
//! traps act on that guest). Starts with the special-port Mach traps; this is where the
//! remaining ~70 calls get implemented as the daemon grows. See plan/rust-rewrite-eval.md.

use crate::rpc_wire::{
    self, CallCheckin, CallCheckout, CallMachMsgOverwrite, CallMachPortAllocate,
    CallMachPortConstruct, CallMachPortDeallocate, CallMachPortDestruct,
    CallMachPortExtractMember, CallMachPortGetAttributes, CallMachPortGuard,
    CallMachPortInsertMember, CallMachPortInsertRight, CallMachPortModRefs,
    CallMachPortMoveMember, CallMachPortRequestNotification, CallMachPortType,
    CallMachPortUnguard, CallMachVmAllocate, CallMachVmDeallocate, CallMkTimerArm,
    CallMkTimerCancel, CallMkTimerDestroy, CallPidForTask, CallSemaphoreSignal,
    CallSemaphoreSignalAll, CallSemaphoreTimedwait, CallSemaphoreTimedwaitSignal,
    CallSemaphoreWait, CallSemaphoreWaitSignal, CallSetDyldInfo, CallTaskForPid,
    CallTaskNameForPid, CallUidgid, ReplyHostSelfTrap, ReplyMachReplyPort,
    ReplyMkTimerCreate, ReplyTaskSelfTrap, ReplyThreadGetSpecialReplyPort,
    ReplyThreadSelfTrap, ReplyUidgid,
};
use crate::{mach, sched, task, traps};
use std::os::fd::RawFd;

/// Map an XNU-trap return (0 == success) to the handler Result the dispatcher expects:
/// Ok(()) encodes reply code 0, Err(code) passes the trap's status through verbatim --
/// exactly what the generated `Thread::syscallReturn(dtape_<trap>(...))` does.
fn trap(r: i32) -> Result<(), i32> {
    if r == 0 {
        Ok(())
    } else {
        Err(r)
    }
}

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

    /// Record the guest's dyld all-image-info (address + length) on its task, so later
    /// introspection can find the loaded-image list. -ESRCH if the task is gone (matching
    /// call.cpp's SetDyldInfo, which resolves process->_dtapeTask). The task here is the
    /// one this microthread is bound to (sched::current_task()).
    fn set_dyld_info(&mut self, call: &CallSetDyldInfo, _fds: &[RawFd]) -> Result<(), i32> {
        let taskptr = sched::current_task();
        if taskptr.is_null() {
            return Err(-libc::ESRCH);
        }
        unsafe { task::set_dyld_info(taskptr, call.address, call.length) };
        Ok(())
    }

    // ---- uidgid: swap the task's uid/gid, returning the previous pair ----
    fn uidgid(&mut self, call: &CallUidgid, _fds: &[RawFd]) -> Result<ReplyUidgid, i32> {
        let taskptr = sched::current_task();
        if taskptr.is_null() {
            return Err(-libc::ESRCH);
        }
        let (old_uid, old_gid) = unsafe { traps::task_uidgid(taskptr, call.new_uid, call.new_gid) };
        Ok(ReplyUidgid { old_uid, old_gid })
    }

    // ---- port-returning traps (no message, never block) ----
    fn thread_get_special_reply_port(&mut self, _fds: &[RawFd]) -> Result<ReplyThreadGetSpecialReplyPort, i32> {
        Ok(ReplyThreadGetSpecialReplyPort { port_name: unsafe { traps::thread_get_special_reply_port() } })
    }
    fn mk_timer_create(&mut self, _fds: &[RawFd]) -> Result<ReplyMkTimerCreate, i32> {
        Ok(ReplyMkTimerCreate { port_name: unsafe { traps::mk_timer_create() } })
    }

    // ---- the remaining mach_port_* XNU traps (act on the current task's ipc space) ----
    fn mach_port_move_member(&mut self, call: &CallMachPortMoveMember, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_move_member(call.target, call.member, call.after) })
    }
    fn mach_port_insert_right(&mut self, call: &CallMachPortInsertRight, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_insert_right(call.target, call.name, call.poly, call.polyPoly) })
    }
    fn mach_port_insert_member(&mut self, call: &CallMachPortInsertMember, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_insert_member(call.target, call.name, call.pset) })
    }
    fn mach_port_extract_member(&mut self, call: &CallMachPortExtractMember, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_extract_member(call.target, call.name, call.pset) })
    }
    fn mach_port_construct(&mut self, call: &CallMachPortConstruct, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_construct(call.target, call.options, call.context, call.name) })
    }
    fn mach_port_destruct(&mut self, call: &CallMachPortDestruct, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_destruct(call.target, call.name, call.srdelta, call.guard) })
    }
    fn mach_port_guard(&mut self, call: &CallMachPortGuard, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_guard(call.target, call.name, call.guard, call.strict) })
    }
    fn mach_port_unguard(&mut self, call: &CallMachPortUnguard, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_unguard(call.target, call.name, call.guard) })
    }
    fn mach_port_request_notification(&mut self, call: &CallMachPortRequestNotification, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe {
            traps::mach_port_request_notification(call.target, call.name, call.msgid, call.sync, call.notify, call.notifyPoly, call.previous)
        })
    }
    fn mach_port_get_attributes(&mut self, call: &CallMachPortGetAttributes, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_port_get_attributes(call.target, call.name, call.flavor, call.info, call.count) })
    }

    // ---- task <-> pid lookups (copy the result out via the pointer arg) ----
    fn task_for_pid(&mut self, call: &CallTaskForPid, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::task_for_pid(call.target_tport, call.pid, call.t) })
    }
    fn task_name_for_pid(&mut self, call: &CallTaskNameForPid, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::task_name_for_pid(call.target_tport, call.pid, call.t) })
    }
    fn pid_for_task(&mut self, call: &CallPidForTask, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::pid_for_task(call.t, call.pid) })
    }

    // ---- Mach VM traps ----
    fn mach_vm_allocate(&mut self, call: &CallMachVmAllocate, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_vm_allocate(call.target, call.addr, call.size, call.flags) })
    }
    fn mach_vm_deallocate(&mut self, call: &CallMachVmDeallocate, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mach_vm_deallocate(call.target, call.address, call.size) })
    }

    // ---- Mach semaphore traps. The wait variants may block (dtape thread_suspend);
    // the reply is then sent when the microthread is woken -- routed by the persistent
    // doWork serve loop (see darlingserverd). The signal variants never block. ----
    fn semaphore_signal(&mut self, call: &CallSemaphoreSignal, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::semaphore_signal(call.signal_name) })
    }
    fn semaphore_signal_all(&mut self, call: &CallSemaphoreSignalAll, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::semaphore_signal_all(call.signal_name) })
    }
    fn semaphore_wait(&mut self, call: &CallSemaphoreWait, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::semaphore_wait(call.wait_name) })
    }
    fn semaphore_wait_signal(&mut self, call: &CallSemaphoreWaitSignal, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::semaphore_wait_signal(call.wait_name, call.signal_name) })
    }
    fn semaphore_timedwait(&mut self, call: &CallSemaphoreTimedwait, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::semaphore_timedwait(call.wait_name, call.sec, call.nsec) })
    }
    fn semaphore_timedwait_signal(&mut self, call: &CallSemaphoreTimedwaitSignal, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::semaphore_timedwait_signal(call.wait_name, call.signal_name, call.sec, call.nsec) })
    }

    // ---- mk_timer arm/cancel/destroy ----
    fn mk_timer_destroy(&mut self, call: &CallMkTimerDestroy, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mk_timer_destroy(call.name) })
    }
    fn mk_timer_arm(&mut self, call: &CallMkTimerArm, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mk_timer_arm(call.name, call.expire_time) })
    }
    fn mk_timer_cancel(&mut self, call: &CallMkTimerCancel, _fds: &[RawFd]) -> Result<(), i32> {
        trap(unsafe { traps::mk_timer_cancel(call.name, call.result_time) })
    }
}
