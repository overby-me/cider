//! The Mach debug queries: the Rust replacement for `duct-tape/src/debug.c` (#71, seventh file).
//!
//! Four read-only walks over a task's Mach state, used by darlingserver's debugging tools to
//! answer what ports a task holds, what is in a port set, and what messages are queued. They
//! never mutate anything, and every one of them takes an ITERATOR the caller supplies, which
//! keeps the allocation on the caller's side.
//!
//! WHY IT LOOKED HARDER THAN IT IS, and the sequence is worth recording because the first two
//! conclusions were both wrong:
//!
//! * Its opaque count read 13, which was really 2 once function names stopped being counted as
//!   types and the preprocessor stopped failing on a generated header.
//! * `imq_msgcount`, `imq_messages` and `ip_receiver` are absent from the bindings, which looked
//!   like the file being unportable. They are macro ALIASES for nested union paths
//!   (`data.port.msgcount`, `data.receiver`), and those paths ARE bound. Only the alias is
//!   missing, so the port spells the path out and nothing is transcribed.
//!
//! WHAT IS SHIMMED AND WHY. `struct task` stays opaque: reopening it was measured at +94 KB and
//! +22 structs, nearly doubling bindings every compile of the crate pays for, and this file
//! reaches through it for exactly one field. `MACH_PORT_MAKE` has two definitions selected by
//! `NO_PORT_GEN`, `io_release` is static inline so there is no symbol to link against, and
//! `ip_object_to_port` is a `__container_of`. All four are one-line C shims.
//!
//! The `IE_BITS_*` accessors are NOT shimmed, deliberately: they are `(bits) & MASK` and the
//! masks are plain defines, so the port ANDs with generated constants.

use std::os::raw::c_void;
use std::ptr;

use crate::bindings::{
    dtape_debug_message_t, dtape_debug_port_list_messages_iterator_f, dtape_debug_port_t,
    dtape_debug_portset_list_members_iterator_f, dtape_debug_task_list_ports_iterator_f,
    dtape_rs_io_release, dtape_rs_ip_object_to_port, dtape_rs_kalloc, dtape_rs_kfree,
    dtape_rs_mach_port_make, dtape_rs_task_ipc_space, dtape_task_t,
    ipc_entry, ipc_kmsg, ipc_mqueue, ipc_object, ipc_space, mach_port_name_t,
    ipc_entry_lookup, ipc_mqueue_copyin, ipc_mqueue_set_gather_member_names, ipc_kmsg_queue_next,
    IE_BITS_GEN_MASK, IE_BITS_TYPE_MASK, IE_BITS_UREFS_MASK, KERN_SUCCESS,
};

/// `dtape_task_for_xnu_task`: XNU's task is EMBEDDED in the duct-tape one, so this walks back
/// by the field offset.
///
/// COMPUTED, NOT CALLED, and the first version of this file got that wrong. The C is
/// `__attribute__((always_inline)) static`, so there is NO SYMBOL to link against. Declaring it
/// extern compiled and even linked the demos, because nothing in them reaches this path and the
/// linker garbage collected it; only building darlingserverd, where handler.rs does call it,
/// produced the undefined reference. Same shape as `dtape_thread_for_xnu_thread`, which
/// condvar.rs computes for the same reason.
#[inline]
unsafe fn dtape_task_for_xnu_task(xnu_task: crate::bindings::task_t) -> *mut dtape_task_t {
    if xnu_task.is_null() {
        return ptr::null_mut();
    }
    (xnu_task as *mut u8).sub(std::mem::offset_of!(crate::bindings::dtape_task, xnu_task))
        as *mut dtape_task_t
}

/// `MACH_PORT_TYPE_NONE`, the empty capability. Spelled out because it is `0` by construction
/// in every Mach version and is compared against, never stored.
const MACH_PORT_TYPE_NONE: u32 = 0;

/// The three IE_BITS accessors, as the macros define them: a mask and nothing else.
#[inline]
fn ie_bits_gen(bits: u32) -> u32 {
    bits & IE_BITS_GEN_MASK
}
#[inline]
fn ie_bits_type(bits: u32) -> u32 {
    bits & IE_BITS_TYPE_MASK
}
#[inline]
fn ie_bits_urefs(bits: u32) -> u32 {
    bits & IE_BITS_UREFS_MASK
}

