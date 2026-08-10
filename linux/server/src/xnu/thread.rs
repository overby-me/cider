//! `xnu-sys/src/thread.c`, in Rust (#71, sixteenth and LAST file).
//!
//! NAMED `xnu_sys_thread` because `linux/server/src/thread.rs` is the DAEMON side. Fourth time
//! after kqchan, psynch and task.
//!
//! 1,383 lines of glue after the copied-XNU half moved to `thread_xnu.c`. It is the most
//! intricate file of the sixteen, and the reason is that three different worlds meet in it:
//! Linux signals arrive, get translated into Mach exceptions, and are delivered through XNU's
//! exception machinery, while the same file also owns thread creation, blocking and the saved
//! x86 register state.
//!
//! **`struct thread` and `xnu_sys_thread_user_state` are both reopened**, at a measured +13
//! structs and 58,000 bytes, because this file reaches 18 distinct fields of the first and
//! writes straight through the second. [`crate::xnu::layout`] is what makes that safe: it asserts at
//! build time that Rust and C agree on the layout, and it holds in this configuration.
//!
//! **The four thread lock macros are shims.** `thread_lock` is
//! `simple_lock(&th->sched_lock, &thread_lck_grp)`, and that lock group is file-static to XNU,
//! so no amount of reopening makes it reachable from Rust.
//!
//! **`thread_handoff_internal` keeps its symbol.** It is glue, but `thread_xnu.c` calls it, so
//! it lost its `static` when the file was split and Rust provides the symbol now.

use std::mem::offset_of;
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::ptr;

use crate::bindings::{
    self, boolean_t, xnu_sys_task, xnu_sys_thread, xnu_sys_thread_user_state, integer_t, kern_return_t,
    mach_msg_header_t, mach_msg_type_number_t, task_t, thread_state_t, thread_t, wait_result_t,
};
use crate::xnu::init::xnu_sys_hooks;

// The Linux constants thread.c spells out for itself.
const LINUX_ENOSYS: c_int = 38;
const LINUX_EFAULT: c_int = 14;
const LINUX_SI_USER: c_int = 0;
const LINUX_SI_KERNEL: c_int = 0x80;
const LINUX_TRAP_HWBKPT: c_int = 4;
const LINUX_SIGSEGV: c_int = 11;
const LINUX_SIGBUS: c_int = 7;
const LINUX_SIGILL: c_int = 4;
const LINUX_SIGFPE: c_int = 8;
const LINUX_SIGTRAP: c_int = 5;

extern "C" {
    fn malloc(size: usize) -> *mut c_void;
    fn free(ptr: *mut c_void);
    /// Defined in `pthread/kern_synch.c` and declared only in psynch.c, so bindgen never sees it.
    fn ux_exception(exception: c_int, code: i64, subcode: i64) -> c_int;
}

// stub
#[no_mangle]
pub static mut sched_mach_factor: u32 = 0;

// stub
#[no_mangle]
pub static thread_qos_policy_params: bindings::qos_policy_params_t =
    unsafe { std::mem::MaybeUninit::zeroed().assume_init() };

// stub
#[no_mangle]
pub static mut thread_max: c_int =
    bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_CONFIG_THREAD_MAX as c_int;

/// `xnu_sys_thread_for_xnu_thread`: `always_inline` in C, so no symbol.
#[inline]
pub(crate) unsafe fn thread_for_xnu_thread(xnu_thread: thread_t) -> *mut xnu_sys_thread {
    if xnu_thread.is_null() {
        return ptr::null_mut();
    }
    (xnu_thread as *mut u8).sub(offset_of!(xnu_sys_thread, xnu_thread)) as *mut xnu_sys_thread
}

/// `xnu_sys_task_for_thread`: the thread's XNU task, walked back to the xnu-sys one.
#[inline]
unsafe fn task_for_thread(thread: *mut xnu_sys_thread) -> *mut xnu_sys_task {
    crate::xnu::task::task_for_xnu_task((*thread).xnu_thread.task)
}

// The four lock macros, through their shims.
#[inline]
unsafe fn thread_lock(t: thread_t) {
    bindings::xnu_sys_rs_thread_lock(t);
}
#[inline]
unsafe fn thread_unlock(t: thread_t) {
    bindings::xnu_sys_rs_thread_unlock(t);
}

/// `LIST_INSERT_HEAD` and friends over `xnu_sys_thread_user_state.link`, which is a BSD
/// `LIST_ENTRY`: a forward pointer and a pointer to the previous link's forward pointer.
#[inline]
unsafe fn user_states_insert_head(head: *mut xnu_sys_thread, elem: *mut xnu_sys_thread_user_state) {
    let first = (*head).user_states.lh_first;
    (*elem).link.le_next = first;
    if !first.is_null() {
        (*first).link.le_prev = &mut (*elem).link.le_next;
    }
    (*head).user_states.lh_first = elem;
    (*elem).link.le_prev = &mut (*head).user_states.lh_first;
}

#[inline]
unsafe fn user_states_remove(elem: *mut xnu_sys_thread_user_state) {
    let next = (*elem).link.le_next;
    if !next.is_null() {
        (*next).link.le_prev = (*elem).link.le_prev;
    }
    *(*elem).link.le_prev = next;
}

