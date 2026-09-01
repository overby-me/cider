//! xnu-sys's timer queue: the Rust replacement for `xnu-sys/src/timer.c`
//! (#71, the third glue file ported).
//!
//! xnu-sys does not emulate XNU's per-CPU timer hardware. It keeps ONE queue, and asks the
//! daemon to arm a real timer through the `timer_arm` hook; when that fires, the daemon calls
//! [`xnu_sys_timer_fired`], which expires the queue and re-arms for whatever is next.
//!
//! WHY THIS FILE WAS NOT PORTED EARLIER, AND WHY THAT WAS WRONG. It was backed off twice on
//! the grounds that `mpqueue_init` needs `mpqueue_head`'s internals, and that reopening the
//! `queue_.*`, `_?lck_.*` and `priority_queue.*` opaque types would "drag most of osfmk" into
//! bindings the whole daemon reads. That was asserted, never measured. Measured: reopening
//! all three costs **+9 structs and +7 KB** (49 structs / 40,546 B to 58 / 47,749 B), and the
//! daemon, both demos and the binary all still build. The caution was unfounded.
//!
//! `mpqueue_init` is a macro nesting two more macros, so it is written out below. Its pieces:
//! `queue_init` makes the list head point at ITSELF (circular, empty), `lck_mtx_init_ext` is
//! a real linkable function in xnu-sys's own locks.c, and `priority_queue_init` is
//! `__builtin_bzero` for the non-comparator variant this queue uses.
//!
//! Three of the thirteen symbols here are DATA, not code: `master_cpu`, `serverperfmode` and
//! `pal_rtc_nanotime_info` are read by XNU C. `serverperfmode = 1` is load bearing -- it is
//! what convinces XNU's timer_call code not to use long-term timers.

use std::os::raw::{c_int, c_void};
use std::ptr;

use crate::bindings::{
    mpqueue_head_t, timer_coalescing_priority_params_ns_t, boolean_t,
    xnu_sys_hooks_t, mach_absolute_time, timer_queue_expire, NSEC_PER_SEC,
};

// The PAL nanotime path is the i386 rtclock's; on arm64 the daemon links rtclock_arm64.c,
// which reads CLOCK_MONOTONIC itself, so neither the type nor these two symbols are wanted
// (task A18).
#[cfg(target_arch = "x86_64")]
use crate::bindings::{pal_rtc_nanotime, lck_mtx_init_ext};
#[cfg(target_arch = "aarch64")]
use crate::bindings::lck_mtx_init;

extern "C" {
    static xnu_sys_hooks: *const xnu_sys_hooks_t;
}

/// The single timer queue. XNU asks for "the queue for CPU n" and always gets this one.
static mut TIMER_QUEUE: mpqueue_head_t = unsafe { std::mem::zeroed() };

/// Returned by [`timer_call_get_priority_params`]. All-zero, as in the C.
static mut COALESCING_PARAMS: timer_coalescing_priority_params_ns_t =
    unsafe { std::mem::zeroed() };

// ---- data symbols XNU reads directly ----

/// A stub: nothing populates it, but the i386 rtclock code takes its address. arm64 has no
/// such symbol (rtclock_arm64.c does not reference it).
#[cfg(target_arch = "x86_64")]
#[no_mangle]
#[used]
pub static mut pal_rtc_nanotime_info: pal_rtc_nanotime = unsafe { std::mem::zeroed() };

#[no_mangle]
#[used]
pub static mut master_cpu: c_int = 0;

/// Load bearing at 1: it is what convinces timer_call not to use long term timers.
#[no_mangle]
#[used]
pub static mut serverperfmode: c_int = 1;

/// `mpqueue_init(q, LCK_GRP_NULL, LCK_ATTR_NULL)`, written out because bindgen binds no
/// macros. The three pieces it expands to are named in the module comment.
unsafe fn mpqueue_init(q: *mut mpqueue_head_t) {
    // queue_init: an empty circular list is one whose head points at itself.
    let head = ptr::addr_of_mut!((*q).head);
    (*head).next = head;
    (*head).prev = head;

    // The lock half of the macro is per-arch (kern/mpqueue.h): x86 has a lock_data_ext field
    // and calls lck_mtx_init_ext, arm64 has neither and calls plain lck_mtx_init (task A18).
    #[cfg(target_arch = "x86_64")]
    lck_mtx_init_ext(
        ptr::addr_of_mut!((*q).lock_data),
        ptr::addr_of_mut!((*q).lock_data_ext) as *mut _,
        ptr::null_mut(),
        ptr::null_mut(),
    );
    #[cfg(target_arch = "aarch64")]
    lck_mtx_init(
        ptr::addr_of_mut!((*q).lock_data),
        ptr::null_mut(),
        ptr::null_mut(),
    );

    (*q).earliest_soft_deadline = u64::MAX;
    (*q).count = 0;

    // priority_queue_init, non-comparator variant: __builtin_bzero(que, sizeof(*que)).
    let pq = ptr::addr_of_mut!((*q).mpq_pqhead);
    ptr::write_bytes(pq as *mut u8, 0, std::mem::size_of_val(&*pq));
}

