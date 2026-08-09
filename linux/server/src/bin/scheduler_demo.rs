//! Stage 4 foundation demo: drive a kernel microthread through a semaphore
//! block/wake using the reusable, static-mut-free `sched` module (promoted from
//! the Stage 3 spike). Proves the library scheduler works end to end.
use darling::bindings::dtape_semaphore_t;
use darling::sched;
use darling::xnu::semaphore::{dtape_semaphore_create, dtape_semaphore_down_simple, dtape_semaphore_up};

// The three declarations that used to sit here reached duct-tape through the linker, from when
// it was C. It is Rust now (#71), so they are imported (#75). A BIN CRATE, so darling:: and not
// crate:: .
//
// THE CASTS WENT WITH THEM, and that is the point. The declarations spelled both the task and
// the semaphore as *mut c_void while the definitions have always taken *mut dtape_task_t and
// *mut dtape_semaphore_t, so every call was laundering a typed pointer through c_void and
// nothing checked what came back. Now the types carry through.

fn main() {
    unsafe {
        let kt = sched::init();
        let sem = dtape_semaphore_create(kt, 0);
        let sem_addr = sem as usize;
        let mt = sched::spawn(kt, Box::new(move || {
            eprintln!("[demo-mt] down (blocks -> suspend)...");
            let ok = dtape_semaphore_down_simple(sem_addr as *mut dtape_semaphore_t);
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
