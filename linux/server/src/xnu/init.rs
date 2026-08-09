//! xnu-sys start-up: the Rust replacement for `xnu-sys/src/init.c` (#71, sixth file).
//!
//! `dtape_init` is the single entry point the daemon calls to bring the XNU emulation up. It
//! creates the zones the kernel allocates out of, initialises two locks, and then runs about
//! twenty subsystem initialisers in an order that matters.
//!
//! WHY THIS FILE IS TRACTABLE, which was not obvious and took three corrections to the ranking
//! tool to see. Its only apparent blocker was `dtape_log_debug`, and that is a macro forwarding
//! to `dtape_log`, which is a real symbol in the archive; Rust cannot DEFINE a C variadic but
//! it can CALL one, exactly as `semaphore.rs` calls `panic`. Its opaque count read 23 and was
//! really 9, the difference being function names the pattern matched and a preprocessor run
//! that had been failing on a generated header.
//!
//! SIZES, NOT FIELDS. Seven of the eight structs here exist in this file only as
//! `sizeof(struct X)` handed to `zone_create`, and an OPAQUE binding carries the size. So none
//! of them is reopened. `struct task_id_token` is the exception worth knowing about: XNU
//! defines it in `osfmk/kern/task_ident.c` rather than a header, and the C redefines it locally
//! to get its size. That definition now lives in `wrapper.h`, so the size is still one the C
//! compiler computed (24) rather than a number typed into Rust.
//!
//! THIS FILE DEFINES `dtape_hooks`, the vtable every other glue file dereferences. That
//! direction, a C archive reading a Rust-defined global, was proven by experiment before any
//! of this port was written, with a negative control: removing the definition fails the link
//! with an undefined reference.

use std::os::raw::{c_char, c_int};
use std::ptr;

use crate::xnu::locks::{lck_mtx_init, lck_spin_init};

use crate::bindings::{
    dtape_hooks_t, ipc_kmsg_zone, ipc_object_zones, ipc_space_zone, lck_attr_t, lck_grp_t,
    lck_spin_t, processor_t, realhost, zone_create,
    zone_create_flags_t, zone_t, IOT_PORT, IOT_PORT_SET,
};

use crate::bindings::{
    dtape_rs_host_consts_DTAPE_RS_IKM_SAVED_KMSG_SIZE as IKM_SAVED_KMSG_SIZE,
    dtape_rs_host_consts_DTAPE_RS_SIZEOF_TASK_ID_TOKEN as SIZEOF_TASK_ID_TOKEN,
    zone_create_flags_t_ZC_CACHING as ZC_CACHING, zone_create_flags_t_ZC_NONE as ZC_NONE,
    zone_create_flags_t_ZC_NOENCRYPT as ZC_NOENCRYPT,
    zone_create_flags_t_ZC_NOSEQUESTER as ZC_NOSEQUESTER,
    zone_create_flags_t_ZC_ZFREE_CLEARMEM as ZC_ZFREE_CLEARMEM,
};

/// The hooks vtable, DEFINED here as the C did. Every other glue file reads it.
#[no_mangle]
pub static mut dtape_hooks: *const dtape_hooks_t = ptr::null();

// xnu-sys is Rust since #71, so its four initialisers are imported rather than declared
// through the linker (#75).
use crate::xnu::psynch::dtape_psynch_init;
use crate::xnu::task::dtape_task_init;
use crate::xnu::memory::dtape_memory_init;
use crate::xnu::timer::dtape_timer_init;

extern "C" {
    // The zones and the lock this file fills in. The C declares these extern itself, at the top
    // of init.c, for the same reason: they live in XNU translation units with no header.
    static mut semaphore_zone: zone_t;
    static mut ipc_importance_task_zone: zone_t;
    static mut ipc_importance_inherit_zone: zone_t;
    static mut task_id_token_zone: zone_t;
    static mut ipc_importance_lock_data: lck_spin_t;

    // The subsystem initialisers, in the order dtape_init runs them. Declared rather than bound
    // because init.c declares most of them itself; they are all void(void). The four that are
    // RUST now are imported below instead (#75); what stays here is XNU.
    fn dtape_mk_timer_init();
    fn timer_call_init();
    fn ipc_table_init();
    fn ipc_voucher_init();
    fn ipc_init();
    fn mig_init();
    fn host_notify_init();
    fn user_data_attr_manager_init();
    fn waitq_bootstrap();
    fn clock_init();
    fn turnstiles_init();
    fn host_statistics_init();
    fn thread_call_initialize();
    fn ipc_thread_call_init();
    fn clock_service_create();
    fn thread_deallocate_daemon_init();
    fn ux_handler_setup();

    fn ipc_processor_init(processor: processor_t);
    fn ipc_processor_enable(processor: processor_t);

    // Variadic, and callable even though Rust cannot define one. dtape_log_debug is a macro
    // forwarding to this with the debug level, so the port calls it directly.
    fn dtape_log(level: c_int, format: *const c_char, ...);
}

