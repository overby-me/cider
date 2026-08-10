//! Host information: the Rust replacement for `xnu-sys/src/host.c` (#71, fourth file).
//!
//! These are the XNU `host_*` entry points the MIG server dispatches into when the guest asks
//! the "kernel" about the machine: how much memory, how many CPUs, what the scheduler's
//! priority bands are. `host_info(HOST_BASIC_INFO)` is the one that matters at boot, since
//! that is what `sysctl`, `sw_vers` and the Nix installer end up going through.
//!
//! WHY THIS FILE WAS PICKED, and it was picked by measurement rather than by feel.
//! `scripts/xnu-sys-portability.py` ranks the sixteen glue files, and after it was taught
//! that `xnu_sys_stub`, `xnu_sys_stub_safe` and `xnu_sys_stub_unsafe` are already Rust, this one has
//! exactly ONE unresolved blocker left: `panic`, which `semaphore.rs` already calls as an
//! extern variadic and which gate3 validated. At 245 lines and 12 exports it is also the
//! smallest remaining file.
//!
//! THE RISK HERE IS DIFFERENT FROM THE FIRST THREE, and worth naming. semaphore, condvar and
//! timer fail LOUDLY when they are wrong: a bad offset or a missed wake hangs or crashes.
//! This file hands numbers back to the guest. Get a field wrong and nothing crashes, the guest
//! simply believes the machine has the wrong amount of memory or the wrong CPU count. So every
//! struct here is filled through a BINDGEN type, never through a hand-written offset, and every
//! count comes from `sizeof` evaluated by the C compiler rather than written down. See the
//! `xnu_sys_rs_host_consts` enum in `wrapper.h`.
//!
//! TWO DELIBERATE DEPARTURES FROM THE C, both of which make it more correct rather than less:
//!
//! * `struct sysinfo` is `libc`'s, not a local copy. host.c declares its OWN version of the
//!   Linux struct and then calls the real `sysinfo()` against it. That works only for as long
//!   as the transcription stays right; the fields this code reads (`totalram`, `mem_unit`) sit
//!   at the same offsets in both today. Using `libc::sysinfo` removes the transcription.
//! * `libsimple_once` becomes `std::sync::OnceLock`. Same contract, once and thread-safe, and
//!   it carries the cached value rather than sitting beside a `static mut`.
//!
//! What is NOT reopened: `vm_statistics` and `vm_statistics64` stay opaque in the bindings.
//! `host_statistics` and `vm_stats` only ever zero them and never name a field, so all that is
//! needed is their SIZE, which an opaque binding still carries.

use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::ptr;
use std::sync::OnceLock;

use crate::bindings::{
    cpu_subtype_t, cpu_threadtype_t, cpu_type_t, hash_info_bucket_array_t, host_basic_info,
    host_flavor_t, host_info_t, host_preferred_user_arch, host_priority_info, host_priv_t,
    host_security_t, host_t, integer_t, ledger_port_array_t, lockgroup_info_array_t,
    mach_msg_type_number_t, memory_object_cluster_size_t, memory_object_default_t, natural_t,
    task_t, vm_statistics64, audit_token_t, boolean_t, kern_return_t, security_token_t,
    UNDServerRef, BASEPRI_DEFAULT, DEPRESSPRI, HOST_BASIC_INFO, HOST_CAN_HAS_DEBUGGER,
    HOST_CPU_LOAD_INFO, HOST_DEBUG_INFO_INTERNAL, HOST_MACH_MSG_TRAP, HOST_PREFERRED_USER_ARCH,
    HOST_PRIORITY_INFO, HOST_RESOURCE_SIZES, HOST_SCHED_INFO, HOST_SEMAPHORE_TRAPS, HOST_VM_INFO,
    HOST_VM_PURGABLE, IDLEPRI, KERN_FAILURE, KERN_INVALID_ARGUMENT, KERN_NOT_SUPPORTED,
    KERN_SUCCESS, MAXPRI_RESERVED, MINPRI_KERNEL, MINPRI_RESERVED, MINPRI_USER,
};

