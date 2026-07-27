//! Microthread scheduler + dtape hook layer (Stage 4 foundation).
//!
//! A stackful microthread runs XNU C on the FFI'd P1 fast_context; when that C
//! suspends it (dtape_hooks->thread_suspend, from inside the call stack), we do the
//! getcontext-returns-twice switch back to the worker loop, and resume it later.
//! Both suspend paths (stackful + continuation) were proven in the Stage 3 spike;
//! this is the same logic promoted off `static mut` into thread-local per-worker
//! state so multiple workers and the rest of the daemon can build on it.
//!
//! Single-worker for now (one run loop). The per-worker state (current thread,
//! back-to-top context) is already thread-local; only RUN_QUEUE needs to become a
//! shared Mutex+condvar to go multi-worker.

use crate::bindings::*;
use std::cell::{Cell, RefCell, UnsafeCell};
use std::collections::{HashMap, VecDeque};
use std::mem::MaybeUninit;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicU64, Ordering};

// ---- FFI ----
extern "C" {
    fn dtape_init(hooks: *const dtape_hooks_t);
    // The SECOND init phase (init.c:117). dtape_init (phase 1) only sets up processor/
    // memory/timer/task; the rest -- thread_call_initialize, ipc_thread_call_init,
    // clock_service_create, thread_deallocate_daemon_init, ux_handler_setup, AND
    // dtape_psynch_init -- lives here and MUST run on a kernel microthread (it needs a
    // current-thread context and spawns kernel daemon threads). The C++ daemon does exactly
    // `Thread::kernelSync(dtape_init_in_thread)` after dtape_init (server.cpp:533). Omitting
    // it left psynch's pthread_list_mlock NULL, so the first contended pthread wait crashed.
    fn dtape_init_in_thread();
    fn dtape_task_create(parent: *mut dtape_task_t, nsid: u32, context: *mut c_void, arch: u32) -> *mut dtape_task_t;
    // Bump a task's refcount, so a task_lookup(retain=true) result stays alive for its caller
    // (paired with a dtape_task_release by the caller). duct-tape.h:85.
    fn dtape_task_retain(task: *mut dtape_task_t);
    fn dtape_thread_create(task: *mut dtape_task_t, nsid: u64, context: *mut c_void) -> *mut dtape_thread_t;
    fn dtape_thread_entering(thread: *mut dtape_thread_t);
    fn dtape_thread_exiting(thread: *mut dtape_thread_t);
    // Resolve a guest Mach thread port to its dtape_thread, and recover the void* context we
    // handed dtape_thread_create (our *mut Microthread). Backs thread_for_port. duct-tape.h:71.
    fn dtape_thread_for_port(thread_port: u32) -> *mut dtape_thread_t;
    fn dtape_thread_context(thread: *mut dtape_thread_t) -> *mut c_void;
    // Bump a thread's refcount, so a thread_lookup(retain=true) result stays alive for its
    // caller (paired with the caller's dtape_thread_release). duct-tape.h:77.
    fn dtape_thread_retain(thread: *mut dtape_thread_t);

    fn dserver_fast_getcontext(ucp: *mut libc::ucontext_t) -> c_int;
    fn dserver_fast_setcontext(ucp: *const libc::ucontext_t);
    fn dserver_fast_makecontext(ucp: *mut libc::ucontext_t, func: extern "C" fn(), argc: c_int, ...);

    fn libsimple_lock_unlock(lock: *mut libsimple_lock_t);

    // Invoked when a timer armed via the timer_arm hook expires; wakes any XNU threads
    // whose deadline has passed. May itself briefly wait, so it runs on a kernel microthread.
    fn dtape_timer_fired();
}

const KERNEL_NSID_BASE: u64 = 1 << 22; // DTAPE_KERNEL_THREAD_ID_THRESHOLD
const STACK_SIZE: usize = 512 * 1024;
static NEXT_EID: AtomicU64 = AtomicU64::new(1);
static NEXT_KTID: AtomicU64 = AtomicU64::new(KERNEL_NSID_BASE + 1);

// The daemon's single timerfd (CLOCK_MONOTONIC) + the deadline currently set on it, in
// XNU absolute (monotonic) nanoseconds. The timer_arm hook arms this; the serve loop's
// epoll wakes on it and calls timer_fired(). Single-worker, so plain atomics suffice.
static TIMER_FD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);
static TIMER_DEADLINE: AtomicU64 = AtomicU64::new(0);

/// Create the daemon's timerfd (CLOCK_MONOTONIC, nonblocking) and store it for the
/// timer_arm hook. Returns the fd so the serve loop can add it to its epoll. Mirrors
/// server.cpp's `_timerFD = timerfd_create(...)`.
pub fn init_timer() -> c_int {
    let fd = unsafe { libc::timerfd_create(libc::CLOCK_MONOTONIC, libc::TFD_CLOEXEC | libc::TFD_NONBLOCK) };
    TIMER_FD.store(fd, Ordering::Relaxed);
    fd
}

/// Drain the fired timerfd and deliver the expiry to XNU: run dtape_timer_fired on a fresh
/// kernel microthread (it may briefly wait, so it cannot run on the serve loop directly),
/// then drain any guest threads it woke. Mirrors server.cpp's timerfd handler +
/// `Thread::kernelAsync(dtape_timer_fired)`.
pub unsafe fn timer_fired(kernel_task: *mut dtape_task_t) {
    let fd = TIMER_FD.load(Ordering::Relaxed);
    if fd >= 0 {
        let mut buf = [0u8; 8];
        libc::read(fd, buf.as_mut_ptr() as *mut c_void, 8);
    }
    TIMER_DEADLINE.store(0, Ordering::Relaxed);
    let mt = spawn(kernel_task, Box::new(|| dtape_timer_fired()));
    run(mt);
    if (*mt).is_suspended() {
        // dtape_timer_fired parked (rare); leave it for a later drain to finish.
        schedule(mt);
    } else {
        drop(Box::from_raw(mt));
    }
    drain();
}

/// Run a one-shot operation on a fresh microthread bound to `task`, so the duct-tape sees a
/// current-thread + the task's guest-memory context, then drain anything it wakes. This is the
/// cooperative-yield stand-in for C++'s `impersonate` + `kernelAsync` -- used by the mach-port
/// kqchan modify/read (task #54), which call dtape_kqchan_mach_port_* that need that context.
pub unsafe fn run_on_task(task: *mut dtape_task_t, body: Box<dyn FnOnce()>) {
    let mt = spawn(task, body);
    run(mt);
    if (*mt).is_suspended() {
        // Rare for a kqchan fill/modify (the message is already available); leave it for a later
        // drain to finish rather than dropping a live microthread.
        schedule(mt);
    } else {
        drop(Box::from_raw(mt));
    }
    drain();
}

