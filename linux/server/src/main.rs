//! Stage 0 link proof: link the real C duct-tape and run dtape_init to completion,
//! now via the reusable `sched` library (which owns the dtape FFI + hook vtable).
//! Builds only when DUCT_TAPE_LIB points at the darling build's static libs.

fn main() {
    // sched::init() installs the Rust hook vtable, calls dtape_init (which runs the
    // full XNU subsystem init through those hooks), and returns the kernel task.
    let kt = unsafe { darling::sched::init() };
    assert!(!kt.is_null(), "kernel task");
    println!("STAGE0_OK: linked real duct-tape and ran dtape_init via the sched lib");
}
