//! Process/thread tables: map a guest pid -> its dtape task, so each guest's calls
//! run on its OWN task (its own XNU state), not the shared kernel task. A microthread
//! spawned via `spawn_on` is bound to the guest's task, so sched::current_task()
//! inside its handler returns that task -- the routing mechanism. See
//! PLAN.md (Stage 4).

use crate::bindings::*;
use crate::sched::{self, Microthread, TaskCtx};
use std::collections::HashMap;
use std::os::raw::c_void;

// Was an `extern "C"` declaration resolving back into this crate through the linker; imported
// directly since xnu-sys became Rust (#71, #75).
use crate::xnu::task::dtape_task_create;

/// The architecture arrives from the RPC wire as a plain u32; dtape_task_create takes the
/// bindgen ENUM.
///
/// THIS CONVERSION WAS ALREADY HAPPENING, just invisibly. The extern declaration removed above
/// said `arch: u32` while the definition has always taken dserver_rpc_architecture_t, and
/// rustc does not check a declaration against a definition, so the raw wire value was handed
/// straight to an enum parameter. An out-of-range value therefore became an invalid
/// discriminant, which is undefined behaviour rather than a wrong answer. A guest is what
/// supplies it.
///
/// Matched explicitly instead, with anything unrecognised mapping to the invalid variant that
/// already exists for the purpose.
fn arch_from_wire(arch: u32) -> crate::bindings::dserver_rpc_architecture_t {
    use crate::bindings::dserver_rpc_architecture_t as A;
    match arch {
        x if x == A::dserver_rpc_architecture_i386 as u32 => A::dserver_rpc_architecture_i386,
        x if x == A::dserver_rpc_architecture_x86_64 as u32 => A::dserver_rpc_architecture_x86_64,
        x if x == A::dserver_rpc_architecture_arm32 as u32 => A::dserver_rpc_architecture_arm32,
        x if x == A::dserver_rpc_architecture_arm64 as u32 => A::dserver_rpc_architecture_arm64,
        _ => A::dserver_rpc_architecture_invalid,
    }
}

pub struct Registry {
    kernel_task: *mut dtape_task_t,
    tasks: HashMap<u32, *mut dtape_task_t>, // guest pid -> dtape task
    ctxs: HashMap<u32, Box<TaskCtx>>,       // keep task contexts alive + address-stable
    parked: HashMap<(u32, u64), *mut Microthread>, // (pid,tid) -> guest thread blocked mid-call
    host_pids: HashMap<u32, libc::pid_t>,   // nsid -> daemon-namespace pid (for memory ops)
}

impl Registry {
    pub fn new(kernel_task: *mut dtape_task_t) -> Self {
        Registry {
            kernel_task,
            tasks: HashMap::new(),
            ctxs: HashMap::new(),
            parked: HashMap::new(),
            host_pids: HashMap::new(),
        }
    }

    /// Record the daemon-namespace (host) pid for a guest nsid, so the task's memory hooks
    /// (process_vm_readv/writev) target the right process. Needed when the guest runs in
    /// its own PID namespace (nsid != host pid); for in-process work nsid IS the host pid,
    /// so this need not be called. Must be set before the task is first ensured.
    pub fn set_host_pid(&mut self, nsid: u32, host_pid: libc::pid_t) {
        self.host_pids.insert(nsid, host_pid);
    }

