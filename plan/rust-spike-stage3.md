# Stage 3 spike design: can a Rust microthread suspend/resume across the dtape FFI?

This is the make-or-break spike from `plan/rust-rewrite-eval.md`. Do it **before**
committing to porting the daemon. It is scoped to days, not weeks. Everything below
is grounded in the actual mechanism in `src/external/darlingserver` (2026-07).

## The single hypothesis to falsify

> A **Rust-owned, stackful microthread** can be entered by the daemon loop, run C/XNU
> code that **suspends it from deep inside a C call stack** (via the daemon-supplied
> `dtape_hooks->thread_suspend`), be **resumed later** (via `thread_resume`), and
> continue from the suspend point correctly and at ~the current P1 switch cost.

If yes -> the whole rewrite is mechanically viable (this is the one thing that
cannot be worked around). If no, or only slowly/ugly -> stop, having spent days.

## The exact mechanism the spike must reproduce

From `thread.cpp` / `server.cpp`, the current C++ daemon does this (the spike
reimplements the daemon side in Rust; the C duct-tape is unchanged):

- **Context primitives (P1):** `src/fast_context.c` exports
  `dserver_fast_{get,set,make}context` -- signal-mask-free ucontext (no per-switch
  `rt_sigprocmask`; this is the landed P1 win). `thread.cpp` `#define`s the standard
  names to these.
- **Enter a microthread (`doWork`, worker side):** `getcontext(&backToThreadTopContext)`
  saves the loop's return point, then `setcontext(&_resumeContext)` (stackful resume)
  or `makecontext(&_resumeContext, microthreadContinuation)` on a fresh stack
  (continuation resume) jumps into the microthread.
- **Suspend (`Thread::suspend`, called from inside XNU via the hook):**
  ```
  _suspended = true;                 // under _rwlock
  unlockMeWhenSuspending = unlockMe;
  getcontext(&_resumeContext);       // <-- returns TWICE
  if (_suspended) {                  // first return: not yet resumed
      if (continuationCallback) _continuationCallback = continuationCallback;
      setcontext(&backToThreadTopContext);   // jump back to the loop
      __builtin_unreachable();
  } else {                           // second return: we were resumed -> continue
      ...
  }
  ```
  The `getcontext`-returns-twice trick is the crux, and it is invoked from **inside
  a C/XNU frame** (`semaphore_wait` -> `thread_block` -> `dtape_hooks->thread_suspend`
  -> `Thread::suspend`). ucontext switches from any frame; a Rust stackful coroutine
  must do the same.
- **Resume (`Thread::resume`, called from another context):** just
  `Server::scheduleThread(self)` -- re-queue onto the work queue; a worker's `doWork`
  then does the `setcontext(&_resumeContext)`, so the `getcontext` above returns its
  second time with `_suspended == false`.
