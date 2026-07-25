//! The daemon's epoll accept loop: a listening unix socket that accepts guest
//! connections and multiplexes the receive -> dispatch -> reply cycle across many
//! guests. The structural top of the daemon; call handlers plug in via the closure
//! passed to `run`. See plan/rust-rewrite-eval.md (Stage 4).

use crate::rpc_io::{recv_message, send_message, Message};
use std::ffi::CString;
use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::RawFd;

fn cvt(r: i64) -> io::Result<i64> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

fn set_nonblocking(fd: RawFd) {
    unsafe {
        let f = libc::fcntl(fd, libc::F_GETFL, 0);
        libc::fcntl(fd, libc::F_SETFL, f | libc::O_NONBLOCK);
    }
}

/// A listening unix (SEQPACKET) socket + its epoll instance.
pub struct Listener {
    listen_fd: RawFd,
    epfd: RawFd,
    path: CString,
}

impl Listener {
    /// Bind + listen on `path` (unlinked first) and register it with a fresh epoll.
    pub fn bind(path: &str) -> io::Result<Listener> {
        let cpath = CString::new(path).unwrap();
        unsafe {
            let listen_fd = cvt(libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0) as i64)? as RawFd;
            libc::unlink(cpath.as_ptr());
            let mut addr: libc::sockaddr_un = zeroed();
            addr.sun_family = libc::AF_UNIX as _;
            let bytes = cpath.as_bytes_with_nul();
            assert!(bytes.len() <= addr.sun_path.len(), "socket path too long");
            std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const i8, addr.sun_path.as_mut_ptr(), bytes.len());
            let addrlen = (size_of::<libc::sa_family_t>() + bytes.len()) as libc::socklen_t;
            cvt(libc::bind(listen_fd, &addr as *const _ as *const libc::sockaddr, addrlen) as i64)?;
            cvt(libc::listen(listen_fd, 128) as i64)?;
            set_nonblocking(listen_fd);

            let epfd = cvt(libc::epoll_create1(libc::EPOLL_CLOEXEC) as i64)? as RawFd;
            let mut ev = libc::epoll_event { events: libc::EPOLLIN as u32, u64: listen_fd as u64 };
            cvt(libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, listen_fd, &mut ev) as i64)?;
            Ok(Listener { listen_fd, epfd, path: cpath })
        }
    }

    pub fn path(&self) -> &str {
        self.path.to_str().unwrap()
    }

    unsafe fn epoll_add(&self, fd: RawFd) {
        let mut ev = libc::epoll_event { events: libc::EPOLLIN as u32, u64: fd as u64 };
        libc::epoll_ctl(self.epfd, libc::EPOLL_CTL_ADD, fd, &mut ev);
    }
    unsafe fn epoll_del(&self, fd: RawFd) {
        libc::epoll_ctl(self.epfd, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut());
        libc::close(fd);
    }

    /// Run the epoll loop until `handle` has served `max_messages` messages. For each
    /// received message, `handle` returns the reply bytes to send back (or None).
    /// (`max_messages` bounds the loop for tests; a real daemon loops forever.)
    pub fn run(&self, max_messages: usize, mut handle: impl FnMut(&Message) -> Option<Vec<u8>>) -> io::Result<()> {
        let mut served = 0usize;
        let mut events: [libc::epoll_event; 64] = unsafe { zeroed() };
        while served < max_messages {
            let n = unsafe { libc::epoll_wait(self.epfd, events.as_mut_ptr(), events.len() as i32, 5000) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted { continue; }
                return Err(e);
            }
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "epoll_wait timed out"));
            }
            for ev in &events[..n as usize] {
                let fd = ev.u64 as RawFd;
                if fd == self.listen_fd {
                    // Drain the accept backlog (nonblocking).
                    loop {
                        let c = unsafe { libc::accept(self.listen_fd, std::ptr::null_mut(), std::ptr::null_mut()) };
                        if c < 0 { break; }
                        set_nonblocking(c);
                        unsafe { self.epoll_add(c) };
                    }
                } else {
                    match recv_message(fd) {
                        Ok(Some(msg)) => {
                            if let Some(reply) = handle(&msg) {
                                let _ = send_message(fd, &reply, &[]);
                            }
                            served += 1;
                        }
                        Ok(None) => unsafe { self.epoll_del(fd) }, // peer closed
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                        Err(_) => unsafe { self.epoll_del(fd) },
                    }
                }
            }
        }
        Ok(())
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.listen_fd);
            libc::close(self.epfd);
            libc::unlink(self.path.as_ptr());
        }
    }
}

/// Helper: connect a client SEQPACKET socket to a bound Listener path (for tests).
pub fn connect(path: &str) -> io::Result<RawFd> {
    let cpath = CString::new(path).unwrap();
    unsafe {
        let fd = cvt(libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0) as i64)? as RawFd;
        let mut addr: libc::sockaddr_un = zeroed();
        addr.sun_family = libc::AF_UNIX as _;
        let bytes = cpath.as_bytes_with_nul();
        std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const i8, addr.sun_path.as_mut_ptr(), bytes.len());
        let addrlen = (size_of::<libc::sa_family_t>() + bytes.len()) as libc::socklen_t;
        cvt(libc::connect(fd, &addr as *const _ as *const libc::sockaddr, addrlen) as i64)?;
        Ok(fd)
    }
}
