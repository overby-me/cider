//! The layout invariant the whole xnu-sys port rests on (#71), asserted at compile time.
//!
//! Six of the ported files walk back from an embedded XNU struct to the xnu-sys struct that
//! contains it:
//!
//! ```text
//! (xnu_task as *mut u8).sub(offset_of!(xnu_sys_task, xnu_task)) as *mut xnu_sys_task
//! ```
//!
//! That is only correct while Rust and C agree, byte for byte, on the layout of both structs.
//! **Nothing was checking it.** bindgen runs with `--no-layout-tests`, so the generated bindings
//! carry no size or offset assertions at all, and the two knobs most likely to move a field are
//! exactly the ones this port keeps adjusting: marking a type `--opaque-type` and later
//! reopening it. A struct that quietly grew or shrank on one side would not fail to compile and
//! would not fail to link. It would compute a wrong pointer at runtime, in the one direction
//! nothing else can catch.
//!
//! So the C compiler is asked for the answers in `wrapper.h`, as enumerators of
//! `xnu_sys_rs_host_consts`, and this module asserts Rust against them. `const` assertions, so a
//! disagreement is a BUILD failure rather than a test that has to be remembered and run.
//!
//! Both sizes and both offsets are checked, for task and for thread. The sizes matter as much as
//! the offsets: an opaque binding carries a type's size and nothing else, so if the size is
//! wrong the opaque form is wrong in every use, and if a reopened form disagrees with C then
//! bindgen has laid the fields out differently and every field access through it is wrong too.

use std::mem::{offset_of, size_of};

use crate::bindings::{
    xnu_sys_rs_host_consts_XNU_SYS_RS_OFFSETOF_XNU_SYS_TASK_XNU_TASK,
    xnu_sys_rs_host_consts_XNU_SYS_RS_OFFSETOF_XNU_SYS_THREAD_XNU_THREAD,
    xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_SYS_TASK,
    xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_SYS_THREAD, xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_TASK,
    xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_THREAD, xnu_sys_task, xnu_sys_thread, task, thread,
};

const _: () = assert!(
    size_of::<task>() == xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_TASK as usize,
    "Rust and C disagree on sizeof(struct task); every xnu_sys_task offset is suspect"
);

const _: () = assert!(
    size_of::<thread>() == xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_THREAD as usize,
    "Rust and C disagree on sizeof(struct thread); every xnu_sys_thread offset is suspect"
);

const _: () = assert!(
    size_of::<xnu_sys_task>() == xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_SYS_TASK as usize,
    "Rust and C disagree on sizeof(struct xnu_sys_task)"
);

const _: () = assert!(
    size_of::<xnu_sys_thread>() == xnu_sys_rs_host_consts_XNU_SYS_RS_SIZEOF_XNU_SYS_THREAD as usize,
    "Rust and C disagree on sizeof(struct xnu_sys_thread)"
);

const _: () = assert!(
    offset_of!(xnu_sys_task, xnu_task)
        == xnu_sys_rs_host_consts_XNU_SYS_RS_OFFSETOF_XNU_SYS_TASK_XNU_TASK as usize,
    "xnu_sys_task_for_xnu_task would compute the wrong pointer"
);

const _: () = assert!(
    offset_of!(xnu_sys_thread, xnu_thread)
        == xnu_sys_rs_host_consts_XNU_SYS_RS_OFFSETOF_XNU_SYS_THREAD_XNU_THREAD as usize,
    "xnu_sys_thread_for_xnu_thread would compute the wrong pointer"
);