/// A Rust-owned stackful microthread. Address-stable: always heap-boxed and handed
/// to the C duct-tape as `*mut c_void` context; never moved while C holds it.
pub struct Microthread {
    resume_ctx: MaybeUninit<libc::ucontext_t>,
    stack: Vec<u8>,
    /// A SEPARATE stack for running continuations, so a continuation never clobbers the
    /// main stack that a persistent doWork loop lives on -- what lets the loop survive a
    /// continuation-based blocking call (semaphore_timedwait). C++ runs continuations on
    /// stack-pool stacks for the same reason.
    cont_stack: Vec<u8>,
    /// The doWork loop's re-entry point (captured by `capture_loop_top`). When a call blocks
    /// via a continuation, `thread_syscall_return` setcontexts here (instead of exiting the
    /// microthread) so the loop posts the reply and takes the next call -- C++'s
    /// backToThreadTopContext. `has_loop_top` gates it: one-shot blocking threads (the demos)
    /// keep the exit-to-daemon path.
    loop_top: MaybeUninit<libc::ucontext_t>,
    has_loop_top: bool,
    suspended: bool,
    finished: bool,
    dtape_thread: *mut dtape_thread_t,
    owning_task: *mut dtape_task_t,
    interrupt_disable: u32,
    body: Option<Box<dyn FnOnce()>>,
    pending_cont: Option<(dtape_thread_continuation_callback_f, *mut c_void)>,
    // Set by the current_thread_syscall_return hook: the result a blocking call (e.g. a
    // mach_msg receive that waited) delivered via its continuation instead of returning
    // to the Rust caller. This is what the real daemon would put in the RPC reply.
    syscall_return: Option<i32>,
    // Set by the thread_set_pending_signal hook during dtape_thread_process_signal: the
    // BSD signal the guest should actually deliver (sigprocess returns it).
    pending_signal: i32,
    // The u32 return value of an in-flight BSD trap (psynch retval). A stable per-thread
    // slot -- the handler passes &bsd_retval as the retvalPointer for the fast path, and a
    // blocking psynch op's continuation writes it via the current_thread_set_bsd_retval
    // hook before unix_syscall_return. C++'s Thread::_bsdReturnValue; sendBSDReply pairs it
    // with the syscall's errno code.
    bsd_retval: u32,
    // ---- guest-thread identity (Foundation A) ----
    // Resolved from a Mach thread port via dtape_thread_for_port -> dtape_thread_context
    // (which returns this Microthread), these answer the port-keyed thread calls without a
    // separate registry. The guest tid (nsid) this thread was created with. C++ Thread::_nstid.
    nsid_tid: u64,
    // Set by pthread_markcancel, observed by pthread_canceled. C++ Thread::_canceled.
    canceled: bool,
    // True while this microthread is parked at the top of its doWork loop waiting for the
    // NEXT call (process_one_call's idle wait), false while it is actively dispatching or
    // suspended DEEP inside a handler (a blocked call). The serve loop reads this to tell
    // "ready for a new call" from "blocked mid-call": a signal-interrupt RPC arriving for a
    // mid-call thread must NOT resume the blocked call (that reads a bogus wait_result and
    // panics the duct-tape) -- it runs nested instead. See task #58.
    at_dowork_top: bool,
    // The guest's host-namespace pid (tgkill tgid), -1 until set by spawn_on. For pthread_kill.
    host_pid: libc::pid_t,
    // The guest thread's host tid (tgkill tid), derived lazily via the /proc NSpid scan; -1 =
    // not derived. C++ Thread::_tid.
    host_tid: libc::pid_t,
    // Saved activations for nested signal interrupts (task #58). When a signal interrupts this
    // thread while it is blocked mid-call, push_activation saves the blocked call's live state
    // (stack, resume_ctx, loop_top, ...) here and installs a fresh activation to run the guest's
    // sigexc handler ON THIS SAME microthread (so the blocked call resumes + re-blocks after
    // interrupt_exit, re-setting TH_WAIT, exactly like C++). pop_activation restores it.
    activations: Vec<SavedActivation>,
}

/// One saved microthread activation (the live-field snapshot push_activation stores). The
/// current activation lives in the Microthread's own fields; this is a suspended one beneath it.
struct SavedActivation {
    stack: Vec<u8>,
    cont_stack: Vec<u8>,
    resume_ctx: MaybeUninit<libc::ucontext_t>,
    loop_top: MaybeUninit<libc::ucontext_t>,
    has_loop_top: bool,
    suspended: bool,
    finished: bool,
    pending_cont: Option<(dtape_thread_continuation_callback_f, *mut c_void)>,
    at_dowork_top: bool,
    body: Option<Box<dyn FnOnce()>>,
}

impl Microthread {
    pub fn is_finished(&self) -> bool { self.finished }
    pub fn is_suspended(&self) -> bool { self.suspended }
    pub fn dtape_thread(&self) -> *mut dtape_thread_t { self.dtape_thread }
    /// The pending BSD signal set during signal processing (sigprocess reads this).
    pub fn pending_signal(&self) -> i32 { self.pending_signal }
    /// The in-flight BSD-trap return value (psynch retval). Read after a psynch op to build
    /// its reply body; on a blocking op it is filled by the continuation before the reply.
    pub fn bsd_retval(&self) -> u32 { self.bsd_retval }
    /// A stable pointer to the BSD-trap return slot, for the fast-path `retvalPointer` a
    /// psynch op writes directly. Reset it (via `set_bsd_retval(0)`) before the op so a
    /// stale value never leaks into a reply.
    pub fn bsd_retval_ptr(&mut self) -> *mut u32 { &mut self.bsd_retval }
    /// Set the BSD-trap return value (also used to zero it before a call).
    pub fn set_bsd_retval(&mut self, v: u32) { self.bsd_retval = v; }
    /// The result a blocking call delivered via thread_syscall_return (None if the call
    /// returned normally instead of blocking). Cleared on read.
    pub fn take_syscall_return(&mut self) -> Option<i32> { self.syscall_return.take() }

