// mldr M5a: the elf_calls vtable (linux/startup/mldr/elfcalls/elfcalls.h). A frozen ABI of 31
// native function pointers that mldr hands to the Mac side (its address is apple[2],
// elf_calls=<ptr>) so Darwin's Mach-O dylibs can reach the native ELF loader + libc. Field
// order and types must match elfcalls.h byte-for-byte -- libSystem reads it by offset.
//
// Real implementations for the tractable primitives (dl*, malloc/free/realloc, exit, sysconf,
// errno); thread/sem/shm/dserver-socket are stubbed and refined during integration.
#![allow(clippy::too_many_arguments)]
use std::os::raw::{c_char, c_int, c_long, c_uint, c_ulong, c_ushort, c_void};
use std::ptr;

#[repr(C)]
pub struct ElfCalls {
    pub dlopen: extern "C" fn(*const c_char) -> *mut c_void,
    pub dlclose: extern "C" fn(*mut c_void) -> c_int,
    pub dlsym: extern "C" fn(*mut c_void, *const c_char) -> *mut c_void,
    pub dlerror: extern "C" fn() -> *mut c_char,
    pub darling_thread_create: extern "C" fn(
        c_ulong,
        c_ulong,
        *mut c_void,
        usize,
        usize,
        usize,
        usize,
        *const c_void,
        *mut c_void,
    ) -> *mut c_void,
    pub darling_thread_terminate: extern "C" fn(*mut c_void, c_ulong, c_ulong) -> c_int,
    pub darling_thread_get_stack: extern "C" fn() -> *mut c_void,
    pub dlopen_fatal: extern "C" fn(*const c_char) -> *mut c_void,
    pub dlclose_fatal: extern "C" fn(*mut c_void) -> c_int,
    pub dlsym_fatal: extern "C" fn(*mut c_void, *const c_char) -> *mut c_void,
    pub get_errno: extern "C" fn() -> c_int,
    pub sem_open: extern "C" fn(*const c_char, c_int, c_ushort, c_uint) -> *mut c_int,
    pub sem_wait: extern "C" fn(*mut c_int) -> c_int,
    pub sem_trywait: extern "C" fn(*mut c_int) -> c_int,
    pub sem_post: extern "C" fn(*mut c_int) -> c_int,
    pub sem_close: extern "C" fn(*mut c_int) -> c_int,
    pub sem_unlink: extern "C" fn(*const c_char) -> c_int,
    pub shm_open: extern "C" fn(*const c_char, c_int, c_ushort) -> c_int,
    pub shm_unlink: extern "C" fn(*const c_char) -> c_int,
    pub exit: extern "C" fn(c_int),
    pub malloc: extern "C" fn(usize) -> *mut c_void,
    pub free: extern "C" fn(*mut c_void),
    pub realloc: extern "C" fn(*mut c_void, usize) -> *mut c_void,
    pub sysconf: extern "C" fn(c_int) -> c_long,
    pub dserver_socket_address: extern "C" fn() -> *const c_void,
    pub dserver_per_thread_socket: extern "C" fn() -> c_int,
    pub dserver_per_thread_socket_refresh: extern "C" fn(),
    pub dserver_close_socket: extern "C" fn(c_int),
    pub dserver_get_process_lifetime_pipe: extern "C" fn() -> c_int,
    pub dserver_process_lifetime_pipe_refresh: extern "C" fn() -> c_int,
    pub dserver_close_process_lifetime_pipe: extern "C" fn(c_int),
}

