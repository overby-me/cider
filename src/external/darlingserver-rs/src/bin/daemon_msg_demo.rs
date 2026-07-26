//! The culmination: a real client PROCESS runs a full mach_msg send/receive loopback
//! OVER THE SOCKET, served by the daemon. The client allocates a port, builds a message
//! in its own memory, and issues mach_msg_overwrite; the daemon copies the message IN
//! from the client (copyinmsg -> read_memory -> process_vm_readv(client)), routes it
//! through XNU's ipc_mqueue, and copies the received message OUT to the client
//! (copyoutmsg -> write_memory -> process_vm_writev(client)). Both copies cross the
//! process boundary, exactly as the real daemon does. The round trip is proven by the
//! message id surviving. See plan/rust-rewrite-eval.md (handler breadth over the socket).

use darlingserver_rs::handler::Handler;
use darlingserver_rs::mach;
use darlingserver_rs::registry::Registry;
use darlingserver_rs::rpc_io::{recv_message, send_message};
use darlingserver_rs::rpc_wire::{
    self, callnum, CallMachMsgOverwrite, CallMachPortAllocate, DserverRpcCallhdr,
    RpcCallMachMsgOverwrite, RpcCallMachPortAllocate,
};
use darlingserver_rs::sched;
use std::cell::RefCell;
use std::mem::size_of;
use std::os::fd::RawFd;
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

const MAGIC: u32 = 0xFEED_FACE;

fn as_bytes<T>(v: &T) -> Vec<u8> {
    unsafe { std::slice::from_raw_parts(v as *const T as *const u8, size_of::<T>()).to_vec() }
}

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    let mut fds = [0 as RawFd; 2];
    assert_eq!(libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, fds.as_mut_ptr()), 0, "socketpair");
    let (daemon_fd, client_fd) = (fds[0], fds[1]);

    let pid = libc::fork();
    assert!(pid >= 0, "fork");
    if pid == 0 {
        libc::close(daemon_fd);
        let ok = client(client_fd, std::process::id() as i32);
        libc::close(client_fd);
        std::process::exit(if ok { 0 } else { 1 });
    }

    // ---------------- daemon ----------------
    libc::close(client_fd);
    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let mut handler = Handler::new();
    let handler_ptr = &mut handler as *mut Handler;

    // Serve the client's three calls (task_self_trap, mach_port_allocate, mach_msg).
    for _ in 0..3 {
        let msg = match recv_message(daemon_fd) {
            Ok(Some(m)) => m,
            _ => break,
        };
        let hdr = msg.header().expect("callhdr");
        let slot: Rc<RefCell<Option<Vec<u8>>>> = Rc::new(RefCell::new(None));
        let out = slot.clone();
        let msg_c = msg.clone();
        let mt = reg.spawn_on(
            hdr.pid as u32,
            hdr.tid as u64,
            hdr.architecture,
            Box::new(move || {
                *out.borrow_mut() = rpc_wire::dispatch(&mut *handler_ptr, &msg_c);
            }),
        );
        sched::run(mt);
        sched::drain();
        let reply = slot.borrow_mut().take();
        if let Some(reply) = reply {
            send_message(daemon_fd, &reply, &[]).ok();
        }
    }

    let mut status = 0i32;
    libc::waitpid(pid, &mut status, 0);
    libc::close(daemon_fd);
    assert!(
        libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0,
        "client mach_msg loopback over the socket failed (status {status})"
    );

    println!("DAEMON_MSG_OK: a client process ran a mach_msg send/receive loopback over the socket; the daemon copied the message in from and out to the CLIENT's memory and routed it through XNU");
}

/// The client's request/reply helper: send bytes, return the reply's data bytes.
unsafe fn client(fd: RawFd, cpid: i32) -> bool {
    let send_recv = |req: &[u8]| -> Option<Vec<u8>> {
        send_message(fd, req, &[]).ok()?;
        recv_message(fd).ok().flatten().map(|m| m.data)
    };

    // 1) task_self_trap -> target task port (reply body).
    let r = match send_recv(&as_bytes(&DserverRpcCallhdr {
        number: callnum::TASK_SELF_TRAP,
        pid: cpid,
        tid: cpid,
        architecture: 2,
    })) {
        Some(r) if r.len() >= 12 => r,
        _ => return false,
    };
    let target = u32::from_ne_bytes(r[8..12].try_into().unwrap());
    if target == 0 {
        return false;
    }

    // 2) mach_port_allocate(RECEIVE) -> a port name copied into our `port_name`.
    let mut port_name: u32 = 0;
    let alloc = RpcCallMachPortAllocate {
        header: DserverRpcCallhdr { number: callnum::MACH_PORT_ALLOCATE, pid: cpid, tid: cpid + 1, architecture: 2 },
        body: CallMachPortAllocate { target, right: mach::MACH_PORT_RIGHT_RECEIVE, name: &port_name as *const u32 as u64 },
    };
    let r = match send_recv(&as_bytes(&alloc)) {
        Some(r) if r.len() >= 8 => r,
        _ => return false,
    };
    if i32::from_ne_bytes(r[4..8].try_into().unwrap()) != 0 {
        return false;
    }
    let port = std::ptr::read_volatile(&port_name);
    if port == 0 {
        return false;
    }

    // 3) mach_msg loopback: send a header-only message to `port` and receive it back.
    let mut send_hdr = MachMsgHeader {
        bits: mach::msgh_bits(mach::MACH_MSG_TYPE_MAKE_SEND, 0),
        size: size_of::<MachMsgHeader>() as u32,
        remote_port: port,
        local_port: 0,
        voucher_port: 0,
        id: MAGIC,
    };
    let mut rcv_buf = [0u8; 64];
    let msgcall = RpcCallMachMsgOverwrite {
        header: DserverRpcCallhdr { number: callnum::MACH_MSG_OVERWRITE, pid: cpid, tid: cpid + 2, architecture: 2 },
        body: CallMachMsgOverwrite {
            msg: &mut send_hdr as *mut MachMsgHeader as u64,
            option: mach::MACH_SEND_MSG | mach::MACH_RCV_MSG,
            send_size: size_of::<MachMsgHeader>() as u32,
            rcv_size: rcv_buf.len() as u32,
            rcv_name: port,
            timeout: 0,
            priority: 0,
            rcv_msg: rcv_buf.as_mut_ptr() as u64,
        },
    };
    let r = match send_recv(&as_bytes(&msgcall)) {
        Some(r) if r.len() >= 8 => r,
        _ => return false,
    };
    if i32::from_ne_bytes(r[4..8].try_into().unwrap()) != 0 {
        return false;
    }

    let rhdr = std::ptr::read_unaligned(rcv_buf.as_ptr() as *const MachMsgHeader);
    rhdr.id == MAGIC
}
