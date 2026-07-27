//! S2C (server-to-client) calls: the daemon asks the GUEST to perform a memory op (mmap /
//! munmap / mprotect) on its own behalf. XNU running in the daemon cannot mmap in the
//! guest's address space, so when it needs to (e.g. `mach_vm_allocate` on the guest task,
//! which is what `clang` trips during a nix build), it delegates to the guest via S2C.
//!
//! The mechanism for the common case (the guest thread is blocked in the very RPC that
//! triggered this, so it is sitting in `recvmsg` able to service an inbound message):
//!   1. Build a `dserver_s2c_call_mmap` (call_number 0x52cca11) and SEND it to the guest's
//!      socket -- the guest's `dserver_rpc_hooks_receive_message` handles S2C calls inline
//!      (does the mmap) and replies, then keeps waiting for its real RPC reply.
//!   2. Suspend this microthread and return to the daemon's main loop.
//!   3. The main loop receives the S2C reply datagram (also call_number 0x52cca11), routes
//!      it here by (pid,tid), and resumes the microthread.
//!   4. Read the reply's address/errno and return.
//!
//! This ports C++ `Thread::_mmap` / `_s2cPerform` for the `_activeCall && currentThread`
//! path (no S2C interrupt signal needed). See thread.cpp:1027-1187, rpc-supplement.h.

use crate::rpc_io::{self, PeerAddr};
use crate::sched;
use std::cell::RefCell;
use std::collections::HashMap;
use std::os::raw::{c_int, c_void};
use std::os::unix::io::RawFd;

/// Magic call number for S2C messages (dserver_callnum_s2c). Both the daemon's S2C call and
/// the guest's S2C reply carry it.
pub const S2C_CALLNUM: i32 = 0x52cca11;
/// dserver_s2c_msgnum enum (invalid=0, then these). rpc-supplement.h:147.
pub const S2C_MSGNUM_MMAP: i32 = 1;
pub const S2C_MSGNUM_MUNMAP: i32 = 2;
pub const S2C_MSGNUM_MPROTECT: i32 = 3;
pub const S2C_MSGNUM_MSYNC: i32 = 4;

