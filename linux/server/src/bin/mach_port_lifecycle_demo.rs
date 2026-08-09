//! A full Mach port-name lifecycle served through XNU on a guest task, exercising more
//! port ops (bucket A): allocate a receive right, query its type (mach_port_type,
//! copied out via the write_memory hook), destroy it with mach_port_mod_refs(-1), then
//! confirm the name is gone (mach_port_type now returns KERN_INVALID_NAME). The guest
//! task carries the demo's own pid so the type copyout lands in a local. See
//! PLAN.md (bucket A, mach IPC core).

use cider::mach;
use cider::registry::Registry;
use cider::sched;
use std::cell::RefCell;
use std::rc::Rc;

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    let kt = sched::init();
    let mut reg = Registry::new(kt);

    let pid: u32 = std::process::id();
    let tid: u64 = pid as u64;
    let arch: u32 = 2; // x86_64

    // (kr_alloc, name, kr_type, ty, kr_mod, kr_type_after) out of the microthread.
    let out: Rc<RefCell<Option<(i32, u32, i32, u32, i32, i32)>>> = Rc::new(RefCell::new(None));
    let out2 = out.clone();

    let parked = reg.run_thread(
        pid,
        tid,
        arch,
        Box::new(move || {
            let target = mach::task_self_trap();

            // Allocate a receive right.
            let mut name: u32 = 0;
            let kr_alloc =
                mach::port_allocate(target, mach::MACH_PORT_RIGHT_RECEIVE, &mut name as *mut u32 as u64);
            let name = std::ptr::read_volatile(&name);

            // Query its type -> should carry the RECEIVE bit (copied out to `ty`).
            let mut ty: u32 = 0;
            let kr_type = mach::port_type(target, name, &mut ty as *mut u32 as u64);
            let ty = std::ptr::read_volatile(&ty);

            // Destroy the receive right (delta -1); the name is released.
            let kr_mod = mach::port_mod_refs(target, name, mach::MACH_PORT_RIGHT_RECEIVE, -1);

            // Query the type again -> the name should no longer exist.
            let mut ty2: u32 = 0;
            let kr_type_after = mach::port_type(target, name, &mut ty2 as *mut u32 as u64);

            *out2.borrow_mut() = Some((kr_alloc, name, kr_type, ty, kr_mod, kr_type_after));
        }),
    );
    assert!(!parked, "port ops are non-blocking; the thread should run to completion");

    let (kr_alloc, name, kr_type, ty, kr_mod, kr_type_after) =
        out.borrow_mut().take().expect("microthread did not complete");
    eprintln!(
        "[lifecycle] allocate kr={kr_alloc} name=0x{name:x}; type kr={kr_type} ty=0x{ty:x}; mod_refs(-1) kr={kr_mod}; type-after kr={kr_type_after}"
    );

    assert_eq!(kr_alloc, mach::KERN_SUCCESS, "allocate(RECEIVE) should succeed");
    assert!(name != 0, "allocated name must be non-null");
    assert_eq!(kr_type, mach::KERN_SUCCESS, "mach_port_type should succeed");
    assert!(
        ty & mach::MACH_PORT_TYPE_RECEIVE != 0,
        "type of a receive right must carry the RECEIVE bit (got 0x{ty:x})"
    );
    assert_eq!(kr_mod, mach::KERN_SUCCESS, "mod_refs(-1) should destroy the receive right");
    assert_eq!(
        kr_type_after,
        mach::KERN_INVALID_NAME,
        "after destruction the name must be invalid (got kr={kr_type_after})"
    );

    println!("MACH_PORT_LIFECYCLE_OK: allocate receive right -> query type (RECEIVE) -> mod_refs(-1) destroy -> name now invalid, all through XNU on a guest task");
}
