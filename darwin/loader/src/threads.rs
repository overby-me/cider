// mldr thread bridge: cider_thread_create (elfcalls) -- create a Darwin thread on a native
// pthread, per src/startup/mldr/elfcalls/threads.c:145-325. The native pthread's entry sets up
// the thread's per-thread RPC socket, checks in, sets the Darwin TSD base (via the guest's
// callbacks), fetches the mach thread-self port, then switches to the Darwin stack and jumps to
// the real entry with the exact Darwin thread-start register ABI. Register-exact + ABI-frozen;
// the _dthread tsd offset (224) was probed from dthreads.h.
use std::os::raw::{c_int, c_uint, c_ulong, c_void};

const TSD_OFFSET: usize = 224; // offsetof(struct _dthread, tsd), probed
const TSD_SLOT_MACH_THREAD_SELF: usize = 3;
const DTHREAD_START_TSD_BASE_SET: usize = 0x1000_0000;
const DWQ_FLAG_THREAD_TSD_BASE_SET: usize = 0x0020_0000;
const GUARD_SIZE: usize = 0x4000;

/// The guest-provided thread-create callbacks (elfcalls.h cider_thread_create_callbacks).
#[repr(C)]
struct Callbacks {
    thread_self_trap: extern "C" fn() -> c_uint,
    thread_set_tsd_base: extern "C" fn(*mut c_void, c_int),
    rpc_guard: extern "C" fn(c_int),
    rpc_unguard: extern "C" fn(c_int),
}

/// Arguments passed from create() to the native-pthread entry (our own layout).
struct ArgStruct {
    entry_point: usize,
    real_entry_point: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    port: c_int,
    pth: *mut c_void,
    callbacks: *const Callbacks,
    stack_addr: usize,
    stack_bottom: usize,
    is_workqueue: bool,
}

fn align_16(p: usize) -> usize {
    p & !0xf
}

/// Allocate a guard page + stack + dthread block (threads.c:116-143). Returns (dthread, stack_top).
unsafe fn dthread_structure_allocate(stack_size: usize) -> (*mut c_void, usize) {
    // dthread size = tsd offset + a generous tsd array (only used for allocated/workqueue threads).
    let dthread_size = TSD_OFFSET + 512 * std::mem::size_of::<usize>();
    let total = GUARD_SIZE + stack_size + dthread_size;
    let base = libc::mmap(
        std::ptr::null_mut(),
        total,
        libc::PROT_READ | libc::PROT_WRITE,
        libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
        -1,
        0,
    );
    if base == libc::MAP_FAILED {
        return (std::ptr::null_mut(), 0);
    }
    libc::mprotect(base, GUARD_SIZE, libc::PROT_NONE);
    let stack_top = base as usize + stack_size + GUARD_SIZE;
    let dthread = stack_top as *mut c_void;
    std::ptr::write_bytes(dthread as *mut u8, 0, dthread_size);
    (dthread, stack_top)
}

/// elfcalls cider_thread_create (threads.c:145-203).
pub extern "C" fn cider_thread_create(
    stack_size: c_ulong,
    _pth_obj_size: c_ulong,
    entry_point: *mut c_void,
    real_entry_point: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    callbacks: *const c_void,
    pth: *mut c_void,
) -> *mut c_void {
    let is_workqueue = real_entry_point == 0;
    if std::env::var_os("MLDR_DEBUG").is_some() {
        eprintln!("[mldr] thread_create wq={is_workqueue} stack_size={stack_size:#x} entry={entry_point:?} real={real_entry_point:#x}");
    }
    let ssize = stack_size as usize;

    let (pth, stack_addr) = if pth.is_null() || is_workqueue {
        unsafe { dthread_structure_allocate(ssize) }
    } else {
        // arg2 is the stack address for normal threads.
        (pth, arg2)
    };
    if pth.is_null() {
        return std::ptr::null_mut();
    }

    let mut args = ArgStruct {
        entry_point: entry_point as usize,
        real_entry_point,
        arg1,
        arg2,
        arg3,
        port: 0,
        pth,
        callbacks: callbacks as *const Callbacks,
        stack_addr,
        stack_bottom: stack_addr.wrapping_sub(ssize),
        is_workqueue,
    };

    // Native pthread with a tiny stack (we switch to the Darwin stack ourselves).
    let mut attr: libc::pthread_attr_t = unsafe { std::mem::zeroed() };
    let mut tid: libc::pthread_t = 0;
    unsafe {
        libc::pthread_attr_init(&mut attr);
        libc::pthread_attr_setstacksize(&mut attr, 4096);
        libc::pthread_create(
            &mut tid,
            &attr,
            cider_thread_entry,
            &mut args as *mut ArgStruct as *mut c_void,
        );
        libc::pthread_attr_destroy(&mut attr);
    }

    // Wait until the child has copied args + cleared pth (threads.c:199-200).
    while !unsafe { std::ptr::read_volatile(&args.pth) }.is_null() {
        unsafe { libc::sched_yield() };
    }
    pth
}

