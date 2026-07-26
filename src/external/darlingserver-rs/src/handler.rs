//! The daemon's reusable RPC handler: the real handler bodies, run on a microthread
//! bound to the calling guest's task (so `sched::current_task()` and the `mach::*`
//! traps act on that guest). Starts with the special-port Mach traps; this is where the
//! remaining ~70 calls get implemented as the daemon grows. See plan/rust-rewrite-eval.md.

use crate::bindings::dtape_semaphore_t;
use crate::rpc_wire::{self, *};
use crate::{mach, sched, task, traps};
use std::collections::HashMap;
use std::os::fd::RawFd;

/// dserver_rpc_architecture values (from dserver-rpc-defs.h): a task is 64-bit iff its
/// architecture is x86_64 or arm64.
const ARCH_X86_64: u32 = 2;
const ARCH_ARM64: u32 = 4;

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

/// Per-guest-process state the daemon tracks in userspace (the parts of C++
/// DarlingServer::Process that the RPC handlers touch, beyond the dtape task). Keyed by
/// nsid in `Handler::procs`.
pub struct ProcState {
    /// The guest's pid in its OWN pid namespace (call header pid) -- identity/routing key.
    pub nsid: u32,
    /// The guest's pid in the DAEMON's namespace (from SO_PASSCRED, or == nsid in-process)
    /// -- what process_vm_readv/writev needs to reach the guest's memory.
    pub host_pid: libc::pid_t,
    /// dserver_rpc_architecture (drives is64Bit).
    pub architecture: u32,
    /// Whether the process should start suspended (StartedSuspended/StopAfterExec).
    pub start_suspended: bool,
    /// The tracer's nsid, or 0 for none (SetTracer/GetTracer). Once set, cannot be reset.
    pub tracer_nsid: i32,
    /// The Mach-O executable path (Set/GetExecutablePath).
    pub executable_path: String,
    /// The vchroot (container root) path, resolved from the vchroot directory fd.
    pub vchroot_path: String,
    /// The received vchroot directory fd, kept open so /proc/self/fd stays valid (owned;
    /// closed when replaced or on drop). Mirrors Process::_vchrootDescriptor.
    pub vchroot_fd: Option<RawFd>,
    /// The supplementary group list (Groups).
    pub groups: Vec<u32>,
    /// Per-thread (pthread_handle, dispatch_qaddr), keyed by guest tid (SetThreadHandles).
    pub thread_handles: HashMap<u64, (u64, u64)>,
    /// The nsid of the process that forked this one (None for the container init or a
    /// process whose parent the daemon never saw). Its fork semaphore is upped on checkin.
    pub parent_nsid: Option<u32>,
    /// This process's fork-wait semaphore (owned by its task): fork_wait_for_child blocks
    /// on it; a forked child ups it on checkin. Mirrors Process::_dtapeForkWaitSemaphore.
    pub fork_sem: Option<*mut dtape_semaphore_t>,
}

impl ProcState {
    fn new(nsid: u32, host_pid: libc::pid_t, architecture: u32) -> Self {
        ProcState {
            nsid,
            host_pid,
            architecture,
            start_suspended: false,
            tracer_nsid: 0,
            executable_path: String::new(),
            vchroot_path: String::new(),
            vchroot_fd: None,
            groups: Vec::new(),
            thread_handles: HashMap::new(),
            parent_nsid: None,
            fork_sem: None,
        }
    }
    fn is_64_bit(&self) -> bool {
        self.architecture == ARCH_X86_64 || self.architecture == ARCH_ARM64
    }
}

/// The daemon's RPC handler. Holds the per-process state table plus the identity of the
/// call currently being dispatched (set by the serve loop before each dispatch, since
/// the generated handler methods do not receive the call header). Single-threaded serve
/// loop -> `current_*` is safe to stash here.
pub struct Handler {
    procs: HashMap<u32, ProcState>,
    current_pid: u32,
    current_tid: u64,
    /// The mldr binary path reported to the guest (MldrPath), from DSERVER_MLDR_PATH.
    mldr_path: String,
    /// Descriptors to attach (SCM_RIGHTS) to the current reply -- set by handlers that
    /// return an @fd, drained by the serve loop after dispatch. Single-threaded, so this
    /// out-of-band channel is safe (the generated reply structs carry only fd indices).
    reply_fds: Vec<RawFd>,
    /// New process kqueue channels opened this dispatch, handed to the serve loop to
    /// register with the event loop (it owns the daemon-side sockets + death routing).
    pending_kqchans: Vec<crate::kqchan::ProcKqchan>,
}

