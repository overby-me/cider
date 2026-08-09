//! Stage 3 spike, now driven by the reusable `sched` library (the same machinery,
//! promoted off `static mut`). Proves both dtape suspend paths + a microbench:
//!   Phase 1 STACKFUL     -- semaphore down/up -> SPIKE_RESUMED_OK
//!   Phase 2 CONTINUATION -- assert_wait + thread_block(cont) -> SPIKE_CONT_RESUMED_OK
//!   Phase 3 microbench   -- N suspend/resume round-trips
//! XNU_SYS_LIB=<dir> cargo run --bin stage3-spike

use cider::bindings::dtape_semaphore_t;
use cider::xnu::thread::thread_block;
use cider::xnu::semaphore::{dtape_semaphore_create, dtape_semaphore_down_simple, dtape_semaphore_up};

// The semaphore trio and thread_block were declared through the linker, from when xnu-sys was
// C. Rust now (#71), so imported (#75). A BIN CRATE, so cider:: and not crate:: .
//
// assert_wait and thread_wakeup_prim STAY declared: they are XNU, living in the xnu-sys
// archive, and there is no Rust definition to import.
//
// The thread_block declaration removed here was CORRECT, unlike the one gate10 found in
// dtape_kqchan.rs: wait_result_t is c_int and thread_continue_t is
// Option<fn(*mut c_void, wait_result_t)>, so it matched. Checked rather than assumed.
use cider::sched;
use std::os::raw::{c_int, c_void};

extern "C" {
    // Raw XNU scheduler primitives (in the xnu-sys .a) for the continuation vehicle.
    fn assert_wait(event: *const c_void, interruptible: c_int) -> c_int;
    fn thread_wakeup_prim(event: *const c_void, one_thread: c_int, result: c_int) -> c_int;
}
static EVENT: u8 = 0;
unsafe extern "C" fn phase2_continuation(_p: *mut c_void, _wr: c_int) {
    println!("SPIKE_CONT_RESUMED_OK");
}

fn main() {
    unsafe {
        let kt = sched::init();

        // Phase 1: stackful suspend/resume via a semaphore.
        let sem = dtape_semaphore_create(kt, 0);
        let sa = sem as usize;
        let p1 = sched::spawn(kt, Box::new(move || {
            eprintln!("[p1] down (blocks -> stackful suspend)...");
            if dtape_semaphore_down_simple(sa as *mut dtape_semaphore_t) {
                println!("SPIKE_RESUMED_OK");
            }
        }));
        sched::run(p1);
        assert!((*p1).is_suspended() && !(*p1).is_finished(), "p1 did not suspend");
        dtape_semaphore_up(sem);
        sched::drain();
        assert!((*p1).is_finished(), "p1 did not finish");
        eprintln!("[spike] Phase 1 (stackful) PROVEN.");

        // Phase 2: continuation suspend/resume via assert_wait + thread_block.
        let p2 = sched::spawn(kt, Box::new(|| {
            eprintln!("[p2] assert_wait + thread_block(cont) (blocks -> continuation suspend)...");
            assert_wait(&EVENT as *const u8 as *const c_void, 0);
            thread_block(Some(phase2_continuation));
            println!("SPIKE_CONT_UNEXPECTED_RETURN");
        }));
        sched::run(p2);
        assert!((*p2).is_suspended() && !(*p2).is_finished(), "p2 did not suspend");
        thread_wakeup_prim(&EVENT as *const u8 as *const c_void, 0, 0);
        sched::drain();
        assert!((*p2).is_finished(), "p2 did not finish");
        eprintln!("[spike] Phase 2 (continuation) PROVEN.");

        // Phase 3: microbench the suspend/resume round-trip.
        const N: u64 = 500_000;
        let bsem = dtape_semaphore_create(kt, 0);
        let ba = bsem as usize;
        let bench = sched::spawn(kt, Box::new(move || {
            for _ in 0..N {
                dtape_semaphore_down_simple(ba as *mut dtape_semaphore_t);
            }
        }));
        sched::run(bench);
        let t0 = std::time::Instant::now();
        for _ in 0..N {
            dtape_semaphore_up(bsem);
            sched::drain();
        }
        let el = t0.elapsed();
        assert!((*bench).is_finished(), "bench did not finish");
        eprintln!(
            "[bench] {} suspend+resume round-trips in {:?} = {:.0} ns/round-trip",
            N, el, el.as_nanos() as f64 / N as f64
        );
        eprintln!("[spike] both suspend paths + microbench PROVEN on the sched lib.");
    }
}
