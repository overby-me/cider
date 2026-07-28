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

/// The darlingserver socket address, exposed to the guest RPC via elfcalls.
static mut SERVER_ADDR: std::mem::MaybeUninit<libc::sockaddr_un> = std::mem::MaybeUninit::uninit();
static SERVER_ADDR_SET: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub fn server_addr_ptr() -> *const c_void {
    if SERVER_ADDR_SET.load(Ordering::SeqCst) {
        unsafe { SERVER_ADDR.as_ptr() as *const c_void }
    } else {
        std::ptr::null()
    }
}

// Per-thread RPC socket (for the thread bridge). Each created guest thread gets its own
// socket; dserver_per_thread_socket returns the calling native thread's fd.
std::thread_local! {
    static T_SOCKET: std::cell::Cell<c_int> = const { std::cell::Cell::new(-1) };
}
static SOCKPATH: std::sync::OnceLock<String> = std::sync::OnceLock::new();
pub fn set_sockpath(p: &str) {
    let _ = SOCKPATH.set(p.to_string());
}
pub fn set_thread_socket(fd: c_int) {
    T_SOCKET.with(|s| s.set(fd));
}
pub fn thread_socket() -> c_int {
    let t = T_SOCKET.with(|s| s.get());
    if t >= 0 {
        t
    } else {
        main_socket()
    }
}
/// Create a per-thread RPC socket (bind + connect) for a newly created guest thread.
pub unsafe fn create_thread_socket() -> c_int {
    let path = match SOCKPATH.get() {
        Some(p) => p.clone(),
        None => return -1,
    };
    let fd = libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM, 0);
    if fd < 0 {
        return -1;
    }
    let mut addr: libc::sockaddr_un = std::mem::zeroed();
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    libc::bind(
        fd,
        &addr as *const _ as *const libc::sockaddr,
        std::mem::size_of::<libc::sa_family_t>() as libc::socklen_t,
    );
    let (server, slen) = make_server_addr(&path);
    libc::connect(fd, &server as *const _ as *const libc::sockaddr, slen);
    set_thread_socket(fd);
    fd
}
/// Check in on a created thread's own socket.
pub unsafe fn checkin_thread(fd: c_int, stack_hint: u64) -> i32 {
    match SOCKPATH.get() {
        Some(p) => checkin(fd, &p.clone(), stack_hint),
        None => -1,
    }
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

const VCHROOT_PATH: u32 = 3;
#[repr(C)]
#[derive(Clone, Copy)]
struct CallVchrootPath {
    buffer: u64,
    buffer_size: u64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct RpcCallVchrootPath {
    header: DserverRpcCallhdr,
    body: CallVchrootPath,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct ReplyVchrootPath {
    length: u64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct RpcReplyVchrootPath {
    header: DserverRpcReplyhdr,
    body: ReplyVchrootPath,
}

/// Fetch the container's vchroot Linux prefix (the daemon writes it into our buffer via a
/// cross-process write, replies the length). Empty for the first process (before the vchroot
/// helper sets it). Requires a connected socket.
pub unsafe fn vchroot_path(fd: c_int) -> Option<String> {
    let mut buf = vec![0u8; 4096];
    let call = RpcCallVchrootPath {
        header: DserverRpcCallhdr {
            number: VCHROOT_PATH,
            pid: libc::getpid(),
            tid: gettid(),
            architecture: ARCH_X86_64,
        },
        body: CallVchrootPath {
            buffer: buf.as_mut_ptr() as u64,
            buffer_size: buf.len() as u64,
        },
    };
    let bytes = std::slice::from_raw_parts(
        &call as *const _ as *const u8,
        std::mem::size_of::<RpcCallVchrootPath>(),
    );
    if libc::send(fd, bytes.as_ptr() as *const c_void, bytes.len(), 0) < 0 {
        return None;
    }
    let mut reply: RpcReplyVchrootPath = std::mem::zeroed();
    if libc::recv(
        fd,
        &mut reply as *mut _ as *mut c_void,
        std::mem::size_of::<RpcReplyVchrootPath>(),
        0,
    ) < 0
    {
        return None;
    }
    if reply.header.code != 0 {
        return None;
    }
    let len = (reply.body.length as usize).min(buf.len());
    if len == 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&buf[..len]).into_owned())
}

/// Create the RPC socket (SOCK_DGRAM) and autobind it so the daemon can reply.
pub unsafe fn create_socket(sockpath: &str) -> c_int {
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
    // Record the server address for the guest (elfcalls dserver_socket_address) and connect,
    // so the guest's send() reaches the daemon.
    let (server, slen) = make_server_addr(sockpath);
    SERVER_ADDR.write(server);
    SERVER_ADDR_SET.store(true, Ordering::SeqCst);
    libc::connect(fd, &server as *const _ as *const libc::sockaddr, slen);
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
