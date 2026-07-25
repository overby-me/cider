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

So every load-bearing **mechanism** is proven in running code. What remains is
breadth + infrastructure + cutover, none of it research.

## What is missing to fully replace the C++ daemon

### A. The ~78 unimplemented RPC handlers (breadth)
The `RpcHandler` trait stubs every call to `ENOSYS`; ~3 are implemented (`uidgid`,
`started_suspended`, `get_tracer`). The rest, by subsystem: **Mach IPC core**
(`mach_msg` send/receive with port-right transfer + OOL descriptors; `mach_port_*`
allocate/deallocate/insert/extract/move rights, port sets, dead-name notifications;
task/thread/host self + bootstrap special ports), **VM** (allocate/deallocate/
protect/read/write/remap, mmap), **thread** (get/set thread+float state, create/
terminate/suspend/resume), **signals/exceptions**, **psynch**, **bsd traps**,
**kqueue** (`EVFILT_MACHPORT`). Many are thin `dtape_*` wrappers (the `uidgid`
template); the memory-touching ones depend on bucket B.

### B. Daemon infrastructure (the actually-hard part -- not thin wrappers)
1. **Guest-memory hooks** -- `task_read_memory`/`write_memory`/`allocate_pages`/
   `map_file` via `/proc/<pid>/mem` + mmap; the hook vtable currently leaves them
   null. `mach_msg`, vm, and thread-state all need them.
2. **Persistent per-guest Threads** -- today one microthread per call; a real guest
   thread must be long-lived (a blocked `mach_msg` receive suspends *that* thread
   and resumes it on message arrival) with a tid -> Thread registry.
3. **Process/Thread lifecycle** -- checkin/checkout, fork/exec, death monitoring +
   reaping (pidfd/waitpid), port death notifications.
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
9. **The container `main()`** -- mounts/namespaces/vchroot, spawning launchd (or the
   bypass), the launcher handshake, and binding `<prefix>/.darlingserver.sock` (not
   a `/tmp` demo path).

### C. Cutover + validation
A `DSERVER_IMPL=rust` switch with the C++ daemon as fallback, then it must pass for
real: `darling shell` reaches a shell, `scripts/run-tests.sh` green, **M1 (guest Nix
builds hello) through the Rust daemon**, and the spawn/IPC stress clean.

### Scope + critical path
The C++ daemon is ~7.4k lines; a full Rust replacement is comparable -- a multi-week
focused effort, dominated by bucket B far more than the ~78 handlers. Critical path
to a *usable* daemon: **memory hooks -> `mach_msg` -> persistent threads ->
checkin/checkout lifecycle -> `kqchan`**, after which most handlers are thin and the
cutover gate is M1 running on it. None of this is research -- the eval's risky
questions are answered in running code; what is left is implementing known
subsystems against a duct-tape API that already works from Rust.
