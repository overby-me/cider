//! The darlingserver-rs daemon entry point: the Rust equivalent of darlingserver.cpp's
//! main(). It brings up the container (private mount namespace, prefix overlay, a new
//! PID namespace for the guest init) and then runs the RPC server, routing each guest
//! call to its task and dispatching it through the shared Handler.
//!
//! Launched by darling.c the same way the C++ daemon is (as mapped-root inside a user
//! namespace, with argv = <prefix> <uid> <gid> <pipefd> <fix_perms>), plus env for the
//! relocatable paths: DSERVER_LIBEXEC_PATH, DSERVER_MLDR_PATH, and the init selector
//! (DSERVER_INIT / DARLING_NO_LAUNCHD). NOT runnable in the nix sandbox (needs root +
//! CAP_SYS_ADMIN); validated by splicing into a darling runtime. See
//! plan/rust-rewrite-eval.md (bucket B, the container main).

use darlingserver_rs::container::{self, Config};
use darlingserver_rs::handler::Handler;
use darlingserver_rs::registry::Registry;
use darlingserver_rs::rpc_io::{Message, PeerAddr};
use darlingserver_rs::rpc_wire;
use darlingserver_rs::sched;
use darlingserver_rs::server::Listener;
use std::cell::RefCell;
use std::collections::HashMap;
use std::os::raw::{c_int, c_void};
use std::rc::Rc;

/// A guest thread's inbox: the call waiting to be dispatched, the reply the doWork
/// microthread produced (possibly later, if the call blocked), and a stop flag.
#[derive(Default)]
struct Mailbox {
    pending: Option<Message>,
    reply: Option<Vec<u8>>,
    stop: bool,
}

/// Per guest thread: its mailbox + the address to send its replies back to.
struct Slot {
    mailbox: Rc<RefCell<Mailbox>>,
    peer: PeerAddr,
}

/// The guest init pid (namespace PID 1). When it dies the session is over and the daemon
/// exits -- the DGRAM socket has no EOF to signal this, so we watch SIGCHLD. A static is
/// the async-signal-safe way to reach it from the handler.
static mut INIT_PID: libc::pid_t = 0;

