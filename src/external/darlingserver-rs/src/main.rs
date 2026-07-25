//! Stage 0 link proof for the darlingserver Rust rewrite.
//!
//! Goal: prove the REAL C duct-tape links from Rust and `dtape_init(&hooks)` is
//! callable with the real 36-field `dtape_hooks_t` vtable (bindgen-generated).
//! This is the prerequisite for the Stage 3 suspend/resume spike
//! (plan/rust-spike-stage3.md). The scheduler/RPC loop is NOT here yet.
//!
//! Build/run (once the duct-tape .a is exported by the darling build):
//!   DUCT_TAPE_LIB=<dir-with-the-.a's> cargo run --bin dtape-link-proof
//! Without DUCT_TAPE_LIB, `cargo check` still validates the Rust/FFI side.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]

// The bindgen-generated dtape hooks contract + types (from build.rs).
include!(concat!(env!("OUT_DIR"), "/dtape_bindings.rs"));

use std::ffi::CStr;
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering};

// Hand-declared (duct-tape.h needs the generated DSERVER_DTAPE_DECLS macro, so we
// declare just the entry points we call rather than bindgen the whole tree).
extern "C" {
    fn dtape_init(hooks: *const dtape_hooks_t);
}

// Monotonic eternal-id source (unique, nonzero) for tasks/threads.
static NEXT_EID: AtomicU64 = AtomicU64::new(1);

/// Route duct-tape logging to stderr.
unsafe extern "C" fn hook_log(_level: dtape_log_level_t, message: *const c_char) {
    if !message.is_null() {
        eprintln!("[dtape] {}", CStr::from_ptr(message).to_string_lossy());
    }
}

// --- Minimal init-time hooks (enough to bring dtape_init to completion). The
// real scheduler/identity hooks (suspend/resume, current_thread, thread_create_kernel)
// are the Stage 3 spike -- see plan/rust-spike-stage3.md. ---

unsafe extern "C" fn hook_task_eternal_id(_task_ctx: *mut c_void) -> dtape_eternal_id_t {
    NEXT_EID.fetch_add(1, Ordering::Relaxed)
}
unsafe extern "C" fn hook_thread_eternal_id(_thread_ctx: *mut c_void) -> dtape_eternal_id_t {
    NEXT_EID.fetch_add(1, Ordering::Relaxed)
}
unsafe extern "C" fn hook_current_task() -> *mut dtape_task_t {
    std::ptr::null_mut() // no current task during early init
}
unsafe extern "C" fn hook_current_thread() -> *mut dtape_thread_t {
    std::ptr::null_mut() // no current microthread during early init
}
unsafe extern "C" fn hook_get_load_info(load_info: *mut dtape_load_info_t) {
    if !load_info.is_null() {
        (*load_info).task_count = 0;
        (*load_info).thread_count = 0;
    }
}
unsafe extern "C" fn hook_timer_arm(_absolute_ns: u64, _override: bool) {
    // no timers in the link proof
}

/// Build the hooks vtable: the minimal init-time set + `log`; everything else null
/// (None). dtape_init only needs the identity/id hooks to create the kernel task;
/// the Stage 3 spike fills the scheduler hooks (thread_suspend/resume, ...).
fn make_hooks() -> dtape_hooks_t {
    // SAFETY: dtape_hooks_t is a POD of Option<extern "C" fn ...> fields; all-zero
    // is all-None (null-pointer-optimized), a valid initial vtable.
    let mut hooks: dtape_hooks_t = unsafe { std::mem::zeroed() };
    hooks.log = Some(hook_log);
    hooks.task_eternal_id = Some(hook_task_eternal_id);
    hooks.thread_eternal_id = Some(hook_thread_eternal_id);
    hooks.current_task = Some(hook_current_task);
    hooks.current_thread = Some(hook_current_thread);
    hooks.get_load_info = Some(hook_get_load_info);
    hooks.timer_arm = Some(hook_timer_arm);
    hooks
}

fn main() {
    let hooks = make_hooks();
    // SAFETY: FFI into the C duct-tape with a valid vtable pointer that outlives
    // the call. (dtape_init copies/stores what it needs.)
    unsafe {
        dtape_init(&hooks);
    }
    println!("STAGE0_OK: linked real duct-tape and called dtape_init(&hooks)");
}
