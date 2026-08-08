//! Processors and processor sets: the Rust replacement for `duct-tape/src/processor.c`
//! (#71, fifth file).
//!
//! What the guest asks through these: how many CPUs there are, what scheduling policies exist,
//! and what the load is. `processor_set_info(PROCESSOR_SET_BASIC_INFO)` and
//! `processor_info(PROCESSOR_BASIC_INFO)` are the ones that matter, and like `host.c` they are
//! answered with NUMBERS, so the same rule applies: every struct is filled through a bindgen
//! type and every count is a `sizeof` the C compiler evaluated, never a transcribed constant.
//!
//! WHY THIS FILE IS THE FIFTH AND NOT THE SECOND. It ranked well from the start on blockers,
//! and the ranking was misleading twice over. `kalloc` looked like one macro; the preprocessor
//! shows it expanding to a statement expression holding a function-static
//! `vm_allocation_site_t`, so writing it in Rust would have meant un-opaquing part of `vm_.*`
//! for the whole crate. `simple_lock_init` is a macro too. Both are now C SHIMS
//! (`duct-tape/src/dtape_rs_shims.c`), which is the remedy for a macro blocker that costs one
//! object file instead of a permanent widening of the bindings, and with them the ranker puts
//! this file at zero blockers.
//!
//! THIS IS THE FIRST PORT THAT DEFINES DATA, seven symbols of it, and one of those is a whole
//! `struct processor_set` by value. XNU reads them directly. `timer.c` proved the direction
//! with three scalars; this is the same mechanism at a size where the ZERO INITIALISER has to
//! be const-evaluable, hence `MaybeUninit::zeroed()` rather than `mem::zeroed()`, which is not
//! a const fn. The resulting symbol has exactly the size and alignment of the C definition,
//! which is asserted below rather than assumed.

use std::mem::MaybeUninit;
use std::os::raw::{c_int, c_uint};
use std::ptr;

use crate::bindings::{
    boolean_t, dtape_load_info_t, dtape_rs_kalloc, dtape_rs_simple_lock_init, host_t, integer_t,
    kern_return_t, mach_msg_type_number_t, policy_fifo_base, policy_fifo_limit, policy_rr_base,
    policy_rr_limit, policy_timeshare_base, policy_timeshare_limit, processor, processor_basic_info,
    processor_cpu_load_info, processor_flavor_t, processor_info_t, processor_set,
    processor_set_basic_info, processor_set_info_t, processor_set_load_info, processor_set_t,
    processor_t, simple_lock_data_t, task_array_t, thread_array_t, vm_offset_t, vm_size_t,
    BASEPRI_DEFAULT, CPU_STATE_IDLE, CPU_STATE_NICE, CPU_STATE_SYSTEM, CPU_STATE_USER,
    KERN_FAILURE, KERN_INVALID_ARGUMENT, KERN_INVALID_PROCESSOR_SET, KERN_SUCCESS, MAXPRI_KERNEL,
    POLICY_FIFO, POLICY_RR, POLICY_TIMESHARE, PROCESSOR_BASIC_INFO, PROCESSOR_CPU_LOAD_INFO,
    PROCESSOR_SET_BASIC_INFO, PROCESSOR_SET_ENABLED_POLICIES, PROCESSOR_SET_FIFO_DEFAULT,
    PROCESSOR_SET_FIFO_LIMITS, PROCESSOR_SET_LOAD_INFO, PROCESSOR_SET_RR_DEFAULT,
    PROCESSOR_SET_RR_LIMITS, PROCESSOR_SET_TIMESHARE_DEFAULT, PROCESSOR_SET_TIMESHARE_LIMITS,
};

