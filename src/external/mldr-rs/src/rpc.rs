// mldr M4: darlingserver checkin RPC. AF_UNIX SOCK_DGRAM to the server at __mldr_sockpath.
// The wire structs are byte-identical to the daemon's generated rpc_wire.rs (x86_64 layout);
// see src/external/darlingserver-rs/src/rpc_wire.rs. mldr is a client of ~6 calls; this
// starts with checkin (the essential one). The lifetime pipe is -1 on kernels >= 5.3 (the
// daemon uses pidfd), so no SCM_RIGHTS fd is needed for the common path.
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicI32, Ordering};

/// The main-thread RPC socket, exposed to the guest via the elfcalls vtable.
static MAIN_SOCKET: AtomicI32 = AtomicI32::new(-1);
pub fn set_main_socket(fd: c_int) {
    MAIN_SOCKET.store(fd, Ordering::SeqCst);
}
pub fn main_socket() -> c_int {
    MAIN_SOCKET.load(Ordering::SeqCst)
}

const CHECKIN: u32 = 1;
const ARCH_X86_64: u32 = 2; // dserver_rpc_architecture_x86_64

#[repr(C)]
#[derive(Clone, Copy)]
struct DserverRpcCallhdr {
    number: u32,
    pid: i32,
    tid: i32,
    architecture: u32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct DserverRpcReplyhdr {
    number: u32,
    code: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct CallCheckin {
    is_fork: bool,
    stack_hint: u64,
    lifetime_listener_pipe: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct RpcCallCheckin {
    header: DserverRpcCallhdr,
    body: CallCheckin,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct RpcReplyCheckin {
    header: DserverRpcReplyhdr,
}

/// For a wire sanity check: must be 40 (16 header + 24 body with x86_64 padding).
pub fn checkin_call_size() -> usize {
    std::mem::size_of::<RpcCallCheckin>()
}

fn gettid() -> i32 {
    unsafe { libc::syscall(libc::SYS_gettid) as i32 }
}

fn errno() -> c_int {
    unsafe { *libc::__errno_location() }
}

/// Create the RPC socket (SOCK_DGRAM) and autobind it so the daemon can reply.
pub unsafe fn create_socket() -> c_int {
    let fd = libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM, 0);
    if fd < 0 {
        return -1;
    }
    let mut addr: libc::sockaddr_un = std::mem::zeroed();
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    // autobind: addrlen = just the family -> the kernel assigns an abstract address.
    libc::bind(
        fd,
        &addr as *const _ as *const libc::sockaddr,
        std::mem::size_of::<libc::sa_family_t>() as libc::socklen_t,
    );
    set_main_socket(fd);
    fd
}

fn make_server_addr(path: &str) -> (libc::sockaddr_un, libc::socklen_t) {
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let bytes = path.as_bytes();
    let n = bytes.len().min(addr.sun_path.len() - 1);
    for i in 0..n {
        addr.sun_path[i] = bytes[i] as c_char;
    }
    let len = (std::mem::size_of::<libc::sa_family_t>() + n + 1) as libc::socklen_t;
    (addr, len)
}

/// Send checkin and return the reply code (0 = ok). is_fork=false, lifetime pipe -1.
pub unsafe fn checkin(fd: c_int, sockpath: &str, stack_hint: u64) -> i32 {
    let (server, slen) = make_server_addr(sockpath);
    let call = RpcCallCheckin {
        header: DserverRpcCallhdr {
            number: CHECKIN,
            pid: libc::getpid(),
            tid: gettid(),
            architecture: ARCH_X86_64,
        },
        body: CallCheckin {
            is_fork: false,
            stack_hint,
            lifetime_listener_pipe: -1,
        },
    };
    let bytes = std::slice::from_raw_parts(
        &call as *const _ as *const u8,
        std::mem::size_of::<RpcCallCheckin>(),
    );
    let sent = libc::sendto(
        fd,
        bytes.as_ptr() as *const c_void,
        bytes.len(),
        0,
        &server as *const _ as *const libc::sockaddr,
        slen,
    );
    if sent < 0 {
        eprintln!("[mldr-rs] checkin sendto failed (errno {})", errno());
        return -1;
    }
    let mut reply: RpcReplyCheckin = std::mem::zeroed();
    let got = libc::recv(
        fd,
        &mut reply as *mut _ as *mut c_void,
        std::mem::size_of::<RpcReplyCheckin>(),
        0,
    );
    if got < 0 {
        eprintln!("[mldr-rs] checkin recv failed (errno {})", errno());
        return -1;
    }
    reply.header.code
}
