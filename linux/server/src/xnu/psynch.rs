//! `xnu-sys/src/psynch.c`, in Rust (#71, eleventh file).
//!
//! NAMED `xnu_sys_psynch` because `linux/server/src/psynch.rs` already exists and is the DAEMON
//! side, the RPC handlers the guest calls. This is the layer under it: the glue that lets the
//! imported XNU pthread kext run against xnu-sys's task and thread structures.
//!
//! 678 lines of C, of which only about 218 are glue. The rest is lifted XNU, and the file marks
//! it: `bsd/kern/kern_synch.c` for the sleep path (`_sleep`, `_sleep_continue`, `msleep`,
//! `wakeup`), `bsd/kern/kern_time.c` for `microuptime` and `tvtoabstime`, `bsd/kern/kern_subr.c`
//! for `hashinit` and `hashdestroy`, and `bsd/pthread/pthread_shims.c` for five of the six
//! turnstile wait shims. Those regions are translated as they stand, comments included, so that
//! a later diff against upstream still reads.
//!
//! THE KEY OBSERVATION IS THE C FILE'S OWN, at line 76: the psynch code never dereferences
//! `proc_t` or `uthread_t`. It reaches everything through the callback table, so xnu-sys can
//! hand it a `xnu_sys_task_t*` and a `xnu_sys_thread_t*` under those names and the kext is none the
//! wiser. Every cast in here that looks alarming is that substitution.
//!
//! WHAT NEEDED HELP FROM C:
//!
//!   * `xnu_sys_task_for_xnu_task` and `xnu_sys_thread_for_xnu_thread` are `always_inline`, so
//!     there is no symbol to call. Both are pointer arithmetic back from an embedded field, so
//!     they are computed here with `offset_of!` (the same as [`crate::xnu::debug`] and
//!     [`crate::xnu::condvar`] already do).
//!   * `current_task`, `kheap_alloc` and `kheap_free` are macros or statement expressions;
//!     they go through the `xnu_sys_rs_` shims.
//!   * `thread->map` is a field of the OPAQUE `struct thread`, so `shim_current_map` reads it
//!     through `xnu_sys_rs_thread_map`.
//!
//! WHAT THE C DOES THAT RUST WILL NOT:
//!
//!   * `_sleep` uses `goto block` and `goto out`. Both jump FORWARD, so both become labeled
//!     blocks: `break 'block` lands exactly where `block:` sits, and `break 'out` skips the
//!     `switch` the way `goto out` does.
//!   * `unix_syscall_return` is `__attribute__((noreturn))`, so it is `-> !` here. The callback
//!     table field is declared returning `void`, so it goes in through a one-line trampoline
//!     rather than leaning on a `!`-to-`()` coercion of a function POINTER.
//!   * `act_set_astbsd` and `SHOULDissignal` are `static` in psynch.c and must stay private:
//!     giving them symbols would collide with the real XNU ones.

use std::mem::{offset_of, size_of, MaybeUninit};
use std::os::raw::{c_char, c_int, c_void};
use std::ptr;

use crate::bindings::{
    self, xnu_sys_rs_host_consts_XNU_SYS_RS_CONFIG_THREAD_MAX,
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_ABORTSAFE, xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_AWAKENED,
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED,
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_RESTART, xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_TIMED_OUT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_UNINT, xnu_sys_rs_host_consts_XNU_SYS_RS_Z_WAITOK,
    xnu_sys_rs_host_consts_XNU_SYS_RS_Z_ZERO, xnu_sys_task, xnu_sys_thread, event_t, ksyn_waitq_element,
    lck_attr_t, lck_grp_attr_t, lck_grp_t, lck_mtx_t, proc_, proc_t, task_t, thread_t, timespec,
    timeval, turnstile, turnstile_type_t, turnstile_update_complete_flags_t,
    turnstile_update_flags_TURNSTILE_DELAYED_UPDATE,
    turnstile_update_flags_TURNSTILE_IMMEDIATE_UPDATE,
    turnstile_update_flags_TURNSTILE_INHERITOR_THREAD, uthread, vm_map_t, wait_result_t,
    EINTR, ERESTART, EWOULDBLOCK, KERN_FAILURE, LCK_SLEEP_DEFAULT, LCK_SLEEP_SPIN,
    LCK_SLEEP_UNLOCK, NSEC_PER_SEC, NSEC_PER_USEC, PCATCH, PDROP, PSPIN,
    TIMEOUT_URGENCY_USER_NORMAL,
};
use crate::xnu::init::xnu_sys_hooks;