// The sizeof-expression counts, evaluated by the C compiler from the real macros. See the
// dtape_rs_host_consts enum in wrapper.h for why these cannot come from bindgen directly.
use crate::bindings::{
    dtape_rs_host_consts_DTAPE_RS_CPU_SUBTYPE_X86_64_ALL as CPU_SUBTYPE_X86_64_ALL,
    dtape_rs_host_consts_DTAPE_RS_CPU_TYPE_X86 as CPU_TYPE_X86,
    dtape_rs_host_consts_DTAPE_RS_MAX_SCHED_CPUS as MAX_SCHED_CPUS,
    dtape_rs_host_consts_DTAPE_RS_POLICY_FIFO_BASE_COUNT as POLICY_FIFO_BASE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_POLICY_FIFO_LIMIT_COUNT as POLICY_FIFO_LIMIT_COUNT,
    dtape_rs_host_consts_DTAPE_RS_POLICY_RR_BASE_COUNT as POLICY_RR_BASE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_POLICY_RR_LIMIT_COUNT as POLICY_RR_LIMIT_COUNT,
    dtape_rs_host_consts_DTAPE_RS_POLICY_TIMESHARE_BASE_COUNT as POLICY_TIMESHARE_BASE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_POLICY_TIMESHARE_LIMIT_COUNT as POLICY_TIMESHARE_LIMIT_COUNT,
    dtape_rs_host_consts_DTAPE_RS_PROCESSOR_BASIC_INFO_COUNT as PROCESSOR_BASIC_INFO_COUNT,
    dtape_rs_host_consts_DTAPE_RS_PROCESSOR_CPU_LOAD_INFO_COUNT as PROCESSOR_CPU_LOAD_INFO_COUNT,
    dtape_rs_host_consts_DTAPE_RS_PROCESSOR_SET_BASIC_INFO_COUNT as PROCESSOR_SET_BASIC_INFO_COUNT,
    dtape_rs_host_consts_DTAPE_RS_PROCESSOR_SET_LOAD_INFO_COUNT as PROCESSOR_SET_LOAD_INFO_COUNT,
};

const MAX_CPUS: usize = MAX_SCHED_CPUS as usize;

extern "C" {
    /// XNU's global host object. Only ever address-taken here, so `host` stays opaque in the
    /// bindings; `processor_info` and `processor_set_info` hand its address back to the caller.
    static mut realhost: crate::bindings::host;

    /// The hooks vtable duct-tape calls back into. `init.c` still defines it (it is C), and
    /// `processor_set_statistics` reads the task and thread counts through it.
    static dtape_hooks: *const crate::bindings::dtape_hooks;

    /// glibc, declared here for the same reason processor.c declares them itself: they are
    /// Linux functions with no XNU header, and the vendored libc crate does not expose them.
    fn get_nprocs() -> c_int;
    fn get_nprocs_conf() -> c_int;
}

const fn kr(value: u32) -> kern_return_t {
    value as kern_return_t
}

// ---------------------------------------------------------------------------------------
// The data symbols. XNU code reads these directly, so they keep their C names and layout.
// ---------------------------------------------------------------------------------------

/// Every processor, indexed by cpu id. `processor_t` is a pointer, so a null array is the same
/// `{0}` the C had.
#[no_mangle]
pub static mut processor_array: [processor_t; MAX_CPUS] = [ptr::null_mut(); MAX_CPUS];

/// The one processor set. A whole struct by value, zeroed, exactly as the C `struct
/// processor_set pset0;` lands in bss.
///
/// `MaybeUninit::zeroed()` rather than `mem::zeroed()`, which is not a const fn and so cannot
/// initialise a static. `MaybeUninit` is `repr(transparent)`, so the emitted symbol has the
/// size and alignment of `processor_set` itself; both are asserted in the tests.
#[no_mangle]
pub static mut pset0: MaybeUninit<processor_set> = MaybeUninit::zeroed();

// "don't use these in our code; this is only for XNU code, use get_nprocs() instead" -- the C.
#[no_mangle]
pub static mut processor_avail_count: u32 = 0;
#[no_mangle]
pub static mut processor_avail_count_user: u32 = 0;
#[no_mangle]
pub static mut primary_processor_avail_count: u32 = 0;
#[no_mangle]
pub static mut primary_processor_avail_count_user: u32 = 0;

