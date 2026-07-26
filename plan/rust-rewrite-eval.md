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
signals. The remaining gaps are narrower: s2c (VM ops the daemon delegates to the guest;
not hit by any workload tested so far), mach-port kqchan (`EVFILT_MACHPORT` -- the full
launchd boot path, which the `DARLING_NO_LAUNCHD` bypass sidesteps), multi-worker
scheduling (throughput), and the `DSERVER_IMPL=rust` cutover + M1 (guest nix builds hello,
which needs a nix-provisioned prefix).

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
