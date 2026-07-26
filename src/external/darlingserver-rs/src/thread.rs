//! Thread-level duct-tape operations. Currently the sigexc (signal-via-Mach-exception)
//! enter/exit bracket used by the interrupt mechanism: when a signal is delivered to a
//! guest thread, it brackets the interrupt with interrupt_enter/interrupt_exit, and the
//! daemon tells XNU the thread has entered/left its sigexc state. Mirrors the
//! dtape_thread_sigexc_* calls in call.cpp's InterruptEnter/InterruptExit + thread.cpp.
//! See plan/rust-rewrite-eval.md (bucket B.4).

use crate::bindings::dtape_thread_t;

extern "C" {
    fn dtape_thread_sigexc_enter(thread: *mut dtape_thread_t);
    fn dtape_thread_sigexc_enter2(thread: *mut dtape_thread_t);
    fn dtape_thread_sigexc_exit(thread: *mut dtape_thread_t);
}

/// Tell XNU the thread is entering signal (sigexc) processing: clears its XNU wait
/// (interrupting any blocked syscall). Mirrors _handleInterruptEnterForCurrentThread's
/// first sigexc call (thread.cpp:1583).
pub unsafe fn sigexc_enter(thread: *mut dtape_thread_t) {
    dtape_thread_sigexc_enter(thread);
}
/// Second half of interrupt entry: PUSHES a saved user_state onto the thread that
/// sigexc_exit later pops. interrupt_enter must call this (thread.cpp:1620) or the
/// matching sigexc_exit pops an empty list and corrupts the thread.
pub unsafe fn sigexc_enter2(thread: *mut dtape_thread_t) {
    dtape_thread_sigexc_enter2(thread);
}
/// Tell XNU the thread has finished signal (sigexc) processing: pops the user_state
/// sigexc_enter2 pushed. Mirrors InterruptExit (call.cpp:768).
pub unsafe fn sigexc_exit(thread: *mut dtape_thread_t) {
    dtape_thread_sigexc_exit(thread);
}
