//! Runtime exercise of the ported xnu-sys psynch (#71, #77).
//!
//! psynch was the one ported glue file that NOTHING drove. scheduler_demo, condvar_demo,
//! stage3_spike and host_demo cover semaphore.c, condvar.c, host.c and processor.c; psynch had
//! only whatever ran incidentally. That is the worst file to leave uncovered, because it is
//! also the one with a recorded history of failing SILENTLY rather than loudly: omitting the
//! second init phase left pthread_list_mlock NULL, and the symptom was not an error but a
//! SIGSEGV in the first contended pthread wait, reported as a task exiting with -111.
//!
//! WHAT THIS ASSERTS, and why each one can actually fail.
//!
//! THE INIT INVARIANTS. xnu_sys_psynch_init runs in phase 2 (xnu_sys_init_in_thread), which must
//! happen on a kernel microthread, and sched::init drives that. It allocates in the C's order,
//! pthread_list_mlock first, then the hash, then psynch_thcall. Asserting both pointers are
//! non-null after init is the direct regression test for the bug that actually happened: unwire
//! phase 2, or reorder the allocation away, and this fails HERE with a name attached instead of
//! crashing later inside the kext with nothing to point at.
//!
//! THE CALLBACK VTABLE. pthread_kern points at a 96-field table of which the port fills 18 and
//! takes the rest from a zeroed const, because that is exactly what the C's static initialiser
//! does. It is also a silent-failure shape: a zeroed Option<extern "C" fn> is None, so dropping
//! a field, renaming one, or having bindgen rename it under a struct change leaves the entry
//! None and still COMPILES. The kext then calls a null pointer. So every field the port is
//! supposed to fill is checked, by name, and the message says which one went missing.
//!
//! WHAT THIS DOES NOT COVER, stated rather than implied: the nine wait and wake wrappers
//! (mutexwait/mutexdrop, cvwait/cvsignal/cvbroad/cvclrprepost, rw_rdlock/rw_wrlock/rw_unlock)
//! are not driven here. They operate on GUEST user addresses and want a task with a real memory
//! map, which is more scaffolding than this harness has. The vtable check is what stands in for
//! them: those wrappers reach the kext only through these entries, so a null one is the failure
//! mode they would hit first.
//!
//! The verdict is the printed line, not the exit code, as with the other demos.

use std::ptr::addr_of;

use cider::bindings;
use cider::sched;

/// Check one callback entry and name it in the failure. Reads through a raw pointer because the
/// table is a `static mut` the kext also sees.
macro_rules! assert_cb {
    ($table:expr, $field:ident) => {
        assert!(
            (*$table).$field.is_some(),
            concat!(
                "pthread_kern.",
                stringify!($field),
                " is None. The port fills this field and the kext calls it through the vtable, \
                 so a None here is a null call inside psynch. It compiles because the other 78 \
                 fields legitimately come from the zeroed const."
            )
        );
    };
}

fn main() {
    unsafe {
        // Phase 1 and phase 2, the latter on a kernel microthread. xnu_sys_psynch_init runs
        // inside phase 2, so everything below is checking state that init left behind.
        let _kt = sched::init();

        // ---- the init invariants ----
        assert!(
            !bindings::pthread_list_mlock.is_null(),
            "pthread_list_mlock is NULL after init. This exact state shipped once: phase 2 \
             (xnu_sys_init_in_thread) was not wired, so the mutex was never allocated and the \
             first contended pthread wait died in the kext with a SIGSEGV, surfacing only as a \
             guest task exiting -111."
        );
        eprintln!("[psynch] pthread_list_mlock allocated");

        assert!(
            !bindings::psynch_thcall.is_null(),
            "psynch_thcall is NULL after init. thread_call_allocate failed or the init order \
             changed; the workqueue cleanup callout has nothing to run."
        );
        eprintln!("[psynch] psynch_thcall allocated");

        // ---- the callback vtable ----
        let table = *addr_of!(cider::xnu::psynch::pthread_kern);
        assert!(
            !table.is_null(),
            "pthread_kern is NULL. It is initialised at compile time to point at the table, so \
             a null here means something overwrote it at runtime."
        );

        assert_cb!(table, current_map);
        assert_cb!(table, get_bsdthread_info);
        assert_cb!(table, get_task_threadmax);
        assert_cb!(table, proc_get_pthhash);
        assert_cb!(table, proc_set_pthhash);
        assert_cb!(table, psynch_wait_cleanup);
        assert_cb!(table, psynch_wait_complete);
        assert_cb!(table, psynch_wait_prepare);
        assert_cb!(table, psynch_wait_update_complete);
        assert_cb!(table, psynch_wait_update_owner);
        assert_cb!(table, psynch_wait_wakeup);
        assert_cb!(table, __pthread_testcancel);
        assert_cb!(table, task_findtid);
        assert_cb!(table, thread_deallocate_safe);
        assert_cb!(table, unix_syscall_return);
        assert_cb!(table, uthread_get_uukwe);
        assert_cb!(table, uthread_is_cancelled);
        assert_cb!(table, uthread_set_returnval);
        eprintln!("[psynch] all 18 filled callback entries are non-null");

        println!("PSYNCH_DEMO_OK");
    }
}
