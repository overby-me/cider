//! Persistent per-guest threads (bucket B.2), the scheduler+registry shape a blocking
//! mach_msg receive needs: a guest thread's call BLOCKS mid-flight, its microthread
//! persists (parked, addressable by tid), and when the awaited event arrives the daemon
//! resumes the SAME logical thread -- continuing on the same stack with its per-thread
//! state intact. Builds on the proven stackful suspend/resume (Stage 3); what is new is
//! that the thread survives as a tid-addressable guest thread the daemon can wake.
//!
//! Proof: two guest threads each issue a "receive" that blocks (both park); delivering
//! to one wakes exactly that thread (the other stays parked, untouched), and its reply
//! combines a STACK-LOCAL stamped before the block with the delivered payload -- so the
//! stack survived. See PLAN.md.

use darling::registry::Registry;
use darling::sched;
use std::cell::RefCell;
use std::rc::Rc;

/// Per-thread mailbox: the daemon delivers a message; the thread leaves its reply.
#[derive(Default)]
struct Mailbox {
    delivered: Option<u64>,
    reply: Option<u64>,
}

/// The "receive" call body: stamp a stack-local derived from tid, then block until the
/// daemon delivers a message; on resume, reply = stack_local + message.
fn receive_body(tid: u64, mb: Rc<RefCell<Mailbox>>) -> Box<dyn FnOnce()> {
    Box::new(move || {
        let stack_local: u64 = 0xBEEF_0000u64 ^ tid; // lives on the microthread's stack
        loop {
            if mb.borrow().delivered.is_some() {
                break;
            }
            // Block: yield to the daemon. The same primitive the thread_suspend hook
            // uses when XNU blocks a thread (here driven directly, no XNU needed).
            unsafe { sched::suspend_current(None, std::ptr::null_mut(), std::ptr::null_mut()) };
        }
        let msg = mb.borrow().delivered.unwrap();
        mb.borrow_mut().reply = Some(stack_local.wrapping_add(msg));
    })
}

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    let kt = sched::init();
    let mut reg = Registry::new(kt);
    let pid: u32 = 7000;
    let arch: u32 = 2; // x86_64

    let (t1, t2): (u64, u64) = (11, 22);
    let mb1 = Rc::new(RefCell::new(Mailbox::default()));
    let mb2 = Rc::new(RefCell::new(Mailbox::default()));

    // Both threads issue the receive and BLOCK, so both microthreads persist (parked).
    let p1 = reg.run_thread(pid, t1, arch, receive_body(t1, mb1.clone()));
    let p2 = reg.run_thread(pid, t2, arch, receive_body(t2, mb2.clone()));
    assert!(p1 && p2, "both threads should block (park) on the receive");
    assert_eq!(reg.parked_count(), 2, "two guest threads parked");
    assert!(
        mb1.borrow().reply.is_none() && mb2.borrow().reply.is_none(),
        "no replies before any delivery"
    );
    eprintln!("[pthreads] t1 and t2 both blocked mid-call; {} parked", reg.parked_count());

    // Deliver to t1 and wake it; t2 must stay parked and untouched.
    let msg1: u64 = 0x1000;
    mb1.borrow_mut().delivered = Some(msg1);
    let still1 = reg.wake_thread(pid, t1);
    assert!(!still1, "t1 should finish after its message arrives");
    assert!(
        reg.is_parked(pid, t2) && !reg.is_parked(pid, t1),
        "only t2 remains parked after t1 completes"
    );
    let want1 = (0xBEEF_0000u64 ^ t1).wrapping_add(msg1);
    assert_eq!(
        mb1.borrow().reply,
        Some(want1),
        "t1 reply must combine its PRESERVED stack-local with the delivered message"
    );
    assert!(mb2.borrow().reply.is_none(), "waking t1 must not touch t2");
    eprintln!(
        "[pthreads] delivered 0x{msg1:x} to t1 -> resumed the same thread; stack-local survived; reply=0x{:x}",
        mb1.borrow().reply.unwrap()
    );

    // Now deliver to t2.
    let msg2: u64 = 0x2000;
    mb2.borrow_mut().delivered = Some(msg2);
    let still2 = reg.wake_thread(pid, t2);
    assert!(!still2, "t2 should finish after its message arrives");
    assert_eq!(reg.parked_count(), 0, "no threads parked after both complete");
    let want2 = (0xBEEF_0000u64 ^ t2).wrapping_add(msg2);
    assert_eq!(mb2.borrow().reply, Some(want2), "t2 reply must combine its preserved stack-local");
    eprintln!(
        "[pthreads] delivered 0x{msg2:x} to t2 -> reply=0x{:x}",
        mb2.borrow().reply.unwrap()
    );

    println!("PERSISTENT_THREADS_OK: guest threads block mid-call, persist addressable by tid, and resume on the same stack with state preserved (the mach_msg receive shape)");
}
