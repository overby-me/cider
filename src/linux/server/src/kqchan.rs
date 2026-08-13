//! Process kqueue channels (EVFILT_PROC): the daemon side of the guest's
//! kqueue(EVFILT_PROC) waiters. A guest opens one via kqchan_proc_open to watch another
//! process; the daemon returns one end of a SEQPACKET socketpair and keeps the other.
//! Over it, the guest sends proc_modify (set the filter flags) and proc_read (fetch the
//! latest event), and the daemon pushes a `notification` message when a watched event
//! (e.g. the target's death -> NOTE_EXIT) occurs. Raw SEQPACKET framing (one struct per
//! message, no length prefix), matching ciderd's MessageQueue. Mirrors
//! DarlingServer::Kqchan::Process (kqchan.cpp). See docs/changelog.md (bucket B.8).

use crate::bindings::xnu_sys_task_t;
use crate::sched;
use std::collections::VecDeque;
use std::io;
use std::mem::size_of;
use std::os::fd::RawFd;
use std::os::raw::c_void;

// kqchan message numbers (rpc-supplement.h dserver_kqchan_msgnum).
const MSGNUM_NOTIFICATION: u32 = 1;
const MSGNUM_PROC_MODIFY: u32 = 4;
const MSGNUM_PROC_READ: u32 = 5;

/// EVFILT_PROC fflags we can report (bsd/sys/event.h).
pub const NOTE_EXIT: u32 = 0x8000_0000;
pub const NOTE_FORK: u32 = 0x4000_0000;

#[repr(C)]
#[derive(Clone, Copy)]
struct Callhdr {
    number: u32,
    pid: i32,
    tid: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Replyhdr {
    number: u32,
    code: i32,
}
#[repr(C)]
struct CallProcModify {
    header: Callhdr,
    flags: u32,
}
#[repr(C)]
struct ReplyProcModify {
    header: Replyhdr,
}
#[repr(C)]
struct ReplyProcRead {
    header: Replyhdr,
    fflags: u32,
    // (4 bytes padding here to 8-align `data`, matching the C struct)
    data: i64,
}
#[repr(C)]
struct Notification {
    header: Callhdr,
}

fn as_bytes<T>(v: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts(v as *const T as *const u8, size_of::<T>()) }
}

/// One process-watching kqueue channel.
pub struct ProcKqchan {
    /// Our end of the socketpair (nonblocking SEQPACKET).
    pub daemon_fd: RawFd,
    /// A pidfd for the watched process (readable when it dies), or -1 if unavailable. The
    /// daemon detects a grandchild guest process's death via this, not SIGCHLD (which only
    /// fires for its own direct child). Mirrors Process::_pidfd.
    pub pidfd: RawFd,
    /// The watched process's guest nsid.
    pub target_nsid: u32,
    /// The watched process's daemon-namespace pid.
    pub target_host_pid: libc::pid_t,
    /// The guest's requested filter flags (set via proc_modify).
    flags: u32,
    /// Queued (events, data) not yet read by the guest.
    events: VecDeque<(u32, i64)>,
    /// Whether we may send a fresh notification (throttled: one unacknowledged at a time).
    can_send_notification: bool,
}