/// The native-pthread entry (threads.c:205-325). Never returns -- switches to the Darwin stack.
extern "C" fn cider_thread_entry(p: *mut c_void) -> *mut c_void {
    let in_args = p as *mut ArgStruct;
    // Copy args locally, then signal the parent by clearing in_args->pth.
    let mut args = unsafe { std::ptr::read(in_args) };
    let cb = unsafe { &*args.callbacks };

    // Per-thread RPC socket + guard.
    let new_fd = unsafe { crate::rpc::create_thread_socket() };
    if new_fd < 0 {
        unsafe { libc::abort() };
    }
    (cb.rpc_guard)(new_fd);

    // Set the Darwin TSD base = &dthread->tsd[0], then flag it on the arg passed to the entry.
    let dthread = args.pth as *mut u8;
    let tsd_base = unsafe { dthread.add(TSD_OFFSET) } as *mut c_void;
    (cb.thread_set_tsd_base)(tsd_base, 0);
    if args.is_workqueue {
        args.arg2 |= DWQ_FLAG_THREAD_TSD_BASE_SET;
    } else {
        args.arg3 |= DTHREAD_START_TSD_BASE_SET;
    }

    // Check in with ciderd on this thread's socket.
    let dummy = 0i32;
    if unsafe { crate::rpc::checkin_thread(new_fd, &dummy as *const _ as u64) } < 0 {
        unsafe { libc::abort() };
    }

    if std::env::var_os("MLDR_DEBUG").is_some() {
        eprintln!("[mldr] thread checked in fd={new_fd}");
    }
    // Mach thread-self port -> tsd[3].
    let port = (cb.thread_self_trap)() as c_int;
    unsafe {
        *(dthread.add(TSD_OFFSET + TSD_SLOT_MACH_THREAD_SELF * 8) as *mut usize) = port as usize;
    }
    args.port = port;

    // Signal the parent that setup is done.
    unsafe { std::ptr::write_volatile(&mut (*in_args).pth, std::ptr::null_mut()) };

    if std::env::var_os("MLDR_DEBUG").is_some() {
        eprintln!(
            "[mldr] thread jump entry={:#x} sp={:#x} port={} pth={:?}",
            args.entry_point, align_16(args.stack_addr), port, args.pth
        );
    }
    // Switch to the Darwin stack + jump to the entry with the exact register ABI
    // (threads.c:262-323). No function calls past this point.
    let stack_ptr = align_16(args.stack_addr);
    let rdx = if args.real_entry_point == 0 {
        args.stack_bottom
    } else {
        args.real_entry_point
    };
    unsafe {
        core::arch::asm!(
            "xor rbp, rbp",
            "mov rsp, {stack}",
            "push 0",
            "jmp {entry}",
            stack = in(reg) stack_ptr,
            entry = in(reg) args.entry_point,
            in("rdi") args.pth,
            in("esi") port,
            in("rdx") rdx,
            in("rcx") args.arg1,
            in("r8") args.arg2,
            in("r9") args.arg3,
            options(noreturn),
        );
    }
}
