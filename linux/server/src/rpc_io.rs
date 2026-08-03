//! Daemon-side RPC message I/O: the receive/decode half of the loop. recvmsg a
//! message (with SCM_RIGHTS fds) off the unix socket, decode its callhdr, and
//! dispatch by call number via the generated codec. Pure socket/wire code -- no
//! duct-tape. See PLAN.md (Stage 4).

use crate::rpc_wire::{callnum_name, DserverRpcCallhdr};
use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::RawFd;
use std::os::raw::c_void;

/// One received RPC message: the wire bytes + any passed file descriptors + (for
/// datagrams with SO_PASSCRED) the sender's pid in the DAEMON's namespace, which
/// process_vm_readv/writev needs to reach a guest running in its own PID namespace.
#[derive(Clone)]
pub struct Message {
    pub data: Vec<u8>,
    pub fds: Vec<RawFd>,
    pub host_pid: Option<libc::pid_t>,
}

impl Message {
    /// Decode the leading callhdr (number, pid, tid, architecture), if present.
    pub fn header(&self) -> Option<DserverRpcCallhdr> {
        if self.data.len() < size_of::<DserverRpcCallhdr>() {
            return None;
        }
        // The wire may be unaligned relative to our buffer start; read unaligned.
        Some(unsafe { std::ptr::read_unaligned(self.data.as_ptr() as *const DserverRpcCallhdr) })
    }
    /// The call name for this message's number (dispatch key), if known.
    pub fn call_name(&self) -> Option<&'static str> {
        self.header().and_then(|h| callnum_name(h.number))
    }
    /// The message body (everything after the callhdr).
    pub fn body(&self) -> &[u8] {
        &self.data[size_of::<DserverRpcCallhdr>().min(self.data.len())..]
    }
}

const MAX_MSG: usize = 64 * 1024;
const MAX_FDS: usize = 253; // SCM_RIGHTS practical cap

