//! Capstone: a runnable darlingserver that ties every piece together -- the epoll
//! accept loop (server) + per-guest task routing (registry) + the microthread
//! scheduler (sched) + the CODE-GENERATED dispatch (rpc_wire) + a real handler that
//! calls into the duct-tape. Serves real RPC calls off a real unix socket.
//!
//! A guest thread sends two `uidgid` calls; the daemon routes them to the guest's
//! task, runs each handler on a microthread through the generated dispatch, and the
//! second reply reports the uid the first call set -- real state through the whole
//! pipeline.
use darling::registry::Registry;
use darling::rpc_io::{recv_message, send_message};
use darling::rpc_wire::{
    self, callnum, CallUidgid, DserverRpcCallhdr, ReplyStartedSuspended, ReplyUidgid, RpcCallUidgid,
    RpcReplyUidgid,
};
use darling::sched;
use darling::server::{connect, Listener};
use std::cell::Cell;
use std::mem::size_of;
use std::os::fd::RawFd;
use std::os::raw::{c_int, c_void};
use std::rc::Rc;

extern "C" {
    fn dtape_task_uidgid(task: *mut c_void, new_uid: c_int, new_gid: c_int, old_uid: *mut c_int, old_gid: *mut c_int);
}
fn as_bytes<T>(v: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts(v as *const T as *const u8, size_of::<T>()) }
}

/// The daemon's RPC handler. Methods run ON a sched microthread bound to the calling
/// guest's task, so sched::current_task() is that guest -- no pid threading needed.
struct Daemon;
impl rpc_wire::RpcHandler for Daemon {
    fn uidgid(&mut self, call: &CallUidgid, _fds: &[RawFd]) -> Result<ReplyUidgid, i32> {
        unsafe {
            let (mut ou, mut og): (c_int, c_int) = (-1, -1);
            dtape_task_uidgid(sched::current_task() as *mut c_void, call.new_uid, call.new_gid, &mut ou, &mut og);
            Ok(ReplyUidgid { old_uid: ou, old_gid: og })
        }
    }
    fn started_suspended(&mut self, _fds: &[RawFd]) -> Result<ReplyStartedSuspended, i32> {
        Ok(ReplyStartedSuspended { suspended: false })
    }
}

fn main() {
    unsafe {
        let path = format!("/tmp/dsrs-daemon-{}.sock", std::process::id());
        let listener = Listener::bind(&path).unwrap();
        let kt = sched::init();
        let mut reg = Registry::new(kt);
        let mut daemon = Daemon;
        let daemon_ptr = &mut daemon as *mut Daemon;

        // A guest thread: two uidgid calls; the 2nd must see the 1st's uid.
        let pathc = path.clone();
        let client = std::thread::spawn(move || {
            let fd = connect(&pathc).unwrap();
            let send = |new_uid: i32| {
                let call = RpcCallUidgid {
                    header: DserverRpcCallhdr { number: callnum::UIDGID, pid: 777, tid: 778, architecture: 2 },
                    body: CallUidgid { new_uid, new_gid: new_uid + 1 },
                };
                send_message(fd, as_bytes(&call), &[]).unwrap();
                let rm = recv_message(fd).unwrap().unwrap();
                std::ptr::read_unaligned(rm.data.as_ptr() as *const RpcReplyUidgid)
            };
            let r1 = send(8100);
            let r2 = send(8200);
            libc::close(fd);
            (r1.header.code, r1.body.old_uid, r2.body.old_uid)
        });

        // The daemon loop: route -> microthread -> generated dispatch -> reply.
        listener
            .run(2, |msg| {
                let hdr = msg.header()?;
                let task = reg.ensure_task(hdr.pid as u32, hdr.architecture); // per-guest routing
                let slot: Rc<Cell<Option<Vec<u8>>>> = Rc::new(Cell::new(None));
                let out = slot.clone();
                let msg_c = msg.clone();
                let mt = sched::spawn_with_nsid(task, hdr.tid as u64, Box::new(move || {
                    // The handler runs here, on this guest's task, via the generated dispatch.
                    out.set(rpc_wire::dispatch(&mut *daemon_ptr, &msg_c));
                }));
                sched::run(mt);
                sched::drain();
                slot.take()
            })
            .unwrap();

        let (code1, old1, old2) = client.join().unwrap();
        assert_eq!(code1, 0);
        assert_eq!(old1, 0, "first call sees uid 0");
        assert_eq!(old2, 8100, "second call must see the uid the first set");
        println!("DAEMON_OK: epoll + registry routing + sched microthread + generated dispatch + real dtape handler; state persisted across two calls (old2={old2})");
    }
}
