//! The hand-written half of `xnu-sys/src/traps.c` (#71, tenth file).
//!
//! Six trivial wrappers the C writes out by hand, each calling an XNU trap with a NULL args
//! pointer because the trap takes none. The OTHER twenty-nine wrappers in that file come from
//! `DSERVER_XNU_SYS_DEFS`, a generated macro, and are in [`crate::xnu::traps_generated`], emitted from
//! the same table by `scripts/gen/gen-xnu-sys-traps.nu`.
//!
//! NOT `traps.rs`: `src/linux/server/src/traps.rs` already exists and is the DAEMON side, which
//! DECLARES these symbols and calls them from handlers. This module is what defines them, so
//! the two are complementary. Cross-checked at port time: of the 24 wrappers the daemon
//! declares by hand and the table also generates, the signatures agree on all 24.

use crate::bindings::{
    host_self_trap, mach_reply_port, mk_timer_create_trap, task_self_trap,
    thread_get_special_reply_port, thread_self_trap,
};
use std::ptr;

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_task_self_trap() -> u32 {
    task_self_trap(ptr::null_mut()) as u32
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_host_self_trap() -> u32 {
    host_self_trap(ptr::null_mut()) as u32
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_self_trap() -> u32 {
    thread_self_trap(ptr::null_mut()) as u32
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_mach_reply_port() -> u32 {
    mach_reply_port(ptr::null_mut()) as u32
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_get_special_reply_port() -> u32 {
    thread_get_special_reply_port(ptr::null_mut()) as u32
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_mk_timer_create() -> u32 {
    mk_timer_create_trap(ptr::null_mut()) as u32
}