impl Default for Handler {
    fn default() -> Self {
        Handler::new()
    }
}

impl Handler {
    pub fn new() -> Self {
        Handler {
            procs: HashMap::new(),
            current_pid: 0,
            current_tid: 0,
            mldr_path: std::env::var("DSERVER_MLDR_PATH").unwrap_or_default(),
            reply_fds: Vec::new(),
            pending_kqchans: Vec::new(),
        }
    }

    /// Take the fds to attach to the reply just produced (the serve loop sends them via
    /// SCM_RIGHTS with the reply datagram).
    pub fn take_reply_fds(&mut self) -> Vec<RawFd> {
        std::mem::take(&mut self.reply_fds)
    }
    /// Take the kqueue channels opened this dispatch, for the serve loop to register.
    pub fn take_pending_kqchans(&mut self) -> Vec<crate::kqchan::ProcKqchan> {
        std::mem::take(&mut self.pending_kqchans)
    }

    /// Bind the identity of the call about to be dispatched, ensuring the process's state
    /// exists. Call this (from the serve loop) before every `dispatch`. `host_pid` is the
    /// SO_PASSCRED pid for real guests, or the daemon's own pid for in-process demos.
    pub fn set_current(&mut self, nsid: u32, tid: u64, host_pid: libc::pid_t, arch: u32) {
        self.current_pid = nsid;
        self.current_tid = tid;
        if let Some(p) = self.procs.get_mut(&nsid) {
            if host_pid > 0 {
                p.host_pid = host_pid;
            }
            if arch != 0 {
                p.architecture = arch;
            }
            return;
        }
        // First sighting of this process. Link it to its parent (the ProcState whose host
        // pid == our /proc PPid) and inherit the parent's vchroot + groups, so a forked
        // child sees the same container root (without which its mldr cannot find dyld).
        // Mirrors Process's constructor. Then create its fork-wait semaphore on its task
        // (already ensured before dispatch, so current_task() is valid here).
        let parent_info = task::read_ppid(host_pid).and_then(|ppid| {
            self.procs
                .iter()
                .find(|(_, p)| p.host_pid == ppid)
                .map(|(&pn, p)| (pn, p.vchroot_path.clone(), p.groups.clone(), p.architecture))
        });
        let mut ps = ProcState::new(nsid, host_pid, arch);
        if let Some((parent_nsid, vchroot_path, groups, parch)) = parent_info {
            ps.parent_nsid = Some(parent_nsid);
            ps.vchroot_path = vchroot_path;
            ps.groups = groups;
            if ps.architecture == 0 {
                ps.architecture = parch;
            }
        }
        let task = sched::current_task();
        if !task.is_null() {
            ps.fork_sem = Some(unsafe { task::semaphore_create(task, 0) });
        }
        self.procs.insert(nsid, ps);
    }

    fn cur(&self) -> Option<&ProcState> {
        self.procs.get(&self.current_pid)
    }
    fn cur_mut(&mut self) -> Option<&mut ProcState> {
        let pid = self.current_pid;
        self.procs.get_mut(&pid)
    }

    /// Write `bytes` into the CURRENT (calling) guest's memory at `addr` (process_vm_writev
    /// to its host pid). Mirrors Process::writeMemory. -EFAULT on failure.
    fn write_mem(&self, addr: u64, bytes: &[u8]) -> Result<(), i32> {
        let pid = self.cur().ok_or(-libc::ESRCH)?.host_pid;
        if unsafe { sched::write_process_memory(pid, addr as usize, bytes) } {
            Ok(())
        } else {
            Err(-libc::EFAULT)
        }
    }
    /// Read `buf.len()` bytes from the CURRENT guest's memory at `addr`. Mirrors
    /// Process::readMemory. -EFAULT on failure.
    fn read_mem(&self, addr: u64, buf: &mut [u8]) -> Result<(), i32> {
        let pid = self.cur().ok_or(-libc::ESRCH)?.host_pid;
        if unsafe { sched::read_process_memory(pid, addr as usize, buf) } {
            Ok(())
        } else {
            Err(-libc::EFAULT)
        }
    }
}

