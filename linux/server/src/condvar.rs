//! duct-tape condition variables: the Rust replacement for `duct-tape/src/condvar.c`
//! (#71, the second glue file ported).
//!
//! These are the condvars duct-taped XNU code blocks on, built on the microthread scheduler
//! rather than on pthreads: a waiter puts its own `mutex_link` on an intrusive queue and
//! suspends its microthread through `dtape_hooks->thread_suspend`, and a signaller pops
//! links and resumes them. Upstream calls its own implementation half-assed; this is a
//! faithful port of it, not a redesign.
//!
//! WHY THIS FILE WENT SECOND. Measured, not guessed. `scripts/duct-tape-portability.py`
//! reports two axes, and they disagree: by BLOCKERS (what Rust cannot express) `init.c`
//! looked next, but by FFI SURFACE, read off the compiled object, `init.c` is 4 exports and
//! FORTY calls out while this file is **3 exports and 7 calls out** -- the closest match to
//! `semaphore.c`, which was 5 and 7 and went through cleanly.
//!
//! WHAT HAD TO BE REWRITTEN RATHER THAN CALLED. Two helpers do not exist as symbols at all,
//! which is visible in `nm -u condvar.c.o`: they are absent from the undefined list because
//! the C inlines them.
//!   * `libsimple_lock_init` is a `static` one-liner (`lock->state = 0`).
//!   * `dtape_thread_for_xnu_thread` is `always_inline`: pointer arithmetic back from the
//!     embedded XNU thread to the duct-tape one.
//! The `TAILQ_*` macros are the same story one level up: bindgen binds no macros, so the
//! four used here are written out below. They are BSD intrusive-list pointer arithmetic, and
//! the subtle one is `tqe_prev`, which is a pointer TO THE PREVIOUS ELEMENT'S NEXT POINTER,
//! not to the previous element. Getting that backwards silently corrupts the queue instead
//! of failing, so it is spelled out rather than paraphrased.
//!
//! Every offset here comes from bindgen (`offset_of!`), never from a number written down.

use std::mem::offset_of;
use std::os::raw::c_void;
use std::ptr;

use crate::bindings::{
    dtape_condvar_t, dtape_hooks_t, dtape_mutex_link_t, dtape_mutex_t, dtape_thread,
    libsimple_lock_t, thread_t,
};

extern "C" {
    /// The hook vtable, still defined by the C `init.c`. Rust only READS it here, which is
    /// the easy direction; `init.c` moving to Rust is what would make this a Rust global.
    static dtape_hooks: *const dtape_hooks_t;

    fn libsimple_lock_lock(lock: *mut libsimple_lock_t);
    fn libsimple_lock_unlock(lock: *mut libsimple_lock_t);
}

// Rust since #71, so imported rather than declared (#75). libsimple above stays foreign.
use crate::dtape_thread::current_thread;
use crate::locks::{dtape_mutex_lock, dtape_mutex_unlock};

/// `libsimple_lock_init`, which is a `static` function in libsimple/lock.h and so has no
/// symbol to call.
#[inline]
pub(crate) unsafe fn lock_init(lock: *mut libsimple_lock_t) {
    (*lock).state = 0;
}

/// `dtape_thread_for_xnu_thread`: XNU's thread is EMBEDDED in the duct-tape one, so this
/// walks back by the field offset. `always_inline` in C, so there is no symbol for it.
#[inline]
pub(crate) unsafe fn thread_for_xnu_thread(xnu_thread: thread_t) -> *mut dtape_thread {
    if xnu_thread.is_null() {
        return ptr::null_mut();
    }
    (xnu_thread as *mut u8).sub(offset_of!(dtape_thread, xnu_thread)) as *mut dtape_thread
}

/// `__container_of(link, dtape_thread_t, mutex_link)`.
#[inline]
pub(crate) unsafe fn thread_for_mutex_link(link: *mut dtape_mutex_link_t) -> *mut dtape_thread {
    (link as *mut u8).sub(offset_of!(dtape_thread, mutex_link)) as *mut dtape_thread
}