    /// The guest tid (nsid) this thread was created with. tid_for_thread reports it.
    pub fn nsid_tid(&self) -> u64 { self.nsid_tid }
    /// True if this thread has been marked canceled (pthread_markcancel).
    pub fn is_canceled(&self) -> bool { self.canceled }
    /// Mark this thread canceled (pthread_markcancel); pthread_canceled later observes it.
    pub fn set_canceled(&mut self) { self.canceled = true; }
    /// True while parked at the doWork top waiting for the next call (vs blocked mid-call).
    pub fn is_at_dowork_top(&self) -> bool { self.at_dowork_top }
    /// Set by the doWork loop around its idle wait so the serve loop can tell a ready thread
    /// from one blocked mid-call.
    pub fn set_at_dowork_top(&mut self, v: bool) { self.at_dowork_top = v; }
    /// Save the current activation (the blocked call) and install a FRESH one running `body` --
    /// for a nested signal interrupt on THIS microthread. A later run() enters the fresh
    /// activation; pop_activation restores the blocked call so it resumes + re-blocks. Task #58.
    pub fn push_activation(&mut self, body: Box<dyn FnOnce()>) {
        let saved = SavedActivation {
            stack: std::mem::replace(&mut self.stack, vec![0u8; STACK_SIZE]),
            cont_stack: std::mem::replace(&mut self.cont_stack, vec![0u8; STACK_SIZE]),
            resume_ctx: std::mem::replace(&mut self.resume_ctx, MaybeUninit::uninit()),
            loop_top: std::mem::replace(&mut self.loop_top, MaybeUninit::uninit()),
            has_loop_top: self.has_loop_top,
            suspended: self.suspended,
            finished: self.finished,
            pending_cont: self.pending_cont.take(),
            at_dowork_top: self.at_dowork_top,
            body: self.body.take(),
        };
        self.activations.push(saved);
        self.has_loop_top = false;
        self.suspended = false;
        self.finished = false;
        self.at_dowork_top = false;
        self.body = Some(body);
    }
    /// Restore the activation saved by the matching push_activation. Task #58.
    pub fn pop_activation(&mut self) {
        let saved = self.activations.pop().expect("pop_activation with empty activation stack");
        self.stack = saved.stack;
        self.cont_stack = saved.cont_stack;
        self.resume_ctx = saved.resume_ctx;
        self.loop_top = saved.loop_top;
        self.has_loop_top = saved.has_loop_top;
        self.suspended = saved.suspended;
        self.finished = saved.finished;
        self.pending_cont = saved.pending_cont;
        self.at_dowork_top = saved.at_dowork_top;
        self.body = saved.body;
    }
    /// Whether a nested-interrupt activation is currently pushed on this microthread.
    pub fn has_saved_activation(&self) -> bool { !self.activations.is_empty() }
    /// The dtape_thread this microthread runs on (for a nested interrupt sharing it).
    pub fn dtape_thread_ptr(&self) -> *mut dtape_thread_t { self.dtape_thread }
    /// The task this microthread is bound to (for spawning a nested interrupt on the same task).
    pub fn owning_task_ptr(&self) -> *mut dtape_task_t { self.owning_task }
    /// The guest's host-namespace pid (tgkill target group), or -1 if unknown.
    pub fn host_pid(&self) -> libc::pid_t { self.host_pid }
    /// Bind the host pid discovered when this guest thread first checked in (set by spawn_on).
    pub fn set_host_pid(&mut self, host_pid: libc::pid_t) { self.host_pid = host_pid; }
    /// The guest thread's host tid (tgkill target), derived + cached lazily via the /proc NSpid
    /// scan the first time it is needed. -1 if it cannot be resolved.
    pub fn host_tid(&mut self) -> libc::pid_t {
        if self.host_tid <= 0 {
            self.host_tid = derive_host_tid(self.host_pid, self.nsid_tid);
        }
        self.host_tid
    }
}

/// Find the host tid of the guest thread whose innermost-namespace tid is `nsid_tid`, by
/// scanning /proc/<host_pid>/task/*/status for the matching NSpid (last field). The task dir
/// name is the host tid. Mirrors the C++ Thread ctor (thread.cpp:104-131). -1 if not found.
fn derive_host_tid(host_pid: libc::pid_t, nsid_tid: u64) -> libc::pid_t {
    if host_pid <= 0 {
        return -1;
    }
    let entries = match std::fs::read_dir(format!("/proc/{host_pid}/task")) {
        Ok(e) => e,
        Err(_) => return -1,
    };
    for entry in entries.flatten() {
        let host_tid: libc::pid_t = match entry.file_name().to_str().and_then(|s| s.parse().ok()) {
            Some(n) => n,
            None => continue,
        };
        let status = match std::fs::read_to_string(entry.path().join("status")) {
            Ok(s) => s,
            Err(_) => continue,
        };
        for line in status.lines() {
            if let Some(rest) = line.strip_prefix("NSpid:") {
                if rest.split_whitespace().last().and_then(|s| s.parse::<u64>().ok()) == Some(nsid_tid) {
                    return host_tid;
                }
            }
        }
    }
    -1
}

/// Create a microthread that SHARES an existing `dtape_thread` (rather than creating a fresh
/// one), for running a signal interrupt nested on the blocked thread's own XNU thread while
/// that thread's doWork microthread stays suspended mid-call. Because it shares the
/// dtape_thread, reaping it must NOT tear the thread down (no dtape_thread_dying). Mirrors the
/// nesting in C++ Thread::doWork, where the interrupt runs on the same _dtapeThread. See #58.
pub unsafe fn spawn_sharing_dtape(task: *mut dtape_task_t, dtape_thread: *mut dtape_thread_t, nsid: u64, body: Box<dyn FnOnce()>) -> *mut Microthread {
    let mt = Box::into_raw(Box::new(Microthread {
        resume_ctx: MaybeUninit::uninit(),
        stack: vec![0u8; STACK_SIZE],
        cont_stack: vec![0u8; STACK_SIZE],
        loop_top: MaybeUninit::uninit(),
        has_loop_top: false,
        suspended: false,
        finished: false,
        dtape_thread,
        owning_task: task,
        interrupt_disable: 0,
        body: Some(body),
        pending_cont: None,
        syscall_return: None,
        pending_signal: 0,
        bsd_retval: 0,
        nsid_tid: nsid,
        canceled: false,
        at_dowork_top: false,
        host_pid: -1,
        host_tid: -1,
        activations: Vec::new(),
    }));
    // NOTE: no dtape_thread_create -- we deliberately reuse the caller's dtape_thread.
    mt
}

/// Resolve a guest Mach thread port to its Microthread, via the duct-tape port registry
/// (dtape_thread_for_port) and the context stored at dtape_thread_create. Returns None for an
/// invalid or dead port. Mirrors C++ Thread::threadForPort (thread.cpp:916).
pub unsafe fn thread_for_port(thread_port: u32) -> Option<*mut Microthread> {
    let dt = dtape_thread_for_port(thread_port);
    if dt.is_null() {
        return None;
    }
    let ctx = dtape_thread_context(dt);
    if ctx.is_null() {
        return None;
    }
    Some(ctx as *mut Microthread)
}

