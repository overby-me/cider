# Rewriting Darling's host side in Rust: a de-risked plan

Decision taken: **we want the Rust rewrite.** This doc is therefore about *how to
do it right*, not whether. It is grounded in the real architecture (LOC, the
`dtape` boundary, the scheduler model, the RPC seam) measured on this tree
(2026-07), because those facts dictate the only design that actually works.

The target with real leverage is **darlingserver** (the daemon). **mldr** and the
**build tooling** are the low-risk on-ramp that builds the Rust-in-tree toolchain
and team muscle before the daemon. The macOS ABI layer (libSystem, frameworks,
dyld, objc4) is **never** rewritten -- it must stay Mach-O tracking Apple, validated
against cache.nixos.org. The vendored XNU under duct-tape (738k lines) stays C
forever.

## The one boundary that governs everything: `dtape`

The daemon is not cleanly separable from the emulation. Measured:

- darlingserver calls **271 distinct `dtape_*` functions** *into* the C duct-tape.
- The duct-tape calls *back* into the daemon through a **`dtape_hooks` vtable**
  (`server.cpp:388` registers it; `dtape_init(&dtape_hooks)`), e.g.
  `dtape_hooks->thread_suspend` / `->thread_resume` (`duct-tape/src/locks.c`,
  `condvar.c`), `->current_thread`, `->current_task`, `->thread_syscall_return`,
  `->log`, `->interrupt_enable/disable`.
- The duct-tape runs **XNU code on the daemon's microthreads** and suspends/resumes
  them *synchronously from deep inside C call stacks* (a mach receive blocks, a
  kernel lock waits).

**So the Rust/C boundary is the `dtape_*` API + the `dtape_hooks` contract, not the
RPC.** Rust owns everything *above* it (event loop, RPC codec, process/thread/port
tables, the microthread scheduler); C keeps everything *below* it (duct-tape glue +
XNU). Step 1 of the project is to **freeze that contract** as the FFI interface and
never widen it.

Consequence to internalize up front: because the daemon holds Rust-owned `Thread`/
`Task`/`Port` objects that the C hooks are handed as raw context pointers, those
objects must be **address-stable** (heap-boxed / `Pin`, never moved) and their
lifetimes managed on the Rust side. The hooks are `extern "C"` shims that recover
`&Thread` from the context pointer. This is `unsafe`, but it is *contained* to the
hook layer -- everything the daemon builds on top is safe Rust.

## The design constraint that kills the naive plan: no async

The obvious "rewrite it in modern Rust" instinct is `async`/`await` + Tokio. **It
does not work here**, and knowing why saves a wasted quarter:

`dtape_hooks->thread_suspend` is called **synchronously, from inside a C/XNU call
stack**, to block the current microthread. You cannot `.await` across a C stack
frame. The only ways to suspend a computation that is mid-C-call are (a) a full OS
thread per microthread (defeats the point; thousands of guest threads) or (b)
**stackful coroutines** -- which is exactly what the current ucontext design is.

**Therefore the Rust scheduler stays stackful.** Use a stackful-coroutine crate
(`corosensei` -- fast, portable switch; or `generator`) instead of raw `ucontext`,
OR keep the tuned assembly switch behind a tiny shim. Either way, `thread_suspend`/
`thread_resume` map to coroutine yield/resume, and the C duct-tape is none the
wiser. `async` is fine for nothing in the microthread path; the single epoll loop
can be a hand-rolled `epoll_wait` (or `mio`) -- do **not** pull in Tokio, whose
model fights the stackful requirement.

This also means the landed perf work is a **constraint, not a target**: P1
(signal-mask-free microthread context switch) and P2 (epoll re-arm) are already ✅
done in the C++ daemon (`plan/perf-improvements.md`). The Rust port must *preserve*
their semantics (fast switch with no per-swap sigmask syscall; EPOLLONESHOT re-arm
discipline) or it is a straight regression. Port them; do not "rediscover" them.

## What the rewrite does and does not buy (set expectations honestly)

- **Buys:** memory-/lifetime-safety on the daemon's *own* state -- the port tables,
  the thread/process registries, the RPC buffers, the epoll/scheduler bookkeeping
  (measured: ~112 alloc sites, ~32 mutex/atomic sites across src+headers). These
  are where the daemon's *own* concurrency and use-after-free hazards live, and
  Rust's ownership model genuinely removes that class.
