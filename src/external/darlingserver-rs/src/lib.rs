//! darlingserver-rs: the Rust host-side rewrite of darlingserver.
//!
//! Boundary (frozen): the C duct-tape (XNU emulation) is consumed via the dtape_*
//! API + the dtape_hooks vtable; everything above it is safe-ish Rust. See
//! plan/rust-rewrite-eval.md. Proven so far (spikes): the link + dtape_init
//! (Stage 0), both microthread suspend/resume paths across the FFI (Stage 3), and
//! the byte-identical RPC wire codec (Stage 1). This library is the Stage 4
//! foundation: a reusable, static-mut-free microthread scheduler + hook layer
//! (promoted from src/bin/stage3_spike.rs).

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]

/// bindgen-generated dtape hooks contract + types (from build.rs).
pub mod bindings {
    include!(concat!(env!("OUT_DIR"), "/dtape_bindings.rs"));
}

/// Byte-identical Rust mirror of the RPC wire messages (generated; see
/// scripts/rpc-wire-parity.sh for the parity gate).
#[path = "rpc_wire.rs"]
pub mod rpc_wire;

/// The microthread scheduler + dtape hook layer.
pub mod sched;

/// Daemon-side RPC message I/O (receive/decode half of the loop).
pub mod rpc_io;

/// Process/thread tables: guest pid/tid -> dtape task/thread.
pub mod registry;

/// The epoll accept loop (listening socket + connection multiplexing).
pub mod server;

/// Mach special-port traps (task_self/host_self/thread_self/mach_reply_port).
pub mod mach;