// ---- per-worker (per-OS-thread) state ----
thread_local! {
    static BACK_TO_TOP: UnsafeCell<MaybeUninit<libc::ucontext_t>> = UnsafeCell::new(MaybeUninit::uninit());
    static RETURNING: Cell<bool> = const { Cell::new(false) };
    static CURRENT: Cell<*mut Microthread> = const { Cell::new(std::ptr::null_mut()) };
    // Shared work queue -> Mutex+condvar when this goes multi-worker.
    static RUN_QUEUE: RefCell<VecDeque<*mut Microthread>> = const { RefCell::new(VecDeque::new()) };
    // nsid -> (dtape_task, host_pid), so the static task_lookup dtape hook can resolve a task
    // by id without reaching the serve-loop-local Registry. Populated by registry::ensure_task
    // (single worker, so same thread as the hook). Tasks are currently leak-lived (task #52),
    // so an entry stays valid for the daemon's life: a lookup after the process exits returns a
    // leaked-but-valid pointer, never a dangling one. Mirrors C++ processRegistry() lookups.
    static TASK_BY_NSID: RefCell<HashMap<u32, (*mut dtape_task_t, libc::pid_t)>> = RefCell::new(HashMap::new());
    // guest tid (nsid) -> dtape_thread, for the thread_lookup dtape hook. Populated per guest
    // thread by registry::spawn_on, removed on death (dtape_thread_dying). Like the task table,
    // dtape_threads are currently leak-lived (the daemon never dtape_thread_release's them), so
    // even a stale entry is a valid pointer, never dangling. Mirrors C++ threadRegistry().
    static THREAD_BY_TID: RefCell<HashMap<u64, *mut dtape_thread_t>> = RefCell::new(HashMap::new());
}

/// Record a guest task in the task_lookup table (called once per task from ensure_task).
pub fn register_task_lookup(nsid: u32, task: *mut dtape_task_t, host_pid: libc::pid_t) {
    TASK_BY_NSID.with(|m| m.borrow_mut().insert(nsid, (task, host_pid)));
}

/// Resolve a task by guest nsid for the RPC handlers (ptrace targets another process), null if
/// unknown. The handler-facing counterpart of the task_lookup dtape hook.
pub fn task_for_nsid(nsid: u32) -> *mut dtape_task_t {
    TASK_BY_NSID.with(|m| m.borrow().get(&nsid).map(|&(t, _)| t).unwrap_or(std::ptr::null_mut()))
}

/// Record a guest thread in the thread_lookup table (called once per guest thread by spawn_on).
pub fn register_thread_lookup(tid: u64, thread: *mut dtape_thread_t) {
    THREAD_BY_TID.with(|m| m.borrow_mut().insert(tid, thread));
}

/// Remove a thread from the thread_lookup table by its dtape_thread pointer (on death, so a
/// later lookup of the dead thread returns null). Called from thread::dying.
pub fn unregister_thread_lookup(thread: *mut dtape_thread_t) {
    THREAD_BY_TID.with(|m| m.borrow_mut().retain(|_, &mut t| t != thread));
}

fn back_to_top_ptr() -> *mut libc::ucontext_t {
    BACK_TO_TOP.with(|c| unsafe { (*c.get()).as_mut_ptr() })
}
/// The microthread the current worker is running (null between microthreads).
pub fn current() -> *mut Microthread {
    CURRENT.with(|c| c.get())
}

/// The task the currently-running microthread is bound to -- the routing key. A
/// handler calls this to operate on its guest's task without capturing it.
pub fn current_task() -> *mut dtape_task_t {
    let mt = current();
    if mt.is_null() { std::ptr::null_mut() } else { unsafe { (*mt).owning_task } }
}

/// The running microthread's BSD-trap return value (psynch retval), or 0 if none. The
/// doWork loop reads this when a continuation-based psynch op re-enters, to pair with the
/// deferred reply's errno code.
pub fn current_bsd_retval() -> u32 {
    let mt = current();
    if mt.is_null() { 0 } else { unsafe { (*mt).bsd_retval() } }
}

/// Run a persistent doWork loop for the current microthread: the C++ `Thread::doWork`.
/// `step` does one unit of work and returns false to stop; it is passed the result of a
/// continuation-based blocking call that just re-entered (Some(code)), or None on a normal
/// pass. The loop's getcontext (the re-entry target, C++'s backToThreadTopContext) lives in
/// THIS function's frame, which persists for the microthread's whole life -- so a
/// thread_syscall_return that setcontexts back to it lands on a valid stack (unlike a
/// getcontext in a helper that returns, whose frame gets reused). `step` must itself keep
/// no drop-requiring locals across a block; delegating per-call work to a separate function
/// ensures that. Never returns until `step` says stop (the microthread then exits).
pub unsafe fn run_dowork_loop(mut step: impl FnMut(Option<i32>) -> bool) {
    let mt = current();
    if mt.is_null() {
        return;
    }
    (*mt).has_loop_top = true;
    loop {
        // Inline getcontext in this persistent frame: returns on the first pass AND each
        // time a continuation-based block re-enters here via setcontext(loop_top).
        dserver_fast_getcontext((*mt).loop_top.as_mut_ptr());
        let sr = (*mt).take_syscall_return();
        if !step(sr) {
            break;
        }
    }
}

/// Create a microthread on `task` with an explicit thread namespace id, backed by a
/// fresh dtape_thread. Use a guest tid for guest threads, or a kernel id (>= 1<<22)
/// for daemon-internal work.
pub unsafe fn spawn_with_nsid(task: *mut dtape_task_t, nsid: u64, body: Box<dyn FnOnce()>) -> *mut Microthread {
    let mt = Box::into_raw(Box::new(Microthread {
        resume_ctx: MaybeUninit::uninit(),
        stack: vec![0u8; STACK_SIZE],
        cont_stack: vec![0u8; STACK_SIZE],
        loop_top: MaybeUninit::uninit(),
        has_loop_top: false,
        suspended: false,
        finished: false,
        dtape_thread: std::ptr::null_mut(),
        owning_task: task,
        interrupt_disable: 0,
        body: Some(body),
        pending_cont: None,
        syscall_return: None,
        pending_signal: 0,
        bsd_retval: 0,
        nsid_tid: nsid,
        canceled: false,
        at_dowork_top: false,
        host_pid: -1,
        host_tid: -1,
        activations: Vec::new(),
    }));
    (*mt).dtape_thread = dtape_thread_create(task, nsid, mt as *mut c_void);
    mt
}

/// Create a kernel microthread (auto kernel-range nsid) with the given body.
pub unsafe fn spawn(task: *mut dtape_task_t, body: Box<dyn FnOnce()>) -> *mut Microthread {
    spawn_with_nsid(task, NEXT_KTID.fetch_add(1, Ordering::Relaxed), body)
}

/// Queue a microthread to be (re)entered by the run loop. Called by thread_resume.
pub fn schedule(mt: *mut Microthread) {
    RUN_QUEUE.with(|q| q.borrow_mut().push_back(mt));
}

