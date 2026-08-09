//! The `dtape_stub` family, for glue ported to Rust (#71).
//!
//! duct-tape marks unimplemented XNU entry points with three macros from
//! `internal-include/darlingserver/xnu-sys/stubs.h`, all of which call the real symbol
//! `dtape_stub_log(function_name, safety, subsection)`:
//!
//!   `dtape_stub`         safety 0, unknown whether stubbing is safe
//!   `dtape_stub_safe`    safety 1, confirmed fine to stub
//!   `dtape_stub_unsafe`  safety -1, confirmed to need a real implementation; the C follows
//!                        it with `__builtin_unreachable()`
//!
//! bindgen binds no macros, so they are written out here ONCE rather than per ported file:
//! seven of the fourteen files still in C use them.
//!
//! `__FUNCTION__` has no stable Rust equivalent, so the macros capture the enclosing function
//! the usual way, by naming a local item and asking for its type name. That yields the full
//! path (`darling::xnu::timer::timer_queue_cpu::f`), which is trimmed to the last segment so the
//! log line reads the same as the C one.

use std::ffi::CString;
use std::os::raw::{c_char, c_int};

// Was an `extern "C"` declaration resolving back into this crate through the linker; imported
// directly since duct-tape became Rust (#71, #75).
use crate::xnu::stubs::dtape_stub_log;

/// Call through to duct-tape's own stub logger. Cold path by construction, so the two small
/// allocations for NUL termination are not worth avoiding.
pub fn stub_log(function: &str, safety: c_int, subsection: &str) {
    let f = CString::new(function).unwrap_or_default();
    let s = CString::new(subsection).unwrap_or_default();
    unsafe { dtape_stub_log(f.as_ptr(), safety, s.as_ptr()) }
}

/// The enclosing function's name, as `__FUNCTION__` would give it in C.
#[macro_export]
macro_rules! dtape_function_name {
    () => {{
        fn f() {}
        fn type_name_of<T>(_: T) -> &'static str {
            ::std::any::type_name::<T>()
        }
        let path = type_name_of(f);
        // strip the trailing "::f", then keep only the final segment
        let path = &path[..path.len() - 3];
        match path.rfind("::") {
            Some(i) => &path[i + 2..],
            None => path,
        }
    }};
}

/// `dtape_stub()`: unknown whether this can be safely stubbed.
#[macro_export]
macro_rules! dtape_stub {
    () => { $crate::xnu::stub_family::stub_log($crate::dtape_function_name!(), 0, "") };
    ($sub:expr) => { $crate::xnu::stub_family::stub_log($crate::dtape_function_name!(), 0, $sub) };
}

/// `dtape_stub_safe()`: confirmed fine to stub.
#[macro_export]
macro_rules! dtape_stub_safe {
    () => { $crate::xnu::stub_family::stub_log($crate::dtape_function_name!(), 1, "") };
    ($sub:expr) => { $crate::xnu::stub_family::stub_log($crate::dtape_function_name!(), 1, $sub) };
}

/// `dtape_stub_unsafe()`: confirmed to need a real implementation. The C follows the log with
/// `__builtin_unreachable()`, so this does not return either.
#[macro_export]
macro_rules! dtape_stub_unsafe {
    () => {{
        $crate::xnu::stub_family::stub_log($crate::dtape_function_name!(), -1, "");
        ::std::process::abort()
    }};
    ($sub:expr) => {{
        $crate::xnu::stub_family::stub_log($crate::dtape_function_name!(), -1, $sub);
        ::std::process::abort()
    }};
}

#[cfg(test)]
mod tests {
    #[test]
    fn function_name_is_the_enclosing_function() {
        fn some_named_function() -> &'static str {
            crate::dtape_function_name!()
        }
        // The whole point is that it tracks the function it sits in, so a wrong answer here
        // would silently mislabel every stub log line in every ported file.
        assert_eq!(some_named_function(), "some_named_function");
    }
}
