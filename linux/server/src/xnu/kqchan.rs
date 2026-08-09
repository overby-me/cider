//! Mach-port kqueue channels: the Rust replacement for `xnu-sys/src/kqchan.c`
//! (#71, ninth file).
//!
//! A kqchan is how the guest watches a Mach port through kqueue. The daemon creates one per
//! watched port, XNU's `filt_machport*` filter does the real work, and a dedicated kernel
//! microthread blocks on the port's waitq so an arriving message can be turned into a
//! notification callback.
//!
//! THE PART THAT IS EASY TO GET WRONG is the shutdown handshake in `knote_unlink_waitq`, and
//! it is preserved exactly. Clearing `waitq` is what tells the waiter microthread to stop;
//! `clear_wait(THREAD_INTERRUPTED)` is what wakes it if it is already blocked; and then the
//! caller BLOCKS on a death semaphore before freeing anything, so the waiter cannot still be
//! running inside a structure that is about to go away.
//!
//! WHAT THIS FILE COST TO REACH, because almost nothing it touches is directly bindable:
//! `kn_id`, `kn_flags`, `kn_filter`, `kn_udata`, `kn_sfflags`, `kn_sdata` and `kn_ext` are all
//! macro ALIASES into `kn_kevent` (`kn_kevent.kei_ident` and so on), the same shape as
//! `imq_msgcount` in `debug.rs`; `kn_status` is a BITFIELD whose enum had to be constified
//! because the C does `kn_status |= KN_VANISHED`; `kn_mqueue` lives in an anonymous union; and
//! `task_reference`, `os_ref_init`, `os_ref_release`, `imq_is_set` and `IPC_MQUEUE_RECEIVE`
//! are macros or inlines with no symbol, so they are C shims.
//!
//! `IPC_MQUEUE_RECEIVE` deserves its own note: it is an event ADDRESS rather than a small
//! integer, so unlike the other constants it cannot be an enumerator and comes back through a
//! shim that returns its value.

use std::mem::offset_of;
use std::os::raw::{c_int, c_long, c_void};
use std::ptr;

use crate::bindings::{
    clear_wait, dserver_kqchan_reply_mach_port_read_t, dtape_kqchan_mach_port_notification_callback_f,
    dtape_kqchan_mach_port_t, dtape_rs_imq_is_set, dtape_rs_ipc_mqueue_receive_event,
    dtape_rs_os_ref_init, dtape_rs_os_ref_release, dtape_rs_task_reference, dtape_task_t,
    ipc_mqueue_peek, ipc_mqueue_set_peek, kernel_thread_start, klist, knote,
    kn_status_t, task_deallocate, thread_deallocate, thread_t, thread_terminate_self, waitq,
    waitq_assert_wait64, wait_result_t, EVFILT_MACHPORT, EV_DISPATCH2, EV_ERROR, EV_ONESHOT,
    EV_VANISHED, FILTER_ACTIVE,
};

use crate::bindings::{
    dtape_rs_host_consts_DTAPE_RS_KN_VANISHED as KN_VANISHED_C,
    dtape_rs_host_consts_DTAPE_RS_THREAD_INTERRUPTED as THREAD_INTERRUPTED,
    dtape_rs_host_consts_DTAPE_RS_THREAD_INTERRUPTIBLE as THREAD_INTERRUPTIBLE,
};

extern "C" {
    // XNU's Mach-port filter. kqchan.c declares these itself, at the top of the file, for the
    // same reason: they live in a translation unit with no header.
    fn filt_machportattach(kn: *mut knote, kev: *mut c_void) -> c_int;
    fn filt_machportdetach(kn: *mut knote);
    fn filt_machporttouch(kn: *mut knote, kev: *mut c_void) -> c_int;
    fn filt_machportprocess(kn: *mut knote, kev: *mut c_void) -> c_int;
    fn filt_machportpeek(kn: *mut knote) -> c_int;

    fn panic(format: *const std::os::raw::c_char, ...);
    fn dtape_log(level: c_int, format: *const std::os::raw::c_char, ...);

    /// NOT allowlisted as a binding: several daemon modules do `use crate::bindings::*` and
    /// have their own parameter called kernel_task, which a bound static would shadow.
    static mut kernel_task: crate::bindings::task_t;
}

