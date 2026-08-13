// GUEST RUST PROBE (#102): the smallest program that proves the whole path.
//
// It is a STATICLIB with a C entry point, not a Rust bin, because that is the shape the port
// uses: rustc bundles std into an archive and crt1.10.6 plus darwin_binary link it exactly
// like any C guest tool. So `main` is exported for crt1, and Rust's lang_start never runs.
//
// IT TOUCHES std ON PURPOSE. Printing goes through std::io, the argument count goes through
// std::env (which on macOS reads _NSGetArgv rather than an init hook), and the String forces
// the allocator. A probe that only returned 0 would link and prove nothing.
use std::os::raw::{c_char, c_int};

// SECOND FILE, DELIBERATELY. See report.rs: a `mod` in its own file is the hidden input the
// endpoint could not see, and this crate is now the check that it can.
mod report;

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: c_int, _argv: *const *const c_char) -> c_int {
    let from_env = std::env::args().count();
    let msg = report::line(argc, from_env);
    println!("{msg}");
    if from_env as c_int == argc { 0 } else { 1 }
}