/// Run every queued microthread until the queue drains.
pub unsafe fn drain() {
    loop {
        let next = RUN_QUEUE.with(|q| q.borrow_mut().pop_front());
        match next {
            Some(mt) => run(mt),
            None => break,
        }
    }
}

unsafe fn setup_fresh_stack(mt: *mut Microthread, trampoline: extern "C" fn(), on_cont_stack: bool) {
    let uc = (*mt).resume_ctx.as_mut_ptr();
    dserver_fast_getcontext(uc);
    // Continuations run on cont_stack so they never clobber the main stack a doWork loop
    // lives on; the first entry (body) runs on the main stack.
    let stack = if on_cont_stack { &mut (*mt).cont_stack } else { &mut (*mt).stack };
    (*uc).uc_stack.ss_sp = stack.as_mut_ptr() as *mut c_void;
    (*uc).uc_stack.ss_size = stack.len();
    (*uc).uc_link = back_to_top_ptr();
    dserver_fast_makecontext(uc, trampoline, 0);
}

/// Enter (first time) or resume a microthread -- the getcontext(BACK_TO_TOP)-
/// returns-twice worker loop (port of Thread::doWork).
pub unsafe fn run(mt: *mut Microthread) {
    CURRENT.with(|c| c.set(mt));
    dtape_thread_entering((*mt).dtape_thread);

    RETURNING.with(|r| r.set(false));
    dserver_fast_getcontext(back_to_top_ptr()); // returns twice

    if RETURNING.with(|r| r.get()) {
        // the microthread jumped back: suspended or finished
        if !(*mt).suspended {
            (*mt).finished = true;
        }
        dtape_thread_exiting((*mt).dtape_thread);
        CURRENT.with(|c| c.set(std::ptr::null_mut()));
        return;
    }
    RETURNING.with(|r| r.set(true));

    if (*mt).suspended {
        (*mt).suspended = false;
        if (*mt).pending_cont.is_some() {
            setup_fresh_stack(mt, continuation_trampoline, true); // continuation on the cont stack
        } else {
            dserver_fast_setcontext((*mt).resume_ctx.as_ptr()); // stackful resume
            unreachable!("setcontext returned");
        }
        dserver_fast_setcontext((*mt).resume_ctx.as_ptr());
        unreachable!("setcontext returned");
    } else {
        setup_fresh_stack(mt, body_trampoline, false); // first entry on the main stack
        dserver_fast_setcontext((*mt).resume_ctx.as_ptr());
        unreachable!("setcontext returned");
    }
}

/// Suspend the current microthread (called from the thread_suspend hook, i.e. from
/// inside a C/XNU call stack). Stackful when `cont` is None; otherwise the current
/// stack is discarded and `cont` runs on a fresh stack on resume.
pub unsafe fn suspend_current(cont: dtape_thread_continuation_callback_f, cont_ctx: *mut c_void, unlock_me: *mut libsimple_lock_t) {
    let mt = current();
    (*mt).suspended = true;
    if !unlock_me.is_null() {
        libsimple_lock_unlock(unlock_me);
    }
    if cont.is_some() {
        (*mt).pending_cont = Some((cont, cont_ctx));
        dserver_fast_setcontext(back_to_top_ptr());
        unreachable!("setcontext returned");
    }
    dserver_fast_getcontext((*mt).resume_ctx.as_mut_ptr()); // returns twice
    if (*mt).suspended {
        dserver_fast_setcontext(back_to_top_ptr());
        unreachable!("setcontext returned");
    }
    // resumed -> fall through; the C caller continues
}

extern "C" fn body_trampoline() {
    unsafe {
        let mt = current();
        if let Some(body) = (*mt).body.take() {
            body();
        }
    }
}
extern "C" fn continuation_trampoline() {
    unsafe {
        let mt = current();
        if let Some((cb, ctx)) = (*mt).pending_cont.take() {
            if let Some(cb) = cb {
                cb(ctx);
            }
        }
    }
}

// ---- guest memory access (the foundation mach_msg copyin/copyout depends on) ----

/// Per-guest-task context handed to the duct-tape as the task's `void*` context (the
/// 3rd arg of dtape_task_create) and handed back to the memory hooks. Carries the
/// guest's host-visible Linux pid -- what process_vm_readv/writev key on. The Registry
/// heap-boxes it so the pointer stays address-stable while C holds it.
#[repr(C)]
pub struct TaskCtx {
    pub pid: libc::pid_t,
}

/// The start address of the first /proc/<pid>/maps region strictly above `addr`, or 0 if
/// none. The map is sorted ascending, so the first line whose start > addr is the answer.
/// Each line begins "start-end perms ..."; only the start (hex) is needed. Pure host-side.
fn next_region_after(pid: libc::pid_t, addr: usize) -> usize {
    let maps = match std::fs::read_to_string(format!("/proc/{pid}/maps")) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    for line in maps.lines() {
        if let Some(start) = line.split('-').next().and_then(|h| usize::from_str_radix(h, 16).ok()) {
            if start > addr {
                return start;
            }
        }
    }
    0
}

/// Read `local.len()` bytes from process `pid`'s address space at `remote_address`,
/// via process_vm_readv -- the exact primitive DarlingServer::Process uses
/// (process.cpp). Pure host-side, no guest cooperation. Returns false unless the whole
/// range transfers.
pub unsafe fn read_process_memory(pid: libc::pid_t, remote_address: usize, local: &mut [u8]) -> bool {
    if local.is_empty() {
        return true;
    }
    let liov = libc::iovec { iov_base: local.as_mut_ptr() as *mut c_void, iov_len: local.len() };
    let riov = libc::iovec { iov_base: remote_address as *mut c_void, iov_len: local.len() };
    let n = libc::process_vm_readv(pid, &liov, 1, &riov, 1, 0);
    n >= 0 && n as usize == local.len()
}

/// Write `local` into process `pid`'s address space at `remote_address`, via
/// process_vm_writev. Mirror of read_process_memory.
pub unsafe fn write_process_memory(pid: libc::pid_t, remote_address: usize, local: &[u8]) -> bool {
    if local.is_empty() {
        return true;
    }
    let liov = libc::iovec { iov_base: local.as_ptr() as *mut c_void, iov_len: local.len() };
    let riov = libc::iovec { iov_base: remote_address as *mut c_void, iov_len: local.len() };
    let n = libc::process_vm_writev(pid, &liov, 1, &riov, 1, 0);
    n >= 0 && n as usize == local.len()
}

/// dtape hook: read `length` bytes from the task's guest process at `remote_address`
/// into `local_buffer`. Recovers the guest pid from the TaskCtx the task was created
/// with. Mirrors DarlingServer::Process::readMemory (server.cpp dtape_hook_task_read_memory).
pub unsafe extern "C" fn task_read_memory(task_context: *mut c_void, remote_address: usize, local_buffer: *mut c_void, length: usize) -> bool {
    if task_context.is_null() || local_buffer.is_null() {
        return false;
    }
    let pid = (*(task_context as *const TaskCtx)).pid;
    let local = std::slice::from_raw_parts_mut(local_buffer as *mut u8, length);
    read_process_memory(pid, remote_address, local)
}