#[no_mangle]
pub static mut processor_count: c_uint = 0;

#[no_mangle]
pub static mut processor_list_lock: MaybeUninit<simple_lock_data_t> = MaybeUninit::zeroed();

#[no_mangle]
pub static mut master_processor: processor_t = ptr::null_mut();

/// `&pset0` as the C spells it. A helper because the static is a `MaybeUninit`, and because
/// taking a reference to a mutable static is what edition 2024 rejects; the pointer form is
/// both allowed and closer to what the C actually does.
#[inline]
fn pset0_ptr() -> *mut processor_set {
    ptr::addr_of_mut!(pset0) as *mut processor_set
}

/// `&pset0` for the runtime demo, which has no other way to name it: the static is private and
/// `processor_set_info` rejects any pset that is not this one.
pub fn pset0_for_test() -> processor_set_t {
    pset0_ptr()
}

// ---------------------------------------------------------------------------------------

/// Build the processor list. Called once, from `dtape_init`.
#[no_mangle]
pub unsafe extern "C" fn dtape_processor_init() {
    dtape_rs_simple_lock_init(ptr::addr_of_mut!(processor_list_lock) as *mut simple_lock_data_t);

    processor_count = get_nprocs_conf() as c_uint;
    if processor_count as usize > MAX_CPUS {
        processor_count = MAX_CPUS as c_uint;
    }

    processor_avail_count = get_nprocs() as u32;
    if processor_avail_count as usize > MAX_CPUS {
        processor_avail_count = MAX_CPUS as u32;
    }

    processor_avail_count_user = processor_avail_count;
    primary_processor_avail_count = processor_avail_count;
    primary_processor_avail_count_user = processor_avail_count;

    for i in 0..processor_count as usize {
        // dtape_rs_kalloc, not libc::malloc: kalloc is a macro that reaches XNU's own heap
        // through kalloc_ext(KHEAP_DEFAULT, ...), and the shim keeps that rather than
        // substituting a different allocator for memory XNU will free.
        let p = dtape_rs_kalloc(std::mem::size_of::<processor>()) as processor_t;
        processor_array[i] = p;
        if p.is_null() {
            continue;
        }

        ptr::write_bytes(p as *mut u8, 0, std::mem::size_of::<processor>());

        (*p).processor_set = pset0_ptr();
        (*p).cpu_id = i as c_int;
    }

    (*pset0_ptr()).online_processor_count = processor_avail_count as c_int;

    master_processor = processor_array[0];

    // TODO: there's probably more stuff we should set in these structures
}

/// `processor_info`: what the guest asks about one CPU.
#[no_mangle]
pub unsafe extern "C" fn processor_info(
    processor: processor_t,
    flavor: processor_flavor_t,
    host: *mut host_t,
    raw_info: processor_info_t,
    count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    // PROCESSOR_NULL is ((processor_t) 0), a macro bindgen does not bind.
    if processor.is_null() {
        return kr(KERN_INVALID_ARGUMENT);
    }

    match flavor as u32 {
        PROCESSOR_BASIC_INFO => {
            if (*count as u32) < PROCESSOR_BASIC_INFO_COUNT as u32 {
                return kr(KERN_FAILURE);
            }

            let info = raw_info as *mut processor_basic_info;
            (*info).cpu_type = CPU_TYPE_X86 as crate::bindings::cpu_type_t;
            (*info).cpu_subtype = CPU_SUBTYPE_X86_64_ALL as crate::bindings::cpu_subtype_t;
            (*info).is_master = (processor == master_processor) as boolean_t;
            (*info).running = 1; // TRUE
            (*info).slot_num = (*processor).cpu_id;

            *count = PROCESSOR_BASIC_INFO_COUNT as mach_msg_type_number_t;
            *host = ptr::addr_of_mut!(realhost);

            kr(KERN_SUCCESS)
        }

        PROCESSOR_CPU_LOAD_INFO => {
            if (*count as u32) < PROCESSOR_CPU_LOAD_INFO_COUNT as u32 {
                return kr(KERN_FAILURE);
            }

            crate::dtape_stub_safe!("PROCESSOR_CPU_LOAD_INFO");

            let info = raw_info as *mut processor_cpu_load_info;
            (*info).cpu_ticks[CPU_STATE_USER as usize] = 0;
            (*info).cpu_ticks[CPU_STATE_SYSTEM as usize] = 0;
            (*info).cpu_ticks[CPU_STATE_IDLE as usize] = 0;
            (*info).cpu_ticks[CPU_STATE_NICE as usize] = 0;

            *count = PROCESSOR_CPU_LOAD_INFO_COUNT as mach_msg_type_number_t;
            *host = ptr::addr_of_mut!(realhost);

            kr(KERN_SUCCESS)
        }

        _ => kr(KERN_FAILURE),
    }
}

