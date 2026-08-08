//! The daemon's reusable RPC handler: the real handler bodies, run on a microthread
//! bound to the calling guest's task (so `sched::current_task()` and the `mach::*`
//! traps act on that guest). Starts with the special-port Mach traps; this is where the
//! remaining ~70 calls get implemented as the daemon grows. See PLAN.md.

use crate::bindings::dtape_semaphore_t;
use crate::rpc_wire::{self, *};
use crate::{mach, psynch, sched, task, thread, traps};
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

/// Run a psynch BSD-trap op. Zeroes the current microthread's BSD-retval slot, calls `f`
/// with a stable pointer to it (the `retvalPointer` the op fills; or, if the op blocks on a
/// contended lock, that its continuation fills before the deferred reply), then pairs the
/// returned errno with the retval `mk` turns into the per-op reply body. Ok(body) encodes
/// reply code 0 with the retval; Err(code) passes the errno through -- exactly C++'s
/// `Thread::syscallReturn(dtape_psynch_<op>(..., bsdReturnValuePointer()))` +
/// `sendBSDReply(code, _bsdReturnValue)`. For a blocking op this never returns (the
/// continuation re-enters the doWork loop, which posts the reply); see darlingserverd.
fn psynch_op<R>(mk: impl FnOnce(u32) -> R, f: impl FnOnce(*mut u32) -> i32) -> Result<R, i32> {
    unsafe {
        let mt = sched::current();
        (*mt).set_bsd_retval(0);
        let trace = psynch_trace();
        // ENTER fires for every psynch op; FASTRET only when f() returns without blocking.
        // ENTER without a matching FASTRET == the op blocked on a contended lock (its reply
        // is deferred: the continuation re-enters the doWork loop, which posts {code,retval}).
        if trace {
            eprintln!("darlingserver: psynch ENTER");
        }
        let code = f((*mt).bsd_retval_ptr());
        let retval = (*mt).bsd_retval();
        if trace {
            eprintln!("darlingserver: psynch FASTRET code={code} retval={retval}");
        }
        if code == 0 {
            Ok(mk(retval))
        } else {
            Err(code)
        }
    }
}

/// Whether a fault signal should be dumped, from `DSERVER_TRACE_SIGNAL` (comma-separated
/// LINUX signal numbers) plus `DSERVER_TRACE_SIGFPE` for 8 on its own.
///
/// A bitmask rather than a list, cached, because this is on the signal path: 64 bits covers
/// every signal number there is.
fn trace_signal(sig: i32) -> bool {
    use std::sync::atomic::{AtomicU64, Ordering};
    const UNREAD: u64 = u64::MAX;
    static MASK: AtomicU64 = AtomicU64::new(UNREAD);
    let mut mask = MASK.load(Ordering::Relaxed);
    if mask == UNREAD {
        mask = 0;
        if std::env::var_os("DSERVER_TRACE_SIGFPE").is_some() {
            mask |= 1 << 8;
        }
        if let Some(v) = std::env::var_os("DSERVER_TRACE_SIGNAL") {
            for part in v.to_string_lossy().split(',') {
                if let Ok(n) = part.trim().parse::<u32>() {
                    if n < 64 {
                        mask |= 1 << n;
                    }
                }
            }
        }
        MASK.store(mask, Ordering::Relaxed);
    }
    (0..64).contains(&sig) && mask & (1 << sig) != 0
}

/// Whether the `DSERVER_TRACE_PSYNCH` env var is set (cached after the first read, so the
/// psynch hot path does no per-call env lookup). 0 = off, 1 = on, 2 = not-yet-read.
fn psynch_trace() -> bool {
    use std::sync::atomic::{AtomicU8, Ordering};
    static STATE: AtomicU8 = AtomicU8::new(2);
    match STATE.load(Ordering::Relaxed) {
        0 => false,
        1 => true,
        _ => {
            let on = std::env::var_os("DSERVER_TRACE_PSYNCH").is_some();
            STATE.store(on as u8, Ordering::Relaxed);
            on
        }
    }
}

