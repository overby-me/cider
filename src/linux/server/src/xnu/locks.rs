//! Mutexes, spin locks, ticket locks and the sleep routines: the Rust replacement for
//! `xnu-sys/src/locks.c` (#71, eighth file).
//!
//! This is the file every guest thread runs on. The mutex here is NOT a native lock, and the
//! comment block in the C explains why at length; the short version is that a native lock would
//! put the whole Linux thread to sleep, when what xnu-sys wants is to suspend one MICROTHREAD
//! and leave the thread free to run others. So the queue of waiters is protected by a real
//! futex-based `libsimple_lock` held for a very short critical section, and the waiters
//! themselves are microthreads parked through the `thread_suspend` hook.
//!
//! THE HANDOFF THAT MAKES IT CORRECT, and it is worth stating because it looks like a bug:
//! `thread_suspend` is called while the queue lock is HELD, and the hook drops it once the
//! microthread is fully suspended. That is what closes the window between adding yourself to
//! the queue and actually going to sleep, in which a waker could otherwise miss you.
//!
//! WHY THIS FILE IS SAFE TO PORT, despite being the one everything depends on: it fails LOUDLY.
//! `stage3_spike` drives 500,000 suspend and resume round-trips through exactly these paths, so
//! a lost waiter hangs and a corrupted queue crashes. There is no silent-wrong-answer mode of
//! the kind `host.c` had.
//!
//! WHAT IS NOT REOPENED. `struct thread` and `struct waitq` stay opaque: this file reaches
//! three fields through them, and reopening the pair measured +17 structs and +68 KB. Those
//! three are C shims. `KERNEL_DEBUG` is absent entirely rather than shimmed, because it expands
//! to `do {} while (0)` in this configuration, so the trace calls have nothing to port.

use std::os::raw::{c_int, c_uint, c_void};
use std::ptr;

use crate::xnu::condvar::{tailq_first, tailq_init, tailq_insert_tail, tailq_remove};

use crate::bindings::{
    assert_wait, assert_wait_deadline, assert_wait_timeout, boolean_t, current_thread,
    xnu_sys_mutex_link_t, xnu_sys_mutex_t, xnu_sys_rs_kalloc, xnu_sys_rs_kfree,
    xnu_sys_rs_thread_rwlock_count, xnu_sys_rs_thread_sched_flags, xnu_sys_rs_waitq_interlock,
    event_t, lck_attr_t, lck_grp_t, lck_mtx_t, lck_rw_t, lck_rw_type_t, lck_sleep_action_t,
    lck_spin_t, lck_ticket_t, libsimple_lock_lock, libsimple_lock_t, libsimple_lock_try_lock,
    libsimple_lock_unlock, thread_block, thread_t, wait_interrupt_t, wait_result_t, waitq,
    LCK_ASSERT_OWNED, LCK_SLEEP_MASK, LCK_SLEEP_PROMOTED_PRI, LCK_SLEEP_SPIN,
    LCK_SLEEP_SPIN_ALWAYS, LCK_SLEEP_UNLOCK, NSEC_PER_USEC, TH_SFLAG_RW_PROMOTED,
};

extern "C" {
    fn panic(format: *const std::os::raw::c_char, ...);
    fn xnu_sys_log(level: c_int, format: *const std::os::raw::c_char, ...);
}

/// `xnu_sys_log_level_warning`. See init.rs for why the level is spelled out.
const XNU_SYS_LOG_LEVEL_WARNING: c_int = 2;

/// `THREAD_WAITING`, `THREAD_CONTINUE_NULL`, `THREAD_UNINT`, `THREAD_TIMED_OUT`.
///
/// Spelled out rather than bound because they are enumerators in headers this file does not
/// otherwise need, and each is compared or passed, never stored. Their values are fixed by the
/// Mach thread-state ABI.
const THREAD_WAITING: wait_result_t = -1;
const THREAD_TIMED_OUT: wait_result_t = 1;
const THREAD_UNINT: wait_interrupt_t = 0;

fn log_warning(what: &str) {
    let mut buf = Vec::with_capacity(what.len() + 1);
    buf.extend_from_slice(what.as_bytes());
    buf.push(0);
    unsafe { xnu_sys_log(XNU_SYS_LOG_LEVEL_WARNING, buf.as_ptr() as *const _) }
}

unsafe fn fail(message: &[u8]) -> ! {
    panic(message.as_ptr() as *const _);
    std::process::abort()
}

