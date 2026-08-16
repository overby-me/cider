//! `xnu-sys/src/stubs.c`, in Rust (#71, thirteenth file).
//!
//! 232 lines, all of it glue: the XNU entry points xnu-sys does not implement, plus
//! `xnu_sys_stub_log`, which every other glue file calls to record that it reached one. Nearly all
//! of it is mechanical, so the interesting parts are the four that are not.
//!
//! **`panic` stays in C.** It is the fourth and last variadic DEFINITION, and it has moved to
//! `xnu-sys/src/xnu_sys_rs_shims.c` with the three from misc.c. Stable Rust cannot define a
//! variadic function; [`crate::xnu::misc`] explains the split.
//!
//! **The globals are `static mut` and their sizes are real.** `machine_info` and
//! `dead_task_statistics` are not decoration: XNU writes into them, so they are bound rather
//! than respelled, and a size that disagreed would corrupt whatever the linker put next.
//!
//! **`XNU_SYS_FATAL_STUBS` is a build-time choice, so the C makes it.** It comes through the
//! derived-constants enum, which reads 0 with the current flags, exactly as the `#ifndef` in
//! stubs.h decides.
//!
//! **The constructor became a lazy read.** The C uses `__attribute__((constructor))` to check
//! `XNU_SYS_LOG_SAFE_STUBS` once at load. A Rust `.init_array` entry in an *rlib* is exactly the
//! kind of thing the linker drops when nothing references it, which would silently turn safe
//! stub logging off for good, so this reads the variable on first use instead. `getenv` does not
//! change under us, so the answer is the same either way.

use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::ptr;
use std::sync::OnceLock;

use crate::bindings::{
    self, boolean_t, xnu_sys_rs_host_consts_XNU_SYS_RS_XNU_SYS_FATAL_STUBS, expired_task_statistics_t,
    fileglob, host_priv_t, host_t, ipc_kmsg_t, ipc_port_t, ipc_voucher_t, kmod_args_t,
    kmod_control_flavor_t, kmod_info_array_t, kmod_t, kqueue, ledger_t, mach_msg_header_t,
    mach_msg_type_number_t, mach_port_mscount_t, mach_port_name_t, machine_info, task_t,
    thread_group, thread_t, turnstile, vm_address_t, vm_object_t, vm_offset_t,
    waitq_set_prepost_hook_t, workqueue, KERN_FAILURE, KERN_NOT_SUPPORTED,
    TASK_POLICY_LATENCY_QOS,
};

/// `TRUE` and `FALSE` as XNU spells them for `boolean_t`.
const TRUE: boolean_t = 1;
const FALSE: boolean_t = 0;

/// A zero of any bound struct, for the globals the C leaves in .bss.
///
/// `MaybeUninit::zeroed` is a const fn, so these are zeroed at compile time exactly as a C
/// tentative definition is, rather than filled by an initialiser that has to run first.
const fn zeroed<T>() -> T {
    unsafe { std::mem::MaybeUninit::zeroed().assume_init() }
}

// The globals. Every one is `static mut`, because every one of them is a mutable C global; a
// Rust `static` would put them in .rodata and turn a write into a SIGSEGV.
#[no_mangle]
pub static mut kdebug_enable: c_uint = 0;
#[no_mangle]
pub static mut avenrun: [u32; 3] = [0; 3];
#[no_mangle]
pub static mut mach_factor: [u32; 3] = [0; 3];
#[no_mangle]
pub static mut compressor_object: vm_object_t = zeroed();
#[no_mangle]
pub static mut c_segment_pages_compressed: u32 = 0;
#[no_mangle]
pub static mut dead_task_statistics: expired_task_statistics_t = zeroed();
#[no_mangle]
pub static mut machine_info: machine_info = zeroed();
#[no_mangle]
pub static mut sched_allow_NO_SMT_threads: c_int = 0;

extern "C" {
    fn getenv(name: *const c_char) -> *mut c_char;
}