- **Hook wiring:** `server.cpp:388` registers `dtape_hooks` (a 34-field vtable, see
  `duct-tape/include/darlingserver/duct-tape/hooks.h`) via `dtape_init(&dtape_hooks)`.
  `thread_suspend`/`thread_resume` forward to `Thread::suspend`/`resume` on the
  `void* thread_context` (the daemon's Thread object).

Two suspend paths exist and the design must respect both eventually:
- **Stackful** (`continuationCallback == NULL`): stack preserved, resume returns from
  the suspend call. **<- the spike proves THIS path.**
- **Continuation** (`continuationCallback != NULL`): old stack discarded
  (`stackPool.free`), resume runs a fresh stack via `makecontext(microthreadContinuation)`.
  **<- validated in a follow-up, not the spike (see Deferred).**

## Test vehicle (zero new C code required)

The duct-tape already exposes everything needed -- do **not** add shims:

- `dtape_semaphore_create(kernel_task, 0)` -> a semaphore at value 0.
- `dtape_semaphore_down_simple(sem)` (`duct-tape/src/semaphore.c:51`, calls XNU
  `semaphore_wait`) -> **blocks** the calling microthread -> XNU -> `thread_suspend`.
- `dtape_semaphore_up(sem)` (`semaphore.c:33`, XNU `semaphore_signal`) -> **wakes**
  the waiter -> `thread_resume`.

Spike flow:
1. `dtape_init(&RUST_HOOKS)`, then per-thread init as the C++ does
   (`Thread::kernelSync(dtape_init_in_thread)` equivalent -- run `dtape_init_in_thread`
   on one bootstrap microthread).
2. Create a kernel task + a kernel microthread (mirror `dtape_hook_thread_create_kernel`
   / the `kernelAsync` pattern) whose body is: `dtape_semaphore_down_simple(sem)`;
   then print `SPIKE_RESUMED_OK`; return.
3. Enter that microthread from the loop (`doWork`) -> it calls down -> **suspends**.
4. Loop observes the microthread suspended, then calls `dtape_semaphore_up(sem)` ->
   the waiter is scheduled -> loop re-enters it (`doWork`) -> down returns ->
   `SPIKE_RESUMED_OK` prints -> microthread exits cleanly.

**Success = `SPIKE_RESUMED_OK` prints and the process exits 0**, i.e. a Rust stackful
microthread suspended from inside XNU C and resumed correctly across the FFI.

## Minimal hook subset (implement ~12 of 34; stub the rest to abort-if-called)

The semaphore vehicle touches only scheduler + identity, not guest memory. Implement:

- `current_task`, `current_thread` (thread-local "current microthread").
- `thread_suspend`, `thread_resume` (the crux).
- `thread_setup`, `thread_create_kernel`, `thread_context_dispose` (kernel microthread
  lifecycle).
- `current_thread_interrupt_disable`/`enable` (increment/decrement a per-thread counter;
  the semaphore path checks it).
- `log` (to stderr), `timer_arm` (no-op / store deadline; the spike arms no timers),
  `get_load_info` (return zeros).

Everything else (`task_read_memory`/`write_memory`/`allocate_pages`/... , the
`thread_lookup*`, `send_signal`, `syscall_return`, `set_bsd_retval`, eternal-id) ->
a single `unimplemented_hook()` that logs its name and `abort()`s. If the spike
`abort()`s in one of these, that is information: the vehicle grew beyond scope.

## Two implementation arms (build both; pick by correctness + P1 cost)

**Arm A -- FFI the proven `fast_context.c` (low risk, preserves P1 exactly).**
Wrap `dserver_fast_{get,set,make}context` in a tiny Rust `Microthread` that reproduces
the getcontext-returns-twice dance. This is the safe baseline: it *cannot* regress P1
(same code) and isolates the question to "does the Rust daemon side wire up
correctly". Downside: still raw ucontext behind `unsafe` (contained to ~1 module).

**Arm B -- `corosensei` (the clean Rust way).** Back the `Microthread` with a
`corosensei::Coroutine`. `thread_resume` -> `coroutine.resume(())`;
`thread_suspend` -> `YIELDER.with(|y| y.suspend(()))`. corosensei's yield does a stack
switch like `setcontext`, so it works from a foreign C frame **iff** the hook can
reach the yielder -- see below. Benchmark switch cost vs Arm A; corosensei must be
within noise of P1 (it does no sigmask syscall, so it should be).

Decision rule: if Arm B is correct *and* within ~10% of Arm A's switch ns, adopt B for
Stage 4 (safer, no hand-rolled ucontext). Else ship Stage 4 on Arm A and revisit.

## Two Rust-specific hazards the spike must confront (not skip)

1. **Reaching the yielder / current-thread from a C callback.** The hook fires deep
   in C with only `void* thread_context`. Mirror the C++ `thread_local currentThreadVar`:
   a `thread_local! { static CURRENT: Cell<*mut Microthread> }` set on entry (`doWork`)
   and cleared on suspend/exit. `thread_suspend`/`current_thread` read it. For Arm B,
   the `Yielder` is stored in the `Microthread` (set while running), retrieved via
   `CURRENT`. This is the analogue of the existing design and is the main "does Rust
   let me do this ergonomically" question.
2. **Address stability of the context object.** `thread_context` is handed to C and
   held across suspends; the Rust `Microthread` must be heap-pinned (`Box`/`Pin`, or an
   arena with stable addresses) and never moved while C holds the pointer. Lifetime is
   manual (retain/release semantics already exist: `dtape_thread_retain/release`). Model
   it explicitly; do not fight it with `&mut`.

## Explicitly OUT of scope for the spike (validate later, do not let them creep in)

- The **continuation path** (`makecontext(microthreadContinuation)` + stack discard).
  Prove it in a *second* micro-spike (semaphore down *with* a continuation) once the
  stackful path is green. It maps to "drop the coroutine, start a fresh one running the
  continuation" -- a known corosensei pattern, but a distinct proof.
- **Interrupts / signals:** `_interrupts` stack, `_syscallReturnHereDuringInterrupt`,
  nested microthread execution for signal delivery. Large; separate spike.
- **Impersonation** (`impersonatingThread`), **ASan fiber annotations**
  (`__sanitizer_start_switch_fiber`), the **full 34 hooks**, **RPC decode**, real
  **port/task tables**. None are needed to falsify the hypothesis.

## Go / No-Go

- **GO (rewrite viable):** `SPIKE_RESUMED_OK`, exit 0, under ASan/valgrind clean; Arm A
  works; Arm B either works or has a clearly-understood fixable gap; switch cost within
  ~10% of the current C++ P1 microbench.
- **NO-GO / rethink:** suspend-from-C requires disabling P1 (sigmask back), or corosensei
  cannot yield from a foreign frame and raw ucontext is the only option *and* it fights
  the ownership model so hard that Stage 4 looks worse than maintaining C++. (Raw-ucontext-
  behind-`unsafe` alone is NOT a no-go -- Arm A expects it.)

## Rust skeleton (Arm A -- enough to be real, not pseudocode)

```rust
// build.rs: cc::Build compiles fast_context.c + links the duct-tape static lib.
// bindgen generates `dtape_*` externs from duct-tape.h + hooks.h.

#[repr(C)]
struct Microthread {
    resume_ctx: ucontext_t,     // _resumeContext
    stack: Vec<u8>,             // owned microthread stack (pooled later)
    suspended: bool,
    dtape_thread: *mut dtape_thread_t, // set by dtape_thread_create(task, nsid, self)
    interrupt_disable: u32,
}
thread_local! {
    static CURRENT: Cell<*mut Microthread> = Cell::new(ptr::null_mut());
    static BACK_TO_TOP: UnsafeCell<ucontext_t> = /* zeroed */;
}

extern "C" fn hook_thread_suspend(ctx: *mut c_void, cont: DtapeCont, cont_ctx: *mut c_void,
                                  unlock_me: *mut libsimple_lock_t) {
    let mt = ctx as *mut Microthread;
    unsafe {
        (*mt).suspended = true;
        if !unlock_me.is_null() { libsimple_lock_unlock(unlock_me); }
        dserver_fast_getcontext(&mut (*mt).resume_ctx);   // returns twice
        if (*mt).suspended {
            // first return: bail back to the loop (stackful path; cont==NULL for spike)
            debug_assert!(cont.is_none());
            BACK_TO_TOP.with(|b| dserver_fast_setcontext(b.get()));
            unreachable!();
        }
        // second return: resumed -> fall through, C caller (semaphore_wait) returns
    }
}
extern "C" fn hook_thread_resume(ctx: *mut c_void) {
    // enqueue for the loop to re-enter via do_work(); single-threaded spike can push a Vec.
    SCHED.lock().push(ctx as *mut Microthread);
}
extern "C" fn hook_current_thread() -> *mut dtape_thread_t {
    CURRENT.with(|c| { let mt = c.get(); if mt.is_null() { ptr::null_mut() }
                       else { unsafe { (*mt).dtape_thread } } })
}
// ... current_task, thread_setup, thread_create_kernel, interrupt_{en,dis}able, log, timer_arm, get_load_info

fn do_work(mt: *mut Microthread) {           // worker side, mirrors doWork()
    CURRENT.with(|c| c.set(mt));
    unsafe {
        BACK_TO_TOP.with(|b| dserver_fast_getcontext(b.get())); // loop return point
        if !(*mt).suspended && already_entered(mt) { return; } // returned-to-top
        (*mt).suspended = false;
        dserver_fast_setcontext(&(*mt).resume_ctx);  // resume the parked microthread
    }
}

fn main() {
    unsafe { dtape_init(&RUST_HOOKS); }
    // bootstrap microthread runs dtape_init_in_thread, creates kernel task + sem,
    // spawns the worker microthread whose body calls dtape_semaphore_down_simple(sem),
    // then the loop calls dtape_semaphore_up(sem) and re-runs the woken microthread.
    run_loop();   // pops SCHED, calls do_work; exits when the worker prints SPIKE_RESUMED_OK
}
```
(Arm B swaps `Microthread`'s ucontext for a `corosensei::Coroutine` + stored `Yielder`;
`hook_thread_suspend` becomes `YIELDER_OF(mt).suspend(())`, `do_work` becomes
`coroutine.resume(())`. Same hooks, same vehicle, same success line.)

## Effort + what a green spike unlocks

- **~2-4 days:** Stage 0 link proof (cargo + `cc` + link the duct-tape `.a` + `dtape_init`)
  is a prerequisite; then Arm A to `SPIKE_RESUMED_OK`; then Arm B; then the P1 microbench.
- **Green unlocks Stage 4** with the load-bearing risk retired: the microthread scheduler,
  the work queue, and the port/thread/process tables can be ported to safe Rust over the
  frozen `dtape` FFI, preserving P0/P1/P2, behind the correctness gates
  (`run-tests.sh`, M1 via `build-pkg-bypass.sh`, the spawn/IPC stress).
- **Red** costs only the spike, and tells us to keep darlingserver in C++ and invest the
  Rust budget in the host-side tooling + mldr instead.
