//! Daemon-side RPC message I/O: the receive/decode half of the loop. recvmsg a
//! message (with SCM_RIGHTS fds) off the unix socket, decode its callhdr, and
//! dispatch by call number via the generated codec. Pure socket/wire code -- no
//! duct-tape. See plan/rust-rewrite-eval.md (Stage 4).

use crate::rpc_wire::{callnum_name, DserverRpcCallhdr};
use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::RawFd;
use std::os::raw::c_void;

/// One received RPC message: the wire bytes + any passed file descriptors.
#[derive(Clone)]
pub struct Message {
    pub data: Vec<u8>,
    pub fds: Vec<RawFd>,
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
    Ok(Some(Message { data: buf, fds }))
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