/// Reap dead guest children; when the container init exits, so do we.
extern "C" fn on_sigchld(_sig: c_int) {
    unsafe {
        let mut status: c_int = 0;
        loop {
            let r = libc::waitpid(-1, &mut status, libc::WNOHANG);
            if r <= 0 {
                break;
            }
            if r == INIT_PID {
                libc::_exit(0);
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cfg = match Config::from_args_and_env(&args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("darlingserver-rs: {e}");
            std::process::exit(1);
        }
    };
    unsafe { run(cfg) }
}

unsafe fn run(cfg: Config) -> ! {
    if libc::getuid() != 0 {
        // darling.c launches us as mapped-root; without it the privileged steps below
        // will fail with EPERM. Warn rather than hard-exit so the failure is legible.
        eprintln!("darlingserver-rs: warning: not running as root; container setup will fail");
    }

    // (Deferred vs the C++, all best-effort prefix work: rlimit bumps, setupUserHome,
    // darlingPreInit, fixPermissions, the writable-/nix overlay.)

    // Private mount namespace + the prefix overlay (needs root; before dropping privs).
    container::enter_mount_namespace().expect("darlingserver-rs: enter mount namespace");
    container::mount_prefix_overlay(&cfg.prefix, &cfg.libexec_path)
        .expect("darlingserver-rs: mount prefix overlay");

    // Tell the launching darling.c the container is set up.
    container::signal_launcher_ready(&cfg);

    // Fork the guest init into a new PID namespace. The child waits on child_wait[0] for
    // our go-ahead (the RPC socket must exist first), then execs the init.
    let mut child_wait = [0 as c_int; 2];
    assert_eq!(libc::pipe(child_wait.as_mut_ptr()), 0, "pipe");
    let init_pid = container::spawn_init_in_pid_namespace(&cfg, child_wait[0])
        .expect("darlingserver-rs: clone guest init");
    libc::close(child_wait[0]); // parent closes the read end

    // Exit the daemon when the guest init dies (the DGRAM socket gives no EOF).
    INIT_PID = init_pid;
    let mut sa: libc::sigaction = std::mem::zeroed();
    sa.sa_sigaction = on_sigchld as usize;
    sa.sa_flags = libc::SA_RESTART | libc::SA_NOCLDSTOP;
    libc::sigemptyset(&mut sa.sa_mask);
    libc::sigaction(libc::SIGCHLD, &sa, std::ptr::null_mut());

    // Parent: permanently drop privileges, then bring up XNU + the RPC server.
    container::perma_drop_privileges(cfg.original_uid, cfg.original_gid).ok();
    libc::prctl(libc::PR_SET_DUMPABLE, 1, 0, 0, 0);

    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let mut handler = Handler::new();
    let handler_ptr = &mut handler as *mut Handler;

    let sock_path = format!("{}/.darlingserver.sock", cfg.prefix);
    let listener = Listener::bind(&sock_path).expect("darlingserver-rs: bind RPC socket");

    // Socket is up: green-light the init child (it execs the guest, which will connect).
    let dot = b".";
    libc::write(child_wait[1], dot.as_ptr() as *const c_void, 1);
    libc::close(child_wait[1]);

    eprintln!("darlingserver-rs: container up (init pid {init_pid}); serving {sock_path}");

    // Serve forever. Each guest THREAD (nsid,tid) gets ONE persistent doWork microthread
    // bound to its task plus a mailbox -- the real darlingserver architecture. A thread's
    // calls run sequentially on that microthread (so its per-thread XNU state persists),
    // and a call that BLOCKS (e.g. a mach_msg receive) parks the microthread deep in its
    // stack, to be resumed later when another thread's send delivers the message. Because
    // such a reply is produced asynchronously, after every wake we scan all mailboxes and
    // flush any that are ready to their peers.
    listener.set_blocking();
    let mut slots: HashMap<(u32, u64), Slot> = HashMap::new();

    loop {
        let (msg, peer) = match listener.recv() {
            Ok(Some(x)) => x,
            _ => continue,
        };
        let hdr = match msg.header() {
            Some(h) => h,
            None => continue,
        };
        let nsid = hdr.pid as u32;
        let tid = hdr.tid as u64;
        let arch = hdr.architecture;
        // The guest's daemon-namespace pid (from SO_PASSCRED) is what process_vm_readv
        // needs; fall back to the header pid for the in-namespace case.
        let host_pid = msg.host_pid.unwrap_or(hdr.pid as c_int);
        reg.set_host_pid(nsid, host_pid);

        // Create this guest thread's doWork microthread + mailbox on first sighting.
        if !slots.contains_key(&(nsid, tid)) {
            let mailbox = Rc::new(RefCell::new(Mailbox::default()));
            let mb = mailbox.clone();
            reg.run_thread(
                nsid,
                tid,
                arch,
                Box::new(move || loop {
                    // Park until a call is queued (or we are told to stop).
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
                    let call = mb.borrow_mut().pending.take().unwrap();
                    let ch = call.header().unwrap();
                    // Bind this call's identity (the generated handlers get no header).
                    (*handler_ptr).set_current(ch.pid as u32, ch.tid as u64, host_pid, ch.architecture);
                    let reply = rpc_wire::dispatch(&mut *handler_ptr, &call);
                    // Diagnostic: surface any call the guest needs that is still ENOSYS.
                    if let Some(ref r) = reply {
                        if r.len() >= 8 && i32::from_ne_bytes([r[4], r[5], r[6], r[7]]) == rpc_wire::ENOSYS {
                            eprintln!("darlingserver-rs: UNIMPLEMENTED call {} (#{})", call.call_name().unwrap_or("?"), ch.number);
                        }
                    }
                    mb.borrow_mut().reply = reply;
                }),
            );
            slots.insert((nsid, tid), Slot { mailbox, peer: peer.clone() });
        }

        // Deliver the call to its thread and wake it (it may block mid-dispatch).
        {
            let slot = slots.get_mut(&(nsid, tid)).unwrap();
            slot.peer = peer;
            slot.mailbox.borrow_mut().pending = Some(msg);
        }
        reg.wake_thread(nsid, tid);
        sched::drain(); // run any OTHER threads unblocked as a side effect of this call

        // Flush every ready reply (this call's, plus any blocked call just unblocked).
        for slot in slots.values_mut() {
            let reply = slot.mailbox.borrow_mut().reply.take();
            if let Some(reply) = reply {
                listener.send(&reply, &[], &slot.peer).ok();
            }
        }
    }
}
