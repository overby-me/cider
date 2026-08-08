//! darlingserver: the Rust host-side rewrite of darlingserver.
//!
//! Boundary (frozen): the C duct-tape (XNU emulation) is consumed via the dtape_*
//! API + the dtape_hooks vtable; everything above it is safe-ish Rust. See
//! PLAN.md. Proven so far (spikes): the link + dtape_init
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
/// rpc_wire_sizes for the sizes the parity gate compared).
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

/// Task-level duct-tape operations (dtape_task_* on an explicit task pointer).
pub mod task;

/// The dtape_stub family, shared by every ported glue file that stubs an XNU entry point.
pub mod dtape_stub;

/// duct-tape's timer queue: the Rust replacement for duct-tape/src/timer.c, the third glue
/// file ported off C (#71).
pub mod timer;

/// duct-tape condition variables: the Rust replacement for duct-tape/src/condvar.c, the
/// second glue file ported off C (#71). Exports the dtape_condvar_* C ABI, so the still-C
/// locks.c and thread.c link against this.
pub mod condvar;

/// Object-level duct-tape semaphores: the Rust replacement for duct-tape/src/semaphore.c,
/// the first glue file ported off C (#71). Exports the dtape_semaphore_* C ABI, so the
/// still-C kqchan.c links against this.
pub mod semaphore;

// host.c: the machine-description entry points (#71, fourth file ported).
pub mod host;

// processor.c: processors and processor sets (#71, fifth file ported).
pub mod processor;

// init.c: duct-tape start-up, and the dtape_hooks global (#71, sixth file ported).
pub mod init;

// debug.c: the Mach debug queries (#71, seventh file ported).
pub mod debug;

// locks.c: mutexes, spin locks and the sleep routines (#71, eighth file ported).
pub mod locks;

// duct-tape/src/kqchan.c: the XNU side of Mach-port kqueue channels (#71, ninth file).
// NAMED dtape_kqchan because linux/server/src/kqchan.rs already exists and is the DAEMON side,
// the socketpair protocol the guest talks; the two are different layers of the same feature.
pub mod dtape_kqchan;

// The layout invariant every container_of style port depends on, asserted against the C
// compiler at build time (#71). bindgen runs with --no-layout-tests, so without this nothing
// checks that Rust and C agree on the structs the offsets are taken from.
pub mod layout;

// duct-tape/src/stubs.c: the XNU entry points duct-tape does not implement, plus the stub
// logger every other glue file calls (#71, thirteenth file). panic, the fourth and last
// variadic definition, stays in C in dtape_rs_shims.c.
pub mod stubs;

// duct-tape/src/misc.c: the machine-state table, the kmsg trace and the odds and ends
// (#71, twelfth file). Its three VARIADIC definitions stay in C, in dtape_rs_shims.c, because
// stable Rust cannot define a variadic function; Rust calls them instead.
pub mod misc;

// duct-tape/src/psynch.c: the pthread kext glue and the BSD sleep path (#71, eleventh file).
// NAMED dtape_psynch because linux/server/src/psynch.rs already exists and is the DAEMON side,
// the RPC handlers the guest calls; this is the layer under it.
pub mod dtape_psynch;

// duct-tape/src/traps.c: six hand-written trap wrappers (#71, tenth file), plus the 29 that
// DSERVER_DTAPE_DEFS generates, emitted by scripts/gen-dtape-traps.py.
pub mod dtape_traps;
pub mod traps_generated;

/// Thread-level duct-tape operations (sigexc enter/exit for the interrupt mechanism).
pub mod thread;

/// XNU-trap duct-tape wrappers (the thin dtape_<name> traps: mach port/vm/semaphore/timer).
pub mod traps;

/// Process kqueue channels (EVFILT_PROC): the daemon side of the guest's process waiters.
pub mod kqchan;

/// psynch: kernel-assisted pthread mutex/condvar/rwlock (the `__psynch_*` BSD syscalls).
pub mod psynch;

/// S2C (server-to-client): the daemon asks the guest to mmap/munmap on its own behalf.
pub mod s2c;

/// The daemon's reusable RPC handler (the real handler bodies).
pub mod handler;

/// Container bring-up: the Linux mount/PID-namespace + overlay + guest-init plumbing
/// darlingserver's main() does before the RPC loop (needs root; not sandbox-runnable).
pub mod container;
