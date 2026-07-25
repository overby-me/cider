//! Stage 3 make-or-break spike (plan/rust-spike-stage3.md).
//!
//! Proves a Rust-owned stackful microthread can suspend from inside a C/XNU call
//! stack (via the daemon-supplied thread_suspend hook) and resume across the dtape
//! FFI, using the landed P1 fast context switch. Two phases, two suspend paths:
//!
//!   Phase 1 -- STACKFUL: a kernel microthread downs a dtape_semaphore (blocks ->
//!     thread_suspend, continuation == NULL); the loop ups it -> thread_resume ->
//!     down returns -> SPIKE_RESUMED_OK.
//!   Phase 2 -- CONTINUATION: a microthread assert_wait + thread_block(continuation)
//!     (blocks -> thread_suspend WITH a continuation; the old stack is discarded);
//!     the loop thread_wakeup_prim -> thread_resume -> the daemon runs the
//!     continuation on a FRESH stack -> SPIKE_CONT_RESUMED_OK.
//!
//! Arm A: FFI dserver_fast_{get,set,make}context (preserves P1). Faithful port of
//! darlingserver's Thread::doWork / Thread::suspend. Single-threaded loop.
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

// ---- FFI: dtape entry points + P1 context primitives + a few raw XNU symbols ----
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

    // Raw XNU scheduler primitives (in the duct-tape .a) for the continuation vehicle.
    fn assert_wait(event: *const c_void, interruptible: c_int) -> c_int;
    fn thread_block(continuation: Option<unsafe extern "C" fn(param: *mut c_void, wr: c_int)>) -> c_int;
    fn thread_wakeup_prim(event: *const c_void, one_thread: c_int, result: c_int) -> c_int;
}
const THREAD_UNINT: c_int = 0; // wait_interrupt_t
const THREAD_AWAKENED: c_int = 0; // wait_result_t

const KERNEL_NSID_BASE: u64 = 1 << 22; // DTAPE_KERNEL_THREAD_ID_THRESHOLD
const STACK_SIZE: usize = 512 * 1024;
static NEXT_EID: AtomicU64 = AtomicU64::new(1);
static NEXT_KTID: AtomicU64 = AtomicU64::new(KERNEL_NSID_BASE + 1);

/// A Rust-owned stackful microthread (address-stable: heap-boxed, handed to C as
/// `*mut c_void` context; never moved while C holds the pointer).
struct Microthread {
    resume_ctx: MaybeUninit<libc::ucontext_t>, // where a stackful microthread parks
    stack: Vec<u8>,
    suspended: bool,
    finished: bool,
    dtape_thread: *mut dtape_thread_t,
    interrupt_disable: u32,
    body: Option<Box<dyn FnOnce()>>,
    // Set when the current suspend used a continuation: on resume, run this on a
    // FRESH stack instead of returning to the (discarded) suspend point.
    pending_cont: Option<(dtape_thread_continuation_callback_f, *mut c_void)>,
}

thread_local! {
    static CURRENT: Cell<*mut Microthread> = const { Cell::new(std::ptr::null_mut()) };
    static RUN_QUEUE: RefCell<VecDeque<*mut Microthread>> = const { RefCell::new(VecDeque::new()) };
}
static mut BACK_TO_TOP: MaybeUninit<libc::ucontext_t> = MaybeUninit::uninit();
static mut RETURNING_TO_TOP: bool = false;
static mut KERNEL_TASK: *mut dtape_task_t = std::ptr::null_mut();
static EVENT: u8 = 0; // a wait-event address for the continuation vehicle

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
        (*mt).suspended = false;
        if (*mt).pending_cont.is_some() {
            // CONTINUATION resume: run the continuation on a fresh stack.
            let uc = (*mt).resume_ctx.as_mut_ptr();
            dserver_fast_getcontext(uc);
            (*uc).uc_stack.ss_sp = (*mt).stack.as_mut_ptr() as *mut c_void;
            (*uc).uc_stack.ss_size = (*mt).stack.len();
            (*uc).uc_link = BACK_TO_TOP.as_mut_ptr();
            dserver_fast_makecontext(uc, continuation_trampoline, 0);
            dserver_fast_setcontext(uc);
            unreachable!("setcontext returned");
        } else {
            // STACKFUL resume: jump back into the parked microthread.
            dserver_fast_setcontext((*mt).resume_ctx.as_ptr());
            unreachable!("setcontext returned");
        }
    } else {
        // First entry: build a fresh stack + body trampoline.
        let uc = (*mt).resume_ctx.as_mut_ptr();
        dserver_fast_getcontext(uc);
        (*uc).uc_stack.ss_sp = (*mt).stack.as_mut_ptr() as *mut c_void;
        (*uc).uc_stack.ss_size = (*mt).stack.len();
        (*uc).uc_link = BACK_TO_TOP.as_mut_ptr();
        dserver_fast_makecontext(uc, body_trampoline, 0);
        dserver_fast_setcontext(uc);
        unreachable!("setcontext returned");
    }
}