    /// Get or create the dtape task for a guest pid (nsid = pid). Parent is NULL for
    /// now (a real checkin would pass the parent process's task).
    pub unsafe fn ensure_task(&mut self, pid: u32, arch: u32) -> *mut dtape_task_t {
        if let Some(&t) = self.tasks.get(&pid) {
            return t;
        }
        // Address-stable per-task context carrying the guest's host pid, handed to the
        // xnu-sys as the task's void* context and back to the memory hooks. Boxed so
        // it never moves while C holds the pointer. (nsid doubles as the host pid here;
        // a real checkin passes the connecting process's actual host pid.)
        let host_pid = self.host_pids.get(&pid).copied().unwrap_or(pid as libc::pid_t);
        let mut ctx = Box::new(TaskCtx { pid: host_pid });
        let ctx_ptr = ctx.as_mut() as *mut TaskCtx as *mut c_void;
        // The PARENT task, found through /proc/<host pid>/PPid. This has to be right, and
        // for a long time it was simply NULL: ipc_task_init's parent==TASK_NULL branch sets
        // itk_bootstrap = IP_NULL, so a task created without a parent can never inherit
        // launchd's bootstrap port. Every launchd JOB then asks for its bootstrap port, gets
        // nothing, sends its first service lookup to MACH_PORT_NULL and exits -- which is the
        // whole of task #47. With a parent, ipc_task_init also inherits the exception ports,
        // the registered ports and the security/audit tokens, which is what XNU does.
        //
        // The lookup happens HERE rather than in Handler::set_current because the task is
        // created before the first call is dispatched, so set_current's parent link comes
        // too late to be passed to dtape_task_create.
        let parent = crate::task::read_ppid(host_pid)
            .and_then(|ppid| {
                self.host_pids
                    .iter()
                    .find(|(_, &hp)| hp == ppid)
                    .map(|(&pnsid, _)| pnsid)
            })
            .and_then(|pnsid| self.tasks.get(&pnsid).copied())
            .unwrap_or(std::ptr::null_mut());
        let t = dtape_task_create(parent, pid, ctx_ptr, arch_from_wire(arch));
        assert!(!t.is_null(), "dtape_task_create failed for pid {pid}");
        self.tasks.insert(pid, t);
        self.ctxs.insert(pid, ctx);
        // Publish to the task_lookup table so the static dtape hook can resolve this task.
        sched::register_task_lookup(pid, t, host_pid);
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
        let host_pid = self.host_pids.get(&pid).copied().unwrap_or(pid as libc::pid_t);
        let mt = sched::spawn_with_nsid(task, tid, body);
        (*mt).set_host_pid(host_pid);
        // Publish to the thread_lookup table so the static dtape hook can resolve this thread.
        sched::register_thread_lookup(tid, (*mt).dtape_thread());
        mt
    }

    /// Run a call on guest thread (pid,tid): spawn its microthread on the guest's task,
    /// run it, and if the call BLOCKS (suspends, e.g. a mach_msg receive) park the
    /// microthread addressable by tid so a later `wake_thread` resumes the SAME thread
    /// (stack + per-thread state preserved). Returns true if it parked, false if the
    /// call ran to completion. A finished thread's microthread box is reclaimed.
    pub unsafe fn run_thread(&mut self, pid: u32, tid: u64, arch: u32, body: Box<dyn FnOnce()>) -> bool {
        let mt = self.spawn_on(pid, tid, arch, body);
        sched::run(mt);
        if (*mt).is_suspended() {
            self.parked.insert((pid, tid), mt);
            true
        } else {
            drop(Box::from_raw(mt));
            false
        }
    }

    /// Resume the parked (blocked) guest thread (pid,tid) -- the daemon calls this when
    /// the event it was waiting on arrives. Returns true if it blocked again (still
    /// parked), false if it finished (removed + box reclaimed). No-op returning false
    /// if no such thread is parked.
    pub unsafe fn wake_thread(&mut self, pid: u32, tid: u64) -> bool {
        let mt = match self.parked.get(&(pid, tid)) {
            Some(&m) => m,
            None => return false,
        };
        sched::run(mt);
        if (*mt).is_suspended() {
            true
        } else {
            self.parked.remove(&(pid, tid));
            drop(Box::from_raw(mt));
            false
        }
    }

    /// Number of guest threads currently parked (blocked mid-call).
    pub fn parked_count(&self) -> usize {
        self.parked.len()
    }
    pub fn is_parked(&self, pid: u32, tid: u64) -> bool {
        self.parked.contains_key(&(pid, tid))
    }

    /// The parked (suspended) microthread for a guest thread, if any -- so the serve loop can
    /// read its at_dowork_top / dtape_thread for the nested signal-interrupt path (task #58).
    pub fn parked_mt(&self, pid: u32, tid: u64) -> Option<*mut Microthread> {
        self.parked.get(&(pid, tid)).copied()
    }

    /// The task a guest thread's microthread is bound to (for spawning a nested interrupt on
    /// the same task). None if the thread is not parked.
    pub unsafe fn thread_task(&self, pid: u32, tid: u64) -> Option<*mut dtape_task_t> {
        self.parked.get(&(pid, tid)).map(|&mt| (*mt).owning_task_ptr())
    }
}
