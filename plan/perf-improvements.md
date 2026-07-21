# Darling performance improvements — catalog

Forward-looking catalog of overhead reductions, ranked. Companion to
`plan/perf-overhead.md` (the investigation + the first landed fix). Goal: push
Darling's per-process / per-RPC overhead toward Wine-like levels for build
workloads (configure/make fork thousands of short-lived processes).

## Methodology

- **Syscall profile:** `scripts/darling-rpc-attach-probe.sh` attaches strace to
  the darlingserver *daemon* (which lives outside the emulated userns, so its RPC
  handling is visible) over N process spawns. Counts are exact; strace slows
  wall-time, so use counts, not the time column.
- **Wall-clock:** `scripts/darling-spawn-bench.sh` (added here) times N external
  process spawns inside one warm container — the metric that actually maps to
  build time. Always pair a syscall win with a wall-clock check: cheap syscalls
  (getpid) cut count a lot but wall-time little; waits/round-trips cut both.
- **Correctness gate for every change:** darling rebuilds green, the probe's
  N-spawn workload completes, and `hello` still runs under Darling. Scheduler /
  IPC-core changes get a heavier spawn+IPC stress before landing on main.

## Baseline (after the ucred fix, 200 `uname` spawns, daemon-side)

| syscall | count | /spawn | class |
|---|---|---|---|
| futex | 38,690 | 193 | internal lock contention (scheduler/threadpool) |
| epoll_wait | 31,547 | 158 | event-loop wait (mostly genuine) |
| rt_sigprocmask | 55,445 | 277 | **ucontext switch sigmask (P1)** |
| read | 32,663 | 163 | pipe/socket reads |
| epoll_ctl | 32,404 | 162 | **EPOLLONESHOT re-arm (P2)** |
| recvmmsg+sendmmsg | 39,919 | 200 | genuine RPC I/O |
| write | 13,700 | 68 | I/O |
| process_vm_readv+writev | 7,579 | 38 | **cross-process RPC payload copy (P6)** |
| total | 256,371 | 1,282 | (was 1,537,526 / 7,687 before ucred) |

## Improvements

### P0 — cache daemon ucred  ✅ DONE (landed on main)
Per-message getpid/getuid/getgid → cached once. **1,537,526 → 256,371 syscalls
(83%, 6×).** See `plan/perf-overhead.md`.

### P1 — signal-mask-free microthread context switch  ⬅ biggest remaining
- **Target:** `rt_sigprocmask` 277/spawn (~21% of daemon syscalls).
- **Cause:** `src/thread.cpp` drives microthreads with glibc `getcontext`/
  `setcontext`/`makecontext`/`swapcontext`. glibc saves/restores `uc_sigmask` via
  an `rt_sigprocmask` syscall on *every* switch. darlingserver's microthreads run
  with an invariant process signal mask, so that save/restore is pure overhead.
- **Approach:** provide drop-in `getcontext`/`setcontext`/`makecontext`/
  `swapcontext` that swap callee-saved regs + SP + PC only, no sigprocmask, and
  honor `uc_link` (needed by `makecontext`). x86_64 first (the supported arch);
  a well-trodden pattern (libtask / State Threads / boost.fcontext). Wrap behind a
  `DSERVER_FAST_CONTEXT` build knob so it can be toggled off.
- **Risk:** HIGH — this is the IPC-emulation core. A bug = crashes/hangs/races on
  spawn. **Validation:** build green + 200-spawn probe completes + hello runs +
  a spawn/IPC stress loop; land on a branch first, merge to main only when clean.
- **Expected:** removes ~21% of daemon syscalls; modest wall-clock (sigprocmask is
  cheap) but real CPU/scheduler-jitter reduction under load.

### P2 — reduce epoll re-arm churn
- **Target:** `epoll_ctl` 162/spawn (~13%).
- **Cause:** client sockets registered `EPOLLIN | EPOLLONESHOT` (`src/server.cpp`
  ~760/790), re-armed with `EPOLL_CTL_MOD` after each message so exactly one
  worker handles a ready socket.
- **Approach:** evaluate `EPOLLET` (edge-triggered, no re-arm) with full-drain per
  wakeup, or keep oneshot but batch re-arm. Concurrency-model sensitive.
- **Risk:** MEDIUM-HIGH (thundering herd / missed-event hazards). Needs the stress
  test. **Expected:** up to ~13% fewer daemon syscalls.

### P3 — mach_msg same-task fast path (client side)
- **Target:** raw RPC count/spawn (recvmmsg ~200/spawn) — and the biggest lever
  for IPC-heavy (not just fork-heavy) workloads.
- **Cause:** `.../libsystem_kernel/.../mach_traps.c` routes *every* `mach_msg` and
  port op through `dserver_rpc_*`; no same-task/local-port shortcut.
- **Approach:** handle same-task local-port sends/receives in-process without a
  round-trip (needs a client-side view of local port state). Large.
- **Risk:** HIGH (must not diverge from server port state). Rebuildable via
  nix-ninja (libsystem_kernel) for a fast loop. **Expected:** large for IPC-heavy;
  smaller for pure fork/exec builds.

### P4 — lighten the per-RPC signal-mask atomic section (client side)
- **Target:** client-side `rt_sigprocmask` (2 per RPC) in
  `src/startup/mldr/resources/dserver-rpc-defs.h`
  (`dserver_rpc_hooks_atomic_begin/end` do a full `pthread_sigmask` block/restore
  around each send+receive).
- **Approach:** userspace signal deferral (a flag the emulated signal path checks)
  instead of a syscall pair, or a narrower mask. **Risk:** MEDIUM (signal safety).

### P5 — psynch mutex/cond uncontended fast path (client side)
- **Target:** `__psynch_mutexwait`/`__psynch_cvwait` RPCs for pthread-heavy guests.
- **Cause:** `.../psynch/psynch_mutexwait.c` RPCs unconditionally; XNU does a
  userspace CAS for the uncontended case.
- **Approach:** userspace CAS fast path, RPC only on contention. **Risk:** MEDIUM
  (XNU mutex fairness semantics). Low impact for fork/exec builds (little
  contention); matters for threaded guests.

### P6 — shrink cross-process RPC payload copies
- **Target:** `process_vm_readv`/`writev` 38/spawn.
- **Cause:** out-of-line RPC arguments read/written from the peer's address space.
- **Approach:** inline small payloads in the socket datagram (already batched via
  sendmmsg) instead of a cross-process copy. **Risk:** MEDIUM.

### P7 — cold-start latency
- **Target:** first-container boot is multi-second (each build script pays it per
  retry). Not a per-spawn cost (daemon stays warm within a build), but a big
  fixed cost.
- **Approach:** profile the darlingserver init + prefix-overlay bring-up; trim the
  handshake / lazy-init frameworks. **Risk:** MEDIUM. Measure first.

### P8 — reduce scheduler futex contention
- **Target:** `futex` 193/spawn (~39% of *time* pre-ucred).
- **Cause:** darlingserver microthread scheduler / worker-pool locking.
- **Approach:** lock-free or finer-grained queues on the hot dispatch path.
  **Risk:** HIGH (concurrency). Deepest; do last.

## Autonomous execution order

Safety × impact: **P1 → P2 → P6 → P4 → P5 → P3 → P8** (P7 measured opportunistically).
Each: implement on a branch, rebuild, run probe + wall-clock + hello smoke, and
land on main only when the correctness gate is green. Risky scheduler/IPC-core
changes (P1/P3/P8) stay on a branch if they can't be clearly validated.