#[inline]
unsafe fn user_states_first(thread: *mut xnu_sys_thread) -> *mut xnu_sys_thread_user_state {
    (*thread).user_states.lh_first
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_create(
    task: *mut xnu_sys_task,
    nsid: u64,
    context: *mut c_void,
) -> *mut xnu_sys_thread {
    let thread = malloc(std::mem::size_of::<xnu_sys_thread>()) as *mut xnu_sys_thread;
    if thread.is_null() {
        return ptr::null_mut();
    }

    (*thread).context = context;
    (*thread).processing_signal = false;
    (*thread).name = ptr::null();
    (*thread).waiting_suspended = false;
    (*thread).user_states.lh_first = ptr::null_mut();
    crate::xnu::locks::xnu_sys_mutex_init(&mut (*thread).suspension_mutex);
    crate::xnu::condvar::xnu_sys_condvar_init(&mut (*thread).suspension_condvar);
    ptr::write_bytes(
        &mut (*thread).xnu_thread as *mut _ as *mut u8,
        0,
        std::mem::size_of::<bindings::thread>(),
    );
    ptr::write_bytes(
        &mut (*thread).kwe as *mut _ as *mut u8,
        0,
        std::mem::size_of::<bindings::xnu_sys_opaque_ksyn_waitq_element>(),
    );

    ptr::write_bytes(
        &mut (*thread).default_state as *mut _ as *mut u8,
        0,
        std::mem::size_of::<xnu_sys_thread_user_state>(),
    );
    user_states_insert_head(thread, &mut (*thread).default_state);

    // this next section uses code adapted from XNU's thread_create_internal() in
    // osfmk/kern/thread.c

    (*thread).xnu_thread.wait_result =
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_WAITING as wait_result_t;
    (*thread).xnu_thread.options =
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_ABORTSAFE as u16;
    (*thread).xnu_thread.state = bindings::TH_RUN as c_int;

    bindings::xnu_sys_rs_os_ref_init(&mut (*thread).xnu_thread.ref_count as *mut _ as *mut _);

    (*thread).xnu_thread.task = &mut (*task).xnu_task;

    bindings::xnu_sys_rs_thread_lock_init(&mut (*thread).xnu_thread);
    bindings::xnu_sys_rs_wake_lock_init(&mut (*thread).xnu_thread);

    bindings::lck_mtx_init(
        &mut (*thread).xnu_thread.mutex,
        ptr::null_mut(),
        ptr::null_mut(),
    );

    bindings::ipc_thread_init(
        &mut (*thread).xnu_thread,
        bindings::ipc_thread_init_options_t::IPC_THREAD_INIT_NONE,
    );

    crate::xnu::task::task_lock(&mut (*task).xnu_task);

    bindings::xnu_sys_rs_task_reference_internal(&mut (*task).xnu_task);

    // queue_enter on the task's thread list, by the task_threads link
    queue_enter_threads(&mut (*task).xnu_task, &mut (*thread).xnu_thread);
    (*task).xnu_task.thread_count += 1;

    (*task).xnu_task.active_thread_count += 1;

    // active is a BITFIELD in struct thread, so bindgen gives it accessor methods rather than
    // a field. The C assignment is a plain store; this is the same store.
    (*thread).xnu_thread.set_active(1);

    (*thread).xnu_thread.turnstile = bindings::turnstile_alloc();

    crate::xnu::task::task_unlock(&mut (*task).xnu_task);

    (*thread).xnu_thread.thread_id = nsid;

    (*thread).xnu_thread.map = (*task).xnu_task.map;

    bindings::timer_call_setup(
        &mut (*thread).xnu_thread.wait_timer,
        Some(bindings::thread_timer_expire),
        &mut (*thread).xnu_thread as *mut _ as *mut c_void,
    );

    crate::xnu::psynch::xnu_sys_psynch_thread_init(thread);

    thread
}

/// `queue_enter(&task->threads, thread, thread_t, task_threads)`: append to the circular list
/// through the thread's own `task_threads` link.
#[inline]
unsafe fn queue_enter_threads(task: task_t, thread: thread_t) {
    let head = &mut (*task).threads as *mut bindings::queue_head_t;
    let prev = (*head).prev;
    (*thread).task_threads.next = head as *mut _;
    (*thread).task_threads.prev = prev;
    (*(prev as *mut bindings::queue_entry)).next = &mut (*thread).task_threads as *mut _ as *mut _;
    (*head).prev = &mut (*thread).task_threads as *mut _ as *mut _;
}

/// `queue_remove(&task->threads, thread, thread_t, task_threads)`.
#[inline]
unsafe fn queue_remove_threads(task: task_t, thread: thread_t) {
    let next = (*thread).task_threads.next;
    let prev = (*thread).task_threads.prev;
    (*(prev as *mut bindings::queue_entry)).next = next;
    (*(next as *mut bindings::queue_entry)).prev = prev;
    let _ = task;
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_destroy(thread: *mut xnu_sys_thread) {
    crate::xnu::misc::log(
        bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
        &format!("{}: thread being destroyed", (*thread).xnu_thread.thread_id),
    );

    crate::xnu::psynch::xnu_sys_psynch_thread_destroy(thread);

    // this next section uses code adapted from XNU's thread_deallocate_complete() in
    // osfmk/kern/thread.c

    bindings::ipc_thread_disable(&mut (*thread).xnu_thread);
    bindings::ipc_thread_terminate(&mut (*thread).xnu_thread);

    if !(*thread).xnu_thread.turnstile.is_null() {
        bindings::turnstile_deallocate((*thread).xnu_thread.turnstile);
    }

    if !(*thread).xnu_thread.ith_voucher.is_null() {
        bindings::ipc_voucher_release((*thread).xnu_thread.ith_voucher);
    }

    thread_lock(&mut (*thread).xnu_thread);

    // Cancel wait timer, and wait for concurrent expirations.
    if (*thread).xnu_thread.wait_timer_is_set {
        (*thread).xnu_thread.wait_timer_is_set = false;

        if bindings::timer_call_cancel(&mut (*thread).xnu_thread.wait_timer) != 0 {
            (*thread).xnu_thread.wait_timer_active -= 1;
        }
    }

    while std::ptr::read_volatile(&(*thread).xnu_thread.wait_timer_active) > 0 {}

    // pull the thread from any waitqs it might have been waiting on
    (*thread).xnu_thread.state |= bindings::TH_TERMINATE as c_int;
    (*thread).xnu_thread.state &= !(bindings::TH_UNINT as c_int);
    bindings::clear_wait_internal(
        &mut (*thread).xnu_thread,
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED as wait_result_t,
    );

    thread_unlock(&mut (*thread).xnu_thread);

    bindings::lck_mtx_destroy(&mut (*thread).xnu_thread.mutex, ptr::null_mut());

    // remove this thread from the task's thread list
    let xtask = (*thread).xnu_thread.task;
    crate::xnu::task::task_lock(xtask);
    queue_remove_threads(xtask, &mut (*thread).xnu_thread);
    (*xtask).thread_count -= 1;
    crate::xnu::task::task_unlock(xtask);

    crate::xnu::task::task_deallocate(xtask);

    (*xnu_sys_hooks).thread_context_dispose.expect("thread_context_dispose hook")(
        (*thread).context,
    );

    free(thread as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_entering(thread: *mut xnu_sys_thread) {
    // if the thread is entering, it cannot be waiting
    (*thread).xnu_thread.state &= !((bindings::TH_WAIT | bindings::TH_UNINT) as c_int);
    (*thread).xnu_thread.state |= bindings::TH_RUN as c_int;
    (*thread).xnu_thread.block_hint = bindings::block_hint_t::kThreadWaitNone;
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_exiting(thread: *mut xnu_sys_thread) {
    (*thread).xnu_thread.state &= !(bindings::TH_RUN as c_int);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_set_handles(
    thread: *mut xnu_sys_thread,
    pthread_handle: usize,
    dispatch_qaddr: usize,
) {
    thread_lock(&mut (*thread).xnu_thread);
    (*thread).pthread_handle = pthread_handle;
    (*thread).dispatch_qaddr = dispatch_qaddr;
    thread_unlock(&mut (*thread).xnu_thread);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_for_port(thread_port: u32) -> *mut xnu_sys_thread {
    let xnu_thread =
        bindings::port_name_to_thread(thread_port, bindings::port_to_thread_options_t::PORT_TO_THREAD_NONE);
    if xnu_thread.is_null() {
        return ptr::null_mut();
    }
    // port_name_to_thread returns a reference on the thread upon success.
    // because we cannot take a reference on the duct-taped thread owner,
    // this reference is meaningless. therefore, we drop it.
    // we entrust our caller with the responsibility of ensuring it remains alive.
    thread_deallocate(xnu_thread);
    thread_for_xnu_thread(xnu_thread)
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_context(thread: *mut xnu_sys_thread) -> *mut c_void {
    (*thread).context
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_load_state_from_user(
    thread: *mut xnu_sys_thread,
    thread_state_address: usize,
    float_state_address: usize,
) -> c_int {
    use bindings::dserver_rpc_architecture_t as Arch;
    let task = task_for_thread(thread);

    if (*task).architecture == Arch::dserver_rpc_architecture_x86_64 {
        let mut tstate: bindings::x86_thread_state64_t = std::mem::zeroed();
        let mut fstate: bindings::x86_float_state64_t = std::mem::zeroed();

        if crate::xnu::memory::copyin(
            thread_state_address as bindings::user_addr_t,
            &mut tstate as *mut _ as *mut c_void,
            std::mem::size_of_val(&tstate) as bindings::vm_size_t,
        ) != 0
            || crate::xnu::memory::copyin(
                float_state_address as bindings::user_addr_t,
                &mut fstate as *mut _ as *mut c_void,
                std::mem::size_of_val(&fstate) as bindings::vm_size_t,
            ) != 0
        {
            return -LINUX_EFAULT;
        }

        thread_set_state(
            current_thread(),
            bindings::x86_THREAD_STATE64 as c_int,
            &mut tstate as *mut _ as thread_state_t,
            bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE64_COUNT
                as mach_msg_type_number_t,
        );
        thread_set_state(
            current_thread(),
            bindings::x86_FLOAT_STATE64 as c_int,
            &mut fstate as *mut _ as thread_state_t,
            bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE64_COUNT
                as mach_msg_type_number_t,
        );
    } else if (*task).architecture == Arch::dserver_rpc_architecture_i386 {
        let mut tstate: bindings::x86_thread_state32_t = std::mem::zeroed();
        let mut fstate: bindings::x86_float_state32_t = std::mem::zeroed();

        if crate::xnu::memory::copyin(
            thread_state_address as bindings::user_addr_t,
            &mut tstate as *mut _ as *mut c_void,
            std::mem::size_of_val(&tstate) as bindings::vm_size_t,
        ) != 0
            || crate::xnu::memory::copyin(
                float_state_address as bindings::user_addr_t,
                &mut fstate as *mut _ as *mut c_void,
                std::mem::size_of_val(&fstate) as bindings::vm_size_t,
            ) != 0
        {
            return -LINUX_EFAULT;
        }

        thread_set_state(
            current_thread(),
            bindings::x86_THREAD_STATE32 as c_int,
            &mut tstate as *mut _ as thread_state_t,
            bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE32_COUNT
                as mach_msg_type_number_t,
        );
        thread_set_state(
            current_thread(),
            bindings::x86_FLOAT_STATE32 as c_int,
            &mut fstate as *mut _ as thread_state_t,
            bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE32_COUNT
                as mach_msg_type_number_t,
        );
    } else {
        crate::xnu::misc::log(
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_error,
            &format!(
                "xnu_sys_thread_load_state_from_user() unimplemented for architecture: {:?}",
                (*task).architecture
            ),
        );
        return -LINUX_ENOSYS;
    }

    0
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_save_state_to_user(
    thread: *mut xnu_sys_thread,
    thread_state_address: usize,
    float_state_address: usize,
) -> c_int {
    use bindings::dserver_rpc_architecture_t as Arch;
    let task = task_for_thread(thread);

    if (*task).architecture == Arch::dserver_rpc_architecture_x86_64 {
        let mut tstate: bindings::x86_thread_state64_t = std::mem::zeroed();
        let mut fstate: bindings::x86_float_state64_t = std::mem::zeroed();

        let mut count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE64_COUNT
            as mach_msg_type_number_t;
        thread_get_state(
            current_thread(),
            bindings::x86_THREAD_STATE64 as c_int,
            &mut tstate as *mut _ as thread_state_t,
            &mut count,
        );

        count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE64_COUNT
            as mach_msg_type_number_t;
        thread_get_state(
            current_thread(),
            bindings::x86_FLOAT_STATE64 as c_int,
            &mut fstate as *mut _ as thread_state_t,
            &mut count,
        );

        if crate::xnu::memory::copyout(
            &tstate as *const _ as *const c_void,
            thread_state_address as bindings::user_addr_t,
            std::mem::size_of_val(&tstate) as bindings::vm_size_t,
        ) != 0
            || crate::xnu::memory::copyout(
                &fstate as *const _ as *const c_void,
                float_state_address as bindings::user_addr_t,
                std::mem::size_of_val(&fstate) as bindings::vm_size_t,
            ) != 0
        {
            return -LINUX_EFAULT;
        }
    } else if (*task).architecture == Arch::dserver_rpc_architecture_i386 {
        let mut tstate: bindings::x86_thread_state32_t = std::mem::zeroed();
        let mut fstate: bindings::x86_float_state32_t = std::mem::zeroed();

        let mut count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE32_COUNT
            as mach_msg_type_number_t;
        thread_get_state(
            current_thread(),
            bindings::x86_THREAD_STATE32 as c_int,
            &mut tstate as *mut _ as thread_state_t,
            &mut count,
        );

        count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE32_COUNT
            as mach_msg_type_number_t;
        thread_get_state(
            current_thread(),
            bindings::x86_FLOAT_STATE32 as c_int,
            &mut fstate as *mut _ as thread_state_t,
            &mut count,
        );

        if crate::xnu::memory::copyout(
            &tstate as *const _ as *const c_void,
            thread_state_address as bindings::user_addr_t,
            std::mem::size_of_val(&tstate) as bindings::vm_size_t,
        ) != 0
            || crate::xnu::memory::copyout(
                &fstate as *const _ as *const c_void,
                float_state_address as bindings::user_addr_t,
                std::mem::size_of_val(&fstate) as bindings::vm_size_t,
            ) != 0
        {
            return -LINUX_EFAULT;
        }
    } else {
        crate::xnu::misc::log(
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_error,
            &format!(
                "xnu_sys_thread_save_state_to_user() unimplemented for architecture: {:?}",
                (*task).architecture
            ),
        );
        return -LINUX_ENOSYS;
    }

    0
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_process_signal(
    thread: *mut xnu_sys_thread,
    bsd_signal_number: c_int,
    linux_signal_number: c_int,
    code: c_int,
    signal_address: usize,
) {
    const CODE_MAX: usize =
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_EXCEPTION_CODE_MAX as usize;
    let mut codes: [i64; CODE_MAX] = [0; CODE_MAX];
    let task = task_for_thread(thread);

    (*thread).processing_signal = true;

    'out: {
        if code == LINUX_SI_USER {
            if (*task).has_sigexc {
                codes[0] = bindings::EXC_SOFT_SIGNAL as i64;
                codes[1] = bsd_signal_number as i64;
                bindings::bsd_exception(bindings::EXC_SOFTWARE as c_int, codes.as_mut_ptr(), 2);
            } else {
                (*xnu_sys_hooks).thread_set_pending_signal.expect("hook")(
                    (*thread).context,
                    bsd_signal_number,
                );
            }
            break 'out;
        }

        let mach_exception: c_int;
        if linux_signal_number == LINUX_SIGSEGV {
            // KERN_INVALID_ADDRESS
            mach_exception = bindings::EXC_BAD_ACCESS as c_int;
            codes[0] = bindings::KERN_INVALID_ADDRESS as i64;
            codes[1] = signal_address as i64;
        } else if linux_signal_number == LINUX_SIGBUS {
            mach_exception = bindings::EXC_BAD_ACCESS as c_int;
            codes[0] = bindings::EXC_I386_ALIGNFLT as i64;
        } else if linux_signal_number == LINUX_SIGILL {
            mach_exception = bindings::EXC_BAD_INSTRUCTION as c_int;
            codes[0] = bindings::EXC_I386_INVOP as i64;
        } else if linux_signal_number == LINUX_SIGFPE {
            mach_exception = bindings::EXC_ARITHMETIC as c_int;
            codes[0] = code as i64;
        } else if linux_signal_number == LINUX_SIGTRAP {
            mach_exception = bindings::EXC_BREAKPOINT as c_int;
            codes[0] = if code == LINUX_SI_KERNEL {
                bindings::EXC_I386_BPT as i64
            } else {
                bindings::EXC_I386_SGL as i64
            };

            if code == LINUX_TRAP_HWBKPT {
                crate::xnu_sys_stub!("LINUX_TRAP_HWBKPT");
                codes[1] = 0;
            }
        } else {
            if (*task).has_sigexc {
                if codes[0] == 0 {
                    codes[0] = bindings::EXC_SOFT_SIGNAL as i64;
                }
                codes[1] = bsd_signal_number as i64;
                bindings::bsd_exception(bindings::EXC_SOFTWARE as c_int, codes.as_mut_ptr(), 2);
            } else {
                (*xnu_sys_hooks).thread_set_pending_signal.expect("hook")(
                    (*thread).context,
                    bsd_signal_number,
                );
            }
            break 'out;
        }

        crate::xnu::misc::log(
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
            &format!(
                "calling exception_triage_thread({}, [{}, {}])",
                mach_exception, codes[0], codes[1]
            ),
        );

        bindings::exception_triage_thread(
            mach_exception,
            codes.as_mut_ptr(),
            CODE_MAX as mach_msg_type_number_t,
            &mut (*thread).xnu_thread,
        );

        crate::xnu::misc::log(
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
            "exception_triage_thread returned",
        );
    }

    // out:
    (*thread).processing_signal = false;
}

#[no_mangle]
pub unsafe extern "C" fn handle_ux_exception(
    xthread: thread_t,
    exception: c_int,
    code: i64,
    subcode: i64,
) -> kern_return_t {
    let thread = thread_for_xnu_thread(xthread);

    // translate exception and code to signal type
    let ux_signal = ux_exception(exception, code, subcode);

    if (*thread).processing_signal {
        (*xnu_sys_hooks).thread_set_pending_signal.expect("hook")((*thread).context, ux_signal);
    } else {
        crate::xnu_sys_stub_unsafe!("handle_ux_exception(): TODO: introduce signal into thread");
    }

    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_wait_while_user_suspended(thread: *mut xnu_sys_thread) {
    if !std::ptr::eq(&(*thread).xnu_thread as *const _, current_thread() as *const _) {
        panic!("Cannot wait with non-current thread");
    }

    // TODO: we need to somehow detect when the thread has a signal pending. See the C for the
    // four approaches considered; none is implemented yet.

    while (*thread).xnu_thread.suspend_count > 0 {
        crate::xnu::misc::log(
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
            "sigexc: going to sleep",
        );

        crate::xnu::locks::xnu_sys_mutex_lock(&mut (*thread).suspension_mutex);
        (*thread).waiting_suspended = true;
        crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*thread).suspension_mutex);
        crate::xnu::condvar::xnu_sys_condvar_signal(&mut (*thread).suspension_condvar, usize::MAX);

        // FIXME: possible race condition here between notifying of waiting and actually sleeping

        (*thread).xnu_thread.wait_result =
            bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_WAITING as wait_result_t;

        (*xnu_sys_hooks).thread_suspend.expect("thread_suspend hook")(
            (*thread).context,
            None,
            ptr::null_mut(),
            ptr::null_mut(),
        );

        crate::xnu::misc::log(
            bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
            "sigexc: woken up",
        );

        crate::xnu::locks::xnu_sys_mutex_lock(&mut (*thread).suspension_mutex);
        (*thread).waiting_suspended = false;
        crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*thread).suspension_mutex);
        crate::xnu::condvar::xnu_sys_condvar_signal(&mut (*thread).suspension_condvar, usize::MAX);

        if (*thread).xnu_thread.wait_result
            == bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED as wait_result_t
        {
            break;
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_retain(thread: *mut xnu_sys_thread) {
    bindings::xnu_sys_rs_thread_reference(&mut (*thread).xnu_thread);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_release(thread: *mut xnu_sys_thread) {
    thread_deallocate(&mut (*thread).xnu_thread);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_sigexc_enter(thread: *mut xnu_sys_thread) {
    thread_lock(&mut (*thread).xnu_thread);
    (*thread).xnu_thread.state &= !((bindings::TH_UNINT | bindings::TH_WAIT) as c_int);
    (*thread).xnu_thread.wait_result =
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED as wait_result_t;
    bindings::clear_wait_internal(
        &mut (*thread).xnu_thread,
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED as wait_result_t,
    );
    thread_unlock(&mut (*thread).xnu_thread);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_sigexc_enter2(thread: *mut xnu_sys_thread) {
    let new_user_state =
        malloc(std::mem::size_of::<xnu_sys_thread_user_state>()) as *mut xnu_sys_thread_user_state;
    if new_user_state.is_null() {
        panic!("ran out of memory");
    }

    ptr::write_bytes(
        new_user_state as *mut u8,
        0,
        std::mem::size_of::<xnu_sys_thread_user_state>(),
    );

    thread_lock(&mut (*thread).xnu_thread);
    user_states_insert_head(thread, new_user_state);
    thread_unlock(&mut (*thread).xnu_thread);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_sigexc_exit(thread: *mut xnu_sys_thread) {
    thread_lock(&mut (*thread).xnu_thread);
    let user_state = user_states_first(thread);
    user_states_remove(user_state);
    thread_unlock(&mut (*thread).xnu_thread);

    free(user_state as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_thread_dying(thread: *mut xnu_sys_thread) {
    thread_lock(&mut (*thread).xnu_thread);
    (*thread).xnu_thread.state &= !((bindings::TH_UNINT | bindings::TH_WAIT) as c_int);
    (*thread).xnu_thread.state |= bindings::TH_TERMINATE as c_int;
    (*thread).xnu_thread.wait_result =
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED as wait_result_t;
    bindings::clear_wait_internal(
        &mut (*thread).xnu_thread,
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED as wait_result_t,
    );
    thread_unlock(&mut (*thread).xnu_thread);
}

#[no_mangle]
pub unsafe extern "C" fn current_thread() -> thread_t {
    let thread = (*xnu_sys_hooks).current_thread.expect("current_thread hook")();
    if thread.is_null() {
        ptr::null_mut()
    } else {
        &mut (*thread).xnu_thread
    }
}

#[no_mangle]
pub unsafe extern "C" fn thread_reference(thread: thread_t) {
    bindings::xnu_sys_rs_os_ref_retain(&mut (*thread).ref_count as *mut _ as *mut _);
}

#[no_mangle]
pub unsafe extern "C" fn thread_deallocate(xthread: thread_t) {
    let thread = thread_for_xnu_thread(xthread);
    if bindings::xnu_sys_rs_os_ref_release(&mut (*xthread).ref_count as *mut _ as *mut _) > 0 {
        return;
    }
    xnu_sys_thread_destroy(thread);
}

#[no_mangle]
pub unsafe extern "C" fn thread_deallocate_safe(thread: thread_t) {
    thread_deallocate(thread)
}

unsafe extern "C" fn thread_continuation_callback(context: *mut c_void) {
    let thread = context as *mut xnu_sys_thread;

    thread_lock(&mut (*thread).xnu_thread);
    let continuation = (*thread).xnu_thread.continuation;
    (*thread).xnu_thread.continuation = None;

    let parameter = (*thread).xnu_thread.parameter;
    (*thread).xnu_thread.parameter = ptr::null_mut();

    let wait_result = (*thread).xnu_thread.wait_result;
    thread_unlock(&mut (*thread).xnu_thread);

    continuation.expect("continuation set before callback")(parameter, wait_result);

    thread_terminate_self();
}

#[no_mangle]
pub unsafe extern "C" fn thread_block_parameter(
    continuation: bindings::thread_continue_t,
    parameter: *mut c_void,
) -> wait_result_t {
    let thread = (*xnu_sys_hooks).current_thread.expect("current_thread hook")();

    thread_lock(&mut (*thread).xnu_thread);

    (*thread).xnu_thread.continuation = continuation;
    (*thread).xnu_thread.parameter = parameter;

    let waiting = (*thread).xnu_thread.state & bindings::TH_WAIT as c_int != 0;

    thread_unlock(&mut (*thread).xnu_thread);

    if waiting {
        (*xnu_sys_hooks).thread_suspend.expect("thread_suspend hook")(
            (*thread).context,
            if continuation.is_some() {
                Some(thread_continuation_callback)
            } else {
                None
            },
            thread as *mut c_void,
            ptr::null_mut(),
        );
    }

    thread_lock(&mut (*thread).xnu_thread);
    let wait_result = (*thread).xnu_thread.wait_result;
    thread_unlock(&mut (*thread).xnu_thread);

    if let Some(cont) = continuation {
        // TODO: we should add a thread hook to jump to a continuation without suspending
        cont(parameter, wait_result);
        std::hint::unreachable_unchecked();
    }

    wait_result
}

#[no_mangle]
pub unsafe extern "C" fn thread_block(continuation: bindings::thread_continue_t) -> wait_result_t {
    thread_block_parameter(continuation, ptr::null_mut())
}

/// thread locked
#[no_mangle]
pub unsafe extern "C" fn thread_unblock(xthread: thread_t, wresult: wait_result_t) -> boolean_t {
    let thread = thread_for_xnu_thread(xthread);
    (*thread).xnu_thread.wait_result = wresult;
    (*xnu_sys_hooks).thread_resume.expect("thread_resume hook")((*thread).context);
    1
}

/// thread locked
#[no_mangle]
pub unsafe extern "C" fn thread_go(
    thread: thread_t,
    wresult: wait_result_t,
    _option: bindings::waitq_options_t,
) -> kern_return_t {
    if thread_unblock(thread, wresult) != 0 {
        bindings::KERN_SUCCESS as kern_return_t
    } else {
        bindings::KERN_FAILURE as kern_return_t
    }
}

#[no_mangle]
pub unsafe extern "C" fn thread_mark_wait_locked(
    thread: thread_t,
    _interruptible_orig: bindings::wait_interrupt_t,
) -> wait_result_t {
    crate::xnu_sys_stub_safe!();
    (*thread).state = bindings::TH_WAIT as c_int;
    (*thread).wait_result =
        bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_WAITING as wait_result_t;
    (*thread).block_hint = (*thread).pending_block_hint;
    (*thread).pending_block_hint = bindings::block_hint_t::kThreadWaitNone;
    bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_WAITING as wait_result_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_terminate(xthread: thread_t) -> kern_return_t {
    let thread = thread_for_xnu_thread(xthread);
    (*xnu_sys_hooks).thread_terminate.expect("thread_terminate hook")((*thread).context);
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_terminate_self() {
    thread_terminate(current_thread());
}

#[no_mangle]
pub unsafe extern "C" fn thread_sched_call(thread: thread_t, call: bindings::sched_call_t) {
    (*thread).sched_call = call;
}

#[no_mangle]
pub unsafe extern "C" fn kernel_thread_create(
    continuation: bindings::thread_continue_t,
    parameter: *mut c_void,
    _priority: integer_t,
    new_thread: *mut thread_t,
) -> kern_return_t {
    let thread = (*xnu_sys_hooks).thread_create_kernel.expect("hook")();
    if thread.is_null() {
        return bindings::KERN_FAILURE as kern_return_t;
    }

    thread_reference(&mut (*thread).xnu_thread);
    *new_thread = &mut (*thread).xnu_thread;

    (*thread).xnu_thread.continuation = continuation;
    (*thread).xnu_thread.parameter = parameter;
    (*thread).xnu_thread.state = (bindings::TH_WAIT | bindings::TH_UNINT) as c_int;

    (*xnu_sys_hooks).thread_setup.expect("thread_setup hook")(
        (*thread).context,
        Some(thread_continuation_callback),
        thread as *mut c_void,
    );

    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_set_thread_name(xthread: thread_t, name: *const c_char) {
    let thread = thread_for_xnu_thread(xthread);
    (*thread).name = name;
}

#[no_mangle]
pub unsafe extern "C" fn thread_syscall_return(ret: kern_return_t) -> ! {
    (*xnu_sys_hooks).current_thread_syscall_return.expect("hook")(ret);
    std::hint::unreachable_unchecked()
}

#[no_mangle]
pub unsafe extern "C" fn thread_set_pending_block_hint(
    thread: thread_t,
    block_hint: bindings::block_hint_t,
) {
    (*thread).pending_block_hint = block_hint;
}

#[no_mangle]
pub unsafe extern "C" fn thread_handoff_internal(
    thread: thread_t,
    continuation: bindings::thread_continue_t,
    parameter: *mut c_void,
    option: bindings::thread_handoff_option_t,
) -> wait_result_t {
    if !thread.is_null() {
        if continuation.is_none()
            || (option & bindings::thread_handoff_option_t_THREAD_HANDOFF_SETRUN_NEEDED)
                != 0
        {
            thread_deallocate_safe(thread);
        }

        // in the real thread_handoff_internal(), an attempt is made to grab the thread to
        // handoff to. if it could not be pulled from its runq, the current thread simply blocks
        // with thread_block_parameter(). therefore, it is not necessary to actually handoff to
        // the given thread, so we do not do that, in order to make our implementation easier.
    }

    thread_block_parameter(continuation, parameter)
}

#[no_mangle]
pub unsafe extern "C" fn thread_hold(xthread: thread_t) {
    let thread = thread_for_xnu_thread(xthread);
    crate::xnu::misc::log(
        bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
        &format!("sigexc: thread_hold({:p})\n", xthread),
    );
    // CHECKME: the LKM was always sending the signal whenever thread_hold got called;
    //          we mimic XNU here instead. check whether this actually works as expected.
    let previous = (*xthread).suspend_count;
    (*xthread).suspend_count += 1;
    if previous == 0 {
        // This signal leads to sigexc.c which will end up calling ciderd;
        // ciderd will hold the caller so long as the suspend_count > 0.
        (*xnu_sys_hooks).thread_send_signal.expect("hook")(
            (*thread).context,
            bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_LINUX_SIGRTMIN as c_int,
        );
    }
}

#[no_mangle]
pub unsafe extern "C" fn thread_release(xthread: thread_t) {
    let thread = thread_for_xnu_thread(xthread);
    crate::xnu::misc::log(
        bindings::xnu_sys_log_level_t::xnu_sys_log_level_debug,
        &format!("sigexc: thread_release({:p})\n", xthread),
    );
    (*xthread).suspend_count -= 1;
    (*xnu_sys_hooks).thread_resume.expect("thread_resume hook")((*thread).context);
}

#[no_mangle]
pub unsafe extern "C" fn thread_wait(xthread: thread_t, _until_not_runnable: boolean_t) {
    let thread = thread_for_xnu_thread(xthread);
    crate::xnu::locks::xnu_sys_mutex_lock(&mut (*thread).suspension_mutex);
    while !(*thread).waiting_suspended {
        crate::xnu::condvar::xnu_sys_condvar_wait(
            &mut (*thread).suspension_condvar,
            &mut (*thread).suspension_mutex,
        );
    }
    crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*thread).suspension_mutex);
}

#[no_mangle]
pub unsafe extern "C" fn thread_info(
    xthread: thread_t,
    flavor: bindings::thread_flavor_t,
    thread_info_out: bindings::thread_info_t,
    thread_info_count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    use bindings::xnu_sys_thread_state as St;
    let thread = thread_for_xnu_thread(xthread);
    let flavor = flavor as u32;

    if flavor == bindings::THREAD_IDENTIFIER_INFO {
        let count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_IDENTIFIER_INFO_COUNT
            as mach_msg_type_number_t;
        if *thread_info_count < count {
            return bindings::KERN_INVALID_ARGUMENT as kern_return_t;
        }
        *thread_info_count = count;

        let info = thread_info_out as *mut bindings::thread_identifier_info;

        thread_lock(xthread);
        (*info).thread_id = (*xthread).thread_id;
        (*info).thread_handle = (*thread).pthread_handle as u64;
        (*info).dispatch_qaddr = (*thread).dispatch_qaddr as u64;
        thread_unlock(xthread);

        return bindings::KERN_SUCCESS as kern_return_t;
    }

    if flavor == bindings::THREAD_BASIC_INFO {
        let count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_BASIC_INFO_COUNT
            as mach_msg_type_number_t;
        if *thread_info_count < count {
            return bindings::KERN_INVALID_ARGUMENT as kern_return_t;
        }
        *thread_info_count = count;

        let info = thread_info_out as *mut bindings::thread_basic_info;
        let mut thread_state: c_int = -1;

        thread_lock(xthread);

        // TODO: fill in these values properly
        (*info).cpu_usage = 0;
        (*info).flags = 0;
        (*info).policy = 0;
        (*info).sleep_time = 0;
        (*info).system_time.seconds = 0;
        (*info).system_time.microseconds = 0;
        (*info).user_time.seconds = 0;
        (*info).user_time.microseconds = 0;

        (*info).suspend_count = (*xthread).user_stop_count as integer_t;

        thread_unlock(xthread);

        // check if the thread is currently waiting suspended; in that case, the
        // `thread_get_state` hook will report that it is waiting interruptibly (because that is
        // what Linux sees), but we know that it is actually "stopped" waiting for us to resume it.
        crate::xnu::locks::xnu_sys_mutex_lock(&mut (*thread).suspension_mutex);
        if (*thread).waiting_suspended {
            thread_state = St::xnu_sys_thread_state_stopped as c_int;
        }
        crate::xnu::locks::xnu_sys_mutex_unlock(&mut (*thread).suspension_mutex);

        if thread_state == -1 {
            thread_state =
                (*xnu_sys_hooks).thread_get_state.expect("hook")((*thread).context) as c_int;
        }

        (*info).run_state = if thread_state == St::xnu_sys_thread_state_dead as c_int {
            0
        } else if thread_state == St::xnu_sys_thread_state_running as c_int {
            bindings::TH_STATE_RUNNING as integer_t
        } else if thread_state == St::xnu_sys_thread_state_stopped as c_int {
            bindings::TH_STATE_STOPPED as integer_t
        } else if thread_state == St::xnu_sys_thread_state_interruptible as c_int {
            bindings::TH_STATE_WAITING as integer_t
        } else if thread_state == St::xnu_sys_thread_state_uninterruptible as c_int {
            bindings::TH_STATE_UNINTERRUPTIBLE as integer_t
        } else {
            panic!("invalid thread state: {thread_state}; this should be impossible")
        };

        return bindings::KERN_SUCCESS as kern_return_t;
    }

    crate::xnu_sys_stub_unsafe!("Unimplemented flavor")
}

//
// The saved x86 register state. thread_set_state and thread_get_state_internal both dispatch
// twice: first on the COMPOSITE flavor, which carries a header naming the real one and a union
// of the 32 and 64 bit forms, then on that real flavor. The C does it with two switches and a
// reassigned `state` pointer; this keeps that shape.
//

#[no_mangle]
pub unsafe extern "C" fn thread_set_state(
    thread: thread_t,
    flavor: c_int,
    state: thread_state_t,
    state_count: mach_msg_type_number_t,
) -> kern_return_t {
    use bindings::dserver_rpc_architecture_t as Arch;
    let invalid = bindings::KERN_INVALID_ARGUMENT as kern_return_t;
    let success = bindings::KERN_SUCCESS as kern_return_t;

    let dthread = thread_for_xnu_thread(thread);
    let dtask = task_for_thread(dthread);
    let user_state = user_states_first(dthread);

    let is64 = (*dtask).architecture == Arch::dserver_rpc_architecture_x86_64;
    if !is64 && (*dtask).architecture != Arch::dserver_rpc_architecture_i386 {
        return bindings::KERN_FAILURE as kern_return_t;
    }

    let mut flavor = flavor as u32;
    let mut state = state;
    let mut state_count = state_count;

    // First switch: resolve a composite flavor to its real one.
    if flavor == bindings::x86_THREAD_STATE {
        let s = state as *mut bindings::x86_thread_state;
        if state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE_COUNT
                as mach_msg_type_number_t
        {
            return invalid;
        }
        if (*s).tsh.flavor as u32 == bindings::x86_THREAD_STATE32 {
            if is64 {
                return invalid;
            }
            state_count = (*s).tsh.count as mach_msg_type_number_t;
            state = &mut (*s).uts.ts32 as *mut _ as thread_state_t;
        } else if (*s).tsh.flavor as u32 == bindings::x86_THREAD_STATE64 {
            if !is64 {
                return invalid;
            }
            state_count = (*s).tsh.count as mach_msg_type_number_t;
            state = &mut (*s).uts.ts64 as *mut _ as thread_state_t;
        } else {
            return invalid;
        }
        flavor = (*s).tsh.flavor as u32;
    } else if flavor == bindings::x86_FLOAT_STATE {
        let s = state as *mut bindings::x86_float_state;
        if state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE_COUNT
                as mach_msg_type_number_t
        {
            return invalid;
        }
        if (*s).fsh.flavor as u32 == bindings::x86_FLOAT_STATE32 {
            if is64 {
                return invalid;
            }
            state_count = (*s).fsh.count as mach_msg_type_number_t;
            state = &mut (*s).ufs.fs32 as *mut _ as thread_state_t;
        } else if (*s).fsh.flavor as u32 == bindings::x86_FLOAT_STATE64 {
            if !is64 {
                return invalid;
            }
            state_count = (*s).fsh.count as mach_msg_type_number_t;
            state = &mut (*s).ufs.fs64 as *mut _ as thread_state_t;
        } else {
            return invalid;
        }
        flavor = (*s).fsh.flavor as u32;
    } else if flavor == bindings::x86_DEBUG_STATE {
        let s = state as *mut bindings::x86_debug_state;
        if state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE_COUNT
                as mach_msg_type_number_t
        {
            return invalid;
        }
        if (*s).dsh.flavor as u32 == bindings::x86_DEBUG_STATE32 {
            if is64 {
                return invalid;
            }
            state_count = (*s).dsh.count as mach_msg_type_number_t;
            state = &mut (*s).uds.ds32 as *mut _ as thread_state_t;
        } else if (*s).dsh.flavor as u32 == bindings::x86_DEBUG_STATE64 {
            if !is64 {
                return invalid;
            }
            state_count = (*s).dsh.count as mach_msg_type_number_t;
            state = &mut (*s).uds.ds64 as *mut _ as thread_state_t;
        } else {
            return invalid;
        }
        flavor = (*s).dsh.flavor as u32;
    }

    // Second switch: copy the leaf state into the thread's saved state.
    if flavor == bindings::x86_THREAD_STATE32 {
        if state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE32_COUNT
                as mach_msg_type_number_t
            || is64
        {
            return invalid;
        }
        (*user_state).thread_state.uts.ts32 = *(state as *const bindings::x86_thread_state32_t);
        success
    } else if flavor == bindings::x86_THREAD_STATE64 {
        if state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE64_COUNT
                as mach_msg_type_number_t
            || !is64
        {
            return invalid;
        }
        (*user_state).thread_state.uts.ts64 = *(state as *const bindings::x86_thread_state64_t);
        success
    } else if flavor == bindings::x86_FLOAT_STATE32 {
        if state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE32_COUNT
                as mach_msg_type_number_t
            || is64
        {
            return invalid;
        }
        (*user_state).float_state.ufs.fs32 = *(state as *const bindings::x86_float_state32_t);
        success
    } else if flavor == bindings::x86_FLOAT_STATE64 {
        if state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE64_COUNT
                as mach_msg_type_number_t
            || !is64
        {
            return invalid;
        }
        (*user_state).float_state.ufs.fs64 = *(state as *const bindings::x86_float_state64_t);
        success
    } else if flavor == bindings::x86_DEBUG_STATE32 {
        if is64 {
            return invalid;
        }
        // Carried over including the bug: the C widens the 32-bit debug state into a local s64
        // and then passes `&s`, the address of the SOURCE pointer, not `&s64`. Reproduced rather
        // than fixed, because both paths end at the KERN_NOT_SUPPORTED stub below and changing
        // it would be a behaviour change made blind.
        let s = state as *const bindings::x86_debug_state32_t;
        let mut s64: bindings::x86_debug_state64_t = std::mem::zeroed();
        s64.dr0 = (*s).dr0 as u64;
        s64.dr1 = (*s).dr1 as u64;
        s64.dr2 = (*s).dr2 as u64;
        s64.dr3 = (*s).dr3 as u64;
        s64.dr4 = (*s).dr4 as u64;
        s64.dr5 = (*s).dr5 as u64;
        s64.dr6 = (*s).dr6 as u64;
        s64.dr7 = (*s).dr7 as u64;
        thread_set_state(
            thread,
            bindings::x86_DEBUG_STATE64 as c_int,
            &s as *const _ as thread_state_t,
            bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE64_COUNT
                as mach_msg_type_number_t,
        )
    } else if flavor == bindings::x86_DEBUG_STATE64 {
        // TODO: the hardware breakpoint path is #if 0 in the C
        crate::xnu_sys_stub!("debug state");
        bindings::KERN_NOT_SUPPORTED as kern_return_t
    } else {
        invalid
    }
}

#[no_mangle]
pub unsafe extern "C" fn thread_get_state_internal(
    thread: thread_t,
    flavor: c_int,
    state: thread_state_t,
    state_count: *mut mach_msg_type_number_t,
    _to_user: boolean_t,
) -> kern_return_t {
    use bindings::dserver_rpc_architecture_t as Arch;
    let invalid = bindings::KERN_INVALID_ARGUMENT as kern_return_t;
    let success = bindings::KERN_SUCCESS as kern_return_t;

    let dthread = thread_for_xnu_thread(thread);
    let dtask = task_for_thread(dthread);
    let user_state = user_states_first(dthread);

    // to_user indicates whether to convert from kernel to user thread state representations. It
    // only does anything on ARM64 with authenticated pointers, so it is ignored here as in the C.

    let is64 = (*dtask).architecture == Arch::dserver_rpc_architecture_x86_64;
    if !is64 && (*dtask).architecture != Arch::dserver_rpc_architecture_i386 {
        return bindings::KERN_FAILURE as kern_return_t;
    }

    let mut flavor = flavor as u32;
    let mut state = state;
    let mut state_count = state_count;

    // The composite flavors select 32 or 64 bit by process type, then RE-POINT state_count at
    // the header count field, which is why state_count is a pointer here as in the C.
    if flavor == bindings::x86_THREAD_STATE {
        let s = state as *mut bindings::x86_thread_state;
        if *state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE_COUNT
                as mach_msg_type_number_t
        {
            return invalid;
        }
        if is64 {
            flavor = bindings::x86_THREAD_STATE64;
            (*s).tsh.flavor = flavor as u32;
            (*s).tsh.count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE64_COUNT
                as u32;
            state = &mut (*s).uts.ts64 as *mut _ as thread_state_t;
        } else {
            flavor = bindings::x86_THREAD_STATE32;
            (*s).tsh.flavor = flavor as u32;
            (*s).tsh.count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE32_COUNT
                as u32;
            state = &mut (*s).uts.ts32 as *mut _ as thread_state_t;
        }
        *state_count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE_COUNT
            as mach_msg_type_number_t;
        state_count = &mut (*s).tsh.count as *mut mach_msg_type_number_t;
    } else if flavor == bindings::x86_FLOAT_STATE {
        let s = state as *mut bindings::x86_float_state;
        if *state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE_COUNT
                as mach_msg_type_number_t
        {
            return invalid;
        }
        if is64 {
            flavor = bindings::x86_FLOAT_STATE64;
            (*s).fsh.flavor = flavor as u32;
            (*s).fsh.count =
                bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE64_COUNT as u32;
            state = &mut (*s).ufs.fs64 as *mut _ as thread_state_t;
        } else {
            flavor = bindings::x86_FLOAT_STATE32;
            (*s).fsh.flavor = flavor as u32;
            (*s).fsh.count =
                bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE32_COUNT as u32;
            state = &mut (*s).ufs.fs32 as *mut _ as thread_state_t;
        }
        *state_count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE_COUNT
            as mach_msg_type_number_t;
        state_count = &mut (*s).fsh.count as *mut mach_msg_type_number_t;
    } else if flavor == bindings::x86_DEBUG_STATE {
        let s = state as *mut bindings::x86_debug_state;
        if *state_count
            < bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE_COUNT
                as mach_msg_type_number_t
        {
            return invalid;
        }
        if is64 {
            flavor = bindings::x86_DEBUG_STATE64;
            (*s).dsh.flavor = flavor as u32;
            (*s).dsh.count =
                bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE64_COUNT as u32;
            state = &mut (*s).uds.ds64 as *mut _ as thread_state_t;
        } else {
            flavor = bindings::x86_DEBUG_STATE32;
            (*s).dsh.flavor = flavor as u32;
            (*s).dsh.count =
                bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE32_COUNT as u32;
            state = &mut (*s).uds.ds32 as *mut _ as thread_state_t;
        }
        *state_count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE_COUNT
            as mach_msg_type_number_t;
        state_count = &mut (*s).dsh.count as *mut mach_msg_type_number_t;
    }

    if flavor == bindings::x86_THREAD_STATE32 {
        let need = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE32_COUNT
            as mach_msg_type_number_t;
        if *state_count < need || is64 {
            return invalid;
        }
        *state_count = need;
        *(state as *mut bindings::x86_thread_state32_t) = (*user_state).thread_state.uts.ts32;
        success
    } else if flavor == bindings::x86_FLOAT_STATE32 {
        let need = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE32_COUNT
            as mach_msg_type_number_t;
        if *state_count < need || is64 {
            return invalid;
        }
        *state_count = need;
        *(state as *mut bindings::x86_float_state32_t) = (*user_state).float_state.ufs.fs32;
        success
    } else if flavor == bindings::x86_FLOAT_STATE64 {
        // these two are practically identical, and the C deliberately does NOT check the
        // architecture here where it does everywhere else
        let need = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_FLOAT_STATE64_COUNT
            as mach_msg_type_number_t;
        if *state_count < need {
            return invalid;
        }
        *state_count = need;
        *(state as *mut bindings::x86_float_state64_t) = (*user_state).float_state.ufs.fs64;
        success
    } else if flavor == bindings::x86_THREAD_STATE64 {
        let need = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_THREAD_STATE64_COUNT
            as mach_msg_type_number_t;
        if *state_count < need || !is64 {
            return invalid;
        }
        *state_count = need;
        *(state as *mut bindings::x86_thread_state64_t) = (*user_state).thread_state.uts.ts64;
        success
    } else if flavor == bindings::x86_DEBUG_STATE32 {
        let need = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE32_COUNT
            as mach_msg_type_number_t;
        if *state_count < need || is64 {
            return invalid;
        }
        *state_count = need;

        // Call self and translate from 64-bit
        let s = state as *mut bindings::x86_debug_state32_t;
        let mut s64: bindings::x86_debug_state64_t = std::mem::zeroed();
        let mut count = bindings::xnu_sys_rs_host_consts_XNU_SYS_RS_x86_DEBUG_STATE64_COUNT
            as mach_msg_type_number_t;

        let kr = thread_get_state_internal(
            thread,
            bindings::x86_DEBUG_STATE64 as c_int,
            &mut s64 as *mut _ as thread_state_t,
            &mut count,
            0,
        );
        if kr != success {
            return kr;
        }

        (*s).dr0 = s64.dr0 as u32;
        (*s).dr1 = s64.dr1 as u32;
        (*s).dr2 = s64.dr2 as u32;
        (*s).dr3 = s64.dr3 as u32;
        (*s).dr4 = s64.dr4 as u32;
        (*s).dr5 = s64.dr5 as u32;
        (*s).dr6 = s64.dr6 as u32;
        (*s).dr7 = s64.dr7 as u32;

        success
    } else if flavor == bindings::x86_DEBUG_STATE64 {
        // TODO: the hardware breakpoint readback is #if 0 in the C
        bindings::KERN_NOT_SUPPORTED as kern_return_t
    } else {
        invalid
    }
}

#[no_mangle]
pub unsafe extern "C" fn thread_get_state(
    thread: thread_t,
    flavor: c_int,
    state: thread_state_t,
    state_count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    thread_get_state_internal(thread, flavor, state, state_count, 0)
}

#[no_mangle]
pub unsafe extern "C" fn thread_set_state_from_user(
    thread: thread_t,
    flavor: c_int,
    state: thread_state_t,
    state_count: mach_msg_type_number_t,
) -> kern_return_t {
    thread_set_state(thread, flavor, state, state_count)
}

//
// The stubs.
//

#[no_mangle]
pub unsafe extern "C" fn thread_get_requested_qos(
    _thread: thread_t,
    relpri: *mut c_int,
) -> bindings::thread_qos_t {
    crate::xnu_sys_stub_safe!();
    *relpri = 0;
    bindings::THREAD_QOS_DEFAULT as bindings::thread_qos_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_user_promotion_qos_for_pri(
    _priority: c_int,
) -> bindings::thread_qos_t {
    crate::xnu_sys_stub_safe!();
    bindings::THREAD_QOS_DEFAULT as bindings::thread_qos_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_guard_violation(
    _thread: thread_t,
    _code: i64,
    _subcode: i64,
    _fatal: boolean_t,
) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn thread_port_with_flavor_notify(_msg: *mut mach_msg_header_t) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn thread_recompute_kernel_promotion_locked(_thread: thread_t) -> boolean_t {
    crate::xnu_sys_stub_safe!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn thread_recompute_user_promotion_locked(_thread: thread_t) -> boolean_t {
    crate::xnu_sys_stub_safe!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn thread_set_eager_preempt(_thread: thread_t) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn sched_thread_promote_reason(
    _thread: thread_t,
    _reason: u32,
    _trace_obj: usize,
) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn sched_thread_unpromote_reason(
    _thread: thread_t,
    _reason: u32,
    _trace_obj: usize,
) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn thread_poll_yield(_self_: thread_t) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn act_get_state_to_user(
    _thread: thread_t,
    _flavor: c_int,
    _state: thread_state_t,
    _count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn act_set_state_from_user(
    _thread: thread_t,
    _flavor: c_int,
    _state: thread_state_t,
    _count: mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_abort(_thread: thread_t) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_abort_safely(_thread: thread_t) -> kern_return_t {
    // TODO: actually do something? in the LKM, we used to call kick_process here (which would
    // presumably interrupt any syscalls). to replicate that, we would probably have to use
    // another real-time signal with SA_RESTART off.
    crate::xnu_sys_stub!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_convert_thread_state(
    _thread: thread_t,
    _direction: c_int,
    _flavor: bindings::thread_state_flavor_t,
    _in_state: thread_state_t,
    _in_state_count: mach_msg_type_number_t,
    _out_state: thread_state_t,
    _out_state_count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_create_from_user(
    _task: task_t,
    _new_thread: *mut thread_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_create_running_from_user(
    _task: task_t,
    _flavor: c_int,
    _new_state: thread_state_t,
    _new_state_count: mach_msg_type_number_t,
    _new_thread: *mut thread_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_depress_abort_from_user(_thread: thread_t) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_policy(
    _thread: thread_t,
    _policy: bindings::policy_t,
    _base: bindings::policy_base_t,
    _count: mach_msg_type_number_t,
    _set_limit: boolean_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_policy_get(
    _thread: thread_t,
    _flavor: bindings::thread_policy_flavor_t,
    _policy_info: bindings::thread_policy_t,
    _count: *mut mach_msg_type_number_t,
    _get_default: *mut boolean_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_policy_set(
    _thread: thread_t,
    _flavor: bindings::thread_policy_flavor_t,
    _policy_info: bindings::thread_policy_t,
    _count: mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    bindings::KERN_SUCCESS as kern_return_t
}

#[no_mangle]
pub unsafe extern "C" fn thread_set_mach_voucher(
    _thread: thread_t,
    _voucher: bindings::ipc_voucher_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_set_policy(
    _thread: thread_t,
    _pset: bindings::processor_set_t,
    _policy: bindings::policy_t,
    _base: bindings::policy_base_t,
    _base_count: mach_msg_type_number_t,
    _limit: bindings::policy_limit_t,
    _limit_count: mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_wire(
    _host_priv: bindings::host_priv_t,
    _thread: thread_t,
    _wired: boolean_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_getstatus_to_user(
    _thread: thread_t,
    _flavor: c_int,
    _tstate: thread_state_t,
    _count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_setstatus_from_user(
    _thread: thread_t,
    _flavor: c_int,
    _tstate: thread_state_t,
    _count: mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn thread_should_abort(_thread: thread_t) -> boolean_t {
    crate::xnu_sys_stub!();
    0
}
