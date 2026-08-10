//! The XNU kernel emulation, in Rust.
//!
//! These are the Rust replacements for the sixteen xnu-sys glue .c files (#71),
//! which is why the module names mirror XNU subsystems. The raw FFI underneath is
//! the xnu_sys bindings (crate::bindings).
//!
//! Six of these used to carry a xnu_sys_ prefix purely to avoid colliding with the
//! DAEMON-side module of the same name (kqchan, thread, task, psynch, traps). Living
//! under xnu:: removes the need for that, so xnu::task is the emulation and crate::task
//! is the daemon side.

/// xnu-sys's timer queue: the Rust replacement for xnu-sys/src/timer.c, the third glue
/// file ported off C (#71).
pub mod timer;

/// xnu-sys condition variables: the Rust replacement for xnu-sys/src/condvar.c, the
/// second glue file ported off C (#71). Exports the xnu_sys_condvar_* C ABI, so the still-C
/// locks.c and thread.c link against this.
pub mod condvar;

/// Object-level xnu-sys semaphores: the Rust replacement for xnu-sys/src/semaphore.c,
/// the first glue file ported off C (#71). Exports the xnu_sys_semaphore_* C ABI, so the
/// still-C kqchan.c links against this.
pub mod semaphore;

// host.c: the machine-description entry points (#71, fourth file ported).
pub mod host;

// processor.c: processors and processor sets (#71, fifth file ported).
pub mod processor;

// init.c: xnu-sys start-up, and the xnu_sys_hooks global (#71, sixth file ported).
pub mod init;

// debug.c: the Mach debug queries (#71, seventh file ported).
pub mod debug;

// locks.c: mutexes, spin locks and the sleep routines (#71, eighth file ported).
pub mod locks;

// xnu-sys/src/memory.c: the zone and kalloc allocators, the copyin/copyout family, the
// vm_map_copy path, the region queries and the memfd-backed shared remap (#71, fifteenth file).
// The red-black tree of shared entries stays C in xnu_sys_rs_shims.c: RB_PROTOTYPE_SC makes every
// tree function file-local, and this file never looked anything up by key.
pub mod memory;

// xnu-sys/src/stubs.c: the XNU entry points xnu-sys does not implement, plus the stub
// logger every other glue file calls (#71, thirteenth file). panic, the fourth and last
// variadic definition, stays in C in xnu_sys_rs_shims.c.
pub mod stubs;

// xnu-sys/src/misc.c: the machine-state table, the kmsg trace and the odds and ends
// (#71, twelfth file). Its three VARIADIC definitions stay in C, in xnu_sys_rs_shims.c, because
// stable Rust cannot define a variadic function; Rust calls them instead.
pub mod misc;

// The layout invariant every container_of style port depends on, asserted against the C
// compiler at build time (#71). bindgen runs with --no-layout-tests, so without this nothing
// checks that Rust and C agree on the structs the offsets are taken from.
pub mod layout;

pub mod traps_generated;

/// The xnu_sys_stub family, shared by every ported glue file that stubs an XNU entry point.
pub mod stub_family;

// xnu-sys/src/kqchan.c: the XNU side of Mach-port kqueue channels (#71, ninth file).
// NAMED xnu_sys_kqchan because linux/server/src/kqchan.rs already exists and is the DAEMON side,
// the socketpair protocol the guest talks; the two are different layers of the same feature.
pub mod kqchan;

// xnu-sys/src/thread.c: thread lifecycle, blocking, saved x86 register state, and the path
// Linux signals take to become Mach exceptions (#71, SIXTEENTH AND LAST file). NAMED
// xnu_sys_thread because linux/server/src/thread.rs is the daemon side.
pub mod thread;

// xnu-sys/src/task.c: task creation and teardown, task_info and the task_for_pid family
// (#71, fourteenth file). NAMED xnu_sys_task because linux/server/src/task.rs is the daemon side.
// The copied-XNU half of the file stays C, in xnu-sys/src/task_xnu.c.
pub mod task;

// xnu-sys/src/psynch.c: the pthread kext glue and the BSD sleep path (#71, eleventh file).
// NAMED xnu_sys_psynch because linux/server/src/psynch.rs already exists and is the DAEMON side,
// the RPC handlers the guest calls; this is the layer under it.
pub mod psynch;

// xnu-sys/src/traps.c: six hand-written trap wrappers (#71, tenth file), plus the 29 that
// DSERVER_XNU_SYS_DEFS generates, emitted by scripts/gen-xnu-sys-traps.py.
pub mod traps;
