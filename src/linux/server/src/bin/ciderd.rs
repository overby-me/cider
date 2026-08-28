//! The ciderd daemon entry point: the Rust equivalent of ciderd.cpp's
//! main(). It brings up the container (private mount namespace, prefix overlay, a new
//! PID namespace for the guest init) and then runs the RPC server, routing each guest
//! call to its task and dispatching it through the shared Handler.
//!
//! Launched by cider.c the same way the C++ daemon is (as mapped-root inside a user
//! namespace, with argv = <prefix> <uid> <gid> <pipefd> <fix_perms>), plus env for the
//! relocatable paths: DSERVER_LIBEXEC_PATH, DSERVER_MLDR_PATH, and the init selector
//! (DSERVER_INIT / DARLING_NO_LAUNCHD). NOT runnable in the nix sandbox (needs root +
//! CAP_SYS_ADMIN); validated by splicing into a cider runtime. See
//! docs/changelog.md (bucket B, the container main).

use cider::container::{self, Config};
use cider::handler::Handler;
use cider::kqchan::{MachPortKqchan, ProcKqchan};
use cider::registry::Registry;
use cider::rpc_io::{Message, PeerAddr};
use cider::rpc_wire;
use cider::s2c;
use cider::sched;
use cider::server::Listener;
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
    /// The wire `number` of the in-flight call, stashed so a call that blocks via a
    /// continuation can have its code-only reply rebuilt from it.
    call_number: u32,
    /// The result a continuation-based blocking call delivered (thread_syscall_return). The
    /// doWork loop stores only this SCALAR across the getcontext re-entry; the serve loop
    /// turns it into the reply bytes (allocating a Vec across the re-entry would be unsound).
    reply_code: Option<i32>,
    /// The BSD-trap retval (psynch) captured alongside reply_code when a psynch op unblocked
    /// via its continuation; folded into the deferred reply body. None for code-only calls.
    reply_retval: Option<u32>,
    /// This thread's guest socket address, so an S2C op it triggers mid-dispatch can send the
    /// S2C call to the right guest (set alongside the Slot peer on each incoming call).
    peer: Option<PeerAddr>,
    stop: bool,
}

/// Per guest thread: its mailbox + the address to send its replies back to.
struct Slot {
    mailbox: Rc<RefCell<Mailbox>>,
    peer: PeerAddr,
    /// An in-flight nested signal interrupt's mailbox. Present only between interrupt_enter and
    /// interrupt_exit for a thread interrupted while blocked mid-call. The interrupt runs on the
    /// thread's OWN microthread via a pushed activation (sched::push_activation), so the blocked
    /// call resumes + re-blocks after interrupt_exit. While set, the thread's RPCs route to this
    /// mailbox instead of resuming the blocked call directly. Task #58.
    interrupt: Option<Rc<RefCell<Mailbox>>>,
}

/// A code-only RPC reply (just the reply header) for a call that blocked via a continuation
/// and finished with `code`. XNU traps (semaphore/mach_msg/...) carry no reply body.
fn code_reply(number: u32, code: c_int) -> Vec<u8> {
    let hdr = rpc_wire::DserverRpcReplyhdr { number, code };
    unsafe {
        std::slice::from_raw_parts(&hdr as *const _ as *const u8, std::mem::size_of::<rpc_wire::DserverRpcReplyhdr>())
    }
    .to_vec()
}

/// Whether `DSERVER_TRACE_CALLS` is set (cached). Diagnostic tracing for the RPC receive/
/// reply path (the -111 interrupt race, task #44): logs each received call's (nsid,tid,
/// number) and any reply-send error.
fn trace_calls() -> bool {
    use std::sync::atomic::{AtomicU8, Ordering};
    static STATE: AtomicU8 = AtomicU8::new(2);
    match STATE.load(Ordering::Relaxed) {
        0 => false,
        1 => true,
        _ => {
            let on = std::env::var_os("DSERVER_TRACE_CALLS").is_some();
            STATE.store(on as u8, Ordering::Relaxed);
            on
        }
    }
}