// ---------------------------------------------------------------------------------------
// mutex
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_mutex_init(mutex: *mut xnu_sys_mutex_t) {
    (*mutex).xnu_sys_owner = 0;
    crate::xnu::condvar::lock_init(ptr::addr_of_mut!((*mutex).xnu_sys_queue_lock) as *mut libsimple_lock_t);
    tailq_init(ptr::addr_of_mut!((*mutex).xnu_sys_queue_head));
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_mutex_assert(mutex: *mut xnu_sys_mutex_t, should_be_owned: bool) {
    let owned = (*mutex).xnu_sys_owner == current_thread() as usize;

    if should_be_owned && !owned {
        fail(b"Lock assertion failed (not owned but expected to be owned)\0");
    } else if !should_be_owned && owned {
        fail(b"Lock assertion failed (owned but expected not to be owned)\0");
    }
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_mutex_lock(mutex: *mut xnu_sys_mutex_t) {
    let xthread = current_thread();
    let thread = crate::xnu::condvar::thread_for_xnu_thread(xthread);
    let queue_lock = ptr::addr_of_mut!((*mutex).xnu_sys_queue_lock) as *mut libsimple_lock_t;

    if thread.is_null() {
        log_warning("Trying to lock mutex without an active thread!");
        // No microthread to suspend, so fall back to the native queue lock and SPIN. Anything
        // taking this path really does sleep the whole thread, so it must hold briefly.
        loop {
            libsimple_lock_lock(queue_lock);
            if (*mutex).xnu_sys_owner == 0 {
                return;
            }
            libsimple_lock_unlock(queue_lock);
            std::hint::spin_loop();
        }
    }

    xnu_sys_mutex_assert(mutex, false);

    loop {
        libsimple_lock_lock(queue_lock);

        if (*mutex).xnu_sys_owner == 0 || (*mutex).xnu_sys_owner == xthread as usize {
            (*mutex).xnu_sys_owner = xthread as usize;
            libsimple_lock_unlock(queue_lock);
            std::sync::atomic::fence(std::sync::atomic::Ordering::Acquire);
            return;
        }

        tailq_insert_tail(
            ptr::addr_of_mut!((*mutex).xnu_sys_queue_head),
            ptr::addr_of_mut!((*thread).mutex_link) as *mut xnu_sys_mutex_link_t,
        );

        // Called with the queue lock HELD: the hook drops it once the microthread is fully
        // suspended, which is what stops a waker slipping in between the insert and the sleep.
        let hooks = crate::xnu::init::xnu_sys_hooks;
        if let Some(suspend) = (*hooks).thread_suspend {
            suspend(
                (*thread).context,
                None,
                ptr::null_mut(),
                queue_lock,
            );
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_mutex_try_lock(mutex: *mut xnu_sys_mutex_t) -> bool {
    let xthread = current_thread();
    let thread = crate::xnu::condvar::thread_for_xnu_thread(xthread);
    let queue_lock = ptr::addr_of_mut!((*mutex).xnu_sys_queue_lock) as *mut libsimple_lock_t;

    if thread.is_null() {
        log_warning("Trying to lock mutex without an active thread!");
        if libsimple_lock_try_lock(queue_lock) {
            if (*mutex).xnu_sys_owner == 0 {
                return true;
            }
            libsimple_lock_unlock(queue_lock);
        }
        return false;
    }

    xnu_sys_mutex_assert(mutex, false);

    if (*mutex).xnu_sys_owner == 0 || (*mutex).xnu_sys_owner == xthread as usize {
        (*mutex).xnu_sys_owner = xthread as usize;
        libsimple_lock_unlock(queue_lock);
        std::sync::atomic::fence(std::sync::atomic::Ordering::Acquire);
        return true;
    }

    false
}

#[no_mangle]
pub unsafe extern "C" fn xnu_sys_mutex_unlock(mutex: *mut xnu_sys_mutex_t) {
    let xcurr = current_thread();
    let curr = crate::xnu::condvar::thread_for_xnu_thread(xcurr);
    let queue_lock = ptr::addr_of_mut!((*mutex).xnu_sys_queue_lock) as *mut libsimple_lock_t;

    if curr.is_null() {
        log_warning("Trying to unlock mutex without an active thread!");
        libsimple_lock_unlock(queue_lock);
        return;
    }

    xnu_sys_mutex_assert(mutex, true);

    libsimple_lock_lock(queue_lock);
    (*mutex).xnu_sys_owner = 0;

    let head = ptr::addr_of_mut!((*mutex).xnu_sys_queue_head);
    let link = tailq_first(head);

    if !link.is_null() {
        // Contended: wake the OLDEST waiter, which is the head of the queue.
        tailq_remove(head, link);
        let thread = crate::xnu::condvar::thread_for_mutex_link(link);
        let hooks = crate::xnu::init::xnu_sys_hooks;
        if let Some(resume) = (*hooks).thread_resume {
            resume((*thread).context);
        }
    }

    libsimple_lock_unlock(queue_lock);
    std::sync::atomic::fence(std::sync::atomic::Ordering::Release);
}

// ---------------------------------------------------------------------------------------
// lck_mtx, which is a xnu_sys_mutex with an XNU name
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_init(lock: *mut lck_mtx_t, _grp: *mut lck_grp_t, _attr: *mut lck_attr_t) {
    xnu_sys_mutex_init(ptr::addr_of_mut!((*lock).xnu_sys_mutex));
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_destroy(lock: *mut lck_mtx_t, _grp: *mut lck_grp_t) {
    if (*lock).xnu_sys_mutex.xnu_sys_owner != 0 {
        fail(b"Attempt to destroy lock while being held\0");
    }
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_assert(lock: *mut lck_mtx_t, r#type: c_uint) {
    xnu_sys_mutex_assert(ptr::addr_of_mut!((*lock).xnu_sys_mutex), r#type == LCK_ASSERT_OWNED);
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_lock(lock: *mut lck_mtx_t) {
    xnu_sys_mutex_lock(ptr::addr_of_mut!((*lock).xnu_sys_mutex));
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_try_lock(lock: *mut lck_mtx_t) -> boolean_t {
    xnu_sys_mutex_try_lock(ptr::addr_of_mut!((*lock).xnu_sys_mutex)) as boolean_t
}

/// Spinning is not a thing here: xnu-sys cannot disable preemption, so a spin variant is the
/// same mutex. Kept as separate symbols because XNU callers reference all three.
#[no_mangle]
pub unsafe extern "C" fn lck_mtx_lock_spin_always(lock: *mut lck_mtx_t) {
    lck_mtx_lock(lock);
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_lock_spin(lock: *mut lck_mtx_t) {
    lck_mtx_lock(lock);
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_unlock(lock: *mut lck_mtx_t) {
    xnu_sys_mutex_unlock(ptr::addr_of_mut!((*lock).xnu_sys_mutex));
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_init_ext(
    lck: *mut lck_mtx_t,
    _lck_ext: *mut c_void,
    grp: *mut lck_grp_t,
    attr: *mut lck_attr_t,
) {
    lck_mtx_init(lck, grp, attr);
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_alloc_init(
    grp: *mut lck_grp_t,
    attr: *mut lck_attr_t,
) -> *mut lck_mtx_t {
    let lck = xnu_sys_rs_kalloc(std::mem::size_of::<lck_mtx_t>()) as *mut lck_mtx_t;
    if lck.is_null() {
        return ptr::null_mut();
    }
    lck_mtx_init(lck, grp, attr);
    lck
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_free(lck: *mut lck_mtx_t, grp: *mut lck_grp_t) {
    lck_mtx_destroy(lck, grp);
    xnu_sys_rs_kfree(lck as *mut c_void, std::mem::size_of::<lck_mtx_t>());
}

// ---------------------------------------------------------------------------------------
// spin locks, which are mutexes: preemption cannot be disabled here
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn lck_spin_init(lock: *mut lck_spin_t, grp: *mut lck_grp_t, attr: *mut lck_attr_t) {
    lck_mtx_init(ptr::addr_of_mut!((*lock).xnu_sys_interlock), grp, attr);
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_assert(lock: *mut lck_spin_t, r#type: c_uint) {
    lck_mtx_assert(ptr::addr_of_mut!((*lock).xnu_sys_interlock), r#type);
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_destroy(lock: *mut lck_spin_t, grp: *mut lck_grp_t) {
    lck_mtx_destroy(ptr::addr_of_mut!((*lock).xnu_sys_interlock), grp);
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_lock(lock: *mut lck_spin_t) {
    lck_mtx_lock(ptr::addr_of_mut!((*lock).xnu_sys_interlock));
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_try_lock(lock: *mut lck_spin_t) -> boolean_t {
    lck_mtx_try_lock(ptr::addr_of_mut!((*lock).xnu_sys_interlock))
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_unlock(lock: *mut lck_spin_t) {
    lck_mtx_unlock(ptr::addr_of_mut!((*lock).xnu_sys_interlock));
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_lock_grp(lock: *mut lck_spin_t, _grp: *mut lck_grp_t) {
    lck_spin_lock(lock);
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_try_lock_grp(
    lock: *mut lck_spin_t,
    _grp: *mut lck_grp_t,
) -> boolean_t {
    lck_spin_try_lock(lock)
}

// ---------------------------------------------------------------------------------------
// waitq lock, and the usimple lock it is built on
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn waitq_lock_init(wq: *mut waitq) {
    usimple_lock_init(xnu_sys_rs_waitq_interlock(wq), 0);
}

#[no_mangle]
pub unsafe extern "C" fn waitq_lock(wq: *mut waitq) {
    usimple_lock(xnu_sys_rs_waitq_interlock(wq), ptr::null_mut());
}

#[no_mangle]
pub unsafe extern "C" fn waitq_unlock(wq: *mut waitq) {
    usimple_unlock(xnu_sys_rs_waitq_interlock(wq));
}

#[no_mangle]
pub unsafe extern "C" fn waitq_lock_try(wq: *mut waitq) -> c_uint {
    usimple_lock_try(xnu_sys_rs_waitq_interlock(wq), ptr::null_mut())
}

/// A usimple_lock is a lck_spin_t with one field, so the interlock is at offset zero and the
/// pointer is reinterpreted rather than walked.
#[inline]
unsafe fn usimple_interlock(lock: *mut c_void) -> *mut lck_spin_t {
    lock as *mut lck_spin_t
}

#[no_mangle]
pub unsafe extern "C" fn usimple_lock(lock: *mut c_void, _grp: *mut lck_grp_t) {
    lck_spin_lock(usimple_interlock(lock));
}

#[no_mangle]
pub unsafe extern "C" fn usimple_lock_init(lock: *mut c_void, _tag: c_ushort) {
    lck_spin_init(usimple_interlock(lock), ptr::null_mut(), ptr::null_mut());
}

#[no_mangle]
pub unsafe extern "C" fn usimple_unlock(lock: *mut c_void) {
    lck_spin_unlock(usimple_interlock(lock));
}

#[no_mangle]
pub unsafe extern "C" fn usimple_lock_try(lock: *mut c_void, _grp: *mut lck_grp_t) -> c_uint {
    lck_spin_try_lock(usimple_interlock(lock)) as c_uint
}

use std::os::raw::c_ushort;

// ---------------------------------------------------------------------------------------
// ticket lock, also a spin lock
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn lck_ticket_init(tlock: *mut lck_ticket_t, _grp: *mut lck_grp_t) {
    lck_spin_init(tlock as *mut lck_spin_t, ptr::null_mut(), ptr::null_mut());
}

#[no_mangle]
pub unsafe extern "C" fn lck_ticket_lock(tlock: *mut lck_ticket_t) {
    lck_spin_lock(tlock as *mut lck_spin_t);
}

#[no_mangle]
pub unsafe extern "C" fn lck_ticket_unlock(tlock: *mut lck_ticket_t) {
    lck_spin_unlock(tlock as *mut lck_spin_t);
}

#[no_mangle]
pub unsafe extern "C" fn lck_ticket_assert_owned(tlock: *mut lck_ticket_t) {
    lck_spin_assert(tlock as *mut lck_spin_t, LCK_ASSERT_OWNED);
}

// ---------------------------------------------------------------------------------------
// read-write locks, which xnu-sys does not implement
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn lck_rw_done(_lock: *mut lck_rw_t) -> lck_rw_type_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn lck_rw_lock_exclusive(_lock: *mut lck_rw_t) {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn lck_rw_clear_promotion(_thread: thread_t, _trace_obj: usize) {
    crate::xnu_sys_stub_safe!();
}

#[no_mangle]
pub unsafe extern "C" fn unslide_for_kdebug(_object: *mut c_void) -> usize {
    crate::xnu_sys_stub_safe!();
    0
}

// ---------------------------------------------------------------------------------------
// The sleep routines, copied from xnu://7195.141.2/osfmk/kern/locks.c
//
// KERNEL_DEBUG is absent rather than ported: it expands to do {} while (0) here.
// ---------------------------------------------------------------------------------------

/// The RW promotion bookkeeping both sleep routines do, which is identical in each and is the
/// only place this file reaches into struct thread.
#[inline]
unsafe fn rwlock_promote(thread: thread_t) {
    *xnu_sys_rs_thread_rwlock_count(thread as *mut crate::bindings::thread) += 1;
}

#[inline]
unsafe fn rwlock_demote(thread: thread_t, event: event_t) {
    let count = xnu_sys_rs_thread_rwlock_count(thread as *mut crate::bindings::thread);
    let was = *count;
    *count -= 1;
    // The C tests the value BEFORE the decrement against 1, so the field is zero afterwards.
    if was == 1 && (xnu_sys_rs_thread_sched_flags(thread as *mut crate::bindings::thread)
        & TH_SFLAG_RW_PROMOTED) != 0
    {
        lck_rw_clear_promotion(thread, unslide_for_kdebug(event as *mut c_void));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lck_spin_sleep_grp(
    lock: *mut lck_spin_t,
    lck_sleep_action: lck_sleep_action_t,
    event: event_t,
    interruptible: wait_interrupt_t,
    grp: *mut lck_grp_t,
) -> wait_result_t {
    if (lck_sleep_action & !(LCK_SLEEP_MASK as lck_sleep_action_t)) != 0 {
        fail(b"Invalid lock sleep action\0");
    }

    let mut res = assert_wait(event, interruptible);
    if res == THREAD_WAITING {
        lck_spin_unlock(lock);
        res = thread_block(None);
        if (lck_sleep_action & LCK_SLEEP_UNLOCK as lck_sleep_action_t) == 0 {
            lck_spin_lock_grp(lock, grp);
        }
    } else if (lck_sleep_action & LCK_SLEEP_UNLOCK as lck_sleep_action_t) != 0 {
        lck_spin_unlock(lock);
    }

    res
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_sleep(
    lck: *mut lck_mtx_t,
    lck_sleep_action: lck_sleep_action_t,
    event: event_t,
    interruptible: wait_interrupt_t,
) -> wait_result_t {
    let thread = current_thread();

    if (lck_sleep_action & !(LCK_SLEEP_MASK as lck_sleep_action_t)) != 0 {
        fail(b"Invalid lock sleep action\0");
    }

    // Overloading the RW promotion gives this thread a priority ceiling while it sleeps, so it
    // wakes runnable at a reasonable priority rather than at the back of the queue.
    if (lck_sleep_action & LCK_SLEEP_PROMOTED_PRI as lck_sleep_action_t) != 0 {
        rwlock_promote(thread);
    }

    let mut res = assert_wait(event, interruptible);
    if res == THREAD_WAITING {
        lck_mtx_unlock(lck);
        res = thread_block(None);
        if (lck_sleep_action & LCK_SLEEP_UNLOCK as lck_sleep_action_t) == 0 {
            if (lck_sleep_action & LCK_SLEEP_SPIN as lck_sleep_action_t) != 0 {
                lck_mtx_lock_spin(lck);
            } else if (lck_sleep_action & LCK_SLEEP_SPIN_ALWAYS as lck_sleep_action_t) != 0 {
                lck_mtx_lock_spin_always(lck);
            } else {
                lck_mtx_lock(lck);
            }
        }
    } else if (lck_sleep_action & LCK_SLEEP_UNLOCK as lck_sleep_action_t) != 0 {
        lck_mtx_unlock(lck);
    }

    if (lck_sleep_action & LCK_SLEEP_PROMOTED_PRI as lck_sleep_action_t) != 0 {
        rwlock_demote(thread, event);
    }

    res
}

#[no_mangle]
pub unsafe extern "C" fn lck_mtx_sleep_deadline(
    lck: *mut lck_mtx_t,
    lck_sleep_action: lck_sleep_action_t,
    event: event_t,
    interruptible: wait_interrupt_t,
    deadline: u64,
) -> wait_result_t {
    let thread = current_thread();

    if (lck_sleep_action & !(LCK_SLEEP_MASK as lck_sleep_action_t)) != 0 {
        fail(b"Invalid lock sleep action\0");
    }

    if (lck_sleep_action & LCK_SLEEP_PROMOTED_PRI as lck_sleep_action_t) != 0 {
        rwlock_promote(thread);
    }

    let mut res = assert_wait_deadline(event, interruptible, deadline);
    if res == THREAD_WAITING {
        lck_mtx_unlock(lck);
        res = thread_block(None);
        if (lck_sleep_action & LCK_SLEEP_UNLOCK as lck_sleep_action_t) == 0 {
            // NOTE: the deadline variant has no SPIN_ALWAYS arm in XNU, and that asymmetry is
            // upstream's rather than an omission here.
            if (lck_sleep_action & LCK_SLEEP_SPIN as lck_sleep_action_t) != 0 {
                lck_mtx_lock_spin(lck);
            } else {
                lck_mtx_lock(lck);
            }
        }
    } else if (lck_sleep_action & LCK_SLEEP_UNLOCK as lck_sleep_action_t) != 0 {
        lck_mtx_unlock(lck);
    }

    if (lck_sleep_action & LCK_SLEEP_PROMOTED_PRI as lck_sleep_action_t) != 0 {
        rwlock_demote(thread, event);
    }

    res
}

const MAX_COLLISION_COUNTS: usize = 32;
const MAX_COLLISION: usize = 8;

#[no_mangle]
pub static mut max_collision_count: [c_uint; MAX_COLLISION_COUNTS] = [0; MAX_COLLISION_COUNTS];

#[no_mangle]
pub static mut collision_backoffs: [u32; MAX_COLLISION] = [10, 50, 100, 200, 400, 600, 800, 1000];

/// Back off after a lock collision, for callers that used to call `simple_lock_pause`.
#[no_mangle]
pub unsafe extern "C" fn mutex_pause(collisions: u32) {
    let mut collisions = collisions as usize;

    if collisions >= MAX_COLLISION_COUNTS {
        collisions = MAX_COLLISION_COUNTS - 1;
    }
    max_collision_count[collisions] += 1;

    if collisions >= MAX_COLLISION {
        collisions = MAX_COLLISION - 1;
    }
    let back_off = collision_backoffs[collisions];

    let wait_result = assert_wait_timeout(
        mutex_pause as *const c_void as event_t,
        THREAD_UNINT,
        back_off,
        NSEC_PER_USEC,
    );
    debug_assert_eq!(wait_result, THREAD_WAITING);

    let wait_result = thread_block(None);
    debug_assert_eq!(wait_result, THREAD_TIMED_OUT);
}

/// Spin until the word at `address` stops being `current`.
///
/// The C has an LL/SC arm for architectures that have it; on x86 it compiles to the plain load,
/// which is what this is. `LOCK_PANIC_TIMEOUT` is `__DARLING__`-excluded upstream, so there is
/// no timeout arm to port.
const LOCK_SNOOP_SPINS: usize = 100;

#[no_mangle]
pub unsafe extern "C" fn hw_wait_while_equals(
    address: *mut *mut c_void,
    current: *mut c_void,
) -> *mut c_void {
    loop {
        for _ in 0..LOCK_SNOOP_SPINS {
            std::hint::spin_loop();
            let v = ptr::read_volatile(address);
            if v != current {
                return v;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The sleep-action mask must cover every flag this file tests, or a valid action would be
    /// rejected as invalid and panic the kernel.
    #[test]
    fn the_sleep_mask_covers_every_action_used() {
        for flag in [
            LCK_SLEEP_UNLOCK,
            LCK_SLEEP_SPIN,
            LCK_SLEEP_SPIN_ALWAYS,
            LCK_SLEEP_PROMOTED_PRI,
        ] {
            assert_eq!(flag & !LCK_SLEEP_MASK, 0, "flag {flag} is outside LCK_SLEEP_MASK");
            assert_ne!(flag, 0);
        }
    }

    /// The backoff table is indexed by a collision count clamped to its length, so the two
    /// constants have to agree with the arrays they bound.
    #[test]
    fn the_collision_tables_match_their_bounds() {
        assert_eq!(unsafe { collision_backoffs.len() }, MAX_COLLISION);
        assert_eq!(unsafe { max_collision_count.len() }, MAX_COLLISION_COUNTS);
        assert!(MAX_COLLISION <= MAX_COLLISION_COUNTS);
        // Monotonic, which is what makes it a backoff rather than a table of noise.
        let table = unsafe { collision_backoffs };
        for i in 1..table.len() {
            assert!(table[i] > table[i - 1], "backoff table is not increasing at {i}");
        }
    }
}
