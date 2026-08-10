//! Runtime exercise of the ported xnu-sys host info (#71).
//!
//! WHY THIS EXISTS, and why it does not simply assert that the code ran. The first three
//! ported files fail LOUDLY when they are wrong: a bad offset or a lost queue link hangs or
//! crashes, so `scheduler_demo` and `condvar_demo` finishing at all is most of the proof.
//! host.c is the opposite. It hands NUMBERS back to the guest, and a wrong field offset or a
//! truncated count does not crash anything: the guest simply believes the machine has the
//! wrong amount of memory or the wrong number of CPUs. Nix, for one, sizes its build
//! parallelism from exactly these values.
//!
//! So this checks the answers against an INDEPENDENT source rather than against the code that
//! produced them. `host_info` reaches the numbers through `sysinfo(2)` and `sysconf(3)`;
//! this reads `/proc/meminfo` and `/proc/cpuinfo`, which share no code path with either. A
//! field written to the wrong offset shows up here as a wrong number, which is the whole
//! point: comparing sysconf against sysconf would agree with itself no matter how wrong the
//! struct layout was.
//!
//! It also drives the two refusal paths, since a guard that never runs is a guard nobody knows
//! is broken: a buffer too short for even the legacy structure, and an unrecognised flavor.
//!
//! The verdict is the printed line rather than the exit code, matching the other demos.

use cider::bindings::{
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_BASIC_INFO_COUNT as HOST_BASIC_INFO_COUNT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_BASIC_INFO_OLD_COUNT as HOST_BASIC_INFO_OLD_COUNT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_PRIORITY_INFO_COUNT as HOST_PRIORITY_INFO_COUNT,
    host_basic_info, host_flavor_t, host_priority_info, host_t, mach_msg_type_number_t,
    BASEPRI_DEFAULT, HOST_BASIC_INFO, HOST_PRIORITY_INFO, KERN_FAILURE, KERN_INVALID_ARGUMENT,
    KERN_SUCCESS, MINPRI_KERNEL,
};
use cider::xnu::host::{host_info, host_statistics};

/// MemTotal from /proc/meminfo, in bytes. Nothing to do with sysinfo(2).
fn meminfo_total_bytes() -> u64 {
    let text = std::fs::read_to_string("/proc/meminfo").expect("/proc/meminfo");
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            let kb: u64 = rest
                .trim()
                .trim_end_matches(" kB")
                .trim()
                .parse()
                .expect("MemTotal value");
            return kb * 1024;
        }
    }
    panic!("no MemTotal in /proc/meminfo");
}

/// Online CPUs, counted from /proc/cpuinfo. Nothing to do with sysconf(3).
fn cpuinfo_online_cpus() -> i32 {
    let text = std::fs::read_to_string("/proc/cpuinfo").expect("/proc/cpuinfo");
    text.lines()
        .filter(|l| l.starts_with("processor") && l.contains(':'))
        .count() as i32
}