/// `processor_set_statistics`: the load numbers, which come from the daemon through the hooks.
#[no_mangle]
pub unsafe extern "C" fn processor_set_statistics(
    pset: processor_set_t,
    flavor: c_int,
    raw_info: processor_set_info_t,
    count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    // The C rejects both a null pset and any pset that is not pset0, since there is only one.
    if pset.is_null() || pset != pset0_ptr() {
        return kr(KERN_INVALID_PROCESSOR_SET);
    }

    match flavor as u32 {
        PROCESSOR_SET_LOAD_INFO => {
            if (*count as u32) < PROCESSOR_SET_LOAD_INFO_COUNT as u32 {
                return kr(KERN_FAILURE);
            }

            let info = raw_info as *mut processor_set_load_info;
            (*info).mach_factor = 0;
            (*info).load_average = 0;

            let mut load_info: dtape_load_info_t = std::mem::zeroed();
            if let Some(get_load_info) = (*dtape_hooks).get_load_info {
                get_load_info(&mut load_info);
            }
            (*info).task_count = load_info.task_count as c_int;
            (*info).thread_count = load_info.thread_count as c_int;

            *count = PROCESSOR_SET_LOAD_INFO_COUNT as mach_msg_type_number_t;

            kr(KERN_SUCCESS)
        }

        _ => kr(KERN_INVALID_ARGUMENT),
    }
}