impl ProcKqchan {
    /// Open a channel watching (`target_nsid`,`target_host_pid`) with initial `flags`.
    /// Returns the channel (holding the daemon end + a pidfd) and the guest end to hand back.
    pub fn open(target_nsid: u32, target_host_pid: libc::pid_t, flags: u32) -> io::Result<(ProcKqchan, RawFd)> {
        let mut fds = [0 as RawFd; 2];
        let rc = unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr()) };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        let (daemon_fd, guest_fd) = (fds[0], fds[1]);
        unsafe {
            let f = libc::fcntl(daemon_fd, libc::F_GETFL, 0);
            libc::fcntl(daemon_fd, libc::F_SETFL, f | libc::O_NONBLOCK);
        }
        // pidfd_open the target so its death becomes an epoll-able readable event.
        let pidfd = unsafe { libc::syscall(libc::SYS_pidfd_open, target_host_pid, 0) as RawFd };
        Ok((
            ProcKqchan {
                daemon_fd,
                pidfd,
                target_nsid,
                target_host_pid,
                flags,
                events: VecDeque::new(),
                can_send_notification: true,
            },
            guest_fd,
        ))
    }

    /// The watched process died: queue NOTE_EXIT and notify the guest. Mirrors
    /// Process::notifyDead -> _notifyListeningKqchannels(NOTE_EXIT, 0).
    pub fn on_target_died(&mut self) {
        self.notify(NOTE_EXIT, 0);
    }

    fn send(&self, bytes: &[u8]) {
        unsafe {
            libc::send(self.daemon_fd, bytes.as_ptr() as *const libc::c_void, bytes.len(), libc::MSG_DONTWAIT);
        }
    }

    /// Drain and handle all pending guest messages. Returns false if the guest closed its
    /// end (the channel should be removed).
    pub fn on_readable(&mut self) -> bool {
        let mut buf = [0u8; 256];
        loop {
            let n = unsafe { libc::recv(self.daemon_fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };
            if n == 0 {
                return false; // peer hung up
            }
            if n < 0 {
                // EAGAIN -> drained; anything else -> treat as closed
                let e = io::Error::last_os_error();
                return e.kind() == io::ErrorKind::WouldBlock;
            }
            let n = n as usize;
            if n < size_of::<Callhdr>() {
                continue;
            }
            let number = u32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]);
            match number {
                MSGNUM_PROC_MODIFY if n >= size_of::<CallProcModify>() => {
                    let call: CallProcModify = unsafe { std::ptr::read_unaligned(buf.as_ptr() as *const _) };
                    self.flags = call.flags;
                    let reply = ReplyProcModify { header: Replyhdr { number: MSGNUM_PROC_MODIFY, code: 0 } };
                    self.send(as_bytes(&reply));
                    // If we already have events, let the guest know it should read them.
                    if !self.events.is_empty() {
                        self.send_notification();
                    }
                }
                MSGNUM_PROC_READ => {
                    // The guest acknowledged our last notification by reading; we may notify again.
                    self.can_send_notification = true;
                    let mut reply: ReplyProcRead = unsafe { std::mem::zeroed() };
                    reply.header.number = MSGNUM_PROC_READ;
                    match self.next_matching_event() {
                        Some((events, data)) => {
                            reply.header.code = 0;
                            reply.fflags = events & self.flags;
                            reply.data = data;
                        }
                        None => {
                            // 0xdead: sentinel for "no events" (kqchan.cpp).
                            reply.header.code = 0xdead;
                        }
                    }
                    self.send(as_bytes(&reply));
                }
                _ => { /* unknown / mach-port msgnums: ignore for a proc channel */ }
            }
        }
    }

    /// Pop the next queued event that intersects the guest's filter flags.
    fn next_matching_event(&mut self) -> Option<(u32, i64)> {
        while let Some((events, data)) = self.events.pop_front() {
            if events & self.flags != 0 {
                return Some((events, data));
            }
        }
        None
    }

    /// Queue an event and notify the guest (throttled). Mirrors Kqchan::Process::_notify.
    pub fn notify(&mut self, event: u32, data: i64) {
        self.events.push_back((event, data));
        self.send_notification();
    }

    fn send_notification(&mut self) {
        if !self.can_send_notification {
            return;
        }
        let note = Notification { header: Callhdr { number: MSGNUM_NOTIFICATION, pid: 0, tid: 0 } };
        self.send(as_bytes(&note));
        self.can_send_notification = false;
    }
}

impl Drop for ProcKqchan {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.daemon_fd);
            if self.pidfd >= 0 {
                libc::close(self.pidfd);
            }
        }
    }
}

