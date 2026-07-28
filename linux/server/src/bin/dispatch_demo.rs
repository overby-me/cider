//! Stage 4 slice: the GENERATED RPC dispatch. Implement a couple of RpcHandler
//! methods (the other ~159 default to ENOSYS), then feed the generated dispatch()
//! real wire messages and verify it decodes -> calls the handler -> encodes the
//! matching reply, including the ENOSYS default for unimplemented calls.
use darling::rpc_io::Message;
use darling::rpc_wire::{
    self, callnum, CallCheckin, DserverRpcCallhdr, ReplyGetTracer, ReplyStartedSuspended,
    RpcReplyCheckin, RpcReplyGetTracer, RpcReplyStartedSuspended,
};
use std::mem::size_of;
use std::os::fd::RawFd;

struct MyHandler;
impl rpc_wire::RpcHandler for MyHandler {
    fn started_suspended(&mut self, _fds: &[RawFd]) -> Result<ReplyStartedSuspended, i32> {
        Ok(ReplyStartedSuspended { suspended: true })
    }
    fn get_tracer(&mut self, _fds: &[RawFd]) -> Result<ReplyGetTracer, i32> {
        Ok(ReplyGetTracer { tracer: 42 })
    }
    // checkin() and ~159 others are left at the default -> ENOSYS.
}

fn as_bytes<T>(v: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts(v as *const T as *const u8, size_of::<T>()) }
}
fn msg_for(number: u32) -> Message {
    let hdr = DserverRpcCallhdr { number, pid: 1, tid: 1, architecture: 2 };
    Message { data: as_bytes(&hdr).to_vec(), fds: vec![], host_pid: None }
}
fn msg_with_body<T>(number: u32, body: &T) -> Message {
    let hdr = DserverRpcCallhdr { number, pid: 1, tid: 1, architecture: 2 };
    let mut data = as_bytes(&hdr).to_vec();
    data.extend_from_slice(as_bytes(body));
    Message { data, fds: vec![], host_pid: None }
}
fn read<T: Copy>(b: &[u8]) -> T {
    unsafe { std::ptr::read_unaligned(b.as_ptr() as *const T) }
}

fn main() {
    let mut h = MyHandler;

    // started_suspended -> Ok(true)
    let out = rpc_wire::dispatch(&mut h, &msg_for(callnum::STARTED_SUSPENDED)).expect("known call");
    let r: RpcReplyStartedSuspended = read(&out);
    assert_eq!(r.header.code, 0);
    assert!(r.body.suspended);

    // get_tracer -> Ok(42)
    let out = rpc_wire::dispatch(&mut h, &msg_for(callnum::GET_TRACER)).expect("known call");
    let r: RpcReplyGetTracer = read(&out);
    assert_eq!(r.header.code, 0);
    assert_eq!(r.body.tracer, 42);

    // checkin with NO body -> the short-body guard returns EINVAL.
    let out = rpc_wire::dispatch(&mut h, &msg_for(callnum::CHECKIN)).expect("known call");
    let r: RpcReplyCheckin = read(&out);
    assert_eq!(r.header.code, rpc_wire::EINVAL, "malformed (no body) -> EINVAL");

    // checkin WELL-FORMED but unimplemented -> the default ENOSYS.
    let body = CallCheckin { is_fork: false, stack_hint: 0, lifetime_listener_pipe: -1 };
    let out = rpc_wire::dispatch(&mut h, &msg_with_body(callnum::CHECKIN, &body)).expect("known call");
    let r: RpcReplyCheckin = read(&out);
    assert_eq!(r.header.number, callnum::CHECKIN);
    assert_eq!(r.header.code, rpc_wire::ENOSYS, "well-formed unimplemented -> ENOSYS");

    // unknown call number -> None.
    assert!(rpc_wire::dispatch(&mut h, &msg_for(0xdead)).is_none());

    println!("DISPATCH_OK: generated dispatch works -- 2 impl'd (started_suspended, get_tracer), malformed->EINVAL, unimpl->ENOSYS, unknown->None");
}
