//! Stage 3 make-or-break spike (plan/rust-spike-stage3.md).
//!
//! Hypothesis to falsify: a Rust-owned STACKFUL microthread can be entered by the
//! loop, run C/XNU code that suspends it from inside a C call stack (via the
//! daemon-supplied `thread_suspend` hook), be resumed later (`thread_resume`), and
//! continue -- all across the dtape FFI, using the landed P1 fast context switch.
//!
//! Vehicle (zero new C): a `dtape_semaphore` at 0. A kernel microthread calls
//! `dtape_semaphore_down_simple` (blocks -> thread_suspend); the loop calls
//! `dtape_semaphore_up` (wakes -> thread_resume). Success = SPIKE_RESUMED_OK.
//!
//! Arm A: FFI `dserver_fast_{get,set,make}context` (preserves P1). This is a faithful
//! port of darlingserver's Thread::doWork / Thread::suspend (the getcontext-returns-
//! twice idiom). Single-threaded loop; continuations/interrupts are out of scope.
//!
//! DUCT_TAPE_LIB=<dir-with-the-.a's> cargo run --bin stage3-spike

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]

include!(concat!(env!("OUT_DIR"), "/dtape_bindings.rs"));

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::ffi::CStr;
use std::mem::MaybeUninit;
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicU64, Ordering};

// ---- FFI: the dtape entry points + P1 context primitives + libsimple ----
extern "C" {
    fn dtape_init(hooks: *const dtape_hooks_t);
    fn dtape_task_create(parent: *mut dtape_task_t, nsid: u32, context: *mut c_void, arch: u32) -> *mut dtape_task_t;
    fn dtape_thread_create(task: *mut dtape_task_t, nsid: u64, context: *mut c_void) -> *mut dtape_thread_t;
    fn dtape_thread_entering(thread: *mut dtape_thread_t);
    fn dtape_thread_exiting(thread: *mut dtape_thread_t);
    fn dtape_semaphore_create(task: *mut dtape_task_t, initial: c_int) -> *mut dtape_semaphore_t;
    fn dtape_semaphore_up(sem: *mut dtape_semaphore_t);
    fn dtape_semaphore_down_simple(sem: *mut dtape_semaphore_t) -> bool;

    fn dserver_fast_getcontext(ucp: *mut libc::ucontext_t) -> c_int;
    fn dserver_fast_setcontext(ucp: *const libc::ucontext_t);
    fn dserver_fast_makecontext(ucp: *mut libc::ucontext_t, func: extern "C" fn(), argc: c_int, ...);

    fn libsimple_lock_unlock(lock: *mut libsimple_lock_t);
}

const KERNEL_NSID_BASE: u64 = 1 << 22; // DTAPE_KERNEL_THREAD_ID_THRESHOLD
const STACK_SIZE: usize = 512 * 1024;
static NEXT_EID: AtomicU64 = AtomicU64::new(1);
static NEXT_KTID: AtomicU64 = AtomicU64::new(KERNEL_NSID_BASE + 1);

/// A Rust-owned stackful microthread (address-stable: always heap-boxed, handed to
/// C as `*mut c_void` context; never moved while C holds the pointer).
struct Microthread {
    resume_ctx: MaybeUninit<libc::ucontext_t>, // where the microthread is parked
    stack: Vec<u8>,
    suspended: bool,
    finished: bool,
    dtape_thread: *mut dtape_thread_t,
    interrupt_disable: u32,
    body: Option<Box<dyn FnOnce()>>,
}

thread_local! {
    static CURRENT: Cell<*mut Microthread> = const { Cell::new(std::ptr::null_mut()) };
    static RUN_QUEUE: RefCell<VecDeque<*mut Microthread>> = const { RefCell::new(VecDeque::new()) };
}
// Single-threaded spike: the loop's return context + the returns-twice flag are globals.
static mut BACK_TO_TOP: MaybeUninit<libc::ucontext_t> = MaybeUninit::uninit();
static mut RETURNING_TO_TOP: bool = false;
static mut KERNEL_TASK: *mut dtape_task_t = std::ptr::null_mut();

fn cur() -> *mut Microthread {
    CURRENT.with(|c| c.get())
}