// ---- real primitives ----
extern "C" fn ec_dlopen(n: *const c_char) -> *mut c_void {
    unsafe { libc::dlopen(n, libc::RTLD_LAZY) }
}
extern "C" fn ec_dlclose(l: *mut c_void) -> c_int {
    unsafe { libc::dlclose(l) }
}
extern "C" fn ec_dlsym(l: *mut c_void, n: *const c_char) -> *mut c_void {
    unsafe { libc::dlsym(l, n) }
}
extern "C" fn ec_dlerror() -> *mut c_char {
    unsafe { libc::dlerror() }
}
extern "C" fn ec_dlopen_fatal(n: *const c_char) -> *mut c_void {
    let h = unsafe { libc::dlopen(n, libc::RTLD_LAZY) };
    if h.is_null() {
        unsafe { libc::abort() }
    }
    h
}
extern "C" fn ec_dlclose_fatal(l: *mut c_void) -> c_int {
    let r = unsafe { libc::dlclose(l) };
    if r != 0 {
        unsafe { libc::abort() }
    }
    r
}
extern "C" fn ec_dlsym_fatal(l: *mut c_void, n: *const c_char) -> *mut c_void {
    let s = unsafe { libc::dlsym(l, n) };
    if s.is_null() {
        unsafe { libc::abort() }
    }
    s
}
extern "C" fn ec_get_errno() -> c_int {
    unsafe { *libc::__errno_location() }
}
extern "C" fn ec_exit(ec: c_int) {
    unsafe { libc::exit(ec) }
}
extern "C" fn ec_malloc(s: usize) -> *mut c_void {
    unsafe { libc::malloc(s) }
}
extern "C" fn ec_free(p: *mut c_void) {
    unsafe { libc::free(p) }
}
extern "C" fn ec_realloc(p: *mut c_void, s: usize) -> *mut c_void {
    unsafe { libc::realloc(p, s) }
}
extern "C" fn ec_sysconf(n: c_int) -> c_long {
    unsafe { libc::sysconf(n) }
}

// ---- stubs (refined during integration) ----
extern "C" fn ec_thread_create(
    _: c_ulong,
    _: c_ulong,
    _: *mut c_void,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
    _: *const c_void,
    _: *mut c_void,
) -> *mut c_void {
    ptr::null_mut()
}
/// `__darling_thread_terminate` (threads.h): the last thing a guest thread does.
///
/// MUST NOT RETURN. libsystem_pthread calls this at the end of pthread_exit and, because the
/// declaration is noreturn, the compiler emits a `ud2` immediately after the call -- so a stub
/// that returns 0 lands on an illegal instruction. That is a SIGILL with no message, in a
/// library, on a thread, long after mldr has handed control over: guest `nix` died exactly
/// this way while single-threaded binaries were unaffected.
///
/// The stack is deliberately NOT unmapped here: this call is RUNNING on it. Whoever allocated
/// it owns it -- the guest for a normal pthread, and for a workqueue thread the mapping is
/// reclaimed when the process exits.
extern "C" fn ec_thread_terminate(_stackaddr: *mut c_void, _freesize: c_ulong, _pthobj_size: c_ulong) -> c_int {
    unsafe { libc::pthread_exit(ptr::null_mut()) }
}
extern "C" fn ec_thread_get_stack() -> *mut c_void {
    ptr::null_mut()
}
extern "C" fn ec_sem_open(_: *const c_char, _: c_int, _: c_ushort, _: c_uint) -> *mut c_int {
    ptr::null_mut()
}
extern "C" fn ec_sem_wait(_: *mut c_int) -> c_int {
    -1
}
extern "C" fn ec_sem_trywait(_: *mut c_int) -> c_int {
    -1
}
extern "C" fn ec_sem_post(_: *mut c_int) -> c_int {
    -1
}
extern "C" fn ec_sem_close(_: *mut c_int) -> c_int {
    -1
}
extern "C" fn ec_sem_unlink(_: *const c_char) -> c_int {
    -1
}
extern "C" fn ec_shm_open(_: *const c_char, _: c_int, _: c_ushort) -> c_int {
    -1
}
extern "C" fn ec_shm_unlink(_: *const c_char) -> c_int {
    -1
}
extern "C" fn ec_dserver_socket_address() -> *const c_void {
    crate::rpc::server_addr_ptr()
}
extern "C" fn ec_dserver_per_thread_socket() -> c_int {
    crate::rpc::thread_socket()
}
extern "C" fn ec_dserver_per_thread_socket_refresh() {
    // The guest calls this in the forked child (fork.c) to obtain a FRESH RPC socket so the child
    // does not share the parent's -- otherwise the parent's dserver_rpc_fork_wait_for_child races
    // and returns -ECOMM (-70), and __mach_fork_parent executes `ud2` (SIGILL). create_thread_socket
    // binds a new autobound socket, moves it to a high CLOEXEC fd, and stores it as this thread's
    // T_SOCKET. Mirrors C __cider_thread_rpc_socket_refresh (threads.c:397). (This works only
    // because create_thread_socket/reserve_high_cloexec are movaps-free: the guest calls this
    // elfcall on a stack that is misaligned by 8, so any aligned SSE store would #GP -- see
    // reserve_high_cloexec.)
    let fd = unsafe { crate::rpc::create_thread_socket() };
    if fd < 0 {
        unsafe { libc::abort() };
    }
    if crate::rpc::is_main_thread() {
        crate::rpc::set_main_socket(fd);
    }
}
extern "C" fn ec_dserver_close_socket(fd: c_int) {
    // The guest's guard table calls this to close the old RPC socket on fork (fork.c) and on
    // thread teardown. Just close the fd (C __mldr_close_rpc_socket also releases a socket
    // bitmap slot, which mldr has no equivalent of). close() is a raw syscall, so this is
    // fork-safe. Mirrors C __mldr_close_rpc_socket.
    // The guest's guard_table calls this to close the old RPC socket on fork (fork.c) and on
    // thread teardown. Close the fd (C __mldr_close_rpc_socket also releases a socket-bitmap slot,
    // which mldr has no equivalent of). close() is a raw syscall, so this is fork-safe. Without
    // this the forked child leaks the inherited RPC socket fd -- one per fork, which a build's
    // thousands of processes would accumulate.
    if fd >= 0 {
        unsafe { libc::close(fd) };
    }
}
extern "C" fn ec_dserver_get_lifetime_pipe() -> c_int {
    -1
}
extern "C" fn ec_dserver_lifetime_pipe_refresh() -> c_int {
    -1
}
extern "C" fn ec_dserver_close_lifetime_pipe(_: c_int) {}