/// `processor_set_info`: the policy and configuration flavors.
///
/// Copied from xnu://7195.141.2/osfmk/kern/processor.c, modified: the BASIC_INFO case reports
/// the live CPU count rather than the cached `processor_avail_count_user`, which is what the
/// `__DARLING__` arm of the C did.
#[no_mangle]
pub unsafe extern "C" fn processor_set_info(
    pset: processor_set_t,
    flavor: c_int,
    host: *mut host_t,
    info: processor_set_info_t,
    count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    if pset.is_null() {
        return kr(KERN_INVALID_ARGUMENT);
    }

    let short = |need: u32| (*count as u32) < need;

    match flavor as u32 {
        PROCESSOR_SET_BASIC_INFO => {
            if short(PROCESSOR_SET_BASIC_INFO_COUNT as u32) {
                return kr(KERN_FAILURE);
            }
            let basic = info as *mut processor_set_basic_info;
            (*basic).processor_count = get_nprocs();
            (*basic).default_policy = POLICY_TIMESHARE as c_int;
            *count = PROCESSOR_SET_BASIC_INFO_COUNT as mach_msg_type_number_t;
        }

        PROCESSOR_SET_TIMESHARE_DEFAULT => {
            if short(POLICY_TIMESHARE_BASE_COUNT as u32) {
                return kr(KERN_FAILURE);
            }
            (*(info as *mut policy_timeshare_base)).base_priority = BASEPRI_DEFAULT as integer_t;
            *count = POLICY_TIMESHARE_BASE_COUNT as mach_msg_type_number_t;
        }

        PROCESSOR_SET_FIFO_DEFAULT => {
            if short(POLICY_FIFO_BASE_COUNT as u32) {
                return kr(KERN_FAILURE);
            }
            (*(info as *mut policy_fifo_base)).base_priority = BASEPRI_DEFAULT as integer_t;
            *count = POLICY_FIFO_BASE_COUNT as mach_msg_type_number_t;
        }

        PROCESSOR_SET_RR_DEFAULT => {
            if short(POLICY_RR_BASE_COUNT as u32) {
                return kr(KERN_FAILURE);
            }
            let rr = info as *mut policy_rr_base;
            (*rr).base_priority = BASEPRI_DEFAULT as integer_t;
            (*rr).quantum = 1;
            *count = POLICY_RR_BASE_COUNT as mach_msg_type_number_t;
        }

        PROCESSOR_SET_TIMESHARE_LIMITS => {
            if short(POLICY_TIMESHARE_LIMIT_COUNT as u32) {
                return kr(KERN_FAILURE);
            }
            (*(info as *mut policy_timeshare_limit)).max_priority = MAXPRI_KERNEL as integer_t;
            *count = POLICY_TIMESHARE_LIMIT_COUNT as mach_msg_type_number_t;
        }

        PROCESSOR_SET_FIFO_LIMITS => {
            if short(POLICY_FIFO_LIMIT_COUNT as u32) {
                return kr(KERN_FAILURE);
            }
            (*(info as *mut policy_fifo_limit)).max_priority = MAXPRI_KERNEL as integer_t;
            *count = POLICY_FIFO_LIMIT_COUNT as mach_msg_type_number_t;
        }

        PROCESSOR_SET_RR_LIMITS => {
            if short(POLICY_RR_LIMIT_COUNT as u32) {
                return kr(KERN_FAILURE);
            }
            (*(info as *mut policy_rr_limit)).max_priority = MAXPRI_KERNEL as integer_t;
            *count = POLICY_RR_LIMIT_COUNT as mach_msg_type_number_t;
        }

        PROCESSOR_SET_ENABLED_POLICIES => {
            // The C measures this one as sizeof(*enabled)/sizeof(int), which is 1 by
            // construction; kept as the same expression rather than written as a literal.
            let one = (std::mem::size_of::<c_int>() / std::mem::size_of::<c_int>()) as u32;
            if short(one) {
                return kr(KERN_FAILURE);
            }
            *(info as *mut c_int) = (POLICY_TIMESHARE | POLICY_RR | POLICY_FIFO) as c_int;
            *count = one as mach_msg_type_number_t;
        }

        _ => {
            // HOST_NULL, and the argument is rejected.
            *host = ptr::null_mut();
            return kr(KERN_INVALID_ARGUMENT);
        }
    }

    *host = ptr::addr_of_mut!(realhost);
    kr(KERN_SUCCESS)
}

/// `processor_info_count`: how big a reply each flavor needs.
#[no_mangle]
pub unsafe extern "C" fn processor_info_count(
    flavor: processor_flavor_t,
    count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    match flavor as u32 {
        PROCESSOR_BASIC_INFO => {
            *count = PROCESSOR_BASIC_INFO_COUNT as mach_msg_type_number_t;
        }
        PROCESSOR_CPU_LOAD_INFO => {
            *count = PROCESSOR_CPU_LOAD_INFO_COUNT as mach_msg_type_number_t;
        }
        _ => return cpu_info_count(flavor, count as *mut c_uint),
    }
    kr(KERN_SUCCESS)
}

/// Copied from xnu://7195.141.2/osfmk/i386/cpu.c: there are no machine-specific flavors.
#[no_mangle]
pub unsafe extern "C" fn cpu_info_count(
    _flavor: processor_flavor_t,
    count: *mut c_uint,
) -> kern_return_t {
    *count = 0;
    kr(KERN_FAILURE)
}

// ---------------------------------------------------------------------------------------
// Unimplemented XNU entry points. Signatures in generated types, bodies unchanged from the C.
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn processor_assign(
    _processor: processor_t,
    _new_pset: processor_set_t,
    _wait: boolean_t,
) -> kern_return_t {
    crate::dtape_stub_safe!();
    kr(KERN_FAILURE)
}

