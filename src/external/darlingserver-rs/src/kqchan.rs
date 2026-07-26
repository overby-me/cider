//! Process kqueue channels (EVFILT_PROC): the daemon side of the guest's
//! kqueue(EVFILT_PROC) waiters. A guest opens one via kqchan_proc_open to watch another
//! process; the daemon returns one end of a SEQPACKET socketpair and keeps the other.
//! Over it, the guest sends proc_modify (set the filter flags) and proc_read (fetch the
//! latest event), and the daemon pushes a `notification` message when a watched event
//! (e.g. the target's death -> NOTE_EXIT) occurs. Raw SEQPACKET framing (one struct per
//! message, no length prefix), matching darlingserver's MessageQueue. Mirrors
//! DarlingServer::Kqchan::Process (kqchan.cpp). See plan/rust-rewrite-eval.md (bucket B.8).

use std::collections::VecDeque;
use std::io;
use std::mem::size_of;
use std::os::fd::RawFd;

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
