//! mach_msg_overwrite served through real XNU on a guest task (bucket A, the mach IPC
//! core): a self-loopback. Allocate a receive-right port, then in ONE mach_msg call
//! with MACH_SEND_MSG|MACH_RCV_MSG send a header-only message to that port (destination
//! disposition MAKE_SEND, so no separate send right is needed) and receive it back.
//!
//! This composes everything: the trap copies the message IN from the guest buffer
//! (copyinmsg -> read_memory hook), XNU routes it through the port's ipc_mqueue, and
//! the receive copies it OUT to the guest buffer (copyoutmsg -> write_memory hook). The
//! guest task carries the demo's own pid, so both copies target our own memory. The
//! round trip is proven by the message id surviving. See PLAN.md.

use cider::mach;
use cider::registry::Registry;
use cider::sched;
use std::cell::RefCell;
use std::rc::Rc;

/// The user-space mach_msg_header_t (trap ABI: 4-byte port names), 24 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MachMsgHeader {
    bits: u32,
    size: u32,
    remote_port: u32,
    local_port: u32,
    voucher_port: u32,
    id: u32,
}

const MAGIC: u32 = 0x1234_5678;

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    let kt = sched::init();
    let mut reg = Registry::new(kt);

    let pid: u32 = std::process::id();
    let tid: u64 = pid as u64;
    let arch: u32 = 2; // x86_64

    // (kr_alloc, port, kr_msg, rcv_id, rcv_size, rcv_bits) out of the microthread.
    let out: Rc<RefCell<Option<(i32, u32, i32, u32, u32, u32)>>> = Rc::new(RefCell::new(None));
    let out2 = out.clone();

    let parked = reg.run_thread(
        pid,
        tid,
        arch,
        Box::new(move || {
            let target = mach::task_self_trap();

            // A port we hold the receive right for.
            let mut port: u32 = 0;
            let kr_alloc =
                mach::port_allocate(target, mach::MACH_PORT_RIGHT_RECEIVE, &mut port as *mut u32 as u64);
            let port = std::ptr::read_volatile(&port);

            // Build a header-only message addressed to `port` (MAKE_SEND destination).
            let mut send = MachMsgHeader {
                bits: mach::msgh_bits(mach::MACH_MSG_TYPE_MAKE_SEND, 0),
                size: core::mem::size_of::<MachMsgHeader>() as u32, // 24
                remote_port: port,
                local_port: 0,
                voucher_port: 0,
                id: MAGIC,
            };

            // Receive buffer (room for the 24-byte header + a trailer).
            let mut rcv = [0u8; 64];

            let kr_msg = mach::msg_overwrite(
                &mut send as *mut MachMsgHeader as u64,      // msg (send)
                mach::MACH_SEND_MSG | mach::MACH_RCV_MSG,     // send then receive
                core::mem::size_of::<MachMsgHeader>() as u32, // send_size = 24
                rcv.len() as u32,                             // rcv_size
                port,                                         // rcv_name
                0,                                            // timeout (none)
                0,                                            // priority
                rcv.as_mut_ptr() as u64,                      // rcv_msg (receive)
            );

            // Decode the received header the trap copied out into `rcv`.
            let rhdr = std::ptr::read_unaligned(rcv.as_ptr() as *const MachMsgHeader);

            *out2.borrow_mut() = Some((kr_alloc, port, kr_msg, rhdr.id, rhdr.size, rhdr.bits));
        }),
    );
    assert!(!parked, "the loopback message is available immediately; receive must not block");

    let (kr_alloc, port, kr_msg, rcv_id, rcv_size, rcv_bits) =
        out.borrow_mut().take().expect("microthread did not complete");
    eprintln!(
        "[mach_msg] port=0x{port:x} (alloc kr={kr_alloc}); mach_msg kr={kr_msg}; received id=0x{rcv_id:x} size={rcv_size} bits=0x{rcv_bits:x}"
    );

    assert_eq!(kr_alloc, mach::KERN_SUCCESS, "mach_port_allocate should succeed");
    assert!(port != 0, "allocated port name must be non-null");
    assert_eq!(kr_msg, 0, "mach_msg (send+receive) should return MACH_MSG_SUCCESS");
    assert_eq!(rcv_id, MAGIC, "the received message id must equal the sent id (round trip)");

    println!("MACH_MSG_OK: sent a message to a self-port and received it back through XNU (copyin via read_memory, route through ipc_mqueue, copyout via write_memory)");
}