impl rpc_wire::RpcHandler for Handler {
    /// A guest thread checks in when it connects. The process is registered implicitly
    /// (set_current, which also links it to its parent). Here we notify the parent that
    /// its forked child has arrived, upping the parent's fork-wait semaphore so its
    /// fork_wait_for_child unblocks. Mirrors Process::notifyCheckin's fork case. (Exec-
    /// replacement's task/thread swap is a later refinement.)
    fn checkin(&mut self, _call: &CallCheckin, _fds: &[RawFd]) -> Result<(), i32> {
        if let Some(parent_nsid) = self.cur().and_then(|p| p.parent_nsid) {
            if let Some(sem) = self.procs.get(&parent_nsid).and_then(|p| p.fork_sem) {
                unsafe { task::semaphore_up(sem) };
            }
        }
        Ok(())
    }
    /// A guest thread checks out on exit/exec. Acknowledged; the death/exec lifecycle
    /// (reaping, exec listener) is a later refinement.
    fn checkout(&mut self, _call: &CallCheckout, _fds: &[RawFd]) -> Result<(), i32> {
        Ok(())
    }

    /// Block until this process's forked child has checked in. Downs this process's
    /// fork-wait semaphore (the child ups it on checkin) -- the doWork microthread parks
    /// here and is resumed when the child arrives. Mirrors Process::waitForChildAfterFork.
    fn fork_wait_for_child(&mut self, _fds: &[RawFd]) -> Result<(), i32> {
        match self.cur().and_then(|p| p.fork_sem) {
            Some(sem) => {
                unsafe { task::semaphore_down_simple(sem) };
                Ok(())
            }
            None => Err(-libc::ESRCH),
        }
    }

    // interrupt_enter / interrupt_exit (#14/#15): signal (sigexc) delivery. These need the
    // interrupt to run NESTED on the guest thread's persisted microthread stack -- a signal
    // that interrupts a blocked daemon call must run its handler "on top", with the syscall
    // return during the interrupt jumping back to the interrupt's getcontext point (not the
    // doWork top), and interrupt_exit restoring the interrupted call. A minimal version that
    // just calls dtape_thread_sigexc_enter breaks the reply path (the guest sees -111) and
    // regresses working commands, so these stay ENOSYS (which the guest tolerates for
    // commands that do not rely on signal delivery) until the nested-interrupt scheduler
    // extension lands. The primitives are ready in thread.rs. See plan/rust-rewrite-eval.md
    // (bucket B.4).

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

    // ================= per-process state handlers =================

    /// Report and clear the start-suspended flag (a debugger/exec sets it via
    /// stop_after_exec; the guest queries it here right after starting).
    fn started_suspended(&mut self, _fds: &[RawFd]) -> Result<ReplyStartedSuspended, i32> {
        let p = self.cur_mut().ok_or(-libc::ESRCH)?;
        let suspended = p.start_suspended;
        p.start_suspended = false;
        Ok(ReplyStartedSuspended { suspended })
    }

    /// Mark the process to start suspended after its next exec (used by the tracer).
    fn stop_after_exec(&mut self, _fds: &[RawFd]) -> Result<(), i32> {
        self.cur_mut().ok_or(-libc::ESRCH)?.start_suspended = true;
        Ok(())
    }

    /// Record this thread's pthread handle + dispatch queue address (libpthread setup).
    fn set_thread_handles(&mut self, call: &CallSetThreadHandles, _fds: &[RawFd]) -> Result<(), i32> {
        let tid = self.current_tid;
        self.cur_mut()
            .ok_or(-libc::ESRCH)?
            .thread_handles
            .insert(tid, (call.pthread_handle, call.dispatch_qaddr));
        Ok(())
    }

    /// Whether the task named by `id` (nsid) is 64-bit. -ESRCH if unknown.
    fn task_is_64_bit(&mut self, call: &CallTaskIs64Bit, _fds: &[RawFd]) -> Result<ReplyTaskIs64Bit, i32> {
        match self.procs.get(&(call.id as u32)) {
            Some(p) => Ok(ReplyTaskIs64Bit { is_64_bit: p.is_64_bit() }),
            None => Err(-libc::ESRCH),
        }
    }

    /// The calling process's tracer nsid (0 if none).
    fn get_tracer(&mut self, _fds: &[RawFd]) -> Result<ReplyGetTracer, i32> {
        let p = self.cur().ok_or(-libc::ESRCH)?;
        Ok(ReplyGetTracer { tracer: p.tracer_nsid })
    }

