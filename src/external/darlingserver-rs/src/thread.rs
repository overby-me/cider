//! Thread-level duct-tape operations. Currently the sigexc (signal-via-Mach-exception)
//! enter/exit bracket used by the interrupt mechanism: when a signal is delivered to a
//! guest thread, it brackets the interrupt with interrupt_enter/interrupt_exit, and the
//! daemon tells XNU the thread has entered/left its sigexc state. Mirrors the
//! dtape_thread_sigexc_* calls in call.cpp's InterruptEnter/InterruptExit + thread.cpp.
//! See plan/rust-rewrite-eval.md (bucket B.4).

use crate::bindings::dtape_thread_t;

extern "C" {
    // Tell XNU a guest thread has died: tears down its Mach state (ports, right/notification
    // cleanup), so no stale message is routed to the dead thread. The C++ daemon calls this
    // on checkout (thread.cpp:1513); without it, a dead thread's ports dangle and a later
    // send spins ("kmsg to pid -1"). duct-tape/include/.../duct-tape.h:82.
    fn dtape_thread_dying(thread: *mut dtape_thread_t);

    fn dtape_thread_sigexc_enter(thread: *mut dtape_thread_t);
    fn dtape_thread_sigexc_enter2(thread: *mut dtape_thread_t);
    fn dtape_thread_sigexc_exit(thread: *mut dtape_thread_t);

    // Signal processing (sigprocess): load the guest's thread+float state (from guest
    // addresses, via the memory hooks), run the signal through XNU (which sets up the
    // guest's handler entry in the state + calls the pending-signal hook), optionally wait
    // while user-suspended (lldb), and save the modified state back. duct-tape/src/thread.c.
    fn dtape_thread_load_state_from_user(thread: *mut dtape_thread_t, thread_state: u64, float_state: u64) -> i32;
    fn dtape_thread_save_state_to_user(thread: *mut dtape_thread_t, thread_state: u64, float_state: u64) -> i32;
    fn dtape_thread_process_signal(thread: *mut dtape_thread_t, bsd_signal: i32, linux_signal: i32, code: i32, signal_address: u64);
    fn dtape_thread_wait_while_user_suspended(thread: *mut dtape_thread_t);
}

/// Tell XNU the guest thread has died, tearing down its Mach state. Call on checkout
/// (thread exit) before reaping the microthread, so the thread's ports/rights are cleaned
/// up and no stale message is routed to it. Mirrors C++'s dtape_thread_dying on checkout.
pub unsafe fn dying(thread: *mut dtape_thread_t) {
    dtape_thread_dying(thread);
}

/// Load the guest thread's saved register/float state (at guest addresses) into the dtape
/// thread. Returns a negative errno on failure.
pub unsafe fn load_state_from_user(thread: *mut dtape_thread_t, thread_state: u64, float_state: u64) -> i32 {
    dtape_thread_load_state_from_user(thread, thread_state, float_state)
}
/// Save the (possibly signal-modified) dtape thread state back to the guest's addresses.
pub unsafe fn save_state_to_user(thread: *mut dtape_thread_t, thread_state: u64, float_state: u64) -> i32 {
    dtape_thread_save_state_to_user(thread, thread_state, float_state)
}
/// Run a signal through XNU: sets up the guest's handler entry in the loaded state and
/// records the pending signal via the thread_set_pending_signal hook.
pub unsafe fn process_signal(thread: *mut dtape_thread_t, bsd_signal: i32, linux_signal: i32, code: i32, signal_address: u64) {
    dtape_thread_process_signal(thread, bsd_signal, linux_signal, code, signal_address);
}
/// Block while the thread is user-suspended (a debugger stopped it); returns immediately
/// if it is not suspended.
pub unsafe fn wait_while_user_suspended(thread: *mut dtape_thread_t) {
    dtape_thread_wait_while_user_suspended(thread);
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
