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
use std::os::raw::c_char;

// Hand-declared (duct-tape.h needs the generated DSERVER_DTAPE_DECLS macro, so we
// declare just the entry points we call rather than bindgen the whole tree).
extern "C" {
    fn dtape_init(hooks: *const dtape_hooks_t);
}

/// The one hook we wire for the link proof: route duct-tape logging to stderr.
unsafe extern "C" fn hook_log(_level: dtape_log_level_t, message: *const c_char) {
    if !message.is_null() {
        eprintln!("[dtape] {}", CStr::from_ptr(message).to_string_lossy());
    }
}

/// Build a hooks vtable: everything null (None) except `log`. Valid for the link
/// proof because we only call `dtape_init` (which stores the vtable); the spike
/// (plan/rust-spike-stage3.md) fills the ~12 scheduler/identity hooks it exercises
/// and points the rest at an abort-stub.
fn make_hooks() -> dtape_hooks_t {
    // SAFETY: dtape_hooks_t is a POD of Option<extern "C" fn ...> fields; all-zero
    // is all-None (null-pointer-optimized), a valid initial vtable.
    let mut hooks: dtape_hooks_t = unsafe { std::mem::zeroed() };
    hooks.log = Some(hook_log);
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