- **Does NOT buy:** correctness of the emulation. The FFI'd XNU semantics stay
  `unsafe` C. This session's live blockers -- the launchd portset/kqueue deadlock
  (#47), the intermittent SIGFPE (#44), the fork/exec race -- live *below* the
  boundary, in duct-tape/XNU/signal-emulation. **A Rust daemon would not have
  prevented any of them.** Rewrite for the daemon's own robustness and
  maintainability, not to fix emulation fidelity.

## Boundary map

| Layer | Language after rewrite | Why |
|---|---|---|
| RPC clients (guest libSystem) | unchanged Mach-O | wire-compatible; never touched |
| RPC codec | **Rust**, byte-identical wire | generated from one source of truth |
| Event loop, scheduler, port/thread/process tables | **Rust** (stackful coroutines) | the daemon's own logic + hot path |
| `dtape_*` API + `dtape_hooks` | **FFI boundary** (frozen) | the one seam; 271 fns + hook vtable |
| duct-tape glue (8.5k) | **C** | wraps XNU; enormous, not a win |
| vendored XNU (738k) | **C** | tracks Apple; never |
| mldr (2.85k) | **Rust** (on-ramp) | small, self-contained Mach-O parse |
| launcher `darling.c` (1.36k) | Rust (optional, later) | folds into startup path |
| build tooling (rpc-wrappers, stubs) | **Rust** (on-ramp) | build-time only, zero risk |

## Staged, gated migration (each stage independently shippable)

The daemon is a single process, so you cannot run half-C++/half-Rust *within* one
daemon. The plan is therefore: build the Rust toolchain and de-risk the hard part
on the side, stand up a **parallel Rust daemon**, and cut over behind a gate --
keeping the C++ daemon buildable as a fallback until the Rust one passes.

**Stage 0 -- toolchain + link proof.** Cargo workspace (`src/external/darlingserver-rs`
or similar) wired into `nix/package.nix` (the Rust-in-nix toolchain already exists
from rust-ninja). Link the existing C duct-tape as a static lib via the `cc`/`cmake`
crate. Prove a Rust binary can call *one* `dtape_*` function and link the whole
duct-tape `.a`. Deliverable: it links and runs `dtape_init`.

**Stage 1 -- RPC codec generator (build tooling, on-ramp).** Extend
`src/external/darlingserver/scripts/generate-rpc-wrappers.py` (1.6k lines; the RPC
surface is its in-file `calls = [...]` list -- a real single source of truth that
already emits the public header, internal header, and library source) to emit
**Rust** decoders/encoders alongside the current C. This keeps the wire format
byte-identical (clients unchanged) and lands the RPC types in Rust with zero daemon
risk. Gate: generated C is unchanged; a Rust round-trip test matches the C wire bytes.

**Stage 2 -- mldr in Rust (foothold).** Rewrite the Mach-O parse + load-command
handling with `goblin`/`object`; keep the register/stack setup and jump-to-entry as
`asm!`. Independent process, low blast radius, real Rust practice on the exact FFI/
exec/vchroot patterns the daemon needs. Gate: guest processes start; `hello` builds
(`scripts/build-hello-bypass.sh`); the spawn stress is clean.

**Stage 3 -- THE SPIKE (make-or-break; do before committing to the full port).**
Minimal Rust daemon that: opens the RPC socket, decodes a couple of calls, holds a
toy thread/port table, calls `dtape_init` with **Rust-implemented `dtape_hooks`**,
and drives **one microthread** (stackful coroutine) through an XNU call that
*suspends and resumes* via `thread_suspend`/`thread_resume` -- e.g. a blocking mach
receive that another call wakes. If a stackful coroutine can suspend from inside the
C/XNU stack and resume correctly and fast across the FFI, the rewrite is viable. If
this is ugly or slow, stop here -- you have spent days, not quarters. **This spike
is the single highest-information step; schedule it first after Stage 0.**

**Stage 4 -- port the core.** With the spike proven: port the epoll loop, the
microthread dispatch/workqueue, the timer path, and the port/thread/process tables
to safe Rust over the frozen `dtape` FFI. Preserve P0 (ucred cache), P1, P2. Bring
the *full* RPC surface online. The C++ daemon still exists in parallel.

**Stage 5 -- cutover.** Flip `darlingserver` to the Rust binary (a build switch /
`DSERVER_IMPL=rust`), gated by the whole correctness suite (below). Keep the C++
daemon buildable for one release as a fallback; delete once the Rust daemon has
carried real workloads (guest Nix building packages) without regression.

## Correctness gates (run at every stage, non-negotiable)

1. Guest userland smoke tests (`scripts/run-tests.sh`) green in a fresh prefix.
2. **M1 still holds:** guest Nix builds hello/pv/jq from source and they run
   (`scripts/build-pkg-bypass.sh`), rootless, via the launchd bypass.
3. The **spawn/IPC stress** (the P-series loop in `plan/perf-improvements.md`)
   passes with no context-switch/epoll regression, and no new leaks/races (run the
   Rust daemon under ASan/TSan-equivalent + `MIRIFLAGS` on unit-testable pieces).
4. The cache.nixos.org oracle where a built artifact is comparable.
Never merge a stage that regresses any of these.

## Crate / tooling choices

- **Stackful coroutines:** `corosensei` (fast, no sigmask games -- preserves P1) or
  keep the tuned asm switch behind a shim. **Not** async/Tokio for the scheduler.
- **epoll:** hand-rolled `epoll_wait` or `mio` (raw), single loop -- match the model.
- **FFI:** `bindgen` for the `dtape_*` headers; hand-write the **28** `dtape_hooks`
  vtable entries (`dtape_hooks_t` in `duct-tape/include/darlingserver/duct-tape.h`).
- **Mach-O (mldr):** `goblin` / `object`. **Syscalls (mldr/launcher):** `nix` + `libc`.
- **Build:** `cc`/`cmake` crate to compile+link the C duct-tape as a static lib;
  the whole thing produced by `nix/package.nix` like the rest of the tree.

## Provenance / dividing line (why this is even allowed)

You may rewrite only what Darling *owns and designed*; never what it *tracks from
Apple* (that would lose upstream tracking and, for the ABI dylibs, the cache oracle).
Verified by copyright headers + `nix/submodules.json`: darlingserver ("Copyright
Darling developers"), mldr + `darling.c` ("Copyright Lubos Dolezel"), and the
duct-tape glue are Darling-original; libc/objc4/Foundation/dyld/the libSystem
sublibs/the wrapped XNU/mig are Apple-tracking forks. The rewrite targets the former
and stops exactly at the `dtape` boundary into the latter.

## One-paragraph bottom line

Rewrite the host side, drawing the Rust/C line at the **`dtape_*` API +
`dtape_hooks` vtable**; keep the duct-tape + XNU + the whole macOS ABI in C. The
scheduler **must** stay stackful (coroutines, not async) because the duct-tape
suspends microthreads synchronously from inside C call stacks -- this is the design's
load-bearing decision. De-risk in order: toolchain/link proof -> Rust RPC codec ->
mldr -> **the suspend/resume spike (make-or-break, do early)** -> port the core
preserving P0/P1/P2 -> gated cutover with the C++ daemon as fallback. Expect the
payoff in the daemon's *own* lifetime/concurrency safety, not in emulation fidelity
(the XNU stays `unsafe` C, so the fidelity bugs remain a separate track).

## Status: what is implemented (2026-07-25)

The plan above was executed through Stage 4's skeleton. On origin/main, in
`src/external/darlingserver-rs` (a clean lib + 11 green bins + an automated parity
gate), built reproducibly via `nix build '.?submodules=1#darlingserver-rs'`:

- **Stage 0** -- links the real duct-tape `.a`; `dtape_init` runs the full XNU
  subsystem init through Rust hooks (`dtape-link-proof` -> STAGE0_OK).
- **Stage 3 (the make-or-break spike)** -- a Rust stackful microthread suspends
  from inside XNU C and resumes across the FFI, **both** paths (stackful via a
  semaphore; continuation via `thread_block`), on the FFI'd P1 `fast_context`
  (`stage3-spike`). Promoted off `static mut` into the reusable `sched` module.
- **Stage 1** -- the RPC wire codec is generated from the same `calls` list and is
  **162/162 byte-identical to the C** (`scripts/rpc-wire-parity.sh`); the generator
  also emits `callnum_name`, an `RpcHandler` trait (one defaulted method per call),
  and a `dispatch()` that decodes/guards/invokes/encodes.
- **Stage 4 (skeleton)** -- receive/decode + `SCM_RIGHTS` fds (`rpc_io`), per-guest
  task routing (`registry`: pid -> dtape task), the epoll accept loop (`server`),
  and the capstone `daemon_demo`: a real daemon that accepts a socket connection,
  routes a call to the guest's task, runs the handler on a `sched` microthread
  through the generated dispatch (real `dtape_task_uidgid`), and replies -- with XNU
  state persisting across calls.
- **Guest memory (bucket B.1, head of the critical path)** -- `task_read_memory` /
  `task_write_memory` implemented via process_vm_readv/writev (the exact primitive
  Process::readMemory uses, process.cpp) and wired into the hooks vtable; each task
  now carries an address-stable `TaskCtx` with its host pid. `mem_hooks_demo` forks a
  child, reads its buffer through the read hook, overwrites it through the write hook,
  and the child confirms with a volatile load that it observes the change ->
  MEM_HOOKS_OK (green in-sandbox under `nix flake check`).
- **First Mach calls (bucket A)** -- the special-port traps (`task_self_trap`,
  `host_self_trap`, `thread_self_trap`, `mach_reply_port`) served through the real XNU
  duct-tape on a microthread bound to a guest task, returning the canonical port names
  (task_self 0x103, host_self 0x203, thread_self 0x303, a fresh reply_port 0x403);
  `task_self_trap` is also driven through the generated dispatch() -> MACH_TRAPS_OK.
- **Persistent per-guest threads (bucket B.2, head of the mach_msg path)** -- a guest
  thread's call can BLOCK mid-flight; its microthread persists (parked, addressable by
  tid), and the daemon resumes the SAME thread on the same stack when the awaited event
  arrives, state preserved and threads isolated. `persistent_threads_demo` blocks two
  threads, wakes each independently, and each reply combines a pre-block stack-local
  with the delivered payload -> PERSISTENT_THREADS_OK.
- **Mach port-right ops (bucket A)** -- `mach_port_allocate` / `deallocate` / `type` /
  `mod_refs` served through the XNU trap on a guest task, results copied OUT to guest
  memory via the write_memory hook (copyoutmap -> task_write_memory). Proven: allocate a
  receive right + a dead name and deallocate the dead name (MACH_PORT_OK); and a full
  name lifecycle -- allocate a receive right, query its type (0x20000, RECEIVE), destroy
  it with mod_refs(-1), then confirm the name is KERN_INVALID_NAME (MACH_PORT_LIFECYCLE_OK).
- **mach_msg send/receive (bucket A, the mach IPC core)** -- a full mach_msg_overwrite
  round trip through XNU on a guest task: allocate a receive-right port, then in one
  MACH_SEND_MSG|MACH_RCV_MSG call send a header-only message to it (MAKE_SEND
  destination) and receive it back. The message is copied IN from the guest buffer
  (copyinmsg -> read_memory), routed through the port's ipc_mqueue, and copied OUT to
  the guest buffer (copyoutmsg -> write_memory); the message id round-trips (0x12345678)
  -> MACH_MSG_OK. The crown jewel, composing memory hooks + port allocation + routing.
- **Blocking mach_msg receive across threads (bucket A + B.2 capstone)** -- the async
  IPC pattern: a thread does mach_msg(RCV) on an empty port and BLOCKS (thread_block with
  a continuation, stack discarded); a second thread's send wakes it (thread_resume -> run
  queue); its continuation resumes, completes the receive (copyout), and delivers the
  result via `current_thread_syscall_return` (now wired). The message id round-trips
  (0xcafebabe) -> BLOCKING_MSG_OK. This is how real Darwin IPC (XPC, libdispatch) blocks.
