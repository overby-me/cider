//! psynch: the kernel-assisted POSIX synchronization primitives (pthread mutex / condition
//! variable / rwlock) that libpthread drives through the `__psynch_*` BSD syscalls. Any
//! multithreaded Darwin program with a contended lock ends up here.
//!
//! Each op is a thin call into duct-tape's hand-written `dtape_psynch_*` (psynch.c), which
//! forwards to the imported XNU pthread kext (`_psynch_*` / `ksyn_wait`). The wait ops
//! (mutexwait / cvwait / rw_rdlock / rw_wrlock) block by `thread_block_parameter` with a
//! continuation (kern_synch.c asserts the continuation is never NULL), so on a contended
//! lock the microthread suspends and its reply is deferred: the continuation
//! (`psynch_mtxcontinue` &c.) later sets the retval via the `current_thread_set_bsd_retval`
//! hook and calls `unix_syscall_return(error)`, which lands in the scheduler's
//! syscall_return path. The signal/drop ops (cvsignal / cvbroad / mutexdrop / rw_unlock /
//! cvclrprepost) are the wake side and return immediately.
//!
//! Every op returns an `int` errno (0 == success) and writes the u32 retval through a
//! pointer -- the same `retvalPointer` (a stable per-thread slot) the C++
//! `Call::<name>::processCall` passes; see the handler wiring in `handler.rs`. See
//! PLAN.md (the psynch bucket).

extern "C" {
    fn dtape_psynch_cvbroad(cv: u64, cvlsgen: u64, cvudgen: u64, flags: u32, mutex: u64, mugen: u64, tid: u64, retval: *mut u32) -> i32;
    fn dtape_psynch_cvclrprepost(cv: u64, cvgen: u32, cvugen: u32, cvsgen: u32, prepocnt: u32, preposeq: u32, flags: u32, retval: *mut u32) -> i32;
    fn dtape_psynch_cvsignal(cv: u64, cvlsgen: u64, cvugen: u32, threadport: i32, mutex: u64, mugen: u64, tid: u64, flags: u32, retval: *mut u32) -> i32;
    fn dtape_psynch_cvwait(cv: u64, cvlsgen: u64, cvugen: u32, mutex: u64, mugen: u64, flags: u32, sec: i64, nsec: u32, retval: *mut u32) -> i32;
    fn dtape_psynch_mutexdrop(mutex: u64, mgen: u32, ugen: u32, tid: u64, flags: u32, retval: *mut u32) -> i32;
    fn dtape_psynch_mutexwait(mutex: u64, mgen: u32, ugen: u32, tid: u64, flags: u32, retval: *mut u32) -> i32;
    fn dtape_psynch_rw_rdlock(rwlock: u64, lgenval: u32, ugenval: u32, rw_wc: u32, flags: i32, retval: *mut u32) -> i32;
    fn dtape_psynch_rw_unlock(rwlock: u64, lgenval: u32, ugenval: u32, rw_wc: u32, flags: i32, retval: *mut u32) -> i32;
    fn dtape_psynch_rw_wrlock(rwlock: u64, lgenval: u32, ugenval: u32, rw_wc: u32, flags: i32, retval: *mut u32) -> i32;
}

/// A pthread cond broadcast: wake every waiter on `cv`.
pub unsafe fn cvbroad(cv: u64, cvlsgen: u64, cvudgen: u64, flags: u32, mutex: u64, mugen: u64, tid: u64, retval: *mut u32) -> i32 {
    dtape_psynch_cvbroad(cv, cvlsgen, cvudgen, flags, mutex, mugen, tid, retval)
}
/// Clear a prepost on `cv` (bookkeeping for a signal that raced ahead of its wait).
pub unsafe fn cvclrprepost(cv: u64, cvgen: u32, cvugen: u32, cvsgen: u32, prepocnt: u32, preposeq: u32, flags: u32, retval: *mut u32) -> i32 {
    dtape_psynch_cvclrprepost(cv, cvgen, cvugen, cvsgen, prepocnt, preposeq, flags, retval)
}
/// A pthread cond signal: wake one waiter on `cv`.
pub unsafe fn cvsignal(cv: u64, cvlsgen: u64, cvugen: u32, threadport: i32, mutex: u64, mugen: u64, tid: u64, flags: u32, retval: *mut u32) -> i32 {
    dtape_psynch_cvsignal(cv, cvlsgen, cvugen, threadport, mutex, mugen, tid, flags, retval)
}
/// Wait on a pthread condition variable (drops `mutex`, may block via a continuation).
pub unsafe fn cvwait(cv: u64, cvlsgen: u64, cvugen: u32, mutex: u64, mugen: u64, flags: u32, sec: i64, nsec: u32, retval: *mut u32) -> i32 {
    dtape_psynch_cvwait(cv, cvlsgen, cvugen, mutex, mugen, flags, sec, nsec, retval)
}
/// Post a contended pthread mutex unlock (hands the lock to a waiter).
pub unsafe fn mutexdrop(mutex: u64, mgen: u32, ugen: u32, tid: u64, flags: u32, retval: *mut u32) -> i32 {
    dtape_psynch_mutexdrop(mutex, mgen, ugen, tid, flags, retval)
}
/// Wait for a contended pthread mutex (may block via a continuation).
pub unsafe fn mutexwait(mutex: u64, mgen: u32, ugen: u32, tid: u64, flags: u32, retval: *mut u32) -> i32 {
    dtape_psynch_mutexwait(mutex, mgen, ugen, tid, flags, retval)
}
/// Acquire a contended pthread rwlock for reading (may block via a continuation).
pub unsafe fn rw_rdlock(rwlock: u64, lgenval: u32, ugenval: u32, rw_wc: u32, flags: i32, retval: *mut u32) -> i32 {
    dtape_psynch_rw_rdlock(rwlock, lgenval, ugenval, rw_wc, flags, retval)
}
/// Release a pthread rwlock (wakes any blocked writers/readers).
pub unsafe fn rw_unlock(rwlock: u64, lgenval: u32, ugenval: u32, rw_wc: u32, flags: i32, retval: *mut u32) -> i32 {
    dtape_psynch_rw_unlock(rwlock, lgenval, ugenval, rw_wc, flags, retval)
}
/// Acquire a contended pthread rwlock for writing (may block via a continuation).
pub unsafe fn rw_wrlock(rwlock: u64, lgenval: u32, ugenval: u32, rw_wc: u32, flags: i32, retval: *mut u32) -> i32 {
    dtape_psynch_rw_wrlock(rwlock, lgenval, ugenval, rw_wc, flags, retval)
}
