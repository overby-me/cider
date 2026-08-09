//! `xnu-sys/src/misc.c`, in Rust (#71, twelfth file).
//!
//! 150 lines, and the smallest remaining file, but it is the one that had to solve the problem
//! blocking the last two: duct-tape exports four VARIADIC DEFINITIONS, and stable Rust cannot
//! define a variadic function. Three of the four are here (`dtape_log`, `kprintf`, `scnprintf`),
//! the fourth is `panic` in stubs.c.
//!
//! THE SOLUTION IS NOT TO PORT THEM. Each is a pure forwarder to a `v`-variant, so all four stay
//! in C, in `xnu-sys/src/dtape_rs_shims.c` alongside the eighteen macro shims, for exactly the
//! same reason those are there: they do the one thing Rust cannot express. `dtape_logv` goes with
//! them, since its parameter is a `va_list`.
//!
//! Nothing is lost by that. Rust can CALL a C variadic even though it cannot define one, so the
//! two places in this file that logged through a variadic macro now format with `format!` and
//! pass the result through a plain `%s`, which is strictly less error-prone than the C: a
//! mismatched format specifier is a compile error on this side rather than a garbage read.
//!
//! The rest of the file is here: the kmsg trace, `Assert`, `waitq_held`, `fls`, `read_frandom`,
//! and the two data tables. `_MachineStateCount` is the interesting one. It is indexed BY the
//! flavor, both flavor and count are macros, and a wrong index would be silent, so both halves
//! come through the derived-constants enum and the array is assembled in a const block. Nothing
//! about it is transcribed.

use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::ptr;

use crate::bindings::{
    self, dtape_log_level_t, dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE32,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE32_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE64,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE64_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE, dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE32,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE32_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE64,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE64_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE,
    dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE32,
    dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE32_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE64,
    dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE64_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE,
    dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE32,
    dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE32_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE64,
    dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE64_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE,
    dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE32,
    dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE32_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE64,
    dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE64_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_PAGEIN_STATE,
    dtape_rs_host_consts_DTAPE_RS_X86_PAGEIN_STATE_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_FULL_STATE64,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_FULL_STATE64_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE32,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE32_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE64,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE64_COUNT,
    dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE_COUNT, ipc_kmsg_t, ipc_port_t,
    mach_msg_body_t, mach_msg_option_t, mach_msg_type_descriptor_t, waitq,
    MACH_MSGH_BITS_COMPLEX,
};

extern "C" {
    /// Linux, not XNU. misc.c declares it by hand for the same reason.
    fn getrandom(buf: *mut c_void, buflen: usize, flags: c_uint) -> isize;
}

/// `char version[] = "Darling 11.5"`. Thirteen bytes with the NUL, which is what the symbol is;
/// Rust spells the element type `u8` where C spells it `char`, and they are the same byte.
///
/// `static mut`, not `static`, and that is not a detail: a C `char version[]` is a WRITABLE
/// array in .data, while a Rust `static` is placed in .rodata. Nothing is known to write to
/// either table, but a difference that turns a stray write from harmless into a SIGSEGV is not
/// one to introduce silently while porting.
#[no_mangle]
pub static mut version: [u8; 13] = *b"Darling 11.5\0";

//
// <copied from="xnu://7195.141.2/osfmk/i386/pcb.c">
//

/// The table is indexed by the state flavor, so its length is the LARGEST flavor plus one.
///
/// Derived rather than assumed, and that mattered: the obvious guess is `x86_PAGEIN_STATE + 1`
/// because PAGEIN is written last in the C initialiser, but PAGEIN is 22 and
/// `x86_THREAD_FULL_STATE64` is 23. A hand-sized array would have been one short, and in C the
/// designated initialiser sizes itself so the bug could not exist there. Const evaluation caught
/// it here as an out-of-bounds write at compile time.
const MACHINE_STATE_COUNT_LEN: usize = {
    let flavors = [
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE32 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE64 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_FULL_STATE64 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE32 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE64 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE32 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE64 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE32 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE64 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE32 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE64 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE32 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE64 as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE as usize,
        dtape_rs_host_consts_DTAPE_RS_X86_PAGEIN_STATE as usize,
    ];
    let mut max = 0;
    let mut i = 0;
    while i < flavors.len() {
        if flavors[i] > max {
            max = flavors[i];
        }
        i += 1;
    }
    max + 1
};