const DTAPE_LOG_LEVEL_DEBUG: c_int = 0;
const DTAPE_LOG_LEVEL_WARNING: c_int = 2;
const THREAD_WAITING: wait_result_t = -1;

fn log_at(level: c_int, what: &str) {
    let mut buf = Vec::with_capacity(what.len() + 1);
    buf.extend_from_slice(what.as_bytes());
    buf.push(0);
    unsafe { dtape_log(level, buf.as_ptr() as *const _) }
}

unsafe fn fail(message: &[u8]) -> ! {
    panic(message.as_ptr() as *const _);
    std::process::abort()
}

// --- the SLIST macros this file uses, on klist / knote.kn_selnext ---
//
// Same treatment as the TAILQ set in condvar.rs: written out once rather than shimmed, because
// they are pointer arithmetic Rust expresses directly and a shim would hide it.

/// `SLIST_INIT`.
#[inline]
unsafe fn slist_init(list: *mut klist) {
    (*list).slh_first = ptr::null_mut();
}

/// `SLIST_EMPTY`.
#[inline]
unsafe fn slist_empty(list: *mut klist) -> bool {
    (*list).slh_first.is_null()
}

/// `SLIST_INSERT_HEAD`.
#[inline]
unsafe fn slist_insert_head(list: *mut klist, elm: *mut knote) {
    (*elm).kn_selnext.sle_next = (*list).slh_first;
    (*list).slh_first = elm;
}

/// `SLIST_REMOVE`. A singly linked list has no back pointer, so removal walks from the head,
/// which is what the C macro does too.
#[inline]
unsafe fn slist_remove(list: *mut klist, elm: *mut knote) {
    if (*list).slh_first == elm {
        (*list).slh_first = (*elm).kn_selnext.sle_next;
        return;
    }
    let mut cur = (*list).slh_first;
    while !cur.is_null() {
        let next = (*cur).kn_selnext.sle_next;
        if next == elm {
            (*cur).kn_selnext.sle_next = (*elm).kn_selnext.sle_next;
            return;
        }
        cur = next;
    }
}

// --- the knote field aliases, which XNU spells as macros into kn_kevent ---

#[inline]
unsafe fn kn_id(kn: *mut knote) -> u64 {
    (*kn).kn_kevent.kei_ident
}
#[inline]
unsafe fn kn_filter(kn: *mut knote) -> i8 {
    (*kn).kn_kevent.kei_filter
}
#[inline]
unsafe fn kn_flags(kn: *mut knote) -> u16 {
    (*kn).kn_kevent.kei_flags
}
#[inline]
unsafe fn kn_udata(kn: *mut knote) -> u64 {
    (*kn).kn_kevent.kei_udata
}
#[inline]
unsafe fn kn_mqueue(kn: *mut knote) -> *mut crate::bindings::ipc_mqueue {
    (*kn).__bindgen_anon_2.kn_mqueue
}

/// The kqchan a knote is embedded in: `__container_of(kn, dtape_kqchan_mach_port_t, knote)`.
#[inline]
unsafe fn kqchan_for_knote(kn: *mut knote) -> *mut dtape_kqchan_mach_port_t {
    (kn as *mut u8).sub(offset_of!(crate::bindings::dtape_kqchan_mach_port, knote))
        as *mut dtape_kqchan_mach_port_t
}

// ---------------------------------------------------------------------------------------

/// Create a channel watching `port`, attaching XNU's Mach-port filter to it.
#[no_mangle]
pub unsafe extern "C" fn dtape_kqchan_mach_port_create(
    owning_task: *mut dtape_task_t,
    port: u32,
    receive_buffer: u64,
    receive_buffer_size: u64,
    saved_filter_flags: u64,
    notification_callback: dtape_kqchan_mach_port_notification_callback_f,
    context: *mut c_void,
) -> *mut dtape_kqchan_mach_port_t {
    let kqchan = libc::malloc(std::mem::size_of::<dtape_kqchan_mach_port_t>())
        as *mut dtape_kqchan_mach_port_t;
    if kqchan.is_null() {
        return ptr::null_mut();
    }
    ptr::write_bytes(kqchan as *mut u8, 0, std::mem::size_of::<dtape_kqchan_mach_port_t>());

    (*kqchan).callback = notification_callback;
    (*kqchan).context = context;
    (*kqchan).task = owning_task;

    // Hold a reference to the task for as long as the channel exists.
    dtape_rs_task_reference(ptr::addr_of_mut!((*(*kqchan).task).xnu_task));

    dtape_rs_os_ref_init(ptr::addr_of_mut!((*kqchan).refcount) as *mut _);

    let kn = ptr::addr_of_mut!((*kqchan).knote);
    (*kn).kn_kevent.kei_ident = port as u64;
    (*kn).kn_kevent.kei_ext[0] = receive_buffer;
    (*kn).kn_kevent.kei_ext[1] = receive_buffer_size;
    (*kn).kn_kevent.kei_sfflags = saved_filter_flags as u32;
    (*kn).kn_kevent.kei_filter = EVFILT_MACHPORT as i8;

    filt_machportattach(kn, ptr::null_mut());

    if (kn_flags(kn) & EV_ERROR as u16) != 0 {
        libc::free(kqchan as *mut c_void);
        return ptr::null_mut();
    }

    kqchan
}

