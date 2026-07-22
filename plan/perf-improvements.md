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

### P0.5 — dyld shared cache  ⚠️ RE-SCOPED: smaller than hypothesized (~1.8 ms/spawn)
- **Target:** per-spawn process-startup wall-clock (not a daemon syscall count).
- **Measured (attribution changed the picture):** spawn under Darling is **~11–12×
  native** (~27.9 ms vs 2.44 ms per `bash -c :`; see `darling-overhead-bench.md`).
  But `DYLD_PRINT_STATISTICS` shows **dyld pre-main is only 6.24 ms of that ~28 ms
  (22%)**, and dyld *image mapping* (dylib loading 1.35 ms + rebase 0.44 ms) is
  just **~1.8 ms (6%)**. So a shared cache saves **~1.8 ms**, not the ~20 ms this
  section originally guessed. **The dyld-cache hypothesis is largely refuted as the
  "biggest lever."**
- **Finding:** the built root ships **no** `dyld_shared_cache` (`find result-both
  -path '*shared*cache*'` is empty). It still costs ~1.8 ms/spawn to re-map+rebase
  the libSystem re-export closure, so a cache is a *real but minor* win. The bulk
  of the spawn cost is elsewhere (see the new P0.7 below).
- **Revised priority:** LOW. Do P0.7 / P1 / P2 (the darlingserver spawn path)
  first; revisit the cache only after, and only if the ~1.8 ms matters at scale.

### P0.7 — darlingserver spawn-path round-trips  ⬅ NEW: the actual biggest lever (~22 ms/spawn)
- **Target:** the ~22 ms of each ~28 ms spawn that is **not** dyld pre-main —
  i.e. fork/exec emulation, mldr load, process registration with darlingserver,
  the libSystem initializers' RPCs, and teardown. This is ~78% of the spawn tax
  and the real reason Darling is heavier than Wine here.
- **Evidence:** `darling-overhead-bench.md` attribution table; the `-111`
  (semaphore_timedwait / mach_msg) lines fired during init+teardown show those
  phases bouncing through darlingserver RPC.
- **Approach:** profile one `bash -c :` spawn on the *daemon* side
  (`scripts/darling-rpc-attach-probe.sh` counts syscalls; add per-RPC-type timing)
  to rank the round-trips, then cut them: batch the fork/exec registration RPCs,
  and land P1 (sigmask-free context switch) + P2 (EPOLLONESHOT re-arm), which
  directly reduce per-RPC syscall overhead on this path.
- **Risk:** touches the IPC core (same class as P1). Measure first (probe), change
  one round-trip at a time, validate with the spawn bench + hello + stress loop.
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

### P1 — signal-mask-free microthread context switch  ✅ DONE (landed on main)
- **Status:** implemented in `src/external/darlingserver/src/fast_context.c` +
  `thread.cpp` wiring behind the `DSERVER_FAST_CONTEXT` CMake option (default ON,
  x86_64-guarded). Drop-in `getcontext`/`setcontext`/`makecontext` that swap only
  callee-saved regs + RSP + RIP + FP control, no signal mask.
- **Validation:**
  - *Isolated (no darlingserver build):* behaviour is **byte-identical to glibc**
    across darlingserver's three usage shapes (setjmp-style resume, makecontext
    new-stack + uc_link return, cooperative suspend/resume), and **rt_sigprocmask
    goes 21 → 0** — `scripts/test-fast-context.sh` + `tests/darlingserver/`. Byte
    offsets into glibc's ucontext_t are `_Static_assert`-checked (layout mismatch =
    compile error).
  - *End-to-end:* the full darling build with `DSERVER_FAST_CONTEXT` on **boots the
    real daemon and runs commands** (twice) and **sustains a 40-spawn loop with
    zero failures** — the microthread switch (including the syscall-interrupt
    resume path) works under rapid spawning.
  - *Daemon syscalls:* the ucontext-switch `rt_sigprocmask` (the P1 target) is
    eliminated by construction; a rough daemon spawn probe showed the daemon-wide
    `rt_sigprocmask` dropping (~277→~157/spawn — the residual is other sources like
    `pthread_sigmask`). A clean per-spawn A/B was hard to pin down because the
    container cold-start is flaky this session (the `-111` RPC failures hit
    baseline runs too), so the deterministic isolated 21→0 is the primary number.
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

### P2 — reduce epoll re-arm churn  ✅ DONE (landed on main)
- **Shipped (the safe variant):** rather than change the EPOLLONESHOT concurrency
  model, memoize the **event loop's `_wakeupFD` re-arm** (`src/server.cpp`): it ran
  an `EPOLL_CTL_MOD` every iteration, but EPOLLONESHOT only disarms the fd when it
  actually fires, so re-arming an already-armed fd is pure churn. Track the armed
  state (`_wakeupArmedEvents`), only `MOD` when the desired arming changed, mark it
  disarmed when it fires. **Same armed states → semantically identical, fewer
  syscalls.** Behind `DSERVER_FAST_EPOLL` (default ON).
- **Validated via the fast splice loop:** built in ~9 min (nix/darlingserver.nix),
  spliced into a runtime, boots and runs commands, and **passed a 150-spawn stress
  run (150/150, 0 failures)**. **Benchmark: `epoll_ctl` ~67/spawn (13,397 over a
  full 200-spawn run) vs ~162 baseline ≈ 59% fewer** — the per-iteration eventfd
  re-arm was a big chunk of the epoll_ctl churn. (Baseline is the doc's earlier
  measurement; a same-run P2-off A/B would tighten it but the direction is clear.)
- **Not done (the risky part):** the Monitor re-arms (`server.cpp` ~790/808, one
  per client-socket message) and an EPOLLET rewrite are left — those are the
  concurrency-model-sensitive changes (thundering herd / missed events).

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

- **P0 (ucred) + P1 (fast context switch) landed on main.** These are the two
  pure, isolate-testable, obviously-correct wins: P0 is a stateless credential
  cache (83% / 6× fewer daemon syscalls); P1 is a drop-in sigmask-free ucontext,
  validated **byte-identical to glibc off-machine** (native unit test, no
  container) with `rt_sigprocmask` 21→0, then confirmed end-to-end (daemon boots,
  runs commands, 40-spawn loop clean). The key that made both landable
  autonomously: **their correctness can be proven without the flaky container.**
- **The rest (P2, P4, P6, P8; also P3, P5) are core-cutting and NOT isolate-testable.**
  P2 changes the epoll concurrency model (thundering-herd / missed-event hazards);
  P4 removes the per-RPC signal-block, which needs the signal-emulation path to
  cooperate (not localized); P6 rewrites RPC arg marshalling (wire format, client
  + server must agree); P8 is the scheduler futex core. Each can only be validated
  by running the **flaky container** under spawn/IPC stress — and this session's
  cold-start `-111` failures (load-dependent; they hit baseline runs too) make a
  clean before/after hard to ground. Landing any of them autonomously risks a
  subtle regression to the working spawn path that a flaky harness wouldn't catch.
- **Blocker for the rest = validation infrastructure, not design.** The designs
  above are implementation-ready. What's missing is (a) a reliable, non-flaky
  spawn/IPC stress harness, and/or (b) fast darlingserver iteration (currently a
  ~40-min full build — nix-ninja is blocked by the mig/migcom scan-toolchain issue,
  see plan/nix-ninja-primary.md). Build one of those first; then P2→P6→P4→P8 become
  tractable behind their own default-toggleable knobs (the P1 pattern).