/// `_MachineStateCount[]`. The C writes it as a designated initialiser, which leaves every index
/// it does not name at zero; a const block assembling the same array is the closest Rust has,
/// and it keeps both the indices and the values coming from the macros rather than from here.
/// `static mut` for the same reason `version` is: the C array is not const.
#[no_mangle]
pub static mut _MachineStateCount: [c_uint; MACHINE_STATE_COUNT_LEN] = {
    let mut c = [0 as c_uint; MACHINE_STATE_COUNT_LEN];
    c[dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE32 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE32_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE64 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE64_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_THREAD_FULL_STATE64 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_FULL_STATE64_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_THREAD_STATE_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE32 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE32_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE64 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE64_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_FLOAT_STATE_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE32 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE32_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE64 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE64_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_EXCEPTION_STATE_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE32 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE32_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE64 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE64_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_DEBUG_STATE_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE32 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE32_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE64 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE64_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_AVX_STATE_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE32 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE32_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE64 as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE64_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_AVX512_STATE_COUNT as c_uint;
    c[dtape_rs_host_consts_DTAPE_RS_X86_PAGEIN_STATE as usize] =
        dtape_rs_host_consts_DTAPE_RS_X86_PAGEIN_STATE_COUNT as c_uint;
    c
};

//
// </copied>
//

/// Log through duct-tape's own variadic entry point, with the message already formatted.
///
/// The C reaches `dtape_log` through variadic MACROS (`dtape_log_debug` and friends). Rust
/// formats first and passes `%s`, which cannot disagree with its arguments.
pub(crate) fn log(level: dtape_log_level_t, message: &str) {
    let c = match CString::new(message) {
        Ok(c) => c,
        // An interior NUL can only come from a %s of foreign data; log the prefix rather than
        // dropping the line.
        Err(e) => {
            let mut v = e.into_vec();
            v.truncate(v.iter().position(|&b| b == 0).unwrap_or(v.len()));
            CString::new(v).unwrap_or_default()
        }
    };
    unsafe { bindings::dtape_log(level, b"%s\0".as_ptr() as *const c_char, c.as_ptr()) }
}

#[no_mangle]
pub unsafe extern "C" fn read_frandom(buffer: *mut c_void, num_bytes: c_uint) {
    getrandom(buffer, num_bytes as usize, 0);
}

#[no_mangle]
pub unsafe extern "C" fn ipc_kmsg_trace_send(kmsg: ipc_kmsg_t, _option: mach_msg_option_t) {
    let header = (*kmsg).ikm_header;
    let dest = (*header).msgh_remote_port;

    let dest_pid = bindings::ipc_port_get_receiver_task(dest as ipc_port_t, ptr::null_mut());

    // The msgh_id is the MIG routine number, which is what actually identifies the
    // operation. Without it every message in the log looks alike and a stalled
    // request cannot be told from a healthy one (task #47).
    // For a COMPLEX message, also report the descriptor count and the first descriptor's
    // type. Port descriptors copy out entirely inside the daemon; OOL descriptors have to
    // map memory INTO the guest, which is a very different (and much more failure-prone)
    // path. Telling them apart from a log is the difference between a guess and a fact.
    let mut ndesc: i64 = -1;
    let mut dtype: i64 = -1;
    if (*header).msgh_bits & MACH_MSGH_BITS_COMPLEX != 0 {
        let body = header.add(1) as *mut mach_msg_body_t;
        ndesc = (*body).msgh_descriptor_count as i64;
        if ndesc > 0 {
            dtype = (*(body.add(1) as *mut mach_msg_type_descriptor_t)).type_() as i64;
        }
    }

    log(
        bindings::dtape_log_level_t::dtape_log_level_debug,
        &format!(
            "sending kmsg {:p} to pid {} id={} size={} bits=0x{:x} remote={:p} local={:p} \
             ndesc={} dtype={}",
            kmsg,
            dest_pid,
            (*header).msgh_id,
            (*header).msgh_size,
            (*header).msgh_bits,
            (*header).msgh_remote_port as *const c_void,
            (*header).msgh_local_port as *const c_void,
            ndesc,
            dtype
        ),
    );
}

#[no_mangle]
pub unsafe extern "C" fn Assert(file: *const c_char, line: c_int, expression: *const c_char) {
    // `panic` is the fourth variadic definition and still lives in stubs.c. Rust cannot define
    // one but can call one, so this formats first and hands over a single `%s`.
    let message = CString::new(format!(
        "{}:{} Assertion failed: {}",
        cstr(file),
        line,
        cstr(expression)
    ))
    .unwrap_or_default();
    bindings::panic(b"%s\0".as_ptr() as *const c_char, message.as_ptr());
}

/// A C string as a `&str`, lossily, for the two log paths. Never on a hot path.
pub(crate) unsafe fn cstr<'a>(p: *const c_char) -> std::borrow::Cow<'a, str> {
    if p.is_null() {
        return std::borrow::Cow::Borrowed("(null)");
    }
    std::ffi::CStr::from_ptr(p).to_string_lossy()
}

/// The interlock owner lives four structs down inside the OPAQUE `struct waitq`, so the
/// comparison is done in C and only its result crosses.
#[no_mangle]
pub unsafe extern "C" fn waitq_held(wq: *mut waitq) -> c_uint {
    bindings::dtape_rs_waitq_held(wq)
}

//
// <copied from="xnu://7195.141.2/osfmk/x86_64/loose_ends.c">
//

/// Find last bit set in bit string.
#[no_mangle]
pub extern "C" fn fls(mask: c_uint) -> c_int {
    if mask == 0 {
        return 0;
    }

    // `(sizeof(mask) << 3) - __builtin_clz(mask)`.
    (c_uint::BITS - mask.leading_zeros()) as c_int
}

//
// </copied>
//