    /// Set the tracer of `target` (0 == the caller) to `tracer` (0 == none). Fails with
    /// EPERM (positive, a user error) if a tracer is already set, ESRCH if either process
    /// is unknown. Mirrors call.cpp's SetTracer (non-negated user-error codes).
    fn set_tracer(&mut self, call: &CallSetTracer, _fds: &[RawFd]) -> Result<(), i32> {
        let target_nsid = if call.target == 0 { self.current_pid } else { call.target as u32 };
        // Validate the tracer exists (if one was named) before touching the target.
        if call.tracer != 0 && !self.procs.contains_key(&(call.tracer as u32)) {
            return Err(libc::ESRCH);
        }
        let target = self.procs.get_mut(&target_nsid).ok_or(libc::ESRCH)?;
        if target.tracer_nsid != 0 {
            return Err(libc::EPERM);
        }
        target.tracer_nsid = call.tracer;
        Ok(())
    }

    /// Store the calling process's Mach-O executable path (read from its memory).
    fn set_executable_path(&mut self, call: &CallSetExecutablePath, _fds: &[RawFd]) -> Result<(), i32> {
        let mut buf = vec![0u8; call.buffer_size as usize];
        self.read_mem(call.buffer, &mut buf)?;
        let path = cstr_from_bytes(&buf);
        self.cur_mut().ok_or(-libc::ESRCH)?.executable_path = path;
        Ok(())
    }

    /// Copy the executable path of process `pid` into the caller's buffer; reply carries
    /// the untruncated length. ESRCH (positive) if the target is gone.
    fn get_executable_path(&mut self, call: &CallGetExecutablePath, _fds: &[RawFd]) -> Result<ReplyGetExecutablePath, i32> {
        let path = match self.procs.get(&(call.pid as u32)) {
            Some(p) => p.executable_path.clone(),
            None => return Err(libc::ESRCH),
        };
        let length = self.copy_path_to_guest(call.buffer, call.buffer_size, &path)?;
        Ok(ReplyGetExecutablePath { length })
    }

    /// Get (and optionally set) the process's supplementary group list. Reply carries the
    /// OLD group count. Mirrors call.cpp's Groups.
    fn groups(&mut self, call: &CallGroups, _fds: &[RawFd]) -> Result<ReplyGroups, i32> {
        let old_groups = self.cur().ok_or(-libc::ESRCH)?.groups.clone();
        if call.new_groups != 0 && call.new_group_count > 0 {
            let mut buf = vec![0u8; (call.new_group_count as usize) * 4];
            self.read_mem(call.new_groups, &mut buf)?;
            let new_groups: Vec<u32> = buf.chunks_exact(4).map(|c| u32::from_ne_bytes([c[0], c[1], c[2], c[3]])).collect();
            self.cur_mut().unwrap().groups = new_groups;
        }
        if call.old_groups != 0 && call.old_group_space > 0 {
            let n = old_groups.len().min(call.old_group_space as usize);
            let mut bytes = Vec::with_capacity(n * 4);
            for g in &old_groups[..n] {
                bytes.extend_from_slice(&g.to_ne_bytes());
            }
            self.write_mem(call.old_groups, &bytes)?;
        }
        Ok(ReplyGroups { old_group_count: old_groups.len() as u64 })
    }

