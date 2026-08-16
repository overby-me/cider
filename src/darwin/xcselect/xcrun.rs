/*
This file is part of Darling.

Copyright (C) 2017 Lubos Dolezel
Copyright (C) 2026 Cider contributors

Darling is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Darling is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

// The Rust rewrite of xcrun.c (#102). It is the FIRST guest tool the port builds from Rust, and
// it was picked because everything it does is observable: the whole program decides ONE argument
// and then hands off to libxcselect, which is unchanged. So parity is testable end to end.
//
// THE ARGUMENTS COME FROM crt1, NOT FROM std::env. That is not a style choice. This is a
// staticlib with a C entry point, so Rust lang_start never runs, and more importantly the C
// original passes the ORIGINAL argv pointers straight through to xcselect_invoke_xcrun. Rebuilding
// that array out of std::env::args would allocate new strings and change what the callee is
// handed. Using argv directly keeps the handoff byte for byte.
//
// getprogname IS NOT argv[0]. It is libSystem's own copy, which is why xcrun installed under
// another name (the `cc`, `clang`, `ld` symlinks the CLT lays down) invokes THAT tool instead.
// Reimplementing it as argv[0] would look identical in every test that runs the binary as xcrun,
// and break every other caller, so it is an extern rather than a rewrite.

use core::ffi::{c_char, c_int};

unsafe extern "C" {
    fn getprogname() -> *const c_char;
    fn xcselect_invoke_xcrun(
        tool: *const c_char,
        argc: c_int,
        argv: *const *const c_char,
        flags: c_int,
    ) -> c_int;
}

/// strcasecmp against the literal "xcrun", which is all the C uses it for.
///
/// ASCII ONLY, deliberately: C strcasecmp folds case per the current locale, and the C program
/// never calls setlocale, so it runs in the "C" locale where folding is exactly ASCII. Matching
/// that is the whole requirement, and a Unicode-aware comparison would be a DIFFERENCE, not an
/// improvement.
unsafe fn is_xcrun(name: *const c_char) -> bool {
    const WANT: &[u8] = b"xcrun";
    let mut i = 0usize;
    loop {
        let c = unsafe { *name.add(i) } as u8;
        if i == WANT.len() {
            return c == 0;
        }
        if c == 0 || c.to_ascii_lowercase() != WANT[i] {
            return false;
        }
        i += 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn main(argc: c_int, argv: *const *const c_char) -> c_int {
    let pname = unsafe { getprogname() };

    // The C is `if (*pname == '/') tool = pname + 1;` -- ONE leading slash, not a basename.
    // It looks like a bug and it is faithfully kept: a path like /usr/bin/cc would become
    // usr/bin/cc rather than cc. Changing it here would make the two binaries disagree on an
    // input a test can reach, and this port is not the place to fix upstream behaviour.
    // THE ONE ADDED CHECK, and it is not reachable in a comparison: the C dereferences pname
    // without testing it, so a null getprogname would segfault there and return NULL-tool here.
    // libSystem never returns null, so no test can tell these apart; it is written down because
    // an unexplained extra branch in a parity port is worse than the branch itself.
    let mut tool = pname;
    if !pname.is_null() && unsafe { *pname } == b'/' as c_char {
        tool = unsafe { pname.add(1) };
    }

    if tool.is_null() || unsafe { is_xcrun(tool) } {
        tool = core::ptr::null();
    }

    unsafe { xcselect_invoke_xcrun(tool, argc - 1, argv.add(1), 0) }
}