/// Send `signal` to a resolved guest thread via tgkill(host_pid, host_tid, signal) -- the
/// primitive C++ Thread::sendSignal uses (thread.cpp:1445). Returns -errno on a failed
/// tgkill, or -ESRCH if the thread's host ids are not (yet) resolvable.
unsafe fn send_thread_signal(mt: *mut crate::sched::Microthread, signal: i32) -> Result<(), i32> {
    let host_pid = (*mt).host_pid();
    let host_tid = (*mt).host_tid();
    if host_pid <= 0 || host_tid <= 0 {
        return Err(-libc::ESRCH);
    }
    let rc = libc::syscall(
        libc::SYS_tgkill,
        host_pid as libc::c_long,
        host_tid as libc::c_long,
        signal as libc::c_long,
    );
    if rc < 0 {
        Err(-std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EPERM))
    } else {
        Ok(())
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

impl Drop for ProcState {
    /// Close the retained vchroot directory fd when the process's state is dropped (on
    /// process exit, when the serve loop prunes it). Without this, every guest process ever
    /// seen leaks its vchroot DIR fd -- a build's thousands of subprocesses exhaust the
    /// daemon's fd table. The fork_sem (owned by the task) is intentionally left to the task's
    /// own lifecycle, not freed here.
    fn drop(&mut self) {
        if let Some(fd) = self.vchroot_fd.take() {
            unsafe { libc::close(fd) };
        }
    }
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

// ---- dserverdbg port/message enumeration (task #60) ----
// Daemon-facing debug records; same layout as the duct-tape's dtape_debug_port_t / _message_t and
// dserver_debug_port_t / _message_t that dserverdbg reads (generate-rpc-wrappers.py:819,826).
#[repr(C)]
struct DserverDebugPort {
    port_name: u32,
    rights: u32,
    refs: u64,
    messages: u64,
}
#[repr(C)]
struct DserverDebugMessage {
    sender: u32,
    size: u64,
}

// Rust since #71, so imported rather than declared through the linker (#75). Each walks a task
// port table and calls the iterator back per entry, returning the count.
use crate::debug::{
    dtape_debug_port_list_messages, dtape_debug_portset_list_members, dtape_debug_task_list_ports,
};

/// dtape port iterator: write each port as a dserver_debug_port_t to the pipe fd in `context`
/// (a *RawFd). Mirrors the C++ lambda in DebugListPorts/Members (call.cpp:1122).
unsafe extern "C" fn debug_port_writer(context: *mut libc::c_void, port: *const crate::bindings::dtape_debug_port_t) -> bool {
    let fd = *(context as *const RawFd);
    let p = &*port;
    let out = DserverDebugPort { port_name: p.name, rights: p.rights, refs: p.refs, messages: p.messages };
    libc::write(fd, &out as *const _ as *const libc::c_void, std::mem::size_of::<DserverDebugPort>());
    true
}
/// dtape message iterator: write each message as a dserver_debug_message_t to the pipe fd in
/// `context`. Mirrors the C++ lambda in DebugListMessages (call.cpp:1184).
unsafe extern "C" fn debug_message_writer(context: *mut libc::c_void, message: *const crate::bindings::dtape_debug_message_t) -> bool {
    let fd = *(context as *const RawFd);
    let m = &*message;
    let out = DserverDebugMessage { sender: m.sender, size: m.size };
    libc::write(fd, &out as *const _ as *const libc::c_void, std::mem::size_of::<DserverDebugMessage>());
    true
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
    /// New mach-port kqueue channels opened this dispatch (task #54), handed to the serve loop
    /// (boxed: their address is the duct-tape notification callback's context, so it must be stable).
    pending_kqchans_mach: Vec<Box<crate::kqchan::MachPortKqchan>>,
    /// New guest-console daemon-side fds opened this dispatch (console_open, task #60): the daemon
    /// monitors each and logs the guest's console/os_log output. Handed to the serve loop.
    pending_consoles: Vec<RawFd>,
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
            pending_kqchans_mach: Vec::new(),
            pending_consoles: Vec::new(),
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
    /// Take the mach-port kqchans opened this dispatch (task #54), for the serve loop to register.
    pub fn take_pending_kqchans_mach(&mut self) -> Vec<Box<crate::kqchan::MachPortKqchan>> {
        std::mem::take(&mut self.pending_kqchans_mach)
    }
    /// Take the guest-console daemon fds opened this dispatch (console_open, task #60).
    pub fn take_pending_consoles(&mut self) -> Vec<RawFd> {
        std::mem::take(&mut self.pending_consoles)
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

    /// Drop a process's state on its exit (the serve loop calls this once the process's last
    /// thread has done a real, non-exec checkout). Removing the ProcState runs its Drop, which
    /// closes the retained vchroot fd. Returns whether a state existed. Mirrors the process-
    /// side of C++ Process::notifyDead cleanup (the ProcState part).
    pub fn prune_process(&mut self, nsid: u32) -> bool {
        if self.current_pid == nsid {
            self.current_pid = 0;
        }
        self.procs.remove(&nsid).is_some()
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
    fn checkin(&mut self, _call: &CallCheckin, fds: &[RawFd]) -> Result<(), i32> {
        // Defensive: close any SCM_RIGHTS fd (a lifetime pipe can ride checkin when
        // __mldr_lifetime_pipe is set). The high-volume leak is on `checkout` -- see there for
        // the full pipe-page-starvation mechanism that this prevents.
        for &fd in fds {
            unsafe { libc::close(fd); }
        }
        if let Some(parent_nsid) = self.cur().and_then(|p| p.parent_nsid) {
            if let Some(sem) = self.procs.get(&parent_nsid).and_then(|p| p.fork_sem) {
                unsafe { task::semaphore_up(sem) };
            }
        }
        Ok(())
    }
    /// A guest thread checks out on exit. Tell XNU the thread is dying so its Mach state
    /// (ports, rights, notifications) is torn down -- otherwise a later send to the dead
    /// thread's ports spins the daemon ("kmsg to pid -1"). The daemon then reaps its
    /// microthread + slot (see darlingserverd::reap_thread). Mirrors C++ Call::Checkout ->
    /// dtape_thread_dying. (The exec-listener branch is a later refinement.)
    fn checkout(&mut self, _call: &CallCheckout, fds: &[RawFd]) -> Result<(), i32> {
        // Checkout carries the process's `lifetime_listener_pipe` read end via SCM_RIGHTS.
        // The C++ daemon holds it (EOF => ungraceful-death detection); this daemon reaps here
        // explicitly and never reads it, so CLOSE it. Otherwise ONE pipe read end leaks per
        // process exit: a build's thousands of exits accumulate thousands of pipe read ends in
        // the daemon (~16 reserved pages each), blow past `fs.pipe-user-pages-soft` (16384
        // pages), and the kernel then shrinks EVERY NEW pipe to a single 4KB page. bash's
        // config.status generation writes a multi-KB here-doc (the M4sh-init block) into a pipe
        // expecting the normal 64KB buffer; against a 1-page pipe with no reader yet it blocks
        // in write() FOREVER -- the "config.status hang" that deadlocks guest nix/toolchain
        // builds (M1) under this daemon but not under C++ (which closes it). Verified: the
        // daemon held 1838 read-end pipes for 5 live processes at a live hang.
        for &fd in fds {
            unsafe { libc::close(fd); }
        }
        let mt = sched::current();
        if !mt.is_null() {
            unsafe { thread::dying((*mt).dtape_thread()) };
        }
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

    // interrupt_enter / interrupt_exit (#14/#15): signal (sigexc) delivery. A guest thread
    // brackets its signal handler with these. interrupt_enter tells XNU the thread entered
    // sigexc state (sigexc_enter) and pushes the saved user_state (sigexc_enter2) that
    // interrupt_exit's sigexc_exit pops -- both are required or the pop corrupts the thread.
    // (The getcontext dance for a signal that interrupts a BLOCKED daemon call -- running
    // that call's continuation nested + deferring its reply -- is a later refinement; this
    // covers the common non-nested case.)
    fn interrupt_enter(&mut self, _fds: &[RawFd]) -> Result<(), i32> {
        let dthread = unsafe {
            let mt = sched::current();
            if mt.is_null() {
                return Err(-libc::ESRCH);
            }
            (*mt).dtape_thread()
        };
        if dthread.is_null() {
            return Err(-libc::ESRCH);
        }
        unsafe {
            thread::sigexc_enter(dthread);
            thread::sigexc_enter2(dthread);
        }
        Ok(())
    }
    fn interrupt_exit(&mut self, _fds: &[RawFd]) -> Result<(), i32> {
        let dthread = unsafe {
            let mt = sched::current();
            if mt.is_null() {
                return Err(-libc::ESRCH);
            }
            (*mt).dtape_thread()
        };
        if dthread.is_null() {
            return Err(-libc::ESRCH);
        }
        unsafe { thread::sigexc_exit(dthread) };
        Ok(())
    }

    /// Process a signal delivered to the calling thread (sigprocess #12): load its saved
    /// register/float state (from the guest addresses), run the signal through XNU -- which
    /// rewrites the state to enter the guest's handler and records the signal to actually
    /// deliver -- optionally wait while user-suspended, then save the modified state back.
    /// The reply carries the BSD signal number the guest should deliver. Mirrors call.cpp's
    /// Sigprocess + Thread::processSignal.
    fn sigprocess(&mut self, call: &CallSigprocess, _fds: &[RawFd]) -> Result<ReplySigprocess, i32> {
        let mt = sched::current();
        if mt.is_null() {
            return Err(-libc::ESRCH);
        }
        let dthread = unsafe { (*mt).dtape_thread() };
        if dthread.is_null() {
            return Err(-libc::ESRCH);
        }
        // Fault diagnostic: the fault kind + the faulting instruction. signal_address is the
        // faulting RIP; dumping 16 bytes there is what identifies the instruction -- an
        // integer `idiv` means a wrongly-zero divisor (task #51's SIGFPE), a `ud2` means code
        // that was compiled to trap, which is how an unimplemented stub announces itself.
        //
        // Which signals to trace comes from DSERVER_TRACE_SIGNAL (comma-separated LINUX
        // numbers, e.g. "4,8,11"); DSERVER_TRACE_SIGFPE still means 8 on its own. Gated
        // either way, so normal runs stay quiet.
        if trace_signal(call.linux_signal_number) {
            let pid = self.cur().map(|p| p.host_pid);
            let mut insn = [0u8; 16];
            let got = pid
                .map(|pid| unsafe { crate::sched::read_process_memory(pid, call.signal_address as usize, &mut insn) })
                .unwrap_or(false);
            let hex = if got { insn.iter().map(|b| format!("{b:02x} ")).collect::<String>() } else { "?".to_string() };
            eprintln!(
                "darlingserver: SIGNAL_DIAG sig={} code={} rip={:#x} sender_pid={} insn=[{}]",
                call.linux_signal_number, call.code, call.signal_address, call.sender_pid,
                hex.trim_end()
            );
        }
        unsafe {
            let r = thread::load_state_from_user(dthread, call.thread_state, call.float_state);
            if r != 0 {
                return Err(r);
            }
            thread::process_signal(dthread, call.bsd_signal_number, call.linux_signal_number, call.code, call.signal_address);
            thread::wait_while_user_suspended(dthread);
            let r = thread::save_state_to_user(dthread, call.thread_state, call.float_state);
            if r != 0 {
                return Err(r);
            }
        }
        let new_bsd_signal_number = unsafe { (*mt).pending_signal() };
        Ok(ReplySigprocess { new_bsd_signal_number })
    }

    /// Block the calling thread while it is user-suspended (a debugger stopped it), then
    /// restore its state. Returns immediately if not suspended. Mirrors call.cpp's
    /// ThreadSuspended + Thread::waitWhileUserSuspended.
    fn thread_suspended(&mut self, call: &CallThreadSuspended, _fds: &[RawFd]) -> Result<(), i32> {
        let mt = sched::current();
        if mt.is_null() {
            return Err(-libc::ESRCH);
        }
        let dthread = unsafe { (*mt).dtape_thread() };
        if dthread.is_null() {
            return Err(-libc::ESRCH);
        }
        unsafe {
            let r = thread::load_state_from_user(dthread, call.thread_state, call.float_state);
            if r != 0 {
                return Err(r);
            }
            thread::wait_while_user_suspended(dthread);
            // saving state back is best-effort (the process may have died while suspended).
            thread::save_state_to_user(dthread, call.thread_state, call.float_state);
        }
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
        let code = unsafe {
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
        };
        // Diagnostic (DSERVER_TRACE_MSG): a timed-out receive is a poll. A tight repeat on one
        // rcv_name flags a port whose expected message never arrives (a Mach-side livelock) --
        // a lead worth checking when a guest hangs. MACH_RCV_TIMED_OUT == 0x10004003. (Note:
        // the M1 config.status hang is NOT this -- it is a guest bash here-doc pipe deadlock
        // with the daemon idle; see PLAN.md "M1 status 2026-07-27".)
        if code as u32 == 0x10004003 && std::env::var_os("DSERVER_TRACE_MSG").is_some() {
            eprintln!(
                "darlingserver: mach_msg RCV TIMED_OUT rcv_name={} option={:#x} timeout={}",
                call.rcv_name, call.option, call.timeout
            );
        }
        match code {
            0 => Ok(()),
            c => Err(c),
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

    // ---- psynch: pthread mutex/condvar/rwlock (BSD traps with a u32 retval body).
    // The wait ops (mutexwait/cvwait/rw_rdlock/rw_wrlock) block on contention via a
    // continuation: this handler then never returns, and the doWork loop posts the deferred
    // reply from the stashed errno + the retval slot the continuation filled (see
    // psynch_op + darlingserverd's deferred_reply). The wake ops return immediately. ----
    fn psynch_cvbroad(&mut self, call: &CallPsynchCvbroad, _fds: &[RawFd]) -> Result<ReplyPsynchCvbroad, i32> {
        psynch_op(|retval| ReplyPsynchCvbroad { retval }, |rv| unsafe {
            psynch::cvbroad(call.cv, call.cvlsgen, call.cvudgen, call.flags, call.mutex, call.mugen, call.tid, rv)
        })
    }
    fn psynch_cvclrprepost(&mut self, call: &CallPsynchCvclrprepost, _fds: &[RawFd]) -> Result<ReplyPsynchCvclrprepost, i32> {
        psynch_op(|retval| ReplyPsynchCvclrprepost { retval }, |rv| unsafe {
            psynch::cvclrprepost(call.cv, call.cvgen, call.cvugen, call.cvsgen, call.prepocnt, call.preposeq, call.flags, rv)
        })
    }
    fn psynch_cvsignal(&mut self, call: &CallPsynchCvsignal, _fds: &[RawFd]) -> Result<ReplyPsynchCvsignal, i32> {
        psynch_op(|retval| ReplyPsynchCvsignal { retval }, |rv| unsafe {
            psynch::cvsignal(call.cv, call.cvlsgen, call.cvugen, call.threadport, call.mutex, call.mugen, call.tid, call.flags, rv)
        })
    }
    fn psynch_cvwait(&mut self, call: &CallPsynchCvwait, _fds: &[RawFd]) -> Result<ReplyPsynchCvwait, i32> {
        psynch_op(|retval| ReplyPsynchCvwait { retval }, |rv| unsafe {
            psynch::cvwait(call.cv, call.cvlsgen, call.cvugen, call.mutex, call.mugen, call.flags, call.sec, call.nsec, rv)
        })
    }
    fn psynch_mutexdrop(&mut self, call: &CallPsynchMutexdrop, _fds: &[RawFd]) -> Result<ReplyPsynchMutexdrop, i32> {
        psynch_op(|retval| ReplyPsynchMutexdrop { retval }, |rv| unsafe {
            psynch::mutexdrop(call.mutex, call.mgen, call.ugen, call.tid, call.flags, rv)
        })
    }
    fn psynch_mutexwait(&mut self, call: &CallPsynchMutexwait, _fds: &[RawFd]) -> Result<ReplyPsynchMutexwait, i32> {
        psynch_op(|retval| ReplyPsynchMutexwait { retval }, |rv| unsafe {
            psynch::mutexwait(call.mutex, call.mgen, call.ugen, call.tid, call.flags, rv)
        })
    }
    fn psynch_rw_rdlock(&mut self, call: &CallPsynchRwRdlock, _fds: &[RawFd]) -> Result<ReplyPsynchRwRdlock, i32> {
        psynch_op(|retval| ReplyPsynchRwRdlock { retval }, |rv| unsafe {
            psynch::rw_rdlock(call.rwlock, call.lgenval, call.ugenval, call.rw_wc, call.flags, rv)
        })
    }
    fn psynch_rw_unlock(&mut self, call: &CallPsynchRwUnlock, _fds: &[RawFd]) -> Result<ReplyPsynchRwUnlock, i32> {
        psynch_op(|retval| ReplyPsynchRwUnlock { retval }, |rv| unsafe {
            psynch::rw_unlock(call.rwlock, call.lgenval, call.ugenval, call.rw_wc, call.flags, rv)
        })
    }
    fn psynch_rw_wrlock(&mut self, call: &CallPsynchRwWrlock, _fds: &[RawFd]) -> Result<ReplyPsynchRwWrlock, i32> {
        psynch_op(|retval| ReplyPsynchRwWrlock { retval }, |rv| unsafe {
            psynch::rw_wrlock(call.rwlock, call.lgenval, call.ugenval, call.rw_wc, call.flags, rv)
        })
    }

    /// `__pthread_canceled(action)` -- the cancellation-point query libpthread makes at every
    /// interruptible syscall. `action == 0` is the query: reply 0 means "this thread is
    /// canceled, act on it", anything else means "not canceled, proceed". The calling thread's
    /// cancel bit is set by a prior pthread_markcancel; actions 1/2 (enable/disable cancel
    /// notifications) are guest-local, so ack them. Mirrors C++ Call::PthreadCanceled
    /// (call.cpp:619), operating on the current thread.
    fn pthread_canceled(&mut self, call: &CallPthreadCanceled, _fds: &[RawFd]) -> Result<(), i32> {
        if call.action == 0 {
            let mt = crate::sched::current();
            let canceled = !mt.is_null() && unsafe { (*mt).is_canceled() };
            if canceled { Ok(()) } else { Err(-libc::EINVAL) }
        } else {
            Ok(())
        }
    }

    /// `tid_for_thread(thread_port)` -> the target thread's guest tid. Resolve the Mach thread
    /// port to its microthread and report its nsid. An invalid port or dead thread is (likely)
    /// user error, so return a non-negated ESRCH. Mirrors Call::TidForThread (call.cpp:936).
    fn tid_for_thread(&mut self, call: &CallTidForThread, _fds: &[RawFd]) -> Result<ReplyTidForThread, i32> {
        match unsafe { crate::sched::thread_for_port(call.thread) } {
            Some(mt) => Ok(ReplyTidForThread { tid: unsafe { (*mt).nsid_tid() } as i32 }),
            None => Err(libc::ESRCH),
        }
    }

    /// `pthread_kill(thread_port, signal)`: deliver `signal` to the target guest thread via
    /// tgkill(host_pid, host_tid, signal). With the nested signal-interrupt path (task #58) in
    /// place, delivering a signal to a thread blocked mid-call no longer crashes the daemon.
    /// A dead/unknown target is -ESRCH, a failed tgkill is -errno. Mirrors Call::PthreadKill +
    /// Thread::sendSignal (thread.cpp:1445).
    fn pthread_kill(&mut self, call: &CallPthreadKill, _fds: &[RawFd]) -> Result<(), i32> {
        let mt = unsafe { crate::sched::thread_for_port(call.thread_port) }.ok_or(-libc::ESRCH)?;
        unsafe { send_thread_signal(mt, call.signal) }
    }

    /// `pthread_markcancel(thread_port)`: mark the target thread canceled and kick it out of
    /// any interruptible syscall with SIGNAL_SIGEXC_KICK (SIGRTMIN+2, installed guest-side
    /// without SA_RESTART) so it promptly reaches a cancellation point. The kick may fail if the
    /// thread is already gone; that is not an error. Mirrors Call::PthreadMarkcancel +
    /// Thread::markCanceled (thread.cpp:1459).
    fn pthread_markcancel(&mut self, call: &CallPthreadMarkcancel, _fds: &[RawFd]) -> Result<(), i32> {
        let mt = unsafe { crate::sched::thread_for_port(call.thread_port) }.ok_or(-libc::ESRCH)?;
        unsafe {
            (*mt).set_canceled();
            let _ = send_thread_signal(mt, libc::SIGRTMIN() + 2);
        }
        Ok(())
    }

    /// `ptrace_sigexc(target, enabled)`: enable/disable Mach-exception signal delivery on the
    /// target process (a debugger's PT_SIGEXC, so signals arrive as interceptable Mach
    /// exceptions) and try to resume it. Resolves the target task by nsid via the task_lookup
    /// table. A missing target is a non-negated ESRCH (not an internal error). Mirrors
    /// Call::PtraceSigexc (call.cpp:950).
    fn ptrace_sigexc(&mut self, call: &CallPtraceSigexc, _fds: &[RawFd]) -> Result<(), i32> {
        let task = crate::sched::task_for_nsid(call.target as u32);
        if task.is_null() {
            return Err(libc::ESRCH);
        }
        unsafe {
            task::set_sigexc_enabled(task, call.enabled);
            task::try_resume(task);
        }
        Ok(())
    }

    /// Modify the signal a target (traced) thread will deliver from its in-flight signal-interrupt
    /// -- a debugger suppressing (0) or changing it via ptrace PT_THUPDATE. Sets the target's
    /// pending_signal, which its sigprocess RPC returns as new_bsd_signal_number. Mirrors
    /// Call::PtraceThupdate -> Thread::setPendingSignal (thread.cpp:952). (task #61)
    fn ptrace_thupdate(&mut self, call: &CallPtraceThupdate, _fds: &[RawFd]) -> Result<(), i32> {
        let mt = crate::sched::microthread_for_tid(call.target as u64);
        if mt.is_null() {
            return Err(libc::ESRCH); // not negated: this is a bad target, not an internal error
        }
        unsafe {
            (*mt).set_pending_signal(call.signum);
        }
        Ok(())
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

    /// Open a mach-port kqueue channel (EVFILT_MACHPORT) on the CALLER's task -- task #54, approach
    /// b (event-driven, single-worker; see kqchan::MachPortKqchan). The guest end comes back via
    /// SCM_RIGHTS (socket=0). Unblocks libdispatch mach sources + launchd boot. Mirrors
    /// Call::KqchanMachPortOpen.
    fn kqchan_mach_port_open(&mut self, call: &CallKqchanMachPortOpen, _fds: &[RawFd]) -> Result<ReplyKqchanMachPortOpen, i32> {
        let task = crate::sched::task_for_nsid(self.current_pid);
        if task.is_null() {
            return Err(-libc::ESRCH);
        }
        let (kq, guest_fd) = crate::kqchan::MachPortKqchan::open(
            task,
            call.port_name,
            call.receive_buffer,
            call.receive_buffer_size,
            call.saved_filter_flags,
        )
        .map_err(|e| -e.raw_os_error().unwrap_or(libc::EIO))?;
        self.reply_fds.push(guest_fd);
        self.pending_kqchans_mach.push(kq);
        Ok(ReplyKqchanMachPortOpen { socket: 0 })
    }

    /// Open a guest console channel (task #60): a SOCK_STREAM socketpair whose guest end (@fd) the
    /// guest writes its console / os_log output to, and whose daemon end the serve loop monitors +
    /// logs. Mirrors Call::ConsoleOpen (call.cpp:787) -- real utility for guest system-console output.
    fn console_open(&mut self, _fds: &[RawFd]) -> Result<ReplyConsoleOpen, i32> {
        let mut fds = [0 as RawFd; 2];
        let rc = unsafe {
            libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr())
        };
        if rc < 0 {
            return Err(-std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EMFILE));
        }
        let (daemon_fd, guest_fd) = (fds[0], fds[1]);
        unsafe {
            let f = libc::fcntl(daemon_fd, libc::F_GETFL, 0);
            libc::fcntl(daemon_fd, libc::F_SETFL, f | libc::O_NONBLOCK);
        }
        self.reply_fds.push(guest_fd);
        self.pending_consoles.push(daemon_fd);
        // console = 0: the fd is the first (only) SCM_RIGHTS descriptor on this reply.
        Ok(ReplyConsoleOpen { console: 0 })
    }

    /// Enumerate the daemon's known guest processes for dserverdbg's `ps` (task #60): write one
    /// {pid, port_count} record per process to a pipe and return the read end (@fd) + count. Real
    /// diagnostic utility -- inspect the live daemon's process/port state when debugging Darling
    /// itself (hangs, leaks). Mirrors Call::DebugListProcesses (call.cpp:1092).
    fn debug_list_processes(&mut self, _fds: &[RawFd]) -> Result<ReplyDebugListProcesses, i32> {
        extern "C" {
            fn dtape_debug_task_port_count(task: *mut crate::bindings::dtape_task_t) -> u64;
        }
        // Matches dserver_debug_process_t (dserverdbg.c:336 reads pid:%u, port_count:%lu): u32 then
        // 4 bytes pad then u64 = 16 bytes under repr(C), exactly what the reader expects.
        #[repr(C)]
        struct DebugProcess {
            pid: u32,
            port_count: u64,
        }
        let mut pipes = [0 as RawFd; 2];
        if unsafe { libc::pipe(pipes.as_mut_ptr()) } < 0 {
            return Err(-std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EMFILE));
        }
        let (rd, wr) = (pipes[0], pipes[1]);
        let mut count = 0u64;
        let nsids: Vec<u32> = self.procs.keys().copied().collect();
        for nsid in nsids {
            let task = crate::sched::task_for_nsid(nsid);
            let port_count = if task.is_null() {
                0
            } else {
                unsafe { dtape_debug_task_port_count(task) }
            };
            let entry = DebugProcess { pid: nsid, port_count };
            unsafe {
                libc::write(wr, &entry as *const _ as *const libc::c_void, std::mem::size_of::<DebugProcess>());
            }
            count += 1;
        }
        unsafe { libc::close(wr) };
        self.reply_fds.push(rd);
        Ok(ReplyDebugListProcesses { process_count: count, fd: 0 })
    }

    /// dserverdbg lsport: enumerate a process's mach ports into a pipe (task #60). Mirrors
    /// Call::DebugListPorts (call.cpp:1112).
    fn debug_list_ports(&mut self, call: &CallDebugListPorts, _fds: &[RawFd]) -> Result<ReplyDebugListPorts, i32> {
        let task = crate::sched::task_for_nsid(call.process);
        if task.is_null() {
            return Err(-libc::ESRCH);
        }
        let mut pipes = [0 as RawFd; 2];
        if unsafe { libc::pipe(pipes.as_mut_ptr()) } < 0 {
            return Err(-std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EMFILE));
        }
        let (rd, wr) = (pipes[0], pipes[1]);
        let count = unsafe {
            dtape_debug_task_list_ports(task, Some(debug_port_writer), &wr as *const RawFd as *mut libc::c_void)
        };
        unsafe { libc::close(wr) };
        self.reply_fds.push(rd);
        Ok(ReplyDebugListPorts { port_count: count, fd: 0 })
    }

    /// dserverdbg lsmember: enumerate a portset's member ports into a pipe (task #60). Mirrors
    /// Call::DebugListMembers (call.cpp:1143).
    fn debug_list_members(&mut self, call: &CallDebugListMembers, _fds: &[RawFd]) -> Result<ReplyDebugListMembers, i32> {
        let task = crate::sched::task_for_nsid(call.process);
        if task.is_null() {
            return Err(-libc::ESRCH);
        }
        let mut pipes = [0 as RawFd; 2];
        if unsafe { libc::pipe(pipes.as_mut_ptr()) } < 0 {
            return Err(-std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EMFILE));
        }
        let (rd, wr) = (pipes[0], pipes[1]);
        let count = unsafe {
            dtape_debug_portset_list_members(task, call.portset, Some(debug_port_writer), &wr as *const RawFd as *mut libc::c_void)
        };
        unsafe { libc::close(wr) };
        self.reply_fds.push(rd);
        Ok(ReplyDebugListMembers { port_count: count, fd: 0 })
    }

    /// dserverdbg lsmsg: enumerate a port's queued messages into a pipe (task #60). Mirrors
    /// Call::DebugListMessages (call.cpp:1174).
    fn debug_list_messages(&mut self, call: &CallDebugListMessages, _fds: &[RawFd]) -> Result<ReplyDebugListMessages, i32> {
        let task = crate::sched::task_for_nsid(call.process);
        if task.is_null() {
            return Err(-libc::ESRCH);
        }
        let mut pipes = [0 as RawFd; 2];
        if unsafe { libc::pipe(pipes.as_mut_ptr()) } < 0 {
            return Err(-std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EMFILE));
        }
        let (rd, wr) = (pipes[0], pipes[1]);
        let count = unsafe {
            dtape_debug_port_list_messages(task, call.port, Some(debug_message_writer), &wr as *const RawFd as *mut libc::c_void)
        };
        unsafe { libc::close(wr) };
        self.reply_fds.push(rd);
        Ok(ReplyDebugListMessages { message_count: count, fd: 0 })
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
