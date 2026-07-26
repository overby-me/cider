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
use std::collections::VecDeque;
use std::mem::MaybeUninit;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicU64, Ordering};

// ---- FFI ----
extern "C" {
    fn dtape_init(hooks: *const dtape_hooks_t);
    fn dtape_task_create(parent: *mut dtape_task_t, nsid: u32, context: *mut c_void, arch: u32) -> *mut dtape_task_t;
    fn dtape_thread_create(task: *mut dtape_task_t, nsid: u64, context: *mut c_void) -> *mut dtape_thread_t;
    fn dtape_thread_entering(thread: *mut dtape_thread_t);
    fn dtape_thread_exiting(thread: *mut dtape_thread_t);

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
}

impl Microthread {
    pub fn is_finished(&self) -> bool { self.finished }
    pub fn is_suspended(&self) -> bool { self.suspended }
    pub fn dtape_thread(&self) -> *mut dtape_thread_t { self.dtape_thread }
    /// The result a blocking call delivered via thread_syscall_return (None if the call
    /// returned normally instead of blocking). Cleared on read.
    pub fn take_syscall_return(&mut self) -> Option<i32> { self.syscall_return.take() }
}

// ---- per-worker (per-OS-thread) state ----
thread_local! {
    static BACK_TO_TOP: UnsafeCell<MaybeUninit<libc::ucontext_t>> = UnsafeCell::new(MaybeUninit::uninit());
    static RETURNING: Cell<bool> = const { Cell::new(false) };
    static CURRENT: Cell<*mut Microthread> = const { Cell::new(std::ptr::null_mut()) };
    // Shared work queue -> Mutex+condvar when this goes multi-worker.
    static RUN_QUEUE: RefCell<VecDeque<*mut Microthread>> = const { RefCell::new(VecDeque::new()) };
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
    pub(super) unsafe extern "C" fn thread_context_dispose(_ctx: *mut c_void) {}
    pub(super) unsafe extern "C" fn thread_terminate(_ctx: *mut c_void) {}
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
    kt
}