/// `XNU_SYS_LOG_SAFE_STUBS`, read once. See the module note on why this is not a constructor.
fn log_safe_stubs() -> bool {
    static CACHED: OnceLock<bool> = OnceLock::new();
    *CACHED.get_or_init(|| unsafe { !getenv(b"XNU_SYS_LOG_SAFE_STUBS\0".as_ptr() as *const c_char).is_null() })
}

/// The stub logger every other glue file calls, through the three macros in
/// `internal-include/ciderd/xnu-sys/stubs.h` and their Rust equivalents in
/// [`crate::xnu::stub_family`].
#[no_mangle]
pub unsafe extern "C" fn xnu_sys_stub_log(
    function_name: *const c_char,
    safety: c_int,
    subsection: *const c_char,
) {
    let (log_level, do_abort, kind_info) = if safety == 0 {
        (
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_warning,
            xnu_sys_rs_host_consts_XNU_SYS_RS_XNU_SYS_FATAL_STUBS != 0,
            "",
        )
    } else if safety < 0 {
        (
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_error,
            true,
            " (unsafe)",
        )
    } else {
        if !log_safe_stubs() {
            return;
        }
        (
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
            false,
            " (safe)",
        )
    };

    let function_name = crate::xnu::misc::cstr(function_name);
    let subsection = crate::xnu::misc::cstr(subsection);
    let separator = if subsection.is_empty() { "" } else { ":" };
    crate::xnu::misc::log(
        log_level,
        &format!("stub{kind_info}: {function_name}{separator}{subsection}"),
    );

    if do_abort {
        std::process::abort();
    }
}

#[no_mangle]
pub unsafe extern "C" fn bank_get_bank_ledger_thread_group_and_persona(
    _voucher: ipc_voucher_t,
    _bankledger: *mut ledger_t,
    _banktg: *mut *mut thread_group,
    _persona_id: *mut u32,
) -> bindings::kern_return_t {
    crate::xnu_sys_stub!();
    KERN_FAILURE as bindings::kern_return_t
}