/// Faithful port of Thread::doWork: enter (first time) or resume a microthread,
/// via the getcontext(BACK_TO_TOP)-returns-twice idiom.
unsafe fn do_work(mt: *mut Microthread) {
    CURRENT.with(|c| c.set(mt));
    dtape_thread_entering((*mt).dtape_thread);

    RETURNING_TO_TOP = false;
    dserver_fast_getcontext(BACK_TO_TOP.as_mut_ptr()); // returns twice

    if RETURNING_TO_TOP {
        // The microthread jumped back to the top: it suspended or finished.
        if !(*mt).suspended {
            (*mt).finished = true;
        }
        dtape_thread_exiting((*mt).dtape_thread);
        CURRENT.with(|c| c.set(std::ptr::null_mut()));
        return;
    }
    RETURNING_TO_TOP = true;

    if (*mt).suspended {
        // resume the parked microthread (stackful)
        (*mt).suspended = false;
        dserver_fast_setcontext((*mt).resume_ctx.as_ptr());
        unreachable!("setcontext returned");
    } else {
        // first entry: build a fresh stack + trampoline
        let uc = (*mt).resume_ctx.as_mut_ptr();
        dserver_fast_getcontext(uc);
        (*uc).uc_stack.ss_sp = (*mt).stack.as_mut_ptr() as *mut c_void;
        (*uc).uc_stack.ss_size = (*mt).stack.len();
        (*uc).uc_link = BACK_TO_TOP.as_mut_ptr();
        dserver_fast_makecontext(uc, trampoline, 0);
        dserver_fast_setcontext(uc);
        unreachable!("setcontext returned");
    }
}

/// Entry trampoline: run the microthread body once. When it returns, uc_link
/// (BACK_TO_TOP) resumes do_work's getcontext (2nd return) -> finished.
extern "C" fn trampoline() {
    unsafe {
        let mt = cur();
        if let Some(body) = (*mt).body.take() {
            body();
        }
        // returns -> uc_link == BACK_TO_TOP
    }
}

// ---- hooks ----

unsafe extern "C" fn hook_log(_level: dtape_log_level_t, message: *const c_char) {
    if !message.is_null() {
        eprintln!("[dtape] {}", CStr::from_ptr(message).to_string_lossy());
    }
}
unsafe extern "C" fn hook_current_task() -> *mut dtape_task_t {
    KERNEL_TASK
}
unsafe extern "C" fn hook_current_thread() -> *mut dtape_thread_t {
    let mt = cur();
    if mt.is_null() { std::ptr::null_mut() } else { (*mt).dtape_thread }
}
/// The crux: suspend the current microthread from inside a C/XNU call stack.
unsafe extern "C" fn hook_thread_suspend(
    thread_context: *mut c_void,
    continuation_callback: dtape_thread_continuation_callback_f,
    _continuation_context: *mut c_void,
    unlock_me: *mut libsimple_lock_t,
) {
    let mt = thread_context as *mut Microthread;
    if continuation_callback.is_some() {
        // The spike proves the STACKFUL path; the continuation path is a separate
        // follow-up. Make this loud rather than silently wrong.
        eprintln!("SPIKE_UNSUPPORTED: thread_suspend with a continuation (stackful-only spike)");
        std::process::abort();
    }
    (*mt).suspended = true;
    if !unlock_me.is_null() {
        libsimple_lock_unlock(unlock_me);
    }
    dserver_fast_getcontext((*mt).resume_ctx.as_mut_ptr()); // returns twice
    if (*mt).suspended {
        // first return: yield back to the loop
        dserver_fast_setcontext(BACK_TO_TOP.as_ptr());
        unreachable!("setcontext returned");
    }
    // second return: resumed -> fall through, the C caller (semaphore_wait) continues
}
unsafe extern "C" fn hook_thread_resume(thread_context: *mut c_void) {
    let mt = thread_context as *mut Microthread;
    RUN_QUEUE.with(|q| q.borrow_mut().push_back(mt));
}
unsafe extern "C" fn hook_thread_context_dispose(_thread_context: *mut c_void) {}
unsafe extern "C" fn hook_thread_terminate(_thread_context: *mut c_void) {}
unsafe extern "C" fn hook_current_thread_interrupt_disable() {
    let mt = cur();
    if !mt.is_null() { (*mt).interrupt_disable += 1; }
}
unsafe extern "C" fn hook_current_thread_interrupt_enable() {
    let mt = cur();
    if !mt.is_null() && (*mt).interrupt_disable > 0 { (*mt).interrupt_disable -= 1; }
}
unsafe extern "C" fn hook_task_eternal_id(_c: *mut c_void) -> dtape_eternal_id_t { NEXT_EID.fetch_add(1, Ordering::Relaxed) }
unsafe extern "C" fn hook_thread_eternal_id(_c: *mut c_void) -> dtape_eternal_id_t { NEXT_EID.fetch_add(1, Ordering::Relaxed) }
unsafe extern "C" fn hook_get_load_info(li: *mut dtape_load_info_t) {
    if !li.is_null() { (*li).task_count = 0; (*li).thread_count = 0; }
}
unsafe extern "C" fn hook_timer_arm(_ns: u64, _o: bool) {}