    /// Set the calling process's vchroot (container root) directory. The directory fd
    /// arrives via SCM_RIGHTS (@fd), not the wire body; resolve it to a path with
    /// readlink(/proc/self/fd/<fd>) and cache that, keeping the fd open. Mirrors call.cpp's
    /// Vchroot + Process::setVchrootDirectory.
    fn vchroot(&mut self, _call: &CallVchroot, fds: &[RawFd]) -> Result<(), i32> {
        let dfd = *fds.first().ok_or(-libc::EBADF)?;
        // Resolve the fd to its path in our (shared) mount namespace.
        let link = std::ffi::CString::new(format!("/proc/self/fd/{dfd}")).unwrap();
        let mut buf = vec![0u8; 4096];
        let len = unsafe { libc::readlink(link.as_ptr(), buf.as_mut_ptr() as *mut libc::c_char, 4095) };
        if len < 0 {
            return Err(-std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EIO));
        }
        buf.truncate(len as usize);
        let path = String::from_utf8_lossy(&buf).into_owned();
        let p = self.cur_mut().ok_or(-libc::ESRCH)?;
        if let Some(old) = p.vchroot_fd.replace(dfd) {
            if old != dfd {
                unsafe { libc::close(old) };
            }
        }
        p.vchroot_path = path;
        Ok(())
    }

    /// Open a process kqueue channel (EVFILT_PROC) watching process `pid`. Returns one
    /// end of a SEQPACKET socketpair (via SCM_RIGHTS; the reply `socket` field is its
    /// descriptor index). The daemon keeps the other end -- the serve loop's event loop
    /// registers it and delivers the target's death (NOTE_EXIT) as a notification.
    /// Mirrors call.cpp's KqchanProcOpen + Kqchan::Process::setup.
    fn kqchan_proc_open(&mut self, call: &CallKqchanProcOpen, _fds: &[RawFd]) -> Result<ReplyKqchanProcOpen, i32> {
        let target_nsid = call.pid as u32;
        let target_host_pid = match self.procs.get(&target_nsid) {
            Some(p) => p.host_pid,
            None => return Err(-libc::ESRCH),
        };
        let (kq, guest_fd) = crate::kqchan::ProcKqchan::open(target_nsid, target_host_pid, call.flags)
            .map_err(|e| -e.raw_os_error().unwrap_or(libc::EIO))?;
        self.reply_fds.push(guest_fd);
        self.pending_kqchans.push(kq);
        // socket = 0: the fd is the first (only) SCM_RIGHTS descriptor on this reply.
        Ok(ReplyKqchanProcOpen { socket: 0 })
    }

    /// Copy the process's vchroot (container root) path into the caller's buffer; reply
    /// carries the untruncated length.
    fn vchroot_path(&mut self, call: &CallVchrootPath, _fds: &[RawFd]) -> Result<ReplyVchrootPath, i32> {
        let path = self.cur().ok_or(-libc::ESRCH)?.vchroot_path.clone();
        let length = self.copy_path_to_guest(call.buffer, call.buffer_size, &path)?;
        Ok(ReplyVchrootPath { length })
    }

    /// Copy the mldr binary path into the caller's buffer. NOTE: call.cpp reports the
    /// vchroot path length (not the mldr path length) as the "full length" here -- a quirk
    /// carried over from VchrootPath; replicated for parity.
    fn mldr_path(&mut self, call: &CallMldrPath, _fds: &[RawFd]) -> Result<ReplyMldrPath, i32> {
        let mldr = self.mldr_path.clone();
        let vchroot_len = self.cur().ok_or(-libc::ESRCH)?.vchroot_path.len() as u64;
        if call.buffer_size > 0 {
            let take = mldr.len().min((call.buffer_size - 1) as usize);
            let mut bytes = mldr.as_bytes()[..take].to_vec();
            bytes.push(0);
            self.write_mem(call.buffer, &bytes)?;
        }
        Ok(ReplyMldrPath { length: vchroot_len })
    }

    /// Log a guest kprintf string (read from its memory, trailing whitespace stripped).
    fn kprintf(&mut self, call: &CallKprintf, _fds: &[RawFd]) -> Result<(), i32> {
        let mut buf = vec![0u8; call.string_length as usize];
        self.read_mem(call.string, &mut buf)?;
        let text = String::from_utf8_lossy(&buf);
        eprintln!("[guest kprintf] {}", text.trim_end());
        Ok(())
    }
}

/// A C string (NUL-terminated) from a byte buffer -> Rust String (lossy; up to the NUL).
fn cstr_from_bytes(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

impl Handler {
    /// Write a path (truncated to `buffer_size - 1` + NUL) into the CURRENT guest's buffer,
    /// returning the untruncated byte length. Mirrors the writeMemory idiom in call.cpp's
    /// VchrootPath/MldrPath/GetExecutablePath.
    fn copy_path_to_guest(&self, buffer: u64, buffer_size: u64, path: &str) -> Result<u64, i32> {
        let full = path.len() as u64;
        if buffer_size > 0 {
            let take = path.len().min((buffer_size - 1) as usize);
            let mut bytes = path.as_bytes()[..take].to_vec();
            bytes.push(0);
            self.write_mem(buffer, &bytes)?;
        }
        Ok(full)
    }
}
