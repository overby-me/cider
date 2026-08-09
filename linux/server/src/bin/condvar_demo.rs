//! Runtime exercise of the ported duct-tape condvar (#71).
//!
//! The semaphore port got a runtime check for free, because `scheduler_demo` already drove
//! it. condvar had none: its only coverage was unit tests over the TAILQ helpers in
//! isolation, which say nothing about whether a microthread actually suspends on a condvar
//! and is actually woken by a signal. This closes that gap, and runs in about a minute
//! rather than the hour the minimal-prefix gate takes.
//!
//! The path it drives, all of it Rust as of the condvar port:
//!   dtape_condvar_wait   takes the queue lock, DROPS the caller's mutex, puts the thread's
//!                        mutex_link on the intrusive queue, and suspends the microthread
//!                        through the thread_suspend hook (which also drops the queue lock)
//!   dtape_condvar_signal pops a link, walks back to the containing dtape_thread through the
//!                        container_of offset, and resumes it via the thread_resume hook
//!
//! Both halves of the queue arithmetic have to be right for this to finish: a wrong
//! INSERT_TAIL loses the waiter (nothing to pop, so the signal wakes nobody and the demo
//! hangs), and a wrong REMOVE corrupts the queue.
//!
//! The verdict is the printed line, not the exit code, for the same reason as
//! scheduler_demo: the harness asserts hold in cases where the result is still wrong.

use cider::bindings::{dtape_condvar_t, dtape_mutex_t};
use cider::sched;

// These were `extern "C"` declarations resolving through the linker back into the cider
// crate, from when duct-tape was C. It is Rust now (#71), so they are imported (#75).
//
// A BIN CRATE, so the path is cider:: and not crate:: . The seven files under src/bin are
// separate rust_binary targets that depend on :cider; crate:: would not compile here, and
// the original #75 edit list had it wrong for all of them.
//
// All six matched their definitions already, so no call site changes: the declarations spelled
// dtape_mutex_t and dtape_condvar_t exactly as locks.rs and condvar.rs do.
use cider::xnu::condvar::{dtape_condvar_init, dtape_condvar_signal, dtape_condvar_wait};
use cider::xnu::locks::{dtape_mutex_init, dtape_mutex_lock, dtape_mutex_unlock};

fn main() {
    unsafe {
        let kt = sched::init();

        let mut mutex: Box<dtape_mutex_t> = Box::new(std::mem::zeroed());
        let mut condvar: Box<dtape_condvar_t> = Box::new(std::mem::zeroed());
        dtape_mutex_init(&mut *mutex);
        dtape_condvar_init(&mut *condvar);

        // Addresses rather than pointers, so the closure stays Send-ish for spawn.
        let mutex_addr = (&mut *mutex as *mut dtape_mutex_t) as usize;
        let condvar_addr = (&mut *condvar as *mut dtape_condvar_t) as usize;

        let mt = sched::spawn(
            kt,
            Box::new(move || {
                let m = mutex_addr as *mut dtape_mutex_t;
                let c = condvar_addr as *mut dtape_condvar_t;
                dtape_mutex_lock(m);
                eprintln!("[condvar-mt] waiting (drops the mutex, suspends)...");
                dtape_condvar_wait(c, m);
                // Back here only if the signal found us on the queue AND the wait reacquired
                // the mutex on the way out.
                dtape_mutex_unlock(m);
                println!("CONDVAR_DEMO_OK");
            }),
        );

        sched::run(mt);
        assert!(
            (*mt).is_suspended() && !(*mt).is_finished(),
            "the microthread did not suspend on the condvar"
        );

        eprintln!("[condvar] suspended; signalling one waiter");
        dtape_condvar_signal(&mut *condvar, 1);

        sched::drain();
        assert!((*mt).is_finished(), "the microthread did not finish after the signal");
        eprintln!("[condvar] block and wake through the ported condvar: OK");
    }
}
