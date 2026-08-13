//! Stage 0 link proof: link the real C xnu-sys and run xnu_sys_init to completion,
//! now via the reusable `sched` library (which owns the xnu_sys FFI + hook vtable).
//! Builds only when XNU_SYS_LIB points at the cider build's static libs.

fn main() {
    // sched::init() installs the Rust hook vtable, calls xnu_sys_init (which runs the
    // full XNU subsystem init through those hooks), and returns the kernel task.
    let kt = unsafe { cider::sched::init() };
    assert!(!kt.is_null(), "kernel task");
    println!("STAGE0_OK: linked real xnu-sys and ran xnu_sys_init via the sched lib");
}