#[no_mangle]
pub unsafe extern "C" fn processor_control(
    _processor: processor_t,
    _info: processor_info_t,
    _count: mach_msg_type_number_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_exit_from_user(_processor: processor_t) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_get_assignment(
    _processor: processor_t,
    _pset: *mut processor_set_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_start_from_user(_processor: processor_t) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_create(
    _host: host_t,
    _new_set: *mut processor_set_t,
    _new_name: *mut processor_set_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_destroy(_pset: processor_set_t) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_max_priority(
    _pset: processor_set_t,
    _max_priority: c_int,
    _change_threads: boolean_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_policy_control(
    _pset: processor_set_t,
    _flavor: c_int,
    _policy_info: processor_set_info_t,
    _count: mach_msg_type_number_t,
    _change: boolean_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_policy_disable(
    _pset: processor_set_t,
    _policy: c_int,
    _change_threads: boolean_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_policy_enable(
    _pset: processor_set_t,
    _policy: c_int,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_stack_usage(
    _pset: processor_set_t,
    _totalp: *mut c_uint,
    _spacep: *mut vm_size_t,
    _residentp: *mut vm_size_t,
    _maxusagep: *mut vm_size_t,
    _maxstackp: *mut vm_offset_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_tasks(
    _pset: processor_set_t,
    _task_list: *mut task_array_t,
    _count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_tasks_with_flavor(
    _pset: processor_set_t,
    _flavor: c_uint,
    _task_list: *mut task_array_t,
    _count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[no_mangle]
pub unsafe extern "C" fn processor_set_threads(
    _pset: processor_set_t,
    _thread_list: *mut thread_array_t,
    _count: *mut mach_msg_type_number_t,
) -> kern_return_t {
    crate::dtape_stub_unsafe!()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The zero-initialised statics must have EXACTLY the C layout, because XNU indexes them
    /// directly. MaybeUninit is repr(transparent), so this should hold, and a wrong answer here
    /// would be a silently misaligned global rather than a compile error.
    #[test]
    fn the_data_symbols_have_the_c_layout() {
        assert_eq!(
            std::mem::size_of::<MaybeUninit<processor_set>>(),
            std::mem::size_of::<processor_set>()
        );
        assert_eq!(
            std::mem::align_of::<MaybeUninit<processor_set>>(),
            std::mem::align_of::<processor_set>()
        );
        assert_eq!(
            std::mem::size_of::<[processor_t; MAX_CPUS]>(),
            MAX_CPUS * std::mem::size_of::<processor_t>()
        );
    }

    /// The counts must be what XNU computes from the structs. A drifted count is a reply of the
    /// wrong length, which no compiler catches.
    #[test]
    fn counts_match_the_structs_they_describe() {
        let words = |bytes: usize| (bytes / std::mem::size_of::<integer_t>()) as u32;
        assert_eq!(
            PROCESSOR_BASIC_INFO_COUNT as u32,
            words(std::mem::size_of::<processor_basic_info>())
        );
        assert_eq!(
            PROCESSOR_CPU_LOAD_INFO_COUNT as u32,
            words(std::mem::size_of::<processor_cpu_load_info>())
        );
        assert_eq!(
            PROCESSOR_SET_BASIC_INFO_COUNT as u32,
            words(std::mem::size_of::<processor_set_basic_info>())
        );
        assert_eq!(
            PROCESSOR_SET_LOAD_INFO_COUNT as u32,
            words(std::mem::size_of::<processor_set_load_info>())
        );
    }

    /// MAX_SCHED_CPUS bounds the array, so a machine with more CPUs than that must clamp rather
    /// than write past the end. The clamp is in dtape_processor_init; this pins the bound it
    /// clamps to, which is the value the array is sized with.
    #[test]
    fn the_cpu_bound_is_the_array_length() {
        assert_eq!(MAX_CPUS, MAX_SCHED_CPUS as usize);
        assert!(MAX_CPUS >= 1);
    }
}