/// dtape hook: write `length` bytes from `local_buffer` into the task's guest process
/// at `remote_address`. Mirror of task_read_memory.
pub unsafe extern "C" fn task_write_memory(task_context: *mut c_void, remote_address: usize, local_buffer: *const c_void, length: usize) -> bool {
    if task_context.is_null() || local_buffer.is_null() {
        return false;
    }
    let pid = (*(task_context as *const TaskCtx)).pid;
    let local = std::slice::from_raw_parts(local_buffer as *const u8, length);
    write_process_memory(pid, remote_address, local)
}

// ---- dtape hooks (the 36-field vtable the duct-tape calls back through) ----
mod hooks {
    use super::*;
    use std::os::raw::c_char;

    pub(super) static mut KERNEL_TASK: *mut dtape_task_t = std::ptr::null_mut();

    pub(super) unsafe extern "C" fn log(_l: dtape_log_level_t, m: *const c_char) {
        if !m.is_null() {
            eprintln!("[dtape] {}", std::ffi::CStr::from_ptr(m).to_string_lossy());
        }
    }
    pub(super) unsafe extern "C" fn current_task() -> *mut dtape_task_t {
        let mt = current();
        if mt.is_null() { KERNEL_TASK } else { (*mt).owning_task }
    }
    pub(super) unsafe extern "C" fn current_thread() -> *mut dtape_thread_t {
        let mt = current();
        if mt.is_null() { std::ptr::null_mut() } else { (*mt).dtape_thread }
    }
    pub(super) unsafe extern "C" fn thread_suspend(ctx: *mut c_void, cont: dtape_thread_continuation_callback_f, cont_ctx: *mut c_void, unlock_me: *mut libsimple_lock_t) {
        debug_assert_eq!(ctx, current() as *mut c_void, "suspend of non-current thread");
        suspend_current(cont, cont_ctx, unlock_me);
    }
    pub(super) unsafe extern "C" fn thread_resume(ctx: *mut c_void) { schedule(ctx as *mut Microthread); }
    /// Create a kernel microthread (no body yet -- thread_setup installs it, thread_resume
    /// schedules it). Used by dtape_init_in_thread + the kernel daemons (thread_call, etc.).
    /// The microthread is leaked; the dtape side owns its lifecycle via thread_terminate.
    /// Mirrors C++ dtape_hook_thread_create_kernel.
    pub(super) unsafe extern "C" fn thread_create_kernel() -> *mut dtape_thread_t {
        let mt = spawn(KERNEL_TASK, Box::new(|| {}));
        (*mt).dtape_thread
    }
    /// Install a kernel thread's startup body: when scheduled, it runs `cb(cb_ctx)`. Mirrors
    /// C++ dtape_hook_thread_setup (setupKernelThread). `ctx` is the microthread pointer.
    pub(super) unsafe extern "C" fn thread_setup(ctx: *mut c_void, cb: dtape_thread_continuation_callback_f, cb_ctx: *mut c_void) {
        if ctx.is_null() {
            return;
        }
        let mt = ctx as *mut Microthread;
        (*mt).body = Some(Box::new(move || {
            if let Some(f) = cb {
                f(cb_ctx);
            }
        }));
    }
    /// dtape_thread_process_signal calls this with the BSD signal the guest should deliver;
    /// record it on the microthread (sigprocess returns it).
    pub(super) unsafe extern "C" fn thread_set_pending_signal(ctx: *mut c_void, sig: c_int) {
        if !ctx.is_null() { (*(ctx as *mut Microthread)).pending_signal = sig; }
    }
    /// current_thread_set_bsd_retval (libpthread's uthread_set_returnval): the u32 return
    /// value the guest's BSD syscall should see. A blocking psynch op's continuation
    /// (psynch_mtxcontinue &c.) calls this before unix_syscall_return, so the deferred reply
    /// carries the retval; store it on the current microthread.
    pub(super) unsafe extern "C" fn current_thread_set_bsd_retval(retval: u32) {
        let mt = current();
        if !mt.is_null() { (*mt).bsd_retval = retval; }
    }
    pub(super) unsafe extern "C" fn thread_context_dispose(_ctx: *mut c_void) {}
    pub(super) unsafe extern "C" fn thread_terminate(_ctx: *mut c_void) {}

