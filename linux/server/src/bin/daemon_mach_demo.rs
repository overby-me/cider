//! The minimal working darlingserver for the special-port traps: a real client PROCESS
//! makes Mach calls over a real unix socket, and the daemon serves each through the full
//! pipeline -- recv off the socket -> route to the client's task (registry) -> run the
//! shared Handler on a microthread via the generated dispatch -> reply over the socket.
//!
//! Uses a SEQPACKET socketpair (a genuine connected unix socket, but no filesystem path,
//! so it works under the nix build sandbox) with the client in a forked child. See
//! plan/rust-rewrite-eval.md (real-socket serving).

use darling::handler::Handler;
use darling::registry::Registry;
use darling::rpc_io::{recv_message, send_message};
use darling::rpc_wire::{self, callnum, DserverRpcCallhdr};
use darling::sched;
use std::cell::RefCell;
use std::mem::size_of;
use std::os::fd::RawFd;
use std::rc::Rc;

fn callhdr_bytes(number: u32, pid: i32, tid: i32) -> Vec<u8> {
    let hdr = DserverRpcCallhdr { number, pid, tid, architecture: 2 };
    unsafe {
        std::slice::from_raw_parts(&hdr as *const _ as *const u8, size_of::<DserverRpcCallhdr>()).to_vec()
    }
}

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    // A connected SEQPACKET socketpair: [daemon end, client end].
    let mut fds = [0 as RawFd; 2];
    assert_eq!(
        libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, fds.as_mut_ptr()),
        0,
        "socketpair"
    );
    let (daemon_fd, client_fd) = (fds[0], fds[1]);

    // The calls the client will make (all special-port traps: reply is a port name).
    let calls = [callnum::TASK_SELF_TRAP, callnum::HOST_SELF_TRAP, callnum::MACH_REPLY_PORT];

    let pid = libc::fork();
    assert!(pid >= 0, "fork");

    if pid == 0 {
        // ---------------- client process ----------------
        libc::close(daemon_fd);
        let cpid = std::process::id() as i32;
        let mut ok = true;
        for (i, &num) in calls.iter().enumerate() {
            let req = callhdr_bytes(num, cpid, cpid + i as i32);
            if send_message(client_fd, &req, &[]).is_err() {
                ok = false;
                break;
            }
            match recv_message(client_fd) {
                Ok(Some(reply)) if reply.data.len() >= 12 => {
                    let code = i32::from_ne_bytes(reply.data[4..8].try_into().unwrap());
                    let port = u32::from_ne_bytes(reply.data[8..12].try_into().unwrap());
                    if code != 0 || port == 0 {
                        ok = false;
                        break;
                    }
                }
                _ => {
                    ok = false;
                    break;
                }
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

    for _ in 0..calls.len() {
        let msg = match recv_message(daemon_fd) {
            Ok(Some(m)) => m,
            _ => break,
        };
        let hdr = msg.header().expect("callhdr");
        // Route to the client's task and run the handler on a microthread bound to it.
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

    // Reap the client; it exits 0 only if every reply was a valid port.
    let mut status = 0i32;
    libc::waitpid(pid, &mut status, 0);
    libc::close(daemon_fd);
    assert!(
        libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0,
        "client did not validate all mach replies (status {status})"
    );

    println!("DAEMON_MACH_OK: a real client process made task_self/host_self/mach_reply_port calls over a unix socket; the daemon routed each to the client's task and served it via the shared Handler + dispatch");
}