- **Persistent-thread doWork loop (bucket B.2, multi-call)** -- one long-lived guest
  thread serves MANY RPC calls over its lifetime, parking between them and resuming on
  the same stack, rather than a fresh microthread per call. `thread_call_loop_demo` runs
  one thread through 3 task_self_trap calls via the generated dispatch, parking between
  each; a per-thread counter reaches 3 and every reply names the same task self port ->
  THREAD_LOOP_OK. The real darlingserver Thread model.
- **Real-socket serving / minimal daemon (integration)** -- a real client PROCESS makes
  Mach calls (task_self/host_self/mach_reply_port) over a genuine unix socket (SEQPACKET
  socketpair); the daemon recvs each, routes it to the client's task (registry), runs the
  shared `Handler` (lib) on a microthread via the generated dispatch, and replies over
  the socket. The client validates every reply -> DAEMON_MACH_OK. The minimal working
  darlingserver for the special-port traps -- every proven piece assembled into a daemon
  a separate process actually talks to.
- **Cross-process copyout over the socket (handler breadth)** -- a client PROCESS calls
  mach_port_allocate over the socket; the daemon allocates the right and copies the name
  into the CLIENT's own memory via the write_memory hook (process_vm_writev to the
  client's pid), replying with just the code. Unlike the in-process demos (guest = the
  daemon), the guest here is a separate process, so this is the genuine cross-process
  write the real daemon performs -> DAEMON_ALLOC_OK.
- **mach_msg over the socket to a real client (culmination)** -- a client PROCESS runs a
  full mach_msg send/receive loopback THROUGH the daemon: it allocates a port, builds a
  message in its own memory, and issues mach_msg_overwrite over the socket; the daemon
  copies the message IN from the client (copyinmsg -> read_memory -> process_vm_readv),
  routes it through XNU's ipc_mqueue, and copies the received message OUT to the client
  (copyoutmsg -> write_memory -> process_vm_writev). Both copies cross the process
  boundary; the message id round-trips -> DAEMON_MSG_OK. Real Mach messaging for a
  separate process, the whole stack composed. (The shared `Handler` now covers the
  traps, mach_port_allocate/deallocate/type/mod_refs, and mach_msg.)
- **Full guest session over the socket (the real architecture)** -- a client PROCESS
  checks in, runs a sequence of Mach calls (task_self_trap -> mach_port_allocate -> a
  mach_msg loopback), and checks out, ALL served on ONE persistent doWork thread bound to
  the client's task: the daemon creates the thread once and the socket loop feeds it each
  call via park/wake, dispatching through the shared Handler (checkin/checkout are
  acknowledged; registration is implicit via routing) -> DAEMON_SESSION_OK. The real
  darlingserver architecture end to end: one long-lived thread per guest thread serving a
  whole session.
- **Container bring-up ported AND runtime-validated (`darlingserverd`)** -- a faithful
  Rust port of darlingserver.cpp main()'s bring-up: the privilege dance (setres*id), a
  private mount namespace + the prefix overlay, a new PID namespace for the guest init via
  clone(CLONE_NEWPID) + proc mount, and the mldr/vchroot exec of the init, then the RPC
  server. Spliced into a real darling runtime (~/darling-rt, DSERVER_*_PATH env for the
  relocatable paths) and launched via darling.c: **the container came up for real** ("container
  up (init pid N); serving <prefix>/.darlingserver.sock"), XNU initialized, and **a real guest
  process spawned and connected** -- the biggest structural piece, validated end to end.
  The guest's first RPC then surfaced the next two concrete fixes (exactly what splice-and-run
  is for; the isolated demos structurally could not catch these):
    1. **The RPC socket is `SOCK_DGRAM` + `SO_PASSCRED`, not `SOCK_SEQPACKET`** (server.cpp:452).
       The guest's checkin send hit EPROTOTYPE (-91) against my SEQPACKET Listener. The
       socketpair demos passed only because both ends were SEQPACKET; the real protocol is
       connectionless datagrams with the sender's pid via SCM_CREDENTIALS and replies sent to
       the sender's address.
    2. **The serve loop must not treat an idle `epoll_wait` timeout as fatal** (it panicked
       after the guest gave up).
  Both were FIXED (rpc_io `recv_datagram`/`send_datagram` with SCM_CREDENTIALS + a
  `SOCK_DGRAM`+`SO_PASSCRED` Listener) and re-validated live.
  Deferred vs the C++ (best-effort prefix work): setupUserHome, darlingPreInit,
  fixPermissions, the writable-/nix overlay, rlimits.

