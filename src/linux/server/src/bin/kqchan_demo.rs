//! Runtime exercise of the ported xnu-sys kqchan mach-port channel (#80).
//!
//! kqchan was the LAST ported file nothing drove, which is the position psynch was in before
//! #77. The five existing demos cover semaphore.c, condvar.c, host.c, processor.c and psynch.c;
//! kqchan had nothing, and it is a live socket protocol between the daemon and the guest.
//!
//! WHAT THIS DRIVES, through the real MachPortKqchan::open path rather than the FFI directly:
//!
//!   xnu_sys_kqchan_mach_port_create        builds the XNU knote on the watched port and hands
//!                                        back the handle. open() turns a null return into
//!                                        ESRCH, so reaching Ok at all means it was non-null.
//!   the notification callback            registered by that same call. Until e721f238 it was
//!                                        declared as a bare safe `extern "C" fn` where the
//!                                        definition takes Option<unsafe extern "C" fn>, so it
//!                                        could not express the null the callee accepts. This
//!                                        demo is what would have caught a null or mistyped
//!                                        entry there, instead of a crash inside the kext.
//!   xnu_sys_kqchan_mach_port_has_events    open() calls it once the handle exists, to decide
//!                                        whether a message is already queued.
//!   xnu_sys_kqchan_mach_port_destroy       run from Drop when the channel goes out of scope.
//!
//! THE PORT IS A REAL ONE. mach_reply_port allocates a receive right in the CURRENT task ipc
//! space, which is why all of this runs on a kernel microthread rather than on the main thread:
//! there has to be a current-thread context for the trap and for the knote. Passing a made-up
//! port number would exercise the failure path instead, and prove much less.
//!
//! WHAT THIS DOES NOT COVER, stated rather than implied. The guest side of the protocol is not
//! driven: nothing sends a modify or read datagram down the socketpair, so
//! xnu_sys_kqchan_mach_port_modify, _fill and _disable_notifications are still untouched, and so
//! is on_readable. A message actually arriving on the watched port, which is what fires the
//! notification callback for real, is not exercised either. That is the second layer and it
//! needs a sender; this is the first, and it is the one that turns "never executed" into
//! "executed once end to end".
//!
//! THE FAILURE MODE IS AN ABORT, NOT A CLEAN PANIC, and that is worth knowing before reading a
//! failed run. An assertion inside the closure fires on a kernel MICROTHREAD, which runs on its
//! own stack, and unwinding off it does not work: the runtime reports "failed to initiate panic"
//! and dumps core. The check still catches it, because the verdict line never appears, but the
//! output ends in a core dump rather than a tidy panic message.
//!
//! PROVEN TO FAIL, which is the only reason a green run means anything here. Watching a made-up
//! port name instead of a real receive right makes xnu_sys_kqchan_mach_port_create return null,
//! open turn that into ESRCH, and the demo die without printing its verdict. So the pass depends
//! on the create path actually working.
//!
//! The verdict is the printed line, not the exit code, as with the other demos.

use cider::bindings::xnu_sys_task_t;
use cider::kqchan::MachPortKqchan;
use cider::mach::mach_reply_port;
use cider::sched;

fn main() {
    unsafe {
        let kt = sched::init();
        // usize rather than a pointer, so the closure stays Send-ish for spawn, the same shape
        // condvar_demo and stage3_spike use.
        let kt_addr = kt as usize;

        let mt = sched::spawn(
            kt,
            Box::new(move || {
                let task = kt_addr as *mut xnu_sys_task_t;

                let port = mach_reply_port();
                assert!(
                    port != 0,
                    "mach_reply_port returned a null name, so there is no receive right to \
                     watch and the rest of this demo would be testing the failure path"
                );
                eprintln!("[kqchan-mt] reply port {} allocated", port);

                // receive_buffer 0 and size 0: the guest would pass its own buffer here, and
                // the channel only reads it when a read request arrives, which this demo does
                // not send. saved_filter_flags 0 means no filter bits set.
                let (channel, guest_fd) = match MachPortKqchan::open(task, port, 0, 0, 0) {
                    Ok(v) => v,
                    Err(e) => panic!(
                        "MachPortKqchan::open failed: {e}. open turns a null return from \
                         xnu_sys_kqchan_mach_port_create into ESRCH, so this is either a null \
                         handle or the port is not watchable"
                    ),
                };
                eprintln!("[kqchan-mt] channel opened, daemon_fd {}", channel.daemon_fd);

                assert!(
                    channel.daemon_fd >= 0 && guest_fd >= 0,
                    "open returned Ok but one end of the socketpair is not a valid descriptor"
                );

                // Drop runs xnu_sys_kqchan_mach_port_destroy. Explicit rather than implicit so a
                // failure lands here, on a named line, rather than in the closure epilogue.
                drop(channel);
                libc::close(guest_fd);
                eprintln!("[kqchan-mt] channel destroyed");

                println!("KQCHAN_DEMO_OK");
            }),
        );

        sched::run(mt);
        sched::drain();
        assert!(
            (*mt).is_finished(),
            "the microthread did not finish, so something in the kqchan path blocked and never \
             came back"
        );
        eprintln!("[kqchan] create, has_events and destroy all ran: OK");
    }
}