fn main() {
    // Not a real host struct: host_info only checks it against null, never dereferences it.
    let host = 1usize as host_t;
    let mut failures: Vec<String> = Vec::new();
    let mut check = |ok: bool, what: String| {
        if !ok {
            failures.push(what);
        }
    };

    // ---- HOST_BASIC_INFO, the reply the guest reads at boot ----
    let mut storage = [0i32; 64];
    let mut count: mach_msg_type_number_t = HOST_BASIC_INFO_COUNT as mach_msg_type_number_t;
    let rc = unsafe {
        host_info(
            host,
            HOST_BASIC_INFO as host_flavor_t,
            storage.as_mut_ptr(),
            &mut count,
        )
    };
    check(rc == KERN_SUCCESS as i32, format!("HOST_BASIC_INFO returned {rc}"));
    check(
        count == HOST_BASIC_INFO_COUNT as mach_msg_type_number_t,
        format!("count {count} is not the modern {}", HOST_BASIC_INFO_COUNT as u32),
    );

    let basic = unsafe { *(storage.as_ptr() as *const host_basic_info) };
    // host_basic_info is PACKED (XNU packs mach/host_info.h to 4 bytes, so the 64-bit max_mem
    // sits unaligned). Reading a packed field is fine, but taking a REFERENCE to one is
    // undefined behaviour and rustc rejects it -- and format! takes references. So every field
    // is copied out once, here, and only the copies are used below.
    let max_cpus = basic.max_cpus;
    let avail_cpus = basic.avail_cpus;
    let memory_size = basic.memory_size;
    let max_mem = basic.max_mem;
    let cpu_type = basic.cpu_type;
    let cpu_subtype = basic.cpu_subtype;
    let logical_cpu = basic.logical_cpu;
    let logical_cpu_max = basic.logical_cpu_max;

    let expect_cpus = cpuinfo_online_cpus();
    let expect_mem = meminfo_total_bytes();

    println!(
        "  host_basic_info: max_cpus={max_cpus} avail_cpus={avail_cpus} \
         memory_size={memory_size} max_mem={max_mem} cpu_type={cpu_type} subtype={cpu_subtype}"
    );
    println!("  /proc says:      cpus={expect_cpus} memtotal={expect_mem}");

    check(
        avail_cpus == expect_cpus,
        format!("avail_cpus {avail_cpus} but /proc/cpuinfo has {expect_cpus}"),
    );
    check(
        max_cpus >= expect_cpus,
        format!("max_cpus {max_cpus} is below the online count {expect_cpus}"),
    );
    // sysinfo totalram and MemTotal are the same quantity, but they are sampled separately and
    // rounded differently, so this allows one percent rather than demanding equality.
    let delta = max_mem.abs_diff(expect_mem);
    check(
        delta * 100 < expect_mem,
        format!("max_mem {max_mem} is not within one percent of MemTotal {expect_mem}"),
    );
    check(
        logical_cpu == avail_cpus && logical_cpu_max == max_cpus,
        "the modern cpu fields do not mirror the legacy ones".to_string(),
    );

    // ---- HOST_PRIORITY_INFO, copied from XNU ----
    let mut pstorage = [0i32; 32];
    let mut pcount: mach_msg_type_number_t = HOST_PRIORITY_INFO_COUNT as mach_msg_type_number_t;
    let rc = unsafe {
        host_info(
            host,
            HOST_PRIORITY_INFO as host_flavor_t,
            pstorage.as_mut_ptr(),
            &mut pcount,
        )
    };
    check(rc == KERN_SUCCESS as i32, format!("HOST_PRIORITY_INFO returned {rc}"));
    let prio = unsafe { *(pstorage.as_ptr() as *const host_priority_info) };
    // Copied out for the same packed-field reason as host_basic_info above.
    let kernel_priority = prio.kernel_priority;
    let user_priority = prio.user_priority;
    let maximum_priority = prio.maximum_priority;
    println!(
        "  host_priority_info: kernel={kernel_priority} user={user_priority} \
         maximum={maximum_priority}"
    );
    check(
        kernel_priority == MINPRI_KERNEL as i32,
        format!("kernel_priority {kernel_priority} is not MINPRI_KERNEL"),
    );
    check(
        user_priority == BASEPRI_DEFAULT as i32,
        format!("user_priority {user_priority} is not BASEPRI_DEFAULT"),
    );

    // ---- the refusal paths, which a passing run would otherwise never touch ----
    let mut scratch = [0i32; 64];
    let mut short: mach_msg_type_number_t =
        (HOST_BASIC_INFO_OLD_COUNT as mach_msg_type_number_t) - 1;
    let rc = unsafe {
        host_info(
            host,
            HOST_BASIC_INFO as host_flavor_t,
            scratch.as_mut_ptr(),
            &mut short,
        )
    };
    check(
        rc == KERN_FAILURE as i32,
        format!("a too-short buffer returned {rc} rather than KERN_FAILURE"),
    );
    check(
        scratch.iter().all(|&w| w == 0),
        "a refused call wrote into the buffer anyway".to_string(),
    );

    let mut c: mach_msg_type_number_t = 32;
    let rc = unsafe { host_info(host, 9999, std::ptr::null_mut(), &mut c) };
    check(
        rc == KERN_INVALID_ARGUMENT as i32,
        format!("an unknown flavor returned {rc}"),
    );
    let rc = unsafe { host_info(std::ptr::null_mut(), HOST_BASIC_INFO as host_flavor_t, std::ptr::null_mut(), &mut c) };
    check(
        rc == KERN_INVALID_ARGUMENT as i32,
        format!("a null host returned {rc}"),
    );

    // ---- host_statistics zeroes rather than inventing ----
    let mut vmbuf = [0x5a5a5a5ai32; 64];
    let mut vmcount: mach_msg_type_number_t = 16;
    let rc = unsafe {
        host_statistics(
            host,
            cider::bindings::HOST_VM_INFO as host_flavor_t,
            vmbuf.as_mut_ptr(),
            &mut vmcount,
        )
    };
    check(rc == KERN_SUCCESS as i32, format!("HOST_VM_INFO returned {rc}"));
    check(
        vmbuf[..16].iter().all(|&w| w == 0),
        "HOST_VM_INFO did not zero the caller buffer".to_string(),
    );
    check(
        vmbuf[16] == 0x5a5a5a5a,
        "HOST_VM_INFO zeroed PAST the count it was given".to_string(),
    );

    // ---- processor.c, the same numbers question one level down ----
    // xnu_sys_processor_init has already run (sched init calls it), so processor_array, pset0
    // and master_processor are populated. PROCESSOR_SET_BASIC_INFO reports the CPU count, which
    // is checked against /proc/cpuinfo exactly as the host one was.
    let mut psbuf = [0i32; 32];
    let mut pscount: mach_msg_type_number_t = 8;
    let mut host_out: host_t = std::ptr::null_mut();
    let rc = unsafe {
        cider::xnu::processor::processor_set_info(
            cider::xnu::processor::pset0_for_test(),
            cider::bindings::PROCESSOR_SET_BASIC_INFO as i32,
            &mut host_out,
            psbuf.as_mut_ptr(),
            &mut pscount,
        )
    };
    check(rc == KERN_SUCCESS as i32, format!("PROCESSOR_SET_BASIC_INFO returned {rc}"));
    let psbasic = unsafe { *(psbuf.as_ptr() as *const cider::bindings::processor_set_basic_info) };
    let pcount = psbasic.processor_count;
    let dpolicy = psbasic.default_policy;
    println!("  processor_set_basic_info: processor_count={pcount} default_policy={dpolicy}");
    check(
        pcount == expect_cpus,
        format!("processor_count {pcount} but /proc/cpuinfo has {expect_cpus}"),
    );
    check(
        !host_out.is_null(),
        "processor_set_info did not hand back a host".to_string(),
    );
    // A short buffer is refused rather than overrun, same guard as the host side.
    let mut tiny: mach_msg_type_number_t = 0;
    let rc = unsafe {
        cider::xnu::processor::processor_set_info(
            cider::xnu::processor::pset0_for_test(),
            cider::bindings::PROCESSOR_SET_BASIC_INFO as i32,
            &mut host_out,
            psbuf.as_mut_ptr(),
            &mut tiny,
        )
    };
    check(
        rc == KERN_FAILURE as i32,
        format!("a zero-length processor_set_info returned {rc}"),
    );

    if failures.is_empty() {
        println!("HOST_DEMO_OK");
    } else {
        for f in &failures {
            println!("  FAIL: {f}");
        }
        println!("HOST_DEMO_FAILED: {} check(s)", failures.len());
    }
}