/// Build a leaked ElfCalls vtable and return its address (for apple[2]=elf_calls=<ptr>).
pub fn make() -> u64 {
    let ec = Box::new(ElfCalls {
        dlopen: ec_dlopen,
        dlclose: ec_dlclose,
        dlsym: ec_dlsym,
        dlerror: ec_dlerror,
        darling_thread_create: crate::threads::darling_thread_create,
        darling_thread_terminate: ec_thread_terminate,
        darling_thread_get_stack: ec_thread_get_stack,
        dlopen_fatal: ec_dlopen_fatal,
        dlclose_fatal: ec_dlclose_fatal,
        dlsym_fatal: ec_dlsym_fatal,
        get_errno: ec_get_errno,
        sem_open: ec_sem_open,
        sem_wait: ec_sem_wait,
        sem_trywait: ec_sem_trywait,
        sem_post: ec_sem_post,
        sem_close: ec_sem_close,
        sem_unlink: ec_sem_unlink,
        shm_open: ec_shm_open,
        shm_unlink: ec_shm_unlink,
        exit: ec_exit,
        malloc: ec_malloc,
        free: ec_free,
        realloc: ec_realloc,
        sysconf: ec_sysconf,
        dserver_socket_address: ec_dserver_socket_address,
        dserver_per_thread_socket: ec_dserver_per_thread_socket,
        dserver_per_thread_socket_refresh: ec_dserver_per_thread_socket_refresh,
        dserver_close_socket: ec_dserver_close_socket,
        dserver_get_process_lifetime_pipe: ec_dserver_get_lifetime_pipe,
        dserver_process_lifetime_pipe_refresh: ec_dserver_lifetime_pipe_refresh,
        dserver_close_process_lifetime_pipe: ec_dserver_close_lifetime_pipe,
    });
    Box::leak(ec) as *const ElfCalls as u64
}