// ============================================================================
// Mach-port kqueue channel (EVFILT_MACHPORT) -- task #54, approach (b): event-driven.
// ============================================================================
// A guest kevent()s on a Mach port; the daemon watches it via the xnu-sys's XNU knote. When a
// message lands on the port, the xnu-sys fires our notification_callback (from inside the
// sender's mach_msg RPC, on the serve loop) -- no thread ever blocks waiting, so this fits the
// single-worker model. `modify` (register/change the filter) and `read` (drain pending messages
// via xnu_sys_kqchan_mach_port_fill) call xnu_sys functions that need a current-thread + the guest
// task's memory context, so they run on a microthread bound to the owning task (sched::run_on_task)
// -- the cooperative-yield replacement for C++'s impersonate + kernelAsync. Mirrors
// DarlingServer::Kqchan::MachPort (kqchan.cpp).

const MSGNUM_MACH_PORT_MODIFY: u32 = 2;
const MSGNUM_MACH_PORT_READ: u32 = 3;

#[repr(C)]
struct CallMachPortModify {
    header: Callhdr,
    receive_buffer: u64,
    receive_buffer_size: u64,
    saved_filter_flags: u64,
}
#[repr(C)]
struct ReplyMachPortModify {
    header: Replyhdr,
}
#[repr(C)]
struct CallMachPortRead {
    header: Callhdr,
    default_buffer: u64,
    default_buffer_size: u64,
}
// Imported rather than declared through the linker, now that kqchan is EXECUTED (#80) and the
// swap can be verified instead of assumed. This was the last of #75.
//
// THE TWO LOCAL TYPES THAT USED TO SIT HERE ARE GONE. kqchan.rs declared its own opaque
// XnuSysKqchanMachPort and its own ReplyMachPortRead, a hand-written mirror of a wire struct that
// xnu_sys_kqchan_mach_port_fill WRITES THROUGH, while the definitions take
// xnu_sys_kqchan_mach_port_t and dserver_kqchan_reply_mach_port_read_t. The mirror was compared
// field by field first (177732f6) and did not differ, so this is a swap and not a fix:
//
//   Kev against dserver_kqchan_reply_mach_port_read__bindgen_ty_1
//     ident u64, filter i16, flags u16, qos i32, udata u64, fflags u32, xflags u32, data i64,
//     ext [u64; 4]                                                            identical
//   Replyhdr against dserver_kqchan_replyhdr
//     number u32 against a re-exported #[repr(u32)] enum, code i32 against c_int   identical
//
// Replyhdr STAYS local, because ReplyProcModify and ReplyMachPortModify still use it. Only the
// two types the FFI boundary needed moved to the generated ones.
use crate::bindings;
use crate::bindings::{dserver_kqchan_reply_mach_port_read_t, xnu_sys_kqchan_mach_port_t};
use crate::xnu::kqchan::{
    xnu_sys_kqchan_mach_port_create, xnu_sys_kqchan_mach_port_destroy,
    xnu_sys_kqchan_mach_port_disable_notifications, xnu_sys_kqchan_mach_port_fill,
    xnu_sys_kqchan_mach_port_has_events, xnu_sys_kqchan_mach_port_modify,
};

/// Duct-tape notification callback: a message landed on the watched port. `context` is the
/// heap-stable MachPortKqchan address passed to create(). Fires on the serve loop (inside the
/// sender's RPC), with NO live borrow of the channel (modify/read never hold `&mut self` across
/// the microthread run), so poking it through the raw pointer here does not alias.
extern "C" fn mach_port_notify_cb(context: *mut c_void) {
    let kq = context as *mut MachPortKqchan;
    unsafe { (*kq).send_notification() };
}