#[no_mangle]
pub unsafe extern "C" fn dtape_kqchan_mach_port_destroy(kqchan: *mut dtape_kqchan_mach_port_t) {
    if dtape_rs_os_ref_release(ptr::addr_of_mut!((*kqchan).refcount) as *mut _) != 0 {
        fail(b"Duct-taped Mach port kqchan over-retained or still in-use at destruction\0");
    }

    filt_machportdetach(ptr::addr_of_mut!((*kqchan).knote));

    task_deallocate(ptr::addr_of_mut!((*(*kqchan).task).xnu_task));

    libc::free(kqchan as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn dtape_kqchan_mach_port_modify(
    kqchan: *mut dtape_kqchan_mach_port_t,
    receive_buffer: u64,
    receive_buffer_size: u64,
    saved_filter_flags: u64,
) {
    let mut kev: crate::bindings::kevent_qos_s = std::mem::zeroed();
    kev.fflags = saved_filter_flags as u32;
    kev.ext[0] = receive_buffer;
    kev.ext[1] = receive_buffer_size;
    filt_machporttouch(ptr::addr_of_mut!((*kqchan).knote), &mut kev as *mut _ as *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn dtape_kqchan_mach_port_disable_notifications(
    kqchan: *mut dtape_kqchan_mach_port_t,
) {
    (*kqchan).callback = None;
    (*kqchan).context = ptr::null_mut();
}

/// Turn whatever is pending into a reply, or report that there was nothing.
#[no_mangle]
pub unsafe extern "C" fn dtape_kqchan_mach_port_fill(
    kqchan: *mut dtape_kqchan_mach_port_t,
    reply: *mut dserver_kqchan_reply_mach_port_read_t,
    default_buffer: u64,
    default_buffer_size: u64,
) -> bool {
    let xthread = crate::bindings::current_thread();
    let thread = crate::xnu::condvar::thread_for_xnu_thread(xthread);

    (*thread).kevent_ctx.kec_data_out = default_buffer;
    (*thread).kevent_ctx.kec_data_avail = default_buffer;
    (*thread).kevent_ctx.kec_data_size = default_buffer_size;
    (*thread).kevent_ctx.kec_data_resid = default_buffer_size;
    (*thread).kevent_ctx.kec_process_flags = 0;

    let kn = ptr::addr_of_mut!((*kqchan).knote);

    if ((*kn).kn_status() & KN_VANISHED_C as kn_status_t) != 0 {
        // The port died under us, so synthesise the vanish event the guest expects rather than
        // asking the filter, which no longer has anything to report.
        ptr::write_bytes(ptr::addr_of_mut!((*reply).kev) as *mut u8, 0,
                         std::mem::size_of_val(&(*reply).kev));
        (*reply).kev.filter = kn_filter(kn) as i16;
        (*reply).kev.ident = kn_id(kn);
        (*reply).kev.flags = (EV_DISPATCH2 | EV_ONESHOT | EV_VANISHED) as u16;
        (*reply).kev.udata = kn_udata(kn);
        return true;
    }

    let result = (filt_machportprocess(kn, ptr::addr_of_mut!((*reply).kev) as *mut c_void)
        & FILTER_ACTIVE as c_int)
        != 0;

    if !(*kqchan).waiter_read_semaphore.is_null() {
        crate::xnu::semaphore::dtape_semaphore_up((*kqchan).waiter_read_semaphore);
    }

    result
}

#[no_mangle]
pub unsafe extern "C" fn dtape_kqchan_mach_port_has_events(
    kqchan: *mut dtape_kqchan_mach_port_t,
) -> bool {
    let mq = kn_mqueue(ptr::addr_of_mut!((*kqchan).knote));
    if dtape_rs_imq_is_set(mq) != 0 {
        ipc_mqueue_set_peek(mq) != 0
    } else {
        ipc_mqueue_peek(mq, ptr::null_mut(), ptr::null_mut(), ptr::null_mut(),
                        ptr::null_mut(), ptr::null_mut()) != 0
    }
}

/// The per-thread kevent context, which lives in the duct-tape thread rather than XNU's.
#[no_mangle]
pub unsafe extern "C" fn kevent_get_context(xthread: thread_t) -> *mut crate::bindings::kevent_ctx_s {
    let thread = crate::xnu::condvar::thread_for_xnu_thread(xthread);
    ptr::addr_of_mut!((*thread).kevent_ctx)
}

/// Notify the owner of a knote that something happened.
unsafe fn knote_post(kn: *mut knote, _hint: c_long) {
    let kqchan = kqchan_for_knote(kn);
    if (*kqchan).callback.is_none() {
        return;
    }
    if let Some(cb) = (*kqchan).callback {
        cb((*kqchan).context);
    }
}

#[no_mangle]
pub unsafe extern "C" fn knote(list: *mut klist, hint: c_long) {
    let mut kn = (*list).slh_first;
    while !kn.is_null() {
        let next = (*kn).kn_selnext.sle_next;
        knote_post(kn, hint);
        kn = next;
    }
}

/// Mark every knote on the list as vanished and notify.
///
/// SLIST_FOREACH_SAFE in the C, and the SAFE matters: `knote_post` invokes a callback that can
/// remove the knote from this very list, so the successor is taken BEFORE the body runs.
#[no_mangle]
pub unsafe extern "C" fn knote_vanish(list: *mut klist, _make_active: bool) {
    log_at(DTAPE_LOG_LEVEL_DEBUG, "klist is vanishing");
    let mut kn = (*list).slh_first;
    while !kn.is_null() {
        let next = (*kn).kn_selnext.sle_next;
        // TODO: handle the old style of vanishing (EV_EOF | EV_ONESHOT), as the C notes.
        (*kn).set_kn_status((*kn).kn_status() | KN_VANISHED_C as kn_status_t);
        knote_post(kn, 0);
        kn = next;
    }
}

/// The microthread that blocks on the port's waitq so an arriving message becomes a callback.
///
/// NORETURN, and declared so. The C ends with `thread_terminate_self()` followed by
/// `__builtin_unreachable()`; a Rust function that let control fall out of a noreturn call is
/// the exact shape of the mldr-rs SIGILL recorded earlier in this project.
unsafe extern "C" fn kqchan_waitq_waiter_entry(context: *mut c_void, _wait_result: wait_result_t) -> ! {
    let kqchan = context as *mut dtape_kqchan_mach_port_t;

    loop {
        let wq = (*kqchan).waitq;
        if wq.is_null() {
            break;
        }

        let mut wait_result = waitq_assert_wait64(
            wq,
            dtape_rs_ipc_mqueue_receive_event(),
            THREAD_INTERRUPTIBLE as crate::bindings::wait_interrupt_t,
            0,
        );
        if wait_result == THREAD_WAITING {
            wait_result = crate::xnu::thread::thread_block(None);
        }

        if wait_result == THREAD_INTERRUPTED as wait_result_t {
            // A wakeup with THREAD_INTERRUPTED is the signal to die.
            break;
        }

        if (filt_machportpeek(ptr::addr_of_mut!((*kqchan).knote)) & FILTER_ACTIVE as c_int) != 0 {
            if let Some(cb) = (*kqchan).callback {
                cb((*kqchan).context);
            }
        }

        // Wait until the reader has taken it, or give up if interrupted.
        if !crate::xnu::semaphore::dtape_semaphore_down_simple((*kqchan).waiter_read_semaphore) {
            break;
        }
    }

    // The death semaphore is what stops the kqchan being freed while this is still running.
    crate::xnu::semaphore::dtape_semaphore_up((*kqchan).waiter_death_semaphore);

    thread_terminate_self();
    unreachable!("thread_terminate_self returned")
}

#[no_mangle]
pub unsafe extern "C" fn knote_link_waitq(
    kn: *mut knote,
    wq: *mut waitq,
    _reserved_link: *mut u64,
) -> c_int {
    let kqchan = kqchan_for_knote(kn);

    if !(*kqchan).waitq.is_null() {
        log_at(DTAPE_LOG_LEVEL_WARNING, "Attempt to link kqchan while it was already linked");
        return 1;
    }

    (*kqchan).waitq = wq;
    let ktask = crate::xnu::debug::dtape_task_for_xnu_task(kernel_task);
    (*kqchan).waiter_death_semaphore = crate::xnu::semaphore::dtape_semaphore_create(ktask, 0);
    (*kqchan).waiter_read_semaphore = crate::xnu::semaphore::dtape_semaphore_create(ktask, 0);

    if kernel_thread_start(
        Some(std::mem::transmute::<
            unsafe extern "C" fn(*mut c_void, wait_result_t) -> !,
            unsafe extern "C" fn(*mut c_void, c_int),
        >(kqchan_waitq_waiter_entry)),
        kqchan as *mut c_void,
        ptr::addr_of_mut!((*kqchan).waiter_thread),
    ) != crate::bindings::KERN_SUCCESS as c_int
    {
        return 1;
    }

    0
}

/// Unlink and shut the waiter microthread down, in an order that cannot race.
#[no_mangle]
pub unsafe extern "C" fn knote_unlink_waitq(kn: *mut knote, wq: *mut waitq) -> c_int {
    let kqchan = kqchan_for_knote(kn);

    if (*kqchan).waitq != wq {
        fail(b"Attempt to unlink kqchan from a waitq it was not linked to\0");
    }

    // Seen by the waiter if it is running: tells it to stop.
    (*kqchan).waitq = ptr::null_mut();

    // Seen by the waiter if it is BLOCKED: wakes it with the code that means die.
    clear_wait((*kqchan).waiter_thread, THREAD_INTERRUPTED as wait_result_t);

    thread_deallocate((*kqchan).waiter_thread);
    (*kqchan).waiter_thread = ptr::null_mut();

    // Block until it has actually died, so nothing below frees a structure it is still in.
    crate::xnu::semaphore::dtape_semaphore_down_simple((*kqchan).waiter_death_semaphore);

    crate::xnu::semaphore::dtape_semaphore_destroy((*kqchan).waiter_death_semaphore);
    (*kqchan).waiter_death_semaphore = ptr::null_mut();

    crate::xnu::semaphore::dtape_semaphore_destroy((*kqchan).waiter_read_semaphore);
    (*kqchan).waiter_read_semaphore = ptr::null_mut();

    0
}

#[no_mangle]
pub unsafe extern "C" fn knote_link_waitqset_lazy_alloc(_kn: *mut knote) {
    crate::dtape_stub!();
}

#[no_mangle]
pub unsafe extern "C" fn knote_link_waitqset_should_lazy_alloc(
    _kn: *mut knote,
) -> crate::bindings::boolean_t {
    crate::dtape_stub_safe!();
    0
}

#[no_mangle]
pub unsafe extern "C" fn kqueue_alloc_turnstile(_kq: *mut c_void) -> *mut c_void {
    crate::dtape_stub!();
    ptr::null_mut()
}

// ---------------------------------------------------------------------------------------
// Copied from xnu://7195.141.2/bsd/kern/kern_event.c
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn klist_init(list: *mut klist) {
    slist_init(list);
}

/// Fill a kevent from a knote, using the knote's own `kn_sdata`.
///
/// The C form is a single struct assignment through a cast, because `kevent_qos_s` and
/// `kevent_internal_s` are laid out to alias. The tests below assert that aliasing rather than
/// trusting it, which is what XNU's own `static_assert`s do.
#[no_mangle]
pub unsafe extern "C" fn knote_fill_kevent_with_sdata(
    kn: *mut knote,
    kev: *mut crate::bindings::kevent_qos_s,
) {
    ptr::copy_nonoverlapping(
        ptr::addr_of!((*kn).kn_kevent) as *const u8,
        kev as *mut u8,
        std::mem::size_of::<crate::bindings::kevent_qos_s>(),
    );
    // Fix the two places the two layouts disagree: xflags overlaps kn_sfflags and must be
    // zeroed, and the high bits of filter hold kn_filtid.
    (*kev).xflags = 0;
    (*kev).filter |= 0xff00u16 as i16;
    if (kn_flags(kn) & crate::bindings::EV_CLEAR as u16) != 0 {
        (*kn).kn_kevent.kei_fflags = 0;
    }
}

#[no_mangle]
pub unsafe extern "C" fn knote_fill_kevent(
    kn: *mut knote,
    kev: *mut crate::bindings::kevent_qos_s,
    data: i64,
) {
    knote_fill_kevent_with_sdata(kn, kev);
    (*kev).filter = kn_filter(kn) as i16;
    (*kev).data = data;
}

/// Attach a knote to a list. Returns true if it was the first.
#[no_mangle]
pub unsafe extern "C" fn knote_attach(list: *mut klist, kn: *mut knote) -> c_int {
    let was_empty = slist_empty(list) as c_int;
    slist_insert_head(list, kn);
    was_empty
}

/// Detach a knote from a list. Returns true if that was the last.
#[no_mangle]
pub unsafe extern "C" fn knote_detach(list: *mut klist, kn: *mut knote) -> c_int {
    slist_remove(list, kn);
    slist_empty(list) as c_int
}

#[no_mangle]
pub unsafe extern "C" fn knote_set_error(kn: *mut knote, error: c_int) {
    (*kn).kn_kevent.kei_flags |= EV_ERROR as u16;
    (*kn).kn_kevent.kei_sdata = error as i64;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bindings::{kevent_qos_s, knote_kevent_internal_s};

    /// XNU's own comment says these aliasings are programmatically asserted, and
    /// knote_fill_kevent_with_sdata copies one struct over the other on the strength of them.
    /// If they ever stop holding, that copy silently produces garbage rather than failing.
    #[test]
    fn kevent_qos_and_kevent_internal_alias() {
        assert_eq!(offset_of!(kevent_qos_s, ident), offset_of!(knote_kevent_internal_s, kei_ident));
        assert_eq!(offset_of!(kevent_qos_s, flags), offset_of!(knote_kevent_internal_s, kei_flags));
        assert_eq!(offset_of!(kevent_qos_s, qos), offset_of!(knote_kevent_internal_s, kei_qos));
        assert_eq!(offset_of!(kevent_qos_s, udata), offset_of!(knote_kevent_internal_s, kei_udata));
        assert_eq!(offset_of!(kevent_qos_s, fflags), offset_of!(knote_kevent_internal_s, kei_fflags));
        assert_eq!(offset_of!(kevent_qos_s, ext), offset_of!(knote_kevent_internal_s, kei_ext));
        // The two NON-trivial overlaps, which is where a layout change would bite first:
        // xflags sits on kei_sfflags and data sits on kei_sdata.
        assert_eq!(offset_of!(kevent_qos_s, xflags), offset_of!(knote_kevent_internal_s, kei_sfflags));
        assert_eq!(offset_of!(kevent_qos_s, data), offset_of!(knote_kevent_internal_s, kei_sdata));
        // filter overlaps kei_filter and kei_filtid, so the qos field must not be smaller.
        assert!(std::mem::size_of::<kevent_qos_s>() >= std::mem::size_of::<knote_kevent_internal_s>());
    }

    /// The singly linked list has no back pointer, so removal walks from the head. Removing the
    /// head, a middle element and the tail all have to leave a consistent list.
    #[test]
    fn slist_remove_handles_head_middle_and_tail() {
        unsafe {
            let mut list: klist = std::mem::zeroed();
            let mut a: knote = std::mem::zeroed();
            let mut b: knote = std::mem::zeroed();
            let mut c: knote = std::mem::zeroed();
            slist_init(&mut list);
            // insert_head, so the order becomes c, b, a
            slist_insert_head(&mut list, &mut a);
            slist_insert_head(&mut list, &mut b);
            slist_insert_head(&mut list, &mut c);
            assert!(!slist_empty(&mut list));

            slist_remove(&mut list, &mut b); // middle
            assert_eq!(list.slh_first, &mut c as *mut knote);
            assert_eq!(c.kn_selnext.sle_next, &mut a as *mut knote);

            slist_remove(&mut list, &mut c); // head
            assert_eq!(list.slh_first, &mut a as *mut knote);

            slist_remove(&mut list, &mut a); // last
            assert!(slist_empty(&mut list));
        }
    }
}
