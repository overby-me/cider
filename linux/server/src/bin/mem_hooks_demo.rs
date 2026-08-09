//! Proof of the guest-memory hooks (task_read_memory / task_write_memory): the daemon
//! reading AND writing another process's address space via process_vm_readv/writev --
//! the exact primitive the C++ daemon uses (Process::readMemory, process.cpp) and the
//! foundation mach_msg copyin/copyout depends on. See PLAN.md
//! (bucket B.1, the head of the critical path).
//!
//! Fork a child holding a known buffer at a known address; the parent reads it back
//! through task_read_memory, overwrites it through task_write_memory, and the child
//! confirms -- with a volatile load, so the optimizer cannot hide the cross-process
//! write -- that it observes the change in its OWN address space. MEM_HOOKS_OK only if
//! the whole round trip holds.

use cider::sched::{self, TaskCtx};
use std::os::raw::c_void;

const N: usize = 64;

fn main() {
    unsafe { run() }
}

unsafe fn run() {
    // child -> parent: the buffer's address. parent -> child: "go verify" signal.
    let mut addr_pipe = [0i32; 2];
    let mut go_pipe = [0i32; 2];
    assert_eq!(libc::pipe(addr_pipe.as_mut_ptr()), 0, "pipe(addr)");
    assert_eq!(libc::pipe(go_pipe.as_mut_ptr()), 0, "pipe(go)");

    let pid = libc::fork();
    assert!(pid >= 0, "fork");

    if pid == 0 {
        // ---------------- child ----------------
        libc::close(addr_pipe[0]);
        libc::close(go_pipe[1]);

        // Heap buffer with pattern A (byte i = i). Boxed -> stable address; black_box
        // so the compiler cannot fold away its contents across the blocking read.
        let mut buf: Box<[u8; N]> = Box::new([0u8; N]);
        for (i, b) in buf.iter_mut().enumerate() {
            *b = i as u8;
        }
        let base = &buf[0] as *const u8;
        std::hint::black_box(base);

        // Hand the parent our buffer's address.
        let addr_bytes = (base as usize).to_ne_bytes();
        libc::write(addr_pipe[1], addr_bytes.as_ptr() as *const c_void, addr_bytes.len());

        // Block until the parent has read + overwritten our memory.
        let mut one = [0u8; 1];
        libc::read(go_pipe[0], one.as_mut_ptr() as *mut c_void, 1);

        // Verify (volatile, to force a real load) that the parent wrote pattern B.
        let mut ok = true;
        for i in 0..N {
            if std::ptr::read_volatile(base.add(i)) != (255u8 - i as u8) {
                ok = false;
                break;
            }
        }
        std::process::exit(if ok { 0 } else { 42 });
    }

    // ---------------- parent ----------------
    libc::close(addr_pipe[1]);
    libc::close(go_pipe[0]);

    // Receive the child's buffer address.
    let mut addr_bytes = [0u8; std::mem::size_of::<usize>()];
    let n = libc::read(addr_pipe[0], addr_bytes.as_mut_ptr() as *mut c_void, addr_bytes.len());
    assert_eq!(n, addr_bytes.len() as isize, "short read of child address");
    let remote = usize::from_ne_bytes(addr_bytes);
    eprintln!("[mem] child pid={pid}, buffer @ 0x{remote:x}");

    // The task context the xnu-sys would hand our hooks: it carries the guest pid.
    let ctx = TaskCtx { pid };
    let ctx_ptr = &ctx as *const TaskCtx as *mut c_void;

    // 1) READ HOOK: pull the child's buffer, expect pattern A (byte i = i).
    let mut got = [0u8; N];
    assert!(
        sched::task_read_memory(ctx_ptr, remote, got.as_mut_ptr() as *mut c_void, N),
        "task_read_memory hook failed"
    );
    for i in 0..N {
        assert_eq!(got[i], i as u8, "read mismatch at byte {i}");
    }
    eprintln!("[mem] read hook: {N} bytes match pattern A");

    // 2) WRITE HOOK: overwrite with pattern B (byte i = 255 - i).
    let mut patb = [0u8; N];
    for (i, b) in patb.iter_mut().enumerate() {
        *b = 255u8 - i as u8;
    }
    assert!(
        sched::task_write_memory(ctx_ptr, remote, patb.as_ptr() as *const c_void, N),
        "task_write_memory hook failed"
    );

    // 3) READ-BACK: confirm the write from the daemon's side.
    let mut got2 = [0u8; N];
    assert!(
        sched::task_read_memory(ctx_ptr, remote, got2.as_mut_ptr() as *mut c_void, N),
        "task_read_memory (readback) failed"
    );
    assert_eq!(got2, patb, "readback mismatch");
    eprintln!("[mem] write hook: daemon-side readback matches pattern B");

    // 4) Tell the child to verify from ITS OWN view; confirm it saw the change.
    libc::write(go_pipe[1], [1u8].as_ptr() as *const c_void, 1);
    let mut status = 0i32;
    libc::waitpid(pid, &mut status, 0);
    assert!(libc::WIFEXITED(status), "child did not exit normally");
    let code = libc::WEXITSTATUS(status);
    assert_eq!(code, 0, "child saw the WRONG bytes (exit {code}): cross-process write not visible");
    eprintln!("[mem] child confirms pattern B in its own address space");

    println!("MEM_HOOKS_OK: read+write another process's memory via the task memory hooks");
}
