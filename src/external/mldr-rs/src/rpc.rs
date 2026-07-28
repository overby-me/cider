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
/// Move `fd` to a high fd number (above the guest program's own low fds) with FD_CLOEXEC set,
/// closing the original. Mirrors C __mldr_create_rpc_socket, which hands out the highest
/// available fds (socket_bitmap, from rlim_cur-1 downward) and sets FD_CLOEXEC. This is
/// essential: RPC socket fds must never collide with the guest's low fds -- a forked subshell
/// (bash) freely dup2s/closes low fds and would otherwise clobber the RPC socket, corrupting
/// the child's control flow (a wild jump / SIGSEGV). CLOEXEC keeps the socket from leaking
/// across the guest's fork+exec. Raw syscalls only, so it is allocation-free / fork-safe.
/// Returns the new high fd, or the original fd if reservation fails.
unsafe fn reserve_high_cloexec(fd: c_int) -> c_int {
    // Land the RPC socket at a moderately high fd: above the guest program's own low fds (bash
    // uses up to fd 255 for its shell fd) but below FD_SETSIZE (1024), so nothing that indexes
    // fds by a fixed-size table or uses select() trips over it. C's socket_bitmap starts at
    // rlim_cur-1, but the guest's rlimit here is enormous (~524288), and an absurdly high fd
    // (~524224) wedges the guest's RPC layer (interrupt_enter -> EBADF); a fd in [512,1023]
    // clears bash without going that high.
    let mut rl: libc::rlimit = std::mem::zeroed();
    let base = if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) == 0
        && rl.rlim_cur != libc::RLIM_INFINITY
        && rl.rlim_cur > 512
        && (rl.rlim_cur as u64) < 1024
    {
        (rl.rlim_cur - 8) as c_int
    } else {
        512
    };
    let hi = libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, base);
    if hi < 0 {
        // Could not reserve a high fd; at least set CLOEXEC on the original and keep it.
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
        return fd;
    }
    libc::close(fd);
    hi
}

/// Create a per-thread RPC socket (bind + connect) for a newly created guest thread, or a
/// fresh socket for the post-fork child (dserver_per_thread_socket_refresh).
///
/// MUST be allocation-free: it runs in the forked child, where another guest thread may have
/// held the malloc lock at fork time, so any heap allocation here can deadlock or corrupt the
/// child. We therefore read the server address straight from `SOCKPATH` by reference (no
/// String clone) and build the sockaddr on the stack. Mirrors C __mldr_create_rpc_socket,
/// which likewise only does socket/bind/connect with a static sockaddr.
pub unsafe fn create_thread_socket() -> c_int {
    if SOCKPATH.get().is_none() {
        return -1;
    }
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
    let fd = reserve_high_cloexec(fd);
    // No connect(): RPCs use sendto with the server address (matches C __mldr_create_rpc_socket).
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

/// True on the process's main thread (pid == tid). Used by the socket-refresh elfcall to also
/// update the main-thread socket, matching C __darling_thread_rpc_socket_refresh.
pub fn is_main_thread() -> bool {
    unsafe { libc::getpid() == gettid() }
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
    let (server, slen) = make_server_addr(SOCKPATH.get()?);
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
    if libc::sendto(
        fd,
        bytes.as_ptr() as *const c_void,
        bytes.len(),
        0,
        &server as *const _ as *const libc::sockaddr,
        slen,
    ) < 0
    {
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
    // Reserve a high fd + CLOEXEC (matches C __mldr_create_rpc_socket): RPC sockets must sit
    // above the guest's low fds so a forked subshell can't clobber them.
    let fd = reserve_high_cloexec(fd);
    set_main_socket(fd);
    // Record the server address for the guest (elfcalls dserver_socket_address). We deliberately
    // do NOT connect(): every RPC uses sendto() with this address (exactly as the C mldr does).
    // A *connected* high fd wedged the guest's interrupt_enter with EBADF.
    let (server, _slen) = make_server_addr(sockpath);
    SERVER_ADDR.write(server);
    SERVER_ADDR_SET.store(true, Ordering::SeqCst);
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