// --- the four TAILQ macros this file uses (pub(crate): locks.rs needs the same four, on the
// same dtape_mutex_head_t, and duplicating intrusive-list arithmetic is how it goes wrong) ---
// --- originally: the four TAILQ macros this file uses, on dtape_mutex_head_t / dtape_mutex_link_t ---

/// `TAILQ_INIT`: empty list, and tqh_last points AT the head's own first-pointer, which is
/// what makes an insert into an empty list write through to tqh_first.
#[inline]
pub(crate) unsafe fn tailq_init(head: *mut crate::bindings::dtape_mutex_head_t) {
    (*head).tqh_first = ptr::null_mut();
    (*head).tqh_last = ptr::addr_of_mut!((*head).tqh_first);
}

/// `TAILQ_FIRST`.
#[inline]
pub(crate) unsafe fn tailq_first(head: *mut crate::bindings::dtape_mutex_head_t) -> *mut dtape_mutex_link_t {
    (*head).tqh_first
}

/// `TAILQ_INSERT_TAIL`.
#[inline]
pub(crate) unsafe fn tailq_insert_tail(
    head: *mut crate::bindings::dtape_mutex_head_t,
    elm: *mut dtape_mutex_link_t,
) {
    (*elm).link.tqe_next = ptr::null_mut();
    (*elm).link.tqe_prev = (*head).tqh_last;
    *(*head).tqh_last = elm;
    (*head).tqh_last = ptr::addr_of_mut!((*elm).link.tqe_next);
}

/// `TAILQ_REMOVE`. tqe_prev points at the PREVIOUS ELEMENT'S NEXT POINTER, so writing
/// through it is what unlinks; when there is no successor the head's tail pointer takes
/// this element's tqe_prev instead.
#[inline]
pub(crate) unsafe fn tailq_remove(
    head: *mut crate::bindings::dtape_mutex_head_t,
    elm: *mut dtape_mutex_link_t,
) {
    let next = (*elm).link.tqe_next;
    let prev = (*elm).link.tqe_prev;
    if !next.is_null() {
        (*next).link.tqe_prev = prev;
    } else {
        (*head).tqh_last = prev;
    }
    *prev = next;
}

/// Initialise `condvar`.
#[no_mangle]
pub unsafe extern "C" fn dtape_condvar_init(condvar: *mut dtape_condvar_t) {
    lock_init(ptr::addr_of_mut!((*condvar).queue_lock));
    tailq_init(ptr::addr_of_mut!((*condvar).queue_head));
}

/// Wake up to `count` waiters on `condvar`.
#[no_mangle]
pub unsafe extern "C" fn dtape_condvar_signal(condvar: *mut dtape_condvar_t, count: usize) {
    let mut remaining = count;
    let head = ptr::addr_of_mut!((*condvar).queue_head);

    libsimple_lock_lock(ptr::addr_of_mut!((*condvar).queue_lock));
    while remaining > 0 {
        let link = tailq_first(head);
        if link.is_null() {
            break;
        }

        tailq_remove(head, link);
        let thread = thread_for_mutex_link(link);
        if let Some(resume) = (*dtape_hooks).thread_resume {
            resume((*thread).context);
        }

        remaining -= 1;
    }
    libsimple_lock_unlock(ptr::addr_of_mut!((*condvar).queue_lock));
}