/// Initialise the queue. Called from `xnu_sys_init`.
#[no_mangle]
pub unsafe extern "C" fn xnu_sys_timer_init() {
    mpqueue_init(ptr::addr_of_mut!(TIMER_QUEUE));
}

/// Monotonic nanoseconds. The i386 rtclock reads the wall clock through this; arm64 uses
/// rtclock_arm64.c's own reader instead, so this symbol is x86-only (task A18).
#[cfg(target_arch = "x86_64")]
#[no_mangle]
pub unsafe extern "C" fn _rtc_nanotime_read(_rntp: *mut pal_rtc_nanotime) -> u64 {
    let mut ts: libc::timespec = std::mem::zeroed();
    libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts);
    (ts.tv_sec as u64) * (NSEC_PER_SEC as u64) + (ts.tv_nsec as u64)
}

/// The daemon's timer fired: expire whatever is due and re-arm for the next deadline.
#[no_mangle]
pub unsafe extern "C" fn xnu_sys_timer_fired() {
    let next_deadline = timer_queue_expire(ptr::addr_of_mut!(TIMER_QUEUE), mach_absolute_time());
    if let Some(arm) = (*xnu_sys_hooks).timer_arm {
        arm(next_deadline, true);
    }
}

/// XNU wants a callback run on another CPU. There is only one, so run it here.
#[no_mangle]
pub unsafe extern "C" fn timer_call_nosync_cpu(
    _cpu: c_int,
    func: Option<unsafe extern "C" fn(*mut c_void)>,
    arg: *mut c_void,
) {
    if let Some(f) = func {
        f(arg);
    }
}

/// Give XNU a queue for `deadline`, arming the daemon's timer on the way.
#[no_mangle]
pub unsafe extern "C" fn timer_queue_assign(deadline: u64) -> *mut mpqueue_head_t {
    if let Some(arm) = (*xnu_sys_hooks).timer_arm {
        arm(deadline, false);
    }
    ptr::addr_of_mut!(TIMER_QUEUE)
}

/// A timer was cancelled; re-arm for the new deadline.
#[no_mangle]
pub unsafe extern "C" fn timer_queue_cancel(
    _queue: *mut mpqueue_head_t,
    _deadline: u64,
    new_deadline: u64,
) {
    if let Some(arm) = (*xnu_sys_hooks).timer_arm {
        arm(new_deadline, true);
    }
}

/// The queue for a given CPU. One queue, so always the same one.
#[no_mangle]
pub unsafe extern "C" fn timer_queue_cpu(_cpu: c_int) -> *mut mpqueue_head_t {
    ptr::addr_of_mut!(TIMER_QUEUE)
}

// Our implementation does not care about XNU's running timers: those exist only for context
// switching and kperf.

#[no_mangle]
pub unsafe extern "C" fn timer_resort_threshold(_skew: u64) -> boolean_t {
    crate::xnu_sys_stub_safe!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn ml_timer_forced_evaluation() -> boolean_t {
    crate::xnu_sys_stub!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn timer_call_get_priority_params(
) -> *mut timer_coalescing_priority_params_ns_t {
    ptr::addr_of_mut!(COALESCING_PARAMS)
}

/// `mpqueue_init` is hand-written from a macro, and an empty circular list that does not point
/// at itself corrupts the first enqueue rather than failing, so it is checked here.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_leaves_an_empty_circular_queue() {
        unsafe {
            let mut q: Box<mpqueue_head_t> = Box::new(std::mem::zeroed());
            mpqueue_init(&mut *q);

            let head = ptr::addr_of_mut!((*q).head);
            assert_eq!((*head).next, head, "empty list head must point at itself");
            assert_eq!((*head).prev, head, "empty list head must point at itself");
            assert_eq!((*q).count, 0);
            assert_eq!(
                (*q).earliest_soft_deadline,
                u64::MAX,
                "an un-armed queue must not look like it is already due"
            );
            assert!(
                (*q).mpq_pqhead.pq_root.is_null(),
                "priority_queue_init is a bzero, so the root must be null"
            );
        }
    }
}
