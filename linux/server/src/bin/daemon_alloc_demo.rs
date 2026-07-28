//! Cross-process copyout over a real socket: a client PROCESS calls mach_port_allocate,
//! and the daemon writes the allocated port NAME back into the CLIENT's memory. Unlike
//! the earlier in-process demos (where the "guest" was the daemon itself), here the
//! guest is a separate forked process, so the copyout is a genuine cross-process
//! process_vm_writev(client_pid, ...) via the write_memory hook -- exactly what the real
//! daemon does. The client provides its own buffer address; the daemon's task for the
//! client carries the client's pid, so the copyout lands in the client. See
//! plan/rust-rewrite-eval.md (handler breadth over the socket).

use darling::handler::Handler;
use darling::mach;
use darling::registry::Registry;
use darling::rpc_io::{recv_message, send_message};
use darling::rpc_wire::{
    self, callnum, CallMachPortAllocate, DserverRpcCallhdr, RpcCallMachPortAllocate,
};
use darling::sched;
use std::cell::RefCell;
use std::mem::size_of;
use std::os::fd::RawFd;
use std::rc::Rc;

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
        // ---------------- client process ----------------
        libc::close(daemon_fd);
        let cpid = std::process::id() as i32;
        let mut ok = true;

        // 1) task_self_trap -> the target task port (in the reply body).
        let req = as_bytes(&DserverRpcCallhdr { number: callnum::TASK_SELF_TRAP, pid: cpid, tid: cpid, architecture: 2 });
        let _ = send_message(client_fd, &req, &[]);
        let target = match recv_message(client_fd) {
            Ok(Some(r)) if r.data.len() >= 12 => u32::from_ne_bytes(r.data[8..12].try_into().unwrap()),
            _ => 0,
        };
        if target == 0 {
            ok = false;
        }

        // 2) mach_port_allocate(target, RECEIVE, &name_buf): the daemon copies the
        //    allocated name into OUR name_buf (cross-process). The reply is just the code.
        let mut name_buf: u32 = 0;
        if ok {
            let call = RpcCallMachPortAllocate {
                header: DserverRpcCallhdr { number: callnum::MACH_PORT_ALLOCATE, pid: cpid, tid: cpid + 1, architecture: 2 },
                body: CallMachPortAllocate {
                    target,
                    right: mach::MACH_PORT_RIGHT_RECEIVE,
                    name: &name_buf as *const u32 as u64,
                },
            };
            let _ = send_message(client_fd, &as_bytes(&call), &[]);
            match recv_message(client_fd) {
                Ok(Some(r)) if r.data.len() >= 8 => {
                    let code = i32::from_ne_bytes(r.data[4..8].try_into().unwrap());
                    let name = std::ptr::read_volatile(&name_buf); // daemon wrote this into our memory
                    if code != 0 || name == 0 {
                        ok = false;
                    }
                }
                _ => ok = false,
            }
        }
        libc::close(client_fd);
        std::process::exit(if ok { 0 } else { 1 });
    }

    // ---------------- daemon process ----------------
    libc::close(client_fd);
    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let mut handler = Handler::new();
    let handler_ptr = &mut handler as *mut Handler;

    // Serve the client's two calls (task_self_trap, then mach_port_allocate).
    for _ in 0..2 {
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
        "client did not get a valid port copied into its memory (status {status})"
    );

    println!("DAEMON_ALLOC_OK: a client process called mach_port_allocate over the socket; the daemon allocated the right and copied the name into the CLIENT's memory (cross-process write_memory)");
}
