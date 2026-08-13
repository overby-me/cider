//! A real BLOCKING mach_msg receive across two guest threads (bucket A, the async IPC
//! pattern) -- the capstone of the mach core + persistent threads. One thread does
//! mach_msg(RCV) on an empty port and BLOCKS (thread_block with a continuation, so its
//! stack is discarded); a second thread on the same task sends a message to that port,
//! which wakes the receiver (thread_resume -> run queue); draining runs the receiver's
//! continuation, which completes the receive (copyout via write_memory) and delivers
//! its result via thread_syscall_return -- the hook this demo wires up.
//!
//! Because the receiver's stack is discarded when it blocks, its receive buffer lives
//! on the heap (stable address) and its result comes back through the syscall_return
//! hook, not a Rust return. The guest task carries the demo's own pid so the message
//! copies target our own memory. See docs/changelog.md (bucket A + B.2).

use cider::mach;
use cider::registry::Registry;
use cider::sched;
use std::cell::Cell;
use std::rc::Rc;

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

const MAGIC: u32 = 0xCAFE_BABE;
const HDR: u32 = core::mem::size_of::<MachMsgHeader>() as u32; // 24

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let pid: u32 = std::process::id();
    let arch: u32 = 2;

    // A heap receive buffer: its address is stable even though the receiver's microthread
    // stack is discarded when it blocks (the continuation copies out to this address).
    let rcv_buf: Box<[u8; 64]> = Box::new([0u8; 64]);
    let rcv_addr = rcv_buf.as_ptr() as u64;

    // Setup thread (tid 1): allocate a receive-right port P on the guest task.
    let port = Rc::new(Cell::new(0u32));
    {
        let port = port.clone();
        let mt = reg.spawn_on(
            pid,
            1,
            arch,
            Box::new(move || {
                let target = mach::task_self_trap();
                let mut p = 0u32;
                let kr = mach::port_allocate(target, mach::MACH_PORT_RIGHT_RECEIVE, &mut p as *mut u32 as u64);
                assert_eq!(kr, 0, "port allocation should succeed");
                port.set(std::ptr::read_volatile(&p));
            }),
        );
        sched::run(mt);
        sched::drain();
    }
    let p = port.get();
    assert!(p != 0, "setup did not allocate a port");

    // Receiver thread (tid 2): mach_msg(RCV) on the EMPTY port -> blocks.
    let recv_mt = reg.spawn_on(
        pid,
        2,
        arch,
        Box::new(move || {
            // Receive-only into the heap buffer; no message yet, so this blocks. On the
            // blocking path the code after this never runs (the continuation delivers
            // the result via thread_syscall_return).
            let _ = mach::msg_overwrite(rcv_addr, mach::MACH_RCV_MSG, 0, 64, p, 0, 0, 0);
        }),
    );
    sched::run(recv_mt);
    assert!(
        (*recv_mt).is_suspended() && !(*recv_mt).is_finished(),
        "the receiver must block on the empty port"
    );
    eprintln!("[blkmsg] receiver blocked on port 0x{p:x} (empty queue)");

    // Sender thread (tid 3): send a message to P -> wakes the blocked receiver.
    let send_mt = reg.spawn_on(
        pid,
        3,
        arch,
        Box::new(move || {
            let mut send = MachMsgHeader {
                bits: mach::msgh_bits(mach::MACH_MSG_TYPE_MAKE_SEND, 0),
                size: HDR,
                remote_port: p,
                local_port: 0,
                voucher_port: 0,
                id: MAGIC,
            };
            let kr = mach::msg_overwrite(&mut send as *mut MachMsgHeader as u64, mach::MACH_SEND_MSG, HDR, 0, 0, 0, 0, 0);
            assert_eq!(kr, 0, "send should succeed");
        }),
    );
    sched::run(send_mt);
    // The send woke the receiver (thread_resume -> run queue); run it to completion.
    sched::drain();
    eprintln!("[blkmsg] sender delivered id=0x{MAGIC:x}; drain resumed the receiver's continuation");

    // The blocking receive completed via its continuation + thread_syscall_return.
    let recv_kr = (*recv_mt).take_syscall_return();
    // The received message was copied out to the heap buffer during the continuation.
    let rhdr = std::ptr::read_unaligned(rcv_buf.as_ptr() as *const MachMsgHeader);
    eprintln!(
        "[blkmsg] receiver syscall_return={recv_kr:?}; received id=0x{:x} size={}",
        rhdr.id, rhdr.size
    );

    assert_eq!(
        recv_kr,
        Some(0),
        "the blocking receive should complete with MACH_MSG_SUCCESS via syscall_return"
    );
    assert_eq!(rhdr.id, MAGIC, "the received message id must equal what the sender sent");

    println!("BLOCKING_MSG_OK: a thread blocked on mach_msg(RCV), a second thread's send woke it, and the receive completed via the continuation + thread_syscall_return");
}