/// Receive one message. Ok(None) on clean EOF (peer closed).
pub fn recv_message(fd: RawFd) -> io::Result<Option<Message>> {
    let mut buf = vec![0u8; MAX_MSG];
    let mut cmsg_space = vec![0u8; unsafe { libc::CMSG_SPACE((MAX_FDS * size_of::<RawFd>()) as u32) } as usize];
    let mut iov = libc::iovec {
        iov_base: buf.as_mut_ptr() as *mut c_void,
        iov_len: buf.len(),
    };
    let mut msg: libc::msghdr = unsafe { zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_space.as_mut_ptr() as *mut c_void;
    msg.msg_controllen = cmsg_space.len();

    let n = unsafe { libc::recvmsg(fd, &mut msg, 0) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    if n == 0 {
        return Ok(None);
    }
    buf.truncate(n as usize);

    let mut fds = Vec::new();
    unsafe {
        let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
        while !cmsg.is_null() {
            if (*cmsg).cmsg_level == libc::SOL_SOCKET && (*cmsg).cmsg_type == libc::SCM_RIGHTS {
                let payload = (*cmsg).cmsg_len as usize - libc::CMSG_LEN(0) as usize;
                let count = payload / size_of::<RawFd>();
                let data = libc::CMSG_DATA(cmsg);
                for i in 0..count {
                    let mut f: RawFd = -1;
                    std::ptr::copy_nonoverlapping(
                        data.add(i * size_of::<RawFd>()),
                        &mut f as *mut RawFd as *mut u8,
                        size_of::<RawFd>(),
                    );
                    fds.push(f);
                }
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }
    }
    Ok(Some(Message { data: buf, fds, host_pid: None }))
}

/// Send a message (bytes + optional fds via SCM_RIGHTS). Mirror of recv_message,
/// for tests and (later) reply sending.
pub fn send_message(fd: RawFd, data: &[u8], fds: &[RawFd]) -> io::Result<()> {
    let mut cmsg_space = vec![0u8; unsafe { libc::CMSG_SPACE((fds.len().max(1) * size_of::<RawFd>()) as u32) } as usize];
    let mut iov = libc::iovec {
        iov_base: data.as_ptr() as *mut c_void,
        iov_len: data.len(),
    };
    let mut msg: libc::msghdr = unsafe { zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    if !fds.is_empty() {
        msg.msg_control = cmsg_space.as_mut_ptr() as *mut c_void;
        msg.msg_controllen = unsafe { libc::CMSG_SPACE((fds.len() * size_of::<RawFd>()) as u32) } as usize;
        unsafe {
            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN((fds.len() * size_of::<RawFd>()) as u32) as _;
            std::ptr::copy_nonoverlapping(
                fds.as_ptr() as *const u8,
                libc::CMSG_DATA(cmsg),
                fds.len() * size_of::<RawFd>(),
            );
        }
    }
    let n = unsafe { libc::sendmsg(fd, &msg, 0) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

// ---- SOCK_DGRAM protocol (the real guest<->daemon transport) ----
//
// The guest talks to the daemon over a connectionless AF_UNIX SOCK_DGRAM socket with
// SO_PASSCRED (server.cpp:452). Each datagram carries the caller's message + (via the
// kernel, because of SO_PASSCRED) the sender's credentials; the daemon replies by
// sending a datagram back to the sender's address, itself carrying the daemon's
// credentials (message.cpp attaches them to every message). This is why the SEQPACKET
// socketpair demos could not surface the mismatch -- the real transport is different.

/// A datagram peer's address, captured from recvmsg's msg_name so the reply can be sent
/// back to it (an autobound guest socket has an address; that is where the reply goes).
#[derive(Clone)]
pub struct PeerAddr {
    pub addr: libc::sockaddr_un,
    pub len: libc::socklen_t,
}

/// The daemon's own credentials, attached to every reply (matching the C++ daemon).
fn daemon_ucred() -> libc::ucred {
    unsafe { libc::ucred { pid: libc::getpid(), uid: libc::getuid(), gid: libc::getgid() } }
}

/// Receive one datagram: the message (+ any SCM_RIGHTS fds) and the sender's address for
/// the reply. Ok(None) on WouldBlock (the nonblocking socket has drained). SCM_CREDENTIALS
/// is consumed by the kernel/ignored here (we route by the callhdr pid).
pub fn recv_datagram(fd: RawFd) -> io::Result<Option<(Message, PeerAddr)>> {
    let mut buf = vec![0u8; MAX_MSG];
    let mut peer: libc::sockaddr_un = unsafe { zeroed() };
    let cmsg_len = unsafe {
        libc::CMSG_SPACE((MAX_FDS * size_of::<RawFd>()) as u32) as usize
            + libc::CMSG_SPACE(size_of::<libc::ucred>() as u32) as usize
    };
    let mut cmsg = vec![0u8; cmsg_len];
    let mut iov = libc::iovec { iov_base: buf.as_mut_ptr() as *mut c_void, iov_len: buf.len() };
    let mut msg: libc::msghdr = unsafe { zeroed() };
    msg.msg_name = &mut peer as *mut _ as *mut c_void;
    msg.msg_namelen = size_of::<libc::sockaddr_un>() as libc::socklen_t;
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg.as_mut_ptr() as *mut c_void;
    msg.msg_controllen = cmsg.len() as _;

    let n = unsafe { libc::recvmsg(fd, &mut msg, 0) };
    if n < 0 {
        let e = io::Error::last_os_error();
        if e.kind() == io::ErrorKind::WouldBlock {
            return Ok(None);
        }
        return Err(e);
    }
    buf.truncate(n as usize);

    let mut fds = Vec::new();
    let mut host_pid: Option<libc::pid_t> = None;
    unsafe {
        let mut c = libc::CMSG_FIRSTHDR(&msg);
        while !c.is_null() {
            if (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_RIGHTS {
                let payload = (*c).cmsg_len as usize - libc::CMSG_LEN(0) as usize;
                let count = payload / size_of::<RawFd>();
                let data = libc::CMSG_DATA(c);
                for i in 0..count {
                    let mut f: RawFd = -1;
                    std::ptr::copy_nonoverlapping(
                        data.add(i * size_of::<RawFd>()),
                        &mut f as *mut RawFd as *mut u8,
                        size_of::<RawFd>(),
                    );
                    fds.push(f);
                }
            } else if (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_CREDENTIALS {
                // SO_PASSCRED: the kernel translated the sender's pid into OUR namespace --
                // exactly the pid process_vm_readv needs for a guest in its own PID ns.
                let mut cred: libc::ucred = std::mem::zeroed();
                std::ptr::copy_nonoverlapping(libc::CMSG_DATA(c), &mut cred as *mut _ as *mut u8, size_of::<libc::ucred>());
                host_pid = Some(cred.pid);
            }
            c = libc::CMSG_NXTHDR(&msg, c);
        }
    }
    Ok(Some((Message { data: buf, fds, host_pid }, PeerAddr { addr: peer, len: msg.msg_namelen })))
}

/// Send `data` (+ any fds) as a datagram to `to`, attaching the daemon's SCM_CREDENTIALS.
pub fn send_datagram(fd: RawFd, data: &[u8], fds: &[RawFd], to: &PeerAddr) -> io::Result<()> {
    let cred = daemon_ucred();
    let has_fds = !fds.is_empty();
    let cmsg_len = unsafe {
        libc::CMSG_SPACE(size_of::<libc::ucred>() as u32) as usize
            + if has_fds { libc::CMSG_SPACE((fds.len() * size_of::<RawFd>()) as u32) as usize } else { 0 }
    };
    let mut cmsg = vec![0u8; cmsg_len];
    let mut iov = libc::iovec { iov_base: data.as_ptr() as *mut c_void, iov_len: data.len() };
    let mut msg: libc::msghdr = unsafe { zeroed() };
    msg.msg_name = &to.addr as *const _ as *mut c_void;
    msg.msg_namelen = to.len;
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg.as_mut_ptr() as *mut c_void;
    msg.msg_controllen = cmsg.len() as _;
    unsafe {
        let c = libc::CMSG_FIRSTHDR(&msg);
        (*c).cmsg_level = libc::SOL_SOCKET;
        (*c).cmsg_type = libc::SCM_CREDENTIALS;
        (*c).cmsg_len = libc::CMSG_LEN(size_of::<libc::ucred>() as u32) as _;
        std::ptr::copy_nonoverlapping(&cred as *const _ as *const u8, libc::CMSG_DATA(c), size_of::<libc::ucred>());
        if has_fds {
            let c2 = libc::CMSG_NXTHDR(&msg, c);
            (*c2).cmsg_level = libc::SOL_SOCKET;
            (*c2).cmsg_type = libc::SCM_RIGHTS;
            (*c2).cmsg_len = libc::CMSG_LEN((fds.len() * size_of::<RawFd>()) as u32) as _;
            std::ptr::copy_nonoverlapping(fds.as_ptr() as *const u8, libc::CMSG_DATA(c2), fds.len() * size_of::<RawFd>());
        }
    }
    let n = unsafe { libc::sendmsg(fd, &msg, 0) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
