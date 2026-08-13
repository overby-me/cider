//! First real Mach port-right operations served through XNU on a guest task:
//! mach_port_allocate and mach_port_deallocate. mach_port_allocate returns its result
//! by writing the allocated port NAME back into the guest's memory (copyout), so this
//! composes the port machinery with the task_write_memory hook: the XNU trap's copyout
//! runs copyoutmap -> xnu_sys_hooks->task_write_memory -> process_vm_writev (memory.c).
//! The demo's guest task carries the demo's OWN pid, so that copyout lands in a local.
//! See docs/changelog.md (bucket A, mach IPC core).

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

    // The guest task carries THIS process's pid, so the trap's copyout (write_memory ->
    // process_vm_writev) lands in our own address space (the stack locals below).
    let pid: u32 = std::process::id();
    let tid: u64 = pid as u64;
    let arch: u32 = 2; // x86_64

    // (kr_recv, receive_name, kr_dead, dead_name, kr_dealloc) captured out of the microthread.
    let out: Rc<RefCell<Option<(i32, u32, i32, u32, i32)>>> = Rc::new(RefCell::new(None));
    let out2 = out.clone();

    let parked = reg.run_thread(
        pid,
        tid,
        arch,
        Box::new(move || {
            let target = mach::task_self_trap(); // the guest task's self port (0x103)

            // 1) Allocate a RECEIVE right; the XNU trap copies the name OUT to `name`.
            let mut name: u32 = 0;
            let kr_recv =
                mach::port_allocate(target, mach::MACH_PORT_RIGHT_RECEIVE, &mut name as *mut u32 as u64);
            let name = std::ptr::read_volatile(&name); // reload after the copyout

            // 2) Allocate a DEAD_NAME right and deallocate it -- a clean allocate/
            //    deallocate round trip (dead names, unlike receive rights, deallocate).
            let mut dead: u32 = 0;
            let kr_dead = mach::port_allocate(
                target,
                mach::MACH_PORT_RIGHT_DEAD_NAME,
                &mut dead as *mut u32 as u64,
            );
            let dead = std::ptr::read_volatile(&dead);
            let kr_dealloc = mach::port_deallocate(target, dead);

            *out2.borrow_mut() = Some((kr_recv, name, kr_dead, dead, kr_dealloc));
        }),
    );
    assert!(!parked, "port ops are non-blocking; the thread should run to completion");

    let (kr_recv, name, kr_dead, dead, kr_dealloc) =
        out.borrow_mut().take().expect("microthread did not complete");
    eprintln!(
        "[mach_port] allocate(RECEIVE) kr={kr_recv} name=0x{name:x}; allocate(DEAD_NAME) kr={kr_dead} dead=0x{dead:x}; deallocate(dead) kr={kr_dealloc}"
    );

    assert_eq!(kr_recv, mach::KERN_SUCCESS, "mach_port_allocate(RECEIVE) should succeed");
    assert!(name != 0, "allocated receive-right name copied out must be non-null");
    assert_eq!(kr_dead, mach::KERN_SUCCESS, "mach_port_allocate(DEAD_NAME) should succeed");
    assert!(dead != 0, "allocated dead name copied out must be non-null");
    assert_eq!(kr_dealloc, mach::KERN_SUCCESS, "mach_port_deallocate(dead) should succeed");

    println!("MACH_PORT_OK: mach_port_allocate copied a valid name out to guest memory (write_memory hook) and mach_port_deallocate released a dead name, through XNU on a guest task");
}