/// `THREAD_CONTINUE_NULL`.
const THREAD_CONTINUE_NULL: bindings::thread_continue_t = None;
/// `TURNSTILE_NULL`, a cast macro rather than an enumerator.
const TURNSTILE_NULL: *mut turnstile = ptr::null_mut();

// The three lock-group globals the kext declares extern, all null as psynch.c leaves them
// (LCK_GRP_ATTR_NULL, LCK_GRP_NULL, LCK_ATTR_NULL are each NULL). lck_mtx_alloc_init is called
// with the last two and accepts null for both.
#[no_mangle]
pub static mut pthread_lck_grp_attr: *mut lck_grp_attr_t = ptr::null_mut();
#[no_mangle]
pub static mut pthread_lck_grp: *mut lck_grp_t = ptr::null_mut();
#[no_mangle]
pub static mut pthread_lck_attr: *mut lck_attr_t = ptr::null_mut();

#[no_mangle]
pub static mut pthread_debug_tracing: u32 = 1;

// The nine pthread-kext entry points. psynch.c re-declares these rather than including the
// kext's kern_internal.h; wrapper.h now carries the same block, so they are bound.
extern "C" {
    /// Defined in `pthread/kern_synch.c`, declared only in psynch.c, so bindgen never sees it.
    fn xnu_sys_psynch_thread_dying(thread: thread_t, kwe: *mut c_void);
}

/// `xnu_sys_thread_for_xnu_thread`: the XNU thread is embedded in the xnu-sys one.
/// `always_inline` in C, so there is no symbol.
#[inline]
unsafe fn thread_for_xnu_thread(xnu_thread: thread_t) -> *mut xnu_sys_thread {
    if xnu_thread.is_null() {
        return ptr::null_mut();
    }
    (xnu_thread as *mut u8).sub(offset_of!(xnu_sys_thread, xnu_thread)) as *mut xnu_sys_thread
}

/// `xnu_sys_task_for_xnu_task`, same shape.
#[inline]
unsafe fn task_for_xnu_task(xnu_task: task_t) -> *mut xnu_sys_task {
    if xnu_task.is_null() {
        return ptr::null_mut();
    }
    (xnu_task as *mut u8).sub(offset_of!(xnu_sys_task, xnu_task)) as *mut xnu_sys_task
}

