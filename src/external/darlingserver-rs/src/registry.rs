//! Process/thread tables: map a guest pid -> its dtape task, so each guest's calls
//! run on its OWN task (its own XNU state), not the shared kernel task. A microthread
//! spawned via `spawn_on` is bound to the guest's task, so sched::current_task()
//! inside its handler returns that task -- the routing mechanism. See
//! plan/rust-rewrite-eval.md (Stage 4).

use crate::bindings::*;
use crate::sched::{self, Microthread};
use std::collections::HashMap;
use std::os::raw::c_void;

extern "C" {
    fn dtape_task_create(parent: *mut dtape_task_t, nsid: u32, context: *mut c_void, arch: u32) -> *mut dtape_task_t;
}

pub struct Registry {
    kernel_task: *mut dtape_task_t,
    tasks: HashMap<u32, *mut dtape_task_t>, // guest pid -> dtape task
}

impl Registry {
    pub fn new(kernel_task: *mut dtape_task_t) -> Self {
        Registry { kernel_task, tasks: HashMap::new() }
    }

    /// Get or create the dtape task for a guest pid (nsid = pid). Parent is NULL for
    /// now (a real checkin would pass the parent process's task).
    pub unsafe fn ensure_task(&mut self, pid: u32, arch: u32) -> *mut dtape_task_t {
        if let Some(&t) = self.tasks.get(&pid) {
            return t;
        }
        let t = dtape_task_create(std::ptr::null_mut(), pid, std::ptr::null_mut(), arch);
        assert!(!t.is_null(), "dtape_task_create failed for pid {pid}");
        self.tasks.insert(pid, t);
        t
    }

    pub fn task_for_pid(&self, pid: u32) -> Option<*mut dtape_task_t> {
        self.tasks.get(&pid).copied()
    }
    pub fn kernel_task(&self) -> *mut dtape_task_t { self.kernel_task }
    pub fn task_count(&self) -> usize { self.tasks.len() }

    /// Spawn a microthread for guest thread `tid` on process `pid`'s task, to run one
    /// call handler. (Guest tids must stay below the kernel-thread-id threshold, 1<<22;
    /// persistent per-guest-thread microthreads are a later refinement.)
    pub unsafe fn spawn_on(&mut self, pid: u32, tid: u64, arch: u32, body: Box<dyn FnOnce()>) -> *mut Microthread {
        let task = self.ensure_task(pid, arch);
        sched::spawn_with_nsid(task, tid, body)
    }
}
