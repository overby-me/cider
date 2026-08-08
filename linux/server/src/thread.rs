//! Thread-level duct-tape operations. Currently the sigexc (signal-via-Mach-exception)
//! enter/exit bracket used by the interrupt mechanism: when a signal is delivered to a
//! guest thread, it brackets the interrupt with interrupt_enter/interrupt_exit, and the
//! daemon tells XNU the thread has entered/left its sigexc state. Mirrors the
//! dtape_thread_sigexc_* calls in call.cpp's InterruptEnter/InterruptExit + thread.cpp.
//! See PLAN.md (bucket B.4).

use crate::bindings::dtape_thread_t;

// These were declared here in an `extern "C"` block and resolved through the linker back into
// this same crate, because duct-tape was C when this file was written. It is Rust now (#71), so
// the declarations are gone and the definitions are imported directly (#75).
//
// That is not tidying. rustc lints declaration against declaration, but it does NOT check a
// declaration against a DEFINITION in the same crate: the linker matches on name alone. Three
// of the imports below had been silently disagreeing with their definitions, u64 here against
// usize there, and the only reason nothing broke is that this target is 64 bit. gate10 found
// the same class of bug the expensive way, when thread_block was declared with the wrong
// continuation type.
//
// What each one does:
//   dtape_thread_dying          tears down a dead guest thread's Mach state (ports, rights,
//                               notifications), so no stale message routes to it. The C++
//                               daemon called this on checkout (thread.cpp:1513); without it a
//                               dead thread's ports dangle and a later send spins.
//   dtape_thread_sigexc_*       the signal-via-Mach-exception bracket, see the wrappers below.
//   load/save_state, process_signal, wait_while_user_suspended
//                               signal processing: load the guest register and float state from
//                               guest addresses, run the signal through XNU, optionally wait
//                               while user-suspended for a debugger, save the modified state.
use crate::dtape_thread::{
    dtape_thread_dying, dtape_thread_load_state_from_user, dtape_thread_process_signal,
    dtape_thread_save_state_to_user, dtape_thread_sigexc_enter, dtape_thread_sigexc_enter2,
    dtape_thread_sigexc_exit, dtape_thread_wait_while_user_suspended,
};

/// Tell XNU the guest thread has died, tearing down its Mach state. Call on checkout
/// (thread exit) before reaping the microthread, so the thread's ports/rights are cleaned
/// up and no stale message is routed to it. Mirrors C++'s dtape_thread_dying on checkout.
pub unsafe fn dying(thread: *mut dtape_thread_t) {
    // Drop it from the thread_lookup table first, so no lookup resolves a dead thread.
    crate::sched::unregister_thread_lookup(thread);
    dtape_thread_dying(thread);
}

/// Load the guest thread's saved register/float state (at guest addresses) into the dtape
/// thread. Returns a negative errno on failure.
pub unsafe fn load_state_from_user(thread: *mut dtape_thread_t, thread_state: u64, float_state: u64) -> i32 {
    // u64 here, usize there. These parameters are GUEST ADDRESSES: the RPC wire carries them
    // as a fixed 64 bit field, and the duct-tape entry point takes them at host pointer width.
    // The old extern declaration said u64 on both sides and the linker did not care, so the
    // conversion happened silently and only worked because this target is 64 bit. Now it is
    // written down.
    dtape_thread_load_state_from_user(thread, thread_state as usize, float_state as usize)
}
/// Save the (possibly signal-modified) dtape thread state back to the guest's addresses.
pub unsafe fn save_state_to_user(thread: *mut dtape_thread_t, thread_state: u64, float_state: u64) -> i32 {
    dtape_thread_save_state_to_user(thread, thread_state as usize, float_state as usize)
}
/// Run a signal through XNU: sets up the guest's handler entry in the loaded state and
/// records the pending signal via the thread_set_pending_signal hook.
pub unsafe fn process_signal(thread: *mut dtape_thread_t, bsd_signal: i32, linux_signal: i32, code: i32, signal_address: u64) {
    // signal_address is the third of the three that had been disagreeing: u64 on the wire,
    // usize at the duct-tape entry point.
    dtape_thread_process_signal(thread, bsd_signal, linux_signal, code, signal_address as usize);
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