/// The task's IPC space, through the shim, because `struct task` is opaque on purpose.
#[inline]
unsafe fn task_space(task: *mut dtape_task_t) -> *mut ipc_space {
    dtape_rs_task_ipc_space(task as *mut crate::bindings::dtape_task) as *mut ipc_space
}

/// How many ports a task holds.
#[no_mangle]
pub unsafe extern "C" fn dtape_debug_task_port_count(task: *mut dtape_task_t) -> u64 {
    (*task_space(task)).is_table_hashed as u64
}

/// Walk the task's port table, calling the iterator for each live entry.
///
/// The iterator can stop early by returning false, and the C keeps COUNTING after it does, so
/// the returned count is the true number of ports rather than the number reported. Preserved
/// exactly: a caller that stops early still learns how many there were.
#[no_mangle]
pub unsafe extern "C" fn dtape_debug_task_list_ports(
    task: *mut dtape_task_t,
    iterator: dtape_debug_task_list_ports_iterator_f,
    context: *mut c_void,
) -> u64 {
    let space = task_space(task);
    let mut port_count: u64 = 0;
    let mut call_it = true;

    for index in 0..(*space).is_table_size {
        let entry: *mut ipc_entry = (*space).is_table.add(index as usize);
        if ie_bits_type((*entry).ie_bits) == MACH_PORT_TYPE_NONE {
            continue;
        }

        let port = dtape_rs_ip_object_to_port((*entry).ie_object as *mut ipc_object);

        let debug_port = dtape_debug_port_t {
            name: dtape_rs_mach_port_make(index, ie_bits_gen((*entry).ie_bits)),
            refs: ie_bits_urefs((*entry).ie_bits) as u64,
            rights: ie_bits_type((*entry).ie_bits),
            // imq_msgcount, which is a macro alias for data.port.msgcount.
            messages: (*port).ip_messages.data.port.msgcount as u64,
        };

        if call_it {
            if let Some(f) = iterator {
                call_it = f(context, &debug_port as *const _ as *mut _);
            }
        }

        port_count += 1;
    }

    port_count
}

/// Walk the members of a port set.
#[no_mangle]
pub unsafe extern "C" fn dtape_debug_portset_list_members(
    task: *mut dtape_task_t,
    portset: u32,
    iterator: dtape_debug_portset_list_members_iterator_f,
    context: *mut c_void,
) -> u64 {
    let mut object: *mut ipc_object = ptr::null_mut();
    let mut mqueue: *mut ipc_mqueue = ptr::null_mut();
    let mut member_count: u32 = 0;
    let mut names: *mut mach_port_name_t = ptr::null_mut();
    let mut actual_count: u32 = 0;
    let mut call_it = true;

    if ipc_mqueue_copyin(task_space(task), portset, &mut mqueue, &mut object)
        != KERN_SUCCESS as i32
    {
        return 0;
    }

    // Grow until the buffer was big enough, exactly as the C loop does: gather reports how many
    // there really are, and a set that grew between the two calls goes round again.
    loop {
        if !names.is_null() {
            dtape_rs_kfree(
                names as *mut c_void,
                std::mem::size_of::<mach_port_name_t>() * member_count as usize,
            );
        }

        names = dtape_rs_kalloc(std::mem::size_of::<mach_port_name_t>() * actual_count as usize)
            as *mut mach_port_name_t;
        member_count = actual_count;

        ipc_mqueue_set_gather_member_names(
            task_space(task),
            mqueue,
            member_count,
            names,
            &mut actual_count,
        );

        if member_count == actual_count {
            break;
        }
    }

    for i in 0..member_count as usize {
        let name = *names.add(i);
        let entry = ipc_entry_lookup(task_space(task), name);
        let port = dtape_rs_ip_object_to_port((*entry).ie_object as *mut ipc_object);

        let debug_port = dtape_debug_port_t {
            name,
            refs: ie_bits_urefs((*entry).ie_bits) as u64,
            rights: ie_bits_type((*entry).ie_bits),
            messages: (*port).ip_messages.data.port.msgcount as u64,
        };

        if call_it {
            if let Some(f) = iterator {
                call_it = f(context, &debug_port as *const _ as *mut _);
            }
        }
    }

    if !names.is_null() {
        dtape_rs_kfree(
            names as *mut c_void,
            std::mem::size_of::<mach_port_name_t>() * member_count as usize,
        );
    }

    dtape_rs_io_release(object);

    member_count as u64
}