/// First-entry trampoline: run the microthread body once.
extern "C" fn body_trampoline() {
    unsafe {
        let mt = cur();
        if let Some(body) = (*mt).body.take() {
            body();
        }
        // returns -> uc_link == BACK_TO_TOP -> finished
    }
}

/// Continuation-resume trampoline: run the stored continuation on the fresh stack.
extern "C" fn continuation_trampoline() {
    unsafe {
        let mt = cur();
        if let Some((cb, ctx)) = (*mt).pending_cont.take() {
            if let Some(cb) = cb {
                cb(ctx); // == thread_continuation_callback(thread) -> the real continuation
            }
        }
        // returns -> uc_link == BACK_TO_TOP -> finished
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
    continuation_context: *mut c_void,
    unlock_me: *mut libsimple_lock_t,
) {
    let mt = thread_context as *mut Microthread;
    (*mt).suspended = true;
    if !unlock_me.is_null() {
        libsimple_lock_unlock(unlock_me);
    }
    if continuation_callback.is_some() {
        // CONTINUATION path: discard the current stack (reused on resume via a fresh
        // makecontext) and yield to the loop WITHOUT saving a resume point.
        (*mt).pending_cont = Some((continuation_callback, continuation_context));
        dserver_fast_setcontext(BACK_TO_TOP.as_ptr());
        unreachable!("setcontext returned");
    }
    // STACKFUL path: save the suspend point (returns twice) and yield.
    dserver_fast_getcontext((*mt).resume_ctx.as_mut_ptr());
    if (*mt).suspended {
        dserver_fast_setcontext(BACK_TO_TOP.as_ptr());
        unreachable!("setcontext returned");
    }
    // resumed -> fall through; the C caller (semaphore_wait) continues
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

unsafe fn new_microthread(task: *mut dtape_task_t, body: Box<dyn FnOnce()>) -> *mut Microthread {
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

/// Drain the run queue (resumes woken microthreads) until empty.
unsafe fn drain() {
    loop {
        let next = RUN_QUEUE.with(|q| q.borrow_mut().pop_front());
        match next {
            Some(mt) => do_work(mt),
            None => break,
        }
    }
}

/// XNU continuation for phase 2: runs on a fresh stack after the wake.
unsafe extern "C" fn phase2_continuation(_param: *mut c_void, _wr: c_int) {
    println!("SPIKE_CONT_RESUMED_OK");
}

fn main() {
    unsafe {
        let hooks = make_hooks();
        dtape_init(&hooks);
        KERNEL_TASK = dtape_task_create(std::ptr::null_mut(), 0, std::ptr::null_mut(), 0);
        assert!(!KERNEL_TASK.is_null(), "no kernel task");
        eprintln!("[spike] dtape_init done; kernel task ready");

        // ---- Phase 1: STACKFUL suspend/resume via a semaphore ----
        let sem = dtape_semaphore_create(KERNEL_TASK, 0);
        assert!(!sem.is_null(), "semaphore_create failed");
        let sem_addr = sem as usize;
        let p1 = new_microthread(KERNEL_TASK, Box::new(move || {
            eprintln!("[p1-mt] downing semaphore (blocks -> stackful suspend)...");
            let ok = dtape_semaphore_down_simple(sem_addr as *mut dtape_semaphore_t);
            println!("{}", if ok { "SPIKE_RESUMED_OK" } else { "SPIKE_RESUMED_BUT_DOWN_FAILED" });
        }));
        do_work(p1);
        assert!((*p1).suspended && !(*p1).finished, "p1 did not suspend");
        eprintln!("[spike] p1 suspended (stackful); posting up");
        dtape_semaphore_up(sem);
        drain();
        assert!((*p1).finished, "p1 did not finish after resume");
        eprintln!("[spike] Phase 1 (stackful) PROVEN.\n");

        // ---- Phase 2: CONTINUATION suspend/resume via assert_wait + thread_block ----
        let p2 = new_microthread(KERNEL_TASK, Box::new(move || {
            eprintln!("[p2-mt] assert_wait + thread_block(continuation) (blocks -> continuation suspend)...");
            assert_wait(&EVENT as *const u8 as *const c_void, THREAD_UNINT);
            thread_block(Some(phase2_continuation));
            // With a continuation, thread_block does NOT return here on wake.
            println!("SPIKE_CONT_UNEXPECTED_RETURN");
        }));
        do_work(p2);
        assert!((*p2).suspended && !(*p2).finished, "p2 did not suspend");
        assert!((*p2).pending_cont.is_some(), "p2 suspend was not a continuation");
        eprintln!("[spike] p2 suspended (continuation, old stack discarded); waking");
        thread_wakeup_prim(&EVENT as *const u8 as *const c_void, 0, THREAD_AWAKENED);
        drain();
        assert!((*p2).finished, "p2 did not finish after continuation resume");
        eprintln!("[spike] Phase 2 (continuation) PROVEN.");

        eprintln!("[spike] Stage 3 spike: BOTH suspend paths PROVEN across the dtape FFI.");
    }
}