#[no_mangle]
pub extern "C" fn cpu_number() -> c_int {
    crate::xnu_sys_stub_safe!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn fileport_releasefg(_fg: *mut fileglob) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn workq_deallocate_safe(_wq: *mut workqueue) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn workq_is_current_thread_updating_turnstile(
    _wq: *mut workqueue,
) -> bool {
    crate::xnu_sys_stub!();
    false
}

#[no_mangle]
pub unsafe extern "C" fn workq_reference(_wq: *mut workqueue) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn workq_schedule_creator_turnstile_redrive(
    _wq: *mut workqueue,
    _locked: bool,
) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn uext_server(
    _request: ipc_kmsg_t,
    _reply: *mut ipc_kmsg_t,
) -> bindings::kern_return_t {
    crate::xnu_sys_stub!();
    KERN_FAILURE as bindings::kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn upl_no_senders(_port: ipc_port_t, _mscount: mach_port_mscount_t) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn suid_cred_destroy(_port: ipc_port_t) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn suid_cred_notify(_msg: *mut mach_msg_header_t) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub extern "C" fn ml_get_interrupts_enabled() -> boolean_t {
    TRUE
}

#[no_mangle]
pub extern "C" fn ml_set_interrupts_enabled(_enable: boolean_t) -> boolean_t {
    TRUE
}

#[no_mangle]
pub extern "C" fn ml_delay_should_spin(_interval: u64) -> boolean_t {
    FALSE
}

#[no_mangle]
pub extern "C" fn ml_wait_max_cpus() -> c_uint {
    0
}

#[no_mangle]
pub unsafe extern "C" fn kqueue_turnstile(_kqu: *mut kqueue) -> *mut turnstile {
    crate::xnu_sys_stub!();
    ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn waitq_set__CALLING_PREPOST_HOOK__(
    _kq_hook: *mut waitq_set_prepost_hook_t,
) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn work_interval_port_notify(_msg: *mut mach_msg_header_t) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn proc_get_effective_thread_policy(
    _thread: thread_t,
    flavor: c_int,
) -> c_int {
    if flavor == TASK_POLICY_LATENCY_QOS as c_int {
        return 0;
    }
    // EXPERIMENT (task #47): was `return -1`. Every caller of this in XNU treats
    // the result as a boolean flag (DARWIN_BG, PASSIVE_IO) or a small non-negative
    // tier/QoS class (IO, QOS, THROUGH_QOS), and -1 is TRUTHY -- so every thread
    // read as "background" and every tier came back nonsense. 0 is the neutral
    // answer in all of those: not background, no throttling, unspecified QoS.
    crate::xnu_sys_stub!("unimplemented flavor");
    0
}

#[no_mangle]
pub unsafe extern "C" fn PE_parse_boot_argn(
    _arg_string: *const c_char,
    _arg_ptr: *mut c_void,
    _max_len: c_int,
) -> boolean_t {
    crate::xnu_sys_stub_safe!();
    FALSE
}

#[no_mangle]
pub extern "C" fn machine_timeout_suspended() -> boolean_t {
    crate::xnu_sys_stub_safe!();
    TRUE
}

#[no_mangle]
pub unsafe extern "C" fn IOTaskHasEntitlement(
    _task: task_t,
    _entitlement: *const c_char,
) -> boolean_t {
    crate::xnu_sys_stub_safe!();
    TRUE
}

#[no_mangle]
pub unsafe extern "C" fn kmod_create(
    _host_priv: host_priv_t,
    _addr: vm_address_t,
    _id: *mut kmod_t,
) -> bindings::kern_return_t {
    crate::xnu_sys_stub_safe!();
    KERN_NOT_SUPPORTED as bindings::kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn kmod_destroy(
    _host_priv: host_priv_t,
    _id: kmod_t,
) -> bindings::kern_return_t {
    crate::xnu_sys_stub_safe!();
    KERN_NOT_SUPPORTED as bindings::kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn kmod_control(
    _host_priv: host_priv_t,
    _id: kmod_t,
    _flavor: kmod_control_flavor_t,
    _data: *mut kmod_args_t,
    _data_count: *mut mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::xnu_sys_stub_safe!();
    KERN_NOT_SUPPORTED as bindings::kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn kmod_get_info(
    _host: host_t,
    _kmod_list: *mut kmod_info_array_t,
    _kmod_count: *mut mach_msg_type_number_t,
) -> bindings::kern_return_t {
    crate::xnu_sys_stub_safe!();
    KERN_NOT_SUPPORTED as bindings::kern_return_t
}

/// The C ends in `xnu_sys_stub_unsafe()`, which logs and then `__builtin_unreachable()`. The Rust
/// macro aborts, which is `!`, so these three need no return value either.
#[no_mangle]
pub unsafe extern "C" fn kext_request(
    _host_priv: host_priv_t,
    _client_log_spec: u32,
    _request_in: vm_offset_t,
    _request_length_in: mach_msg_type_number_t,
    _response_out: *mut vm_offset_t,
    _response_length_out: *mut mach_msg_type_number_t,
    _log_data_out: *mut vm_offset_t,
    _log_data_length_out: *mut mach_msg_type_number_t,
    _op_result: *mut bindings::kern_return_t,
) -> bindings::kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn PE_i_can_has_debugger(_something: *mut u32) -> u32 {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub extern "C" fn work_interval_port_type_render_server(_port_name: mach_port_name_t) -> bool {
    crate::xnu_sys_stub_safe!();
    false
}

#[no_mangle]
pub unsafe extern "C" fn convert_suid_cred_to_port(
    _sc: bindings::suid_cred_t,
) -> ipc_port_t {
    crate::xnu_sys_stub_unsafe!()
}