    // ---- Lookups, thread introspection, and the S2C VM hooks. These were all left NULL,
    // and a NULL dtape hook is an indirect-call-to-0 -> SIGSEGV the moment any guest
    // exercises it (e.g. `hostinfo` -> host statistics). Wire safe defaults so no hook is
    // ever NULL: lookups report "not found" (null), the S2C VM ops (allocate/free/map/
    // protect/sync -- the daemon-delegates-to-guest path, not yet implemented) report
    // failure, and memory introspection returns empty. Real impls arrive with a global
    // thread/task registry (lookups) and s2c (VM). Mirrors the C++ DTapeHooks set. ----
    pub(super) unsafe extern "C" fn thread_set_pending_call_override(_ctx: *mut c_void, _o: bool) {}
    /// Resolve a guest thread by its nsid (tid), returning the dtape_thread (retained if asked,
    /// so it outlives the lookup for its caller). null if unknown. Lookup by host tid
    /// (`is_nsid == false`) is not supported (the daemon does not track host tids) and returns
    /// null. Mirrors C++ dtape_hook_thread_lookup -> threadRegistry().lookupEntryByNSID
    /// (server.cpp:173).
    pub(super) unsafe extern "C" fn thread_lookup(id: c_int, is_nsid: bool, retain: bool) -> *mut dtape_thread_t {
        if !is_nsid {
            return std::ptr::null_mut();
        }
        let thread = THREAD_BY_TID.with(|m| m.borrow().get(&(id as u64)).copied());
        match thread {
            Some(t) if !t.is_null() => {
                if retain {
                    dtape_thread_retain(t);
                }
                t
            }
            _ => std::ptr::null_mut(),
        }
    }
    pub(super) unsafe extern "C" fn thread_lookup_eternal(_eid: dtape_eternal_id_t, _retain: bool) -> *mut dtape_thread_t {
        std::ptr::null_mut()
    }
    pub(super) unsafe extern "C" fn thread_get_state(_ctx: *mut c_void) -> dtape_thread_state_t {
        dtape_thread_state::dtape_thread_state_running
    }
    pub(super) unsafe extern "C" fn thread_send_signal(_ctx: *mut c_void, _sig: c_int) -> c_int {
        0
    }
    /// Resolve a task by its guest nsid (`is_nsid`) or its host pid, returning the dtape_task
    /// (retained if asked, so it outlives the lookup for its caller). null if unknown. Mirrors
    /// C++ dtape_hook_task_lookup -> processRegistry().lookupEntryByNSID/ByID (server.cpp:247).
    pub(super) unsafe extern "C" fn task_lookup(id: c_int, is_nsid: bool, retain: bool) -> *mut dtape_task_t {
        let task = TASK_BY_NSID.with(|m| {
            let m = m.borrow();
            if is_nsid {
                m.get(&(id as u32)).map(|&(t, _)| t)
            } else {
                m.values().find(|&&(_, hp)| hp == id as libc::pid_t).map(|&(t, _)| t)
            }
        });
        match task {
            Some(t) if !t.is_null() => {
                if retain {
                    dtape_task_retain(t);
                }
                t
            }
            _ => std::ptr::null_mut(),
        }
    }
    pub(super) unsafe extern "C" fn task_lookup_eternal(_eid: dtape_eternal_id_t, _retain: bool) -> *mut dtape_task_t {
        std::ptr::null_mut()
    }
    pub(super) unsafe extern "C" fn task_get_memory_info(_ctx: *mut c_void, info: *mut dtape_memory_info_t) {
        if !info.is_null() {
            (*info).virtual_size = 0;
            (*info).resident_size = 0;
            (*info).page_size = 4096;
            (*info).region_count = 0;
        }
    }
    pub(super) unsafe extern "C" fn task_get_memory_region_info(_ctx: *mut c_void, _addr: usize, _info: *mut dtape_memory_region_info_t) -> bool {
        false
    }
    /// Allocate `pages` in the guest's address space via an S2C mmap (the guest does the
    /// mmap on our behalf). dtape memory protections (read=1/write=2/exec=4) match PROT_*,
    /// and the memory flags carry fixed/overwrite. Returns the guest address, or 0 on
    /// failure (MAP_FAILED). Mirrors C++ Process/Thread::allocatePages.
    pub(super) unsafe extern "C" fn task_allocate_pages(_ctx: *mut c_void, pages: usize, prot: c_int, hint: usize, flags: dtape_memory_flags_t) -> usize {
        let flags_u = flags as u32; // dtape_memory_flags is repr(u32); may be a fixed|overwrite bitfield
        let fixed = (flags_u & 1) != 0; // dtape_memory_flag_fixed
        let overwrite = (flags_u & 2) != 0; // dtape_memory_flag_overwrite
        let length = pages.saturating_mul(4096);
        let (addr, err) = crate::s2c::perform_mmap(hint, length, prot, crate::s2c::mmap_flags(fixed, overwrite), -1, 0);
        if err != 0 || addr == usize::MAX {
            0
        } else {
            addr
        }
    }
    /// Free `pages` in the guest's address space via an S2C munmap (the guest does the munmap
    /// on our behalf, like task_allocate_pages does for mmap). Returns 0 on success, else a
    /// negative errno. Mirrors C++ Process/Thread::freePages.
    pub(super) unsafe extern "C" fn task_free_pages(_ctx: *mut c_void, addr: usize, pages: usize) -> c_int {
        let length = pages.saturating_mul(4096);
        let (rv, err) = crate::s2c::perform_munmap(addr, length);
        if rv == 0 { 0 } else { -err }
    }
    /// Map a real file (the daemon-side `fd`) into the guest's address space via S2C: the
    /// daemon passes a dup of the fd to the guest, which mmaps it. File mappings are MAP_SHARED
    /// (not the anonymous MAP_PRIVATE of task_allocate_pages). Returns the mapped address, or 0
    /// on failure. Mirrors C++ Thread::mapFile (thread.cpp) + Process::mapFile.
    pub(super) unsafe extern "C" fn task_map_file(_ctx: *mut c_void, fd: c_int, pages: usize, prot: c_int, hint: usize, page_offset: usize, flags: dtape_memory_flags_t) -> usize {
        let flags_u = flags as u32;
        let fixed = (flags_u & 1) != 0; // dtape_memory_flag_fixed
        let overwrite = (flags_u & 2) != 0; // dtape_memory_flag_overwrite
        let mut mflags = libc::MAP_SHARED;
        if fixed && overwrite {
            mflags |= libc::MAP_FIXED;
        } else if fixed {
            mflags |= 0x100000; // MAP_FIXED_NOREPLACE (libc may not name it here)
        }
        let length = pages.saturating_mul(4096);
        let offset = page_offset.saturating_mul(4096) as i64;
        let (addr, _err) = crate::s2c::perform_map_file(hint, length, prot, mflags, fd, offset);
        if addr == usize::MAX {
            0
        } else {
            addr
        }
    }
    /// Return the start of the first mapped region strictly above `addr` in the guest's
    /// address space (0 if none). Pure host-side: parse /proc/<host_pid>/maps, which is sorted
    /// ascending, and take the first region whose start > addr. Mirrors C++
    /// Process::getNextRegion (process.cpp:662); backs mach_vm_region[_recurse] introspection.
    pub(super) unsafe extern "C" fn task_get_next_region(ctx: *mut c_void, addr: usize) -> usize {
        if ctx.is_null() {
            return 0;
        }
        let pid = (*(ctx as *const TaskCtx)).pid;
        next_region_after(pid, addr)
    }
    /// Change the protection of `pages` in the guest's address space via an S2C mprotect.
    /// Returns true on success. Mirrors C++ Process/Thread::changeProtection.
    pub(super) unsafe extern "C" fn task_change_protection(_ctx: *mut c_void, addr: usize, pages: usize, prot: c_int) -> bool {
        let length = pages.saturating_mul(4096);
        let (rv, _err) = crate::s2c::perform_mprotect(addr, length, prot);
        rv == 0
    }
    /// Flush `size` bytes of the guest's address space to backing store via an S2C msync.
    /// Returns true on success. Mirrors C++ Process/Thread::syncMemory.
    pub(super) unsafe extern "C" fn task_sync_memory(_ctx: *mut c_void, addr: usize, size: usize, flags: c_int) -> bool {
        let (rv, _err) = crate::s2c::perform_msync(addr, size, flags);
        rv == 0
    }
    pub(super) unsafe extern "C" fn task_context_dispose(_ctx: *mut c_void) {}
    pub(super) unsafe extern "C" fn interrupt_disable() {
        let mt = current();
        if !mt.is_null() { (*mt).interrupt_disable += 1; }
    }
    pub(super) unsafe extern "C" fn interrupt_enable() {
        let mt = current();
        if !mt.is_null() && (*mt).interrupt_disable > 0 { (*mt).interrupt_disable -= 1; }
    }
    /// thread_syscall_return: a blocking call finished via its continuation (the stack
    /// was discarded when it blocked, so it can't return to the Rust caller). Record the
    /// result -- what the real daemon puts in the RPC reply -- and jump back to the
    /// daemon (the run() top); the microthread is left suspended, its call complete.
    /// thread_syscall_return is noreturn in XNU, so this never returns to its caller.
    pub(super) unsafe extern "C" fn syscall_return(code: c_int) {
        let mt = current();
        if !mt.is_null() {
            (*mt).syscall_return = Some(code);
            if (*mt).has_loop_top {
                // A persistent doWork loop is running: return to its top (on the preserved
                // main stack -- the continuation ran on cont_stack) so it posts this call's
                // reply and takes the next call, instead of exiting the microthread.
                dserver_fast_setcontext((*mt).loop_top.as_ptr());
                unreachable!("setcontext to loop_top returned");
            }
            (*mt).suspended = true;
        }
        dserver_fast_setcontext(back_to_top_ptr());
        unreachable!("thread_syscall_return did not transfer control back to the daemon");
    }
    pub(super) unsafe extern "C" fn task_eternal_id(_c: *mut c_void) -> dtape_eternal_id_t { NEXT_EID.fetch_add(1, Ordering::Relaxed) }
    pub(super) unsafe extern "C" fn thread_eternal_id(_c: *mut c_void) -> dtape_eternal_id_t { NEXT_EID.fetch_add(1, Ordering::Relaxed) }
    pub(super) unsafe extern "C" fn get_load_info(li: *mut dtape_load_info_t) {
        if !li.is_null() { (*li).task_count = 0; (*li).thread_count = 0; }
    }
    /// Arm (or, with a 0/UINT64_MAX deadline, disarm) the daemon timerfd for the XNU timer
    /// subsystem. `override_` forces the deadline even if it is later than the current one;
    /// otherwise a later deadline than the one already set is ignored (we keep the nearest).
    /// Mirrors server.cpp's dtape_hook_timer_arm.
    pub(super) unsafe extern "C" fn timer_arm(deadline_ns: u64, override_: bool) {
        let mut deadline = deadline_ns;
        if deadline == u64::MAX {
            deadline = 0;
        }
        let fd = super::TIMER_FD.load(super::Ordering::Relaxed);
        if fd < 0 {
            return;
        }
        let current = super::TIMER_DEADLINE.load(super::Ordering::Relaxed);
        if !override_ && current != 0 && deadline >= current {
            return;
        }
        super::TIMER_DEADLINE.store(deadline, super::Ordering::Relaxed);
        // it_value = 0 disarms; a nonzero absolute deadline arms (TFD_TIMER_ABSTIME).
        let spec = libc::itimerspec {
            it_interval: libc::timespec { tv_sec: 0, tv_nsec: 0 },
            it_value: libc::timespec {
                tv_sec: (deadline / 1_000_000_000) as libc::time_t,
                tv_nsec: (deadline % 1_000_000_000) as i64,
            },
        };
        libc::timerfd_settime(fd, libc::TFD_TIMER_ABSTIME, &spec, std::ptr::null_mut());
    }
}

