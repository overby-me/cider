//! The daemon's socket loop: a bound AF_UNIX SOCK_DGRAM socket (SO_PASSCRED) over which
//! every guest sends its RPC datagrams, multiplexed through one epoll into the receive ->
//! dispatch -> reply cycle. Connectionless: replies go back to each sender's address.
//! This matches the real guest transport (server.cpp:452); call handlers plug in via the
//! closure passed to `run`. See PLAN.md.

use crate::rpc_io::{recv_datagram, send_datagram, Message};
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
    /// Bind a SOCK_DGRAM socket with SO_PASSCRED on `path` (unlinked first) and register
    /// it with a fresh epoll. Connectionless -- no listen/accept.
    pub fn bind(path: &str) -> io::Result<Listener> {
        let cpath = CString::new(path).unwrap();
        unsafe {
            let listen_fd = cvt(libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM, 0) as i64)? as RawFd;
            libc::unlink(cpath.as_ptr());
            // Receive the sender's credentials (pid/uid/gid) with each datagram.
            let one: libc::c_int = 1;
            cvt(libc::setsockopt(listen_fd, libc::SOL_SOCKET, libc::SO_PASSCRED, &one as *const _ as *const libc::c_void, size_of::<libc::c_int>() as libc::socklen_t) as i64)?;
            let mut addr: libc::sockaddr_un = zeroed();
            addr.sun_family = libc::AF_UNIX as _;
            let bytes = cpath.as_bytes_with_nul();
            assert!(bytes.len() <= addr.sun_path.len(), "socket path too long");
            std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const i8, addr.sun_path.as_mut_ptr(), bytes.len());
            let addrlen = (size_of::<libc::sa_family_t>() + bytes.len()) as libc::socklen_t;
            cvt(libc::bind(listen_fd, &addr as *const _ as *const libc::sockaddr, addrlen) as i64)?;
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

    /// The bound socket fd (for a daemon that drives its own recv/send loop instead of
    /// `run`, e.g. to route replies across multiple guest threads).
    pub fn fd(&self) -> RawFd {
        self.listen_fd
    }

    /// Switch the socket to blocking mode, so `recv` blocks for the next datagram rather
    /// than returning Ok(None). Used by the daemon's own serve loop (single socket, no
    /// need for the nonblocking + epoll dance).
    pub fn set_blocking(&self) {
        unsafe {
            let f = libc::fcntl(self.listen_fd, libc::F_GETFL, 0);
            libc::fcntl(self.listen_fd, libc::F_SETFL, f & !libc::O_NONBLOCK);
        }
    }

    /// Receive one datagram (message + sender address). Blocks if the socket is blocking.
    pub fn recv(&self) -> io::Result<Option<(crate::rpc_io::Message, crate::rpc_io::PeerAddr)>> {
        recv_datagram(self.listen_fd)
    }

    /// Send a reply datagram back to `to`.
    pub fn send(&self, data: &[u8], fds: &[RawFd], to: &crate::rpc_io::PeerAddr) -> io::Result<()> {
        send_datagram(self.listen_fd, data, fds, to)
    }

    /// Serve datagrams until `handle` has served `max_messages` (pass usize::MAX for a
    /// real daemon that runs forever). For each datagram, `handle` returns the reply bytes
    /// to send back to that sender (or None). An idle wait is NOT an error -- the loop just
    /// blocks in epoll until the next datagram.
    pub fn run(&self, max_messages: usize, mut handle: impl FnMut(&Message) -> Option<Vec<u8>>) -> io::Result<()> {
        let mut served = 0usize;
        let mut events: [libc::epoll_event; 8] = unsafe { zeroed() };
        while served < max_messages {
            // Block until the datagram socket is readable (no fatal idle timeout).
            let n = unsafe { libc::epoll_wait(self.epfd, events.as_mut_ptr(), events.len() as i32, -1) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted { continue; }
                return Err(e);
            }
            // Drain all pending datagrams; reply to each sender's address.
            loop {
                match recv_datagram(self.listen_fd) {
                    Ok(Some((msg, peer))) => {
                        if let Some(reply) = handle(&msg) {
                            let _ = send_datagram(self.listen_fd, &reply, &[], &peer);
                        }
                        served += 1;
                        if served >= max_messages {
                            break;
                        }
                    }
                    Ok(None) => break, // drained (WouldBlock)
                    Err(_) => break,
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

/// Helper: a client DGRAM socket with the bound Listener path as its default peer (for
/// tests). Autobinds first so the daemon's reply datagram has somewhere to go.
pub fn connect(path: &str) -> io::Result<RawFd> {
    let cpath = CString::new(path).unwrap();
    unsafe {
        let fd = cvt(libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM, 0) as i64)? as RawFd;
        // Autobind (empty address -> kernel assigns an abstract name) so replies reach us.
        let mut anon: libc::sockaddr_un = zeroed();
        anon.sun_family = libc::AF_UNIX as _;
        let _ = libc::bind(fd, &anon as *const _ as *const libc::sockaddr, size_of::<libc::sa_family_t>() as libc::socklen_t);
        let mut addr: libc::sockaddr_un = zeroed();
        addr.sun_family = libc::AF_UNIX as _;
        let bytes = cpath.as_bytes_with_nul();
        std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const i8, addr.sun_path.as_mut_ptr(), bytes.len());
        let addrlen = (size_of::<libc::sa_family_t>() + bytes.len()) as libc::socklen_t;
        cvt(libc::connect(fd, &addr as *const _ as *const libc::sockaddr, addrlen) as i64)?;
        Ok(fd)
    }
}
