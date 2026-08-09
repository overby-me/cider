//! The persistent-thread doWork loop (bucket B.2, the multi-call half): a single
//! long-lived guest thread serves MANY RPC calls over its lifetime, parking between
//! them and resuming on the same stack -- the real ciderd Thread model, versus a
//! fresh microthread per call. Composes persistent threads (park/wake) with the
//! generated dispatch: the loop waits for a call, dispatches it, posts the reply, then
//! parks for the next; a per-thread stack counter proves the SAME thread served them
//! all. See PLAN.md (bucket B.2).

use cider::mach;
use cider::registry::Registry;
use cider::rpc_io::Message;
use cider::rpc_wire::{self, callnum, DserverRpcCallhdr, ReplyTaskSelfTrap};
use cider::sched;
use std::cell::RefCell;
use std::os::fd::RawFd;
use std::rc::Rc;

/// The daemon's handler (just task_self_trap here, to keep the loop's focus on the
/// thread model rather than breadth).
struct H;
impl rpc_wire::RpcHandler for H {
    fn task_self_trap(&mut self, _fds: &[RawFd]) -> Result<ReplyTaskSelfTrap, i32> {
        Ok(ReplyTaskSelfTrap { port_name: unsafe { mach::task_self_trap() } })
    }
}

/// Mailbox between the daemon and the long-lived guest thread.
#[derive(Default)]
struct Mailbox {
    pending: Option<Message>,
    reply: Option<Vec<u8>>,
    stop: bool,
    served: u32,
}

fn loop_body(mb: Rc<RefCell<Mailbox>>) -> Box<dyn FnOnce()> {
    Box::new(move || {
        let mut h = H;
        let mut served: u32 = 0; // per-thread state, lives on the microthread's stack
        loop {
            // Wait for the next call (or a stop signal), parking while idle.
            loop {
                let ready = {
                    let m = mb.borrow();
                    m.pending.is_some() || m.stop
                };
                if ready {
                    break;
                }
                unsafe { sched::suspend_current(None, std::ptr::null_mut(), std::ptr::null_mut()) };
            }
            if mb.borrow().stop {
                break;
            }
            let msg = mb.borrow_mut().pending.take().unwrap();
            served += 1;
            let reply = rpc_wire::dispatch(&mut h, &msg);
            let mut m = mb.borrow_mut();
            m.reply = reply;
            m.served = served;
        }
        mb.borrow_mut().served = served;
    })
}

fn task_self_trap_request(pid: u32, tid: u64) -> Message {
    let hdr = DserverRpcCallhdr { number: callnum::TASK_SELF_TRAP, pid: pid as i32, tid: tid as i32, architecture: 2 };
    let data = unsafe {
        std::slice::from_raw_parts(&hdr as *const _ as *const u8, std::mem::size_of::<DserverRpcCallhdr>()).to_vec()
    };
    Message { data, fds: vec![], host_pid: None }
}

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let pid: u32 = 9000;
    let tid: u64 = 7;
    let arch: u32 = 2;

    let mb = Rc::new(RefCell::new(Mailbox::default()));

    // Spawn the long-lived thread; it parks waiting for its first call.
    let parked = reg.run_thread(pid, tid, arch, loop_body(mb.clone()));
    assert!(parked, "the doWork loop thread should park waiting for its first call");

    // Serve several calls on the SAME thread; collect each reply's port name.
    let mut ports = Vec::new();
    for i in 0..3 {
        mb.borrow_mut().pending = Some(task_self_trap_request(pid, tid));
        let still_parked = reg.wake_thread(pid, tid);
        assert!(still_parked, "thread should park again after serving call {i}");
        let reply = mb.borrow_mut().reply.take().expect("handler produced a reply");
        let port = u32::from_ne_bytes(reply[8..12].try_into().unwrap());
        ports.push(port);
    }

    // Stop the loop; the thread finishes.
    mb.borrow_mut().stop = true;
    let still_parked = reg.wake_thread(pid, tid);
    assert!(!still_parked, "thread should finish after the stop signal");

    let served = mb.borrow().served;
    eprintln!("[loop] one thread served {served} calls; task-self ports = {ports:x?}");

    assert_eq!(served, 3, "the SAME long-lived thread must have served all 3 calls");
    assert!(ports.iter().all(|&p| p != 0), "every reply carried a valid port name");
    assert!(ports.windows(2).all(|w| w[0] == w[1]), "all replies name the same task self port (same task)");

    println!("THREAD_LOOP_OK: one persistent guest thread served 3 RPC calls via dispatch, parking between them with per-thread state preserved (the doWork loop)");
}