/// Wait on `condvar`, having dropped `mutex`, and reacquire it on wake-up.
#[no_mangle]
pub unsafe extern "C" fn dtape_condvar_wait(
    condvar: *mut dtape_condvar_t,
    mutex: *mut dtape_mutex_t,
) {
    let thread = thread_for_xnu_thread(current_thread());

    libsimple_lock_lock(ptr::addr_of_mut!((*condvar).queue_lock));

    // Dropping the mutex here is safe: we cannot be signalled until the queue lock goes,
    // and that only happens once we have actually suspended, so no wakeup can be missed.
    dtape_mutex_unlock(mutex);

    tailq_insert_tail(
        ptr::addr_of_mut!((*condvar).queue_head),
        ptr::addr_of_mut!((*thread).mutex_link),
    );

    // Suspending also drops the queue lock, which is why it is handed to the hook.
    if let Some(suspend) = (*dtape_hooks).thread_suspend {
        suspend(
            (*thread).context,
            None,
            ptr::null_mut(),
            ptr::addr_of_mut!((*condvar).queue_lock),
        );
    }

    // Awake again; take the mutex back.
    dtape_mutex_lock(mutex);
}

/// A wake-up must not be lost when the list is empty, and `tqe_prev` must be the address of
/// the predecessor's next-pointer. Both are the kind of thing that corrupts a queue quietly
/// rather than failing, so they are checked here rather than trusted.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::bindings::dtape_mutex_head_t;

    unsafe fn empty_head() -> Box<dtape_mutex_head_t> {
        let mut h: Box<dtape_mutex_head_t> = Box::new(std::mem::zeroed());
        tailq_init(&mut *h);
        h
    }

    #[test]
    fn insert_then_remove_returns_to_empty() {
        unsafe {
            let mut h = empty_head();
            assert!(tailq_first(&mut *h).is_null(), "fresh list must be empty");

            let mut a: dtape_mutex_link_t = std::mem::zeroed();
            tailq_insert_tail(&mut *h, &mut a);
            assert_eq!(tailq_first(&mut *h), &mut a as *mut _, "insert must be visible");

            tailq_remove(&mut *h, &mut a);
            assert!(tailq_first(&mut *h).is_null(), "removing the only element must empty it");
            // and the head must be reusable, which is what a wrong tqh_last would break
            let mut b: dtape_mutex_link_t = std::mem::zeroed();
            tailq_insert_tail(&mut *h, &mut b);
            assert_eq!(tailq_first(&mut *h), &mut b as *mut _);
        }
    }

    #[test]
    fn fifo_order_is_preserved() {
        unsafe {
            let mut h = empty_head();
            let mut a: dtape_mutex_link_t = std::mem::zeroed();
            let mut b: dtape_mutex_link_t = std::mem::zeroed();
            let mut c: dtape_mutex_link_t = std::mem::zeroed();
            tailq_insert_tail(&mut *h, &mut a);
            tailq_insert_tail(&mut *h, &mut b);
            tailq_insert_tail(&mut *h, &mut c);

            // signal() pops from the front, so the first waiter in is the first woken
            for expect in [&mut a as *mut _, &mut b as *mut _, &mut c as *mut _] {
                let got = tailq_first(&mut *h);
                assert_eq!(got, expect, "queue must be FIFO");
                tailq_remove(&mut *h, got);
            }
            assert!(tailq_first(&mut *h).is_null());
        }
    }

    #[test]
    fn removing_from_the_middle_relinks_both_sides() {
        unsafe {
            let mut h = empty_head();
            let mut a: dtape_mutex_link_t = std::mem::zeroed();
            let mut b: dtape_mutex_link_t = std::mem::zeroed();
            let mut c: dtape_mutex_link_t = std::mem::zeroed();
            tailq_insert_tail(&mut *h, &mut a);
            tailq_insert_tail(&mut *h, &mut b);
            tailq_insert_tail(&mut *h, &mut c);

            tailq_remove(&mut *h, &mut b);
            assert_eq!(tailq_first(&mut *h), &mut a as *mut _);
            assert_eq!(a.link.tqe_next, &mut c as *mut _, "a must now point past b");
            assert_eq!(c.link.tqe_prev, ptr::addr_of_mut!(a.link.tqe_next),
                       "c must point back at a next-pointer, not at a itself");
        }
    }
}