/// `dtape_log_level_debug`, the level `dtape_log_debug` passes.
///
/// Spelled out because it is an enumerator in a header this file does not otherwise need, and
/// because it is a RETURN-less trace call: a wrong value here mislabels a log line and nothing
/// else. Every other constant in this file is generated.
const DTAPE_LOG_LEVEL_DEBUG: c_int = 0;

/// `dtape_log_debug("...")` for a fixed string, which is every use in this file.
fn log_debug(what: &str) {
    // The C passes a literal format string with no arguments. Building a NUL-terminated copy
    // and passing it as the format is the same call; the string never contains a percent.
    let mut buf = Vec::with_capacity(what.len() + 1);
    buf.extend_from_slice(what.as_bytes());
    buf.push(0);
    unsafe { dtape_log(DTAPE_LOG_LEVEL_DEBUG, buf.as_ptr() as *const c_char) }
}

/// Create a zone, with the name as a C string literal.
unsafe fn zone(name: &[u8], size: usize, flags: zone_create_flags_t) -> zone_t {
    debug_assert_eq!(name.last(), Some(&0), "zone names must be NUL terminated");
    zone_create(name.as_ptr() as *const c_char, size as crate::bindings::vm_size_t, flags)
}

/// Bring xnu-sys up. Called once by the daemon, before any guest exists.
#[no_mangle]
pub unsafe extern "C" fn dtape_init(hooks: *const dtape_hooks_t) {
    dtape_hooks = hooks;

    log_debug("dtape_processor_init");
    crate::xnu::processor::dtape_processor_init();

    log_debug("dtape_memory_init");
    dtape_memory_init();

    // Sizes only: none of these structs has a field touched here, so they stay OPAQUE in the
    // bindings and only their size crosses.
    ipc_space_zone = zone(
        b"ipc spaces\0",
        std::mem::size_of::<crate::bindings::ipc_space>(),
        ZC_NOENCRYPT,
    );
    ipc_kmsg_zone = zone(
        b"ipc kmsgs\0",
        IKM_SAVED_KMSG_SIZE as usize,
        ZC_CACHING | ZC_ZFREE_CLEARMEM,
    );
    semaphore_zone = zone(
        b"semaphores\0",
        std::mem::size_of::<crate::bindings::semaphore>(),
        ZC_NONE,
    );

    ipc_object_zones[IOT_PORT as usize] = zone(
        b"ipc ports\0",
        std::mem::size_of::<crate::bindings::ipc_port>(),
        ZC_NOENCRYPT | ZC_CACHING | ZC_ZFREE_CLEARMEM | ZC_NOSEQUESTER,
    );
    ipc_object_zones[IOT_PORT_SET as usize] = zone(
        b"ipc port sets\0",
        std::mem::size_of::<crate::bindings::ipc_pset>(),
        ZC_NOENCRYPT | ZC_ZFREE_CLEARMEM | ZC_NOSEQUESTER,
    );

    ipc_importance_task_zone = zone(
        b"ipc task importance\0",
        std::mem::size_of::<crate::bindings::ipc_importance_task>(),
        ZC_NOENCRYPT,
    );
    ipc_importance_inherit_zone = zone(
        b"ipc importance inherit\0",
        std::mem::size_of::<crate::bindings::ipc_importance_inherit>(),
        ZC_NOENCRYPT,
    );

    // The one size that cannot come from a bindgen struct, because XNU defines
    // struct task_id_token in a .c file. See wrapper.h.
    task_id_token_zone = zone(
        b"task_id_token\0",
        SIZEOF_TASK_ID_TOKEN as usize,
        ZC_ZFREE_CLEARMEM,
    );

    // LCK_GRP_NULL and LCK_ATTR_NULL are macros for null pointers.
    lck_mtx_init(
        ptr::addr_of_mut!(realhost.lock),
        ptr::null_mut::<lck_grp_t>(),
        ptr::null_mut::<lck_attr_t>(),
    );
    lck_spin_init(
        ptr::addr_of_mut!(ipc_importance_lock_data),
        ptr::null_mut::<lck_grp_t>(),
        ptr::null_mut::<lck_attr_t>(),
    );

    log_debug("dtape_timer_init");
    dtape_timer_init();

    log_debug("dtape_mk_timer_init");
    dtape_mk_timer_init();

    log_debug("timer_call_init");
    timer_call_init();

    log_debug("ipc_table_init");
    ipc_table_init();

    log_debug("ipc_voucher_init");
    ipc_voucher_init();

    log_debug("dtape_task_init");
    dtape_task_init();

    log_debug("ipc_init");
    ipc_init();

    // Every processor EXCEPT the master gets an IPC port; the master already has one from
    // ipc_init. Skipping the wrong one here would leave a processor unreachable over Mach.
    for i in 0..crate::xnu::processor::processor_count as usize {
        let p = crate::xnu::processor::processor_array[i];
        if p == crate::xnu::processor::master_processor {
            continue;
        }
        ipc_processor_init(p);
        ipc_processor_enable(p);
    }

    log_debug("mig_init");
    mig_init();

    log_debug("host_notify_init");
    host_notify_init();

    log_debug("user_data_attr_manager_init");
    user_data_attr_manager_init();

    log_debug("waitq_bootstrap");
    waitq_bootstrap();

    log_debug("clock_init");
    clock_init();

    log_debug("turnstiles_init");
    turnstiles_init();

    log_debug("host_statistics_init");
    host_statistics_init();
}