/// One Mach-port-watching kqueue channel. Heap-boxed: its address is the xnu-sys callback's
/// context, so it must never move while the xnu_sys kqchan is alive (Drop disables notifications
/// first, so the callback can never fire into a freed box).
pub struct MachPortKqchan {
    /// Our end of the socketpair (nonblocking SEQPACKET); the guest sends modify/read here.
    pub daemon_fd: RawFd,
    /// The xnu-sys kqchan (XNU knote on the port); null only transiently during open().
    xnu_sys: *mut xnu_sys_kqchan_mach_port_t,
    /// The owning guest task -- modify/read run on a microthread bound to it.
    owning_task: *mut xnu_sys_task_t,
    /// Throttle: at most one unacknowledged notification outstanding (the guest acks by reading).
    can_send_notification: bool,
}

impl MachPortKqchan {
    /// Open a channel watching `port` on `owning_task`. Returns the boxed daemon-side channel and
    /// the guest end to hand back over SCM_RIGHTS. Mirrors Kqchan::MachPort::MachPort + setup().
    pub fn open(
        owning_task: *mut xnu_sys_task_t,
        port: u32,
        receive_buffer: u64,
        receive_buffer_size: u64,
        saved_filter_flags: u64,
    ) -> io::Result<(Box<MachPortKqchan>, RawFd)> {
        let mut fds = [0 as RawFd; 2];
        let rc = unsafe {
            libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr())
        };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        let (daemon_fd, guest_fd) = (fds[0], fds[1]);
        unsafe {
            let f = libc::fcntl(daemon_fd, libc::F_GETFL, 0);
            libc::fcntl(daemon_fd, libc::F_SETFL, f | libc::O_NONBLOCK);
        }
        let mut b = Box::new(MachPortKqchan {
            daemon_fd,
            xnu_sys: std::ptr::null_mut(),
            owning_task,
            can_send_notification: true,
        });
        // The callback context is the box's stable heap address (it never moves while xnu_sys lives).
        let ctx = b.as_mut() as *mut MachPortKqchan as *mut c_void;
        let xnu_sys = unsafe {
            xnu_sys_kqchan_mach_port_create(
                owning_task,
                port,
                receive_buffer,
                receive_buffer_size,
                saved_filter_flags,
                Some(mach_port_notify_cb),
                ctx,
            )
        };
        if xnu_sys.is_null() {
            unsafe {
                libc::close(daemon_fd);
                libc::close(guest_fd);
            }
            return Err(io::Error::from_raw_os_error(libc::ESRCH));
        }
        b.xnu_sys = xnu_sys;
        // If a message is already queued, notify now (the client's filter is level-triggered).
        if unsafe { xnu_sys_kqchan_mach_port_has_events(xnu_sys) } {
            b.send_notification();
        }
        Ok((b, guest_fd))
    }

    fn send(&self, bytes: &[u8]) {
        unsafe {
            libc::send(self.daemon_fd, bytes.as_ptr() as *const c_void, bytes.len(), libc::MSG_DONTWAIT);
        }
    }

    /// Enqueue a notification datagram to the guest (throttled to one outstanding). Called from the
    /// xnu-sys callback (message arrived) and after open/modify/read when events are pending.
    fn send_notification(&mut self) {
        if !self.can_send_notification {
            return;
        }
        let note = Notification { header: Callhdr { number: MSGNUM_NOTIFICATION, pid: 0, tid: 0 } };
        self.send(as_bytes(&note));
        self.can_send_notification = false;
    }

    /// Drain + handle all pending guest messages (modify/read). Returns false if the guest closed
    /// its end (remove the channel). Mirrors Kqchan::MachPort::_processMessages.
    pub fn on_readable(&mut self) -> bool {
        let mut buf = [0u8; 256];
        loop {
            let n = unsafe { libc::recv(self.daemon_fd, buf.as_mut_ptr() as *mut c_void, buf.len(), 0) };
            if n == 0 {
                return false;
            }
            if n < 0 {
                let e = io::Error::last_os_error();
                return e.kind() == io::ErrorKind::WouldBlock;
            }
            let n = n as usize;
            if n < size_of::<Callhdr>() {
                continue;
            }
            let number = u32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]);
            match number {
                MSGNUM_MACH_PORT_MODIFY if n >= size_of::<CallMachPortModify>() => {
                    let call: CallMachPortModify = unsafe { std::ptr::read_unaligned(buf.as_ptr() as *const _) };
                    self.modify(call.receive_buffer, call.receive_buffer_size, call.saved_filter_flags);
                }
                MSGNUM_MACH_PORT_READ if n >= size_of::<CallMachPortRead>() => {
                    let call: CallMachPortRead = unsafe { std::ptr::read_unaligned(buf.as_ptr() as *const _) };
                    self.read(call.default_buffer, call.default_buffer_size);
                }
                _ => { /* unknown msgnum for a mach-port channel: ignore */ }
            }
        }
    }

    /// Register/modify the port filter, then ack. The xnu_sys modify runs on a microthread bound to
    /// the owning task (thread context) -- the cooperative stand-in for C++'s impersonate. No
    /// `&mut self` is held across run_on_task, so the notify callback can safely fire during it.
    fn modify(&mut self, receive_buffer: u64, receive_buffer_size: u64, saved_filter_flags: u64) {
        let (xnu_sys, task) = (self.xnu_sys, self.owning_task);
        unsafe {
            sched::run_on_task(
                task,
                Box::new(move || {
                    xnu_sys_kqchan_mach_port_modify(xnu_sys, receive_buffer, receive_buffer_size, saved_filter_flags);
                }),
            );
        }
        let reply = ReplyMachPortModify { header: Replyhdr { number: MSGNUM_MACH_PORT_MODIFY, code: 0 } };
        self.send(as_bytes(&reply));
        if unsafe { xnu_sys_kqchan_mach_port_has_events(xnu_sys) } {
            self.send_notification();
        }
    }

    /// Fetch pending messages: the guest acked our notification (implicitly by reading), so
    /// re-enable notifications, then fill the reply via the xnu-sys on the owning task's
    /// microthread (which also copies the message body into the guest's buffer). Mirrors _read.
    fn read(&mut self, default_buffer: u64, default_buffer_size: u64) {
        self.can_send_notification = true; // ack: may notify again
        let (xnu_sys, task, daemon_fd) = (self.xnu_sys, self.owning_task, self.daemon_fd);
        // No `&mut self` is held across this run, so a notify callback that fires mid-fill only
        // touches self through the raw pointer (no aliasing). The reply is sent from the body so it
        // precedes any such notification, keeping the channel in order (cf. _read's deferral note).
        unsafe {
            sched::run_on_task(
                task,
                Box::new(move || {
                    let mut reply: dserver_kqchan_reply_mach_port_read_t = std::mem::zeroed();
                    // The GENERATED header types this field as the enum, where the local
                    // mirror typed it u32 and accepted any number. Same value (3), now checked.
                    reply.header.number =
                        bindings::dserver_kqchan_msgnum::dserver_kqchan_msgnum_mach_port_read;
                    reply.header.code = 0;
                    if !xnu_sys_kqchan_mach_port_fill(xnu_sys, &mut reply, default_buffer, default_buffer_size) {
                        // 0xdead: "no events" sentinel (matches ProcKqchan + kqchan.cpp).
                        reply.header.code = 0xdead;
                    }
                    libc::send(
                        daemon_fd,
                        &reply as *const _ as *const c_void,
                        size_of::<dserver_kqchan_reply_mach_port_read_t>(),
                        libc::MSG_DONTWAIT,
                    );
                }),
            );
        }
        if unsafe { xnu_sys_kqchan_mach_port_has_events(xnu_sys) } {
            self.send_notification();
        }
    }
}

impl Drop for MachPortKqchan {
    fn drop(&mut self) {
        unsafe {
            if !self.xnu_sys.is_null() {
                // Disable notifications BEFORE destroy so the callback can never fire into a freed box.
                xnu_sys_kqchan_mach_port_disable_notifications(self.xnu_sys);
                xnu_sys_kqchan_mach_port_destroy(self.xnu_sys);
            }
            libc::close(self.daemon_fd);
        }
    }
}