#[repr(C)]
#[derive(Clone, Copy)]
struct S2CCallhdr {
    call_number: i32,
    s2c_number: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct S2CCallMmap {
    header: S2CCallhdr,
    address: u64,
    length: u64,
    protection: i32,
    flags: i32,
    fd: i32,
    offset: i64,
}

/// The reply header the guest sends back (wider than the call header: it carries pid/tid so
/// the daemon can route the reply to the right waiting thread).
#[repr(C)]
#[derive(Clone, Copy)]
struct S2CReplyhdr {
    call_number: i32,
    pid: i32,
    tid: i32,
    architecture: i32,
    s2c_number: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct S2CReplyMmap {
    header: S2CReplyhdr,
    address: u64,
    errno_result: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct S2CCallMunmap {
    header: S2CCallhdr,
    address: u64,
    length: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct S2CCallMprotect {
    header: S2CCallhdr,
    address: u64,
    length: u64,
    protection: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct S2CCallMsync {
    header: S2CCallhdr,
    address: u64,
    size: u64,
    sync_flags: i32,
}

/// The shared reply for munmap/mprotect/msync: {replyhdr, return_value, errno_result}.
#[repr(C)]
#[derive(Clone, Copy)]
struct S2CReplyRc {
    header: S2CReplyhdr,
    return_value: i32,
    errno_result: i32,
}

thread_local! {
    /// The daemon's RPC socket fd (S2C calls are sent from it; the guest replies to it).
    static LISTENER_FD: RefCell<RawFd> = const { RefCell::new(-1) };
    /// The (nsid,tid,peer) of the RPC currently being dispatched -- set by the main loop
    /// before each dispatch, so an S2C op mid-dispatch knows which guest socket to send to.
    static CURRENT: RefCell<Option<(u32, u64, PeerAddr)>> = const { RefCell::new(None) };
    /// S2C replies the main loop has delivered, keyed by (nsid,tid), awaiting the suspended
    /// microthread that will read them on resume.
    static REPLIES: RefCell<HashMap<(u32, u64), Vec<u8>>> = RefCell::new(HashMap::new());
}

/// Record the daemon socket fd once at startup.
pub fn set_listener_fd(fd: RawFd) {
    LISTENER_FD.with(|f| *f.borrow_mut() = fd);
}

/// Set the guest whose RPC is about to be dispatched (so an S2C op it triggers can reach it).
pub fn set_current(nsid: u32, tid: u64, peer: PeerAddr) {
    CURRENT.with(|c| *c.borrow_mut() = Some((nsid, tid, peer)));
}

/// True if `number` is the S2C magic call number (an S2C reply from the guest).
pub fn is_s2c(number: u32) -> bool {
    number as i32 == S2C_CALLNUM
}

/// Route an S2C reply datagram from the guest to the microthread waiting for it. Parses the
/// (pid,tid) from the reply header. Returns the (nsid,tid) to wake, or None if unparseable.
pub fn deliver_reply(bytes: Vec<u8>) -> Option<(u32, u64)> {
    if bytes.len() < std::mem::size_of::<S2CReplyhdr>() {
        return None;
    }
    let hdr: S2CReplyhdr = unsafe { std::ptr::read_unaligned(bytes.as_ptr() as *const _) };
    let key = (hdr.pid as u32, hdr.tid as u64);
    REPLIES.with(|r| r.borrow_mut().insert(key, bytes));
    Some(key)
}

/// Send an S2C call to the current guest thread, suspend until it replies, and return the
/// reply bytes (None on error or a short reply). Shared by all S2C VM ops. Runs on the guest
/// thread's own microthread (mid-RPC), so the guest is blocked in recvmsg and services the
/// S2C inline; control returns to the daemon main loop while suspended, which receives the
/// reply datagram, routes it by (pid,tid), and reschedules this microthread.
unsafe fn perform_raw(call_bytes: &[u8], min_reply: usize) -> Option<Vec<u8>> {
    let (nsid, tid, peer) = CURRENT.with(|c| c.borrow().clone())?;
    let listener = LISTENER_FD.with(|f| *f.borrow());
    if listener < 0 {
        return None;
    }
    REPLIES.with(|r| r.borrow_mut().remove(&(nsid, tid)));
    if rpc_io::send_datagram(listener, call_bytes, &[], &peer).is_err() {
        return None;
    }
    sched::suspend_current(None, std::ptr::null_mut(), std::ptr::null_mut());
    match REPLIES.with(|r| r.borrow_mut().remove(&(nsid, tid))) {
        Some(b) if b.len() >= min_reply => Some(b),
        _ => None,
    }
}

/// Perform an S2C mmap on the current guest thread. Returns (address, errno); address ==
/// usize::MAX (MAP_FAILED) on error.
pub unsafe fn perform_mmap(address: usize, length: usize, protection: i32, flags: i32, fd: i32, offset: i64) -> (usize, i32) {
    let call = S2CCallMmap {
        header: S2CCallhdr { call_number: S2C_CALLNUM, s2c_number: S2C_MSGNUM_MMAP },
        address: address as u64,
        length: length as u64,
        protection,
        flags,
        fd,
        offset,
    };
    let bytes = std::slice::from_raw_parts(&call as *const _ as *const u8, std::mem::size_of::<S2CCallMmap>());
    match perform_raw(bytes, std::mem::size_of::<S2CReplyMmap>()) {
        Some(b) => {
            let reply: S2CReplyMmap = std::ptr::read_unaligned(b.as_ptr() as *const _);
            (reply.address as usize, reply.errno_result)
        }
        None => (usize::MAX, libc::EIO),
    }
}

/// Perform an S2C munmap. Returns (return_value, errno); return_value == 0 on success.
pub unsafe fn perform_munmap(address: usize, length: usize) -> (i32, i32) {
    let call = S2CCallMunmap {
        header: S2CCallhdr { call_number: S2C_CALLNUM, s2c_number: S2C_MSGNUM_MUNMAP },
        address: address as u64,
        length: length as u64,
    };
    let bytes = std::slice::from_raw_parts(&call as *const _ as *const u8, std::mem::size_of::<S2CCallMunmap>());
    match perform_raw(bytes, std::mem::size_of::<S2CReplyRc>()) {
        Some(b) => { let r: S2CReplyRc = std::ptr::read_unaligned(b.as_ptr() as *const _); (r.return_value, r.errno_result) }
        None => (-1, libc::EIO),
    }
}

/// Perform an S2C mprotect. Returns (return_value, errno); return_value == 0 on success.
pub unsafe fn perform_mprotect(address: usize, length: usize, protection: i32) -> (i32, i32) {
    let call = S2CCallMprotect {
        header: S2CCallhdr { call_number: S2C_CALLNUM, s2c_number: S2C_MSGNUM_MPROTECT },
        address: address as u64,
        length: length as u64,
        protection,
    };
    let bytes = std::slice::from_raw_parts(&call as *const _ as *const u8, std::mem::size_of::<S2CCallMprotect>());
    match perform_raw(bytes, std::mem::size_of::<S2CReplyRc>()) {
        Some(b) => { let r: S2CReplyRc = std::ptr::read_unaligned(b.as_ptr() as *const _); (r.return_value, r.errno_result) }
        None => (-1, libc::EIO),
    }
}

/// Perform an S2C msync. Returns (return_value, errno); return_value == 0 on success.
pub unsafe fn perform_msync(address: usize, size: usize, sync_flags: i32) -> (i32, i32) {
    let call = S2CCallMsync {
        header: S2CCallhdr { call_number: S2C_CALLNUM, s2c_number: S2C_MSGNUM_MSYNC },
        address: address as u64,
        size: size as u64,
        sync_flags,
    };
    let bytes = std::slice::from_raw_parts(&call as *const _ as *const u8, std::mem::size_of::<S2CCallMsync>());
    match perform_raw(bytes, std::mem::size_of::<S2CReplyRc>()) {
        Some(b) => { let r: S2CReplyRc = std::ptr::read_unaligned(b.as_ptr() as *const _); (r.return_value, r.errno_result) }
        None => (-1, libc::EIO),
    }
}

/// The mmap flags XNU's allocate_pages wants: private anonymous, plus MAP_FIXED[_NOREPLACE]
/// when the allocation is at a fixed address. Mirrors Thread::allocatePages (thread.cpp:1272).
pub fn mmap_flags(fixed: bool, overwrite: bool) -> i32 {
    let mut flags = libc::MAP_PRIVATE | libc::MAP_ANONYMOUS;
    if fixed && overwrite {
        flags |= libc::MAP_FIXED;
    } else if fixed {
        // MAP_FIXED_NOREPLACE (0x100000 on Linux); libc may not expose it by name here.
        flags |= 0x100000;
    }
    flags
}

/// Unused helper kept to document the c_void/c_int imports used by the extern-facing shims.
#[allow(dead_code)]
fn _types(_a: *mut c_void, _b: c_int) {}