fn make_hooks() -> dtape_hooks_t {
    let mut h: dtape_hooks_t = unsafe { std::mem::zeroed() };
    h.log = Some(hooks::log);
    h.current_task = Some(hooks::current_task);
    h.current_thread = Some(hooks::current_thread);
    h.thread_suspend = Some(hooks::thread_suspend);
    h.thread_resume = Some(hooks::thread_resume);
    h.thread_create_kernel = Some(hooks::thread_create_kernel);
    h.thread_setup = Some(hooks::thread_setup);
    // Lookups + introspection + S2C VM hooks (safe defaults; see the hooks module) -- wired
    // so no dtape hook is ever NULL (a NULL hook is an indirect-call-to-0 crash).
    h.thread_set_pending_call_override = Some(hooks::thread_set_pending_call_override);
    h.thread_lookup = Some(hooks::thread_lookup);
    h.thread_lookup_eternal = Some(hooks::thread_lookup_eternal);
    h.thread_get_state = Some(hooks::thread_get_state);
    h.thread_send_signal = Some(hooks::thread_send_signal);
    h.task_lookup = Some(hooks::task_lookup);
    h.task_lookup_eternal = Some(hooks::task_lookup_eternal);
    h.task_get_memory_info = Some(hooks::task_get_memory_info);
    h.task_get_memory_region_info = Some(hooks::task_get_memory_region_info);
    h.task_allocate_pages = Some(hooks::task_allocate_pages);
    h.task_free_pages = Some(hooks::task_free_pages);
    h.task_map_file = Some(hooks::task_map_file);
    h.task_get_next_region = Some(hooks::task_get_next_region);
    h.task_change_protection = Some(hooks::task_change_protection);
    h.task_sync_memory = Some(hooks::task_sync_memory);
    h.task_context_dispose = Some(hooks::task_context_dispose);
    h.thread_set_pending_signal = Some(hooks::thread_set_pending_signal);
    h.current_thread_set_bsd_retval = Some(hooks::current_thread_set_bsd_retval);
    h.thread_context_dispose = Some(hooks::thread_context_dispose);
    h.thread_terminate = Some(hooks::thread_terminate);
    h.current_thread_interrupt_disable = Some(hooks::interrupt_disable);
    h.current_thread_interrupt_enable = Some(hooks::interrupt_enable);
    h.current_thread_syscall_return = Some(hooks::syscall_return);
    h.task_eternal_id = Some(hooks::task_eternal_id);
    h.thread_eternal_id = Some(hooks::thread_eternal_id);
    h.get_load_info = Some(hooks::get_load_info);
    h.timer_arm = Some(hooks::timer_arm);
    h.task_read_memory = Some(task_read_memory);
    h.task_write_memory = Some(task_write_memory);
    h
}

/// Initialize the duct-tape with the Rust hook vtable and return the kernel task.
/// (Leaks the hooks vtable intentionally: dtape_init stores the pointer for the
/// process lifetime.)
pub unsafe fn init() -> *mut dtape_task_t {
    let hooks = Box::leak(Box::new(make_hooks()));
    dtape_init(hooks);
    let kt = dtape_task_create(std::ptr::null_mut(), 0, std::ptr::null_mut(), 0);
    hooks::KERNEL_TASK = kt;
    // Phase 2 (init.c:117) on a kernel microthread -- C++'s Thread::kernelSync(
    // dtape_init_in_thread). Sets up thread_call/ipc/clock/psynch; spawns kernel daemon
    // threads (which park waiting for work, so drain() after to settle them).
    let mt = spawn(kt, Box::new(|| dtape_init_in_thread()));
    run(mt);
    if (*mt).is_suspended() {
        schedule(mt);
    } else {
        drop(Box::from_raw(mt));
    }
    drain();
    kt
}
