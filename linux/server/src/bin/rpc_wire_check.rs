//! Stage 1 gate: the generated Rust RPC wire structs compile and have the correct
//! fundamental layout. Full byte-parity vs the C (compile the generated C header,
//! compare sizeof/offsetof for every call) is the next increment; this proves the
//! emitter output is well-formed and the header/nesting layout is right on x86_64.

use darling::rpc_wire::*;
use std::mem::{align_of, size_of};

fn main() {
    // Headers: callhdr = {u32,i32,i32,u32} = 16; replyhdr = {u32,i32} = 8.
    assert_eq!(size_of::<DserverRpcCallhdr>(), 16, "callhdr must be 16 bytes");
    assert_eq!(align_of::<DserverRpcCallhdr>(), 4, "callhdr align");
    assert_eq!(size_of::<DserverRpcReplyhdr>(), 8, "replyhdr must be 8 bytes");

    // A message = header + (optional) body; nesting must not add padding beyond
    // the body's own alignment.
    assert_eq!(
        size_of::<RpcCallCheckin>(),
        size_of::<DserverRpcCallhdr>() + size_of::<CallCheckin>(),
        "RpcCall = header + body"
    );
    assert_eq!(
        size_of::<RpcReplyUidgid>(),
        size_of::<DserverRpcReplyhdr>() + size_of::<ReplyUidgid>(),
        "RpcReply = header + body"
    );

    // Bodies containing a u64 are 8-aligned (matches the C aligned(8)).
    assert_eq!(align_of::<CallCheckin>(), 8, "u64-containing body is 8-aligned");
    // Two i32s: 8 bytes, 4-aligned.
    assert_eq!(size_of::<CallUidgid>(), 8);
    assert_eq!(align_of::<CallUidgid>(), 4);

    // Call-number constants match the C enum ordering.
    assert_eq!(callnum::CHECKIN, 1);
    assert_eq!(callnum::CHECKOUT, 2);
    assert_eq!(callnum::INVALID, 0);
    assert_eq!(callnum::S2C, 0x52cca11);

    println!(
        "RPC_WIRE_OK: callhdr={} replyhdr={} CallCheckin={} RpcCallCheckin={} CallUidgid={}",
        size_of::<DserverRpcCallhdr>(),
        size_of::<DserverRpcReplyhdr>(),
        size_of::<CallCheckin>(),
        size_of::<RpcCallCheckin>(),
        size_of::<CallUidgid>(),
    );
}
