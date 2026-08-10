//! First real Mach calls served by the Rust daemon: the special-port traps
//! (task_self_trap / host_self_trap / thread_self_trap / mach_reply_port). Each runs
//! through the real XNU xnu-sys on a microthread bound to a guest task and returns a
//! valid Mach port name -- proving the daemon can serve Mach operations, the first
//! step toward mach_msg. task_self_trap is ALSO driven through the generated
//! dispatch() so the full RPC path (decode -> handler -> encode) is exercised end to
//! end. See PLAN.md (bucket A, mach IPC core).

use cider::mach;
use cider::registry::Registry;
use cider::rpc_io::Message;
use cider::rpc_wire::{
    self, callnum, DserverRpcCallhdr, ReplyHostSelfTrap, ReplyMachReplyPort, ReplyTaskSelfTrap,
    ReplyThreadSelfTrap,
};
use cider::sched;
use std::cell::RefCell;
use std::mem::size_of;
use std::os::fd::RawFd;
use std::rc::Rc;

/// The daemon's handler for the special-port traps. Each mirrors call.cpp: call the
/// xnu_sys trap on the current task/thread, reply with the port name.
struct Traps;
impl rpc_wire::RpcHandler for Traps {
    fn task_self_trap(&mut self, _fds: &[RawFd]) -> Result<ReplyTaskSelfTrap, i32> {
        Ok(ReplyTaskSelfTrap { port_name: unsafe { mach::task_self_trap() } })
    }
    fn host_self_trap(&mut self, _fds: &[RawFd]) -> Result<ReplyHostSelfTrap, i32> {
        Ok(ReplyHostSelfTrap { port_name: unsafe { mach::host_self_trap() } })
    }
    fn thread_self_trap(&mut self, _fds: &[RawFd]) -> Result<ReplyThreadSelfTrap, i32> {
        Ok(ReplyThreadSelfTrap { port_name: unsafe { mach::thread_self_trap() } })
    }
    fn mach_reply_port(&mut self, _fds: &[RawFd]) -> Result<ReplyMachReplyPort, i32> {
        Ok(ReplyMachReplyPort { port_name: unsafe { mach::mach_reply_port() } })
    }
}

fn as_bytes<T>(v: &T) -> Vec<u8> {
    unsafe { std::slice::from_raw_parts(v as *const T as *const u8, size_of::<T>()).to_vec() }
}

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    let kt = sched::init();
    let mut reg = Registry::new(kt);

    let pid: u32 = 4242;
    let tid: u64 = 4242;
    let arch: u32 = 2; // x86_64 (matches the wire architecture the guest sends)

    // Results captured out of the cooperative microthread.
    let out: Rc<RefCell<Option<(u32, u32, u32, u32, u32)>>> = Rc::new(RefCell::new(None));
    let out2 = out.clone();

    let mt = reg.spawn_on(
        pid,
        tid,
        arch,
        Box::new(move || {
            // (a) direct: the four traps run on THIS guest task/thread via the xnu-sys.
            let task_self = mach::task_self_trap();
            let host_self = mach::host_self_trap();
            let thread_self = mach::thread_self_trap();
            let reply_port = mach::mach_reply_port();

            // (b) full path: drive task_self_trap through the generated dispatch().
            let mut h = Traps;
            let hdr = DserverRpcCallhdr {
                number: callnum::TASK_SELF_TRAP,
                pid: pid as i32,
                tid: tid as i32,
                architecture: arch,
            };
            let msg = Message { data: as_bytes(&hdr), fds: vec![], host_pid: None };
            let reply = rpc_wire::dispatch(&mut h, &msg).expect("task_self_trap produced no reply");
            // reply layout: replyhdr { number:u32, code:i32 } then body { port_name:u32 }.
            let code = i32::from_ne_bytes(reply[4..8].try_into().unwrap());
            let dispatched = u32::from_ne_bytes(reply[8..12].try_into().unwrap());
            assert_eq!(code, 0, "task_self_trap reply code should be 0");
            assert_eq!(dispatched, task_self, "dispatch port must equal the direct trap");

            *out2.borrow_mut() = Some((task_self, host_self, thread_self, reply_port, dispatched));
        }),
    );
    sched::run(mt);
    sched::drain();

    let (task_self, host_self, thread_self, reply_port, dispatched) =
        out.borrow_mut().take().expect("microthread did not complete");

    eprintln!(
        "[mach] task_self=0x{task_self:x} host_self=0x{host_self:x} thread_self=0x{thread_self:x} reply_port=0x{reply_port:x} (via dispatch: 0x{dispatched:x})"
    );
    assert!(task_self != 0, "task_self_trap returned MACH_PORT_NULL");
    assert!(host_self != 0, "host_self_trap returned MACH_PORT_NULL");
    assert!(thread_self != 0, "thread_self_trap returned MACH_PORT_NULL");
    assert!(reply_port != 0, "mach_reply_port returned MACH_PORT_NULL");

    println!("MACH_TRAPS_OK: task_self/host_self/thread_self/mach_reply_port served through XNU on a guest task");
}
