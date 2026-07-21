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

### P0.5 — dyld shared cache  ⬅ likely the biggest *wall-clock* lever
- **Target:** per-spawn process-startup wall-clock (not a daemon syscall count).
- **Finding:** the built root ships **no** `dyld_shared_cache` (`find result-both
  -path '*shared*cache*'` is empty), though dyld has the machinery
  (`dyld3/`, `build-scripts/update_dyld_shared_cache-build.sh`). So every exec maps
  and re-relocates the full libSystem re-export closure (31 sublibraries) from
  scratch. This is almost certainly the bulk of the ~tens-of-ms per trivial spawn
  and the deepest reason Darling is heavier than Wine (which maps a handful of
  DLLs). configure/make fork thousands of these.
- **Approach:** generate a shared cache for the prefix's dylib set
  (`update_dyld_shared_cache` cross-built or run once under Darling at prefix
  init) and have dyld map it. Cache must match dylib paths/UUIDs exactly or dyld
  falls back.
- **Risk:** HIGH complexity (cache generation under emulation is why upstream
  doesn't ship one), and a stale/mismatched cache can break loading — must be
  correct-or-absent, never wrong. But the single biggest potential win; measure
  the load cost first (`scripts/darling-spawn-bench.sh`) to size it.

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

## Status (honest)

- **P0 (ucred) landed on main — 83% / 6× fewer daemon syscalls.** This was the one
  pure, obviously-correct, high-value win (a stateless cache; no core behavior
  change).
- **Everything else is core-touching.** P1 replaces the microthread context
  switch (Darling's most delicate code — intricate ucontext use across interrupts,
  syscall-resume, uc_link); P2 changes the epoll concurrency model (EPOLLONESHOT is
  load-bearing for deferred microthread consumption); P3 duplicates server port
  state in-process; P0.5 generates a dyld shared cache under emulation. A subtle
  mistake in any regresses the working `hello`. They are **not** safe to land
  autonomously without review and a reliable IPC/spawn **stress harness** — the
  current container cold-start is too flaky even for clean wall-clock grounding
  (`darling-spawn-bench.sh` hung on boot).
- **Recommended next perf step (needs review):** build a non-flaky spawn/IPC stress
  harness first, then take P1 behind a `DSERVER_FAST_CONTEXT` flag (measurable via
  `rt_sigprocmask`), and separately size P0.5 (the biggest wall-clock lever).
- Designs above are implementation-ready for when that review/harness exists.
