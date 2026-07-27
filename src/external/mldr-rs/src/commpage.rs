// mldr M3a: the commpage -- a fixed shared page at 0x7fffffe00000 that Darwin's libSystem
// reads for CPU capabilities, CPU counts, page sizes, and memory size. Mirrors
// src/startup/mldr/commpage.c:23-172.
//
// CRITICAL (commpage.c:52-73): the CPU counts must NEVER be 0. A rootless container's mount
// namespace may hide /sys/devices/system/cpu, so _SC_NPROCESSORS_CONF returns 0/-1, and
// libsystem_malloc later divides logical/physical -> SIGFPE at guest startup (the intermittent
// build flake). We fall back CONF -> ONLN (sched_getaffinity) -> 1, and never store 0.
use std::os::raw::c_void;

const COMM_PAGE64_BASE: u64 = 0x0000_7fff_ffe0_0000;
const COMM_PAGE_LENGTH: usize = 4096;
const COMM_PAGE_THIS_VERSION: u16 = 14;

// Field offsets relative to the page base (i386/cpu_capabilities.h).
const OFF_SIGNATURE: usize = 0x000;
const OFF_CPU_CAPABILITIES64: usize = 0x010;
const OFF_VERSION: usize = 0x01E;
const OFF_CPU_CAPABILITIES: usize = 0x020;
const OFF_NCPUS: usize = 0x022;
const OFF_ACTIVE_CPUS: usize = 0x034;
const OFF_PHYSICAL_CPUS: usize = 0x035;
const OFF_LOGICAL_CPUS: usize = 0x036;
const OFF_MEMORY_SIZE: usize = 0x038;
const OFF_KERNEL_PAGE_SHIFT: usize = 0x04D;
const OFF_USER_PAGE_SHIFT_64: usize = 0x04E;

unsafe fn put<T>(base: *mut u8, off: usize, val: T) {
    std::ptr::write_unaligned(base.add(off) as *mut T, val);
}

/// Map + populate the commpage. Returns its base address (== COMM_PAGE64_BASE).
pub unsafe fn setup() -> *mut u8 {
    // Not MAP_FIXED -- relies on the address being free (commpage.c:36-42).
    let p = libc::mmap(
        COMM_PAGE64_BASE as *mut c_void,
        COMM_PAGE_LENGTH,
        libc::PROT_READ | libc::PROT_WRITE,
        libc::MAP_ANONYMOUS | libc::MAP_PRIVATE,
        -1,
        0,
    );
    if p == libc::MAP_FAILED {
        eprintln!("[mldr-rs] commpage mmap failed");
        std::process::exit(1);
    }
    let base = p as *mut u8;

    let sig = b"commpage 64-bit\0";
    std::ptr::copy_nonoverlapping(sig.as_ptr(), base.add(OFF_SIGNATURE), sig.len());
    put::<u16>(base, OFF_VERSION, COMM_PAGE_THIS_VERSION);

    let caps = cpu_caps();
    put::<u64>(base, OFF_CPU_CAPABILITIES64, caps);
    put::<u32>(base, OFF_CPU_CAPABILITIES, caps as u32);

    // CPU counts -- never 0 (the SIGFPE fix).
    let ncpu = cpu_count();
    put::<u8>(base, OFF_NCPUS, ncpu);
    put::<u8>(base, OFF_ACTIVE_CPUS, ncpu);
    put::<u8>(base, OFF_PHYSICAL_CPUS, ncpu);
    put::<u8>(base, OFF_LOGICAL_CPUS, ncpu);

    let pshift = page_shift();
    put::<u8>(base, OFF_KERNEL_PAGE_SHIFT, pshift);
    put::<u8>(base, OFF_USER_PAGE_SHIFT_64, pshift);

    put::<u64>(base, OFF_MEMORY_SIZE, memory_size());

    base
}

/// CPU count that is never 0 (commpage.c:52-73).
fn cpu_count() -> u8 {
    let conf = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_CONF) };
    if conf > 0 {
        return conf.min(255) as u8;
    }
    let onln = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) };
    if onln > 0 {
        return onln.min(255) as u8;
    }
    1
}

fn page_shift() -> u8 {
    let ps = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if ps <= 0 {
        12 // 4096
    } else {
        (ps as u64).trailing_zeros() as u8
    }
}

fn memory_size() -> u64 {
    let mut info: libc::sysinfo = unsafe { std::mem::zeroed() };
    if unsafe { libc::sysinfo(&mut info) } == 0 {
        info.totalram as u64 * info.mem_unit as u64
    } else {
        0
    }
}

/// TODO(M3a-refine): full cpuid parse per commpage.c:97-167 (kHasSSE.., k64Bit, kUP, ..).
/// The counts above are what caused the SIGFPE; the capability bits affect libSystem's
/// SIMD path selection and must be filled from cpu_capabilities.h before running a guest.
fn cpu_caps() -> u64 {
    0
}
