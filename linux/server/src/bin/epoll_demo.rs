//! Stage 4 slice: the daemon's epoll accept loop over a REAL unix socket. A client
//! thread connects and sends a uidgid call; the main thread's epoll loop accepts the
//! connection, receives the message, dispatches it on a sched microthread (real
//! dtape_task_uidgid, routed to the guest's task via the registry), and replies.
use darling::registry::Registry;
use darling::rpc_io::{recv_message, send_message};
use darling::rpc_wire::{
    callnum, CallUidgid, DserverRpcCallhdr, DserverRpcReplyhdr, ReplyUidgid, RpcCallUidgid, RpcReplyUidgid,
};
use darling::sched;
use darling::server::{connect, Listener};
use std::cell::Cell;
use std::mem::size_of;
use std::os::raw::{c_int, c_void};
use std::rc::Rc;

extern "C" {
    fn dtape_task_uidgid(task: *mut c_void, new_uid: c_int, new_gid: c_int, old_uid: *mut c_int, old_gid: *mut c_int);
}
fn as_bytes<T>(v: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts(v as *const T as *const u8, size_of::<T>()) }
}

fn main() {
    unsafe {
        let path = format!("/tmp/dsrs-epoll-{}.sock", std::process::id());
        let listener = Listener::bind(&path).unwrap();
        let kt = sched::init();
        let mut reg = Registry::new(kt);

        // Client on another OS thread: connect, send uidgid, read + verify the reply.
        let pathc = path.clone();
        let client = std::thread::spawn(move || {
            let fd = connect(&pathc).unwrap();
            let call = RpcCallUidgid {
                header: DserverRpcCallhdr { number: callnum::UIDGID, pid: 555, tid: 556, architecture: 2 },
                body: CallUidgid { new_uid: 3300, new_gid: 3301 },
            };
            send_message(fd, as_bytes(&call), &[]).unwrap();
            let rm = recv_message(fd).unwrap().expect("no reply");
            let reply = std::ptr::read_unaligned(rm.data.as_ptr() as *const RpcReplyUidgid);
            assert_eq!(reply.header.number, callnum::UIDGID);
            assert_eq!(reply.header.code, 0);
            libc::close(fd);
            (reply.body.old_uid, reply.body.old_gid)
        });

        // Daemon: epoll loop, serve exactly one message.
        listener
            .run(1, |msg| {
                let hdr = msg.header()?;
                if hdr.number != callnum::UIDGID {
                    return None;
                }
                let call = std::ptr::read_unaligned(msg.body().as_ptr() as *const CallUidgid);
                let slot: Rc<Cell<Option<ReplyUidgid>>> = Rc::new(Cell::new(None));
                let out = slot.clone();
                let mt = reg.spawn_on(hdr.pid as u32, hdr.tid as u64, hdr.architecture, Box::new(move || {
                    let (mut ou, mut og): (c_int, c_int) = (-1, -1);
                    dtape_task_uidgid(sched::current_task() as *mut c_void, call.new_uid, call.new_gid, &mut ou, &mut og);
                    out.set(Some(ReplyUidgid { old_uid: ou, old_gid: og }));
                }));
                sched::run(mt);
                sched::drain();
                let body = slot.get().unwrap();
                let reply = RpcReplyUidgid { header: DserverRpcReplyhdr { number: callnum::UIDGID, code: 0 }, body };
                Some(as_bytes(&reply).to_vec())
            })
            .unwrap();

        let (old_uid, old_gid) = client.join().unwrap();
        println!("EPOLL_OK: accepted a guest connection on {path}, served uidgid via epoll -> reply old=({old_uid},{old_gid})");
    }
}
