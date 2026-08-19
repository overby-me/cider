// mldr M3a: the commpage -- a fixed shared page at 0x7fffffe00000 that Darwin's libSystem
// reads for CPU capabilities, CPU counts, page sizes, and memory size. Mirrors
// src/linux/startup/mldr/commpage.c:23-172.
//
// CRITICAL (commpage.c:52-73): the CPU counts must NEVER be 0. A rootless container's mount
// namespace may hide /sys/devices/system/cpu, so _SC_NPROCESSORS_CONF returns 0/-1, and
// libsystem_malloc later divides logical/physical -> SIGFPE at guest startup (the intermittent
// build flake). We fall back CONF -> ONLN (sched_getaffinity) -> 1, and never store 0.
use std::os::raw::c_void;

// The commpage base is per-arch (aarch64 port, task D7): x86_64 maps it at 0x7fffffe00000,
// arm64 macOS at 0xFFFFFC000 (arm/cpu_capabilities.h _COMM_PAGE64_BASE_ADDRESS).
#[cfg(target_arch = "x86_64")]
const COMM_PAGE64_BASE: u64 = 0x0000_7fff_ffe0_0000;
#[cfg(target_arch = "aarch64")]
const COMM_PAGE64_BASE: u64 = 0x0000_000f_ffff_c000;
const COMM_PAGE_LENGTH: usize = 4096;
const COMM_PAGE_THIS_VERSION: u16 = 14;

// Field offsets relative to the page base. Most match between i386/cpu_capabilities.h and
// arm/cpu_capabilities.h; the two page-shift bytes do not (arm64 packs them right after the
// 32-bit caps word, x86 leaves them higher).
const OFF_SIGNATURE: usize = 0x000;
const OFF_CPU_CAPABILITIES64: usize = 0x010;
const OFF_VERSION: usize = 0x01E;
const OFF_CPU_CAPABILITIES: usize = 0x020;
const OFF_NCPUS: usize = 0x022;
const OFF_ACTIVE_CPUS: usize = 0x034;
const OFF_PHYSICAL_CPUS: usize = 0x035;
const OFF_LOGICAL_CPUS: usize = 0x036;
const OFF_MEMORY_SIZE: usize = 0x038;
#[cfg(target_arch = "x86_64")]
const OFF_KERNEL_PAGE_SHIFT: usize = 0x04D;
#[cfg(target_arch = "x86_64")]
const OFF_USER_PAGE_SHIFT_64: usize = 0x04E;
#[cfg(target_arch = "aarch64")]
const OFF_KERNEL_PAGE_SHIFT: usize = 0x037;
#[cfg(target_arch = "aarch64")]
const OFF_USER_PAGE_SHIFT_64: usize = 0x025;

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
        eprintln!("[mldr] commpage mmap failed");
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

