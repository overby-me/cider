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
}

const KERNEL_NSID_BASE: u64 = 1 << 22; // DTAPE_KERNEL_THREAD_ID_THRESHOLD
const STACK_SIZE: usize = 512 * 1024;
static NEXT_EID: AtomicU64 = AtomicU64::new(1);
static NEXT_KTID: AtomicU64 = AtomicU64::new(KERNEL_NSID_BASE + 1);

/// A Rust-owned stackful microthread. Address-stable: always heap-boxed and handed
/// to the C duct-tape as `*mut c_void` context; never moved while C holds it.
pub struct Microthread {
    resume_ctx: MaybeUninit<libc::ucontext_t>,
    stack: Vec<u8>,
    suspended: bool,
    finished: bool,
    dtape_thread: *mut dtape_thread_t,
    interrupt_disable: u32,
    body: Option<Box<dyn FnOnce()>>,
    pending_cont: Option<(dtape_thread_continuation_callback_f, *mut c_void)>,
}

impl Microthread {
    pub fn is_finished(&self) -> bool { self.finished }
    pub fn is_suspended(&self) -> bool { self.suspended }
    pub fn dtape_thread(&self) -> *mut dtape_thread_t { self.dtape_thread }
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

/// Create a kernel microthread with the given body, backed by a fresh dtape_thread.
pub unsafe fn spawn(task: *mut dtape_task_t, body: Box<dyn FnOnce()>) -> *mut Microthread {
    let mt = Box::into_raw(Box::new(Microthread {
        resume_ctx: MaybeUninit::uninit(),
        stack: vec![0u8; STACK_SIZE],
        suspended: false,
        finished: false,
        dtape_thread: std::ptr::null_mut(),
        interrupt_disable: 0,
        body: Some(body),
        pending_cont: None,
    }));
    let nsid = NEXT_KTID.fetch_add(1, Ordering::Relaxed);
    (*mt).dtape_thread = dtape_thread_create(task, nsid, mt as *mut c_void);
    mt
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

unsafe fn setup_fresh_stack(mt: *mut Microthread, trampoline: extern "C" fn()) {
    let uc = (*mt).resume_ctx.as_mut_ptr();
    dserver_fast_getcontext(uc);
    (*uc).uc_stack.ss_sp = (*mt).stack.as_mut_ptr() as *mut c_void;
    (*uc).uc_stack.ss_size = (*mt).stack.len();
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
            setup_fresh_stack(mt, continuation_trampoline); // continuation on a fresh stack
        } else {
            dserver_fast_setcontext((*mt).resume_ctx.as_ptr()); // stackful resume
            unreachable!("setcontext returned");
        }
        dserver_fast_setcontext((*mt).resume_ctx.as_ptr());
        unreachable!("setcontext returned");
    } else {
        setup_fresh_stack(mt, body_trampoline); // first entry
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
    pub(super) unsafe extern "C" fn current_task() -> *mut dtape_task_t { KERNEL_TASK }
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
    pub(super) unsafe extern "C" fn task_eternal_id(_c: *mut c_void) -> dtape_eternal_id_t { NEXT_EID.fetch_add(1, Ordering::Relaxed) }
    pub(super) unsafe extern "C" fn thread_eternal_id(_c: *mut c_void) -> dtape_eternal_id_t { NEXT_EID.fetch_add(1, Ordering::Relaxed) }
    pub(super) unsafe extern "C" fn get_load_info(li: *mut dtape_load_info_t) {
        if !li.is_null() { (*li).task_count = 0; (*li).thread_count = 0; }
    }
    pub(super) unsafe extern "C" fn timer_arm(_ns: u64, _o: bool) {}
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
    h.task_eternal_id = Some(hooks::task_eternal_id);
    h.thread_eternal_id = Some(hooks::thread_eternal_id);
    h.get_load_info = Some(hooks::get_load_info);
    h.timer_arm = Some(hooks::timer_arm);
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