### Update 2026-07-26: the live guest now boots through fork/exec/dyld

Driving the splice-and-run loop (implement the next call the guest needs -> advance
further), the real spliced guest now gets **all the way through**: container up ->
`vchroot` (paths remap into /Volumes/SystemRoot) -> `shellspawn` -> **fork -> exec
/bin/bash -> bash loads dyld successfully**. It stops at `kqchan_proc_open` (shellspawn
watching the bash child via an EVFILT_PROC kqueue channel), which needs the async event
loop (bucket B.8). Implemented and validated this pass:
- **`set_dyld_info`** + **~26 XNU-trap handlers** (the rest of `mach_port_*`,
  `task_for_pid`/`pid_for_task`, `mach_vm_allocate`/`deallocate`, the six semaphore traps,
  `mk_timer_*`, `thread_get_special_reply_port`) -- thin `dtape_*` wrappers, link-checked.
- **The per-process state model** (`Handler::procs`, a `ProcState` per nsid) + the state
  handlers: `uidgid`, `started_suspended`, `stop_after_exec`, `set_thread_handles`,
  `task_is_64_bit`, `get_tracer`/`set_tracer`, `set`/`get_executable_path`, `groups`,
  `vchroot_path`, `mldr_path`, `kprintf` (memory ones via the read/write hooks).
- **Host-pid routing**: the guest runs in its own PID namespace, so the header pid (nsid)
  is not what process_vm_readv needs; the SO_PASSCRED credential pid is captured off each
  datagram and used for all memory ops.