// The counts and the CPU identifiers, evaluated by the C compiler from the real macros (see
// the xnu_sys_rs_host_consts enum in wrapper.h). bindgen cannot const-evaluate either
// sizeof(...)/sizeof(integer_t) or ((cpu_type_t) 7), so without that enum these come out
// missing, and the only alternative would be transcribing them here.
use crate::bindings::{
    xnu_sys_rs_host_consts_XNU_SYS_RS_CPU_SUBTYPE_X86_64_ALL as CPU_SUBTYPE_X86_64_ALL,
    xnu_sys_rs_host_consts_XNU_SYS_RS_CPU_THREADTYPE_NONE as CPU_THREADTYPE_NONE,
    xnu_sys_rs_host_consts_XNU_SYS_RS_CPU_TYPE_X86 as CPU_TYPE_X86,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_BASIC_INFO_COUNT as HOST_BASIC_INFO_COUNT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_BASIC_INFO_OLD_COUNT as HOST_BASIC_INFO_OLD_COUNT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_PREFERRED_USER_ARCH_COUNT as HOST_PREFERRED_USER_ARCH_COUNT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_PRIORITY_INFO_COUNT as HOST_PRIORITY_INFO_COUNT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_VM_INFO64_COUNT as HOST_VM_INFO64_COUNT,
    xnu_sys_rs_host_consts_XNU_SYS_RS_HOST_VM_INFO_REV0_COUNT as HOST_VM_INFO_REV0_COUNT,
};

extern "C" {
    // XNU's panic: variadic, and fatal. Called rather than replaced with Rust's panic!, which
    // would unwind across the extern "C" boundary. Same reasoning as semaphore.rs.
    fn panic(format: *const c_char, ...);
}

/// The bindgen constants are `u32`; `kern_return_t` is a C `int`.
const fn kr(value: u32) -> kern_return_t {
    value as kern_return_t
}

/// Cached `sysinfo`, fetched once.
///
/// The C used `libsimple_once` over a file-static struct. `OnceLock` is the same contract and
/// holds the value itself. A failure here is fatal in the C, and stays fatal here.
fn cached_sysinfo() -> &'static libc::sysinfo {
    static CACHED: OnceLock<libc::sysinfo> = OnceLock::new();
    CACHED.get_or_init(|| unsafe {
        let mut info: libc::sysinfo = std::mem::zeroed();
        if libc::sysinfo(&mut info) < 0 {
            panic(b"Failed to retrieve sysinfo\0".as_ptr() as *const c_char);
        }
        info
    })
}