fn make_hooks() -> dtape_hooks_t {
    let mut h: dtape_hooks_t = unsafe { std::mem::zeroed() };
    h.log = Some(hook_log);
    h.current_task = Some(hook_current_task);
    h.current_thread = Some(hook_current_thread);
    h.thread_suspend = Some(hook_thread_suspend);
    h.thread_resume = Some(hook_thread_resume);
    h.thread_context_dispose = Some(hook_thread_context_dispose);
    h.thread_terminate = Some(hook_thread_terminate);
    h.current_thread_interrupt_disable = Some(hook_current_thread_interrupt_disable);
    h.current_thread_interrupt_enable = Some(hook_current_thread_interrupt_enable);
    h.task_eternal_id = Some(hook_task_eternal_id);
    h.thread_eternal_id = Some(hook_thread_eternal_id);
    h.get_load_info = Some(hook_get_load_info);
    h.timer_arm = Some(hook_timer_arm);
    h
}

/// Heap-box a microthread + create its backing dtape_thread (context = the box).
unsafe fn new_microthread(task: *mut dtape_task_t, body: Box<dyn FnOnce()>) -> *mut Microthread {
    let mt = Box::into_raw(Box::new(Microthread {
        resume_ctx: MaybeUninit::uninit(),
        stack: vec![0u8; STACK_SIZE],
        suspended: false,
        finished: false,
        dtape_thread: std::ptr::null_mut(),
        interrupt_disable: 0,
        body: Some(body),
    }));
    let nsid = NEXT_KTID.fetch_add(1, Ordering::Relaxed);
    (*mt).dtape_thread = dtape_thread_create(task, nsid, mt as *mut c_void);
    mt
}

fn main() {
    unsafe {
        let hooks = make_hooks();
        dtape_init(&hooks);
        eprintln!("[spike] dtape_init done");

        // Kernel task handle (dtape_init already created it; this returns the existing one).
        KERNEL_TASK = dtape_task_create(std::ptr::null_mut(), 0, std::ptr::null_mut(), 0);
        assert!(!KERNEL_TASK.is_null(), "no kernel task");

        let sem = dtape_semaphore_create(KERNEL_TASK, 0);
        assert!(!sem.is_null(), "semaphore_create failed");
        eprintln!("[spike] kernel task + semaphore(0) ready");

        // The microthread that blocks on the semaphore.
        let sem_addr = sem as usize;
        let spike = new_microthread(KERNEL_TASK, Box::new(move || {
            eprintln!("[spike-mt] downing semaphore (will block -> suspend)...");
            let ok = dtape_semaphore_down_simple(sem_addr as *mut dtape_semaphore_t);
            if ok {
                println!("SPIKE_RESUMED_OK");
            } else {
                println!("SPIKE_RESUMED_BUT_DOWN_FAILED");
            }
        }));

        // Enter it: it runs until it suspends inside semaphore_wait.
        do_work(spike);
        assert!((*spike).suspended, "microthread did not suspend on down");
        assert!(!(*spike).finished);
        eprintln!("[spike] microthread suspended; posting up");

        // Wake it: semaphore_signal -> thread_resume -> re-queued.
        dtape_semaphore_up(sem);

        // Drain the run queue: resume the microthread -> down returns -> it finishes.
        loop {
            let next = RUN_QUEUE.with(|q| q.borrow_mut().pop_front());
            match next {
                Some(mt) => do_work(mt),
                None => break,
            }
        }

        assert!((*spike).finished, "microthread did not finish after resume");
        eprintln!("[spike] microthread finished. Stage 3 stackful suspend/resume: PROVEN.");
        // (leak the box; process exits)
    }
}