/// The half of start-up that must run ON a kernel microthread rather than on the caller.
///
/// Splitting these out is what made multithreaded guests work at all (the psynch and
/// thread-call subsystems allocate per-thread state), so the split is load bearing and not
/// tidiness.
#[no_mangle]
pub unsafe extern "C" fn dtape_init_in_thread() {
    log_debug("thread_call_initialize");
    thread_call_initialize();

    log_debug("ipc_thread_call_init");
    ipc_thread_call_init();

    log_debug("clock_service_create");
    clock_service_create();

    log_debug("thread_deallocate_daemon_init");
    thread_deallocate_daemon_init();

    ux_handler_setup();

    dtape_psynch_init();
}

/// Empty in the C, and kept empty rather than dropped: it is part of the exported contract.
#[no_mangle]
pub unsafe extern "C" fn dtape_deinit() {}

#[cfg(test)]
mod tests {
    use super::*;

    /// The zone sizes must be the ones the C computed. These are the allocation sizes the
    /// kernel then carves objects out of, so a wrong one is silent heap corruption rather than
    /// a crash, which is exactly why none of them is written as a literal here.
    #[test]
    fn the_zone_sizes_are_the_compilers_and_not_transcribed() {
        assert_eq!(SIZEOF_TASK_ID_TOKEN as usize, 24, "wrapper.h computed this, not this file");
        assert_eq!(IKM_SAVED_KMSG_SIZE as usize, 256);
        // The opaque bindings must still carry a real size, or every zone above is created
        // with a zero element size.
        for (name, size) in [
            ("ipc_space", std::mem::size_of::<crate::bindings::ipc_space>()),
            ("ipc_port", std::mem::size_of::<crate::bindings::ipc_port>()),
            ("ipc_pset", std::mem::size_of::<crate::bindings::ipc_pset>()),
            ("semaphore", std::mem::size_of::<crate::bindings::semaphore>()),
            (
                "ipc_importance_task",
                std::mem::size_of::<crate::bindings::ipc_importance_task>(),
            ),
            (
                "ipc_importance_inherit",
                std::mem::size_of::<crate::bindings::ipc_importance_inherit>(),
            ),
        ] {
            assert!(size > 0, "{name} bound with size 0, so its zone would be unusable");
        }
    }

    /// IOT_PORT and IOT_PORT_SET index ipc_object_zones, so they must be inside it.
    #[test]
    fn the_object_zone_indices_are_in_range() {
        let len = unsafe { ipc_object_zones.len() };
        assert!((IOT_PORT as usize) < len);
        assert!((IOT_PORT_SET as usize) < len);
        assert_ne!(IOT_PORT, IOT_PORT_SET);
    }
}
