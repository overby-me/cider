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
use darlingserver_rs::rpc_wire;
use darlingserver_rs::sched;
use darlingserver_rs::server::Listener;
use std::cell::RefCell;
use std::os::raw::{c_int, c_void};
use std::rc::Rc;

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

    // Parent: permanently drop privileges, then bring up XNU + the RPC server.
    container::perma_drop_privileges(cfg.original_uid, cfg.original_gid).ok();
    libc::prctl(libc::PR_SET_DUMPABLE, 1, 0, 0, 0);

    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let mut handler = Handler;
    let handler_ptr = &mut handler as *mut Handler;

    let sock_path = format!("{}/.darlingserver.sock", cfg.prefix);
    let listener = Listener::bind(&sock_path).expect("darlingserver-rs: bind RPC socket");

    // Socket is up: green-light the init child (it execs the guest, which will connect).
    let dot = b".";
    libc::write(child_wait[1], dot.as_ptr() as *const c_void, 1);
    libc::close(child_wait[1]);

    eprintln!("darlingserver-rs: container up (init pid {init_pid}); serving {sock_path}");

    // Serve forever: route each call to the guest's task, dispatch on a microthread bound
    // to it through the shared Handler, and reply. (Per-connection persistent doWork
    // threads -- daemon_session_demo -- are the refinement; this uses a microthread per
    // call, which is correct but less efficient.)
    listener
        .run(usize::MAX, |msg| {
            let hdr = msg.header()?;
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
            let r = slot.borrow_mut().take();
            r
        })
        .expect("darlingserver-rs: serve loop");

    // Listener::run only returns on error; keep the never-type contract.
    std::process::exit(0);
}
