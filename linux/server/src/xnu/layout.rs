//! The layout invariant the whole xnu-sys port rests on (#71), asserted at compile time.
//!
//! Six of the ported files walk back from an embedded XNU struct to the xnu-sys struct that
//! contains it:
//!
//! ```text
//! (xnu_task as *mut u8).sub(offset_of!(dtape_task, xnu_task)) as *mut dtape_task
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
//! `dtape_rs_host_consts`, and this module asserts Rust against them. `const` assertions, so a
//! disagreement is a BUILD failure rather than a test that has to be remembered and run.
//!
//! Both sizes and both offsets are checked, for task and for thread. The sizes matter as much as
//! the offsets: an opaque binding carries a type's size and nothing else, so if the size is
//! wrong the opaque form is wrong in every use, and if a reopened form disagrees with C then
//! bindgen has laid the fields out differently and every field access through it is wrong too.

use std::mem::{offset_of, size_of};

use crate::bindings::{
    dtape_rs_host_consts_DTAPE_RS_OFFSETOF_DTAPE_TASK_XNU_TASK,
    dtape_rs_host_consts_DTAPE_RS_OFFSETOF_DTAPE_THREAD_XNU_THREAD,
    dtape_rs_host_consts_DTAPE_RS_SIZEOF_DTAPE_TASK,
    dtape_rs_host_consts_DTAPE_RS_SIZEOF_DTAPE_THREAD, dtape_rs_host_consts_DTAPE_RS_SIZEOF_XNU_TASK,
    dtape_rs_host_consts_DTAPE_RS_SIZEOF_XNU_THREAD, dtape_task, dtape_thread, task, thread,
};

const _: () = assert!(
    size_of::<task>() == dtape_rs_host_consts_DTAPE_RS_SIZEOF_XNU_TASK as usize,
    "Rust and C disagree on sizeof(struct task); every dtape_task offset is suspect"
);

const _: () = assert!(
    size_of::<thread>() == dtape_rs_host_consts_DTAPE_RS_SIZEOF_XNU_THREAD as usize,
    "Rust and C disagree on sizeof(struct thread); every dtape_thread offset is suspect"
);

const _: () = assert!(
    size_of::<dtape_task>() == dtape_rs_host_consts_DTAPE_RS_SIZEOF_DTAPE_TASK as usize,
    "Rust and C disagree on sizeof(struct dtape_task)"
);

const _: () = assert!(
    size_of::<dtape_thread>() == dtape_rs_host_consts_DTAPE_RS_SIZEOF_DTAPE_THREAD as usize,
    "Rust and C disagree on sizeof(struct dtape_thread)"
);

const _: () = assert!(
    offset_of!(dtape_task, xnu_task)
        == dtape_rs_host_consts_DTAPE_RS_OFFSETOF_DTAPE_TASK_XNU_TASK as usize,
    "dtape_task_for_xnu_task would compute the wrong pointer"
);

const _: () = assert!(
    offset_of!(dtape_thread, xnu_thread)
        == dtape_rs_host_consts_DTAPE_RS_OFFSETOF_DTAPE_THREAD_XNU_THREAD as usize,
    "dtape_thread_for_xnu_thread would compute the wrong pointer"
);