/// Build the wire reply for a call that blocked via a continuation and finished with `code`.
/// The psynch ops (callnums 68..=76) each carry a u32 `retval` body -- their continuation
/// (psynch_mtxcontinue &c.) filled the retval slot captured here -- so append it after the
/// header; every other blocking call (semaphore/mach_msg/nanosleep) is code-only. Mirrors
/// C++'s sendBSDReply(code, retval) vs sendBasicReply(code). All nine psynch replies share
/// the layout {DserverRpcReplyhdr{number,code}, u32 retval}.
fn deferred_reply(number: u32, code: c_int, retval: Option<u32>) -> Vec<u8> {
    use rpc_wire::callnum;
    let base = number & !callnum::UNMANAGED_FLAG;
    if (callnum::PSYNCH_CVBROAD..=callnum::PSYNCH_RW_WRLOCK).contains(&base) {
        let mut v = code_reply(number, code);
        v.extend_from_slice(&retval.unwrap_or(0).to_ne_bytes());
        return v;
    }
    code_reply(number, code)
}

/// Process exactly ONE call for a guest thread's doWork loop: wait for a call, dispatch it,
/// and post the reply. Returns false when the thread should stop. This is a SEPARATE function
/// so the doWork loop's own frame stays free of drop-requiring locals (the Message lives
/// here): when a call blocks via a continuation, thread_syscall_return setcontexts to the
/// loop top and THIS frame is abandoned (its Message leaks -- rare, acceptable) without
/// corrupting the loop frame it returns into.
unsafe fn process_one_call(mb: &Rc<RefCell<Mailbox>>, handler_ptr: *mut Handler, host_pid: c_int) -> bool {
    loop {
        let ready = {
            let m = mb.borrow();
            m.pending.is_some() || m.stop
        };
        if ready {
            break;
        }
        // Parked at the doWork top waiting for the next call -- flag it so the serve loop knows
        // this microthread is ready for a new call, not blocked deep in a handler (task #58).
        let mt = sched::current();
        if !mt.is_null() {
            (*mt).set_at_dowork_top(true);
        }
        sched::suspend_current(None, std::ptr::null_mut(), std::ptr::null_mut());
    }
    // Dispatching (or stopping): no longer idle at the top.
    let mt = sched::current();
    if !mt.is_null() {
        (*mt).set_at_dowork_top(false);
    }
    if mb.borrow().stop {
        return false;
    }
    let call = mb.borrow_mut().pending.take().unwrap();
    let ch = call.header().unwrap();
    (*handler_ptr).set_current(ch.pid as u32, ch.tid as u64, host_pid, ch.architecture);
    // Tell the S2C layer which guest this dispatch is for, so a VM op it triggers (e.g.
    // task_allocate_pages) can send its S2C mmap to the right guest socket.
    if let Some(peer) = mb.borrow().peer.clone() {
        s2c::set_current(ch.pid as u32, ch.tid as u64, peer);
    }
    mb.borrow_mut().call_number = ch.number;
    let reply = rpc_wire::dispatch(&mut *handler_ptr, &call);
    // (reached only when dispatch RETURNED -- a non-blocking or stackful call; a
    // continuation-based block never returns here, it re-enters the loop via loop_top)
    let rfds = (*handler_ptr).take_reply_fds();
    if let Some(ref r) = reply {
        if r.len() >= 8 && i32::from_ne_bytes([r[4], r[5], r[6], r[7]]) == rpc_wire::ENOSYS {
            eprintln!("ciderd: UNIMPLEMENTED call {} (#{})", call.call_name().unwrap_or("?"), ch.number);
        }
    }
    let mut m = mb.borrow_mut();
    m.reply = reply;
    m.reply_fds = rfds;
    true
}