/// `host_info`: what the guest asks about the machine.
///
/// A negative flavor casts to a large `u32` and falls through to the default arm, which is
/// `KERN_INVALID_ARGUMENT`, exactly as the C switch behaved.
#[no_mangle]
pub unsafe extern "C" fn host_info(
    host: host_t,
    flavor: host_flavor_t,
    info: host_info_t,
    count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    // HOST_NULL is ((host_t) 0), a macro bindgen does not bind.
    if host.is_null() {
        return kr(KERN_INVALID_ARGUMENT);
    }

    match flavor as u32 {
        HOST_BASIC_INFO => {
            // Enough room for the LEGACY structure is the entry condition; the modern one is
            // filled only if there is room for it.
            if (*count as u32) < HOST_BASIC_INFO_OLD_COUNT as u32 {
                return kr(KERN_FAILURE);
            }

            let sysinfo = cached_sysinfo();
            let memsize = (sysinfo.totalram as u64).wrapping_mul(sysinfo.mem_unit as u64);

            let basic = info as *mut host_basic_info;
            // memory_size is a natural_t, so this truncates on a machine with more than 4 GB.
            // That is what the C did, and the modern max_mem field below carries the full
            // value, which is where a 64-bit-aware caller reads it.
            (*basic).memory_size = memsize as natural_t;
            (*basic).cpu_type = CPU_TYPE_X86 as cpu_type_t;
            (*basic).cpu_subtype = CPU_SUBTYPE_X86_64_ALL as cpu_subtype_t;
            (*basic).max_cpus = libc::sysconf(libc::_SC_NPROCESSORS_CONF) as integer_t;
            (*basic).avail_cpus = libc::sysconf(libc::_SC_NPROCESSORS_ONLN) as integer_t;

            if (*count as u32) >= HOST_BASIC_INFO_COUNT as u32 {
                // TODO: properly differentiate physical vs. logical cores
                crate::xnu_sys_stub_safe!("modern HOST_BASIC_INFO");
                (*basic).cpu_threadtype = CPU_THREADTYPE_NONE as cpu_threadtype_t;
                (*basic).physical_cpu = (*basic).avail_cpus;
                (*basic).physical_cpu_max = (*basic).max_cpus;
                (*basic).logical_cpu = (*basic).avail_cpus;
                (*basic).logical_cpu_max = (*basic).max_cpus;

                (*basic).max_mem = memsize;

                *count = HOST_BASIC_INFO_COUNT as mach_msg_type_number_t;
            } else {
                *count = HOST_BASIC_INFO_OLD_COUNT as mach_msg_type_number_t;
            }

            kr(KERN_SUCCESS)
        }

        HOST_PRIORITY_INFO => {
            // <copied from="xnu://7195.141.2/osfmk/kern/host.c">
            if (*count as u32) < HOST_PRIORITY_INFO_COUNT as u32 {
                return kr(KERN_FAILURE);
            }

            let priority = info as *mut host_priority_info;

            (*priority).kernel_priority = MINPRI_KERNEL as integer_t;
            (*priority).system_priority = MINPRI_KERNEL as integer_t;
            (*priority).server_priority = MINPRI_RESERVED as integer_t;
            (*priority).user_priority = BASEPRI_DEFAULT as integer_t;
            (*priority).depress_priority = DEPRESSPRI as integer_t;
            (*priority).idle_priority = IDLEPRI as integer_t;
            (*priority).minimum_priority = MINPRI_USER as integer_t;
            (*priority).maximum_priority = MAXPRI_RESERVED as integer_t;

            *count = HOST_PRIORITY_INFO_COUNT as mach_msg_type_number_t;

            kr(KERN_SUCCESS)
            // </copied>
        }

        HOST_DEBUG_INFO_INTERNAL => kr(KERN_NOT_SUPPORTED),

        HOST_PREFERRED_USER_ARCH => {
            if (*count as u32) < HOST_PREFERRED_USER_ARCH_COUNT as u32 {
                return kr(KERN_FAILURE);
            }

            *count = HOST_PREFERRED_USER_ARCH_COUNT as mach_msg_type_number_t;

            let user_arch = info as *mut host_preferred_user_arch;
            (*user_arch).cpu_type = CPU_TYPE_X86 as cpu_type_t;
            (*user_arch).cpu_subtype = CPU_SUBTYPE_X86_64_ALL as cpu_subtype_t;

            kr(KERN_SUCCESS)
        }

        HOST_SCHED_INFO => crate::xnu_sys_stub_unsafe!("HOST_SCHED_INFO"),
        HOST_RESOURCE_SIZES => crate::xnu_sys_stub_unsafe!("HOST_RESOURCE_SIZES"),
        HOST_CAN_HAS_DEBUGGER => crate::xnu_sys_stub_unsafe!("HOST_CAN_HAS_DEBUGGER"),
        HOST_VM_PURGABLE => crate::xnu_sys_stub_unsafe!("HOST_VM_PURGABLE"),

        // Both are "how many of these traps do you have", and the answer is none.
        HOST_MACH_MSG_TRAP | HOST_SEMAPHORE_TRAPS => {
            *count = 0;
            kr(KERN_SUCCESS)
        }

        _ => kr(KERN_INVALID_ARGUMENT),
    }
}

/// `host_statistics`: counters rather than configuration. Zeroed rather than invented.
#[no_mangle]
pub unsafe extern "C" fn host_statistics(
    _host: host_t,
    flavor: host_flavor_t,
    info: host_info_t,
    count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    match flavor as u32 {
        // we can get away with not implementing it
        HOST_VM_INFO => {
            if (*count as u32) < HOST_VM_INFO_REV0_COUNT as u32 {
                return kr(KERN_FAILURE);
            }

            crate::xnu_sys_stub_safe!("HOST_VM_INFO");
            // The C zeroes (*count) * sizeof(integer_t), which is the CALLER's buffer length,
            // not the struct size. Kept exactly: the caller may have asked for a revision
            // longer or shorter than the one this build knows about.
            ptr::write_bytes(
                info as *mut u8,
                0,
                (*count as usize) * std::mem::size_of::<integer_t>(),
            );

            kr(KERN_SUCCESS)
        }

        HOST_CPU_LOAD_INFO => {
            crate::xnu_sys_stub_safe!("HOST_CPU_LOAD_INFO");
            kr(KERN_INVALID_ARGUMENT)
        }

        _ => crate::xnu_sys_stub_unsafe!(),
    }
}