/// CPU capability bitmask (commpage.c:97-167). libSystem selects its SIMD code paths
/// (memcpy/memset/... function pointers) from these bits, so a zero here mis-dispatches ->
/// SIGILL. x86 reads cpuid; arm64 reads AT_HWCAP (bit values from arm/cpu_capabilities.h),
/// which is task D7.
#[cfg(target_arch = "aarch64")]
fn cpu_caps() -> u64 {
    // arm/cpu_capabilities.h bit values.
    const K_HAS_NEON_FP16: u64 = 0x0000_0008;
    const K_HAS_NEON: u64 = 0x0000_0100;
    const K_HAS_NEON_HPFP: u64 = 0x0000_0200;
    const K_HAS_VFP: u64 = 0x0000_0400;
    const K_HAS_EVENT: u64 = 0x0000_1000;
    const K_HAS_FMA: u64 = 0x0000_2000;
    const K_HAS_ARMV8_CRYPTO: u64 = 0x0100_0000;
    const K_HAS_ARMV81_ATOMICS: u64 = 0x0200_0000;
    const K_HAS_ARMV8_CRC32: u64 = 0x0400_0000;
    // Linux AT_HWCAP bits (asm/hwcap.h); libc does not export them all, so name them here.
    const HWCAP_FP: u64 = 1 << 0;
    const HWCAP_ASIMD: u64 = 1 << 1;
    const HWCAP_EVTSTRM: u64 = 1 << 2;
    const HWCAP_AES: u64 = 1 << 3;
    const HWCAP_SHA2: u64 = 1 << 6;
    const HWCAP_CRC32: u64 = 1 << 7;
    const HWCAP_ATOMICS: u64 = 1 << 8;
    const HWCAP_FPHP: u64 = 1 << 9;
    const HWCAP_ASIMDHP: u64 = 1 << 10;

    let hwcap = unsafe { libc::getauxval(libc::AT_HWCAP) };
    // NEON and VFP are architectural on arm64; the reference sets them unconditionally.
    let mut caps: u64 = K_HAS_NEON | K_HAS_VFP | K_HAS_FMA;
    if hwcap & HWCAP_ASIMD != 0 {
        caps |= K_HAS_NEON;
    }
    if hwcap & HWCAP_FP != 0 {
        caps |= K_HAS_VFP;
    }
    if hwcap & HWCAP_FPHP != 0 {
        caps |= K_HAS_NEON_FP16;
    }
    if hwcap & HWCAP_ASIMDHP != 0 {
        caps |= K_HAS_NEON_HPFP;
    }
    if hwcap & HWCAP_ATOMICS != 0 {
        caps |= K_HAS_ARMV81_ATOMICS;
    }
    if hwcap & HWCAP_CRC32 != 0 {
        caps |= K_HAS_ARMV8_CRC32;
    }
    if hwcap & (HWCAP_AES | HWCAP_SHA2) != 0 {
        caps |= K_HAS_ARMV8_CRYPTO;
    }
    if hwcap & HWCAP_EVTSTRM != 0 {
        caps |= K_HAS_EVENT;
    }
    let n = cpu_count() as u64;
    caps |= (n << 16) & 0x00FF_0000; // kNumCPUs
    caps
}

#[cfg(target_arch = "x86_64")]
fn cpu_caps() -> u64 {
    use core::arch::x86_64::__cpuid_count;
    let mut caps: u64 = 0;
    unsafe {
        let c1 = __cpuid_count(1, 0);
        if c1.edx & (1 << 23) != 0 {
            caps |= 0x1; // MMX
        }
        if c1.edx & (1 << 25) != 0 {
            caps |= 0x2; // SSE
        }
        if c1.edx & (1 << 26) != 0 {
            caps |= 0x4; // SSE2
        }
        if c1.ecx & (1 << 0) != 0 {
            caps |= 0x8; // SSE3
        }
        if c1.ecx & (1 << 9) != 0 {
            caps |= 0x100; // SupplementalSSE3
        }
        if c1.ecx & (1 << 19) != 0 {
            caps |= 0x400; // SSE4.1
        }
        if c1.ecx & (1 << 20) != 0 {
            caps |= 0x800; // SSE4.2
        }
        if c1.ecx & (1 << 25) != 0 {
            caps |= 0x1000; // AES
        }
        if c1.ecx & (1 << 12) != 0 {
            caps |= 0x1000_0000; // FMA
        }
        if c1.ecx & (1 << 28) != 0 {
            caps |= 0x0100_0000; // AVX
        }
        if c1.ecx & (1 << 29) != 0 {
            caps |= 0x0400_0000; // F16C
        }
        if c1.ecx & (1 << 30) != 0 {
            caps |= 0x0200_0000; // RDRAND
        }
        let c7 = __cpuid_count(7, 0);
        if c7.ebx & (1 << 3) != 0 {
            caps |= 0x4000_0000; // BMI1
        }
        if c7.ebx & (1 << 5) != 0 {
            caps |= 0x2000_0000; // AVX2
        }
        if c7.ebx & (1 << 8) != 0 {
            caps |= 0x8000_0000; // BMI2
        }
    }
    caps |= 0x200; // k64Bit
    caps |= 0x20; // kCache64 (64-byte cache line)
    caps |= 0x80; // kFastThreadLocalStorage (fs/gs base)
    let n = cpu_count() as u64;
    caps |= (n << 16) & 0x00FF_0000; // kNumCPUs
    if n == 1 {
        caps |= 0x8000; // kUP
    }
    caps
}
