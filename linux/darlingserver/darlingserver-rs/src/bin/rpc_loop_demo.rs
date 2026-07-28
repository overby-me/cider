//! Stage 4 slice: the daemon's RPC receive/decode half. Send a real RpcCallCheckin
//! (with a file descriptor via SCM_RIGHTS) over a unix socket, then decode it on the
//! other side exactly as the daemon loop will -- header -> call number -> name ->
//! body -> passed fds -- using the generated wire codec + rpc_io.
use darlingserver_rs::rpc_io::{recv_message, send_message};
use darlingserver_rs::rpc_wire::{callnum, CallCheckin, DserverRpcCallhdr, RpcCallCheckin};
use std::mem::size_of;
use std::os::fd::RawFd;

fn main() {
    unsafe {
        let mut sp: [RawFd; 2] = [0; 2];
        assert_eq!(libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, sp.as_mut_ptr()), 0);
        let (client, server) = (sp[0], sp[1]);

        let mut pf: [RawFd; 2] = [0; 2];
        assert_eq!(libc::pipe(pf.as_mut_ptr()), 0);
        let (pipe_r, pipe_w) = (pf[0], pf[1]);

        // A real, wire-format call message.
        let call = RpcCallCheckin {
            header: DserverRpcCallhdr { number: callnum::CHECKIN, pid: 4242, tid: 4243, architecture: 2 /* x86_64 */ },
            body: CallCheckin { is_fork: true, stack_hint: 0xdead_beef_00, lifetime_listener_pipe: -1 },
        };
        let bytes = std::slice::from_raw_parts(&call as *const _ as *const u8, size_of::<RpcCallCheckin>());
        send_message(client, bytes, &[pipe_r]).unwrap();

        // Daemon side: receive + decode.
        let msg = recv_message(server).unwrap().expect("no message");
        let hdr = msg.header().expect("no header");
        let name = msg.call_name().expect("unknown call number");
        println!(
            "[rpc] recv call #{} = {:?}  pid={} tid={} arch={}  body={}B fds={}",
            hdr.number, name, hdr.pid, hdr.tid, hdr.architecture, msg.body().len(), msg.fds.len()
        );
        assert_eq!(hdr.number, callnum::CHECKIN);
        assert_eq!(name, "checkin");
        assert_eq!(hdr.pid, 4242);
        assert_eq!(hdr.tid, 4243);

        let body = std::ptr::read_unaligned(msg.body().as_ptr() as *const CallCheckin);
        assert!(body.is_fork);
        assert_eq!(body.stack_hint, 0xdead_beef_00);

        // The SCM_RIGHTS fd must be a live dup of our pipe: write here, read there.
        assert_eq!(msg.fds.len(), 1, "expected one passed fd");
        let got = msg.fds[0];
        let w = [0x5au8];
        assert_eq!(libc::write(pipe_w, w.as_ptr() as *const _, 1), 1);
        let mut r = [0u8];
        assert_eq!(libc::read(got, r.as_mut_ptr() as *mut _, 1), 1);
        assert_eq!(r[0], 0x5a, "passed fd is not connected to our pipe");

        println!("RPC_LOOP_OK: decoded RpcCallCheckin off the socket (header + name + body + SCM_RIGHTS fd verified)");
        for fd in [client, server, pipe_r, pipe_w, got] { libc::close(fd); }
    }
}