//
// The nine forwarding wrappers. Each one supplies `current_proc()` and passes the rest
// through, which is all psynch.c does.
//

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_cvbroad(
    cv: u64,
    cvlsgen: u64,
    cvudgen: u64,
    flags: u32,
    mutex: u64,
    mugen: u64,
    tid: u64,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_cvbroad(
        current_proc(),
        cv,
        cvlsgen,
        cvudgen,
        flags,
        mutex,
        mugen,
        tid,
        retval,
    )
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_cvclrprepost(
    cv: u64,
    cvgen: u32,
    cvugen: u32,
    cvsgen: u32,
    prepocnt: u32,
    preposeq: u32,
    flags: u32,
    retval: *mut u32,
) -> c_int {
    // The C casts retval to int*: the RPC signature says uint32_t, the kext says int, and the
    // two are the same four bytes.
    bindings::_psynch_cvclrprepost(
        current_proc(),
        cv,
        cvgen,
        cvugen,
        cvsgen,
        prepocnt,
        preposeq,
        flags,
        retval as *mut c_int,
    )
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_cvsignal(
    cv: u64,
    cvlsgen: u64,
    cvugen: u32,
    threadport: i32,
    mutex: u64,
    mugen: u64,
    tid: u64,
    flags: u32,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_cvsignal(
        current_proc(),
        cv,
        cvlsgen,
        cvugen,
        threadport,
        mutex,
        mugen,
        tid,
        flags,
        retval,
    )
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_cvwait(
    cv: u64,
    cvlsgen: u64,
    cvugen: u32,
    mutex: u64,
    mugen: u64,
    flags: u32,
    sec: i64,
    nsec: u32,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_cvwait(
        current_proc(),
        cv,
        cvlsgen,
        cvugen,
        mutex,
        mugen,
        flags,
        sec,
        nsec,
        retval,
    )
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_mutexdrop(
    mutex: u64,
    mgen: u32,
    ugen: u32,
    tid: u64,
    flags: u32,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_mutexdrop(current_proc(), mutex, mgen, ugen, tid, flags, retval)
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_mutexwait(
    mutex: u64,
    mgen: u32,
    ugen: u32,
    tid: u64,
    flags: u32,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_mutexwait(current_proc(), mutex, mgen, ugen, tid, flags, retval)
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_rw_rdlock(
    rwlock: u64,
    lgenval: u32,
    ugenval: u32,
    rw_wc: u32,
    flags: i32,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_rw_rdlock(current_proc(), rwlock, lgenval, ugenval, rw_wc, flags, retval)
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_rw_unlock(
    rwlock: u64,
    lgenval: u32,
    ugenval: u32,
    rw_wc: u32,
    flags: i32,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_rw_unlock(current_proc(), rwlock, lgenval, ugenval, rw_wc, flags, retval)
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_rw_wrlock(
    rwlock: u64,
    lgenval: u32,
    ugenval: u32,
    rw_wc: u32,
    flags: i32,
    retval: *mut u32,
) -> c_int {
    bindings::_psynch_rw_wrlock(current_proc(), rwlock, lgenval, ugenval, rw_wc, flags, retval)
}

/// The kext's own init, in the C's order. `pthread_list_mlock` FIRST: a null one was a silent
/// SIGSEGV in the psynch path once already, so its allocation is load bearing rather than
/// incidental.
#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_init() {
    bindings::pthread_list_mlock = bindings::lck_mtx_alloc_init(pthread_lck_grp, pthread_lck_attr);

    bindings::pth_global_hashinit();
    bindings::psynch_thcall =
        bindings::thread_call_allocate(Some(wq_cleanup_trampoline), ptr::null_mut());
    bindings::psynch_zoneinit();
}

/// `thread_call_allocate` takes `void (*)(thread_call_param_t, thread_call_param_t)` and
/// `psynch_wq_cleanup` is declared `void (*)(void*, void*)`. Identical after the typedefs, but
/// C converts silently between them and Rust will not, so the conversion is one call rather
/// than a transmute of a function pointer.
unsafe extern "C" fn wq_cleanup_trampoline(a: *mut c_void, b: *mut c_void) {
    bindings::psynch_wq_cleanup(a, b)
}

// NOTE (from psynch.c):
// the psynch code doesn't actually access `proc_t` or `uthread_t`; it invokes the callbacks we
// give it in order to do that stuff. therefore, we can actually give it any context we like for
// those pointers. we just use our duct-taped task and thread structures.

#[no_mangle]
pub unsafe extern "C" fn current_proc() -> proc_t {
    task_for_xnu_task(bindings::xnu_sys_rs_current_task()) as proc_t
}

#[no_mangle]
pub unsafe extern "C" fn current_uthread() -> *mut uthread {
    thread_for_xnu_thread(bindings::current_thread()) as *mut uthread
}

#[no_mangle]
pub unsafe extern "C" fn proc_pid(proc: proc_t) -> c_int {
    let task = proc as *mut xnu_sys_task;
    (*task).saved_pid as c_int
}

/// `static` and `noreturn` in the C. Only ever reached through the callback table.
unsafe extern "C" fn unix_syscall_return(retval: c_int) -> ! {
    bindings::thread_syscall_return(retval);
    // `__builtin_unreachable()`: thread_syscall_return does not come back.
    std::hint::unreachable_unchecked()
}

/// The table field is declared returning `void`, so the noreturn one goes in through this
/// rather than leaning on a `!`-to-`()` coercion of a function POINTER.
unsafe extern "C" fn unix_syscall_return_cb(retval: c_int) {
    unix_syscall_return(retval)
}

/// `static` in the C, and it must stay private: XNU has a real `act_set_astbsd`.
unsafe fn act_set_astbsd(_thread: thread_t) {
    crate::xnu_sys_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn get_bsdthread_info(th: thread_t) -> *mut uthread {
    thread_for_xnu_thread(th) as *mut uthread
}

/// xnu-sys `#undef`s the XNU macro and substitutes this. Always false, so the signal paths
/// below are dead for now; they are kept because upstream keeps them.
unsafe fn should_issignal(_task: *mut xnu_sys_task, _thread: *mut xnu_sys_thread) -> bool {
    crate::xnu_sys_stub!();
    false
}

//
// <adapted from="xnu://7195.141.2/bsd/kern/kern_synch.c">
//

unsafe extern "C" fn _sleep_continue(_parameter: *mut c_void, wresult: wait_result_t) {
    let p = current_proc() as *mut xnu_sys_task;
    let self_: thread_t = bindings::current_thread();
    let mut error: c_int = 0;

    let ut = get_bsdthread_info(self_) as *mut xnu_sys_thread;
    let catch = (*ut).uu_pri as u32 & PCATCH;
    let dropmutex = (*ut).uu_pri as u32 & PDROP;
    let spinmutex = (*ut).uu_pri as u32 & PSPIN;

    // The C switch falls through from THREAD_AWAKENED into THREAD_INTERRUPTED when `catch` is
    // set, which is why this is an if-chain rather than a match: Rust has no fallthrough.
    if wresult == thread_timed_out() {
        error = EWOULDBLOCK as c_int;
    } else if wresult == thread_awakened() || wresult == thread_interrupted() {
        // Posix implies any signal should be delivered first, regardless of whether awakened
        // due to receiving event.
        let interrupted = wresult == thread_interrupted() || catch != 0;
        if interrupted {
            if catch != 0 {
                if bindings::thread_should_abort(self_) != 0 {
                    error = EINTR as c_int;
                } else if should_issignal(p, ut) {
                    crate::xnu_sys_stub_unsafe!("_sleep_continue SHOULDissignal");
                } else {
                    crate::xnu_sys_stub!("THREAD_INTERRUPTED IN _sleep_continue");
                    error = EINTR as c_int;
                }
            } else {
                error = EINTR as c_int;
            }
        }
    }

    if error == EINTR as c_int || error == ERESTART {
        act_set_astbsd(self_);
    }

    if !(*ut).uu_mtx.is_null() && dropmutex == 0 {
        if spinmutex != 0 {
            bindings::lck_mtx_lock_spin((*ut).uu_mtx);
        } else {
            bindings::lck_mtx_lock((*ut).uu_mtx);
        }
    }
    (*ut).uu_wchan = ptr::null_mut();
    (*ut).uu_wmesg = ptr::null();

    let continuation = (*ut).uu_continuation.expect("uu_continuation set before block");
    unix_syscall_return(continuation(error))
    // unix_syscall_return does not return; `!` coerces to the `()` this signature promises.
}

/*
 * Give up the processor till a wakeup occurs
 * on chan, at which time the process
 * enters the scheduling queue at priority pri.
 * The most important effect of pri is that when
 * pri<=PZERO a signal cannot disturb the sleep;
 * if pri>PZERO signals will be processed.
 * If pri&PCATCH is set, signals will cause sleep
 * to return 1, rather than longjmp.
 * Callers of this routine must be prepared for
 * premature return, and check that the reason for
 * sleeping has gone away.
 *
 * if msleep was the entry point, than we have a mutex to deal with
 *
 * The mutex is unlocked before the caller is blocked, and
 * relocked before msleep returns unless the priority includes the PDROP
 * flag... if PDROP is specified, _sleep returns with the mutex unlocked
 * regardless of whether it actually blocked or not.
 */
unsafe fn _sleep(
    chan: bindings::caddr_t,
    pri: c_int,
    wmsg: *const c_char,
    abstime: u64,
    continuation: Option<unsafe extern "C" fn(c_int) -> c_int>,
    mtx: *mut lck_mtx_t,
) -> c_int {
    let self_: thread_t = bindings::current_thread();
    let dropmutex = pri as u32 & PDROP;
    let spinmutex = pri as u32 & PSPIN;
    // Deliberately not pre-set: every path to the switch below assigns it, and letting the
    // compiler prove that is stronger than the C, which declares it uninitialized.
    let wait_result: wait_result_t;
    let mut error: c_int = 0;

    let ut = get_bsdthread_info(self_) as *mut xnu_sys_thread;
    let p = current_proc() as *mut xnu_sys_task;

    let catch = if pri as u32 & PCATCH != 0 {
        thread_abortsafe()
    } else {
        thread_unint()
    };

    /* set wait message & channel */
    (*ut).uu_wchan = chan;
    (*ut).uu_wmesg = if wmsg.is_null() {
        b"unknown\0".as_ptr() as *const c_char
    } else {
        wmsg
    };

    // `goto out` skips the switch; `goto block` jumps into the else branch. Both are forward
    // jumps, so both are labeled blocks.
    'out: {
        if !mtx.is_null() && !chan.is_null() && continuation.is_none() {
            let mut flags = if dropmutex != 0 {
                LCK_SLEEP_UNLOCK
            } else {
                LCK_SLEEP_DEFAULT
            };

            if spinmutex != 0 {
                flags |= LCK_SLEEP_SPIN;
            }

            wait_result = if abstime != 0 {
                bindings::lck_mtx_sleep_deadline(
                    mtx,
                    flags as bindings::lck_sleep_action_t,
                    chan as event_t,
                    catch,
                    abstime,
                )
            } else {
                bindings::lck_mtx_sleep(
                    mtx,
                    flags as bindings::lck_sleep_action_t,
                    chan as event_t,
                    catch,
                )
            };
        } else {
            'block: {
                if !chan.is_null() {
                    bindings::assert_wait_deadline(chan as event_t, catch, abstime);
                }
                if !mtx.is_null() {
                    bindings::lck_mtx_unlock(mtx);
                }

                if catch == thread_abortsafe() {
                    if should_issignal(p, ut) {
                        crate::xnu_sys_stub_unsafe!("_sleep:SHOULDissignal");
                    }
                    if bindings::thread_should_abort(self_) != 0 {
                        if bindings::clear_wait(self_, thread_interrupted()) == KERN_FAILURE as i32
                        {
                            break 'block;
                        }
                        error = EINTR as c_int;

                        if !mtx.is_null() && dropmutex == 0 {
                            if spinmutex != 0 {
                                bindings::lck_mtx_lock_spin(mtx);
                            } else {
                                bindings::lck_mtx_lock(mtx);
                            }
                        }
                        break 'out;
                    }
                }
            }

            // block:
            if continuation.is_some() {
                (*ut).uu_continuation = continuation;
                (*ut).uu_pri = pri as u16;
                (*ut).uu_mtx = mtx;
                bindings::thread_block(Some(_sleep_continue));
                /* NOTREACHED */
            }

            wait_result = bindings::thread_block(THREAD_CONTINUE_NULL);

            if !mtx.is_null() && dropmutex == 0 {
                if spinmutex != 0 {
                    bindings::lck_mtx_lock_spin(mtx);
                } else {
                    bindings::lck_mtx_lock(mtx);
                }
            }
        }

        // Same fallthrough shape as _sleep_continue: THREAD_AWAKENED and THREAD_RESTART fall
        // into THREAD_INTERRUPTED when the wait was abortsafe.
        if wait_result == thread_timed_out() {
            error = EWOULDBLOCK as c_int;
        } else if wait_result == thread_awakened()
            || wait_result == thread_restart()
            || wait_result == thread_interrupted()
        {
            let interrupted =
                wait_result == thread_interrupted() || catch == thread_abortsafe();
            if interrupted {
                if catch == thread_abortsafe() {
                    if bindings::thread_should_abort(self_) != 0 {
                        error = EINTR as c_int;
                    } else if should_issignal(p, ut) {
                        crate::xnu_sys_stub_unsafe!("THREAD_INTERRUPTED SHOULDissignal");
                    } else {
                        crate::xnu_sys_stub!("THREAD_INTERRUPTED in _sleep");
                        error = EINTR as c_int;
                    }
                } else {
                    error = EINTR as c_int;
                }
            }
        }
    }

    // out:
    if error == EINTR as c_int || error == ERESTART {
        act_set_astbsd(self_);
    }
    (*ut).uu_wchan = ptr::null_mut();
    (*ut).uu_wmesg = ptr::null();

    error
}

//
// </adapted>
//

//
// <copied from="xnu://7195.141.2/bsd/kern/kern_synch.c">
//

#[no_mangle]
pub unsafe extern "C" fn msleep(
    chan: *mut c_void,
    mtx: *mut lck_mtx_t,
    pri: c_int,
    wmsg: *const c_char,
    ts: *mut timespec,
) -> c_int {
    let mut abstime: u64 = 0;

    if !ts.is_null() && ((*ts).tv_sec != 0 || (*ts).tv_nsec != 0) {
        bindings::nanoseconds_to_absolutetime(
            (*ts).tv_sec as u64 * NSEC_PER_SEC as u64 + (*ts).tv_nsec as u64,
            &mut abstime,
        );
        bindings::clock_absolutetime_interval_to_deadline(abstime, &mut abstime);
    }

    _sleep(chan as bindings::caddr_t, pri, wmsg, abstime, None, mtx)
}

/// Wake up all processes sleeping on chan.
#[no_mangle]
pub unsafe extern "C" fn wakeup(chan: *mut c_void) {
    // `thread_wakeup(x)` is `thread_wakeup_prim((x), FALSE, THREAD_AWAKENED)`.
    bindings::thread_wakeup_prim(chan as event_t, 0, thread_awakened());
}

//
// </copied>
//

//
// <copied from="xnu://7195.141.2/bsd/kern/kern_time.c">
//

#[no_mangle]
pub unsafe extern "C" fn microuptime(tvp: *mut timeval) {
    let mut tv_sec: bindings::clock_sec_t = 0;
    let mut tv_usec: bindings::clock_usec_t = 0;

    bindings::clock_get_system_microtime(&mut tv_sec, &mut tv_usec);

    (*tvp).tv_sec = tv_sec as _;
    (*tvp).tv_usec = tv_usec as _;
}

#[no_mangle]
pub unsafe extern "C" fn tvtoabstime(tvp: *mut timeval) -> u64 {
    let mut result: u64 = 0;
    let mut usresult: u64 = 0;

    bindings::clock_interval_to_absolutetime_interval((*tvp).tv_sec as u32, NSEC_PER_SEC, &mut result);
    bindings::clock_interval_to_absolutetime_interval(
        (*tvp).tv_usec as u32,
        NSEC_PER_USEC,
        &mut usresult,
    );

    result + usresult
}

//
// </copied>
//

//
// <copied from="xnu://7195.141.2/bsd/kern/kern_subr.c">
//

/// `LIST_HEAD(generic_hash_head, generic)`: one pointer, and only its size is used.
#[repr(C)]
struct generic_hash_head {
    lh_first: *mut c_void,
}

/// General routine to allocate a hash table.
#[no_mangle]
pub unsafe extern "C" fn hashinit(
    elements: c_int,
    _type: c_int,
    hashmask: *mut ::std::os::raw::c_ulong,
) -> *mut c_void {
    if elements <= 0 {
        // XNU calls panic() here, which takes the kernel down. An abort is the closest thing
        // the daemon has, and a Rust panic in an extern "C" function aborts rather than
        // unwinding into C.
        panic!("hashinit: bad cnt");
    }

    // misc.c exports fls, and misc.c is Rust now, so this is the same one the C called.
    let hashsize: usize = 1usize << (crate::xnu::misc::fls(elements as ::std::os::raw::c_uint) - 1);
    let hashtbl = bindings::xnu_sys_rs_kheap_alloc(
        hashsize * size_of::<generic_hash_head>(),
        (xnu_sys_rs_host_consts_XNU_SYS_RS_Z_WAITOK | xnu_sys_rs_host_consts_XNU_SYS_RS_Z_ZERO) as c_int,
    );
    if !hashtbl.is_null() {
        *hashmask = (hashsize - 1) as _;
    }
    hashtbl
}

#[no_mangle]
pub unsafe extern "C" fn hashdestroy(
    hash: *mut c_void,
    _type: c_int,
    hashmask: ::std::os::raw::c_ulong,
) {
    debug_assert!(
        (hashmask + 1) & hashmask == 0,
        "powerof2(hashmask + 1)"
    );
    bindings::xnu_sys_rs_kheap_free(hash, (hashmask as usize + 1) * size_of::<generic_hash_head>());
}

//
// </copied>
//

unsafe extern "C" fn shim_current_map() -> vm_map_t {
    let thread = thread_for_xnu_thread(bindings::current_thread());
    // `thread->map` is a field of the opaque struct thread, hence the shim.
    bindings::xnu_sys_rs_thread_map(&mut (*thread).xnu_thread) as vm_map_t
}

unsafe extern "C" fn shim_get_task_threadmax() -> u32 {
    xnu_sys_rs_host_consts_XNU_SYS_RS_CONFIG_THREAD_MAX as u32
}

unsafe extern "C" fn shim_proc_get_pthhash(proc: *mut proc_) -> *mut c_void {
    let task = proc as *mut xnu_sys_task;
    (*task).p_pthhash
}

unsafe extern "C" fn shim_proc_set_pthhash(proc: *mut proc_, ptr: *mut c_void) {
    let task = proc as *mut xnu_sys_task;
    (*task).p_pthhash = ptr;
}

//
// <copied from="xnu://7195.141.2/bsd/pthread/pthread_shims.c">
//

unsafe extern "C" fn shim_psynch_wait_cleanup() {
    bindings::turnstile_cleanup();
}

unsafe extern "C" fn shim_psynch_wait_complete(kwq: usize, tstore: *mut *mut turnstile) {
    assert!(!tstore.is_null());
    bindings::turnstile_complete(
        kwq,
        tstore,
        ptr::null_mut(),
        turnstile_type_t::TURNSTILE_PTHREAD_MUTEX,
    );
}

unsafe extern "C" fn shim_psynch_wait_prepare(
    kwq: usize,
    tstore: *mut *mut turnstile,
    owner: thread_t,
    block_hint: bindings::block_hint_t,
    deadline: u64,
) -> wait_result_t {
    if !tstore.is_null() {
        let ts = bindings::turnstile_prepare(
            kwq,
            tstore,
            TURNSTILE_NULL,
            turnstile_type_t::TURNSTILE_PTHREAD_MUTEX,
        );

        bindings::turnstile_update_inheritor(
            ts,
            owner as bindings::turnstile_inheritor_t,
            turnstile_update_flags_TURNSTILE_DELAYED_UPDATE
                | turnstile_update_flags_TURNSTILE_INHERITOR_THREAD,
        );

        bindings::thread_set_pending_block_hint(bindings::current_thread(), block_hint);

        bindings::waitq_assert_wait64_leeway(
            &mut (*ts).ts_waitq,
            kwq as bindings::event64_t,
            thread_abortsafe(),
            TIMEOUT_URGENCY_USER_NORMAL as bindings::wait_timeout_urgency_t,
            deadline,
            0,
        )
    } else {
        bindings::thread_set_pending_block_hint(bindings::current_thread(), block_hint);

        bindings::assert_wait_deadline_with_leeway(
            kwq as event_t,
            thread_abortsafe(),
            TIMEOUT_URGENCY_USER_NORMAL as bindings::wait_timeout_urgency_t,
            deadline,
            0,
        )
    }
}

unsafe extern "C" fn shim_psynch_wait_update_complete(ts: *mut turnstile) {
    assert!(!ts.is_null());
    bindings::turnstile_update_inheritor_complete(
        ts,
        turnstile_update_complete_flags_t::TURNSTILE_INTERLOCK_NOT_HELD,
    );
}

unsafe extern "C" fn shim_psynch_wait_update_owner(
    kwq: usize,
    owner: thread_t,
    tstore: *mut *mut turnstile,
) {
    let ts = bindings::turnstile_prepare(
        kwq,
        tstore,
        TURNSTILE_NULL,
        turnstile_type_t::TURNSTILE_PTHREAD_MUTEX,
    );

    bindings::turnstile_update_inheritor(
        ts,
        owner as bindings::turnstile_inheritor_t,
        turnstile_update_flags_TURNSTILE_IMMEDIATE_UPDATE
            | turnstile_update_flags_TURNSTILE_INHERITOR_THREAD,
    );
    bindings::turnstile_update_inheritor_complete(
        ts,
        turnstile_update_complete_flags_t::TURNSTILE_INTERLOCK_HELD,
    );
    bindings::turnstile_complete(
        kwq,
        tstore,
        ptr::null_mut(),
        turnstile_type_t::TURNSTILE_PTHREAD_MUTEX,
    );
}

//
// </copied>
//

//
// <adapted from="xnu://7195.141.2/bsd/pthread/pthread_shims.c">
//

unsafe extern "C" fn shim_psynch_wait_wakeup(
    kwq: usize,
    kwe: *mut ksyn_waitq_element,
    tstore: *mut *mut turnstile,
) -> bindings::kern_return_t {
    // `__container_of((void*)kwe, xnu_sys_thread_t, kwe)`.
    let thread =
        (kwe as *mut u8).sub(offset_of!(xnu_sys_thread, kwe)) as *mut xnu_sys_thread;

    if !tstore.is_null() {
        let ts = bindings::turnstile_prepare(
            kwq,
            tstore,
            TURNSTILE_NULL,
            turnstile_type_t::TURNSTILE_PTHREAD_MUTEX,
        );
        bindings::turnstile_update_inheritor(
            ts,
            &mut (*thread).xnu_thread as *mut _ as bindings::turnstile_inheritor_t,
            turnstile_update_flags_TURNSTILE_IMMEDIATE_UPDATE
                | turnstile_update_flags_TURNSTILE_INHERITOR_THREAD,
        );

        let kr = bindings::waitq_wakeup64_thread(
            &mut (*ts).ts_waitq,
            kwq as bindings::event64_t,
            &mut (*thread).xnu_thread,
            thread_awakened(),
        );

        bindings::turnstile_update_inheritor_complete(
            ts,
            turnstile_update_complete_flags_t::TURNSTILE_INTERLOCK_HELD,
        );
        bindings::turnstile_complete(
            kwq,
            tstore,
            ptr::null_mut(),
            turnstile_type_t::TURNSTILE_PTHREAD_MUTEX,
        );
        kr
    } else {
        bindings::thread_wakeup_thread(kwq as event_t, &mut (*thread).xnu_thread)
    }
}

//
// </adapted>
//

unsafe extern "C" fn shim_pthread_testcancel(_presyscall: c_int) {
    crate::xnu_sys_stub!();
}

unsafe extern "C" fn shim_uthread_get_uukwe(uthread: *mut uthread) -> *mut c_void {
    let thread = uthread as *mut xnu_sys_thread;
    &mut (*thread).kwe as *mut _ as *mut c_void
}

unsafe extern "C" fn shim_uthread_is_cancelled(_uthread: *mut uthread) -> c_int {
    crate::xnu_sys_stub!();
    0
}

/// Not `static` in the C either, so it keeps its symbol.
#[no_mangle]
pub unsafe extern "C" fn shim_uthread_set_returnval(_uthread: *mut uthread, retval: c_int) {
    if let Some(set_bsd_retval) = (*xnu_sys_hooks).current_thread_set_bsd_retval {
        // The hook is declared taking uint32_t and the C passes an int, converting silently.
        set_bsd_retval(retval as u32);
    }
}

/// The callback vtable, 96 fields of which psynch.c fills 18 and leaves the rest zero.
///
/// The C gets the zeroing from static initialisation, and so does this: `MaybeUninit::zeroed`
/// is a const fn, and a zeroed `Option<extern "C" fn>` is `None`, so the table is built at
/// compile time exactly as the C's is. Filling it in `xnu_sys_psynch_init` instead would leave a
/// window where `pthread_kern` pointed at nothing.
const ZEROED_CALLBACKS: bindings::pthread_callbacks_s =
    unsafe { MaybeUninit::zeroed().assume_init() };

/// The table holds raw pointers, so it is not `Sync` and cannot be a plain `static`. It is
/// nonetheless shared exactly as the C shares it: written once at compile time, then only read,
/// by whichever thread is in the kext.
#[repr(transparent)]
struct SyncCallbacks(bindings::pthread_callbacks_s);
unsafe impl Sync for SyncCallbacks {}

static PTHREAD_KERN_REAL: SyncCallbacks = SyncCallbacks(bindings::pthread_callbacks_s {
    current_map: Some(shim_current_map),
    get_bsdthread_info: Some(get_bsdthread_info),
    get_task_threadmax: Some(shim_get_task_threadmax),
    proc_get_pthhash: Some(shim_proc_get_pthhash),
    proc_set_pthhash: Some(shim_proc_set_pthhash),
    psynch_wait_cleanup: Some(shim_psynch_wait_cleanup),
    psynch_wait_complete: Some(shim_psynch_wait_complete),
    psynch_wait_prepare: Some(shim_psynch_wait_prepare),
    psynch_wait_update_complete: Some(shim_psynch_wait_update_complete),
    psynch_wait_update_owner: Some(shim_psynch_wait_update_owner),
    psynch_wait_wakeup: Some(shim_psynch_wait_wakeup),
    __pthread_testcancel: Some(shim_pthread_testcancel),
    task_findtid: Some(bindings::task_findtid),
    thread_deallocate_safe: Some(bindings::thread_deallocate_safe),
    unix_syscall_return: Some(unix_syscall_return_cb),
    uthread_get_uukwe: Some(shim_uthread_get_uukwe),
    uthread_is_cancelled: Some(shim_uthread_is_cancelled),
    uthread_set_returnval: Some(shim_uthread_set_returnval),
    ..ZEROED_CALLBACKS
});

#[no_mangle]
pub static mut pthread_kern: bindings::pthread_callbacks_t = &PTHREAD_KERN_REAL.0;

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_task_init(task: *mut xnu_sys_task) {
    bindings::_pth_proc_hashinit(task as proc_t);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_task_destroy(task: *mut xnu_sys_task) {
    bindings::_pth_proc_hashdelete(task as proc_t);
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_thread_init(_thread: *mut xnu_sys_thread) {
    // nothing for now
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_psynch_thread_destroy(thread: *mut xnu_sys_thread) {
    xnu_sys_psynch_thread_dying(
        &mut (*thread).xnu_thread,
        &mut (*thread).kwe as *mut _ as *mut c_void,
    );
}

// The wait results and interrupt levels are anonymous-enum values in XNU, so they come across
// through the derived-constants enum rather than by name. Wrapped so the code above reads like
// the C.
#[inline]
fn thread_awakened() -> wait_result_t {
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_AWAKENED as wait_result_t
}
#[inline]
fn thread_timed_out() -> wait_result_t {
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_TIMED_OUT as wait_result_t
}
#[inline]
fn thread_interrupted() -> wait_result_t {
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_INTERRUPTED as wait_result_t
}
#[inline]
fn thread_restart() -> wait_result_t {
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_RESTART as wait_result_t
}
#[inline]
fn thread_abortsafe() -> bindings::wait_interrupt_t {
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_ABORTSAFE as bindings::wait_interrupt_t
}
#[inline]
fn thread_unint() -> bindings::wait_interrupt_t {
    xnu_sys_rs_host_consts_XNU_SYS_RS_THREAD_UNINT as bindings::wait_interrupt_t
}
