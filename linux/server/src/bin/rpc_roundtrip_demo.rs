//! Stage 4 slice: the full daemon request->reply cycle on one call. The client
//! sends an RpcCallUidgid over a unix socket; the server decodes it, runs the
//! handler ON A sched MICROTHREAD (which calls dtape_task_uidgid in the duct-tape),
//! encodes the RpcReplyUidgid, and sends it back; the client verifies the reply.
//! This exercises: rpc_io recv/send + rpc_wire decode/encode + sched dispatch +
//! a real duct-tape call from a microthread.
use darling::rpc_io::{recv_message, send_message};
use darling::rpc_wire::{
    callnum, CallUidgid, DserverRpcCallhdr, DserverRpcReplyhdr, ReplyUidgid, RpcCallUidgid, RpcReplyUidgid,
};
use darling::sched;
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

/// Handle one message on `fd`: decode -> dispatch on a microthread -> reply.
unsafe fn serve_one(fd: RawFd, kt: *mut darling::bindings::dtape_task_t) {
    let msg = recv_message(fd).unwrap().expect("no message");
    let hdr = msg.header().expect("header");
    match hdr.number {
        callnum::UIDGID => {
            let call = std::ptr::read_unaligned(msg.body().as_ptr() as *const CallUidgid);
            // Run the handler on a sched microthread (it may call into the duct-tape).
            let slot: Rc<Cell<Option<ReplyUidgid>>> = Rc::new(Cell::new(None));
            let out = slot.clone();
            let kt_addr = kt as usize;
            let mt = sched::spawn(kt, Box::new(move || {
                let (mut ou, mut og): (c_int, c_int) = (-1, -1);
                dtape_task_uidgid(kt_addr as *mut c_void, call.new_uid, call.new_gid, &mut ou, &mut og);
                out.set(Some(ReplyUidgid { old_uid: ou, old_gid: og }));
            }));
            sched::run(mt);
            sched::drain();
            let body = slot.get().expect("handler produced no reply");
            let reply = RpcReplyUidgid {
                header: DserverRpcReplyhdr { number: callnum::UIDGID, code: 0 },
                body,
            };
            send_message(fd, as_bytes(&reply), &[]).unwrap();
        }
        other => panic!("unhandled call number {}", other),
    }
}

fn main() {
    unsafe {
        let kt = sched::init();

        let mut sp: [RawFd; 2] = [0; 2];
        assert_eq!(libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, sp.as_mut_ptr()), 0);
        let (client, server) = (sp[0], sp[1]);

        // Client -> server: set uid/gid to 7000/7001.
        let call = RpcCallUidgid {
            header: DserverRpcCallhdr { number: callnum::UIDGID, pid: 4242, tid: 4243, architecture: 2 },
            body: CallUidgid { new_uid: 7000, new_gid: 7001 },
        };
        send_message(client, as_bytes(&call), &[]).unwrap();

        // Server handles it (decode -> microthread -> duct-tape -> reply).
        serve_one(server, kt);

        // Client <- server: the reply.
        let rmsg = recv_message(client).unwrap().expect("no reply");
        assert!(rmsg.data.len() >= size_of::<RpcReplyUidgid>());
        let reply = std::ptr::read_unaligned(rmsg.data.as_ptr() as *const RpcReplyUidgid);
        println!(
            "[rpc] reply for #{} code={} old_uid={} old_gid={}",
            reply.header.number, reply.header.code, reply.body.old_uid, reply.body.old_gid
        );
        assert_eq!(reply.header.number, callnum::UIDGID);
        assert_eq!(reply.header.code, 0);
        // A second round-trip must report the uid/gid we just set as the "old" values.
        let call2 = RpcCallUidgid {
            header: DserverRpcCallhdr { number: callnum::UIDGID, pid: 4242, tid: 4243, architecture: 2 },
            body: CallUidgid { new_uid: 9000, new_gid: 9001 },
        };
        send_message(client, as_bytes(&call2), &[]).unwrap();
        serve_one(server, kt);
        let rmsg2 = recv_message(client).unwrap().unwrap();
        let reply2 = std::ptr::read_unaligned(rmsg2.data.as_ptr() as *const RpcReplyUidgid);
        assert_eq!(reply2.body.old_uid, 7000, "second call should see the uid we set");
        assert_eq!(reply2.body.old_gid, 7001);

        println!("RPC_ROUNDTRIP_OK: call -> decode -> microthread handler (dtape_task_uidgid) -> reply -> verified (incl. state across two calls)");
        for fd in [client, server] { libc::close(fd); }
    }
}
