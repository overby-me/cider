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
use darlingserver_rs::kqchan::ProcKqchan;
use darlingserver_rs::registry::Registry;
use darlingserver_rs::rpc_io::{Message, PeerAddr};
use darlingserver_rs::rpc_wire;
use darlingserver_rs::sched;
use darlingserver_rs::server::Listener;
use std::cell::RefCell;
use std::collections::HashMap;
use std::os::fd::RawFd;
use std::os::raw::{c_int, c_void};
use std::rc::Rc;

/// A guest thread's inbox: the call waiting to be dispatched, the reply the doWork
/// microthread produced (possibly later, if the call blocked), any fds to attach to that
/// reply (SCM_RIGHTS, e.g. a kqchan socket), and a stop flag.
#[derive(Default)]
struct Mailbox {
    pending: Option<Message>,
    reply: Option<Vec<u8>>,
    reply_fds: Vec<RawFd>,
    stop: bool,
}

/// Per guest thread: its mailbox + the address to send its replies back to.
struct Slot {
    mailbox: Rc<RefCell<Mailbox>>,
    peer: PeerAddr,
}

unsafe fn epoll_add(epfd: RawFd, fd: RawFd) {
    let mut ev = libc::epoll_event { events: libc::EPOLLIN as u32, u64: fd as u64 };
    libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, fd, &mut ev);
}
unsafe fn epoll_del(epfd: RawFd, fd: RawFd) {
    libc::epoll_ctl(epfd, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut());
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

    // Serve forever via an epoll event loop multiplexing: the main RPC socket, the init
    // pidfd (its death -> the daemon exits, since the DGRAM socket has no EOF), and each
    // process kqueue channel's socket (guest modify/read) + target pidfd (target death ->
    // NOTE_EXIT). Each guest THREAD (nsid,tid) still gets ONE persistent doWork microthread
    // + mailbox; a call that BLOCKS parks its microthread and its reply is flushed when a
    // later event unblocks it.
    let mut slots: HashMap<(u32, u64), Slot> = HashMap::new();
    let mut kqchans: Vec<ProcKqchan> = Vec::new();

    let epfd = libc::epoll_create1(libc::EPOLL_CLOEXEC);
    let main_fd = listener.fd();
    epoll_add(epfd, main_fd);
    let init_pidfd = libc::syscall(libc::SYS_pidfd_open, init_pid, 0) as RawFd;
    if init_pidfd >= 0 {
        epoll_add(epfd, init_pidfd);
    }

    let mut events: [libc::epoll_event; 16] = std::mem::zeroed();
    loop {
        let n = libc::epoll_wait(epfd, events.as_mut_ptr(), events.len() as c_int, -1);
        if n < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        for ev in &events[..n as usize] {
            let fd = ev.u64 as RawFd;
            if init_pidfd >= 0 && fd == init_pidfd {
                // Container init died: the session is over.
                libc::_exit(0);
            } else if fd == main_fd {
                // Drain all pending RPC datagrams; dispatch each on its guest thread's
                // doWork microthread, flush replies, and register any kqchans it opened.
                while let Ok(Some((msg, peer))) = listener.recv() {
                    handle_call(&listener, &mut reg, handler_ptr, &mut slots, msg, peer);
                    flush_replies(&listener, &mut slots);
                    for kq in (*handler_ptr).take_pending_kqchans() {
                        epoll_add(epfd, kq.daemon_fd);
                        if kq.pidfd >= 0 {
                            epoll_add(epfd, kq.pidfd);
                        }
                        kqchans.push(kq);
                    }
                }
            } else if let Some(idx) = kqchans.iter().position(|k| k.daemon_fd == fd) {
                // Guest sent a message on a kqchan socket (proc_modify/proc_read) or hung up.
                if !kqchans[idx].on_readable() {
                    let kq = kqchans.remove(idx);
                    epoll_del(epfd, kq.daemon_fd);
                    if kq.pidfd >= 0 {
                        epoll_del(epfd, kq.pidfd);
                    }
                    // dropping kq closes its fds
                }
            } else if let Some(idx) = kqchans.iter().position(|k| k.pidfd == fd) {
                // A watched process died -> deliver NOTE_EXIT; stop watching the pidfd.
                epoll_del(epfd, fd);
                libc::close(fd);
                kqchans[idx].pidfd = -1;
                kqchans[idx].on_target_died();
            }
        }
    }
    libc::close(epfd);
    std::process::exit(0);
}

/// Dispatch one RPC datagram on the calling guest thread's persistent doWork microthread
/// (created on first sighting), waking it and draining any threads it unblocks.
unsafe fn handle_call(
    _listener: &Listener,
    reg: &mut Registry,
    handler_ptr: *mut Handler,
    slots: &mut HashMap<(u32, u64), Slot>,
    msg: Message,
    peer: PeerAddr,
) {
    let hdr = match msg.header() {
        Some(h) => h,
        None => return,
    };
    let nsid = hdr.pid as u32;
    let tid = hdr.tid as u64;
    let arch = hdr.architecture;
    // The guest's daemon-namespace pid (SO_PASSCRED) is what process_vm_readv needs.
    let host_pid = msg.host_pid.unwrap_or(hdr.pid as c_int);
    reg.set_host_pid(nsid, host_pid);

    if !slots.contains_key(&(nsid, tid)) {
        let mailbox = Rc::new(RefCell::new(Mailbox::default()));
        let mb = mailbox.clone();
        reg.run_thread(
            nsid,
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
                let call = mb.borrow_mut().pending.take().unwrap();
                let ch = call.header().unwrap();
                (*handler_ptr).set_current(ch.pid as u32, ch.tid as u64, host_pid, ch.architecture);
                let reply = rpc_wire::dispatch(&mut *handler_ptr, &call);
                let rfds = (*handler_ptr).take_reply_fds();
                if let Some(ref r) = reply {
                    if r.len() >= 8 && i32::from_ne_bytes([r[4], r[5], r[6], r[7]]) == rpc_wire::ENOSYS {
                        eprintln!("darlingserver-rs: UNIMPLEMENTED call {} (#{})", call.call_name().unwrap_or("?"), ch.number);
                    }
                }
                let mut m = mb.borrow_mut();
                m.reply = reply;
                m.reply_fds = rfds;
            }),
        );
        slots.insert((nsid, tid), Slot { mailbox, peer: peer.clone() });
    }

    {
        let slot = slots.get_mut(&(nsid, tid)).unwrap();
        slot.peer = peer;
        slot.mailbox.borrow_mut().pending = Some(msg);
    }
    reg.wake_thread(nsid, tid);
    sched::drain();
}

/// Flush every mailbox that has a ready reply to its peer (attaching any reply fds via
/// SCM_RIGHTS, then closing the daemon's copies). Covers both the just-dispatched call and
/// any blocked call unblocked as a side effect.
unsafe fn flush_replies(listener: &Listener, slots: &mut HashMap<(u32, u64), Slot>) {
    for slot in slots.values_mut() {
        let (reply, rfds) = {
            let mut m = slot.mailbox.borrow_mut();
            (m.reply.take(), std::mem::take(&mut m.reply_fds))
        };
        if let Some(reply) = reply {
            listener.send(&reply, &rfds, &slot.peer).ok();
            for fd in rfds {
                libc::close(fd);
            }
        }
    }
}
