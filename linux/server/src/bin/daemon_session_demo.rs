//! A realistic full guest SESSION over the socket, served on ONE persistent doWork
//! thread -- the real darlingserver architecture end to end. A client PROCESS checks in,
//! runs a sequence of Mach calls (task_self_trap -> mach_port_allocate -> a mach_msg
//! loopback), and checks out; the daemon feeds every call to a single long-lived
//! microthread bound to the client's task (created once, parked between calls and woken
//! by the socket loop), which dispatches each through the shared Handler and posts the
//! reply. This composes checkin/checkout + the doWork loop + real-socket serving +
//! cross-process memory + the mach engine into one session. See PLAN.md.

use darling::handler::Handler;
use darling::mach;
use darling::registry::Registry;
use darling::rpc_io::{recv_message, send_message, Message};
use darling::rpc_wire::{
    self, callnum, CallCheckin, CallCheckout, CallMachMsgOverwrite, CallMachPortAllocate,
    DserverRpcCallhdr, RpcCallCheckin, RpcCallCheckout, RpcCallMachMsgOverwrite,
    RpcCallMachPortAllocate,
};
use darling::sched;
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

const MAGIC: u32 = 0x5E55_1010;

#[derive(Default)]
struct Mailbox {
    pending: Option<Message>,
    reply: Option<Vec<u8>>,
    stop: bool,
}

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

    // The client's single guest thread (its getpid == the fork return `pid`).
    let client_pid = pid as u32;
    let tid = pid as u64;
    let arch = 2u32;

    let mailbox = Rc::new(RefCell::new(Mailbox::default()));

    // ONE persistent doWork thread for the whole session: wait for a call, dispatch it,
    // post the reply, park for the next. Bound to the client's task (all its Mach calls
    // run on the same task/thread, so ports allocated in one call persist to the next).
    let mb = mailbox.clone();
    let parked = reg.run_thread(
        client_pid,
        tid,
        arch,
        Box::new(move || loop {
            loop {
                let ready = {
                    let m = mb.borrow();
                    m.pending.is_some() || m.stop
                };
                if ready {
                    break;
                }
                sched::suspend_current(None, std::ptr::null_mut(), std::ptr::null_mut());
            }
            if mb.borrow().stop {
                break;
            }
            let msg = mb.borrow_mut().pending.take().unwrap();
            let reply = rpc_wire::dispatch(&mut *handler_ptr, &msg);
            mb.borrow_mut().reply = reply;
        }),
    );
    assert!(parked, "the doWork thread should park waiting for the first call");

    // Socket loop: feed each received call to the doWork thread, return its reply.
    let mut served = 0u32;
    loop {
        let msg = match recv_message(daemon_fd) {
            Ok(Some(m)) => m,
            _ => break,
        };
        mailbox.borrow_mut().pending = Some(msg);
        reg.wake_thread(client_pid, tid);
        served += 1;
        let reply = mailbox.borrow_mut().reply.take();
        if let Some(reply) = reply {
            send_message(daemon_fd, &reply, &[]).ok();
        }
    }
    // Client closed the connection: stop the doWork thread.
    mailbox.borrow_mut().stop = true;
    reg.wake_thread(client_pid, tid);

    let mut status = 0i32;
    libc::waitpid(pid, &mut status, 0);
    libc::close(daemon_fd);
    eprintln!("[session] served {served} calls on one persistent doWork thread for pid {client_pid}");
    assert!(
        libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0,
        "client session failed (status {status})"
    );

    println!("DAEMON_SESSION_OK: a client ran a full session (checkin -> task_self_trap -> mach_port_allocate -> mach_msg -> checkout) over the socket, all served on ONE persistent doWork thread bound to the client's task");
}

/// The client's session: checkin, a few Mach calls, checkout. Returns true iff every
/// reply was successful and the mach_msg round-tripped.
unsafe fn client(fd: RawFd, cpid: i32) -> bool {
    let tid = cpid; // one guest thread makes every call
    let send_recv = |req: &[u8]| -> Option<Vec<u8>> {
        send_message(fd, req, &[]).ok()?;
        recv_message(fd).ok().flatten().map(|m| m.data)
    };
    let hdr = |num: u32| DserverRpcCallhdr { number: num, pid: cpid, tid, architecture: 2 };
    let code_ok = |r: &[u8]| r.len() >= 8 && i32::from_ne_bytes(r[4..8].try_into().unwrap()) == 0;

    // 1) checkin
    let checkin = RpcCallCheckin { header: hdr(callnum::CHECKIN), body: CallCheckin { is_fork: false, stack_hint: 0, lifetime_listener_pipe: -1 } };
    match send_recv(&as_bytes(&checkin)) {
        Some(r) if code_ok(&r) => {}
        _ => return false,
    }

    // 2) task_self_trap -> target
    let target = match send_recv(&as_bytes(&hdr(callnum::TASK_SELF_TRAP))) {
        Some(r) if r.len() >= 12 => u32::from_ne_bytes(r[8..12].try_into().unwrap()),
        _ => return false,
    };
    if target == 0 {
        return false;
    }

    // 3) mach_port_allocate(RECEIVE) -> port name copied into port_name
    let mut port_name: u32 = 0;
    let alloc = RpcCallMachPortAllocate { header: hdr(callnum::MACH_PORT_ALLOCATE), body: CallMachPortAllocate { target, right: mach::MACH_PORT_RIGHT_RECEIVE, name: &port_name as *const u32 as u64 } };
    match send_recv(&as_bytes(&alloc)) {
        Some(r) if code_ok(&r) => {}
        _ => return false,
    }
    let port = std::ptr::read_volatile(&port_name);
    if port == 0 {
        return false;
    }

    // 4) mach_msg loopback on that port
    let mut send_hdr = MachMsgHeader { bits: mach::msgh_bits(mach::MACH_MSG_TYPE_MAKE_SEND, 0), size: size_of::<MachMsgHeader>() as u32, remote_port: port, local_port: 0, voucher_port: 0, id: MAGIC };
    let mut rcv_buf = [0u8; 64];
    let msgcall = RpcCallMachMsgOverwrite {
        header: hdr(callnum::MACH_MSG_OVERWRITE),
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
    match send_recv(&as_bytes(&msgcall)) {
        Some(r) if code_ok(&r) => {}
        _ => return false,
    }
    let rhdr = std::ptr::read_unaligned(rcv_buf.as_ptr() as *const MachMsgHeader);
    if rhdr.id != MAGIC {
        return false;
    }

    // 5) checkout
    let checkout = RpcCallCheckout { header: hdr(callnum::CHECKOUT), body: CallCheckout { exec_listener_pipe: -1, executing_macho: false } };
    matches!(send_recv(&as_bytes(&checkout)), Some(r) if code_ok(&r))
}