/// Async-signal-safe host-crash reporter: a segfault/abort in a daemon microthread would
/// otherwise die silently (no Rust panic, no init-death message), looking exactly like a
/// hang or the guest's -111. Print the signal number, then re-raise with the default handler
/// so the crash still propagates. Diagnostic for the multithread/psynch investigation.
extern "C" {
    fn backtrace(buffer: *mut *mut c_void, size: c_int) -> c_int;
    fn backtrace_symbols_fd(buffer: *const *mut c_void, size: c_int, fd: c_int);
}

/// Async-signal-safe: write "<label>0x<hex>\n" to stderr.
unsafe fn write_labeled_hex(label: &[u8], val: u64) {
    libc::write(2, label.as_ptr() as *const c_void, label.len());
    let mut buf = [0u8; 19];
    buf[0] = b'0';
    buf[1] = b'x';
    for i in 0..16 {
        let nib = ((val >> ((15 - i) * 4)) & 0xf) as u8;
        buf[2 + i] = if nib < 10 { b'0' + nib } else { b'a' + nib - 10 };
    }
    buf[18] = b'\n';
    libc::write(2, buf.as_ptr() as *const c_void, buf.len());
}

extern "C" fn crash_handler(sig: c_int, info: *mut libc::siginfo_t, ctx: *mut c_void) {
    let msg = b"ciderd: FATAL host signal ";
    let d = [b'0' + ((sig / 10) % 10) as u8, b'0' + (sig % 10) as u8, b'\n'];
    unsafe {
        libc::write(2, msg.as_ptr() as *const c_void, msg.len());
        libc::write(2, d.as_ptr() as *const c_void, d.len());
        // Fault address (si_addr, the second word of siginfo's _sifields on Linux x86_64)
        // and the crash PC (rip from the ucontext) -- these survive when the microthread
        // stack can't be unwound, and addr2line'ing rip names the exact faulting function.
        if !info.is_null() {
            let fault = *((info as *const u8).add(16) as *const u64);
            write_labeled_hex(b"  fault addr ", fault);
        }
        if !ctx.is_null() {
            let uc = ctx as *mut libc::ucontext_t;
            // The crash PC, named per arch (task A18): x86_64 keeps it in gregs[REG_RIP],
            // aarch64 in mcontext.pc. Same label so the two transcripts read alike.
            #[cfg(target_arch = "x86_64")]
            let pc = (*uc).uc_mcontext.gregs[libc::REG_RIP as usize] as u64;
            #[cfg(target_arch = "aarch64")]
            let pc = (*uc).uc_mcontext.pc as u64;
            write_labeled_hex(b"  pc ", pc);
        }
        let mut bt: [*mut c_void; 40] = [std::ptr::null_mut(); 40];
        let n = backtrace(bt.as_mut_ptr(), 40);
        backtrace_symbols_fd(bt.as_ptr(), n, 2);
        libc::signal(sig, libc::SIG_DFL);
        libc::raise(sig);
    }
}

unsafe fn install_crash_handler() {
    let mut sa: libc::sigaction = std::mem::zeroed();
    sa.sa_sigaction = crash_handler as usize;
    sa.sa_flags = libc::SA_SIGINFO;
    libc::sigemptyset(&mut sa.sa_mask);
    for &sig in &[libc::SIGSEGV, libc::SIGBUS, libc::SIGABRT, libc::SIGILL, libc::SIGFPE] {
        libc::sigaction(sig, &sa, std::ptr::null_mut());
    }
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
            eprintln!("ciderd: {e}");
            std::process::exit(1);
        }
    };
    unsafe { run(cfg) }
}

