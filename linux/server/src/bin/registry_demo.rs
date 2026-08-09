//! Stage 4 slice: per-guest routing via the process/thread tables. Two "guests"
//! (pids 100 and 200) each get their own dtape task; uidgid calls routed by pid run
//! on the right task, so each guest has independent uid state -- proven by second
//! calls reporting each guest's own previously-set value as "old".
use cider::registry::Registry;
use cider::rpc_wire::{CallUidgid, ReplyUidgid};
use cider::sched;
use std::cell::Cell;
use std::os::raw::{c_int, c_void};
use std::rc::Rc;

extern "C" {
    fn dtape_task_uidgid(task: *mut c_void, new_uid: c_int, new_gid: c_int, old_uid: *mut c_int, old_gid: *mut c_int);
}

/// Run a uidgid handler for guest (pid,tid) on ITS task and return the reply. The
/// handler uses sched::current_task() -- it never sees the pid, only "my task".
unsafe fn call_uidgid(reg: &mut Registry, pid: u32, tid: u64, call: CallUidgid) -> ReplyUidgid {
    let slot: Rc<Cell<Option<ReplyUidgid>>> = Rc::new(Cell::new(None));
    let out = slot.clone();
    let mt = reg.spawn_on(pid, tid, 2 /* x86_64 */, Box::new(move || {
        let task = sched::current_task(); // <-- routed to this guest's task
        let (mut ou, mut og): (c_int, c_int) = (-1, -1);
        dtape_task_uidgid(task as *mut c_void, call.new_uid, call.new_gid, &mut ou, &mut og);
        out.set(Some(ReplyUidgid { old_uid: ou, old_gid: og }));
    }));
    sched::run(mt);
    sched::drain();
    slot.get().expect("no reply")
}

fn main() {
    unsafe {
        let kt = sched::init();
        let mut reg = Registry::new(kt);

        // First calls: each guest sets its own uid; both start from 0.
        let a1 = call_uidgid(&mut reg, 100, 100, CallUidgid { new_uid: 1100, new_gid: 1101 });
        let b1 = call_uidgid(&mut reg, 200, 200, CallUidgid { new_uid: 2200, new_gid: 2201 });
        println!("[reg] pid100 old=({},{})  pid200 old=({},{})  tasks={}", a1.old_uid, a1.old_gid, b1.old_uid, b1.old_gid, reg.task_count());
        assert_eq!((a1.old_uid, b1.old_uid), (0, 0), "first calls see uid 0");

        // Second calls: each guest must see ITS OWN previously-set uid as "old".
        let a2 = call_uidgid(&mut reg, 100, 101, CallUidgid { new_uid: 1150, new_gid: 1151 });
        let b2 = call_uidgid(&mut reg, 200, 201, CallUidgid { new_uid: 2250, new_gid: 2251 });
        println!("[reg] pid100 old={} (expect 1100)   pid200 old={} (expect 2200)", a2.old_uid, b2.old_uid);
        assert_eq!(a2.old_uid, 1100, "pid100 must see its own prior uid");
        assert_eq!(b2.old_uid, 2200, "pid200 must see its own prior uid");
        assert_eq!(reg.task_count(), 2, "two distinct guest tasks");

        println!("REGISTRY_OK: two guests routed to independent dtape tasks by pid; per-guest state isolated");
    }
}
