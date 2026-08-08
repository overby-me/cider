//! Object-level duct-tape semaphores: the Rust replacement for
//! `duct-tape/src/semaphore.c` (#71, the first glue file ported).
//!
//! These are semaphores OWNED BY A TASK, distinct from the name-based semaphore traps in
//! [`crate::traps`]. The daemon uses them for the fork-wait handshake (the parent blocks on
//! its own semaphore, the forked child ups it on checkin), and `kqchan.c` -- which is still
//! C -- uses them for its reader/death waiters.
//!
//! WHY THIS FILE WENT FIRST. It was picked by measurement, not by feel:
//! `scripts/duct-tape-portability.py` ranks the sixteen glue files by what Rust genuinely
//! cannot express, and this one is 60 lines with a single macro (`panic`) and no C variadic
//! definitions. It still exercises every part of the seam that the remaining files need:
//! it exports the C ABI, it is called FROM C (kqchan.c), it calls INTO XNU, it dereferences
//! both a duct-tape struct and an XNU one, and it maps a `kern_return_t` onto a C enum.
//!
//! TWO THINGS WERE PROVEN BEFORE ANY OF IT WAS WRITTEN, because both are load-bearing and
//! neither is obvious:
//!
//! * A C ARCHIVE RESOLVES AGAINST A RUST RLIB. `kqchan.c` stays C and calls
//!   `dtape_semaphore_up`, so the port needs the C-to-Rust direction. rustc puts rlibs and
//!   native static libs on one link line and ld resolves archives left to right, so this is
//!   a real failure mode. Built the smallest case with the archive listed AFTER the rlib:
//!   links, runs, returns the right answer. With the definition removed it fails to link.
//! * `panic` IS A LINKABLE SYMBOL, not just a macro (`nm` shows it undefined in the
//!   duct-tape archive, so something else in the link defines it). Rust may CALL a C
//!   variadic even though it cannot DEFINE one, so the fatal paths below stay exactly what
//!   they were rather than becoming a Rust `panic!`, which would unwind across `extern "C"`.
//!
//! Every type and offset here comes from bindgen (see `wrapper.h`); nothing is transcribed.

use std::os::raw::{c_char, c_int, c_void};
use std::ptr;

use crate::bindings::{
    dtape_semaphore_t, dtape_task_t, semaphore_create, semaphore_destroy, semaphore_signal,
    semaphore_wait, KERN_ABORTED, KERN_SUCCESS,
};

extern "C" {
    // XNU's panic: variadic, and fatal. Declared rather than replaced with Rust's panic!,
    // which would unwind across the extern "C" boundary.
    fn panic(format: *const c_char, ...);
}

/// Mirrors `dtape_semaphore_wait_result_t` in duct-tape/include/.../types.h.
///
/// Spelled out rather than reusing the bindgen enum because this is a RETURN type across
/// the C ABI: the C header pins the discriminants at -1/0/1, so they are pinned here too.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitResult {
    Error = -1,
    Ok = 0,
    Interrupted = 1,
}

/// Create a semaphore owned by `owning_task`, starting at `initial_value`.
///
/// Returns null if the allocation or the XNU semaphore fails, exactly as the C did.
#[no_mangle]
pub unsafe extern "C" fn dtape_semaphore_create(
    owning_task: *mut dtape_task_t,
    initial_value: c_int,
) -> *mut dtape_semaphore_t {
    // malloc/free rather than Box: this pointer is handed to and freed through C code paths,
    // so it has to stay on the C allocator.
    let semaphore = libc::malloc(std::mem::size_of::<dtape_semaphore_t>()) as *mut dtape_semaphore_t;
    if semaphore.is_null() {
        return ptr::null_mut();
    }

    (*semaphore).owning_task = owning_task;

    // &owning_task->xnu_task: the XNU task is EMBEDDED in the duct-tape task, so this is an
    // interior pointer, and its offset is bindgen's, not one written down here.
    let xnu_task = ptr::addr_of_mut!((*(*semaphore).owning_task).xnu_task) as *mut _;

    if semaphore_create(
        xnu_task,
        ptr::addr_of_mut!((*semaphore).xnu_semaphore),
        0,
        initial_value,
    ) != KERN_SUCCESS as i32
    {
        libc::free(semaphore as *mut c_void);
        return ptr::null_mut();
    }

    semaphore
}

/// Destroy `semaphore` and free it. Fatal if XNU refuses, as in the C.
#[no_mangle]
pub unsafe extern "C" fn dtape_semaphore_destroy(semaphore: *mut dtape_semaphore_t) {
    let xnu_task = ptr::addr_of_mut!((*(*semaphore).owning_task).xnu_task) as *mut _;

    if semaphore_destroy(xnu_task, (*semaphore).xnu_semaphore) != KERN_SUCCESS as i32 {
        panic(c"Failed to destroy duct-taped XNU semaphore".as_ptr());
    }

    libc::free(semaphore as *mut c_void);
}

/// Raise the up-count of `semaphore` (signal it).
#[no_mangle]
pub unsafe extern "C" fn dtape_semaphore_up(semaphore: *mut dtape_semaphore_t) {
    if semaphore_signal((*semaphore).xnu_semaphore) != KERN_SUCCESS as i32 {
        panic(c"Failed to raise up-count of duct-taped XNU semaphore".as_ptr());
    }
}

/// Wait on `semaphore`, blocking the calling microthread until it is signaled.
#[no_mangle]
pub unsafe extern "C" fn dtape_semaphore_down(semaphore: *mut dtape_semaphore_t) -> WaitResult {
    let kr = semaphore_wait((*semaphore).xnu_semaphore);
    if kr == KERN_SUCCESS as i32 {
        WaitResult::Ok
    } else if kr == KERN_ABORTED as i32 {
        WaitResult::Interrupted
    } else {
        WaitResult::Error
    }
}

/// [`dtape_semaphore_down`] for callers that only care whether they were interrupted.
/// Fatal on a real error, as in the C.
#[no_mangle]
pub unsafe extern "C" fn dtape_semaphore_down_simple(semaphore: *mut dtape_semaphore_t) -> bool {
    match dtape_semaphore_down(semaphore) {
        WaitResult::Ok => true,
        WaitResult::Interrupted => false,
        WaitResult::Error => {
            panic(c"Failed to lower up-count of duct-taped XNU semaphore".as_ptr());
            // panic() is noreturn in practice but is not declared so; keep the type honest.
            unreachable!()
        }
    }
}