- **The persistent per-thread doWork serve loop**: one long-lived microthread + mailbox
  per guest thread, with async reply routing (a blocked call's reply is flushed when
  another thread's action unblocks it) -- the real darlingserver architecture.
- **`vchroot`** (#9): the container-root fd (SCM_RIGHTS) resolved via readlink.
- **The fork lifecycle**: parent linkage via /proc PPid, vchroot+groups inheritance (what
  lets a forked child's mldr find dyld), and `fork_wait_for_child` (#11) on a per-process
  fork semaphore upped by the child's checkin.
- **Daemon exit** on container-init death (SIGCHLD; DGRAM has no EOF).

Iteration is now cargo-direct against a cached DUCT_TAPE_LIB (nix would rebuild the whole
darling tree on any crate edit, since darlingserver.nix `inherit src`s the flake).

**Then kqchan + the epoll event loop landed, and the Rust daemon now RUNS REAL COMMANDS.**
`darling shell echo ...` prints its output and exits rc=0; `uname -a` returns
`Darwin gravitas 23.4.0 ... x86_64`; `sh -c 'echo darling-rust | tr a-z A-Z; ls /'` runs a
multi-process pipeline (DARLING-RUST) and lists the whole vchroot root -- all through the
pure-Rust daemon, verified via its exclusive "container up" marker, with a clean exit when
the container init dies. Added for this:
- **kqchan** (`kqchan.rs`): the proc kqueue channel (EVFILT_PROC). socketpair(SEQPACKET),
  proc_modify/proc_read + a `notification` push; the watched target's death is detected via
  a **pidfd** (SIGCHLD only fires for the daemon's own child, not a guest grandchild).
- **The epoll event loop** in darlingserverd, multiplexing the main RPC socket, the init
  pidfd (death -> daemon exit), and each channel's socket + target pidfd. The per-thread
  doWork model is unchanged; **reply-fd plumbing** (@fd replies via SCM_RIGHTS) was added.

Broader workloads confirm this is not a one-command fluke:
`sh -c 'whoami; echo HOME=$HOME; for i in 1 2 3; do echo loop$i; done; date +YEAR=%Y'`
returns `root`, `HOME=/Users/root`, `loop1/2/3`, `YEAR=2026` -- shell control flow, env
vars, external commands (whoami/date), and time syscalls all correct, clean exit.

**Then timers and signals landed, and the Rust daemon now has broad functional parity
INCLUDING the async/continuation paths.** `sleep`/timers run robustly (timerfd + the
timer_arm hook driving a kernel microthread; a loop that sleeps repeatedly works), and
**signal delivery works, including the nested case** (a SIGUSR1 trap fires, even when the
signal arrives during a blocked `sleep`) -- via the `interrupt_enter`/`interrupt_exit`
sigexc bracket (both `dtape_thread_sigexc_enter` AND `_enter2`) plus `sigprocess`
(load-state -> process_signal -> wait_while_user_suspended -> save-state) and
`thread_suspended`, all riding the continuation-surviving doWork loop (a persistent frame
holds the getcontext re-entry point, so a continuation-based blocking call's fresh-stack
reply does not discard the serve loop). Exec-replacement (`exec echo ...`) and background
job control (`(...) & wait`) also run clean. A comprehensive sweep of diverse real Darwin
binaries -- `id -un`->root, `$((7*8))`->56, `rev`->OLLEH, `date +%Y`->2026, `sort`,
`grep -o`, `awk` (`seq|awk`->5050), `tr`, `wc`, `cat` -- all return correct output, rc=0.

So every load-bearing **mechanism** is proven in running code, and the daemon runs real
multi-process Darwin workloads end to end -- shell, pipelines, filesystem, timers, and
signals.

**Then psynch (pthread mutex/condvar/rwlock) landed, and MULTITHREADED GUESTS NOW RUN.**
All nine psynch handlers are implemented (thin wrappers over duct-tape's `dtape_psynch_*`,
with the BSD-retval reply-body infrastructure a contended wait's deferred reply needs).
Multithreaded `python -c` works: a `threading.Lock` contended across 2 threads x 50k
increments returns `COUNTER=100000` (63968 psynch ops, ~half blocking on a continuation and
resuming with the correct retval), and a `threading.Condition` across 4 threads returns
`COUNTER=80000`, `WAITER_WOKE`, `CV_DONE` -- all rc=0, matching the C++ daemon exactly. This
validates the psynch BSD-retval deferred-reply path end to end.

The blocker turned out to be a **missing init phase**, not (as first mis-diagnosed) the
single-worker model. duct-tape init is two-phase: `dtape_init` sets up processor/memory/
timer/task, then **`dtape_init_in_thread`** (init.c:117) sets up thread_call, ipc_thread_call,
clock_service, thread_deallocate_daemon, ux_handler, AND `dtape_psynch_init` -- and it MUST
run on a kernel microthread. The C++ daemon does `Thread::kernelSync(dtape_init_in_thread)`
right after `dtape_init` (server.cpp:533); the Rust `sched::init` never ran phase 2. So
psynch's global `pthread_list_mlock` stayed NULL, and the first contended pthread wait
dereferenced it -> **SIGSEGV**. The crash was silent (no Rust panic, no init-death log), so
the stopped epoll heartbeat first read as a "single-worker spinlock freeze" -- wrong: a
host SIGSEGV/backtrace handler (now installed in darlingserverd) showed the real fault, and
duct-tape's `lck_mtx`/`lck_spin` are cooperative (they call `thread_suspend`, they don't
spin), so a single worker is fine. The guest's `-111`/ECONNREFUSED was purely downstream of
the dead daemon socket -- so "task #44" is resolved: it was this crash, not an RPC race.

Fix: `sched::init` spawns a kernel microthread running `dtape_init_in_thread`, and the two
hooks phase 2 needs to spawn kernel daemon threads -- `thread_create_kernel` (bodyless
kernel microthread) and `thread_setup` (install its startup body) -- are now implemented
(both had been left NULL; C++ sets them at server.cpp:400-401).

**A second NULL-hook class then surfaced and was closed.** `hostinfo`/`vm_stat` crashed
with `rip=0x0` -- an indirect call to a NULL dtape hook. `make_hooks` had left 16 hooks
unset: the thread/task lookups, `thread_get_state`/`send_signal`/`set_pending_call_override`,
memory introspection (`get_memory_info`/`region_info`/`get_next_region`), and the S2C VM ops
(`allocate_pages`/`free_pages`/`map_file`/`change_protection`/`sync_memory`). All are now
wired with safe defaults (lookups -> null, VM ops -> failure, introspection -> empty) so no
hook is ever NULL; real impls arrive with a thread/task registry and s2c. A host crash
handler (SA_SIGINFO -> fault addr + rip) was added and is what pinpointed both NULL calls.

**Broadly validated on real workloads** (all rc=0, no crash): multithreaded python
(`threading.Lock`/`Condition`/`Queue` producer-consumer), subprocess fork/exec from threads
(incl. a thread-per-child pool), TCP sockets (threaded server + client on localhost), and
CoreFoundation/host system tools (`sw_vers`->macOS 14.4.1, `hostinfo`, `vm_stat`, `sysctl
hw.ncpu`->22). The daemon even drives the `clang`->`xcrun`->exec toolchain wrapper correctly
(it fails only because the `.dbash` prefix has no Command Line Tools installed, not a daemon
gap). The one call still returning ENOSYS in these runs is `pthread_canceled` (a cancellation
-point query), which guests tolerate gracefully; left unimplemented per the task #45 caution
around thread cancellation.

**M1 (guest Nix) now runs on the Rust daemon.** The writable-`/nix` overlay is ported
(`container::mount_nix_overlay`), so in the `.wnix` prefix the guest x86_64-darwin nix finds
itself, reports `nix 2.34.8`, sees a `nix_store_WRITABLE` store, and seeds the closure DB.
Driving `nix build hello` from source, the daemon runs the full build machinery -- unpack,
patch, and configure through dozens of autoconf checks (BSD install, mkdir -p, gawk, make,
ustar, `checking for gcc... clang`, and ~27 more) up to configure's compiler probe --
**without the daemon ever crashing** (0 host SIGSEGV/SIGABRT), and it services the S2C
memory allocations clang needs along the way (`task_allocate_pages` -> S2C mmap, verified
live: 4/4 round-trips return valid addresses, errno=0). The build does not complete, but the
blocker is now precisely diagnosed from the kept `conftest.err`, and it is **not the
daemon**: clang's `libLLVM.dylib` (LLVM 21, built for macOS 14) references
`std::__1::__libcpp_verbose_abort` (`__ZNSt3__122__libcpp_verbose_abortEPKcz`), a newer
libc++ symbol that darling's bundled `/usr/lib/libc++.1.dylib` does not export, so dyld
fails the lookup -> `abort_with_payload` -> the `Abort trap: 6`. That is a darling **guest
libc++ symbol gap** (task #10), identical under the C++ daemon.

**With that guest gap worked around, the build now runs FAR past the compiler probe.** A
host-linked wrapper `libc++.1.dylib` (defines `__libcpp_verbose_abort` -> `abort()`,
`-reexport_library`s the renamed original via the darling-ld64 Mach-O linker; see
scripts) was staged into the runtime, and clang loads: `checking whether the C compiler
works... yes`, cross-compile/GNU-C checks pass, and configure proceeds through hundreds of
autoconf subprocess checks (1000s of guest exec RPCs). Two further **daemon** fixes were
needed to get here and are committed: `reap_thread` on checkout (the daemon leaked a parked
microthread -- two big stacks -- per guest thread, so the build's thousands of subprocesses
exhausted memory and killed the daemon; now reaped) and `dtape_thread_dying` on checkout
(tear down a dead thread's Mach state). The daemon stays up through it all.

The build still doesn't reach the compile phase: in the config.status region it hits a
**Mach-message-routing livelock** -- a guest thread spins `mach_msg_overwrite` polling for a
reply that never arrives (duct-tape logs the message routed `to pid -1`, a dead/wrong task),
burning ~15% CPU with no forward progress. The stall point varies run to run (a race, not a
fixed operation). This is the current frontier: a deep Mach-message-routing/port-cleanup
issue under sustained multi-process load, distinct from every earlier blocker. So the daemon
now hosts guest nix and drives a real from-source compile through nearly all of configure --
an enormous advance over the prior first-clang-call ceiling -- with this Mach-routing
livelock the remaining thing between here and a fully-completing M1.

The other remaining gaps are narrower: s2c (VM ops the daemon delegates to the guest; not
hit by any workload tested so far, hooks stubbed to fail safely), mach-port kqchan
(`EVFILT_MACHPORT` -- the full launchd boot path, which the `DARLING_NO_LAUNCHD` bypass
sidesteps), multi-worker scheduling (now purely a throughput item, not a correctness
prerequisite), and the `DSERVER_IMPL=rust` cutover (making the Rust daemon the default).

## What is missing to fully replace the C++ daemon

### A. The ~78 unimplemented RPC handlers (breadth)
The `RpcHandler` trait defaults every call to `ENOSYS`; implemented so far: the
special-port Mach traps (`task_self_trap`/`host_self_trap`/`thread_self_trap`/
`mach_reply_port`), the port-name ops `mach_port_allocate`/`deallocate`/`type`/
`mod_refs`, and `mach_msg_overwrite` (a send/receive loopback -- real messaging), all
through real XNU (results/messages copied via the memory hooks), plus `uidgid`/
`started_suspended`/`get_tracer`. The rest, by subsystem: **Mach IPC core**
(`mach_msg` cross-task routing and OOL-descriptor transfer -- the loopback plus a
blocking cross-thread receive prove the send/receive/block/wake mechanism; `mach_port_*`
allocate/deallocate/insert/extract/move rights, port sets, dead-name notifications;
task/thread/host self + bootstrap special ports), **VM** (allocate/deallocate/
protect/read/write/remap, mmap), **thread** (get/set thread+float state, create/
terminate/suspend/resume), **signals/exceptions**, **psynch**, **bsd traps**,
**kqueue** (`EVFILT_MACHPORT`). Many are thin `dtape_*` wrappers (the `uidgid`
template); the memory-touching ones depend on bucket B.

### B. Daemon infrastructure (the actually-hard part -- not thin wrappers)
1. **Guest-memory hooks** -- read/write DONE: `task_read_memory`/`task_write_memory`
   via process_vm_readv/writev, wired into the vtable + proven (`mem_hooks_demo`).
   Still open: `allocate_pages`/`free_pages`/`map_file`/`change_protection`, which are
   S2C calls (the daemon asks the guest to mmap on its own behalf), so they wait on
   the s2c path (item 5).
2. **Persistent per-guest Threads** -- DONE: a blocked call's microthread persists
   addressable by tid and the daemon resumes the SAME thread on the awaited event, state
   preserved (`persistent_threads_demo`); and one long-lived thread serves many calls via
   the doWork loop, parking between them (`thread_call_loop_demo`). Registry
   run_thread/wake_thread. Still open: the checkin/checkout lifecycle (item 3).
3. **Process/Thread lifecycle** -- checkin/checkout now served (acknowledged; a full
   session works end to end, `daemon_session_demo`). Still open: fork/exec replacement,
   death monitoring + reaping (pidfd/waitpid), and port death notifications.
4. **The interrupt mechanism** -- signals delivered *during* a blocked call (nested
   microthreads, InterruptEnter/Exit, the sigexc path); the spike deferred this.
5. **s2c (server->guest) calls + push replies** -- the daemon calling *into* the
   guest (signal/exception delivery, continuations); only guest->daemon exists.
6. **Multi-worker scheduling + thread-safe tables** -- the scheduler is single-worker
   with thread-local state; real concurrency needs a shared work queue + locked
   port/thread tables.
7. **Timers** -- `timerfd` + `dtape_timer_fired` (`timer_arm` is a no-op today).
8. **`kqchan`** (mach-port kqueue) -- the `EVFILT_MACHPORT` waiter mechanism; this
   is exactly the launchd-boot area (task #47).
9. **The container `main()`** -- DONE and runtime-validated: brings up the container and
   boots a real guest through fork/exec/dyld (see the 2026-07-26 update). Still open: the
   deferred prefix work (setupUserHome, darlingPreInit, fixPermissions, writable-/nix
   overlay, rlimits).

**B.8 (kqchan / the async event loop): DONE for proc channels.** The epoll event loop
(main RPC socket + init pidfd + per-channel socket + target pidfd) and the proc kqueue
channel (`dserver_kqchan_*` protocol, pidfd death delivery) are implemented and validated
live -- the guest runs real commands through it. Still open: mach-port channels
(EVFILT_MACHPORT, the launchd-boot area, task #47).

**B.7 (timers): DONE -- `sleep` works.** The timer_arm hook drives a real CLOCK_MONOTONIC
timerfd (server.cpp parity), the epoll loop wakes on it and runs dtape_timer_fired on a
kernel microthread, and -- with the continuation-survival scheduler fix below --
`sh -c 'echo START; sleep 1; echo END'` prints START, waits, prints END, exits rc=0
(validated live, reproducible). The fix: a call like semaphore_timedwait unblocks via an XNU
CONTINUATION (its result comes back through thread_syscall_return on a fresh stack), which
used to discard the persistent doWork microthread's loop. Now (a) continuations run on a
separate per-microthread cont_stack (never clobbering the loop's main stack); (b) the doWork
loop lives in `sched::run_dowork_loop`, whose frame PERSISTS for the microthread's life and
whose inline getcontext is the loop-top re-entry point that thread_syscall_return setcontexts
back to (C++'s backToThreadTopContext -- gated by has_loop_top so the demos' one-shot blocking
threads keep the exit path); (c) the re-entry stashes only the SCALAR result and the serve
loop builds the reply bytes (a Vec across the non-local re-entry is unsound). Key lesson: the
getcontext must be in a frame that persists (run_dowork_loop) -- an earlier helper that
returned had its frame reused and setcontext landed on corrupted stack.

**B.4 (signals): DONE.** Signal delivery works end to end -- a program that traps SIGUSR1
and sends itself one runs its handler and continues, INCLUDING when the signal interrupts a
blocked `sleep` (`... trap USR1; (sleep 1; kill -USR1 $$) & sleep 5; echo DONE` prints
GOT_USR1 then DONE, rc=0). Pieces: interrupt_enter/exit (the sigexc bracket -- the fix was
calling `dtape_thread_sigexc_enter2` too, which pushes the user_state sigexc_exit pops;
omitting it corrupted the thread -> -111); sigprocess (#12, `dtape_thread_load/process/
save` + the `thread_set_pending_signal` hook on the microthread); thread_suspended (#23, the
self-ptrace SIGEXC_SUSPEND wait). The nested case (signal during a blocked call) is handled
by the interrupt bracket + the continuation-surviving loop -- no separate deferred-reply
machinery was needed. Broad workloads confirm capability: awk (`seq 1 100 | awk` -> 5050),
file I/O, loops, pipelines all run.

**Current gap:** the remaining pieces are s2c (server->client calls, e.g. mmap on the
guest's behalf -- not yet hit by tested workloads), mach-port kqchan (EVFILT_MACHPORT, the
launchd-boot path, bypassed by DARLING_NO_LAUNCHD), exec-replacement (checkin's exec case),
multi-worker scheduling, and the DSERVER_IMPL=rust cutover + M1 (guest nix builds hello).

### C. Cutover + validation
A `DSERVER_IMPL=rust` switch with the C++ daemon as fallback, then it must pass for
real: `darling shell` reaches a shell, `scripts/run-tests.sh` green, **M1 (guest Nix
builds hello) through the Rust daemon**, and the spawn/IPC stress clean.

### Scope + critical path
The C++ daemon is ~7.4k lines; a full Rust replacement is comparable -- a multi-week
focused effort, dominated by bucket B far more than the ~78 handlers. Critical path to
a *usable* daemon: **read/write memory, `mach_msg` (send/recv + blocking), persistent
threads + the doWork loop, and real-socket serving of a live client (incl. cross-process
copyout) are all DONE** -> remaining: **checkin/checkout lifecycle -> the container
`main()` bring-up -> `kqchan`** (for launchd), then handler breadth and the cutover gate
(M1 running on it). The mechanisms are all proven in running code; what remains is
mechanical breadth plus the container bring-up -- known subsystems against a duct-tape
API that already works from Rust, not research.

---

## M1 status (2026-07-27): Rust daemon reaches config.status; deadlock is NOT the daemon

Ran the real M1 build (guest `nix build hello` from source) through the **Rust** daemon
end to end and captured where it stalls. Result: **huge progress + a precise, non-daemon
deadlock.**

**Progress.** The build boots the container, seeds the guest nix db, and runs hello's
`./configure` to completion -- ALL clang probes and the full gnulib check battery pass
(234k+ log lines; `checking ... mbrtowc/realloc/wcwidth/...` all answered) -- reaching
`configure: creating ./config.status`. clang works fully (the libc++ verbose-abort wrapper
holds). Basic fork/exec/wait/signal/pipe/subshell/cmd-subst all validated via fast repros
(40x fork-storm rc=0; pipes+subshells+sed+heredoc rc=0).

**The stall (config.status).** Fully reproducible. Daemon goes **State=S (idle)**, not
spinning -- its single thread parks in `epoll_wait`. Process snapshot at the stall:
- `bash ./configure` (generating config.status, fd 1 -> config.status) is blocked in
  `write()` -> `anon_pipe_write` on fd 4, and holds BOTH ends of that pipe (fd 3 = read,
  fd 4 = write). No other process shares the pipe; there is no reader child.
- This pipe is **bash-internal** (configure's own fd 3/4 are only the transient
  `(exec 3>&N)` probes at lines 73-75). It is a real Linux anon pipe (kernel-level block),
  NOT daemon-mediated.

**Diagnosis.** This is bash's **here-document mechanism** for the large `<<\_ACEOF` block
that generates config.status: bash buffers a large here-doc to a temp file, and on
temp-file failure falls back to writing the body to a pipe before the consumer (`cat`)
reads -> self-deadlock (bash holds the read end, so no EPIPE). It is a guest bash/container
filesystem behavior, reached only after a full configure. It is **NOT** the daemon's
interrupt/reply path: the daemon is idle with no RPC pending, so the earlier
"fork_wait_for_child interrupt-deferral" hypothesis is RULED OUT for this stall. (The
nested-interrupt getcontext dance is a real C++ mechanism -- thread.cpp:479-487 push an
interrupt frame saving the blocked call's stack/continuation/activeCall; InterruptExit
re-sends the deferred reply -- but it is NOT what blocks M1 here.)

**Open (the parity question).** Does the **C++** daemon complete this exact build or hit
the same config.status here-doc deadlock? If C++ also deadlocks -> the Rust daemon is at
**parity** on the M1 path (a pre-existing darling here-doc/tmp-file limitation, task
#44/#47 territory). If C++ completes -> a Rust-specific regression in the guest tmp-file
path to chase. Experiment blocked momentarily on a host disk GC (store was 99% full);
run C++ M1 on ~/.wnix once the disk frees. Likely trigger to probe next: why bash's
here-doc temp file (`sys_mkstemp` under TMPDIR=the nix build dir) fails in-container,
forcing the pipe fallback.

### Parity experiment result (2026-07-27): C++ ALSO fails M1 (both flaky); Rust hangs vs C++ clean-fails

Ran the identical nix-build M1 through the **C++** daemon (~/darling-rt restored to the
C++ backup). Result across the script's 4-attempt retry loop:
- **Attempt 1** got PAST config.status (`config.status: creating Makefile / config.h /
  executing depfiles commands`) into the make phase, then failed (rc=1).
- **Attempts 2-4** each failed EARLY at `configure: error: C compiler cannot create
  executables` (the first clang link/run probe).
- Overall `build_rc=1` -- **C++ never completes the nix-build M1 either.**

So the "official" nix-build M1 is **flaky on BOTH daemons** -- dominated by task #44
transient exec-fidelity failures (a freshly-linked binary intermittently fails to run /
link), NOT by the daemon rewrite. Pipe pressure was identical under both (~529 my-uid
pipe-fd refs, far under the 16384-page soft limit), ruling out pipe-shrink.

**The one Rust-specific difference:** where the flake hits, C++ tends to **fail cleanly**
(configure exits with an error -> the retry loop re-attempts), whereas Rust can **HANG**
(the config.status bash here-doc pipe deadlock -> the build never exits -> the retry loop
never fires -> permanent stall). Making Rust fail-cleanly (or not hang) where C++ does
would bring the failure MODE to parity and let the retry loop mask the shared task-#44
flakiness the same way. Whether the Rust config.status hang is deterministic or just one
flaky manifestation is being re-tested (re-run of Rust M1).

**Bottom line for the rewrite (task #50):** the Rust daemon drives the guest through the
FULL hello ./configure identically to C++ (configure-level parity reached). The remaining
M1 non-completion is a **shared, daemon-independent** darling exec-fidelity issue (task
#44) -- not a Rust-vs-C++ gap -- plus a Rust robustness gap (hang vs clean-fail) worth
closing.

### 2026-07-27 DECISIVE: toolchain M1 COMPLETES on C++, HANGS on Rust at config.status (a Rust regression)

Ran the toolchain-path M1 (`build-hello-under-darling.sh` inline: bootstrap clang +
apple-sdk, `./configure && make && ./hello`, no guest nix) through BOTH daemons on the same
~/.wnix prefix, host qlen=16384:

- **C++ daemon: COMPLETES.** `configure_rc=0`, `make_rc=0`, `./hello` -> **"Hello, world!"**,
  `hello_rc=0`. config.status = 98995 bytes (complete), Makefile = 480583 bytes.
- **Rust daemon: HANGS at config.status** (config.status = 416 bytes, no Makefile), a guest
  bootstrap-`bash` blocked in `anon_pipe_write` (here-doc pipe), daemon idle. Reproduced
  twice (nix-build M1 at 406B, toolchain M1 at 416B) -> DETERMINISTIC, not flaky.

So this specific stall is a **Rust-daemon regression**, NOT shared task-#44 flakiness: C++
generates the full config.status and builds+runs hello; Rust deadlocks bash's here-doc at
the second (M4sh-init) here-doc every time. (The nix-build M1 is separately flaky on both
daemons via task #44; the toolchain M1 isolates the Rust regression cleanly.)

The Rust daemon must be doing something that makes bash fall back to a here-doc PIPE (and
then block) where C++ lets bash use a temp file (or the pipe reader work). Note a 228KB
`cat > file <<EOF $big EOF` runs fine under Rust in isolation, so it is NOT a blanket
here-doc break. The hung bash held two pipes (fd3 read + fd9 write = pipe A; fd4 write
BLOCKED = pipe B), i.e. bash's here-doc machinery mid-write with no reader. Leading
hypotheses to test: (a) guest pipe buffer smaller under Rust (F_GETPIPE_SZ) e.g. pipe-pages
accounting; (b) the here-doc's reader (`cat`) fails to fork/exec under Rust; (c) a
guest-visible open()/mkstemp difference so bash picks a pipe over a temp file. **This is the
concrete M1 blocker for the Rust daemon and the next thing to fix.**

### 2026-07-27 unifying insight: the config.status "hang" is likely a spurious SIGFPE on the here-doc reader

More data on the Rust toolchain-M1 flakiness:
- One run HANGS at config.status; another SIGFPE-crashes during configure (`rm` got
  "Floating point exception: 8 (core dumped)" at a `checking ...` probe). The SIGFPE is the
  known darling execution-fidelity flake (task #44, "transient signal").
- A here-doc size sweep (`cat > file <<EOF` with 1.9KB..109KB bodies) completes with 0
  failures in a FRESH Rust container -- so config.status's here-doc is NOT a pipe-size/
  capacity bug in isolation, and guest pipe pressure stays low (no lifetime-pipe leak).

**Unifying hypothesis:** the config.status stall and the visible SIGFPE are the SAME root
-- a spurious SIGFPE. config.status is generated by `cat >>config.status <<\_ASEOF`
(configure:33086, ~10-15KB M4sh-init here-doc). bash forks `cat` (the reader), then writes
the body. If `cat` takes a spurious SIGFPE and dies mid-read, bash blocks in `anon_pipe_write`
FOREVER -- because bash still holds the pipe's READ end (fd3), so the dead reader does NOT
produce EPIPE. That is exactly the observed hang (bash holding both ends, daemon idle). When
the same flake instead hits `rm`, you just see "rm: Floating point exception". So fixing the
spurious SIGFPE should fix BOTH the crash and the "hang".

**Where to look:** a spurious SIGFPE = the guest's FP state getting corrupted, then a valid
FP op faulting. The daemon touches guest thread+FLOAT state only in the signal path
(`dtape_thread_load_state_from_user` / `process_signal` / `save_state_to_user`, sigprocess
call #12). A subtly wrong float_state save/restore (address/size/ordering) under the build's
SIGCHLD storm would corrupt FP regs and fault later. Compare the Rust sigprocess/state path
(thread.rs load/process/save + the handler) against C++ thread.cpp processSignal. This is
the next concrete lead for making the Rust toolchain M1 complete.

### 2026-07-27 ROOT CAUSE + FIX: config.status hang = checkin lifetime-pipe leak -> pipe-page starvation

Found and fixed the Rust-specific M1 blocker. At a live config.status hang under the Rust
daemon, the DAEMON held **1838 pipe fds with only 5 live guest processes** -- a per-process
`lifetime_listener_pipe` LEAK. The chain:

1. Every guest process's `checkin` (call #1) passes a `lifetime_listener_pipe` fd via
   SCM_RIGHTS. The C++ daemon holds its read end and watches EOF for ungraceful death; this
   Rust daemon reaps on the explicit `checkout` and NEVER read or closed it. `Message.fds`
   (rpc_io.rs) has no Drop and only *reply* fds were closed, so `handler.rs:checkin` dropped
   the received fd on the floor -> one leaked pipe fd per process.
2. A configure run spawns ~thousands of processes -> thousands of leaked pipe read ends. Each
   pipe reserves ~16 pages, so the daemon's leak blows past `fs.pipe-user-pages-soft`
   (16384 pages, ~1024 pipes). Past that the kernel silently shrinks EVERY NEW pipe to a
   single 4KB page (rootless, host netns, so the limit is the host's).
3. bash generating config.status writes the multi-KB M4sh-init here-doc
   (`cat >>config.status <<\_ASEOF`, configure:33086) into a pipe expecting the normal 64KB
   buffer. Against a 1-page pipe with no reader yet, `write()` blocks FOREVER -> the exact
   "config.status hang" (bash in anon_pipe_write, daemon idle). C++ never leaks, so its
   guest pipes stay 64KB and the here-doc fits -> C++ completes M1.

This also explains every prior observation: fresh container = few pipes = 64KB = all here-doc
sizes pass; full configure = leak accumulates = 4KB = deadlock; and it is DAEMON-specific
(the daemon owns the leak), matching "C++ completes, Rust hangs".

**Fix (handler.rs checkin):** close the received fd(s) -- `for &fd in fds { close(fd) }`.
Stops the leak at the source, so guest pipes keep the normal 64KB buffer. (The SIGFPE crash
seen in another run is a SEPARATE, shared darling flake, task #44; it is retryable and NOT
this bug.) Validation pending: rebuild the (GC'd) duct-tape lib, cargo-build, splice, re-run
the toolchain M1 and confirm (a) daemon pipe-fd count stays flat and (b) it reaches
Makefile / "Hello, world!".

### 2026-07-27 FIXED + VALIDATED: leak is on CHECKOUT (not checkin); Rust M1 now completes

Correction to the section above: the leaked `lifetime_listener_pipe` read end rides
**`checkout` (call #2), not checkin** -- confirmed by instrumenting the recv path
(`RECV_FDS call=2 nfds=1` per process exit; checkin carries 0 fds here because
`__mldr_lifetime_pipe` is unset, so the pipe is passed at checkout). The `checkout` handler
ignored `_fds` and dropped the read end -> one leaked pipe per process EXIT.

**Fix:** `handler.rs::checkout` now closes the received fd(s) (`for &fd in fds { close(fd) }`);
`checkin` closes any too, defensively. **Validated:**
- 40-fork storm: daemon pipe-fd count stays at **0** (was climbing 845 -> 1695 -> 1838).
- Toolchain M1 under the fixed daemon: `configure_rc=0`, `make_rc=0`, **"Hello, world!"**,
  `hello_rc=0`, config.status = 98995 bytes (full), Makefile = 480583, hello = 76368. The
  config.status hang is GONE -- the Rust daemon now builds + runs hello, at parity with C++.

So the Rust-daemon M1 blocker was a plain fd leak, not signals/interrupts. (The separate
shared SIGFPE flake, task #44, is retryable and independent.) A secondary `vchroot_fd`
dir-fd leak remains (the `procs` map is never pruned) -- lower impact (dir fds, not pipes;
bounded by RLIMIT_NOFILE) and a good follow-up.
