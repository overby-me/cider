//! Stage 4 foundation demo: drive a kernel microthread through a semaphore
//! block/wake using the reusable, static-mut-free `sched` module (promoted from
//! the Stage 3 spike). Proves the library scheduler works end to end.
use darling::sched;
use std::os::raw::{c_int, c_void};

extern "C" {
    fn dtape_semaphore_create(task: *mut c_void, initial: c_int) -> *mut c_void;
    fn dtape_semaphore_up(sem: *mut c_void);
    fn dtape_semaphore_down_simple(sem: *mut c_void) -> bool;
}

fn main() {
    unsafe {
        let kt = sched::init();
        let sem = dtape_semaphore_create(kt as *mut c_void, 0);
        let sem_addr = sem as usize;
        let mt = sched::spawn(kt, Box::new(move || {
            eprintln!("[demo-mt] down (blocks -> suspend)...");
            let ok = dtape_semaphore_down_simple(sem_addr as *mut c_void);
            println!("{}", if ok { "SCHED_DEMO_OK" } else { "SCHED_DEMO_DOWN_FAILED" });
        }));
        sched::run(mt);
        assert!((*mt).is_suspended() && !(*mt).is_finished(), "did not suspend");
        eprintln!("[demo] suspended via lib; posting up");
        dtape_semaphore_up(sem);
        sched::drain();
        assert!((*mt).is_finished(), "did not finish");
        eprintln!("[demo] scheduler module: microthread block/wake OK (static-mut-free lib).");
    }
}