/// Walk the messages queued on a port.
#[no_mangle]
pub unsafe extern "C" fn dtape_debug_port_list_messages(
    task: *mut dtape_task_t,
    port: u32,
    iterator: dtape_debug_port_list_messages_iterator_f,
    context: *mut c_void,
) -> u64 {
    let mut object: *mut ipc_object = ptr::null_mut();
    let mut mqueue: *mut ipc_mqueue = ptr::null_mut();
    let mut message_count: u64 = 0;
    let mut call_it = true;

    if ipc_mqueue_copyin(task_space(task), port, &mut mqueue, &mut object) != KERN_SUCCESS as i32 {
        return 0;
    }

    // ipc_kmsg_queue_first is a macro for the queue head; next is a real function.
    let queue = ptr::addr_of_mut!((*mqueue).data.port.messages);
    let mut kmsg: *mut ipc_kmsg = (*queue).ikmq_base;
    while !kmsg.is_null() {
        let mut debug_message = dtape_debug_message_t {
            sender: 0,
            size: (*kmsg).ikm_size as u64,
        };

        // ip_receiver is a macro alias for data.receiver. A message with no remote port, or a
        // remote port with no receiver, has no sender to report and keeps the zero.
        let remote = (*(*kmsg).ikm_header).msgh_remote_port;
        if !remote.is_null() {
            let receiver = (*remote).data.receiver;
            if !receiver.is_null() {
                let dtask = dtape_task_for_xnu_task((*receiver).is_task);
                if !dtask.is_null() {
                    debug_message.sender = (*dtask).saved_pid as u32;
                }
            }
        }

        if call_it {
            if let Some(f) = iterator {
                call_it = f(context, &debug_message as *const _ as *mut _);
            }
        }

        message_count += 1;
        kmsg = ipc_kmsg_queue_next(queue, kmsg);
    }

    dtape_rs_io_release(object);

    message_count
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The three masks must partition the entry bits the way XNU says. If two of them
    /// overlapped, a port would report its generation as part of its reference count and
    /// nothing would crash.
    #[test]
    fn the_entry_bit_masks_do_not_overlap() {
        assert_eq!(IE_BITS_UREFS_MASK & IE_BITS_TYPE_MASK, 0);
        assert_eq!(IE_BITS_UREFS_MASK & IE_BITS_GEN_MASK, 0);
        assert_eq!(IE_BITS_TYPE_MASK & IE_BITS_GEN_MASK, 0);
        // And each must actually select something, or the accessor is a constant zero.
        for m in [IE_BITS_UREFS_MASK, IE_BITS_TYPE_MASK, IE_BITS_GEN_MASK] {
            assert_ne!(m, 0);
        }
    }

    /// The accessors are a mask and nothing else, so a value entirely outside a mask reads zero
    /// and a value entirely inside reads back unchanged. This is the property that would break
    /// if a mask were ever swapped for another.
    #[test]
    fn the_accessors_are_exactly_their_masks() {
        assert_eq!(ie_bits_urefs(IE_BITS_UREFS_MASK), IE_BITS_UREFS_MASK);
        assert_eq!(ie_bits_urefs(IE_BITS_GEN_MASK), 0);
        assert_eq!(ie_bits_type(IE_BITS_TYPE_MASK), IE_BITS_TYPE_MASK);
        assert_eq!(ie_bits_type(IE_BITS_UREFS_MASK), 0);
        assert_eq!(ie_bits_gen(IE_BITS_GEN_MASK), IE_BITS_GEN_MASK);
        assert_eq!(ie_bits_gen(IE_BITS_TYPE_MASK), 0);
    }
}