unsafe fn run(cfg: Config) -> ! {
    install_crash_handler();
    if libc::getuid() != 0 {
        // cider.c launches us as mapped-root; without it the privileged steps below
        // will fail with EPERM. Warn rather than hard-exit so the failure is legible.
        eprintln!("ciderd: warning: not running as root; container setup will fail");
    }

    // (Deferred vs the C++, all best-effort prefix work: rlimit bumps, setupUserHome,
    // ciderPreInit, fixPermissions, the writable-/nix overlay.)

    // Private mount namespace + the prefix overlay (needs root; before dropping privs).
    container::enter_mount_namespace().expect("ciderd: enter mount namespace");
    container::mount_prefix_overlay(&cfg.prefix, &cfg.libexec_path)
        .expect("ciderd: mount prefix overlay");
    // Optional writable native /nix for guest Nix (M1); best-effort, opt-in via the
    // .enable-writable-nix marker. Must happen while root, after the prefix overlay.
    container::mount_nix_overlay(&cfg.prefix);

    // Tell the launching cider.c the container is set up.
    container::signal_launcher_ready(&cfg);

    // Fork the guest init into a new PID namespace. The child waits on child_wait[0] for
    // our go-ahead (the RPC socket must exist first), then execs the init.
    let mut child_wait = [0 as c_int; 2];
    assert_eq!(libc::pipe(child_wait.as_mut_ptr()), 0, "pipe");
    let init_pid = container::spawn_init_in_pid_namespace(&cfg, child_wait[0])
        .expect("ciderd: clone guest init");
    libc::close(child_wait[0]); // parent closes the read end

    // Parent: permanently drop privileges, then bring up XNU + the RPC server.
    container::perma_drop_privileges(cfg.original_uid, cfg.original_gid).ok();
    libc::prctl(libc::PR_SET_DUMPABLE, 1, 0, 0, 0);

    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let mut handler = Handler::new();
    let handler_ptr = &mut handler as *mut Handler;

    let sock_path = format!("{}/.ciderd.sock", cfg.prefix);
    let listener = Listener::bind(&sock_path).expect("ciderd: bind RPC socket");

    // Socket is up: green-light the init child (it execs the guest, which will connect).
    let dot = b".";
    libc::write(child_wait[1], dot.as_ptr() as *const c_void, 1);
    libc::close(child_wait[1]);

    eprintln!("ciderd: container up (init pid {init_pid}); serving {sock_path}");

    // Serve forever via an epoll event loop multiplexing: the main RPC socket, the init
    // pidfd (its death -> the daemon exits, since the DGRAM socket has no EOF), and each
    // process kqueue channel's socket (guest modify/read) + target pidfd (target death ->
    // NOTE_EXIT). Each guest THREAD (nsid,tid) still gets ONE persistent doWork microthread
    // + mailbox; a call that BLOCKS parks its microthread and its reply is flushed when a
    // later event unblocks it.
    let mut slots: HashMap<(u32, u64), Slot> = HashMap::new();
    let mut kqchans: Vec<ProcKqchan> = Vec::new();
    let mut mach_kqchans: Vec<Box<MachPortKqchan>> = Vec::new();
    let mut consoles: Vec<RawFd> = Vec::new();

    let epfd = libc::epoll_create1(libc::EPOLL_CLOEXEC);
    let main_fd = listener.fd();
    // The socket S2C calls are sent from (and the guest replies to).
    s2c::set_listener_fd(main_fd);
    epoll_add(epfd, main_fd);
    let init_pidfd = libc::syscall(libc::SYS_pidfd_open, init_pid, 0) as RawFd;
    if init_pidfd >= 0 {
        epoll_add(epfd, init_pidfd);
    }
    // The XNU timer subsystem's timerfd: its expiry wakes sleeping guest threads.
    let timer_fd = sched::init_timer();
    if timer_fd >= 0 {
        epoll_add(epfd, timer_fd);
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
        if trace_calls() {
            eprintln!("ciderd: epoll wakeup ({n} events)");
        }
        for ev in &events[..n as usize] {
            let fd = ev.u64 as RawFd;
            if init_pidfd >= 0 && fd == init_pidfd {
                // Container init died: the session is over.
                eprintln!("ciderd: container init (pid {init_pid}) died -> daemon exit");
                libc::_exit(0);
            } else if timer_fd >= 0 && fd == timer_fd {
                // A timer expired: wake the XNU threads whose deadline passed, then flush
                // any replies (e.g. a completed nanosleep) their wake produced.
                sched::timer_fired(reg.kernel_task());
                flush_replies(&listener, &mut slots);
            } else if fd == main_fd {
                // Drain all pending RPC datagrams; dispatch each on its guest thread's
                // doWork microthread, flush replies, and register any kqchans it opened.
                while let Ok(Some((msg, peer))) = listener.recv() {
                    // checkout (call #2) = a guest thread exiting or execing: reap its microthread +
                    // slot after its reply flushes, or every thread leaks (captured before the move).
                    // The process's real teardown (free its task + threads) runs on its pidfd death
                    // (the "CIDER_PROCKQ target died" path), the reliable signal; a checkout alone
                    // cannot tell a thread that execs from the process's last exit.
                    let reap = msg.header().filter(|h| h.number == 2).map(|h| (h.pid as u32, h.tid as u64));
                    handle_call(&listener, &mut reg, handler_ptr, &mut slots, msg, peer);
                    flush_replies(&listener, &mut slots);
                    if let Some((rn, rt)) = reap {
                        reap_thread(&mut reg, &mut slots, rn, rt);
                    }
                    for kq in (*handler_ptr).take_pending_kqchans() {
                        epoll_add(epfd, kq.daemon_fd);
                        if kq.pidfd >= 0 {
                            epoll_add(epfd, kq.pidfd);
                        }
                        kqchans.push(kq);
                    }
                    // A task that changed host process has its death watch pointed at the old one,
                    // which never dies as far as anyone cares. Re-arm onto the new process.
                    for (nsid, new_pid) in (*handler_ptr).take_pending_pid_changes() {
                        for kq in kqchans.iter_mut().filter(|k| k.target_nsid == nsid) {
                            let old = kq.rearm(new_pid);
                            if old >= 0 {
                                epoll_del(epfd, old);
                                libc::close(old);
                            }
                            if kq.pidfd >= 0 {
                                epoll_add(epfd, kq.pidfd);
                            }
                        }
                    }
                    // Mach-port kqchans (task #54): only a daemon_fd to watch -- events arrive via
                    // the xnu-sys notification callback (fired inline on a sender's RPC), not epoll.
                    for kq in (*handler_ptr).take_pending_kqchans_mach() {
                        epoll_add(epfd, kq.daemon_fd);
                        mach_kqchans.push(kq);
                    }
                    // Guest console channels (console_open, task #60): monitor the daemon end.
                    for cfd in (*handler_ptr).take_pending_consoles() {
                        epoll_add(epfd, cfd);
                        consoles.push(cfd);
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
                // Traced because the consumer of this is launchd's restart path: no NOTE_EXIT means
                // a job's MachService ports never go back into launchd's demand set and it can never
                // be started again. launchd reaps secd and securityd and never trustd.
                let dead_nsid = kqchans[idx].target_nsid;
                eprintln!("CIDER_PROCKQ target died, nsid={} host pid={}",
                          dead_nsid, kqchans[idx].target_host_pid);
                epoll_del(epfd, fd);
                libc::close(fd);
                kqchans[idx].pidfd = -1;
                kqchans[idx].on_target_died();
                // A process that dies via its pidfd never checks its threads out, so its doWork
                // microthreads sit parked and its task never frees -> ~1 task + thread leaked per
                // process, ciderd OOMs on build workloads (task #33). Tear it down on the LAST live
                // watcher (so a multiply-watched pid frees once), on a kernel-task microthread via
                // run_on_task: the IPC teardown reads current_thread(), null on the bare epoll loop
                // -> null deref (same reason task CREATE runs on a microthread). The body runs
                // synchronously, so the raw reg/handler pointers outlive it.
                if !kqchans.iter().any(|k| k.target_nsid == dead_nsid && k.pidfd >= 0) {
                    slots.retain(|(n, _), _| *n != dead_nsid);
                    let kt = reg.kernel_task();
                    let reg_ptr: *mut Registry = &mut reg;
                    let hp = handler_ptr;
                    sched::run_on_task(kt, Box::new(move || unsafe {
                        (*reg_ptr).discard_parked(dead_nsid);
                        (*hp).prune_process(dead_nsid);
                        (*reg_ptr).despawn_task(dead_nsid);
                    }));
                }
            } else if let Some(idx) = mach_kqchans.iter().position(|k| k.daemon_fd == fd) {
                // Guest sent modify/read on a mach-port kqchan socket, or hung up (task #54).
                if !mach_kqchans[idx].on_readable() {
                    let kq = mach_kqchans.remove(idx);
                    epoll_del(epfd, kq.daemon_fd);
                    // dropping kq disables the xnu_sys notifications + closes the fd
                }
            } else if let Some(idx) = consoles.iter().position(|&c| c == fd) {
                // Guest console output (console_open, task #60): drain + log to the daemon stderr.
                let mut buf = [0u8; 512];
                loop {
                    let n = libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len());
                    if n > 0 {
                        eprint!("[guest console] {}", String::from_utf8_lossy(&buf[..n as usize]));
                    } else {
                        if n == 0 {
                            // guest closed the console: stop monitoring it.
                            epoll_del(epfd, fd);
                            libc::close(fd);
                            consoles.remove(idx);
                        }
                        break;
                    }
                }
            }
        }
    }
    libc::close(epfd);
    std::process::exit(0);
}

/// Dispatch one RPC datagram on the calling guest thread's persistent doWork microthread
/// (created on first sighting), waking it and draining any threads it unblocks.
unsafe fn handle_call(
    listener: &Listener,
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
    // An S2C reply (call_number 0x52cca11) from the guest: not a new call, but the answer to
    // an S2C mmap the daemon sent. Hand it to the microthread suspended in s2c::perform_mmap
    // (mid-RPC) and resume it; its real RPC reply flushes after handle_call returns.
    if s2c::is_s2c(hdr.number) {
        if let Some((rn, rt)) = s2c::deliver_reply(msg.data) {
            reg.wake_thread(rn, rt);
            sched::drain();
        }
        return;
    }

    // The guest's daemon-namespace pid (SO_PASSCRED) is what process_vm_readv needs.
    let host_pid = msg.host_pid.unwrap_or(hdr.pid as c_int);
    reg.set_host_pid(nsid, host_pid);

    if trace_calls() {
        let known = slots.contains_key(&(nsid, tid));
        let queued = slots.get(&(nsid, tid)).map(|s| s.mailbox.borrow().pending.is_some()).unwrap_or(false);
        // number & !UNMANAGED_FLAG for readability; interrupt_enter is #14.
        eprintln!(
            "ciderd: RECV #{} nsid={} tid={} known_thread={} prev_call_still_queued={}",
            hdr.number & !rpc_wire::callnum::UNMANAGED_FLAG, nsid, tid, known, queued
        );
    }

    let base_number = hdr.number & !rpc_wire::callnum::UNMANAGED_FLAG;

    // ---- Nested signal-interrupt routing (task #58) ----
    // (a) An interrupt is already in progress on this thread: route the RPC to its nested
    //     microthread rather than the still-suspended blocked call.
    if slots.get(&(nsid, tid)).map(|s| s.interrupt.is_some()).unwrap_or(false) {
        run_interrupt_call(listener, reg, slots, nsid, tid, msg, peer, base_number);
        return;
    }
    // (b) interrupt_enter arriving for a thread blocked DEEP in a handler (not idle at the
    //     doWork top): run its sigexc sequence NESTED so it never resumes the blocked call
    //     (which reads a bogus wait_result and panics the xnu-sys). A thread idle at the top
    //     just takes the normal path below.
    if base_number == 14 {
        if let Some(mt) = reg.parked_mt(nsid, tid) {
            if !(*mt).is_at_dowork_top() {
                start_interrupt(listener, reg, handler_ptr, slots, nsid, tid, host_pid, msg, peer);
                return;
            }
        }
    }

    if !slots.contains_key(&(nsid, tid)) {
        let mailbox = Rc::new(RefCell::new(Mailbox::default()));
        let mb = mailbox.clone();
        reg.run_thread(
            nsid,
            tid,
            arch,
            // The persistent doWork loop (its getcontext re-entry point lives in
            // sched::run_dowork_loop's frame, so a continuation-based block can setcontext
            // back to it). `sr` is Some(code) when re-entering after such a block -- stash the
            // SCALAR (the serve loop builds the reply bytes); else do one normal call.
            Box::new(move || {
                sched::run_dowork_loop(|sr| {
                    if let Some(code) = sr {
                        // A psynch op's continuation set the retval slot before returning
                        // here; capture it now (still on this microthread) so the deferred
                        // reply carries {code, retval}. Harmless (ignored) for code-only calls.
                        let mut m = mb.borrow_mut();
                        m.reply_code = Some(code);
                        m.reply_retval = Some(sched::current_bsd_retval());
                        true
                    } else {
                        process_one_call(&mb, handler_ptr, host_pid)
                    }
                });
            }),
        );
        slots.insert((nsid, tid), Slot { mailbox, peer: peer.clone(), interrupt: None });
    }

    {
        let slot = slots.get_mut(&(nsid, tid)).unwrap();
        slot.peer = peer.clone();
        let mut m = slot.mailbox.borrow_mut();
        m.peer = Some(peer);
        m.pending = Some(msg);
    }
    reg.wake_thread(nsid, tid);
    sched::drain();
}

/// Start a nested signal interrupt on guest thread (nsid,tid), blocked mid-call. PUSH a fresh
/// activation onto ITS OWN microthread (saving the blocked call), install an interrupt doWork
/// loop reading a fresh mailbox, dispatch interrupt_enter on it, stash the mailbox on the Slot,
/// and flush the reply. The blocked call resumes + re-blocks on this same microthread after
/// interrupt_exit (re-setting TH_WAIT), exactly like C++ Thread::doWork. Task #58 (approach 1).
unsafe fn start_interrupt(
    listener: &Listener,
    reg: &mut Registry,
    handler_ptr: *mut Handler,
    slots: &mut HashMap<(u32, u64), Slot>,
    nsid: u32,
    tid: u64,
    host_pid: c_int,
    msg: Message,
    peer: PeerAddr,
) {
    let mt = match reg.parked_mt(nsid, tid) {
        Some(m) => m,
        None => return,
    };
    let imb = Rc::new(RefCell::new(Mailbox::default()));
    {
        let mut m = imb.borrow_mut();
        m.peer = Some(peer.clone());
        m.pending = Some(msg);
    }
    let mb = imb.clone();
    (*mt).push_activation(Box::new(move || {
        sched::run_dowork_loop(|sr| {
            if let Some(code) = sr {
                let mut m = mb.borrow_mut();
                m.reply_code = Some(code);
                m.reply_retval = Some(sched::current_bsd_retval());
                true
            } else {
                process_one_call(&mb, handler_ptr, host_pid)
            }
        });
    }));
    if let Some(slot) = slots.get_mut(&(nsid, tid)) {
        slot.peer = peer.clone();
        slot.interrupt = Some(imb.clone());
    }
    sched::run(mt);
    sched::drain();
    flush_mailbox(listener, &imb, &peer, (nsid, tid));
}

/// Route an RPC to the in-progress nested interrupt on (nsid,tid), run it on the thread's OWN
/// microthread, and flush its reply. On interrupt_exit, stop the interrupt activation, pop it to
/// restore the blocked call, and run the microthread so the blocked call RESUMES and re-blocks
/// (re-setting TH_WAIT so the timer can wake it). Task #58 (approach 1).
unsafe fn run_interrupt_call(
    listener: &Listener,
    reg: &mut Registry,
    slots: &mut HashMap<(u32, u64), Slot>,
    nsid: u32,
    tid: u64,
    msg: Message,
    peer: PeerAddr,
    base_number: u32,
) {
    let mt = match reg.parked_mt(nsid, tid) {
        Some(m) => m,
        None => return,
    };
    let imb = {
        let slot = match slots.get_mut(&(nsid, tid)) {
            Some(s) => s,
            None => return,
        };
        slot.peer = peer.clone();
        let imb = slot.interrupt.as_ref().unwrap().clone();
        {
            let mut m = imb.borrow_mut();
            m.peer = Some(peer.clone());
            m.pending = Some(msg);
        }
        imb
    };
    sched::run(mt);
    sched::drain();
    flush_mailbox(listener, &imb, &peer, (nsid, tid));
    if base_number == 15 {
        // interrupt_exit: stop the interrupt activation so its doWork loop breaks and it
        // finishes; pop it to restore the blocked call; then run the microthread so the blocked
        // call RESUMES and re-blocks (re-sets TH_WAIT). The timer then wakes it normally.
        imb.borrow_mut().stop = true;
        sched::run(mt);
        sched::drain();
        (*mt).pop_activation();
        sched::run(mt);
        sched::drain();
        if let Some(slot) = slots.get_mut(&(nsid, tid)) {
            slot.interrupt = None;
        }
    }
}

/// Reap an exited guest thread after its `checkout` reply has been flushed: stop its doWork
/// microthread (so its two big stacks are freed) and drop its Slot. Without this, every
/// guest thread ever seen leaks a parked microthread -- a nix build's thousands of configure
/// subprocesses then exhaust memory and kill the daemon. `stop` makes the parked
/// process_one_call loop break; wake_thread runs it once so it exits and the registry
/// reclaims its box.
unsafe fn reap_thread(reg: &mut Registry, slots: &mut HashMap<(u32, u64), Slot>, nsid: u32, tid: u64) {
    if let Some(slot) = slots.get(&(nsid, tid)) {
        slot.mailbox.borrow_mut().stop = true;
    }
    reg.wake_thread(nsid, tid);
    sched::drain();
    slots.remove(&(nsid, tid));
}

/// Flush every mailbox that has a ready reply to its peer (attaching any reply fds via
/// SCM_RIGHTS, then closing the daemon's copies). Covers both the just-dispatched call and
/// any blocked call unblocked as a side effect.
/// Send a mailbox's pending reply (or a continuation-deferred code-reply) to `peer`,
/// attaching + closing any reply fds. Shared by the normal per-thread flush and the
/// nested-interrupt flush.
unsafe fn flush_mailbox(listener: &Listener, mb: &Rc<RefCell<Mailbox>>, peer: &PeerAddr, who: (u32, u64)) {
    let (reply, rfds, callnum) = {
        let mut m = mb.borrow_mut();
        // A continuation-based blocking call's result (reply_code) takes precedence: its
        // dispatch never assigned `reply`, so build the code-only reply from the stashed
        // number + result. Otherwise use the dispatch reply.
        let reply = if let Some(code) = m.reply_code.take() {
            Some(deferred_reply(m.call_number, code, m.reply_retval.take()))
        } else {
            m.reply.take()
        };
        (reply, std::mem::take(&mut m.reply_fds), m.call_number)
    };
    if let Some(reply) = reply {
        // The counterpart to the RECV trace. Without it a call that is received and parked
        // forever looks exactly like one that was received and answered, which is the whole
        // question when a guest thread is stuck in recvmsg (task #47).
        if trace_calls() {
            eprintln!(
                "ciderd: SEND reply #{} nsid={} tid={} fds={}",
                callnum, who.0, who.1, rfds.len()
            );
        }
        if let Err(e) = listener.send(&reply, &rfds, peer) {
            if trace_calls() {
                eprintln!("ciderd: SEND reply failed: {} (raw={:?})", e, e.raw_os_error());
            }
        }
        for fd in rfds {
            libc::close(fd);
        }
    }
}

unsafe fn flush_replies(listener: &Listener, slots: &mut HashMap<(u32, u64), Slot>) {
    for (&(nsid, tid), slot) in slots.iter_mut() {
        flush_mailbox(listener, &slot.mailbox, &slot.peer, (nsid, tid));
        // A nested signal interrupt in progress on this thread has its own mailbox.
        if let Some(ref imb) = slot.interrupt {
            flush_mailbox(listener, imb, &slot.peer, (nsid, tid));
        }
    }
}