/// `vm_stats`: the 64-bit VM counters. Zeroed, and the size comes from the opaque binding.
#[no_mangle]
pub unsafe extern "C" fn vm_stats(info: *mut c_void, count: *mut c_uint) -> kern_return_t {
    if (*count as u32) < HOST_VM_INFO64_COUNT as u32 {
        return kr(KERN_FAILURE);
    }

    // sizeof(*stat), the STRUCT size here rather than the caller's count. vm_statistics64 is
    // opaque in the bindings, which still carries its size and is all this needs.
    ptr::write_bytes(info as *mut u8, 0, std::mem::size_of::<vm_statistics64>());

    crate::xnu_sys_stub!("TODO: actually fill in the values with something useful");

    *count = HOST_VM_INFO64_COUNT as c_uint;

    kr(KERN_SUCCESS)
}

// The rest of the file is unimplemented XNU entry points. Their bodies never read their
// arguments, but the signatures are still written in the GENERATED types rather than in
// convenient placeholders: security_token_t is 8 bytes and passes in a register while
// audit_token_t is 32 and passes in memory, and those are precisely the shapes that go wrong
// quietly when transcribed.

#[no_mangle]
pub unsafe extern "C" fn host_default_memory_manager(
    _host_priv: host_priv_t,
    _default_manager: *mut memory_object_default_t,
    _cluster_size: memory_object_cluster_size_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn host_get_boot_info(
    _host_priv: host_priv_t,
    // kernel_boot_info_t is an ARRAY typedef, and an array parameter decays to a pointer in C.
    _boot_info: *mut c_char,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn host_get_UNDServer(
    _host_priv: host_priv_t,
    _serverp: *mut UNDServerRef,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn host_set_UNDServer(
    _host_priv: host_priv_t,
    _server: UNDServerRef,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn host_lockgroup_info(
    _host: host_t,
    _lockgroup_infop: *mut lockgroup_info_array_t,
    _lockgroup_infoCntp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn host_reboot(_host_priv: host_priv_t, _options: c_int) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

/// The one stub that RETURNS rather than aborting, because the guest asks for this on a normal
/// path and a hard failure there would be worse than a refusal.
#[no_mangle]
pub unsafe extern "C" fn host_security_create_task_token(
    _host_security: host_security_t,
    _parent_task: task_t,
    _sec_token: security_token_t,
    _audit_token: audit_token_t,
    _host_priv: host_priv_t,
    _ledger_ports: ledger_port_array_t,
    _num_ledger_ports: mach_msg_type_number_t,
    _inherit_memory: boolean_t,
    _child_task: *mut task_t,
) -> kern_return_t {
    crate::xnu_sys_stub_safe!();
    kr(KERN_NOT_SUPPORTED)
}

#[no_mangle]
pub unsafe extern "C" fn host_security_set_task_token(
    _host_security: host_security_t,
    _task: task_t,
    _sec_token: security_token_t,
    _audit_token: audit_token_t,
    _host_priv: host_priv_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn host_virtual_physical_table_info(
    _host: host_t,
    _infop: *mut hash_info_bucket_array_t,
    _countp: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::xnu_sys_stub_unsafe!()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The counts must be what XNU computes from the struct, not what anyone typed. If these
    /// ever disagree, the enum in wrapper.h has stopped tracking the structs and every reply
    /// this file sends is a wrong length.
    #[test]
    fn counts_match_the_structs_they_describe() {
        let words = |bytes: usize| (bytes / std::mem::size_of::<integer_t>()) as u32;
        assert_eq!(
            HOST_BASIC_INFO_COUNT as u32,
            words(std::mem::size_of::<host_basic_info>()),
            "HOST_BASIC_INFO_COUNT no longer describes host_basic_info"
        );
        assert_eq!(
            HOST_PRIORITY_INFO_COUNT as u32,
            words(std::mem::size_of::<host_priority_info>()),
            "HOST_PRIORITY_INFO_COUNT no longer describes host_priority_info"
        );
        assert_eq!(
            HOST_PREFERRED_USER_ARCH_COUNT as u32,
            words(std::mem::size_of::<host_preferred_user_arch>()),
            "HOST_PREFERRED_USER_ARCH_COUNT no longer describes host_preferred_user_arch"
        );
        assert_eq!(
            HOST_VM_INFO64_COUNT as u32,
            words(std::mem::size_of::<vm_statistics64>()),
            "HOST_VM_INFO64_COUNT no longer describes vm_statistics64"
        );
    }

    /// The legacy count has to be SHORTER than the modern one, since the whole
    /// HOST_BASIC_INFO path branches on that. Equal counts would silently mean the modern
    /// fields are never filled.
    #[test]
    fn the_legacy_basic_info_is_shorter_than_the_modern_one() {
        assert!(
            (HOST_BASIC_INFO_OLD_COUNT as u32) < (HOST_BASIC_INFO_COUNT as u32),
            "old {} is not shorter than modern {}",
            HOST_BASIC_INFO_OLD_COUNT as u32,
            HOST_BASIC_INFO_COUNT as u32
        );
    }

    /// A null host is rejected before anything is written. Checked with a deliberately
    /// undersized count so that, if the null check ever goes missing, the call would fall into
    /// the HOST_BASIC_INFO arm and be caught by KERN_FAILURE rather than passing by accident.
    #[test]
    fn a_null_host_is_invalid_rather_than_a_null_dereference() {
        let mut count: mach_msg_type_number_t = 0;
        let rc = unsafe {
            host_info(
                ptr::null_mut(),
                HOST_BASIC_INFO as host_flavor_t,
                ptr::null_mut(),
                &mut count,
            )
        };
        assert_eq!(rc, kr(KERN_INVALID_ARGUMENT));
        assert_eq!(count, 0, "a rejected call must not write through count");
    }

    /// HOST_BASIC_INFO with a real buffer: the modern branch fills every field and reports the
    /// modern length. This is the reply the guest actually reads at boot.
    #[test]
    fn basic_info_fills_the_modern_structure() {
        let mut storage = [0i32; 64];
        let mut count: mach_msg_type_number_t = HOST_BASIC_INFO_COUNT as mach_msg_type_number_t;
        // A non-null host: nothing is dereferenced through it, only checked against null.
        let host = 1usize as host_t;
        let rc = unsafe {
            host_info(
                host,
                HOST_BASIC_INFO as host_flavor_t,
                storage.as_mut_ptr(),
                &mut count,
            )
        };
        assert_eq!(rc, kr(KERN_SUCCESS));
        assert_eq!(count, HOST_BASIC_INFO_COUNT as mach_msg_type_number_t);

        let basic = storage.as_ptr() as *const host_basic_info;
        unsafe {
            assert!((*basic).max_cpus > 0, "max_cpus should be a real CPU count");
            assert!((*basic).avail_cpus > 0, "avail_cpus should be a real CPU count");
            assert_eq!((*basic).cpu_type, CPU_TYPE_X86 as cpu_type_t);
            assert!((*basic).max_mem > 0, "max_mem should be a real memory size");
            // The modern fields mirror the legacy ones on this build.
            assert_eq!((*basic).logical_cpu, (*basic).avail_cpus);
            assert_eq!((*basic).logical_cpu_max, (*basic).max_cpus);
        }
    }

    /// A buffer too short even for the legacy structure is refused rather than overrun.
    #[test]
    fn basic_info_refuses_a_buffer_it_would_overrun() {
        let mut storage = [0i32; 64];
        let mut count: mach_msg_type_number_t =
            (HOST_BASIC_INFO_OLD_COUNT as mach_msg_type_number_t) - 1;
        let rc = unsafe {
            host_info(
                1usize as host_t,
                HOST_BASIC_INFO as host_flavor_t,
                storage.as_mut_ptr(),
                &mut count,
            )
        };
        assert_eq!(rc, kr(KERN_FAILURE));
        assert!(
            storage.iter().all(|&w| w == 0),
            "a refused call must not have written into the buffer"
        );
    }

    /// An unknown flavor, and a negative one, both come back invalid rather than matching an
    /// arm by accident once the signed flavor is widened to unsigned.
    #[test]
    fn unknown_and_negative_flavors_are_invalid() {
        let mut count: mach_msg_type_number_t = 32;
        for flavor in [9999 as host_flavor_t, -1 as host_flavor_t] {
            let rc = unsafe {
                host_info(1usize as host_t, flavor, ptr::null_mut(), &mut count)
            };
            assert_eq!(rc, kr(KERN_INVALID_ARGUMENT), "flavor {flavor} should be invalid");
        }
    }
}
